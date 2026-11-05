/* glub1 NVMTL_GL_UBO: constant-offset reads of a read-only buffer whose address table-pc already pushes become ANV
 * push data (registers) instead of one A64 SEND per read.
 *
 * Apple's OpenGL hands a shader its default-block uniforms with setVertexBytes/setFragmentBytes (Metal buffer 0,
 * vs_uniform_buffer / fs_uniform_buffer, address space constant); Metal apps pass their constant arguments the same way
 * or with setVertexBuffer. After address lowering and table-pc the shader reads such a buffer as
 *     %v = OpLoad (PushConstant qword k)  ->  %B = OpConvertUToPtr PhysicalStorageBuffer(struct P)  ->
 *     OpAccessChain %B <constants>  ->  OpLoad ... Aligned 4
 * and brw emits a load.ugm A64 SEND for every read. ANV (Mesa MR 39451 "promote push constant pointers to push
 * buffers", present in the prod8 Mesa) already pushes load_global_constant(pointer-from-push-constant + constant) into
 * registers, but only when the load's align_mul is at least 32 (anv_nir_push_constants_analysis.c
 * anv_nir_is_pushable_pointer). An "Aligned 4" load is align_mul 4, so today nothing is pushed.
 *
 * The Alignment decoration that would say "%B is 64-aligned" is Kernel-only SPIR-V. The valid way to state it is a load
 * through %B itself: this pass adds, right after %B,
 *     %Bs  = OpConvertUToPtr PhysicalStorageBuffer(P')  %v      (P' = P with a trailing runtime array sized N)
 *     %blk = OpLoad P' %Bs Aligned 64
 * vtn splits that aggregate load into one load per leaf, each a deref of the 64-aligned cast, i.e. (align_mul 64,
 * align_offset = the leaf's byte offset); unused leaves are dead code. Every load through %B with constant indices
 * becomes OpCompositeExtract from %blk; the translator's two-word re-cast reads (OpConvertPtrToU of a word pointer,
 * OpConvertUToPtr to a 2..4 word vector, OpLoad) become extracts of the consecutive words (+ bitcasts). Values are the
 * same bytes: P is NonWritable (Metal constant / read-only), so reading it once at %B's definition is what reading it
 * at each use returned. Loads the pass cannot reach (dynamic index, phi, escape) stay A64 loads through %B, unchanged.
 *
 * Nothing else changes: no descriptor, layout, binding or push range. Two promises are made per draw and checked by
 * the plugin (nvmtl_gl_ubo_pick): the pushed qword is 64-aligned (ANV_UBO_ALIGNMENT, get_push_range_address) and the
 * buffer holds [offset, offset + extent rounded to 64) (ANV reads whole 64-byte register chunks). When either fails
 * the draw binds the module built without this pass.
 * No Vulkan/ObjC dependency: tools/b580/gl_ubo_check.c runs this exact header offline.
 */
#ifndef NVMTL_GL_UBO_H
#define NVMTL_GL_UBO_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "nvmtl_table_pc.h"

#define NVMTL_GL_UBO_ALIGN  64u    /* ANV_UBO_ALIGNMENT (anv_types.h) */
#define NVMTL_GL_UBO_NBUF   32u    /* table entries [0,32) are buffer addresses (NVMTL_NBUF) */
#define NVMTL_GL_UBO_LEAVES 1024   /* at most this many scalar/vector leaves in one block load (compile time) */
#define NVMTL_GL_UBO_DEPTH  6u     /* access-chain index depth followed */

typedef struct {
    uint32_t mask;                         /* bit k: plan entry k's buffer is read through a 64-aligned block load */
    uint32_t extent[NVMTL_PC_TABLE_MAX];   /* bytes of entry k's block (the largest of its bases), 0 = none */
    uint32_t bases, loads, recasts, words; /* blocks added; plain loads and re-cast loads replaced; words they read */
    uint32_t complete;                     /* every table-pc qword of the stage is such a buffer and nothing else in the
                                              shader reads the qwords: ANV then needs no client push data for the stage
                                              (NVMTL_GL_UBO=2 converts only these) */
} nvmtl_gl_ubo_info;

typedef struct { uint32_t *w; size_t n, cap; int failed; } nvmtl_gu_words;
static void nvmtl_gu_put(nvmtl_gu_words *o, const uint32_t *w, size_t n)
{
    if (o->failed) return;
    if (n > o->cap - o->n) { o->failed = 1; return; }
    memcpy(o->w + o->n, w, n * sizeof *w); o->n += n;
}
#define NVMTL_GU_EMIT(o, ...) do { const uint32_t a_[] = { __VA_ARGS__ }; nvmtl_gu_put((o), a_, sizeof a_ / sizeof *a_); } while (0)

