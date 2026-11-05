// SPDX-License-Identifier: MIT
// rb7t: object file descriptors (fd sharing stages 1-2, uapi/intelxe_drm.h INTELXE_OBJ_DEVICE): the clone device /dev/intelxeobj,
// one record per open minor, and the resolution of a caller's fd to its record. What the records hold (BOs, syncobjs,
// sync files) and the ioctls are xe_core.cpp's; this file only keeps a typed pointer per minor and hands references
// out through the callbacks xeFdObj* (xe_core.cpp).
#pragma once
#include <stdint.h>
#include <stddef.h>

enum : uint32_t { kFdNone = 0, kFdBo = 1, kFdSyncobj = 2, kFdSyncFile = 3 };   // = INTELXE_OBJ_KIND_*

extern int gFds;   // debug.intelxe.fds: 1 = object fds offered (INTELXE_CAP_FD_OBJECTS, DRM_CAP_PRIME, the four ioctls)
extern int gFdsBoot;   // boot-arg intelxe_fds=1: switch gFds on with the first client (devfs is up by then)

bool xeFdInit();                 // module start: the lock only (the device appears with xeFdEnable)
bool xeFdFini();                 // module stop: false (refuse) while a minor is open; else the node and cdevsw go
int xeFdEnable();                // the clone device, made once (debug.intelxe.fds 1, boot-arg intelxe_fds=1)
uint32_t xeFdOpenCount();        // minors open now (IntelXe::terminate refuses while there are any)
// Bind obj (a reference the record takes over on success) to the unbound minor behind the caller's fd: EBADF (not an
// open fd), EINVAL (not an open of INTELXE_OBJ_DEVICE), EBUSY (bound already).
int xeFdBind(int fd, uint32_t kind, void *obj);
// The object behind the caller's fd, with a new reference (xeFdObjGet) the caller drops with xeFdObjPut: EBADF / EINVAL
// as above; an unbound minor gives kFdNone and nullptr.
int xeFdTake(int fd, uint32_t *kind, void **obj);
// fn on every bound record of a kind, under the record lock (fn takes no lock but leaves and may allocate).
void xeFdForEach(uint32_t kind, void (*fn)(void *obj, void *ctx), void *ctx);
int xeFdStatsString(char *out, size_t len);   // debug.intelxe.fd_stats

// xe_core.cpp: a new reference to obj (called under the record lock: atomic increments only), its drop, and the
// release of the record's own reference after the minor's last close (no lock held).
void xeFdObjGet(uint32_t kind, void *obj);
void xeFdObjPut(uint32_t kind, void *obj);
void xeFdObjRelease(uint32_t kind, void *obj);
