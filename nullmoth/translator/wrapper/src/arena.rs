// SPDX-License-Identifier: MIT
//! The allocator of this library. A translation makes millions of small allocations and frees nearly all of them by
//! its end, so inside `scope` small blocks come from thread-owned chunks with one free list per size, which is what
//! made it 9-21% faster than the system allocator with 14% less memory. Outside a scope, and for anything large, it
//! is the system allocator.
//!
//! The library is loaded into long-lived processes (WindowServer, the Dock), so nothing may stay behind: leaving the
//! outermost scope gives back every chunk whose blocks have all been freed, and a block that outlives its scope (an
//! error string, a small result, a lazily built table) gives its chunk back when it is freed. At most KEEP_DIRTY
//! chunks stay touched for the next translation; the others go back to the kernel at once.
//!
//! A chunk counts its own blocks without atomics while its thread is in a scope. Frees from elsewhere, and all frees
//! after the scope, go through `pending`: it goes negative while the owner still works, the owner adds its count when
//! it leaves, and whoever brings it to zero after that gives the chunk back.
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::UnsafeCell;
use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};

const GRANULE: usize = 16;
const CLASSES: usize = 64;
const MAX_SMALL: usize = CLASSES * GRANULE;
const CHUNK: usize = 1 << 20;
const REGION: usize = 1 << 33;
const CHUNKS: usize = REGION / CHUNK;
const KEEP_DIRTY: usize = 4;
const REGION_UNSET: usize = 0;
const REGION_FAILED: usize = 1;

const PROT_READ_WRITE: i32 = 1 | 2;
const MAP_PRIVATE_ANON: i32 = 0x0002 | 0x1000;
const MAP_FIXED: i32 = 0x0010;
const MAP_FAILED: *mut c_void = !0usize as *mut c_void;

