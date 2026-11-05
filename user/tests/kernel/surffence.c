// SPDX-License-Identifier: MIT
// surffence: end-to-end test of the surface fence ioctls (uapi/intelxe_drm.h) and the job watchdog on IntelXe.kext.
//   ./surffence            GPU-side implicit sync: a render-queue writer (held by MI_SEMAPHORE_WAIT until the CPU releases
//                          it) attaches a WRITE fence to surface 777; a copy-queue reader imports it (READER) into its own
//                          timeline and passes that point as an exec in-fence; its MI_COPY_MEM_MEM must copy the value the
//                          writer stored, and it must not complete before the writer is released. Also SURFACE_FENCE_WAIT
//                          (ETIME while held, 0 after), the dma-resv replacement rule and the error codes.
//   ./surffence watchdog   a writer that is never released: with debug.intelxe.job_timeout_ms (set it low, e.g. 2000,
//                          first) its queue is banned, its surface fence completes, the importer's exec runs, and the
//                          writer's next exec fails with ECANCELED.
// Measurement/test only.   clang -arch x86_64 -O2 -I../uapi -o surffence surffence.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xe_drm.h"
#include "intelxe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	errno = (int)out;
	return out ? -1 : 0;
}
static mach_timebase_info_data_t tb;
static uint64_t ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t gem(uint64_t size) {
	struct drm_xe_gem_create g = {.size = size, .placement = 1, .cpu_caching = DRM_XE_GEM_CPU_CACHING_WB};
	if (xioctl(DRM_IOCTL_XE_GEM_CREATE, &g)) { fprintf(stderr, "GEM_CREATE %d\n", errno); exit(1); }
	return g.handle;
}
static void *map(uint32_t handle, uint64_t size) {
	struct drm_xe_gem_mmap_offset m = {.handle = handle};
	if (xioctl(DRM_IOCTL_XE_GEM_MMAP_OFFSET, &m)) return NULL;
	mach_vm_address_t addr = 0; mach_vm_size_t sz = size;
	if (IOConnectMapMemory64(conn, (uint32_t)(m.offset >> 12), mach_task_self(), &addr, &sz, kIOMapAnywhere)) return NULL;
	return (void *)(uintptr_t)addr;
}
static int bind(uint32_t vm, uint32_t bo, uint64_t addr, uint64_t range) {
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1};
	b.bind.obj = bo; b.bind.range = range; b.bind.addr = addr; b.bind.op = DRM_XE_VM_BIND_OP_MAP; b.bind.pat_index = 2;
	return xioctl(DRM_IOCTL_XE_VM_BIND, &b);
}
static uint32_t queue(uint32_t vm, uint16_t cls) {
	struct drm_xe_engine_class_instance ei = {.engine_class = cls};
	struct drm_xe_exec_queue_create q = {.width = 1, .num_placements = 1, .vm_id = vm, .instances = (uint64_t)(uintptr_t)&ei};
	if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &q)) { fprintf(stderr, "queue %u: %d\n", cls, errno); exit(1); }
	return q.exec_queue_id;
}
static uint32_t syncobj(void) {
	struct drm_syncobj_create sc = {0};
	if (xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc)) { fprintf(stderr, "syncobj %d\n", errno); exit(1); }
	return sc.handle;
}
static int exec(uint32_t q, uint64_t batch, struct drm_xe_sync *s, uint32_t ns_) {
	struct drm_xe_exec x = {.exec_queue_id = q, .num_syncs = ns_, .syncs = (uint64_t)(uintptr_t)s, .address = batch, .num_batch_buffer = 1};
	return xioctl(DRM_IOCTL_XE_EXEC, &x);
}
static int waitBin(uint32_t h, uint64_t timeoutNs) {
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&h, .count_handles = 1, .timeout_nsec = (int64_t)(ns() + timeoutNs)};
	return xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w) ? errno : 0;
}
static int attach(uint32_t surf, uint32_t so, uint64_t point, uint32_t flags) {
	struct drm_intelxe_surface_fence_attach a = {.surface_id = surf, .syncobj = so, .point = point, .flags = flags};
	return xioctl(DRM_IOCTL_INTELXE_SURFACE_FENCE_ATTACH, &a) ? errno : 0;
}
static int surfWait(uint32_t surf, uint32_t flags, uint64_t timeoutNs) {
	struct drm_intelxe_surface_fence_wait w = {.surface_id = surf, .flags = flags, .timeout_ns = (int64_t)(ns() + timeoutNs)};
	return xioctl(DRM_IOCTL_INTELXE_SURFACE_FENCE_WAIT, &w) ? errno : 0;
}

