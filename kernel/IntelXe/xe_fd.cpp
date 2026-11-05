// SPDX-License-Identifier: MIT
// rb7t: the clone device behind object file descriptors (fd sharing stages 1-2; docs/reports/b580-fd-sharing-20261103.md
// §5 "A", b580-fd-sharing-stage0-20261104.md §5). Linux makes a file for a syncobj (anon_inode "syncobj_file"), a
// sync_file and a dma-buf and installs it in the caller's fd table; a kext cannot (falloc/fdalloc are not KPI). Here the
// caller (xemac) opens INTELXE_OBJ_DEVICE itself and passes that fd IN the export ioctl, and the kext binds the object to the
// open's minor:
//  - /dev/intelxeobj is a devfs clone node (devfs_make_node_clone, 0666 as a render node): every lookup takes a new minor
//    from a 24-bit counter that skips the minors open now. stat() makes a lookup too, so nothing is recorded for a minor
//    until d_open; a minor that is open already (a second open through a mknod alias) answers EBUSY.
//  - one record per open minor {kind, object, pid}; d_close is that minor's last close (dup, fork, SCM_RIGHTS and XPC
//    carry the same open file, so it comes when the last holder anywhere has closed it, or exited) and releases the
//    object, as drm_syncobj_file_release / dma_buf_release / sync_file_release do.
//  - an fd is resolved in the CALLER's fd table (file_vnode_withvid, com.apple.kpi.bsd: the IOUserClient's
//    externalMethod runs on the calling thread), so a number names nothing in another process: the fd itself is the
//    capability. While that holds the fileproc, the minor cannot reach its last close (close() waits for the I/O count),
//    so the record is stable for the duration; the record table itself is gFdLock's. (file_vnode, which the design
//    named, is in com.apple.kpi.private only, which a third-party kext may not link.)
//  - nothing is offered on the object fd itself: read/write/mmap ENODEV, ioctl ENOTTY (SYNC_IOC_FILE_INFO,
//    DMA_BUF_IOCTL_*_SYNC_FILE: WSI takes ENOTTY as "no implicit sync"), poll/select is stage 4 (kqueue needs
//    cdevsw_setkqueueok, not in the SDK's headers). DRM_IOCTL_INTELXE_OBJ_INFO on the device answers what an fd holds.
// The device exists only once debug.intelxe.fds was set to 1 (or boot-arg intelxe_fds=1): until then nothing of this is visible.
// Unload: refused (IntelXe::terminate, IntelXe_stop) while a minor is open, as NMDRM refuses with descriptors open.
// Locks: gFdLock is a leaf (taken under client locks and gClientsLock; only atomic reference increments and allocation
// inside); gFdEnLock serialises the one-time registration (devfs calls back into objClone under its own lock, which then
// takes gFdLock: gFdLock is never held while calling devfs).
#include "IntelXe.h"
#include "xe_fd.h"
#include <IOKit/IOLib.h>
#include <libkern/OSAtomic.h>
#include <sys/conf.h>
#include <sys/errno.h>
#include <sys/file.h>
#include <sys/proc.h>
#include <sys/vnode.h>
#include <miscfs/devfs/devfs.h>

int gFds = 0;
int gFdsBoot = 0;
static IOLock *gFdLock, *gFdEnLock;
static int gMajor = -1;
static void *gNode;
static volatile UInt32 gNextMinor;

struct FdRec {
	FdRec *next;
	uint32_t minor, kind;
	void *obj;
	int pid;
};
static constexpr uint32_t kBuckets = 256;
static FdRec *gRecs[kBuckets];
// debug.intelxe.fd_stats (gFdLock): minors open now (in total and by kind), and since load: opens, opens refused (fds 0 /
// minor open already), last closes, binds and imports by kind, resolutions refused
static struct {
	uint32_t open, byKind[4], opens, offOpens, busyOpens, closes, binds[4], takes[4], badFd, notOurs, bound;
} gFdSt;

// dev_t is an int: major bits 31:24, minor 23:0 (sys/types.h makedev), without the macros' sign conversions
static uint32_t devMinor(dev_t d) { return (uint32_t)d & 0xffffffu; }
static int devMajor(dev_t d) { return (int)((uint32_t)d >> 24); }

static FdRec **slot(uint32_t minor) {
	FdRec **pp = &gRecs[minor % kBuckets];
	while (*pp && (*pp)->minor != minor) pp = &(*pp)->next;
	return pp;
}

