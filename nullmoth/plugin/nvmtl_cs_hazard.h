/* compute2: what a compute module needs from the barrier before its dispatch. Pure C (offline-checkable: tools/b580/cs_offline.m).
 *
 * nvmtl_cs_access(): the Vulkan access types the kernel can read GPU-written memory through, for the narrow serial
 * barrier (NVMTL_CS_BAR). Storage buffers (physical/BDA and descriptor), storage images and texel buffers are read and
 * written through the dataport: VK_ACCESS_2_SHADER_STORAGE_READ/WRITE. A sampled image or uniform texel buffer goes
 * through the sampler: + SHADER_SAMPLED_READ. A Uniform block other than the address table (binding 640, written by the
 * CPU before the submit) would be read through the constant cache: + UNIFORM_READ.
 *
 * nvmtl_cs_reach(): NVMTL_CS_HAZARD (opt-in). 1 when every memory address the kernel can touch is derived from the
 * address-table qwords it received as push constants (compute table-pc applied): no descriptor-bound buffer, image,
 * sampler or acceleration structure; every OpConvertUToPtr takes a value whose provenance is a table qword (P) plus
 * integer arithmetic; no pointer or address is loaded from memory, passed as a function parameter or merged with a
 * non-P value. Then the buffers a dispatch can reach are exactly the bound buffers of its table entries (Metal makes an
 * access outside the bound buffer undefined), and two serial dispatches whose reachable buffers do not overlap (or only
 * share buffers both read) need no barrier. *wr = 1 when the kernel stores or performs an atomic on physical memory.
 * Any doubt answers 0: the barrier stays.
 */
#ifndef NVMTL_CS_HAZARD_H
#define NVMTL_CS_HAZARD_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define NVMTL_CS_ACC_SAMPLED 1u
#define NVMTL_CS_ACC_UNIFORM 2u
static uint32_t nvmtl_cs_access(const void *bytes, size_t nbytes)
{
    const uint32_t *w = bytes; const size_t nw = nbytes / 4;
    if (!w || nw < 5 || w[0] != 0x07230203u) return NVMTL_CS_ACC_SAMPLED | NVMTL_CS_ACC_UNIFORM;
    const uint32_t bound = w[3];
    if (!bound || bound > (1u << 22)) return NVMTL_CS_ACC_SAMPLED | NVMTL_CS_ACC_UNIFORM;
    uint32_t r = 0, table = 0;
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (!wc || at + wc > nw) return NVMTL_CS_ACC_SAMPLED | NVMTL_CS_ACC_UNIFORM;
        if (op == 71 && wc == 4 && i[2] == 33 && i[3] == 640) table = i[1];
        if (op == 25 && wc >= 9 && i[7] != 2) r |= NVMTL_CS_ACC_SAMPLED;   /* OpTypeImage, Sampled 0 (unknown) or 1 */
        if (op == 27) r |= NVMTL_CS_ACC_SAMPLED;                          /* OpTypeSampledImage */
        at += wc;
    }
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (op == 59 && wc >= 4 && i[3] == 2 && i[2] != table) r |= NVMTL_CS_ACC_UNIFORM;
        at += wc;
    }
    return r;
}

