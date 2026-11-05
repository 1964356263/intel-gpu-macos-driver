// glcpu3: completed handlers copied into a per-command-buffer arena instead of _Block_copy's malloc.
//
// Apple's OpenGL renderer adds one completed handler to the command buffer for every draw
// (GLDContextRec::drawCore, a stack block capturing two C pointers). -addCompletedHandler: must keep a copy of
// that block until the command buffer completes; _Block_copy mallocs 48 bytes on the app's render thread and the
// block is freed later on the callback thread. That producer/consumer pattern makes nanov2's allocation miss on
// slots another core just freed: in prod6/prod7 Minecraft profiles _Block_copy -> nanov2_malloc_type was
// 5.8-6.0% of the render thread (~160 ns per draw at ~2150 draws/frame), with no free on that thread at all.
//
// A block literal without copy/dispose helpers captures only plain bytes, and _Block_copy of such a block is a
// memmove of descriptor->size bytes plus heap isa/flags (Block ABI, libclosure runtime.cpp). The copy here is the
// same memmove into memory owned by the command buffer, invoked through the same invoke pointer with the copy as
// its block argument, in the order added, on the same callback queue. Anything else (global, heap, helpers,
// noescape, small/relative descriptor, ptrauth) is still copied with Block_copy, as before.
//
// NVMTL_HANDLER_ARENA=0 restores the prod7 path (every handler Block_copy'd, an NSArray built at completion).
#include <Block.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct nvmtl_hchunk { struct nvmtl_hchunk *next; uint32_t used, cap; uint64_t pad; unsigned char data[]; } nvmtl_hchunk;
typedef struct { void *isa; int32_t flags; int32_t reserved; void (*invoke)(void *, ...);
                 const struct { unsigned long reserved, size; } *descriptor; } nvmtl_block_layout;
enum { NVMTL_BLK_SMALL_DESCRIPTOR = 1 << 22, NVMTL_BLK_IS_NOESCAPE = 1 << 23, NVMTL_BLK_NEEDS_FREE = 1 << 24,
       NVMTL_BLK_HAS_COPY_DISPOSE = 1 << 25, NVMTL_BLK_HAS_CTOR = 1 << 26, NVMTL_BLK_IS_GC = 1 << 27,
       NVMTL_BLK_IS_GLOBAL = 1 << 28, NVMTL_BLK_USE_STRET = 1 << 29 };
#define NVMTL_HCHUNK_BYTES (32u << 10)
#define NVMTL_HPOOL_MAX 32u            // 1 MB of chunks kept for reuse, the rest freed
#define NVMTL_HBLOCK_MAX 512u          // larger literals are left to Block_copy
#define NVMTL_HTAG ((uintptr_t)1)      // low bit of an _hv entry: an arena copy (no reference to drop)

static int nvmtl_handler_arena_on(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("NVMTL_HANDLER_ARENA"), *m = getenv("NVMTL_GLCPU4");   // glcpu4: unset follows NVMTL_GLCPU4
        int v = (e && *e) ? e[0] != '0' : !(m && m[0] == '0');
#if __has_feature(ptrauth_calls)
        v = 0;                          // arm64e signs invoke with the block's address: a moved copy would not verify
#endif
        on = v;
        nvlog("glcpu3: completed handlers %s (NVMTL_HANDLER_ARENA=%s)",
              v ? "without helpers are copied into the command buffer's arena" : "are Block_copy'd (prod7)", e ? e : "default");
    }
    return on;
}
static os_unfair_lock g_hpool_lock = OS_UNFAIR_LOCK_INIT;
static nvmtl_hchunk *g_hpool; static unsigned g_hpool_n;
// census only: relaxed load + store, not a read-modify-write. A locked RMW per draw would drain the render thread's
// pending (write-combined batch) stores on x86; a lost count between racing threads does not matter here.
static _Atomic unsigned long long g_harena_copies, g_harena_fallbacks;
static inline unsigned long long nvmtl_census_bump(_Atomic unsigned long long *c) {
    const unsigned long long k = atomic_load_explicit(c, memory_order_relaxed) + 1;
    atomic_store_explicit(c, k, memory_order_relaxed); return k;
}

