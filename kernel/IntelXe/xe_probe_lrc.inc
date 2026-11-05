// SPDX-License-Identifier: MIT
// Context image register layouts (set_offsets tables) copied from Linux drivers/gpu/drm/xe/xe_lrc.c
// (MIT, Copyright Intel Corporation; torvalds/master as of 2026-10-30): gen12/dg2 xcs, gen12/xehp/dg2/mtl/xe2 rcs,
// xe2 bcs/xcs. Encoding as in set_offsets(): NOP(n) skips n dwords, LRI(count, flags) starts a register list,
// REG/REG16 give offsets from the engine base. Used only by xe_probe.cpp.
#pragma once
#include <stdint.h>
#define NOP(x) (0x80 | (x))
#define LRI(count, flags) ((flags) << 6 | (count))
#define POSTED 1
#define REG(x) ((x) >> 2)
#define REG16(x) (((x) >> 9) | 0x80), (((x) >> 2) & 0x7f)

static const uint8_t xp_gen12_xcs_offsets[] = {
	NOP(1),
	LRI(13, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),

	NOP(5),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	0
};

static const uint8_t xp_dg2_xcs_offsets[] = {
	NOP(1),
	LRI(15, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),
	REG(0x120),
	REG(0x124),

	NOP(1),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	0
};

static const uint8_t xp_gen12_rcs_offsets[] = {
	NOP(1),
	LRI(13, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),

	NOP(5),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	LRI(3, POSTED),
	REG(0x1b0),
	REG16(0x5a8),
	REG16(0x5ac),

	NOP(6),
	LRI(1, 0),
	REG(0x0c8),
	NOP(3 + 9 + 1),

	LRI(51, POSTED),
	REG16(0x588),
	REG16(0x588),
	REG16(0x588),
	REG16(0x588),
	REG16(0x588),
	REG16(0x588),
	REG(0x028),
	REG(0x09c),
	REG(0x0c0),
	REG(0x178),
	REG(0x17c),
	REG16(0x358),
	REG(0x170),
	REG(0x150),
	REG(0x154),
	REG(0x158),
	REG16(0x41c),
	REG16(0x600),
	REG16(0x604),
	REG16(0x608),
	REG16(0x60c),
	REG16(0x610),
	REG16(0x614),
	REG16(0x618),
	REG16(0x61c),
	REG16(0x620),
	REG16(0x624),
	REG16(0x628),
	REG16(0x62c),
	REG16(0x630),
	REG16(0x634),
	REG16(0x638),
	REG16(0x63c),
	REG16(0x640),
	REG16(0x644),
	REG16(0x648),
	REG16(0x64c),
	REG16(0x650),
	REG16(0x654),
	REG16(0x658),
	REG16(0x65c),
	REG16(0x660),
	REG16(0x664),
	REG16(0x668),
	REG16(0x66c),
	REG16(0x670),
	REG16(0x674),
	REG16(0x678),
	REG16(0x67c),
	REG(0x068),
	REG(0x084),
	NOP(1),

	0
};

static const uint8_t xp_xehp_rcs_offsets[] = {
	NOP(1),
	LRI(13, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),

	NOP(5),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	LRI(3, POSTED),
	REG(0x1b0),
	REG16(0x5a8),
	REG16(0x5ac),

	NOP(6),
	LRI(1, 0),
	REG(0x0c8),

	0
};

static const uint8_t xp_dg2_rcs_offsets[] = {
	NOP(1),
	LRI(15, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),
	REG(0x120),
	REG(0x124),

	NOP(1),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	LRI(3, POSTED),
	REG(0x1b0),
	REG16(0x5a8),
	REG16(0x5ac),

	NOP(6),
	LRI(1, 0),
	REG(0x0c8),

	0
};