static int nvmtl_cs_reach(const void *bytes, size_t nbytes, int *wr)
{
    const uint32_t *w = bytes; const size_t nw = nbytes / 4;
    *wr = 1;
    if (!w || nw < 5 || w[0] != 0x07230203u) return 0;
    const uint32_t bound = w[3];
    if (!bound || bound > (1u << 22)) return 0;
    /* per id: 1 = the type is a PhysicalStorageBuffer pointer, 2 = P (address derived from a table qword),
       4 = PushConstant pointer into a table member (>= first table member), 8 = defined as a constant/clean value */
    uint8_t *k = calloc(bound, 1); uint32_t *ty = calloc(bound, 4), *ptrsc = calloc(bound, 4);
    uint32_t pushvar = 0, first_member = ~0u; int ok = 0, writes = 0;
    if (!k || !ty || !ptrsc) goto out;
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
        if (!wc || at + wc > nw) goto out;
        if (op == 32 && wc == 4 && i[1] < bound) { ptrsc[i[1]] = i[2] + 1; if (i[2] == 5349) k[i[1]] |= 1; }
        if (op == 59 && wc >= 4) {
            switch (i[3]) {
            case 1: case 4: case 6: case 7: break;               /* Input, Workgroup, Private, Function */
            case 9: if (pushvar) goto out; pushvar = i[2]; break; /* the one push block */
            default: goto out;                                    /* descriptors, images, ... */
            }
        }
        if (op == 4472 || op == 5341 || op == 25 || op == 26 || op == 27) goto out;   /* ray query, AS, image, sampler */
        at += wc;
    }
    if (!pushvar) goto out;
    {   /* the push block's member at offset 48 is the first table qword (nvmtl_spirv_table_pc_ex, NVMTL_PC_TABLE_CS_OFFSET) */
        uint32_t ptype = 0, block = 0;
        for (size_t at = 5; at < nw && !ptype;) { const uint32_t *i = w + at, wc = i[0] >> 16;
            if ((i[0] & 0xffffu) == 59 && wc >= 4 && i[2] == pushvar) ptype = i[1]; at += wc; }
        for (size_t at = 5; at < nw && ptype && !block;) { const uint32_t *i = w + at, wc = i[0] >> 16;
            if ((i[0] & 0xffffu) == 32 && wc == 4 && i[1] == ptype) block = i[3]; at += wc; }
        for (size_t at = 5; at < nw && block;) { const uint32_t *i = w + at, wc = i[0] >> 16;
            if ((i[0] & 0xffffu) == 72 && wc == 5 && i[1] == block && i[3] == 35 && i[4] == 48) first_member = i[2]; at += wc; }
    }
    if (first_member == ~0u) goto out;
    /* forward data flow, iterated to a fixed point for phis (back edges) */
    for (int pass = 0; pass < 8; pass++) {
        int changed = 0;
        for (size_t at = 5; at < nw;) {
            const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
            const uint32_t rt = wc >= 3 ? i[1] : 0, id = wc >= 3 ? i[2] : 0;
            uint8_t add = 0;
#define NVK_P(x) ((x) < bound && (k[(x)] & 2))
            switch (op) {
            case 65: case 66: case 67: case 70:   /* access chains: the base's provenance; a push-table member pointer */
                if (wc >= 4 && id < bound) {
                    if (i[3] == pushvar && wc >= 5) {
                        /* OpAccessChain %ptr %push %member: a member >= first_member is a table qword */
                        uint32_t mv = ~0u;
                        for (size_t j = 5; j < nw;) { const uint32_t *c = w + j, cw = c[0] >> 16;
                            if ((c[0] & 0xffffu) == 43 && cw >= 4 && c[2] == i[4]) { mv = c[3]; break; } j += cw; }
                        if (mv != ~0u && mv >= first_member) add = 4;
                    } else if (NVK_P(i[3])) add = 2;
                    else if (i[3] < bound && (k[i[3]] & 4)) add = 4;
                }
                break;
            case 61:   /* OpLoad: from a table member -> P; a pointer or address loaded from memory is never P */
                if (wc >= 4 && i[3] < bound && (k[i[3]] & 4)) add = 2;
                break;
            case 128: case 130: case 113: case 114: case 124: case 83:   /* IAdd ISub UConvert SConvert Bitcast CopyObject */
            case 199: case 197: case 198: case 194: case 196:            /* And Or Xor ShiftRightLogical ShiftLeftLogical */
            case 81: case 80: case 117: case 120:                        /* CompositeExtract/Construct, PtrToU, UToPtr */
                for (uint32_t a = 3; a < wc; a++) if (NVK_P(i[a])) { add = 2; break; }   /* base + any index stays P */
                break;
            case 169: {   /* OpSelect: both values */
                if (wc == 6 && NVK_P(i[4]) && NVK_P(i[5])) add = 2;
                break; }
            case 245: {   /* OpPhi: every incoming value */
                int all = wc >= 5;
                for (uint32_t a = 3; a + 1 < wc; a += 2) if (!NVK_P(i[a])) { all = 0; break; }
                if (all) add = 2;
                break; }
            default: break;
            }
#undef NVK_P
            if (wc >= 3 && id < bound && rt < bound && (op == 61 || op == 65 || op == 66 || op == 67 || op == 70 || op == 120 ||
                                         op == 169 || op == 245 || op == 83 || op == 55 || op == 57 || op == 124)) ty[id] = rt;
            if (add && id < bound && (k[id] & add) != add) { k[id] |= add; changed = 1; }
            at += wc;
        }
        if (!changed) break;
    }
    /* every physical pointer made, and every physical access, must be P */
    for (size_t at = 5; at < nw;) {
        const uint32_t *i = w + at, wc = i[0] >> 16, op = i[0] & 0xffffu;
#define NVK_PP(x) ((x) < bound && ty[(x)] < bound && (k[ty[(x)]] & 1))   /* x has a physical pointer type */
#define NVK_OK(x) ((x) < bound && (k[(x)] & 2))
        if (op == 120 && wc == 4 && !NVK_OK(i[3])) goto out;                     /* ConvertUToPtr of a non-P value */
        if ((op == 61 || op == 55) && wc >= 3 && i[1] < bound && (k[i[1]] & 1)) goto out;   /* pointer loaded / passed in */
        if (op == 61 && wc >= 4 && NVK_PP(i[3]) && !NVK_OK(i[3])) goto out;      /* physical load through a non-P pointer */
        if (op == 62 && wc >= 3) {                                               /* OpStore */
            if (NVK_PP(i[1])) { if (!NVK_OK(i[1])) goto out; writes = 1; }
            if (NVK_OK(i[2])) goto out;                                          /* an address stored to memory escapes */
        }
        if (op == 63 && wc >= 3) {                                               /* OpCopyMemory */
            if (NVK_PP(i[1])) { if (!NVK_OK(i[1])) goto out; writes = 1; }
            if (NVK_PP(i[2]) && !NVK_OK(i[2])) goto out;
        }
        if (op == 228 && wc >= 2 && NVK_PP(i[1])) { if (!NVK_OK(i[1])) goto out; writes = 1; }   /* OpAtomicStore */
        if (((op >= 227 && op <= 242 && op != 228) || op == 5614 || op == 5615 || op == 6035) && wc >= 4 && NVK_PP(i[3])) {
            if (!NVK_OK(i[3])) goto out; writes = 1; }
        if (op == 57) for (uint32_t a = 4; a < wc; a++) if (NVK_OK(i[a]) || NVK_PP(i[a])) goto out;   /* passed to a function */
#undef NVK_PP
#undef NVK_OK
        at += wc;
    }
    ok = 1;
out:
    free(k); free(ty); free(ptrsc);
    if (ok) *wr = writes;
    return ok;
}
#endif
