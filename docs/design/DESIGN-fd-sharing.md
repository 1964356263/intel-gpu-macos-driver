# Vulkan fd sharing on macOS without real dma-buf/sync_file fds (design, 2026-10-30)

Goal: `VK_KHR_external_memory_fd` (+ `VK_EXT_external_memory_dma_buf`), `VK_KHR_external_semaphore_fd` and
`VK_KHR_external_fence_fd` on ANV over IntelXe.kext, **across processes**: Wine's shared resources (D3D11/12 shared
handles, the DXGI swapchain between the game and the compositor process) map `*_win32` handles onto the host's fd
extensions, and wineserver hands the fds from process to process with `SCM_RIGHTS`. Today xemac answers
`PRIME_*` and `SYNCOBJ_*_FD` with ENOTTY.

XeGfx's answer (HOW.md "Fences without file descriptors") makes the stand-ins in userspace (the read end of a pipe,
told apart by inode) and keeps the kernel side per DRM file, so it cannot share between processes, cannot `poll()`
a sync_file and cannot merge. Wine needs the cross-process part, so the kernel has to recognise the stand-in itself.

## 1. The stand-in: an unlinked file the kernel can identify

A kext cannot make file descriptors, but it can look at one the caller passes in. With public KPIs only
(com.apple.kpi.bsd: `file_vnode_withvid`, `file_drop`, `vnode_vid`, `vnode_getwithvid`, `vnode_isinuse`,
`vnode_put`) the stand-in is a regular file nobody can reach by name:

