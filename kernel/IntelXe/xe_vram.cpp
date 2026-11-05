// SPDX-License-Identifier: MIT
// VRAM and GGTT range allocators of IntelXe.kext (phase 2).
//
// VramBuddy follows drivers/gpu/drm/drm_buddy.c as xe_ttm_vram_mgr.c uses it: power-of-two blocks of a minimum chunk
// (64 KB, XE_VRAM_FLAGS_NEED64K / the 64K PTE granule), roots that are the largest naturally aligned blocks of the
// region (so a 2 MB or 1 GB block is aligned in device physical address space and can back a huge PTE), split on
// allocation and merged with their buddy on free; DRM_BUDDY_TOPDOWN_ALLOCATION (highest addresses first) for BOs the
// CPU never maps, best fit from the bottom otherwise; DRM_BUDDY_CONTIGUOUS_ALLOCATION as one power-of-two block whose
// unused tail is trimmed back (drm_buddy_block_trim). A BO's VRAM is a list of blocks (XeBo::blocks, linked by `link`).
// Callers hold gResLock.
//
// GgttRanges hands out GGTT address ranges to IntelXeFB (scan-out slots, cursor) instead of fixed addresses; IntelXe's own
// GGTT layout (IntelXe.h) stays below kGgttDispStart.
#include "IntelXe.h"
#include "xe_vram.h"
#include <sys/errno.h>

static VBlock *gNodeCache;

static VBlock *nodeNew(uint64_t off, uint8_t order, VBlock *parent) {
	VBlock *n = gNodeCache;
	if (n) gNodeCache = n->next;
	else n = static_cast<VBlock *>(IOMalloc(sizeof(VBlock)));
	if (!n) return nullptr;
	bzero(n, sizeof(*n));
	n->off = off;
	n->order = order;
	n->parent = parent;
	return n;
}

static void nodeDel(VBlock *n) {
	n->next = gNodeCache;
	gNodeCache = n;
}

static void listAdd(VramBuddy *b, VBlock *n) {
	n->state = kVFree;
	n->prev = nullptr;
	n->next = b->lists[n->order];
	if (n->next) n->next->prev = n;
	b->lists[n->order] = n;
	b->freeBytes += vblockSize(n);
}

static void listDel(VramBuddy *b, VBlock *n) {
	if (n->prev) n->prev->next = n->next;
	else b->lists[n->order] = n->next;
	if (n->next) n->next->prev = n->prev;
	n->prev = n->next = nullptr;
	b->freeBytes -= vblockSize(n);
}

bool buddyInit(VramBuddy *b, uint64_t start, uint64_t end) {
	bzero(b, sizeof(*b));
	start = (start + kVChunk - 1) & ~(kVChunk - 1);
	end &= ~(kVChunk - 1);
	b->start = start;
	b->end = end;
	for (uint64_t off = start; off < end;) {
		int o = kVMaxOrder;
		while (o > 0 && ((off & ((kVChunk << o) - 1)) || off + (kVChunk << o) > end)) o--;
		if (b->nRoots == sizeof(b->roots) / sizeof(b->roots[0])) return false;
		VBlock *r = nodeNew(off, (uint8_t)o, nullptr);
		if (!r) return false;
		b->roots[b->nRoots++] = r;
		listAdd(b, r);
		off += kVChunk << o;
	}
	b->size = b->freeBytes;
	return true;
}

static bool split(VramBuddy *b, VBlock *n) {
	const uint64_t half = vblockSize(n) / 2;
	VBlock *l = nodeNew(n->off, (uint8_t)(n->order - 1), n), *r = nodeNew(n->off + half, (uint8_t)(n->order - 1), n);
	if (!l || !r) {
		if (l) nodeDel(l);
		if (r) nodeDel(r);
		return false;
	}
	n->left = l;
	n->right = r;
	n->state = kVSplit;
	return true;
}

// Free block n (not on a list), merging with free buddies upwards.
static void freeBlock(VramBuddy *b, VBlock *n) {
	while (n->parent) {
		VBlock *p = n->parent, *bud = p->left == n ? p->right : p->left;
		if (bud->state != kVFree) break;
		listDel(b, bud);
		nodeDel(bud);
		nodeDel(n);
		p->left = p->right = nullptr;
		n = p;
	}
	listAdd(b, n);
}