// DEVFS_CLONE_ALLOC: a minor for a new vnode (an open or a stat). DEVFS_CLONE_FREE is not relied on (ptmx_clone ignores
// it too): nothing is kept per allocation, and a minor is only skipped while a record holds it.
static int objClone(dev_t, int action) {
	if (action != DEVFS_CLONE_ALLOC) return -1;
	IOLockLock(gFdLock);
	uint32_t m = 0;
	for (uint32_t i = 0; i < 0x1000000u; i++) {
		m = (uint32_t)OSIncrementAtomic(reinterpret_cast<volatile SInt32 *>(&gNextMinor)) & 0xffffffu;
		if (m && !*slot(m)) break;
		m = 0;
	}
	IOLockUnlock(gFdLock);
	return m ? (int)m : -1;
}

static int objOpen(dev_t dev, int, int, proc_t p) {
	auto *r = static_cast<FdRec *>(IOMallocZero(sizeof(FdRec)));
	if (!r) return ENOMEM;
	r->minor = devMinor(dev);
	r->pid = p ? proc_pid(p) : 0;
	IOLockLock(gFdLock);
	int err = 0;
	if (!gFds) err = ENODEV, gFdSt.offOpens++;              // switched off: nothing new (bound minors stay valid)
	else if (*slot(r->minor)) err = EBUSY, gFdSt.busyOpens++;   // open already (a second node for the same minor)
	else {
		r->next = gRecs[r->minor % kBuckets];
		gRecs[r->minor % kBuckets] = r;
		gFdSt.open++;
		gFdSt.byKind[kFdNone]++;
		gFdSt.opens++;
	}
	IOLockUnlock(gFdLock);
	if (err) IOFree(r, sizeof(*r));
	return err;
}

static int objClose(dev_t dev, int, int, proc_t) {
	IOLockLock(gFdLock);
	FdRec **pp = slot(devMinor(dev)), *r = *pp;
	if (r) {
		*pp = r->next;
		gFdSt.open--;
		gFdSt.byKind[r->kind & 3]--;
		gFdSt.closes++;
	}
	IOLockUnlock(gFdLock);
	if (!r) return 0;
	if (r->obj) xeFdObjRelease(r->kind, r->obj);
	IOFree(r, sizeof(*r));
	return 0;
}

static int objIoctl(dev_t, u_long, caddr_t, int, proc_t) { return ENOTTY; }
// what eno_rdwrt / eno_stop / eno_reset / eno_select are (enodev), typed: read, write ENODEV; select answers nonzero
// (ENODEV), which spec_select reports as ready, as for any device without select; poll() gets POLLNVAL (no kqueue)
static int objRw(dev_t, struct uio *, int) { return ENODEV; }
static int objStop(struct tty *, int) { return ENODEV; }
static int objReset(int) { return ENODEV; }
static int objSelect(dev_t, int, void *, proc_t) { return ENODEV; }

static struct cdevsw gSw = {objOpen, objClose, objRw, objRw, objIoctl, objStop, objReset, nullptr, objSelect, eno_mmap,
	eno_strat, eno_getc, eno_putc, 0};

bool xeFdInit() {
	gFdLock = IOLockAlloc();
	gFdEnLock = IOLockAlloc();
	return gFdLock && gFdEnLock;
}

int xeFdEnable() {
	if (!gFdEnLock) return ENXIO;
	IOLockLock(gFdEnLock);
	int err = 0;
	if (gMajor < 0) {
		const int maj = cdevsw_add(-1, &gSw);
		if (maj < 0) err = EBUSY;
		else if (!(gNode = devfs_make_node_clone((dev_t)((uint32_t)maj << 24), DEVFS_CHAR, UID_ROOT, GID_WHEEL, 0666, objClone, "intelxeobj"))) {
			cdevsw_remove(maj, &gSw);
			err = ENOMEM;
		} else {
			gMajor = maj;
		}
	}
	IOLockUnlock(gFdEnLock);
	return err;
}

uint32_t xeFdOpenCount() {
	if (!gFdLock) return 0;
	IOLockLock(gFdLock);
	const uint32_t n = gFdSt.open;
	IOLockUnlock(gFdLock);
	return n;
}