- Export (xemac): `mkstemp()` in the process's temporary directory (sandboxed processes have their own), `unlink()` at
  once, `ftruncate()` to the BO size (sparse: no disk space; `lseek(fd, 0, SEEK_END)`, which Mesa and libdrm use to
  read a dma-buf's size, then just works), and the fd passed in the export ioctl. The kext resolves it
  (`file_vnode_withvid` -> vnode + vid) and records **(vnode pointer, vid)** as the key of a new export entry.
- Import (any process; the fd came by dup, fork or `SCM_RIGHTS`, it is the same open file): the kext resolves the fd
  and compares (vnode, vid). Not found -> EINVAL, as Linux answers an fd that is not a dma-buf. The pair cannot be
  forged or guessed: only a holder of the fd can present that vnode, and a vnode recycled for another file has a new
  vid, so a stale pointer never matches.
- Lifetime, as a dma-buf (alive while an fd or an import holds it): the entry must go when the last fd is closed. An
  unlinked file's vnode is inactivated and reclaimed on its last close (its vid changes). The kext checks its entries
  on every export/import and from a timer (every few seconds while entries exist): `vnode_getwithvid(vp, vid)` fails
  (recycled) or `vnode_isinuse(vp, 0)` is false (no open file left) -> the entry and its BO reference go.
- Not possible this way (and not needed by Vulkan or Wine, which wait through vkWait*/syncobjs): `poll()` waiting for
  a sync_file to signal (a regular file always polls readable). XeGfx cannot either.

Rejected: an AF_UNIX socketpair (`file_socket` is public, but keeping the kext's end alive and being told of the
peer's close needs `sock_retain` / `sock_setupcall`, which are KERNEL_PRIVATE); a pipe (no KPI resolves a pipe fd);
mach ports or IOSurface-style global ids (Wine moves fds, not ports).

## 2. Kernel objects (xe_core.cpp)

```
struct XeExport { vnode_t vp; uint32_t vid; uint8_t kind; XeBo *bo; XeFence *f; uint32_t n; ... };   // key: (vp, vid)
```

- **dma-buf entry**: holds a BO reference (`boGet`). Import gives the caller a new GEM handle on the *same* `XeBo` in
  its client (`c->bos.add`, `boGet`), as `SURFACE_VRAM` already does for IOSurface backings, so binding, CPU maps
  (one cookie map per client, rb2's map-holds-BO rule) and freeing follow the BO refcount. The BO is marked
  `shared`: compressed PATs are refused for it from then on (Linux, xe_vm_bind_ioctl_validate_bo: no compression for
  imported dma-bufs; a CPU or another process reading it raw must see plain data) and it never moves
  (`noMove`, like a scan-out pin: another process may hold its pages mapped).
- **sync_file entry** (its stand-in file has size 0): a copy of the fences of a syncobj point at export time. Fences here are already device-global
  (slot, generation, seqno), valid in any client, so a copy is all a sync_file needs; `fenceSignaled()` and the ban
  floor (rb2) apply unchanged. Import: `syncReplace()` of the target syncobj (Linux `IMPORT_SYNC_FILE` = temporary
  payload) or a timeline point (`SYNCOBJ_FD_TO_HANDLE` with `IMPORT_SYNC_FILE` and a point).
- **syncobj fd (opaque)**: `SYNCOBJ_HANDLE_TO_FD` without the sync_file flag shares the syncobj itself (the same
  `XeSyncobj` in two clients). That needs a refcount on `XeSyncobj` and its lock moved from the client lock to its own
  (today a syncobj belongs to one client, under that client's lock). ANV uses opaque syncobj fds for
  `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD`; Wine prefers sync_file/opaque depending on the semaphore type.
- **implicit sync on a dma-buf** (`DMA_BUF_IOCTL_EXPORT_SYNC_FILE` / `IMPORT_SYNC_FILE`, used by ANV for WSI and by
  Wine's swapchain): the dma-buf entry carries a fence list with dma_resv rules: exactly the surface-fence registry
  that exists for IOSurface ids (`surfaceAttach` / `surfCollect`, WRITE/READ usage, 1024 live entries). The entry's key
  becomes the registry key instead of an IOSurface id.

## 3. New ioctls (uapi/intelxe_drm.h), all on the client connection

| ioctl | in | out | Linux equivalent |
|---|---|---|---|
| `INTELXE_EXPORT` | kind (dmabuf / syncfile / syncobj), handle (BO or syncobj), point, flags, fd (unlinked file) | 0 | PRIME_HANDLE_TO_FD, SYNCOBJ_HANDLE_TO_FD |
| `INTELXE_IMPORT` | fd, kind, target syncobj + point (sync_file) | GEM handle / syncobj handle | PRIME_FD_TO_HANDLE, SYNCOBJ_FD_TO_HANDLE |
| `INTELXE_DMABUF_SYNC` | fd, direction, usage (READ/WRITE), syncobj | 0 | DMA_BUF_IOCTL_EXPORT/IMPORT_SYNC_FILE |
| `INTELXE_SYNC_MERGE` | fd a, fd b, new fd | 0 | SYNC_IOC_MERGE |
| `INTELXE_FD_INFO` | fd | kind, size | telling a stand-in from any other file (xemac asks before routing an ioctl) |

`DRM_CAP_PRIME` then answers IMPORT|EXPORT, and `DRM_CAP_SYNCOBJ` already says yes.

## 4. Userspace (xemac in Mesa; Wine needs nothing of its own)

- `drmPrimeHandleToFD` / `drmSyncobjHandleToFD` / `...FDToHandle` and `ioctl(fd, DMA_BUF_IOCTL_*)` / `SYNC_IOC_MERGE`
  on a stand-in are routed to the ioctls above (`INTELXE_FD_INFO` tells a stand-in from any other fd).
- `lseek(dmabuf_fd, 0, SEEK_END)` works unchanged (the file is truncated to the BO size).
- `close()`, `dup()`, `fork()`, `SCM_RIGHTS` need nothing: the stand-in is a real fd.

## 5. What it costs / risks

- No new memory paths: an import is a second handle on an existing BO; everything rb2-rb6 made safe (BO refcounts,
  bind atomicity, ban floor, map-holds-BO, compression rules) applies as is.
- A process can pin another's VRAM only through an fd it was given (the Linux model).
- One open file per export (no disk space: unlinked, sparse). The per-process fd limit (256 soft by default on macOS)
  is the practical ceiling, as on Linux; Wine raises its limit at start.
- Entries outlive their last fd by up to one timer period (the check in section 1); their BO stays allocated that long.
- Not covered: `VK_EXT_external_memory_host` is unrelated (userptr already works); Metal/IOSurface sharing stays on
  the IOSurface-id path (SURFACE_VRAM), which is the right one between Metal and ANV processes.

## 6. Order of work

1. dma-buf export/import + BO `shared` rules (unblocks Wine's shared textures and DXGI swapchains).
2. sync_file export/import into syncobjs (unblocks `VK_KHR_external_semaphore_fd` SYNC_FD and fence fds).
3. dma-buf implicit sync (EXPORT/IMPORT_SYNC_FILE) on top of the surface-fence registry.
4. Opaque syncobj sharing (refcounted syncobjs) and merge. poll on a sync_file stays unsupported (section 1).