typedef struct {
    const uint32_t *w; size_t nw; uint32_t bound, *def, function_pos;
} nvmtl_gu_mod;
static const uint32_t *nvmtl_gu_def(const nvmtl_gu_mod *m, uint32_t id)
{ return id && id < m->bound && m->def[id] ? m->w + m->def[id] : NULL; }
static uint32_t nvmtl_gu_opc(const uint32_t *i) { return i ? i[0] & 0xffffu : 0; }
static int nvmtl_gu_const32(const nvmtl_gu_mod *m, uint32_t id, uint32_t *type, uint32_t *value)
{
    const uint32_t *i = nvmtl_gu_def(m, id);
    if (nvmtl_gu_opc(i) != 43 || (i[0] >> 16) != 4) return 0;
    const uint32_t *t = nvmtl_gu_def(m, i[1]);
    if (nvmtl_gu_opc(t) != 21 || t[2] != 32) return 0;
    if (type) *type = i[1];
    *value = i[3]; return 1;
}
static int nvmtl_gu_scalar32(const nvmtl_gu_mod *m, uint32_t id)
{
    const uint32_t *t = nvmtl_gu_def(m, id);
    return (nvmtl_gu_opc(t) == 21 && (t[0] >> 16) == 4 && t[2] == 32) || (nvmtl_gu_opc(t) == 22 && (t[0] >> 16) >= 3 && t[2] == 32);
}
/* decoration `d` of type `id` (member `mem` when mem != ~0u); its first literal, or `none` */
static uint32_t nvmtl_gu_deco(const nvmtl_gu_mod *m, uint32_t id, uint32_t mem, uint32_t d, uint32_t none)
{
    for (size_t at = 5; at < m->function_pos;) {
        const uint32_t *i = m->w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (mem == ~0u && op == 71 && wc >= 3 && i[1] == id && i[2] == d) return wc >= 4 ? i[3] : 1;
        if (mem != ~0u && op == 72 && wc >= 4 && i[1] == id && i[2] == mem && i[3] == d) return wc >= 5 ? i[4] : 1;
        at += wc;
    }
    return none;
}
/* Leaves (scalars/vectors/matrix columns of 32-bit components) of a sized type; -1: not all 32-bit or not sized. */
static long nvmtl_gu_leaves(const nvmtl_gu_mod *m, uint32_t ty, unsigned depth)
{
    const uint32_t *t = nvmtl_gu_def(m, ty); uint32_t len;
    if (!t || depth > 8) return -1;
    switch (nvmtl_gu_opc(t)) {
    case 21: case 22: return nvmtl_gu_scalar32(m, ty) ? 1 : -1;
    case 23: return nvmtl_gu_scalar32(m, t[2]) ? 1 : -1;
    case 24: { long c = nvmtl_gu_leaves(m, t[2], depth + 1); return c < 0 ? -1 : c * (long)t[3]; }
    case 28: { if (!nvmtl_gu_const32(m, t[3], NULL, &len) || !nvmtl_gu_deco(m, ty, ~0u, 6, 0)) return -1;
               long c = nvmtl_gu_leaves(m, t[2], depth + 1);
               return c < 0 || (long)len * c > 1L << 20 ? -1 : c * (long)len; }
    case 30: { long s = 0;
               for (uint32_t k = 2; k < (t[0] >> 16); k++) {
                   if (nvmtl_gu_deco(m, ty, k - 2, 21, 0) || nvmtl_gu_deco(m, ty, k - 2, 23, 0)) return -1;   /* Volatile, Coherent */
                   long c = nvmtl_gu_leaves(m, t[k], depth + 1); if (c < 0) return -1; s += c; }
               return s; }
    default: return -1;
    }
}
/* Byte size of a sized type at a struct member whose MatrixStride is `ms`; 0: unknown. */
static uint32_t nvmtl_gu_size(const nvmtl_gu_mod *m, uint32_t ty, uint32_t ms, unsigned depth)
{
    const uint32_t *t = nvmtl_gu_def(m, ty); uint32_t len;
    if (!t || depth > 8) return 0;
    switch (nvmtl_gu_opc(t)) {
    case 21: case 22: return 4;
    case 23: return 4 * t[3];
    case 24: return ms ? ms * t[3] : 0;
    case 28: { uint32_t st = nvmtl_gu_deco(m, ty, ~0u, 6, 0);
               if (!nvmtl_gu_const32(m, t[3], NULL, &len) || !st || !len) return 0;
               uint32_t e = nvmtl_gu_size(m, t[2], ms, depth + 1); return e ? st * (len - 1) + e : 0; }
    case 30: { uint32_t end = 0;
               for (uint32_t k = 2; k < (t[0] >> 16); k++) {
                   uint32_t off = nvmtl_gu_deco(m, ty, k - 2, 35, ~0u), s = nvmtl_gu_size(m, t[k], nvmtl_gu_deco(m, ty, k - 2, 7, 0), depth + 1);
                   if (off == ~0u || !s) return 0;
                   if (off + s > end) end = off + s;
               }
               return end; }
    default: return 0;
    }
}