bool xeFdFini() {
	if (xeFdOpenCount()) return false;
	if (gFdEnLock) IOLockLock(gFdEnLock);
	if (gMajor >= 0) {
		devfs_remove(gNode);
		cdevsw_remove(gMajor, &gSw);
		gNode = nullptr;
		gMajor = -1;
	}
	if (gFdEnLock) IOLockUnlock(gFdEnLock);
	if (gFdLock) IOLockFree(gFdLock);
	if (gFdEnLock) IOLockFree(gFdEnLock);
	gFdLock = gFdEnLock = nullptr;
	return true;
}

// The record behind the caller's fd: 0 with gFdLock held (the caller unlocks, then file_drop(fd)), or EBADF (not an
// open fd: fp_lookup) / EINVAL (a socket, pipe or kqueue: not a vnode; another file; one of ours never opened). On an
// error nothing is held.
static int fdRecord(int fd, FdRec **out) {
	vnode_t vp = nullptr;
	if (gMajor < 0) return fd < 0 ? EBADF : EINVAL;   // (not reached: the ioctls need fds on, which made the device)
	uint32_t vid = 0;   // file_vnode_withvid: com.apple.kpi.bsd (file_vnode itself is only in com.apple.kpi.private)
	int err = file_vnode_withvid(fd, &vp, &vid);
	if (err) {
		IOLockLock(gFdLock);
		if (err == EBADF) gFdSt.badFd++;
		else gFdSt.notOurs++;
		IOLockUnlock(gFdLock);
		return err == EBADF ? EBADF : EINVAL;
	}
	const dev_t rdev = vp && vnode_ischr(vp) ? vnode_specrdev(vp) : NODEV;
	const bool ours = rdev != NODEV && devMajor(rdev) == gMajor;
	IOLockLock(gFdLock);
	FdRec *r = ours ? *slot(devMinor(rdev)) : nullptr;
	if (!r) {
		gFdSt.notOurs++;
		IOLockUnlock(gFdLock);
		file_drop(fd);
		return EINVAL;
	}
	*out = r;
	return 0;
}

int xeFdBind(int fd, uint32_t kind, void *obj) {
	FdRec *r;
	int err = fdRecord(fd, &r);
	if (err) return err;
	if (r->kind != kFdNone) {
		err = EBUSY;   // bound already: xemac opens a new minor for every export
	} else {
		r->kind = kind;
		r->obj = obj;
		gFdSt.byKind[kFdNone]--;
		gFdSt.byKind[kind & 3]++;
		gFdSt.binds[kind & 3]++;
	}
	IOLockUnlock(gFdLock);
	file_drop(fd);
	return err;
}

int xeFdTake(int fd, uint32_t *kind, void **obj) {
	FdRec *r;
	int err = fdRecord(fd, &r);
	if (err) return err;
	*kind = r->kind;
	*obj = r->obj;
	if (r->obj) xeFdObjGet(r->kind, r->obj);
	gFdSt.takes[r->kind & 3]++;
	IOLockUnlock(gFdLock);
	file_drop(fd);
	return 0;
}

void xeFdForEach(uint32_t kind, void (*fn)(void *obj, void *ctx), void *ctx) {
	if (!gFdLock) return;
	IOLockLock(gFdLock);
	for (uint32_t b = 0; b < kBuckets; b++)
		for (FdRec *r = gRecs[b]; r; r = r->next)
			if (r->kind == kind && r->obj) fn(r->obj, ctx);
	IOLockUnlock(gFdLock);
}

int xeFdStatsString(char *out, size_t len) {
	if (!gFdLock) return snprintf(out, len, "object fds: not initialised\n");
	IOLockLock(gFdLock);
	const auto s = gFdSt;
	IOLockUnlock(gFdLock);
	return snprintf(out, len,
		"fds %d, device /dev/intelxeobj %s (major %d)\n"
		"minors open %u: unbound %u, BO %u, syncobj %u, sync file %u\n"
		"opens %u (refused: fds off %u, minor open already %u), last closes %u\n"
		"binds: BO %u, syncobj %u, sync file %u; lookups: none %u, BO %u, syncobj %u, sync file %u; refused: not an open fd "
		"%u, not an object fd %u\n",
		gFds, gMajor >= 0 ? "present" : "absent", gMajor, s.open, s.byKind[0], s.byKind[1], s.byKind[2], s.byKind[3], s.opens,
		s.offOpens, s.busyOpens, s.closes, s.binds[1], s.binds[2], s.binds[3], s.takes[0], s.takes[1], s.takes[2],
		s.takes[3], s.badFd, s.notOurs);
}
