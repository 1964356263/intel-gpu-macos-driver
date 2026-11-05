// SPDX-License-Identifier: MIT
// VRAM buddy allocator and GGTT range manager (xe_vram.cpp). Callers hold gResLock.
#pragma once
#include <stdint.h>

static constexpr uint64_t kVChunk = 64ull << 10;   // minimum block: 64 KB
static constexpr int kVMaxOrder = 14;               // 64 KB << 14 = 1 GB
enum : uint8_t { kVFree = 1, kVAlloc = 2, kVSplit = 3 };

struct VBlock {
	uint64_t off;            // device physical address (DPA)
	uint8_t order, state;
	VBlock *parent, *left, *right;
	VBlock *prev, *next;     // free list of its order
	VBlock *link;            // the owning BO's block list
};
static inline uint64_t vblockSize(const VBlock *b) { return kVChunk << b->order; }

struct VramBuddy {
	uint64_t start, end, size, freeBytes;
	VBlock *lists[kVMaxOrder + 1];
	VBlock *roots[64];
	uint32_t nRoots;
};

bool buddyInit(VramBuddy *b, uint64_t start, uint64_t end);
VBlock *buddyAlloc(VramBuddy *b, uint64_t size, bool topdown, bool contiguous);
void buddyFree(VramBuddy *b, VBlock *list);

// GGTT addresses IntelXeFB may be given: above IntelXe's own objects (everything IntelXe.h places ends below 0x10000000).
static constexpr uint64_t kGgttDispStart = 0x10000000, kGgttDispEnd = 0xff000000;
struct GgttRange { uint32_t start, size; };
int ggttRangeAlloc(uint64_t size, uint64_t align, bool fixed, uint32_t *addr);
int ggttRangeFree(uint32_t addr);
void ggttRangeStats(uint32_t *n, uint64_t *bytes);   // IntelXeFB ranges in use (of 64) and their bytes
