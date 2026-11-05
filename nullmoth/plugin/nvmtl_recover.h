/*
 * GPU reset recovery of the Metal plugin's Vulkan backend (nvmtl_vk.c includes this once, after g_state and g_dev).
 * Kept apart so tests/recover_unit.c can run the state machine on the host against a mock Mesa entry point.
 * Needs, from the includer: g_state, g_dev, nvlog, and later definitions of nvmtl_submit_mutex (recursive) and
 * nvmtl_sub_done.
 */
#ifndef NVMTL_RECOVER_H
#define NVMTL_RECOVER_H
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static pthread_mutex_t nvmtl_submit_mutex;
static void nvmtl_sub_done(uint64_t s);
/* GPU reset recovery (nvmtl_vk_recover, after nvmtl_vk_submit_begin_at): the device generation, +1 each time the banned
   exec queue was replaced; a submission remembers the generation it went to the GPU in. While a recovery swaps the
   queue, fence waits hold off (nvmtl_wait_enter): anv asks the kernel about each queue's ban after every wait, and a
   waiter that asked about the old queue just after it was destroyed would mark the device lost again. */
static _Atomic unsigned g_loss_gen;
static _Atomic int g_recovering, g_fence_waiters;
static void nvmtl_wait_enter(void)
{
    for (;;) {
        while (atomic_load(&g_recovering)) usleep(200);
        atomic_fetch_add(&g_fence_waiters, 1);
        if (!atomic_load(&g_recovering)) return;
        atomic_fetch_sub(&g_fence_waiters, 1);
    }
}
static void nvmtl_wait_leave(void) { atomic_fetch_sub(&g_fence_waiters, 1); }

/* GPU reset recovery (Mesa anv_nvmtl_recover.c): a banned exec queue replaced by a fresh one on the same VM */
struct nvmtl_anv_recover_info { uint32_t size, was_lost, queues_banned, queues_replaced; int32_t error; uint32_t failed_step; };
#define NVMTL_ANV_RECOVER_FORCE (1u << 0)
#define NVMTL_ANV_RECOVER_QUERY (1u << 1)
static VkResult (*panv_recover)(VkDevice, uint32_t, struct nvmtl_anv_recover_info *);

/* ---- GPU reset recovery ------------------------------------------------------------------------------------------
   IntelXe.kext follows xe: a hang resets the guilty context, the kernel bans that exec queue and signals every fence it
   handed out; a GT reset bans the queues whose work had started and replays the rest. The VM, every BO and every GPU
   address survive, and Linux userspace goes on with a new exec queue on the same VM. anv reports the ban as
   VK_ERROR_DEVICE_LOST, final for a VkDevice; this plugin used to switch its backend off for the rest of the process
   (g_state -1), after which -[MTLCommandQueue commandBuffer] returned nil and WindowServer died on CoreDisplay's "Failed
   to get a MTLCommandBuffer" assert: a GPU hang logged the user out.
   Now, as on Apple's drivers after a GPU restart: the command buffers that were on the GPU end with an error (the one
   whose wait saw the loss "Caused GPU Hang Error", the others "Discarded (victim of GPU error/recovery)"), their
   completion handlers run, and the device keeps working. Mesa's nvmtl_anv_device_recover_v1 replaces the banned exec
   queue on the same VkDevice (same VM), so every Vulkan handle, GPU address and CPU mapping the plugin and its
   applications hold stays valid; nothing is re-created or re-imported. A new VkDevice is no option: it would be a new
   VM (no dma-buf on macOS), and Metal applications keep gpuAddress values and contents pointers into the old one.
   Bounded: at most NVMTL_RECOVER_MAX recoveries (default 3) in 60 s and 16 per process; past that, or when Mesa has no
   entry point or the replacement fails three times, the backend goes down as before. NVMTL_GPU_RECOVERY=0: as before.
   Tests (never in WindowServer): NVMTL_FAKE_DEVICE_LOST=N[:M] reports the N-th successful fence wait (then every M-th)
   as VK_ERROR_DEVICE_LOST, NVMTL_FAKE_SUBMIT_LOST=N[:M] the N-th vkQueueSubmit (not made); a faked loss replaces the
   queue for real (NVMTL_ANV_RECOVER_FORCE, after the old queue went idle). */
