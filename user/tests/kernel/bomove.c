// SPDX-License-Identifier: MIT
// bomove: BO moves into and out of the BAR window (p2c) on IntelXe.kext.
//   ./bomove         migrate on map: a 48 MB VRAM BO the CPU may not map lands outside the window; the GPU writes a pattern
//                    into it through its VA, then GEM_MMAP_OFFSET moves it into the window. The CPU reads the pattern
//                    through the new mapping, and the GPU writes again through the same VA (its PTEs were rewritten): the
//                    CPU must see the new values.
//   ./bomove evict   window eviction: NEEDS_VISIBLE BOs that are never mapped are filled by the GPU until the window has
//                    less room than one more; that allocation must evict some of them (debug.intelxe.stats "BO moves: ... out
//                    of it"), and mapping an evicted one brings it back with its contents.
// Test only.   clang -arch x86_64 -O2 -I../uapi -o bomove bomove.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include "xe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	errno = (int)out;
	return out ? -1 : 0;
}
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
static uint32_t gem(uint64_t size, uint32_t placement, uint32_t flags, uint16_t caching) {
	struct drm_xe_gem_create g = {.size = size, .placement = placement, .flags = flags, .cpu_caching = caching};
	if (xioctl(DRM_IOCTL_XE_GEM_CREATE, &g)) { fprintf(stderr, "GEM_CREATE %d\n", errno); exit(1); }
	return g.handle;
}
static void *map(uint32_t handle, uint64_t size) {
	struct drm_xe_gem_mmap_offset m = {.handle = handle};
	if (xioctl(DRM_IOCTL_XE_GEM_MMAP_OFFSET, &m)) { printf("MMAP_OFFSET %d\n", errno); return NULL; }
	mach_vm_address_t addr = 0; mach_vm_size_t sz = size;
	if (IOConnectMapMemory64(conn, (uint32_t)(m.offset >> 12), mach_task_self(), &addr, &sz, kIOMapAnywhere)) return NULL;
	return (void *)(uintptr_t)addr;
}
// The bind's out-fence is the BO's VRAM clear (copy engine): waited for, as Mesa makes its execs wait on it.
static int bind(uint32_t vm, uint32_t bo, uint64_t addr, uint64_t range) {
	struct drm_syncobj_create sc = {0};
	if (xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc)) return -1;
	struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle};
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s};
	b.bind.obj = bo; b.bind.range = range; b.bind.addr = addr; b.bind.op = DRM_XE_VM_BIND_OP_MAP; b.bind.pat_index = 2;
	int r = xioctl(DRM_IOCTL_XE_VM_BIND, &b);
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&sc.handle, .count_handles = 1, .timeout_nsec = INT64_MAX};
	if (!r) r = xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w);
	struct drm_syncobj_destroy d = {.handle = sc.handle};
	xioctl(DRM_IOCTL_SYNCOBJ_DESTROY, &d);
	return r;
}
static void stats(const char *what) {
	char buf[4096]; size_t l = sizeof(buf);
	if (sysctlbyname("debug.intelxe.stats", buf, &l, NULL, 0)) return;
	char *p = strstr(buf, "BO moves");
	if (p) { char *e = strchr(p, '\n'); if (e) *e = 0; printf("%s: %s\n", what, p); }
	if ((p = strstr(buf, "VRAM end"))) { char *e = strchr(p, '\n'); if (e) *e = 0; printf("%s: %s\n", what, p); }
}
static uint64_t windowFreeMB(void) {
	char buf[4096]; size_t l = sizeof(buf);
	if (sysctlbyname("debug.intelxe.stats", buf, &l, NULL, 0)) return 0;
	char *p = strstr(buf, "free ");
	return p ? strtoull(p + 5, NULL, 10) : 0;
}

