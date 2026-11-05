/* GPUTIME (fix29, gpuperf): where the GPU time of a frame goes, by category, from GPU timestamps.
 *
 * Switched on and off at run time by the diag flag file /tmp/nvmtl-gputime (a regular file owned by this process's
 * user or root, polled every 250 ms; non-release builds only). While it is on, every command buffer begun gets a
 * timestamp query pool and a timestamp at each boundary of its work: its start, each render pass begin and end, each
 * change between compute dispatches, transfers (copies, blits, clears, fills) and barrier-only stretches, and its end.
 * The segments between two timestamps are summed when the command buffer retires (its fence has signalled), and every
 * 300 frames (or 3 s) the totals are logged as "GPUTIME" lines in the plugin log:
 *   - frames and fps (frames = presents: -[NSOpenGLContext flushBuffer] or a Metal drawable's present),
 *   - GPU busy in this process's command buffers (the union of their [start, end] intervals) as a share of the wall,
 *     and per frame; the idle time between them,
 *   - per kind: render passes, compute, transfers, barrier-only stretches (a pipeline drain: the flushes and stalls
 *     between two pieces of work), empty stretches,
 *   - the render passes grouped by shape (size, colour/depth formats, samples, load mask, first fragment shaders),
 *     largest first, with count, ms per frame, us each, draws and vertices,
 *   - transfers by operation mix, and the time by submitter (who submitted the command buffer).
 * The timestamps are written bottom-of-pipe (a PIPE_CONTROL post-sync write on ANV) and only outside render passes, so a
 * segment is the time from the end of the previous piece of work to the end of this one. Render passes already begin
 * and end with ALL_COMMANDS dependencies (a pipeline drain), so the extra timestamps add little; the overhead is logged
 * as the timestamps per frame. Command buffers begun while the flag is off are not timed.
 *
 * Off: each wrapped vkCmd* entry point costs one relaxed atomic load. */
#if !NVMTL_RELEASE
#define GPT_TS 768                  /* segments per command buffer; the pool holds GPT_TS + 1 timestamps */
#define GPT_TAB 1024                /* command buffers being recorded or in flight with a record (power of two) */
#define GPT_KEYS 128                /* render pass shapes per report */
#define GPT_IV 16384                /* command buffer intervals per report */
enum { GPT_NONE, GPT_RP, GPT_CS, GPT_XF };
enum { GPX_COPYBUF = 1, GPX_BUF2IMG = 2, GPX_IMG2BUF = 4, GPX_FILL = 8, GPX_CLRCOL = 16, GPX_CLRDS = 32, GPX_BLIT = 64, GPX_COPYIMG = 128 };
static const char *const g_gpx_name[8] = { "copybuf", "buf2img", "img2buf", "fill", "clearcolour", "cleardepth", "blit", "copyimg" };
typedef struct { uint8_t kind, samples, ncol, npipe; uint16_t ops, ld; uint32_t w, h, cfmt, dfmt, n, nbar, nlay; uint64_t work; uint32_t fs[2]; } gpt_seg;
typedef struct gpt_cb { struct gpt_cb *next; VkCommandBuffer cb; VkQueryPool pool; unsigned cur, nts, ended; const char *who; gpt_seg seg[GPT_TS]; } gpt_cb;

static _Atomic int g_gpt_live;                 /* records in the table: 0 = every wrapper goes straight through */
static _Atomic uint64_t g_gpt_frames;
static _Atomic int g_gpt_reset;                /* switched on again: the totals start a new window */
static os_unfair_lock g_gpt_tlk = OS_UNFAIR_LOCK_INIT;
static gpt_cb *g_gpt_tab[GPT_TAB];
static gpt_cb *g_gpt_free; static unsigned g_gpt_nfree;