static pthread_mutex_t g_recover_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_recoveries, g_recover_window_n; static uint64_t g_recover_window_t0;
static _Atomic unsigned long long g_lost_hang, g_lost_victim;
static int nvmtl_recover_on(void)
{
    static int on = -1;
    if (on < 0) { const char *e = getenv("NVMTL_GPU_RECOVERY"); on = !(e && e[0] == '0'); }
    return on;
}
static unsigned nvmtl_recover_max(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("NVMTL_RECOVER_MAX"); v = e && *e ? atoi(e) : 3; if (v < 0) v = 0; if (v > 16) v = 16; }
    return (unsigned)v;
}
/* NVMTL_FAKE_DEVICE_LOST / NVMTL_FAKE_SUBMIT_LOST: "N" or "N:M" - fires at the N-th event, then every M-th */
typedef struct { const char *env; int parsed; unsigned long long first, every; _Atomic unsigned long long n; } nvmtl_fake;
static nvmtl_fake g_fake_wait = { "NVMTL_FAKE_DEVICE_LOST" }, g_fake_submit = { "NVMTL_FAKE_SUBMIT_LOST" };
static int nvmtl_fake_fire(nvmtl_fake *k)
{
    if (!k->parsed) {
        const char *e = getenv(k->env); char *end = NULL;
        const char *me = getprogname();
        if (me && !strcmp(me, "WindowServer")) e = NULL;   // never in WindowServer
        if (e && *e) { k->first = strtoull(e, &end, 10); if (end && *end == ':') k->every = strtoull(end + 1, NULL, 10); }
        if (k->first) nvlog("vk: GPU recovery TEST: %s=%s - a VK_ERROR_DEVICE_LOST is faked at event %llu%s", k->env, e,
                            k->first, k->every ? " and periodically after it" : "");
        k->parsed = 1;
    }
    if (!k->first) return 0;
    const unsigned long long i = atomic_fetch_add(&k->n, 1) + 1;
    return i == k->first || (k->every && i > k->first && (i - k->first) % k->every == 0);
}
/* Tests (in-process, staged bundle): fake a loss at the `after`-th next successful fence wait (submit 0) or vkQueueSubmit
   (submit 1). Looked up with dlsym by tests/mtl_recover.m; does nothing in WindowServer. */
void nvmtl_vk_fake_lost_arm(int submit, unsigned long long after)
{
    const char *me = getprogname();
    if (me && !strcmp(me, "WindowServer")) return;
    nvmtl_fake *k = submit ? &g_fake_submit : &g_fake_wait;
    k->parsed = 1; k->every = 0; atomic_store(&k->n, 0); k->first = after;
    nvlog("vk: GPU recovery TEST: a VK_ERROR_DEVICE_LOST is faked at the %llu-th next %s", after, submit ? "vkQueueSubmit" : "successful fence wait");
}
/* The device was seen lost (or a fence gave up) by a submission of generation `gen`. Returns 2 when this call replaced
   the queue, 1 when it is usable without that (another thread recovered it, or nothing was lost), 0 when it is not: the
   backend is then down (g_state -1), as before recovery existed. Takes nvmtl_submit_mutex (recursive: a submitter may
   hold it) so no submission runs while the queue is swapped, then drains the fence waiters (2 s at most). */
