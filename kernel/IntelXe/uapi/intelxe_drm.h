// SPDX-License-Identifier: MIT
/* IntelXe.kext extensions to the xe uAPI (include after drm.h / xe_drm.h). Same transport as the xe ioctls: xemac_ioctl()
 * passes the request through external method 0 unchanged.
 *
 * Implicit synchronization of IOSurfaces on the GPU, the way Linux dma-buf implicit fencing works (drivers/dma-buf/
 * dma-resv.c): the kernel keeps, per IOSurface ID, the fences of the last jobs that wrote it and of the jobs that read
 * it since, each tagged with its usage (WRITE or READ, dma_resv_usage). A producer attaches its job's fence after the
 * submit; a consumer imports the fences it must wait for into one of its own timeline syncobjs and passes that point as
 * an in-fence of its exec, so the wait happens in the kernel's job queue, not on the CPU.
 *
 * Capability: DRM_IOCTL_GET_CAP with capability INTELXE_CAP_SURFACE_FENCES returns value 1 when these ioctls exist.
 *
 * Registry (dma_resv_add_fence): per surface at most INTELXE_SURFACE_FENCE_MAX_WRITE write and INTELXE_SURFACE_FENCE_MAX_READ
 * read fences. Adding a fence replaces, in place, an entry that has signaled or that comes from the same exec queue
 * with an equal or weaker usage (READ is weaker than WRITE) and an earlier or equal seqno: a WRITE from queue Q
 * supersedes Q's earlier reads and writes, a READ supersedes Q's earlier reads. Signaled fences are pruned whenever a
 * surface is touched; a surface whose fences have all signaled is dropped. The table holds 1024 surfaces; when it is
 * full only surfaces whose fences have all signaled are evicted (least recently used first), otherwise ENOSPC.
 * The fences of a banned exec queue read as signaled (its pending jobs are cancelled), so a hung or killed client cannot
 * stall its consumers past the job watchdog (debug.intelxe.job_timeout_ms).
 */
#pragma once
/* needs drm.h (DRM_IOW, __u32) included first: the kext uses uapi/drm.h, xemac Mesa's include/drm-uapi/drm.h */