void nvmtl_gpt_frame(void) { atomic_fetch_add_explicit(&g_gpt_frames, 1, memory_order_relaxed); }
static int nvmtl_gpt_armed(void)
{
    static int was;
    const int on = nvmtl_diag_flag("gputime") && g_timestamp_bits && g_lim.timestampPeriod > 0;
    if (on != was) { was = on; if (on) atomic_store(&g_gpt_reset, 1);
        nvlog("GPUTIME %s (/tmp/nvmtl-gputime)", on ? "ON: command buffers begun from now on are timed" : "OFF"); }
    return on;
}
static inline unsigned gpt_home(VkCommandBuffer b) { const uintptr_t v = (uintptr_t)b; return (unsigned)((v >> 4) ^ (v >> 14) ^ (v >> 24)) & (GPT_TAB - 1); }
static gpt_cb *gpt_find(VkCommandBuffer b)
{
    if (!atomic_load_explicit(&g_gpt_live, memory_order_relaxed) || !b) return NULL;
    gpt_cb *g = NULL;
    os_unfair_lock_lock(&g_gpt_tlk);
    for (unsigned i = gpt_home(b), k = 0; k < GPT_TAB && g_gpt_tab[i]; i = (i + 1) & (GPT_TAB - 1), k++)
        if (g_gpt_tab[i]->cb == b) { g = g_gpt_tab[i]; break; }
    os_unfair_lock_unlock(&g_gpt_tlk);
    return g;
}
static int gpt_insert(gpt_cb *g)
{
    os_unfair_lock_lock(&g_gpt_tlk);
    if (atomic_load(&g_gpt_live) >= GPT_TAB / 2) { os_unfair_lock_unlock(&g_gpt_tlk); return -1; }
    unsigned i = gpt_home(g->cb); while (g_gpt_tab[i]) i = (i + 1) & (GPT_TAB - 1);
    g_gpt_tab[i] = g; atomic_fetch_add(&g_gpt_live, 1);
    os_unfair_lock_unlock(&g_gpt_tlk);
    return 0;
}
static gpt_cb *gpt_remove(VkCommandBuffer b)   /* linear probing with backward-shift deletion */
{
    if (!atomic_load(&g_gpt_live) || !b) return NULL;
    gpt_cb *g = NULL;
    os_unfair_lock_lock(&g_gpt_tlk);
    unsigned i = gpt_home(b), k = 0;
    for (; k < GPT_TAB && g_gpt_tab[i]; i = (i + 1) & (GPT_TAB - 1), k++) if (g_gpt_tab[i]->cb == b) { g = g_gpt_tab[i]; break; }
    if (g) {
        unsigned j = i;
        for (;;) {
            j = (j + 1) & (GPT_TAB - 1);
            if (!g_gpt_tab[j]) break;
            const unsigned h = gpt_home(g_gpt_tab[j]->cb);
            /* move j back to i unless its home lies cyclically in (i, j] */
            const int keep = i <= j ? (h > i && h <= j) : (h > i || h <= j);
            if (!keep) { g_gpt_tab[i] = g_gpt_tab[j]; i = j; }
        }
        g_gpt_tab[i] = NULL; atomic_fetch_sub(&g_gpt_live, 1);
    }
    os_unfair_lock_unlock(&g_gpt_tlk);
    return g;
}
static void gpt_recycle(gpt_cb *g)
{
    if (g->pool && g_host_query_reset) pvkResetQueryPool(g_dev, g->pool, 0, GPT_TS + 1);
    os_unfair_lock_lock(&g_gpt_tlk);
    if (g->pool && g_host_query_reset && g_gpt_nfree < 32) { g->next = g_gpt_free; g_gpt_free = g; g_gpt_nfree++; g = NULL; }
    os_unfair_lock_unlock(&g_gpt_tlk);
    if (g) { if (g->pool) pvkDestroyQueryPool(g_dev, g->pool, NULL); free(g); }
}
/* the original entry points, taken over by nvmtl_gpt_wrap */
static PFN_vkCmdWriteTimestamp o_gpt_ts;
static int gpt_ts(gpt_cb *g)   /* close segment cur, open cur + 1 (NONE) */
{
    if (g->cur + 1 >= GPT_TS) return 0;
    o_gpt_ts(g->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g->pool, g->cur + 1);
    g->cur++; memset(&g->seg[g->cur], 0, sizeof g->seg[0]);
    return 1;
}
static gpt_seg *gpt_kind(gpt_cb *g, int kind)
{
    gpt_seg *s = &g->seg[g->cur];
    if (s->kind == kind && kind != GPT_RP) return s;
    if (s->kind == GPT_NONE && !s->n && !s->nbar) { s->kind = (uint8_t)kind; return s; }   /* nothing ran since the last stamp */
    if (!gpt_ts(g)) return &g->seg[g->cur];   /* full: the rest goes into the last segment */
    s = &g->seg[g->cur]; s->kind = (uint8_t)kind; return s;
}
void nvmtl_gpt_begin(nvk_cmdbuf *c)
{
    if (!c || !c->cb || !o_gpt_ts || !nvmtl_gpt_armed()) return;
    gpt_cb *g = NULL;
    os_unfair_lock_lock(&g_gpt_tlk);
    if (g_gpt_free) { g = g_gpt_free; g_gpt_free = g->next; g_gpt_nfree--; }
    os_unfair_lock_unlock(&g_gpt_tlk);
    int fresh = 0;
    if (!g) {
        g = (gpt_cb *)calloc(1, sizeof *g); if (!g) return;
        VkQueryPoolCreateInfo qi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, NULL, 0, VK_QUERY_TYPE_TIMESTAMP, GPT_TS + 1, 0 };
        if (pvkCreateQueryPool(g_dev, &qi, NULL, &g->pool) != VK_SUCCESS) { free(g); return; }
        if (g_host_query_reset) pvkResetQueryPool(g_dev, g->pool, 0, GPT_TS + 1); else fresh = 1;
    }
    g->cb = (VkCommandBuffer)c->cb; g->cur = 0; g->nts = 0; g->ended = 0; g->who = NULL; memset(&g->seg[0], 0, sizeof g->seg[0]);
    if (fresh) pvkCmdResetQueryPool(g->cb, g->pool, 0, GPT_TS + 1);
    o_gpt_ts(g->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g->pool, 0);
    if (gpt_insert(g)) gpt_recycle(g);
}
int nvmtl_gpt_on_cb(void *cb) { return gpt_find((VkCommandBuffer)cb) != NULL; }
/* the render pass just begun: its shape (nvmtl_vk_cmd_begin_pass) */
void nvmtl_gpt_pass(void *cb, uint32_t w, uint32_t h, uint32_t cfmt, uint32_t ncol, uint32_t dfmt, uint32_t samples, uint32_t load)
{
    gpt_cb *g = gpt_find((VkCommandBuffer)cb); if (!g) return;
    gpt_seg *s = &g->seg[g->cur]; if (s->kind != GPT_RP) return;
    s->w = w; s->h = h; s->cfmt = cfmt; s->ncol = (uint8_t)ncol; s->dfmt = dfmt; s->samples = (uint8_t)samples; s->ld = (uint16_t)load;
}
/* a pipeline bound in the open pass: its fragment shader's hash (the ptpso line names its SPIR-V file) */
void nvmtl_gpt_fs(void *cb, uint32_t fs)
{
    gpt_cb *g = gpt_find((VkCommandBuffer)cb); if (!g) return;
    gpt_seg *s = &g->seg[g->cur]; if (s->kind != GPT_RP) return;
    if (s->fs[0] == fs || s->fs[1] == fs) return;
    if (!s->fs[0]) s->fs[0] = fs; else if (!s->fs[1]) s->fs[1] = fs;
    if (s->npipe < 255) s->npipe++;
}
/* before vkEndCommandBuffer, outside a render pass */
void nvmtl_gpt_end(void *cb, const char *who)
{
    gpt_cb *g = gpt_find((VkCommandBuffer)cb); if (!g || g->ended) return;
    gpt_seg *s = &g->seg[g->cur];
    if (g->cur && s->kind == GPT_NONE && !s->n && !s->nbar) g->nts = g->cur + 1;   /* the last stamp ends it */
    else { o_gpt_ts(g->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g->pool, g->cur + 1); g->nts = g->cur + 2; }
    g->who = who; g->ended = 1;
}