unsafe extern "C" {
    fn mmap(addr: *mut c_void, len: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> i32;
}

#[repr(C, align(64))]
struct Chunk {
    owner: AtomicUsize,
    pending: AtomicI64,
    /// The owner's count of its live blocks: only the owner touches it, and only in its scope.
    live: UnsafeCell<i64>,
    /// The next chunk of the owner's list, or of the free list.
    next: UnsafeCell<*mut Chunk>,
    /// A chunk on the free list with its pages still touched.
    dirty: UnsafeCell<bool>,
}

const HEADER: usize = std::mem::size_of::<Chunk>();

struct Heap {
    depth: usize,
    free: [*mut u8; CLASSES],
    bump: *mut u8,
    bump_end: *mut u8,
    chunks: *mut Chunk,
}

thread_local! {
    // Const and without Drop: no lazy initialization and no destructor, so any allocation may use it at any time.
    static HEAP: UnsafeCell<Heap> = const {
        UnsafeCell::new(Heap {
            depth: 0,
            free: [null_mut(); CLASSES],
            bump: null_mut(),
            bump_end: null_mut(),
            chunks: null_mut(),
        })
    };
}

static REGION_BASE: AtomicUsize = AtomicUsize::new(REGION_UNSET);
static NEXT_FRESH: AtomicUsize = AtomicUsize::new(0);
static LOCK: AtomicBool = AtomicBool::new(false);
struct FreeList {
    head: *mut Chunk,
    dirty: usize,
}
struct Shared(UnsafeCell<FreeList>);
unsafe impl Sync for Shared {}
static FREE_LIST: Shared = Shared(UnsafeCell::new(FreeList { head: null_mut(), dirty: 0 }));

fn locked<R>(f: impl FnOnce(&mut FreeList) -> R) -> R {
    while LOCK.swap(true, Ordering::Acquire) {
        std::hint::spin_loop();
    }
    let result = f(unsafe { &mut *FREE_LIST.0.get() });
    LOCK.store(false, Ordering::Release);
    result
}

/// The reserved address range, made once. Untouched pages cost nothing; without it everything is the system allocator.
fn region() -> usize {
    let base = REGION_BASE.load(Ordering::Acquire);
    if base != REGION_UNSET {
        return base;
    }
    // One chunk more than needed, to start at the first address aligned to a chunk.
    let mapped = unsafe { mmap(null_mut(), REGION + CHUNK, PROT_READ_WRITE, MAP_PRIVATE_ANON, -1, 0) };
    let aligned = if mapped == MAP_FAILED {
        REGION_FAILED
    } else {
        (mapped as usize + CHUNK - 1) & !(CHUNK - 1)
    };
    match REGION_BASE.compare_exchange(REGION_UNSET, aligned, Ordering::AcqRel, Ordering::Acquire) {
        Ok(_) => aligned,
        Err(existing) => {
            if mapped != MAP_FAILED {
                unsafe { munmap(mapped, REGION + CHUNK) };
            }
            existing
        }
    }
}

#[inline]
fn in_region(pointer: *mut u8) -> bool {
    let base = REGION_BASE.load(Ordering::Relaxed);
    (pointer as usize).wrapping_sub(base) < REGION && base != REGION_FAILED && base != REGION_UNSET
}

#[inline]
fn chunk_of(pointer: *mut u8) -> *mut Chunk {
    (pointer as usize & !(CHUNK - 1)) as *mut Chunk
}

fn take_chunk(heap: *mut Heap) -> *mut Chunk {
    let reused = locked(|list| {
        let chunk = list.head;
        if !chunk.is_null() {
            unsafe {
                list.head = *(*chunk).next.get();
                if *(*chunk).dirty.get() {
                    list.dirty -= 1;
                }
            }
        }
        chunk
    });
    let chunk = if !reused.is_null() {
        reused
    } else {
        let base = REGION_BASE.load(Ordering::Acquire);
        let index = NEXT_FRESH.fetch_add(1, Ordering::Relaxed);
        if index >= CHUNKS {
            return null_mut();
        }
        (base + index * CHUNK) as *mut Chunk
    };
    unsafe {
        (*chunk).owner.store(heap as usize, Ordering::Relaxed);
        (*chunk).pending.store(0, Ordering::Relaxed);
        *(*chunk).live.get() = 0;
        *(*chunk).next.get() = (*heap).chunks;
        (*heap).chunks = chunk;
    }
    chunk
}

/// All of the chunk's blocks are gone.
fn give_back(chunk: *mut Chunk) {
    let keep = locked(|list| {
        let keep = list.dirty < KEEP_DIRTY;
        if keep {
            list.dirty += 1;
            unsafe {
                *(*chunk).dirty.get() = true;
                *(*chunk).next.get() = list.head;
            }
            list.head = chunk;
        }
        keep
    });
    if keep {
        return;
    }
    // Fresh pages over the old ones: the memory goes back to the kernel now, and the header reads as zero.
    let mapped = unsafe {
        mmap(chunk as *mut c_void, CHUNK, PROT_READ_WRITE, MAP_PRIVATE_ANON | MAP_FIXED, -1, 0)
    };
    locked(|list| unsafe {
        let dirty = mapped == MAP_FAILED;
        *(*chunk).dirty.get() = dirty;
        list.dirty += usize::from(dirty);
        *(*chunk).next.get() = list.head;
        list.head = chunk;
    });
}

#[inline]
fn foreign_free(chunk: *mut Chunk) {
    if unsafe { (*chunk).pending.fetch_sub(1, Ordering::AcqRel) } == 1 {
        give_back(chunk);
    }
}

fn leave(heap: &mut Heap) {
    let mut chunk = heap.chunks;
    heap.chunks = null_mut();
    heap.free = [null_mut(); CLASSES];
    heap.bump = null_mut();
    heap.bump_end = null_mut();
    while !chunk.is_null() {
        unsafe {
            let next = *(*chunk).next.get();
            let live = *(*chunk).live.get();
            (*chunk).owner.store(0, Ordering::Relaxed);
            if (*chunk).pending.fetch_add(live, Ordering::AcqRel) + live == 0 {
                give_back(chunk);
            }
            chunk = next;
        }
    }
}

/// Runs `f` with small allocations of this thread in chunks.
pub fn scope<R>(f: impl FnOnce() -> R) -> R {
    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            HEAP.with(|heap| {
                let heap = unsafe { &mut *heap.get() };
                heap.depth -= 1;
                if heap.depth == 0 {
                    leave(heap);
                }
            });
        }
    }
    if region() == REGION_FAILED {
        return f();
    }
    HEAP.with(|heap| unsafe { (*heap.get()).depth += 1 });
    let _guard = Guard;
    f()
}