/* One base: %B = OpConvertUToPtr from a pushed buffer qword. */
typedef struct {
    uint32_t id, u64, def_at, k;          /* %B, the qword it converts, where it is defined, plan entry */
    uint32_t pointee, rt, rt_elem, rt_stride, nmem;   /* P; P's trailing runtime array member (rt=1), its element and stride */
    uint32_t n;                           /* elements of the runtime array the replaced loads need (max index + 1) */
    uint32_t cap;                         /* most elements allowed by NVMTL_GL_UBO_LEAVES */
    uint32_t blk, ptr_t, struct_t, arr_t, len_c, bs;   /* new ids */
    int ok;
} nvmtl_gu_base;
/* One replaced load. */
typedef struct {
    uint32_t at, res, type, base;         /* the OpLoad, its result and type, the nvmtl_gu_base index */
    uint32_t np, path[NVMTL_GL_UBO_DEPTH];/* literal indices into P */
    uint32_t words, comp;                 /* re-cast: consecutive words read from path's last index, component type */
} nvmtl_gu_load;

/* Walk `np` constant indices from type `ty`. Returns the reached type (0: invalid). *rt gets the runtime-array index when
 * the walk passes P's trailing runtime array (only at depth 0 of a struct whose last member it is), else ~0u. */
static uint32_t nvmtl_gu_walk(const nvmtl_gu_mod *m, uint32_t ty, const uint32_t *idx, uint32_t np, uint32_t *rt)
{
    *rt = ~0u;
    for (uint32_t d = 0; d < np; d++) {
        const uint32_t *t = nvmtl_gu_def(m, ty), op = nvmtl_gu_opc(t); uint32_t len;
        if (!t) return 0;
        if (op == 30) { if (idx[d] >= (t[0] >> 16) - 2) return 0; ty = t[2 + idx[d]]; }
        else if (op == 28) { if (!nvmtl_gu_const32(m, t[3], NULL, &len) || idx[d] >= len) return 0; ty = t[2]; }
        else if (op == 29) { if (d != 1) return 0; *rt = idx[d]; ty = t[2]; }
        else if (op == 23 || op == 24) { if (idx[d] >= t[3]) return 0; ty = t[2]; }
        else return 0;
    }
    return ty;
}

/* Returns an owned module, or NULL when nothing changed (the caller keeps its module). `pc_base` is the byte offset of
 * the stage's table-pc qwords (NVMTL_PC_TABLE_VS_OFFSET / _FS_OFFSET), `plan` what table-pc published. */