// One block of `order`: across every free list of that order and above, the highest (topdown) or lowest address,
// split down to `order` keeping the half on that side.
static VBlock *allocOrder(VramBuddy *b, int order, bool topdown) {
	VBlock *best = nullptr;
	for (int o = order; o <= kVMaxOrder; o++)
		for (VBlock *n = b->lists[o]; n; n = n->next)
			if (!best || (topdown ? n->off > best->off : n->off < best->off)) best = n;
	if (!best) return nullptr;
	listDel(b, best);
	while (best->order > order) {
		if (!split(b, best)) {
			freeBlock(b, best);
			return nullptr;
		}
		VBlock *keep = topdown ? best->right : best->left, *other = topdown ? best->left : best->right;
		listAdd(b, other);
		best = keep;
	}
	best->state = kVAlloc;
	return best;
}

// drm_buddy_block_trim: keep the first `keep` bytes of allocated block n, give the rest back. Returns the kept blocks
// (address order, linked by `link`).
static VBlock *trim(VramBuddy *b, VBlock *n, uint64_t keep) {
	if (keep >= vblockSize(n) || !n->order) return n;
	if (!split(b, n)) return n;   // keep the whole block rather than fail
	const uint64_t half = vblockSize(n) / 2;
	VBlock *l = n->left, *r = n->right;
	l->state = kVAlloc;
	if (keep <= half) {
		freeBlock(b, r);
		return trim(b, l, keep);
	}
	r->state = kVAlloc;
	l->link = trim(b, r, keep - half);
	return l;
}

static int log2Floor(uint64_t v) { return 63 - __builtin_clzll(v); }

VBlock *buddyAlloc(VramBuddy *b, uint64_t size, bool topdown, bool contiguous) {
	size = (size + kVChunk - 1) & ~(kVChunk - 1);
	if (!size || size > b->freeBytes) return nullptr;
	const uint64_t chunks = size / kVChunk;
	if (contiguous) {
		int order = log2Floor(chunks);
		if ((1ull << order) < chunks) order++;
		if (order > kVMaxOrder) return nullptr;
		VBlock *n = allocOrder(b, order, topdown);
		return n ? trim(b, n, size) : nullptr;
	}
	// Largest blocks first (2 MB and up wherever the request and free space allow, for huge PTEs), smaller ones only
	// when the larger orders have nothing left.
	VBlock *head = nullptr, **tail = &head;
	uint64_t left = size;
	int cap = kVMaxOrder;
	while (left) {
		int o = log2Floor(left / kVChunk);
		if (o > cap) o = cap;
		VBlock *n = nullptr;
		for (; o >= 0 && !(n = allocOrder(b, o, topdown)); o--) {}
		if (!n) {
			buddyFree(b, head);
			return nullptr;
		}
		cap = o;   // nothing larger is free any more
		*tail = n;
		tail = &n->link;
		left -= vblockSize(n);
	}
	return head;
}

void buddyFree(VramBuddy *b, VBlock *list) {
	while (list) {
		VBlock *nx = list->link;
		list->link = nullptr;
		freeBlock(b, list);
		list = nx;
	}
}

// ─── GGTT ranges for IntelXeFB ───────────────────────────────────────────────────────────────────────────────────────
static GgttRange gGgtt[64];
static uint32_t gGgttN;

int ggttRangeAlloc(uint64_t size, uint64_t align, bool fixed, uint32_t *addr) {
	size = (size + 0xfff) & ~0xfffull;
	if (!align || (align & (align - 1))) align = 0x1000;
	if (!size || gGgttN == sizeof(gGgtt) / sizeof(gGgtt[0])) return ENOSPC;
	uint64_t at = fixed ? *addr : kGgttDispStart;
	if (fixed && ((at & 0xfff) || at < kGgttDispStart || at + size > kGgttDispEnd)) return EINVAL;
	for (;;) {
		at = (at + align - 1) & ~(align - 1);
		if (at + size > kGgttDispEnd) return ENOSPC;
		uint32_t i = 0;
		while (i < gGgttN && (gGgtt[i].start + gGgtt[i].size <= at || gGgtt[i].start >= at + size)) i++;
		if (i == gGgttN) break;
		if (fixed) return EBUSY;
		at = gGgtt[i].start + gGgtt[i].size;
	}
	gGgtt[gGgttN++] = {(uint32_t)at, (uint32_t)size};
	*addr = (uint32_t)at;
	return 0;
}

void ggttRangeStats(uint32_t *n, uint64_t *bytes) {   // gResLock
	uint64_t b = 0;
	for (uint32_t i = 0; i < gGgttN; i++) b += gGgtt[i].size;
	*n = gGgttN;
	*bytes = b;
}

int ggttRangeFree(uint32_t addr) {
	for (uint32_t i = 0; i < gGgttN; i++)
		if (gGgtt[i].start == addr) {
			gGgtt[i] = gGgtt[--gGgttN];
			return 0;
		}
	return ENOENT;
}