static const uint8_t xp_mtl_rcs_offsets[] = {
	NOP(1),
	LRI(15, POSTED),
	REG16(0x244),
	REG(0x034),
	REG(0x030),
	REG(0x038),
	REG(0x03c),
	REG(0x168),
	REG(0x140),
	REG(0x110),
	REG(0x1c0),
	REG(0x1c4),
	REG(0x1c8),
	REG(0x180),
	REG16(0x2b4),
	REG(0x120),
	REG(0x124),

	NOP(1),
	LRI(9, POSTED),
	REG16(0x3a8),
	REG16(0x28c),
	REG16(0x288),
	REG16(0x284),
	REG16(0x280),
	REG16(0x27c),
	REG16(0x278),
	REG16(0x274),
	REG16(0x270),

	NOP(2),
	LRI(2, POSTED),
	REG16(0x5a8),
	REG16(0x5ac),

	NOP(6),
	LRI(1, 0),
	REG(0x0c8),

	0
};

#define XE2_CTX_COMMON \
	NOP(1),                 /* [0x00] */ \
	LRI(15, POSTED),        /* [0x01] */ \
	REG16(0x244),           /* [0x02] CTXT_SR_CTL */ \
	REG(0x034),             /* [0x04] RING_BUFFER_HEAD */ \
	REG(0x030),             /* [0x06] RING_BUFFER_TAIL */ \
	REG(0x038),             /* [0x08] RING_BUFFER_START */ \
	REG(0x03c),             /* [0x0a] RING_BUFFER_CONTROL */ \
	REG(0x168),             /* [0x0c] BB_ADDR_UDW */ \
	REG(0x140),             /* [0x0e] BB_ADDR */ \
	REG(0x110),             /* [0x10] BB_STATE */ \
	REG(0x1c0),             /* [0x12] BB_PER_CTX_PTR */ \
	REG(0x1c4),             /* [0x14] RCS_INDIRECT_CTX */ \
	REG(0x1c8),             /* [0x16] RCS_INDIRECT_CTX_OFFSET */ \
	REG(0x180),             /* [0x18] CCID */ \
	REG16(0x2b4),           /* [0x1a] SEMAPHORE_TOKEN */ \
	REG(0x120),             /* [0x1c] PRT_BB_STATE */ \
	REG(0x124),             /* [0x1e] PRT_BB_STATE_UDW */ \
	\
	NOP(1),                 /* [0x20] */ \
	LRI(9, POSTED),         /* [0x21] */ \
	REG16(0x3a8),           /* [0x22] CTX_TIMESTAMP */ \
	REG16(0x3ac),           /* [0x24] CTX_TIMESTAMP_UDW */ \
	REG(0x108),             /* [0x26] INDIRECT_RING_STATE */ \
	REG16(0x284),           /* [0x28] dummy reg */ \
	REG16(0x280),           /* [0x2a] CS_ACC_CTR_THOLD */ \
	REG16(0x27c),           /* [0x2c] CS_CTX_SYS_PASID */ \
	REG16(0x278),           /* [0x2e] CS_CTX_ASID */ \
	REG16(0x274),           /* [0x30] PTBP_UDW */ \
	REG16(0x270)            /* [0x32] PTBP_LDW */

static const uint8_t xp_xe2_rcs_offsets[] = {
	XE2_CTX_COMMON,

	NOP(2),                 /* [0x34] */
	LRI(2, POSTED),         /* [0x36] */
	REG16(0x5a8),           /* [0x37] CONTEXT_SCHEDULING_ATTRIBUTES */
	REG16(0x5ac),           /* [0x39] PREEMPTION_STATUS */

	NOP(6),                 /* [0x41] */
	LRI(1, 0),              /* [0x47] */
	REG(0x0c8),             /* [0x48] R_PWR_CLK_STATE */

	0
};

static const uint8_t xp_xe2_bcs_offsets[] = {
	XE2_CTX_COMMON,

	NOP(4 + 8 + 1),         /* [0x34] */
	LRI(2, POSTED),         /* [0x41] */
	REG16(0x200),           /* [0x42] BCS_SWCTRL */
	REG16(0x204),           /* [0x44] BLIT_CCTL */

	0
};

static const uint8_t xp_xe2_xcs_offsets[] = {
	XE2_CTX_COMMON,

	0
};

#undef NOP
#undef LRI
#undef POSTED
#undef REG
#undef REG16