static uint32_t *nvmtl_spirv_gl_ubo(const void *bytes, size_t nbytes, uint32_t pc_base, const nvmtl_pc_table *plan,
                                    nvmtl_gl_ubo_info *info, size_t *out_bytes)
{
    nvmtl_gl_ubo_info got; memset(&got, 0, sizeof got);
    if (info) *info = got;
    const uint32_t *w = bytes; const size_t nw = nbytes / 4;
    if (!w || !plan || !plan->count || nbytes % 4 || nw < 5 || w[0] != 0x07230203u) return NULL;
    const uint32_t bound = w[3];
    if (!bound || bound > (1u << 18) || nw > (1u << 22)) return NULL;
    nvmtl_gu_mod m = { w, nw, bound, calloc(bound, sizeof(uint32_t)), 0 };
    uint8_t *entry = calloc(bound, 1), *value = calloc(bound, 1), *qbad = calloc(bound, 1);
    uint16_t *bix = calloc(bound, sizeof *bix);                     /* id -> base index + 1 (bases and path pointers) */
    uint8_t *plen = calloc(bound, 1);                                /* path pointer: depth + 1 */
    uint32_t *path = calloc((size_t)bound * NVMTL_GL_UBO_DEPTH, sizeof *path);
    uint32_t *recast = calloc(bound, sizeof *recast), *qsrc = calloc(bound, sizeof *qsrc);
    uint32_t *member_off = NULL;
    nvmtl_gu_base *bases = NULL; uint32_t nb = 0;
    nvmtl_gu_load *loads = NULL; uint32_t nl = 0, capl = 0;
    uint32_t *result = NULL; nvmtl_gu_words out = {0};
    uint32_t type_pos = 0, push_var = 0, push_block = 0, push_members = 0, u32 = 0;
    if (!m.def || !entry || !value || !qbad || !bix || !plen || !path || !recast || !qsrc) goto done;
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (!wc || at + wc > nw) goto done;
        if (op == 54 && !m.function_pos) m.function_pos = (uint32_t)at;
        if (op >= 19 && op <= 39 && wc >= 2) {
            if (i[1] >= bound) goto done;
            if (!type_pos) type_pos = (uint32_t)at;
            m.def[i[1]] = (uint32_t)at;
            if (op == 21 && wc == 4 && i[2] == 32 && !i[3] && !u32) u32 = i[1];
        } else if ((op == 41 || op == 42 || op == 43 || op == 44 || op == 46 || op == 50 || op == 59 || op == 61 || op == 65
                    || op == 66 || op == 83 || op == 117 || op == 120 || op == 124) && wc >= 3) {
            if (i[2] >= bound) goto done;
            m.def[i[2]] = (uint32_t)at;
            if (op == 59 && wc >= 4 && i[3] == 9) { if (push_var) goto done; push_var = i[2]; }
        }
        at += wc;
    }
    if (!push_var || !type_pos || !m.function_pos || !u32) goto done;
    {
        const uint32_t *v = nvmtl_gu_def(&m, push_var), *pt = v ? nvmtl_gu_def(&m, v[1]) : NULL;
        if (nvmtl_gu_opc(pt) != 32) goto done;
        push_block = pt[3];
        const uint32_t *pb = nvmtl_gu_def(&m, push_block);
        if (nvmtl_gu_opc(pb) != 30 || (pb[0] >> 16) < 3) goto done;
        push_members = (pb[0] >> 16) - 2;
        member_off = malloc(push_members * sizeof *member_off);
        if (!member_off) goto done;
        for (uint32_t k = 0; k < push_members; k++) member_off[k] = nvmtl_gu_deco(&m, push_block, k, 35, ~0u);
    }
    /* Pass 1, in module order (a definition precedes its uses in the blocks that matter; anything else is simply not
     * recognized): push member chain -> qword load (u64 or 2 x u32) -> optional bitcast/copy -> OpConvertUToPtr = base;
     * constant access chains from a base = path pointers; OpConvertPtrToU of a path pointer -> OpConvertUToPtr to a
     * 32-bit scalar or a 2..4 vector of them = re-cast pointer. */
    for (size_t at = m.function_pos; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if ((op == 65 || op == 66) && wc == 5 && i[3] == push_var && i[2] < bound) {
            uint32_t mem;
            if (nvmtl_gu_const32(&m, i[4], NULL, &mem) && mem < push_members && member_off[mem] != ~0u
                && member_off[mem] >= pc_base && !((member_off[mem] - pc_base) & 7u)) {
                const uint32_t k = (member_off[mem] - pc_base) / 8;
                if (k < plan->count && plan->index[k] < NVMTL_GL_UBO_NBUF) entry[i[2]] = (uint8_t)(k + 1);
            }
        } else if (op == 61 && wc >= 4 && i[3] < bound && entry[i[3]] && i[2] < bound) {
            const uint32_t *t = nvmtl_gu_def(&m, i[1]);
            const int u64 = nvmtl_gu_opc(t) == 21 && t[2] == 64;
            const int v2 = nvmtl_gu_opc(t) == 23 && t[3] == 2 && nvmtl_gu_opc(nvmtl_gu_def(&m, t[2])) == 21 && nvmtl_gu_def(&m, t[2])[2] == 32;
            if (u64 || v2) value[i[2]] = entry[i[3]];
        } else if ((op == 124 || op == 83) && wc == 4 && i[3] < bound && value[i[3]] && i[2] < bound) {
            const uint32_t *t = nvmtl_gu_def(&m, i[1]);
            if (nvmtl_gu_opc(t) == 21 && t[2] == 64) value[i[2]] = value[i[3]];
        } else if (op == 120 && wc == 4 && i[3] < bound && value[i[3]] && i[2] < bound && nb < 64) {
            const uint32_t *pt = nvmtl_gu_def(&m, i[1]);
            const uint32_t *st = pt && nvmtl_gu_opc(pt) == 32 && pt[2] == 5349 ? nvmtl_gu_def(&m, pt[3]) : NULL;
            if (nvmtl_gu_opc(st) == 30 && (st[0] >> 16) >= 3) {
                nvmtl_gu_base b; memset(&b, 0, sizeof b);
                b.id = i[2]; b.u64 = i[3]; b.def_at = (uint32_t)at; b.k = value[i[3]] - 1u; b.pointee = pt[3];
                b.nmem = (st[0] >> 16) - 2; b.ok = 1;
                const uint32_t last = st[2 + b.nmem - 1], *lt = nvmtl_gu_def(&m, last);
                long leaves = 0;
                for (uint32_t k = 0; k < b.nmem && b.ok; k++) {
                    /* read-only: every member NonWritable (the translator's Metal constant / read-only metadata) */
                    if (!nvmtl_gu_deco(&m, b.pointee, k, 24, 0) || nvmtl_gu_deco(&m, b.pointee, k, 35, ~0u) == ~0u) b.ok = 0;
                    /* Volatile / Coherent members: another agent may write them during the draw, one read at %B is not the same */
                    if (nvmtl_gu_deco(&m, b.pointee, k, 21, 0) || nvmtl_gu_deco(&m, b.pointee, k, 23, 0)) b.ok = 0;
                    if (k + 1 == b.nmem && nvmtl_gu_opc(lt) == 29) continue;
                    long c = nvmtl_gu_leaves(&m, st[2 + k], 0); if (c < 0) b.ok = 0; else leaves += c;
                }
                if (b.ok && nvmtl_gu_opc(lt) == 29) {
                    long c = nvmtl_gu_leaves(&m, lt[2], 0);
                    b.rt = 1; b.rt_elem = lt[2]; b.rt_stride = nvmtl_gu_deco(&m, last, ~0u, 6, 0);
                    if (c <= 0 || !b.rt_stride || !nvmtl_gu_size(&m, lt[2], nvmtl_gu_deco(&m, b.pointee, b.nmem - 1, 7, 0), 0)) b.ok = 0;
                    else b.cap = leaves >= NVMTL_GL_UBO_LEAVES ? 0 : (uint32_t)((NVMTL_GL_UBO_LEAVES - leaves) / c);
                    if (!b.cap) b.ok = 0;
                } else if (b.ok && (leaves > NVMTL_GL_UBO_LEAVES || !nvmtl_gu_size(&m, b.pointee, 0, 0))) b.ok = 0;
                if (b.ok) {
                    bases = realloc(bases, (nb + 1) * sizeof *bases);
                    if (!bases) goto done;
                    bases[nb++] = b; bix[b.id] = (uint16_t)nb; plen[b.id] = 1;
                }
            }
        }
        if ((op == 65 || op == 66) && wc >= 5 && i[3] < bound && bix[i[3]] && i[2] < bound && i[3] != push_var) {
            const uint32_t src = i[3], d0 = plen[src] - 1u, nidx = wc - 4;
            int ok = d0 + nidx <= NVMTL_GL_UBO_DEPTH;
            for (uint32_t k = 0; ok && k < nidx; k++) {
                uint32_t v; if (!nvmtl_gu_const32(&m, i[4 + k], NULL, &v)) ok = 0;
                else path[(size_t)i[2] * NVMTL_GL_UBO_DEPTH + d0 + k] = v;
            }
            if (ok) {
                memcpy(path + (size_t)i[2] * NVMTL_GL_UBO_DEPTH, path + (size_t)src * NVMTL_GL_UBO_DEPTH, d0 * sizeof *path);
                bix[i[2]] = bix[src]; plen[i[2]] = (uint8_t)(d0 + nidx + 1);
            }
        } else if (op == 117 && wc == 4 && i[3] < bound && bix[i[3]] && plen[i[3]] > 1 && i[2] < bound) {
            recast[i[2]] = i[3];
        } else if (op == 120 && wc == 4 && i[3] < bound && recast[i[3]] && i[2] < bound) {
            const uint32_t *pt = nvmtl_gu_def(&m, i[1]);
            if (nvmtl_gu_opc(pt) == 32 && pt[2] == 5349) {
                const uint32_t *vt = nvmtl_gu_def(&m, pt[3]);
                if (nvmtl_gu_scalar32(&m, pt[3]) || (nvmtl_gu_opc(vt) == 23 && vt[3] >= 2 && vt[3] <= 4 && nvmtl_gu_scalar32(&m, vt[2])))
                    qsrc[i[2]] = recast[i[3]];
            }
        }
        at += wc;
    }
    if (!nb) goto done;
    /* A re-cast pointer counts only if every use is an OpLoad of it with no memory operand or only Aligned. */
    for (size_t at = m.function_pos; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        for (uint32_t k = 1; k < wc; k++) {
            const uint32_t id = i[k];
            if (id >= bound || !qsrc[id] || qbad[id]) continue;
            if (op == 120 && k == 2) continue;
            if (op == 61 && k == 3 && (wc == 4 || (wc == 6 && i[4] == 2u))) continue;
            qbad[id] = 1;
        }
        at += wc;
    }
    /* Pass 2: the loads to replace. */
    for (size_t at = m.function_pos; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (op == 61 && (wc == 4 || (wc == 6 && i[4] == 2u)) && i[3] < bound && i[2] < bound) {
            nvmtl_gu_load l; memset(&l, 0, sizeof l);
            uint32_t ptr = i[3], rtix = ~0u, reached = 0;
            if (bix[ptr] && plen[ptr] > 1 && !qsrc[ptr]) {                         /* a plain load through a path pointer */
                l.base = bix[ptr] - 1u; l.np = plen[ptr] - 1u;
                memcpy(l.path, path + (size_t)ptr * NVMTL_GL_UBO_DEPTH, l.np * sizeof *l.path);
                reached = nvmtl_gu_walk(&m, bases[l.base].pointee, l.path, l.np, &rtix);
                if (reached != i[1]) reached = 0;
            } else if (qsrc[ptr] && !qbad[ptr]) {                                  /* a re-cast word read */
                const uint32_t wp = qsrc[ptr];
                l.base = bix[wp] - 1u; l.np = plen[wp] - 1u;
                memcpy(l.path, path + (size_t)wp * NVMTL_GL_UBO_DEPTH, l.np * sizeof *l.path);
                const uint32_t word = nvmtl_gu_walk(&m, bases[l.base].pointee, l.path, l.np, &rtix);
                /* the word's container: an array of 32-bit words with stride 4 */
                uint32_t crt = ~0u, cont = l.np ? nvmtl_gu_walk(&m, bases[l.base].pointee, l.path, l.np - 1, &crt) : 0;
                const uint32_t *ct = nvmtl_gu_def(&m, cont), *vt = nvmtl_gu_def(&m, i[1]);
                l.words = nvmtl_gu_opc(vt) == 23 ? vt[3] : 1; l.comp = nvmtl_gu_opc(vt) == 23 ? vt[2] : i[1];
                uint32_t len = ~0u;
                if (nvmtl_gu_opc(ct) == 28 && !nvmtl_gu_const32(&m, ct[3], NULL, &len)) len = 0;
                const int stride4 = (nvmtl_gu_opc(ct) == 28 || nvmtl_gu_opc(ct) == 29) && nvmtl_gu_deco(&m, cont, ~0u, 6, 0) == 4;
                const uint32_t last = l.np ? l.path[l.np - 1] : 0;
                if (word && nvmtl_gu_scalar32(&m, word) && stride4 && last + l.words <= len && last + l.words > last) {
                    reached = i[1];
                    if (rtix != ~0u) rtix = last + l.words - 1;
                } else reached = 0;
            }
            if (reached) {
                nvmtl_gu_base *b = &bases[l.base];
                if (rtix != ~0u && (!b->rt || rtix >= b->cap)) reached = 0;
                if (reached && rtix != ~0u && rtix + 1 > b->n) b->n = rtix + 1;
            }
            if (reached) {
                l.at = (uint32_t)at; l.res = i[2]; l.type = i[1];
                if (nl == capl) { capl = capl ? capl * 2 : 64; nvmtl_gu_load *g = realloc(loads, capl * sizeof *g); if (!g) goto done; loads = g; }
                loads[nl++] = l;
            }
        }
        at += wc;
    }
    /* Bases with nothing to replace are left alone; the others get ids and an extent. */
    uint32_t next = bound;
    for (uint32_t b = 0; b < nb; b++) bases[b].ok = 0;
    for (uint32_t l = 0; l < nl; l++) bases[loads[l].base].ok = 1;
    for (uint32_t b = 0; b < nb; b++) {
        nvmtl_gu_base *B = &bases[b];
        if (!B->ok) continue;
        if (B->rt && !B->n) B->n = 1;
        B->blk = next++;
        if (B->rt) { B->len_c = next++; B->arr_t = next++; B->struct_t = next++; B->ptr_t = next++; B->bs = next++; }
        uint32_t size;
        if (B->rt) {
            const uint32_t es = nvmtl_gu_size(&m, B->rt_elem, nvmtl_gu_deco(&m, B->pointee, B->nmem - 1, 7, 0), 0);
            const uint32_t off = nvmtl_gu_deco(&m, B->pointee, B->nmem - 1, 35, 0);
            uint32_t head = 0;
            for (uint32_t k = 0; k + 1 < B->nmem; k++) {
                const uint32_t *st = nvmtl_gu_def(&m, B->pointee);
                uint32_t o = nvmtl_gu_deco(&m, B->pointee, k, 35, 0), s = nvmtl_gu_size(&m, st[2 + k], nvmtl_gu_deco(&m, B->pointee, k, 7, 0), 0);
                if (o + s > head) head = o + s;
            }
            size = off + B->rt_stride * (B->n - 1) + es; if (head > size) size = head;
        } else size = nvmtl_gu_size(&m, B->pointee, 0, 0);
        if (size > got.extent[B->k]) got.extent[B->k] = size;
        got.mask |= 1u << B->k; got.bases++;
    }
    for (uint32_t l = 0; l < nl; l++) { if (loads[l].words) { got.recasts++; got.words += loads[l].words; } else got.loads++; }
    if (!got.bases) goto done;
    /* complete: every plan entry converted, and every value derived from the pushed qwords (any base, ok or not) ends in a
     * replaced load or in nothing. Derivation follows every instruction except the data an OpLoad reads. */
    got.complete = got.mask == (plan->count >= 32 ? ~0u : (1u << plan->count) - 1u);
    if (got.complete) {
        uint8_t *taint = calloc(bound, 1), *repl = calloc(bound, 1);
        if (!taint || !repl) { free(taint); free(repl); got.complete = 0; }
        else {
            for (uint32_t id = 1; id < bound; id++) if (value[id] || entry[id]) taint[id] = 1;
            for (uint32_t l = 0; l < nl; l++) repl[loads[l].res] = 1;
            for (int round = 0; round < 2; round++)
                for (size_t at = m.function_pos; at < nw;) {
                    const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
                    if (wc >= 3 && i[2] < bound && m.def[i[2]] == at && !taint[i[2]]) {
                        int from = 0;
                        if (op == 61) from = i[3] < bound && taint[i[3]] && nvmtl_gu_opc(nvmtl_gu_def(&m, i[1])) == 32;
                        else for (uint32_t k = 3; k < wc && !from; k++) from = i[k] < bound && taint[i[k]];
                        if (from) taint[i[2]] = 1;
                    } else if (wc >= 3 && op != 61 && op != 62 && !(i[2] < bound && m.def[i[2]] == at)) {
                        /* instructions this walk has no def for (phi, select, arithmetic...): taint their result too */
                        for (uint32_t k = 3; k < wc; k++) if (i[k] < bound && taint[i[k]] && i[2] < bound) { taint[i[2]] = 1; break; }
                    }
                    at += wc;
                }
            for (size_t at = m.function_pos; at < nw && got.complete;) {
                const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
                const int has_result = op == 65 || op == 66 || op == 67 || op == 117 || op == 120 || op == 124 || op == 83 || op == 61;
                for (uint32_t k = has_result ? 3 : 1; k < wc; k++) {
                    if (i[k] >= bound || !taint[i[k]]) continue;
                    if (op == 65 || op == 66 || op == 67 || op == 117 || op == 120 || op == 124 || op == 83) continue;
                    if (op == 61 && k == 3 && (repl[i[2]] || entry[i[3]])) continue;   /* a replaced read; the qword load */
                    if (op == 5 || op == 6 || op == 71 || op == 72) continue;
                    got.complete = 0; break;
                }
                at += wc;
            }
            free(taint); free(repl);
        }
    }
    /* the extract sequence of a re-cast needs per-word and per-bitcast ids */
    out.cap = 2 * nw + 4096 + (size_t)got.bases * 256 + (size_t)nl * (8 + NVMTL_GL_UBO_DEPTH) + (size_t)got.words * (12 + NVMTL_GL_UBO_DEPTH);
    out.w = malloc(out.cap * 4);
    if (!out.w) goto done;
    nvmtl_gu_put(&out, w, 5);
    uint32_t li = 0;
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16;
        if (at == type_pos)     /* annotations of the new sized types: P's member decorations, the array's stride */
            for (uint32_t b = 0; b < nb; b++) {
                const nvmtl_gu_base *B = &bases[b];
                if (!B->ok || !B->rt) continue;
                NVMTL_GU_EMIT(&out, (4u << 16) | 71u, B->arr_t, 6u, B->rt_stride);
                for (size_t a2 = 5; a2 < m.function_pos;) {
                    const uint32_t *d = w + a2, dc = d[0] >> 16;
                    if ((d[0] & 0xffffu) == 72 && dc >= 4 && d[1] == B->pointee) {
                        out.failed |= dc > 16;
                        if (!out.failed) { uint32_t c[16]; memcpy(c, d, dc * 4); c[1] = B->struct_t; nvmtl_gu_put(&out, c, dc); }
                    }
                    a2 += dc;
                }
            }
        if (at == m.function_pos)
            for (uint32_t b = 0; b < nb; b++) {
                const nvmtl_gu_base *B = &bases[b];
                if (!B->ok || !B->rt) continue;
                const uint32_t *st = nvmtl_gu_def(&m, B->pointee);
                NVMTL_GU_EMIT(&out, (4u << 16) | 43u, u32, B->len_c, B->n);
                NVMTL_GU_EMIT(&out, (4u << 16) | 28u, B->arr_t, B->rt_elem, B->len_c);
                NVMTL_GU_EMIT(&out, ((2u + B->nmem) << 16) | 30u, B->struct_t);
                nvmtl_gu_put(&out, st + 2, B->nmem - 1); nvmtl_gu_put(&out, &B->arr_t, 1);
                NVMTL_GU_EMIT(&out, (4u << 16) | 32u, B->ptr_t, 5349u, B->struct_t);
            }
        if (li < nl && loads[li].at == at) {
            const nvmtl_gu_load *l = &loads[li++];
            const nvmtl_gu_base *B = &bases[l->base];
            if (!l->words) {
                NVMTL_GU_EMIT(&out, ((4u + l->np) << 16) | 81u, l->type, l->res, B->blk);
                nvmtl_gu_put(&out, l->path, l->np);
            } else {
                uint32_t parts[4]; const uint32_t first = l->path[l->np - 1];
                uint32_t word_t = nvmtl_gu_walk(&m, B->pointee, l->path, l->np, &(uint32_t){0});
                for (uint32_t j = 0; j < l->words; j++) {
                    uint32_t p2[NVMTL_GL_UBO_DEPTH]; memcpy(p2, l->path, l->np * sizeof *p2); p2[l->np - 1] = first + j;
                    const uint32_t v = next++;
                    NVMTL_GU_EMIT(&out, ((4u + l->np) << 16) | 81u, word_t, v, B->blk);
                    nvmtl_gu_put(&out, p2, l->np);
                    if (word_t != l->comp) { const uint32_t c = next++; NVMTL_GU_EMIT(&out, (4u << 16) | 124u, l->comp, c, v); parts[j] = c; }
                    else parts[j] = v;
                }
                if (l->words > 1) { NVMTL_GU_EMIT(&out, ((3u + l->words) << 16) | 80u, l->type, l->res); nvmtl_gu_put(&out, parts, l->words); }
                else NVMTL_GU_EMIT(&out, (4u << 16) | 83u, l->type, l->res, parts[0]);
            }
            at += wc; continue;
        }
        nvmtl_gu_put(&out, i, wc);
        for (uint32_t b = 0; b < nb; b++) {     /* right after %B: the one 64-aligned read of its block */
            const nvmtl_gu_base *B = &bases[b];
            if (!B->ok || B->def_at != at) continue;
            if (B->rt) {
                NVMTL_GU_EMIT(&out, (4u << 16) | 120u, B->ptr_t, B->bs, B->u64);
                NVMTL_GU_EMIT(&out, (6u << 16) | 61u, B->struct_t, B->blk, B->bs, 2u, NVMTL_GL_UBO_ALIGN);
            } else NVMTL_GU_EMIT(&out, (6u << 16) | 61u, B->pointee, B->blk, B->id, 2u, NVMTL_GL_UBO_ALIGN);
        }
        at += wc;
    }
    if (out.failed) goto done;
    out.w[3] = next;
    result = out.w; out.w = NULL;
    *out_bytes = out.n * 4;
    if (info) *info = got;
done:
    free(out.w); free(m.def); free(entry); free(value); free(qbad); free(bix); free(plen); free(path); free(recast); free(qsrc);
    free(member_off); free(bases); free(loads);
    return result;
}
#undef NVMTL_GU_EMIT
#endif