// target page dwords: 0 written by the writer, 2 copied by the reader, 16 the writer's semaphore
enum { kBatchW = 0x100000, kBatchR = 0x110000, kTarget = 0x200000 };

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	const int watchdog = argc > 1 && !strcmp(argv[1], "watchdog");
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	struct drm_get_cap cap = {.capability = INTELXE_CAP_SURFACE_FENCES};
	CHECK(!xioctl(DRM_IOCTL_GET_CAP, &cap) && cap.value == 1, "INTELXE_CAP_SURFACE_FENCES = %llu", (unsigned long long)cap.value);
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create\n"); return 1; }
	uint32_t bw = gem(0x10000), br = gem(0x10000), tgh = gem(0x1000);
	volatile uint32_t *pw = map(bw, 0x10000), *pr = map(br, 0x10000), *tg = map(tgh, 0x1000);
	if (!pw || !pr || !tg || bind(vc.vm_id, bw, kBatchW, 0x10000) || bind(vc.vm_id, br, kBatchR, 0x10000) || bind(vc.vm_id, tgh, kTarget, 0x1000)) {
		fprintf(stderr, "setup\n");
		return 1;
	}
	const uint32_t qw = queue(vc.vm_id, DRM_XE_ENGINE_CLASS_RENDER), qr = queue(vc.vm_id, DRM_XE_ENGINE_CLASS_COPY);
	const uint32_t sw = syncobj(), sr = syncobj(), tl = syncobj();
	const uint32_t X = 0x5eed0000u | (uint32_t)(ns() & 0xffff), surf = 777;
	tg[0] = 0; tg[2] = 0; tg[16] = 0;
	// writer: MI_SEMAPHORE_WAIT (poll, == X) on dword 16, MI_STORE_DATA_IMM X -> dword 0
	uint32_t k = 0;
	pw[k++] = 0x1c << 23 | 1u << 15 | 4u << 12 | 3; pw[k++] = X; pw[k++] = kTarget + 64; pw[k++] = 0; pw[k++] = 0;
	pw[k++] = 0x20 << 23 | 2; pw[k++] = kTarget; pw[k++] = 0; pw[k++] = X;
	pw[k++] = 0xa << 23; pw[k++] = 0;
	// reader: MI_COPY_MEM_MEM dword 0 -> dword 2
	k = 0;
	pr[k++] = 0x2e << 23 | 3; pr[k++] = kTarget + 8; pr[k++] = 0; pr[k++] = kTarget; pr[k++] = 0;
	pr[k++] = 0xa << 23;
	__sync_synchronize();

	// error codes
	CHECK(attach(surf, sw, 0, INTELXE_SURFACE_FENCE_WRITE) == EAGAIN, "attach before any submit: EAGAIN");
	CHECK(attach(0, sw, 0, INTELXE_SURFACE_FENCE_WRITE) == EINVAL, "surface 0: EINVAL");
	CHECK(attach(surf, sw, 0, 3) == EINVAL, "flags 3: EINVAL");
	CHECK(attach(surf, 9999, 0, INTELXE_SURFACE_FENCE_WRITE) == ENOENT, "bad syncobj: ENOENT");

	struct drm_xe_sync s1 = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sw};
	CHECK(!exec(qw, kBatchW, &s1, 1), "writer exec %d", errno);
	CHECK(!attach(surf, sw, 0, INTELXE_SURFACE_FENCE_WRITE), "attach WRITE %d", errno);
	struct drm_intelxe_surface_fence_import im = {.surface_id = surf, .syncobj = tl, .flags = INTELXE_SURFACE_FENCE_READER};
	CHECK(!xioctl(DRM_IOCTL_INTELXE_SURFACE_FENCE_IMPORT, &im) && im.count_out == 1 && im.point_out == 1,
		"import: count %u point %llu (errno %d)", im.count_out, (unsigned long long)im.point_out, errno);
	struct drm_xe_sync s2[2] = {
		{.type = DRM_XE_SYNC_TYPE_TIMELINE_SYNCOBJ, .handle = tl, .timeline_value = im.point_out},
		{.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sr}};
	const uint64_t t0 = ns();
	CHECK(!exec(qr, kBatchR, s2, 2), "reader exec %d", errno);
	CHECK(waitBin(sr, 20000000) == ETIME, "reader completed while the writer is held");
	CHECK(tg[2] == 0, "reader copied 0x%x early", tg[2]);
	CHECK(surfWait(surf, INTELXE_SURFACE_FENCE_READER, 5000000) == ETIME, "SURFACE_FENCE_WAIT while held: ETIME");
	if (!watchdog) {
		tg[16] = X;
		__sync_synchronize();
		CHECK(!waitBin(sr, 2000000000ull), "reader wait %d", errno);
		CHECK(tg[2] == X, "reader copied 0x%x, writer stored 0x%x", tg[2], tg[0]);
		CHECK(!surfWait(surf, INTELXE_SURFACE_FENCE_WRITER, 1000000000ull), "SURFACE_FENCE_WAIT after release");
		printf("ordered: reader completed %.1f ms after its exec (writer released at ~20 ms)\n", (ns() - t0) / 1e6);
		// dma-resv rule: a READ from the reader's queue, then a WRITE from it supersedes the read
		CHECK(!attach(surf, sr, 0, INTELXE_SURFACE_FENCE_READ), "attach READ (signaled: no-op) %d", errno);
		struct drm_intelxe_surface_fence_import im2 = {.surface_id = surf, .syncobj = tl, .flags = INTELXE_SURFACE_FENCE_WRITER};
		CHECK(!xioctl(DRM_IOCTL_INTELXE_SURFACE_FENCE_IMPORT, &im2) && im2.count_out == 0 && im2.point_out == 0,
			"import after everything signaled: count %u point %llu", im2.count_out, (unsigned long long)im2.point_out);
	} else {
		printf("watchdog: the writer is never released; waiting up to 30 s for its queue to be banned\n");
		const int r = waitBin(sr, 30000000000ull);
		CHECK(!r, "reader never ran (%d)", r);
		printf("reader completed %.1f s after its exec (copied 0x%x: the banned writer stored nothing)\n", (ns() - t0) / 1e9, tg[2]);
		CHECK(!surfWait(surf, INTELXE_SURFACE_FENCE_WRITER, 1000000000ull), "surface fence of the banned queue completes");
		struct drm_xe_exec_queue_get_property gp = {.exec_queue_id = qw, .property = DRM_XE_EXEC_QUEUE_GET_PROPERTY_BAN};
		CHECK(!xioctl(DRM_IOCTL_XE_EXEC_QUEUE_GET_PROPERTY, &gp) && gp.value == 1, "writer queue banned: %llu", (unsigned long long)gp.value);
		CHECK(exec(qw, kBatchW, NULL, 0) && errno == ECANCELED, "exec on the banned queue: %d", errno);
		tg[16] = X;   // let the context finish if the GuC ever runs it again
	}
	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