static int nvmtl_vk_recover(unsigned gen, int injected, const char *where, VkResult why)
{
    if (!nvmtl_recover_on() || !panv_recover) {
        static int said; if (!said++) nvlog("vk: GPU recovery unavailable (%s) - a lost device disables the backend", !panv_recover
            ? "the Vulkan driver has no nvmtl_anv_device_recover_v1" : "NVMTL_GPU_RECOVERY=0");
        return 0;
    }
    int ok = 0;
    pthread_mutex_lock(&nvmtl_submit_mutex);
    pthread_mutex_lock(&g_recover_lock);
    if (atomic_load(&g_loss_gen) != gen) { ok = g_state == 1; goto out; }   // recovered since that submission
    if (g_state != 1) goto out;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!g_recover_window_t0 || now - g_recover_window_t0 > 60000000000ull) { g_recover_window_t0 = now; g_recover_window_n = 0; }
    if (g_recover_window_n >= nvmtl_recover_max() || g_recoveries >= 16) {
        nvlog("vk: GPU RECOVERY REFUSED in %s: %u recoveries in the last %llu s, %u in all (limit %u per minute, 16 in all) - "
              "disabling backend (%s -> %d)", getprogname(), g_recover_window_n, (unsigned long long)((now - g_recover_window_t0) / 1000000000ull),
              g_recoveries, nvmtl_recover_max(), where, why);
        g_state = -1; goto out;
    }
    atomic_store(&g_recovering, 1);
    const uint64_t d0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    while (atomic_load(&g_fence_waiters) > 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - d0 < 2000000000ull) usleep(500);
    const int still = atomic_load(&g_fence_waiters);
    struct nvmtl_anv_recover_info info; VkResult r = VK_ERROR_UNKNOWN; int attempt = 0;
    for (; attempt < 3; attempt++) {
        memset(&info, 0, sizeof info); info.size = sizeof info;
        r = panv_recover(g_dev, injected ? NVMTL_ANV_RECOVER_FORCE : 0, &info);
        if (r == VK_SUCCESS) break;
        usleep(100000);
    }
    const uint64_t d1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (r == VK_SUCCESS && (info.queues_replaced || info.was_lost)) {
        g_recoveries++; g_recover_window_n++;
        atomic_fetch_add(&g_loss_gen, 1);
        ok = 2;
        nvlog("vk: GPU RECOVERY #%u in %s after %s -> %d%s: device was %s, %u exec queue(s) banned, %u queue(s) replaced on the same VM "
              "in %.1f ms (%d attempt(s), %d fence waiter(s) still in the driver); in-flight command buffers end with an error, new ones run",
              g_recoveries, getprogname(), where, why, injected ? " (FAKED by NVMTL_FAKE_*)" : "", info.was_lost ? "lost" : "not lost",
              info.queues_banned, info.queues_replaced, (d1 - d0) / 1e6, attempt + 1, still);
    } else if (r == VK_SUCCESS) {
        ok = 1;   // nothing lost and nothing banned (a fence that gave up): the command buffer fails, the device goes on
        nvlog("vk: GPU recovery check in %s after %s -> %d: device not lost, no queue banned - only that command buffer fails", getprogname(), where, why);
    } else {
        g_state = -1;
        nvlog("vk: GPU RECOVERY FAILED in %s after %s -> %d: nvmtl_anv_device_recover_v1 -> %d (step %u, errno %d, %u banned) %d times - "
              "disabling backend", getprogname(), where, why, r, info.failed_step, info.error, info.queues_banned, attempt);
    }
    atomic_store(&g_recovering, 0);
out:
    pthread_mutex_unlock(&g_recover_lock);
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    return ok;
}
/* What a lost submission reports: -3 its wait saw the loss and recovered the device (Metal: GPU hang error), -4 it was
   in flight when another submission's loss was recovered (innocent victim), -5 its fence gave up while the device
   reports neither a loss nor a ban (Metal: GPU timeout error; the job may still run), -2 the backend is down. A lost
   submission is over for the GPU (banned: dropped by the kernel; faked: waited for), so its number is marked done and
   the descriptor and buffer reuse watermark moves on; a timed-out one is not. Resources stay quarantined by the caller. */
static int nvmtl_vk_lost(uint64_t subseq, unsigned gen, int injected, const char *where, VkResult why)
{
    const int timed_out = why == VK_TIMEOUT;
    const int rec = atomic_load(&g_loss_gen) != gen ? (g_state == 1 ? 1 : 0) : nvmtl_vk_recover(gen, injected, where, why);
    if (!rec) return -2;
    if (timed_out && rec == 1 && atomic_load(&g_loss_gen) == gen) return -5;
    nvmtl_sub_done(subseq);
    if (rec == 2) { atomic_fetch_add(&g_lost_hang, 1); return -3; }
    const unsigned long long n = atomic_fetch_add(&g_lost_victim, 1) + 1;
    if (n <= 8 || !(n & (n - 1))) nvlog("vk: a command buffer in flight across a GPU recovery ends with an error (%s -> %d; %llu so far)", where, why, n);
    return -4;
}
int nvmtl_vk_recover_counts(unsigned *recoveries, unsigned *gen, unsigned long long *hang, unsigned long long *victim)
{
    if (recoveries) *recoveries = g_recoveries;
    if (gen) *gen = atomic_load(&g_loss_gen);
    if (hang) *hang = atomic_load(&g_lost_hang);
    if (victim) *victim = atomic_load(&g_lost_victim);
    return g_state == 1 ? 0 : -1;
}
#endif