/* ---- totals ---- */
typedef struct { uint32_t w, h, cfmt, dfmt, fs0, fs1; uint16_t ld; uint8_t samples, ncol; uint64_t n, ns, mx, draws, work, npipe; } gpt_key;
static os_unfair_lock g_gpa_lk = OS_UNFAIR_LOCK_INIT;
static struct {
    uint64_t t0, f0, ncb, nts, nfull, nnr;
    uint64_t kind_ns[6], kind_n[6], kind_work[6];   /* NONE-with-barriers (sync), RP, CS, XF, NONE empty, barriers in all */
    uint64_t lay;                                     /* layout transitions */
    gpt_key key[GPT_KEYS]; unsigned nkey; uint64_t key_lost_ns;
    struct { uint16_t ops; uint64_t n, ns, bytes; } xf[24]; unsigned nxf;
    struct { const char *who; uint64_t n, ns; } who[16]; unsigned nwho;
    struct { uint64_t a, b; } iv[GPT_IV]; unsigned niv;
} g_gpa;
static int gpt_ivcmp(const void *x, const void *y) { const uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y; return a < b ? -1 : a > b; }
static int gpt_keycmp(const void *x, const void *y) { const gpt_key *a = x, *b = y; return a->ns < b->ns ? 1 : a->ns > b->ns ? -1 : 0; }
static void gpt_report(uint64_t now)
{
    const uint64_t frames = atomic_load(&g_gpt_frames) - g_gpa.f0; const double wall = (double)(now - g_gpa.t0);
    const double per = frames ? (double)frames : 1.0; const char *unit = frames ? "/frame" : " total";
    /* GPU busy: union of the command buffers' intervals (ticks) */
    qsort(g_gpa.iv, g_gpa.niv, sizeof g_gpa.iv[0], gpt_ivcmp);
    const uint64_t mask = g_timestamp_bits >= 64 ? ~0ull : ((1ull << g_timestamp_bits) - 1);
    double busy = 0, idle = 0; uint64_t end = 0;
    for (unsigned i = 0; i < g_gpa.niv; i++) {
        const uint64_t a = g_gpa.iv[i].a, b = g_gpa.iv[i].b;
        if (!i) { busy += (double)((b - a) & mask); end = b; continue; }
        if (a >= end) { idle += (double)(a - end); busy += (double)(b - a); end = b; }
        else if (b > end) { busy += (double)(b - end); end = b; }
    }
    const double tp = g_lim.timestampPeriod; busy *= tp; idle *= tp;
    const double span = g_gpa.niv ? (double)((end - g_gpa.iv[0].a) & mask) * tp : 0;
    nvlog_keep("GPUTIME %.2f s: %llu frames (%.1f fps), %llu cbs (%.1f%s), GPU busy in this process %.1f%% of wall = %.3f ms%s; idle between its cbs %.3f ms%s (%.1f%% of its span); %.1f timestamps%s%s%s",
               wall / 1e9, (unsigned long long)frames, frames * 1e9 / wall, (unsigned long long)g_gpa.ncb, g_gpa.ncb / per, unit,
               100.0 * busy / wall, busy / per / 1e6, unit, idle / per / 1e6, unit, span > 0 ? 100.0 * idle / span : 0.0, g_gpa.nts / per, unit,
               g_gpa.nfull ? " (some cbs ran out of timestamps)" : "", g_gpa.nnr ? " (some results not ready)" : "");
    static const char *const kname[5] = { "barrier-only", "render passes", "compute", "transfers", "empty" };
    char b[1200]; int k = 0;
    for (int i = 1; i <= 4; i++) {
        const int j = i == 4 ? 0 : i;
        k += snprintf(b + k, sizeof b - (size_t)k, " %s %.3f ms (%.1f%s)%s", kname[j], g_gpa.kind_ns[j] / per / 1e6, g_gpa.kind_n[j] / per, unit, i < 4 ? " |" : "");
    }
    k += snprintf(b + k, sizeof b - (size_t)k, " | empty %.3f ms | barriers %.1f%s, layout transitions %.1f%s, dispatch groups %.0f%s",
                  g_gpa.kind_ns[4] / per / 1e6, g_gpa.kind_n[5] / per, unit, g_gpa.lay / per, unit, g_gpa.kind_work[GPT_CS] / per, unit);
    nvlog_keep("GPUTIME  by kind%s:%s", unit, b);
    qsort(g_gpa.key, g_gpa.nkey, sizeof g_gpa.key[0], gpt_keycmp);
    for (unsigned i = 0; i < g_gpa.nkey && i < 14; i++) {
        const gpt_key *q = &g_gpa.key[i];
        nvlog_keep("GPUTIME  pass %4ux%-4u c%u fmt %3u d %3u s%u ld 0x%02x fs %08x %08x: %.2f%s, %.3f ms%s (%.1f%%), %.0f us each (max %.0f), %.0f draws %.0f verts each, %.1f pipelines",
                   q->w, q->h, q->ncol, q->cfmt, q->dfmt, q->samples, q->ld, q->fs0, q->fs1, q->n / per, unit, q->ns / per / 1e6, unit,
                   busy > 0 ? 100.0 * q->ns / busy : 0.0, q->ns / 1e3 / (double)q->n, q->mx / 1e3, (double)q->draws / q->n, (double)q->work / q->n, (double)q->npipe / q->n);
    }
    if (g_gpa.nkey > 14 || g_gpa.key_lost_ns) {
        uint64_t rest = g_gpa.key_lost_ns, rn = 0; for (unsigned i = 14; i < g_gpa.nkey; i++) { rest += g_gpa.key[i].ns; rn += g_gpa.key[i].n; }
        nvlog_keep("GPUTIME  pass (other %u shapes): %.2f%s, %.3f ms%s", g_gpa.nkey > 14 ? g_gpa.nkey - 14 : 0, rn / per, unit, rest / per / 1e6, unit);
    }
    k = 0;
    for (unsigned i = 0; i < g_gpa.nxf && k < (int)sizeof b - 160; i++) {
        char ops[96]; int o = 0; ops[0] = 0;
        for (int j = 0; j < 8; j++) if (g_gpa.xf[i].ops & (1u << j)) o += snprintf(ops + o, sizeof ops - (size_t)o, "%s%s", o ? "+" : "", g_gpx_name[j]);
        k += snprintf(b + k, sizeof b - (size_t)k, " [%s %.2f%s %.3f ms %.2f MB each]", ops, g_gpa.xf[i].n / per, unit, g_gpa.xf[i].ns / per / 1e6,
                      g_gpa.xf[i].n ? g_gpa.xf[i].bytes / 1048576.0 / g_gpa.xf[i].n : 0.0);
    }
    if (k) nvlog_keep("GPUTIME  transfers%s:%s", unit, b);
    k = 0;
    for (unsigned i = 0; i < g_gpa.nwho && k < (int)sizeof b - 120; i++)
        k += snprintf(b + k, sizeof b - (size_t)k, " [%s: %.2f cbs %.3f ms]", g_gpa.who[i].who ? g_gpa.who[i].who : "?", g_gpa.who[i].n / per, g_gpa.who[i].ns / per / 1e6);
    if (k) nvlog_keep("GPUTIME  by submitter%s:%s", unit, b);
    memset(&g_gpa, 0, sizeof g_gpa);
    g_gpa.t0 = now; g_gpa.f0 = atomic_load(&g_gpt_frames);
}
static void gpt_collect(gpt_cb *g)
{
    uint64_t r[GPT_TS + 1];
    const unsigned n = g->nts;
    if (n < 2) return;
    const VkResult q = pvkGetQueryPoolResults(g_dev, g->pool, 0, n, sizeof(uint64_t) * n, r, 8, VK_QUERY_RESULT_64_BIT);
    const uint64_t mask = g_timestamp_bits >= 64 ? ~0ull : ((1ull << g_timestamp_bits) - 1);
    const double tp = g_lim.timestampPeriod;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    os_unfair_lock_lock(&g_gpa_lk);
    if (atomic_exchange(&g_gpt_reset, 0)) memset(&g_gpa, 0, sizeof g_gpa);
    if (!g_gpa.t0) { g_gpa.t0 = now; g_gpa.f0 = atomic_load(&g_gpt_frames); }
    if (q != VK_SUCCESS) { g_gpa.nnr++; os_unfair_lock_unlock(&g_gpa_lk); return; }
    g_gpa.ncb++; g_gpa.nts += n; if (g->cur + 1 >= GPT_TS) g_gpa.nfull++;
    if (g_gpa.niv < GPT_IV) { g_gpa.iv[g_gpa.niv].a = r[0]; g_gpa.iv[g_gpa.niv].b = r[n - 1]; g_gpa.niv++; }
    uint64_t cbns = 0;
    for (unsigned i = 0; i + 1 < n; i++) {
        const gpt_seg *s = &g->seg[i];
        const uint64_t ns = (uint64_t)((double)((r[i + 1] - r[i]) & mask) * tp); cbns += ns;
        const int kind = s->kind == GPT_NONE ? (s->nbar ? 0 : 4) : s->kind;
        g_gpa.kind_ns[kind] += ns; g_gpa.kind_n[kind]++; g_gpa.kind_work[kind] += s->work;
        g_gpa.kind_n[5] += s->nbar; g_gpa.lay += s->nlay;
        if (s->kind == GPT_RP) {
            unsigned j = 0;
            for (; j < g_gpa.nkey; j++) { const gpt_key *q2 = &g_gpa.key[j];
                if (q2->w == s->w && q2->h == s->h && q2->cfmt == s->cfmt && q2->dfmt == s->dfmt && q2->ld == s->ld && q2->samples == s->samples &&
                    q2->ncol == s->ncol && q2->fs0 == s->fs[0]) break; }
            if (j == g_gpa.nkey && j < GPT_KEYS) { gpt_key *q2 = &g_gpa.key[g_gpa.nkey++]; memset(q2, 0, sizeof *q2);
                q2->w = s->w; q2->h = s->h; q2->cfmt = s->cfmt; q2->dfmt = s->dfmt; q2->ld = s->ld; q2->samples = s->samples; q2->ncol = s->ncol;
                q2->fs0 = s->fs[0]; q2->fs1 = s->fs[1]; }
            if (j < g_gpa.nkey) { gpt_key *q2 = &g_gpa.key[j]; q2->n++; q2->ns += ns; if (ns > q2->mx) q2->mx = ns; q2->draws += s->n; q2->work += s->work; q2->npipe += s->npipe;
                if (!q2->fs1 && s->fs[1]) q2->fs1 = s->fs[1]; }
            else g_gpa.key_lost_ns += ns;
        } else if (s->kind == GPT_XF) {
            unsigned j = 0; for (; j < g_gpa.nxf && g_gpa.xf[j].ops != s->ops; j++) {}
            if (j == g_gpa.nxf && j < 24) { g_gpa.xf[j].ops = s->ops; g_gpa.nxf++; }
            if (j < g_gpa.nxf) { g_gpa.xf[j].n++; g_gpa.xf[j].ns += ns; g_gpa.xf[j].bytes += s->work; }
        }
    }
    { unsigned j = 0; for (; j < g_gpa.nwho && g_gpa.who[j].who != g->who; j++) {}
      if (j == g_gpa.nwho && j < 16) { g_gpa.who[j].who = g->who; g_gpa.nwho++; }
      if (j < g_gpa.nwho) { g_gpa.who[j].n++; g_gpa.who[j].ns += cbns; } }
    const uint64_t frames = atomic_load(&g_gpt_frames) - g_gpa.f0;
    if (frames >= 300 || now - g_gpa.t0 >= 3000000000ull) gpt_report(now);
    os_unfair_lock_unlock(&g_gpa_lk);
}
/* from nvmtl_cmd_retire: an ended record whose fence signalled is summed; any record is dropped */
void nvmtl_gpt_retire(void *cb)
{
    gpt_cb *g = gpt_remove((VkCommandBuffer)cb); if (!g) return;
    if (g->ended) gpt_collect(g);
    gpt_recycle(g);
}