#if defined(__cplusplus)
extern "C" {
#endif

#define INTELXE_CAP_SURFACE_FENCES 0xb5800001ull

#define INTELXE_SURFACE_FENCE_MAX_WRITE 4
#define INTELXE_SURFACE_FENCE_MAX_READ 8

/* drm_intelxe_surface_fence_attach.flags: how the job behind the fence uses the surface (exactly one) */
#define INTELXE_SURFACE_FENCE_WRITE (1u << 0)
#define INTELXE_SURFACE_FENCE_READ (1u << 1)

/* drm_intelxe_surface_fence_import.flags / drm_intelxe_surface_fence_wait.flags: what the caller is about to do (exactly one).
 * READER: it will read the surface, so it waits for the write fences only (dma_resv_usage WRITE).
 * WRITER: it will write the surface, so it waits for the write and the read fences (dma_resv_usage READ). */
#define INTELXE_SURFACE_FENCE_READER (1u << 0)
#define INTELXE_SURFACE_FENCE_WRITER (1u << 1)

/* Record the fence of `syncobj` at `point` (0 for a binary syncobj; for a timeline, the fences of every point up to it,
 * as a wait on that point would) as a `flags` user of surface `surface_id`. A point whose fence has already signaled
 * records nothing. EAGAIN: the point has no fence yet (not submitted). ENOENT: no such syncobj. ENOSPC: the surface has
 * no free write/read entry, or the table is full of surfaces with live fences. EINVAL: bad flags or surface_id 0. */
struct drm_intelxe_surface_fence_attach {
	__u32 surface_id;
	__u32 syncobj;
	__u64 point;
	__u32 flags;
	__u32 pad;   /* must be 0 */
};

/* Add every unsignaled fence of surface `surface_id` that `flags` asks for as consecutive new points of the caller's
 * timeline syncobj `syncobj`, after its last submitted point: count_out fences at points P+1 .. P+count_out, and
 * point_out = P + count_out. A wait on point_out (an exec in-fence, SYNCOBJ_TIMELINE_WAIT) completes when all of them
 * and every earlier point of that timeline have signaled, so use a timeline that holds only these imports. count_out 0
 * (nothing to wait for): nothing is added and point_out is 0. ENOENT: no such syncobj. EINVAL: bad flags. */
struct drm_intelxe_surface_fence_import {
	__u32 surface_id;
	__u32 syncobj;
	__u64 point_out;
	__u32 flags;
	__u32 count_out;
};

/* Wait on the CPU for the fences of surface `surface_id` that `flags` asks for (those present at the call).
 * timeout_ns: absolute, CLOCK_UPTIME_RAW nanoseconds (mach_absolute_time); 0 polls. ETIME on timeout. */
struct drm_intelxe_surface_fence_wait {
	__u32 surface_id;
	__u32 flags;
	__s64 timeout_ns;
};

#define DRM_INTELXE_SURFACE_FENCE_ATTACH 0x50
#define DRM_INTELXE_SURFACE_FENCE_IMPORT 0x51
#define DRM_INTELXE_SURFACE_FENCE_WAIT 0x52

#define DRM_IOCTL_INTELXE_SURFACE_FENCE_ATTACH \
	DRM_IOW(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_FENCE_ATTACH, struct drm_intelxe_surface_fence_attach)
#define DRM_IOCTL_INTELXE_SURFACE_FENCE_IMPORT \
	DRM_IOWR(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_FENCE_IMPORT, struct drm_intelxe_surface_fence_import)
#define DRM_IOCTL_INTELXE_SURFACE_FENCE_WAIT \
	DRM_IOW(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_FENCE_WAIT, struct drm_intelxe_surface_fence_wait)

/* VRAM-shared IOSurfaces (gpuperf phase 1, DESIGN-iosurface-vram.md). DRM_IOCTL_GET_CAP INTELXE_CAP_SURFACE_VRAM returns
 * debug.intelxe.surfvram (0 = off: the ioctls answer EOPNOTSUPP; 1 = apps; 2 = apps and WindowServer).
 *
 * SURFACE_VRAM: a GEM handle in the caller's client for the one VRAM backing of IOSurface `surface_id` plane `plane`, shared
 * by every process that imports it (linear, uncompressed, pinned, never CPU-mapped: the CPU sees the IOSurface's own pages,
 * filled by a copy-engine page-off when a CPU lock finds the GPU copy newer). INTELXE_SURFACE_VRAM_CREATE makes the backing if
 * the surface has none (size: the bytes the caller needs; the backing covers the surface's whole allocation); without it
 * ENOENT when none exists. The caller must be able to look the surface up (IOSurfaceLookup semantics): ENOENT otherwise.
 * size_out: the backing's bytes; gen: its generation (changes when a surface gets a new backing).
 * EBUSY: the surface has another (system memory) backing in the accelerator family; ENOSPC: over debug.intelxe.surfvram_mb.
 *
 * SURFACE_DIRTY: after the caller's job that wrote the backing was submitted (and its fence attached with
 * SURFACE_FENCE_ATTACH WRITE): the GPU copy is newer than the pages, so a CPU lock pages it off first. */
#define INTELXE_CAP_SURFACE_VRAM 0xb5800002ull
#define INTELXE_SURFACE_VRAM_CREATE (1u << 0)
/* INTELXE_SURFACE_VRAM_SAME_HANDLE (rb7m): when this client already holds a handle for the backing, that handle comes back
 * (no new one), as DRM_IOCTL_PRIME_FD_TO_HANDLE returns the existing handle for a dma-buf the file has imported before
 * (drm_gem_prime_fd_to_handle -> drm_prime_lookup_buf_handle): one handle per object per client, so a userspace BO cache
 * keyed by handle (Mesa ANV's anv_device_lookup_bo) shares one BO and one VA between the imports. The caller owns the
 * handle as it owns a PRIME handle: it closes it once, when its last user goes. Older kernels answer EINVAL: retry
 * without it. */
#define INTELXE_SURFACE_VRAM_SAME_HANDLE (1u << 1)
#define INTELXE_SURFACE_DIRTY_TRYLOCK (1u << 0)
/* INTELXE_SURFACE_DIRTY_DEMOTE_OK (rb7f): the caller can stop sharing the backing for its writes. When the CPU keeps
 * reading the surface (repeated page-offs, NMXAccel decides), the kernel refuses the mark with ETIME instead of making
 * the VRAM copy newest; the caller then writes the surface's own pages (its copy-out path) from that write on, so CPU
 * locks find them current without a page-off - the system-memory placement xe/TTM moves a CPU-faulted BO to. A caller
 * that marks without this flag is never refused this way (and such a mark puts the surface back on the shared path).
 * Older kernels answer EINVAL to the flag: retry without it. */
#define INTELXE_SURFACE_DIRTY_DEMOTE_OK (1u << 1)
struct drm_intelxe_surface_vram {
	__u32 surface_id;
	__u32 plane;
	__u64 size;
	__u32 flags;
	__u32 handle;      /* out */
	__u64 size_out;    /* out */
	__u32 gen;         /* out */
	__u32 pad;         /* must be 0 */
};
struct drm_intelxe_surface_dirty {
	__u32 surface_id;
	__u32 plane;
	__u32 flags;
	__u32 pad;
};
#define DRM_INTELXE_SURFACE_VRAM 0x53
#define DRM_INTELXE_SURFACE_DIRTY 0x54
#define DRM_IOCTL_INTELXE_SURFACE_VRAM DRM_IOWR(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_VRAM, struct drm_intelxe_surface_vram)
#define DRM_IOCTL_INTELXE_SURFACE_DIRTY DRM_IOW(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_DIRTY, struct drm_intelxe_surface_dirty)

/* Tiled VRAM backings (Tile4 swapchains). SURFACE_VRAM2 is SURFACE_VRAM plus the layout of the backing, the way a Linux
 * framebuffer carries a DRM format modifier and a pitch next to its BO (drm_mode_fb_cmd2):
 *   modifier      DRM_FORMAT_MOD_LINEAR (0) or I915_FORMAT_MOD_4_TILED (fourcc_mod_code(INTEL, 9)), uncompressed: the
 *                 backing stays noComp, so no CCS modifier;
 *   pitch         bytes per row of that layout (Tile4: a multiple of 128, the tile's width in bytes);
 *   cpp, width, height   the image in it (cpp 4 or 8; the Tile4 rows it uses, rounded up to 32, fit in the backing);
 *   linear_pitch  bytes per row of the IOSurface's pages (its bytesPerRow).
 * With INTELXE_SURFACE_VRAM_CREATE the caller states the layout it renders with: the first creator records it, a later
 * CREATE with another layout gets EBUSY. Without CREATE the layout is an output (an importer learns how to read it).
 * The CPU never sees tiled bytes: a CPU lock's page-off of a Tile4 backing detiles it into the pages on the copy engine
 * (XY_BLOCK_COPY_BLT Tile4 -> linear), a page-on tiles the pages back. SURFACE_VRAM (the old call) refuses a backing
 * that is not linear with EBUSY, so an importer that does not know layouts falls back to its own copy of the pages.
 * DRM_IOCTL_GET_CAP INTELXE_CAP_SURFACE_VRAM_LAYOUT: 1 once WindowServer imports with SURFACE_VRAM2 (its Metal plugin reads
 * tiled backings), 0 otherwise (no WindowServer client yet, or one that only knows linear): creators render linear then. */
#define INTELXE_CAP_SURFACE_VRAM_LAYOUT 0xb5800003ull

/* Status page. DRM_IOCTL_GET_CAP INTELXE_CAP_STATUS_PAGE returns the IOConnectMapMemory64 memory type of a read-only page
 * shared with every client (0: none). Its first u64 is the ban epoch: it moves after any exec queue is banned (a hang,
 * a GT reset), before the ban is visible to DRM_IOCTL_XE_EXEC_QUEUE_GET_PROPERTY. A client that saw a queue unbanned
 * at epoch E knows it is still unbanned while the epoch reads E, without the ioctl (on macOS an IOKit round trip; Mesa
 * asks after every vkWaitSemaphores / vkWaitForFences, vk_device_check_status). */
#define INTELXE_CAP_STATUS_PAGE 0xb5800004ull
struct intelxe_status_page {
	volatile __u64 ban_epoch;
};
#ifndef DRM_FORMAT_MOD_LINEAR
#define DRM_FORMAT_MOD_LINEAR 0ull
#endif
#ifndef I915_FORMAT_MOD_4_TILED
#define I915_FORMAT_MOD_4_TILED ((0x01ull << 56) | 9ull)
#endif
struct drm_intelxe_surface_vram2 {
	__u32 surface_id;
	__u32 plane;
	__u64 size;
	__u32 flags;
	__u32 handle;      /* out */
	__u64 size_out;    /* out */
	__u32 gen;         /* out */
	__u32 pad;         /* must be 0 */
	__u64 modifier;    /* in with CREATE, out */
	__u32 pitch;       /* in with CREATE, out */
	__u32 cpp;         /* in with CREATE, out */
	__u32 width;       /* in with CREATE, out */
	__u32 height;      /* in with CREATE, out */
	__u32 linear_pitch;/* in with CREATE, out */
	__u32 pad2;        /* must be 0 */
};
#define DRM_INTELXE_SURFACE_VRAM2 0x55
#define DRM_IOCTL_INTELXE_SURFACE_VRAM2 DRM_IOWR(DRM_COMMAND_BASE + DRM_INTELXE_SURFACE_VRAM2, struct drm_intelxe_surface_vram2)

/* Object file descriptors (fd sharing, docs/reports/b580-fd-sharing-20261103.md, stages 1-2): what Linux gives as
 * DRM syncobj fds, sync_files and PRIME dma-bufs. The kext cannot create a file descriptor, so every such fd is an open
 * of the clone device INTELXE_OBJ_DEVICE (each open is a new minor, i.e. one kernel object per fd): for
 * DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD and DRM_IOCTL_PRIME_HANDLE_TO_FD the caller (xemac) opens INTELXE_OBJ_DEVICE itself,
 * O_RDWR (| O_CLOEXEC for DRM_CLOEXEC; syncobj fds always), and passes that fd IN args->fd; the kext binds the object
 * to that minor (EBUSY: bound already; EBADF/EINVAL: not an unbound minor of INTELXE_OBJ_DEVICE in the caller's fd table)
 * and leaves args->fd as it was. Everything else is Linux's uAPI unchanged:
 *  - SYNCOBJ_HANDLE_TO_FD flags 0: the fd holds a reference to the syncobj itself (later signals and resets are seen by
 *    every holder); SYNCOBJ_FD_TO_HANDLE flags 0 gives a new handle to that syncobj in the caller's client.
 *  - SYNCOBJ_HANDLE_TO_FD EXPORT_SYNC_FILE: the fd holds the syncobj's current fence (EINVAL when it has none, as
 *    drm_syncobj_find_fence); SYNCOBJ_FD_TO_HANDLE IMPORT_SYNC_FILE replaces args->handle's fence with the file's.
 *  - PRIME_HANDLE_TO_FD (flags DRM_CLOEXEC | DRM_RDWR only): the fd holds a reference to the BO (EPERM for a BO
 *    created VM-private, as xe_gem_prime_export); PRIME_FD_TO_HANDLE returns the handle the caller already has for
 *    that BO, otherwise a new one (one handle per object per client, drm_gem_prime_fd_to_handle).
 *  - The object lives until its last handle and the last close of its fd (dup, fork, SCM_RIGHTS and XPC carry the
 *    same open file, so the minor's d_close is the last close).
 * Imports take an fd of the caller: one that is not open is EBADF for PRIME_FD_TO_HANDLE and OBJ_INFO (dma_buf_get) but
 * EINVAL for SYNCOBJ_FD_TO_HANDLE (drm_syncobj_fd_to_handle, sync_file_get_fence); an open fd that is not this kind of
 * object is EINVAL. A sync file holds the unsignaled fences of the syncobj when it was exported (a timeline: every
 * point's), one per queue; IMPORT_SYNC_FILE puts them all in place of the binary syncobj's fence.
 * IntelXe.kext (rb7t): all of this only while sysctl debug.intelxe.fds is 1 (boot-arg intelxe_fds=1); /dev/intelxeobj exists from the
 * first time it is; debug.intelxe.fd_stats counts the minors and the objects behind them.
 * Not supported: mmap, poll/select and ioctls on the object fd itself, lseek (a character device: SEEK_END is 0).
 * DRM_IOCTL_INTELXE_OBJ_INFO answers what an fd holds and the BO size Linux reads with lseek(dmabuf, 0, SEEK_END); it goes
 * through the device's IOUserClient like every other ioctl, never through the object fd.
 *
 * DRM_IOCTL_GET_CAP INTELXE_CAP_FD_OBJECTS = 1 when the syncobj fds, sync files and OBJ_INFO exist; DRM_CAP_PRIME then
 * reports DRM_PRIME_CAP_IMPORT | DRM_PRIME_CAP_EXPORT when BO fds exist too. A kernel without them returns EINVAL /
 * 0 for the caps and ENOTTY for the four ioctls (the behaviour before this). */
#define INTELXE_OBJ_DEVICE "/dev/intelxeobj"
#define INTELXE_CAP_FD_OBJECTS 0xb5800005ull
#define INTELXE_OBJ_KIND_NONE 0      /* an open of INTELXE_OBJ_DEVICE nothing was bound to yet */
#define INTELXE_OBJ_KIND_BO 1
#define INTELXE_OBJ_KIND_SYNCOBJ 2
#define INTELXE_OBJ_KIND_SYNC_FILE 3
#define INTELXE_OBJ_SIGNALED (1u << 0) /* status of a SYNC_FILE: its fence has signaled */
struct drm_intelxe_obj_info {
	__s32 fd;      /* in: an fd of the caller */
	__u32 kind;    /* out: INTELXE_OBJ_KIND_* */
	__u64 size;    /* out: the BO's size for KIND_BO, else 0 */
	__u32 status;  /* out: INTELXE_OBJ_SIGNALED for a signaled SYNC_FILE */
	__u32 pad;     /* must be 0 */
};
#define DRM_INTELXE_OBJ_INFO 0x56
#define DRM_IOCTL_INTELXE_OBJ_INFO DRM_IOWR(DRM_COMMAND_BASE + DRM_INTELXE_OBJ_INFO, struct drm_intelxe_obj_info)

#if defined(__cplusplus)
}
#endif
