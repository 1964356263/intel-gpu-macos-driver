// SPDX-License-Identifier: MIT
/*
 * Contains material from Linux drivers/gpu/drm/xe: xe_lrc.c and regs/xe_lrc_layout.h.
 *
 * Copyright © 2021 Intel Corporation
 * Copyright (c) 2026 Yusuf İhsan Kılınç (this adaptation)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
// Logical ring context (LRC) image for the Xe2 copy engine, from Linux v7.2 drivers/gpu/drm/xe/xe_lrc.c (MIT,
// Copyright Intel Corporation): set_offsets(), XE2_CTX_COMMON, xe2_bcs_offsets, set_context_control(), and the
// layout of regs/xe_lrc_layout.h. Graphics 20.01 has no indirect ring state (graphics_xe2), so the ring registers
// live in the context image.
#pragma once
#include <stdint.h>

#define LRC_NOP(x) (0x80 | (x))
#define LRC_LRI(count, flags) ((flags) << 6 | (count))
#define LRC_POSTED 1
#define LRC_REG(x) ((x) >> 2)
#define LRC_REG16(x) (((x) >> 9) | 0x80), (((x) >> 2) & 0x7f)

#define XE2_CTX_COMMON \
	LRC_NOP(1), \
	LRC_LRI(15, LRC_POSTED), \
	LRC_REG16(0x244), LRC_REG(0x034), LRC_REG(0x030), LRC_REG(0x038), LRC_REG(0x03c), LRC_REG(0x168), LRC_REG(0x140), \
	LRC_REG(0x110), LRC_REG(0x1c0), LRC_REG(0x1c4), LRC_REG(0x1c8), LRC_REG(0x180), LRC_REG16(0x2b4), LRC_REG(0x120), \
	LRC_REG(0x124), \
	LRC_NOP(1), \
	LRC_LRI(9, LRC_POSTED), \
	LRC_REG16(0x3a8), LRC_REG16(0x3ac), LRC_REG(0x108), LRC_REG16(0x284), LRC_REG16(0x280), LRC_REG16(0x27c), \
	LRC_REG16(0x278), LRC_REG16(0x274), LRC_REG16(0x270)

static const uint8_t xe2_rcs_offsets[] = {
	XE2_CTX_COMMON,
	LRC_NOP(2),
	LRC_LRI(2, LRC_POSTED),
	LRC_REG16(0x5a8), LRC_REG16(0x5ac),
	LRC_NOP(6),
	LRC_LRI(1, 0),
	LRC_REG(0x0c8),
	0
};

static const uint8_t xe2_xcs_offsets[] = {
	XE2_CTX_COMMON,
	0
};

static const uint8_t xe2_bcs_offsets[] = {
	LRC_NOP(1),
	LRC_LRI(15, LRC_POSTED),
	LRC_REG16(0x244), LRC_REG(0x034), LRC_REG(0x030), LRC_REG(0x038), LRC_REG(0x03c), LRC_REG(0x168), LRC_REG(0x140),
	LRC_REG(0x110), LRC_REG(0x1c0), LRC_REG(0x1c4), LRC_REG(0x1c8), LRC_REG(0x180), LRC_REG16(0x2b4), LRC_REG(0x120),
	LRC_REG(0x124),
	LRC_NOP(1),
	LRC_LRI(9, LRC_POSTED),
	LRC_REG16(0x3a8), LRC_REG16(0x3ac), LRC_REG(0x108), LRC_REG16(0x284), LRC_REG16(0x280), LRC_REG16(0x27c),
	LRC_REG16(0x278), LRC_REG16(0x274), LRC_REG16(0x270),
	LRC_NOP(4 + 8 + 1),
	LRC_LRI(2, LRC_POSTED),
	LRC_REG16(0x200), LRC_REG16(0x204),
	0
};

// MI commands (instructions/xe_mi_commands.h, xe_instr_defs.h)
#define MI_INSTR(op) ((uint32_t)(op) << 23)
#define MI_NOOP MI_INSTR(0x0)
#define MI_ARB_ON_OFF MI_INSTR(0x8)
#define   MI_ARB_ENABLE 1u
#define MI_BATCH_BUFFER_END MI_INSTR(0xa)
#define MI_STORE_DATA_IMM MI_INSTR(0x20)
#define   MI_SDI_GGTT (1u << 22)
#define   MI_SDI_NUM_DW(x) ((x) + 3 - 2)
#define MI_LOAD_REGISTER_IMM MI_INSTR(0x22)
#define   MI_LRI_LRM_CS_MMIO (1u << 19)
#define   MI_LRI_FORCE_POSTED (1u << 12)
#define   MI_LRI_NUM_REGS(x) (2 * (x) + 1 - 2)

// Context image dword indices (regs/xe_lrc_layout.h)
#define CTX_CONTEXT_CONTROL (0x02 + 1)
#define CTX_RING_HEAD (0x04 + 1)
#define CTX_RING_TAIL (0x06 + 1)
#define CTX_RING_START (0x08 + 1)
#define CTX_RING_CTL (0x0a + 1)
#define CTX_TIMESTAMP (0x22 + 1)
#define CTX_ASID (0x2e + 1)
#define CTX_PDP0_UDW (0x30 + 1)
#define CTX_PDP0_LDW (0x32 + 1)

static inline void lrcSetOffsets(uint32_t *regs, const uint8_t *data, uint32_t base) {
	while (*data) {
		if (*data & 0x80) {
			regs += *data++ & 0x7f;
			continue;
		}
		uint8_t count = *data & 0x3f, flags = *data >> 6;
		data++;
		*regs = MI_LOAD_REGISTER_IMM | MI_LRI_NUM_REGS(count) | MI_LRI_LRM_CS_MMIO;
		if (flags & LRC_POSTED) *regs |= MI_LRI_FORCE_POSTED;
		regs++;
		do {
			uint32_t offset = 0;
			uint8_t v;
			do {
				v = *data++;
				offset = offset << 7 | (v & 0x7f);
			} while (v & 0x80);
			regs[0] = base + (offset << 2);
			regs += 2;
		} while (--count);
	}
	*regs = MI_BATCH_BUFFER_END | 1;
}