/* ---- the wrapped entry points ---- */
#define GPT_DECL(f) static PFN_##f o_gpt_##f;
GPT_DECL(vkCmdBeginRenderPass) GPT_DECL(vkCmdEndRenderPass) GPT_DECL(vkCmdDispatch) GPT_DECL(vkCmdDispatchIndirect) GPT_DECL(vkCmdDraw)
GPT_DECL(vkCmdDrawIndexed) GPT_DECL(vkCmdDrawIndirect) GPT_DECL(vkCmdDrawIndexedIndirect) GPT_DECL(vkCmdPipelineBarrier) GPT_DECL(vkCmdCopyBuffer)
GPT_DECL(vkCmdCopyBufferToImage) GPT_DECL(vkCmdCopyImageToBuffer) GPT_DECL(vkCmdFillBuffer) GPT_DECL(vkCmdClearColorImage)
GPT_DECL(vkCmdClearDepthStencilImage) GPT_DECL(vkCmdBlitImage) GPT_DECL(vkCmdCopyImage)
#undef GPT_DECL
static void VKAPI_CALL gpt_BeginRenderPass(VkCommandBuffer b, const VkRenderPassBeginInfo *i, VkSubpassContents c)
{
    gpt_cb *g = gpt_find(b);
    if (g) { gpt_seg *s = gpt_kind(g, GPT_RP); if (s->kind == GPT_RP && i) { s->w = i->renderArea.extent.width; s->h = i->renderArea.extent.height; } }
    o_gpt_vkCmdBeginRenderPass(b, i, c);
}
static void VKAPI_CALL gpt_EndRenderPass(VkCommandBuffer b)
{
    o_gpt_vkCmdEndRenderPass(b);
    gpt_cb *g = gpt_find(b); if (g) (void)gpt_ts(g);
}
static inline void gpt_add(VkCommandBuffer b, int kind, uint16_t op, uint64_t work)
{
    gpt_cb *g = gpt_find(b); if (!g) return;
    gpt_seg *s = kind == GPT_RP ? &g->seg[g->cur] : gpt_kind(g, kind);
    s->n++; s->work += work; s->ops |= op;
}
static void VKAPI_CALL gpt_Dispatch(VkCommandBuffer b, uint32_t x, uint32_t y, uint32_t z) { gpt_add(b, GPT_CS, 0, (uint64_t)x * y * z); o_gpt_vkCmdDispatch(b, x, y, z); }
static void VKAPI_CALL gpt_DispatchIndirect(VkCommandBuffer b, VkBuffer f, VkDeviceSize o) { gpt_add(b, GPT_CS, 0, 0); o_gpt_vkCmdDispatchIndirect(b, f, o); }
static void VKAPI_CALL gpt_Draw(VkCommandBuffer b, uint32_t a, uint32_t c, uint32_t d, uint32_t e) { gpt_add(b, GPT_RP, 0, (uint64_t)a * c); o_gpt_vkCmdDraw(b, a, c, d, e); }
static void VKAPI_CALL gpt_DrawIndexed(VkCommandBuffer b, uint32_t a, uint32_t c, uint32_t d, int32_t e, uint32_t f) { gpt_add(b, GPT_RP, 0, (uint64_t)a * c); o_gpt_vkCmdDrawIndexed(b, a, c, d, e, f); }
static void VKAPI_CALL gpt_DrawIndirect(VkCommandBuffer b, VkBuffer f, VkDeviceSize o, uint32_t n, uint32_t s) { gpt_add(b, GPT_RP, 0, 0); o_gpt_vkCmdDrawIndirect(b, f, o, n, s); }
static void VKAPI_CALL gpt_DrawIndexedIndirect(VkCommandBuffer b, VkBuffer f, VkDeviceSize o, uint32_t n, uint32_t s) { gpt_add(b, GPT_RP, 0, 0); o_gpt_vkCmdDrawIndexedIndirect(b, f, o, n, s); }
static void VKAPI_CALL gpt_PipelineBarrier(VkCommandBuffer b, VkPipelineStageFlags ss, VkPipelineStageFlags ds, VkDependencyFlags f, uint32_t nm, const VkMemoryBarrier *m,
                                           uint32_t nb, const VkBufferMemoryBarrier *bb, uint32_t ni, const VkImageMemoryBarrier *im)
{
    gpt_cb *g = gpt_find(b);
    if (g) { gpt_seg *s = &g->seg[g->cur]; s->nbar++; for (uint32_t k = 0; k < ni; k++) if (im[k].oldLayout != im[k].newLayout) s->nlay++; }
    o_gpt_vkCmdPipelineBarrier(b, ss, ds, f, nm, m, nb, bb, ni, im);
}
static uint64_t gpt_bic_bytes(uint32_t n, const VkBufferImageCopy *r) { uint64_t t = 0; for (uint32_t i = 0; i < n; i++) t += (uint64_t)r[i].imageExtent.width * r[i].imageExtent.height * r[i].imageExtent.depth * 4; return t; }
static void VKAPI_CALL gpt_CopyBuffer(VkCommandBuffer b, VkBuffer s, VkBuffer d, uint32_t n, const VkBufferCopy *r)
{ uint64_t t = 0; for (uint32_t i = 0; i < n; i++) t += r[i].size; gpt_add(b, GPT_XF, GPX_COPYBUF, t); o_gpt_vkCmdCopyBuffer(b, s, d, n, r); }
static void VKAPI_CALL gpt_CopyBufferToImage(VkCommandBuffer b, VkBuffer s, VkImage d, VkImageLayout l, uint32_t n, const VkBufferImageCopy *r)
{ gpt_add(b, GPT_XF, GPX_BUF2IMG, gpt_bic_bytes(n, r)); o_gpt_vkCmdCopyBufferToImage(b, s, d, l, n, r); }
static void VKAPI_CALL gpt_CopyImageToBuffer(VkCommandBuffer b, VkImage s, VkImageLayout l, VkBuffer d, uint32_t n, const VkBufferImageCopy *r)
{ gpt_add(b, GPT_XF, GPX_IMG2BUF, gpt_bic_bytes(n, r)); o_gpt_vkCmdCopyImageToBuffer(b, s, l, d, n, r); }
static void VKAPI_CALL gpt_FillBuffer(VkCommandBuffer b, VkBuffer d, VkDeviceSize o, VkDeviceSize s, uint32_t v)
{ gpt_add(b, GPT_XF, GPX_FILL, s == VK_WHOLE_SIZE ? 0 : s); o_gpt_vkCmdFillBuffer(b, d, o, s, v); }
static void VKAPI_CALL gpt_ClearColorImage(VkCommandBuffer b, VkImage i, VkImageLayout l, const VkClearColorValue *c, uint32_t n, const VkImageSubresourceRange *r)
{ gpt_add(b, GPT_XF, GPX_CLRCOL, 0); o_gpt_vkCmdClearColorImage(b, i, l, c, n, r); }
static void VKAPI_CALL gpt_ClearDepthStencilImage(VkCommandBuffer b, VkImage i, VkImageLayout l, const VkClearDepthStencilValue *c, uint32_t n, const VkImageSubresourceRange *r)
{ gpt_add(b, GPT_XF, GPX_CLRDS, 0); o_gpt_vkCmdClearDepthStencilImage(b, i, l, c, n, r); }
static void VKAPI_CALL gpt_BlitImage(VkCommandBuffer b, VkImage s, VkImageLayout sl, VkImage d, VkImageLayout dl, uint32_t n, const VkImageBlit *r, VkFilter f)
{ gpt_add(b, GPT_XF, GPX_BLIT, 0); o_gpt_vkCmdBlitImage(b, s, sl, d, dl, n, r, f); }
static void VKAPI_CALL gpt_CopyImage(VkCommandBuffer b, VkImage s, VkImageLayout sl, VkImage d, VkImageLayout dl, uint32_t n, const VkImageCopy *r)
{ uint64_t t = 0; for (uint32_t i = 0; i < n; i++) t += (uint64_t)r[i].extent.width * r[i].extent.height * r[i].extent.depth * 4;
  gpt_add(b, GPT_XF, GPX_COPYIMG, t); o_gpt_vkCmdCopyImage(b, s, sl, d, dl, n, r); }