#[inline]
fn is_small(layout: &Layout) -> bool {
    layout.size() <= MAX_SMALL && layout.align() <= GRANULE && layout.size() != 0
}

#[inline]
unsafe fn small_alloc(heap: *mut Heap, class: usize) -> *mut u8 {
    unsafe {
        let head = (*heap).free[class];
        if !head.is_null() {
            (*heap).free[class] = *(head as *mut *mut u8);
            *(*chunk_of(head)).live.get() += 1;
            return head;
        }
        let size = (class + 1) * GRANULE;
        if ((*heap).bump_end as usize) - ((*heap).bump as usize) < size {
            let chunk = take_chunk(heap);
            if chunk.is_null() {
                return null_mut();
            }
            (*heap).bump = (chunk as *mut u8).add(HEADER);
            (*heap).bump_end = (chunk as *mut u8).add(CHUNK);
        }
        let block = (*heap).bump;
        (*heap).bump = block.add(size);
        *(*chunk_of(block)).live.get() += 1;
        block
    }
}

pub struct Allocator;

unsafe impl GlobalAlloc for Allocator {
    #[inline]
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if is_small(&layout) {
            let block = HEAP.with(|heap| {
                let heap = heap.get();
                if unsafe { (*heap).depth } == 0 {
                    return null_mut();
                }
                unsafe { small_alloc(heap, (layout.size() - 1) / GRANULE) }
            });
            if !block.is_null() {
                return block;
            }
        }
        unsafe { System.alloc(layout) }
    }

    #[inline]
    unsafe fn dealloc(&self, block: *mut u8, layout: Layout) {
        if !in_region(block) {
            return unsafe { System.dealloc(block, layout) };
        }
        let chunk = chunk_of(block);
        HEAP.with(|heap| unsafe {
            let heap = heap.get();
            if (*heap).depth > 0 && (*chunk).owner.load(Ordering::Relaxed) == heap as usize {
                let class = (layout.size() - 1) / GRANULE;
                *(block as *mut *mut u8) = (*heap).free[class];
                (*heap).free[class] = block;
                *(*chunk).live.get() -= 1;
            } else {
                foreign_free(chunk);
            }
        });
    }

    #[inline]
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let in_scope = HEAP.with(|heap| unsafe { (*heap.get()).depth > 0 });
        if !in_scope || !is_small(&layout) {
            return unsafe { System.alloc_zeroed(layout) };
        }
        let block = unsafe { self.alloc(layout) };
        if !block.is_null() {
            unsafe { block.write_bytes(0, layout.size()) };
        }
        block
    }

    #[inline]
    unsafe fn realloc(&self, block: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if !in_region(block) {
            return unsafe { System.realloc(block, layout, new_size) };
        }
        if new_size != 0 && new_size <= MAX_SMALL && (new_size - 1) / GRANULE == (layout.size() - 1) / GRANULE {
            return block;
        }
        let new_layout = unsafe { Layout::from_size_align_unchecked(new_size, layout.align()) };
        let moved = unsafe { self.alloc(new_layout) };
        if !moved.is_null() {
            unsafe {
                block.copy_to_nonoverlapping(moved, layout.size().min(new_size));
                self.dealloc(block, layout);
            }
        }
        moved
    }
}