static uint32_t vmId, q, so, bbh;
static volatile uint32_t *bb;
// One stored dword per 64 KB of [va, va + size): value ^ offset.
static void gpuPattern(uint64_t va, uint64_t size, uint32_t value) {
	uint32_t k = 0;
	for (uint64_t o = 0; o < size; o += 0x10000) {
		bb[k++] = 0x20 << 23 | 2; bb[k++] = (uint32_t)(va + o); bb[k++] = (uint32_t)((va + o) >> 32); bb[k++] = value ^ (uint32_t)o;
	}
	bb[k++] = 0xa << 23; bb[k++] = 0;
	__sync_synchronize();
	struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = so};
	struct drm_xe_exec x = {.exec_queue_id = q, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s, .address = 0x100000, .num_batch_buffer = 1};
	CHECK(!xioctl(DRM_IOCTL_XE_EXEC, &x), "exec %d", errno);
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&so, .count_handles = 1, .timeout_nsec = INT64_MAX};
	CHECK(!xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w), "wait %d", errno);
}
static int checkPattern(volatile uint32_t *p, uint64_t size, uint32_t value) {
	int bad = 0;
	for (uint64_t o = 0; o < size; o += 0x10000)
		if (p[o / 4] != (value ^ (uint32_t)o)) bad++;
	return bad;
}

int main(int argc, char **argv) {
	const int evict = argc > 1 && !strcmp(argv[1], "evict");
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create\n"); return 1; }
	vmId = vc.vm_id;
	bbh = gem(0x10000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
	bb = map(bbh, 0x10000);
	CHECK(bb && !bind(vmId, bbh, 0x100000, 0x10000), "batch");
	struct drm_xe_engine_class_instance ei = {.engine_class = DRM_XE_ENGINE_CLASS_RENDER};
	struct drm_xe_exec_queue_create qc = {.width = 1, .num_placements = 1, .vm_id = vmId, .instances = (uint64_t)(uintptr_t)&ei};
	if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &qc)) { fprintf(stderr, "queue\n"); return 1; }
	q = qc.exec_queue_id;
	struct drm_syncobj_create sc = {0};
	xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc);
	so = sc.handle;
	stats("before");
	if (!evict) {
		const uint64_t size = 48ull << 20, va = 1ull << 32;
		const uint32_t bo = gem(size, 2, 0, DRM_XE_GEM_CPU_CACHING_WC);   // VRAM, no NEEDS_VISIBLE: outside the window
		CHECK(!bind(vmId, bo, va, size), "bind %d", errno);
		gpuPattern(va, size, 0xa5a50000);
		volatile uint32_t *p = map(bo, size);   // moves it into the window
		CHECK(p != NULL, "map of a BO outside the window failed");
		if (p) {
			const int bad = checkPattern(p, size, 0xa5a50000);
			CHECK(!bad, "%d of %llu words wrong after the move", bad, size >> 16);
			gpuPattern(va, size, 0x3c3c0000);   // the same VA: its PTEs now point into the window
			const int bad2 = checkPattern(p, size, 0x3c3c0000);
			CHECK(!bad2, "%d of %llu words wrong after a GPU write through the remapped VA", bad2, size >> 16);
		}
	} else {
		const uint64_t each = 64ull << 20;
		uint64_t freeMB = windowFreeMB();
		uint32_t n = (uint32_t)(freeMB / 64) + 1, made = 0, h[64];
		if (n > 60) n = 60;
		printf("window free %llu MB: %u never-mapped visible BOs of 64 MB, then one more\n", freeMB, n);
		for (uint32_t i = 0; i < n; i++) {
			h[i] = gem(each, 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC);
			CHECK(!bind(vmId, h[i], (2ull << 32) + i * each, each), "bind %u", i);
			gpuPattern((2ull << 32) + i * each, each, 0x77000000u | i);
			made++;
		}
		stats("filled");
		const uint32_t extra = gem(each, 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC);
		volatile uint32_t *pe = map(extra, each);
		CHECK(pe != NULL, "map of the extra BO");
		stats("after the extra BO");
		int bad = 0;
		// map them back (evicted ones return; others may go out meanwhile), leaving room: a CPU-mapped BO never moves, so
		// the window must hold all of them plus the extra one and everything other clients mapped
		const uint32_t back = made > 3 ? made - 3 : made;
		for (uint32_t i = 0; i < back; i++) {
			volatile uint32_t *p = map(h[i], each);
			if (!p) { bad++; continue; }
			bad += checkPattern(p, each, 0x77000000u | i) != 0;
		}
		CHECK(!bad, "%d BOs lost their contents across eviction and return", bad);
		stats("after mapping them all");
	}
	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