/* after vkCreateDevice and the hitch/census wrappers: ours go on top */
static void nvmtl_gpt_wrap(void)
{
    if (!pvkCmdWriteTimestamp || !pvkCreateQueryPool || !pvkGetQueryPoolResults) return;
    o_gpt_ts = pvkCmdWriteTimestamp;
#define GPT_W(f, w) do { o_gpt_##f = p##f; p##f = w; } while (0)
    GPT_W(vkCmdBeginRenderPass, gpt_BeginRenderPass); GPT_W(vkCmdEndRenderPass, gpt_EndRenderPass); GPT_W(vkCmdDispatch, gpt_Dispatch);
    GPT_W(vkCmdDispatchIndirect, gpt_DispatchIndirect); GPT_W(vkCmdDraw, gpt_Draw); GPT_W(vkCmdDrawIndexed, gpt_DrawIndexed);
    GPT_W(vkCmdDrawIndirect, gpt_DrawIndirect); GPT_W(vkCmdDrawIndexedIndirect, gpt_DrawIndexedIndirect); GPT_W(vkCmdPipelineBarrier, gpt_PipelineBarrier);
    GPT_W(vkCmdCopyBuffer, gpt_CopyBuffer); GPT_W(vkCmdCopyBufferToImage, gpt_CopyBufferToImage); GPT_W(vkCmdCopyImageToBuffer, gpt_CopyImageToBuffer);
    GPT_W(vkCmdFillBuffer, gpt_FillBuffer); GPT_W(vkCmdClearColorImage, gpt_ClearColorImage); GPT_W(vkCmdClearDepthStencilImage, gpt_ClearDepthStencilImage);
    GPT_W(vkCmdBlitImage, gpt_BlitImage); GPT_W(vkCmdCopyImage, gpt_CopyImage);
#undef GPT_W
}
#else
void nvmtl_gpt_frame(void) {}
static inline void nvmtl_gpt_begin(nvk_cmdbuf *c) { (void)c; }
int nvmtl_gpt_on_cb(void *cb) { (void)cb; return 0; }
void nvmtl_gpt_pass(void *cb, uint32_t w, uint32_t h, uint32_t cfmt, uint32_t ncol, uint32_t dfmt, uint32_t samples, uint32_t load) { (void)cb, (void)w, (void)h, (void)cfmt, (void)ncol, (void)dfmt, (void)samples, (void)load; }
void nvmtl_gpt_fs(void *cb, uint32_t fs) { (void)cb, (void)fs; }
void nvmtl_gpt_end(void *cb, const char *who) { (void)cb, (void)who; }
void nvmtl_gpt_retire(void *cb) { (void)cb; }
static inline void nvmtl_gpt_wrap(void) {}
#endif