static nvmtl_hchunk *nvmtl_hchunk_get(void) {
    os_unfair_lock_lock(&g_hpool_lock);
    nvmtl_hchunk *c = g_hpool;
    if (c) { g_hpool = c->next; g_hpool_n--; }
    os_unfair_lock_unlock(&g_hpool_lock);
    if (!c) { c = (nvmtl_hchunk *)malloc(NVMTL_HCHUNK_BYTES); if (!c) return NULL; c->cap = NVMTL_HCHUNK_BYTES - (uint32_t)sizeof *c; }
    c->next = NULL; c->used = 0; return c;
}
// all of a command buffer's chunks, after its handlers ran (or it died without completing)
static void nvmtl_hchunks_put(nvmtl_hchunk *c) {
    while (c) {
        nvmtl_hchunk *n = c->next; int keep;
        os_unfair_lock_lock(&g_hpool_lock);
        keep = g_hpool_n < NVMTL_HPOOL_MAX;
        if (keep) { c->next = g_hpool; g_hpool = c; g_hpool_n++; }
        os_unfair_lock_unlock(&g_hpool_lock);
        if (!keep) free(c);
        c = n;
    }
}
// a stack block whose copy is a plain byte copy: no helpers to run, nothing it captures needs a reference
static size_t nvmtl_block_plain_size(const void *blk) {
    const nvmtl_block_layout *b = (const nvmtl_block_layout *)blk;
    if (b->isa != (void *)_NSConcreteStackBlock) return 0;
    if (b->flags & (NVMTL_BLK_SMALL_DESCRIPTOR | NVMTL_BLK_IS_NOESCAPE | NVMTL_BLK_NEEDS_FREE | NVMTL_BLK_HAS_COPY_DISPOSE |
                    NVMTL_BLK_HAS_CTOR | NVMTL_BLK_IS_GC | NVMTL_BLK_IS_GLOBAL | NVMTL_BLK_USE_STRET)) return 0;
    if (!b->invoke || !b->descriptor) return 0;
    const size_t n = b->descriptor->size;
    return n >= sizeof *b && n <= NVMTL_HBLOCK_MAX ? n : 0;
}
// caller holds the command buffer's lock; returns the tagged entry, or NULL to fall back to Block_copy
static void *nvmtl_harena_copy(nvmtl_hchunk **head, const void *blk) {
    const size_t n = nvmtl_block_plain_size(blk);
    if (!n) { (void)nvmtl_census_bump(&g_harena_fallbacks); return NULL; }
    const uint32_t need = (uint32_t)((n + 15u) & ~(size_t)15u);
    nvmtl_hchunk *c = *head;
    if (!c || c->cap - c->used < need) {
        nvmtl_hchunk *f = nvmtl_hchunk_get();
        if (!f) return NULL;
        f->next = c; *head = c = f;
    }
    void *dst = c->data + c->used; c->used += need;
    memcpy(dst, blk, n);
    const unsigned long long k = nvmtl_census_bump(&g_harena_copies);
    if (!(k & (k - 1)) && k >= 1024)
        nvlog("glcpu3: %llu completed handlers copied into arenas, %llu left to Block_copy", k,
              (unsigned long long)atomic_load_explicit(&g_harena_fallbacks, memory_order_relaxed));
    return (void *)((uintptr_t)dst | NVMTL_HTAG);
}
static inline void nvmtl_handler_entry_call(void *e, id cb) {
    if ((uintptr_t)e & NVMTL_HTAG) {
        nvmtl_block_layout *b = (nvmtl_block_layout *)((uintptr_t)e & ~NVMTL_HTAG);
        ((void (*)(void *, id))b->invoke)(b, cb);
    } else {
        ((__bridge MTLCommandBufferHandler)e)(cb);
    }
}
// drop an entry's reference (arena copies have none; their chunk goes back to the pool with the batch)
static inline void nvmtl_handler_entry_drop(void *e) { if (!((uintptr_t)e & NVMTL_HTAG)) CFRelease(e); }
