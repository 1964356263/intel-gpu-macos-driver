// SPDX-License-Identifier: MIT
/* Kernel ABI between NMXAccel.kext and IntelXe.kext for VRAM-shared IOSurfaces (gpuperf phase 1; design in
 * src/nullmoth-gpuperf/DESIGN-iosurface-vram.md). Both kexts include this file; a version mismatch is refused.
 *
 *   IntelXe -> NMXAccel (callPlatformFunction on the accelerator):
 *     "nmxSurfVram"   NMXSurfVramReq: the IOSurface's family resource for `task` (IOSurfaceRoot::lookupSurface, so a task
 *                     reaches only surfaces it can already see), its vidmem wired with an IntelXe registry backing (create)
 *                     or only looked up (import); entry returned with one reference for the caller.
 *     "nmxSurfDirty"  NMXSurfVramReq (sid, plane, task, flags & NMX_SV_TRYLOCK): the GPU copy is newer than the pages -
 *                     the family's per-plane valid bits are set so a CPU lock pages it off. With NMX_SV_DEMOTE_OK a
 *                     surface NMXAccel has seen paged off again and again is answered NMX_SV_DEMOTED, unmarked.
 *   NMXAccel -> IntelXe (callPlatformFunction on IntelXe):
 *     "intelxeSurfAdopt"   IntelXeSurfAdopt: from inside NVVidMemory::allocPhysical (family lock held): the registry entry of
 *                       (sid, plane), made with `size` bytes of pinned VRAM if absent; one reference for the vidmem.
 *     "intelxeSurfRef"     IntelXeSurfAdopt (entry): one more reference.
 *     "intelxeSurfRelease" IntelXeSurfAdopt (entry): drop one reference (the BO lives on while client handles hold it).
 *     "intelxeSurfWaitWriters" IntelXeSurfWait (rb7g): wait for the surface's write fences (CPU lock of a demoted surface).
 *     "intelxeSurfCopy"    IntelXeSurfCopy: copy-engine copy between the entry's VRAM and `md` (the IOSurface's pages), after
 *                       the surface's GPU writers (and, towards VRAM, readers) have finished. Waits; bounded.
 * Lock order: NMXAccel's family lock -> IntelXe's registry lock / resource locks. IntelXe never calls NMXAccel holding a
 * client lock or the registry lock.
 */
#pragma once
#include <stdint.h>

#define INTELXE_SV_KABI_VERSION 1u

#define NMX_SV_CREATE   (1u << 0)   /* nmxSurfVram: make the VRAM backing if the surface has none */
#define NMX_SV_TRYLOCK  (1u << 1)   /* nmxSurfDirty: give up instead of waiting for the family lock */
#define NMX_SV_DEMOTE_OK (1u << 2)  /* nmxSurfDirty: the caller copies out itself when told NMX_SV_DEMOTED (rb7f) */

enum { NMX_SV_OK = 0, NMX_SV_OFF = 1, NMX_SV_NO_SURFACE = 2, NMX_SV_NO_CACHE = 3, NMX_SV_NO_VRAM = 4,
       NMX_SV_NOT_FOUND = 5, NMX_SV_BUSY = 6, NMX_SV_OTHER_BACKING = 7, NMX_SV_BAD = 8,
       NMX_SV_DEMOTED = 9 /* nmxSurfDirty with NMX_SV_DEMOTE_OK: CPU-read surface, not marked (caller copies out) */ };

struct NMXSurfVramReq {
	uint32_t version;   /* INTELXE_SV_KABI_VERSION */
	uint32_t sid, plane, flags;
	void *task;
	uint64_t size;      /* in: bytes the caller needs; out: bytes of the backing */
	void *entry;        /* out: registry entry (referenced) */
	uint32_t status;    /* out: NMX_SV_* */
	uint32_t gen;       /* out: the entry's generation */
};

struct IntelXeSurfAdopt {
	uint32_t version;
	uint32_t sid, plane;
	uint32_t pad;
	uint64_t size;      /* in: bytes */
	void *entry;        /* in (Ref/Release) / out (Adopt) */
	uint64_t bytes;     /* out */
	uint64_t cookie;    /* out: unique per backing (NVVidMemory::fAllocationCookie) */
};

/* "intelxeSurfWaitWriters" (rb7g): NMXAccel's CPU-lock path for a surface whose pages its GPU writers fill themselves (a
 * demoted backing): wait until the surface's WRITE fences (SURFACE_FENCE_ATTACH registry) have signaled, as Apple's
 * IOSurfaceLock waits for the GPU writes of a surface. Bounded by timeoutMs (0: 1000); err ETIMEDOUT then. */
struct IntelXeSurfWait {
	uint32_t version;   /* INTELXE_SV_KABI_VERSION */
	uint32_t sid;
	uint32_t timeoutMs;
	int32_t err;        /* out */
	uint32_t fences;    /* out: unsignaled write fences found */
	uint32_t pad;
	uint64_t usec;      /* out: time waited */
};

struct IntelXeSurfCopy {
	uint32_t version;
	uint32_t toSys;     /* 1: VRAM -> pages (page-off), 0: pages -> VRAM (page-on) */
	void *entry;
	void *md;           /* IOMemoryDescriptor * of the surface's pages, prepared by the caller */
	uint64_t len;       /* bytes from offset 0 (page multiple) */
	uint32_t timeoutMs;
	int32_t err;        /* out: errno-style, 0 ok, ETIMEDOUT */
	uint64_t usec;      /* out */
};

/* gpuperf phase 4. NMXAccel -> IntelXe:
 *   "intelxeCopyPinToPages" IntelXePinCopy: the pinned scan-out VRAM (a xeScanoutPin cookie, held) -> md's pages, len bytes from
 *                        offset 0 (same pitch on both sides: the caller checks), on the copy engine, waited for.
 *   "intelxePinGet" / "intelxePinPut" p1 = the pin cookie: one more / one less reference on its BO (the copy outlives the
 *                        scan-out lock it was found under). */
struct IntelXePinCopy {
	uint32_t version;
	uint32_t timeoutMs;
	void *pin;
	void *md;
	uint64_t len;
	int32_t err;        /* out */
	uint32_t pad;
	uint64_t usec;      /* out */
};
