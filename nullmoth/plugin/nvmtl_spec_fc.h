// Function-constant values into a module whose function constants are specialization constants
// (nvmtl_translate_fc_spec, translator wrapper spec_fc.rs). The values become the specialization constants' defaults,
// which is exactly what VkSpecializationInfo would do: the driver folds them before it compiles. The SpecIds are read
// from the module's decorations:
//   0x00800000 | (index << 3) | lane    value of function constant `index`, lane `lane`
//   0x01000000 | index                  1 when function constant `index` has a value (is_function_constant_defined)
// (other specialization constants, such as a kernel's workgroup size at SpecId 0-3, are not touched)
// Values are little-endian bytes as Metal holds them (MTLFunctionConstantValues), lane after lane.
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define NVMTL_SPEC_DEFINED 0x01000000u
#define NVMTL_SPEC_VALUE 0x00800000u

// Returns a malloc'ed copy of the module with the values applied (*out_words words), or NULL on a malformed module.
// *applied counts the specialization constants that took a supplied value (definedness included).
// freeze: the specialization constants become plain constants (OpSpecConstant* -> OpConstant*, SpecId decorations
// dropped), the module then is exactly a module translated with the values; otherwise they stay specialization
// constants whose defaults are the values.
static uint32_t *nvmtl_spec_fc_apply_ex(const uint32_t *w, size_t n, const uint32_t *idx, const uint32_t *sz,
                                        const uint8_t *const *pay, size_t count, size_t *out_words, unsigned *applied, int freeze);
static uint32_t *nvmtl_spec_fc_apply(const uint32_t *w, size_t n, const uint32_t *idx, const uint32_t *sz,
                                     const uint8_t *const *pay, size_t count, size_t *out_words, unsigned *applied)
{
    return nvmtl_spec_fc_apply_ex(w, n, idx, sz, pay, count, out_words, applied, 0);
}
static uint32_t *nvmtl_spec_fc_apply_ex(const uint32_t *w, size_t n, const uint32_t *idx, const uint32_t *sz,
                                        const uint8_t *const *pay, size_t count, size_t *out_words, unsigned *applied, int freeze)
{
    if (applied) *applied = 0;
    if (n < 5 || w[0] != 0x07230203u) return NULL;
    const uint32_t bound = w[3];
    if (!bound || bound > (1u << 26)) return NULL;
    uint32_t *spec = calloc(bound, sizeof *spec);      // id -> SpecId + 1 (0: none)
    uint32_t *tinfo = calloc(bound, sizeof *tinfo);    // type id -> bits | signed << 8 | float << 9 (0: not a scalar)
    uint32_t *out = malloc(n * sizeof *out);
    if (!spec || !tinfo || !out) { free(spec); free(tinfo); free(out); return NULL; }
    memcpy(out, w, n * sizeof *out);
    for (size_t i = 5; i < n;) {
        const uint32_t op = w[i] & 0xffffu, wc = w[i] >> 16;
        if (!wc || i + wc > n) { free(spec); free(tinfo); free(out); return NULL; }
        if (op == 71 && wc == 4 && w[i + 2] == 1 && w[i + 1] < bound) spec[w[i + 1]] = w[i + 3] + 1;      // OpDecorate SpecId
        else if (op == 21 && wc == 4 && w[i + 1] < bound) tinfo[w[i + 1]] = (w[i + 2] & 0xff) | (w[i + 3] ? 1u << 8 : 0); // OpTypeInt
        else if (op == 22 && wc >= 3 && w[i + 1] < bound) tinfo[w[i + 1]] = (w[i + 2] & 0xff) | 1u << 9;          // OpTypeFloat
        else if (op == 54) break;                                                                               // OpFunction: no more
        i += wc;
    }
    for (size_t i = 5; i < n;) {
        const uint32_t op = w[i] & 0xffffu, wc = w[i] >> 16;
        if (op == 54) break;
        // OpSpecConstantTrue / OpSpecConstantFalse / OpSpecConstant
        if ((op == 48 || op == 49 || op == 50) && wc >= 3 && w[i + 2] < bound && spec[w[i + 2]]) {
            const uint32_t sid = spec[w[i + 2]] - 1;
            if (!(sid & (NVMTL_SPEC_DEFINED | NVMTL_SPEC_VALUE))) { spec[w[i + 2]] = 0; i += wc; continue; }   // not ours
            const uint32_t index = (sid & NVMTL_SPEC_DEFINED) ? (sid & ~NVMTL_SPEC_DEFINED) : (sid & ~NVMTL_SPEC_VALUE) >> 3, lane = sid & 7;
            const uint8_t *v = NULL; uint32_t vlen = 0;
            for (size_t k = 0; k < count; k++) if (idx[k] == index) { v = pay[k]; vlen = sz[k]; break; }
            if (sid & NVMTL_SPEC_DEFINED) {
                if (op != 50) { out[i] = (wc << 16) | (v ? 48u : 49u); if (v && applied) (*applied)++; }
            } else if (v && op != 50) {                                  // a bool-typed constant: one byte per lane
                if (lane < vlen) { out[i] = (wc << 16) | (v[lane] ? 48u : 49u); if (applied) (*applied)++; }
            } else if (v && op == 50 && w[i + 1] < bound && tinfo[w[i + 1]]) {
                const uint32_t ti = tinfo[w[i + 1]], bits = ti & 0xff, bytes = bits / 8;
                if (bytes && (lane + 1) * bytes <= vlen && ((bits <= 32 && wc == 4) || (bits == 64 && wc == 5))) {
                    uint64_t x = 0;
                    memcpy(&x, v + lane * bytes, bytes);
                    if (bits < 32 && (ti & (1u << 8)) && (x >> (bits - 1)) & 1) x |= ~0ull << bits;   // signed: sign-extend
                    out[i + 3] = (uint32_t)x;
                    if (bits == 64) out[i + 4] = (uint32_t)(x >> 32);
                    if (applied) (*applied)++;
                }
            }
        }
        i += wc;
    }
    if (freeze) {   // after the values are in: plain constants, and the SpecId decorations go
        // spec[id] is nonzero only for ours now; a composite is frozen when all its constituents are
        size_t o = 5;
        for (size_t i = 5; i < n;) {
            const uint32_t op = out[i] & 0xffffu, wc = out[i] >> 16;
            if (op == 71 && wc == 4 && out[i + 2] == 1 && out[i + 1] < bound && spec[out[i + 1]]) { i += wc; continue; }   // our SpecId
            uint32_t nop = op;
            if ((op == 48 || op == 49 || op == 50) && wc >= 3 && out[i + 2] < bound && spec[out[i + 2]])
                nop = op == 48 ? 41u : op == 49 ? 42u : 43u;                                       // Spec* -> Constant*
            else if (op == 51 && wc >= 3 && out[i + 2] < bound) {
                int all = 1; for (uint32_t k = 3; k < wc; k++) if (out[i + k] >= bound || !spec[out[i + k]]) all = 0;
                if (all) { nop = 44u; spec[out[i + 2]] = 1; }                                      // OpConstantComposite
            }
            memmove(out + o, out + i, wc * sizeof *out);
            out[o] = (wc << 16) | nop;
            o += wc; i += wc;
        }
        n = o;
    }
    free(spec); free(tinfo);
    *out_words = n;
    return out;
}
