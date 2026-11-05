// SPDX-License-Identifier: MIT
// winfill: the BAR window (CPU-visible VRAM) under pressure, on IntelXe.kext.
//   ./winfill unmap  CPU maps of VRAM BOs: IOConnectUnmapMemory64 must find and remove each mapping (it failed unseen
//                    before build pv: a new memory descriptor per call), two maps of one BO must be two mappings, and
//                    the BO's VRAM must go back when it is unmapped and closed. Uses ~20 MB of the window. Safe anywhere.
//   ./winfill fill   fills the window the way Mesa does (NEEDS_VISIBLE_VRAM BOs allowed in system memory, mapped for
//                    good, bound), then keeps allocating: BOs that no longer fit must land in system memory, binds must
//                    still get page tables (a fresh VM, 4 KB-paged system BOs), and every BO must keep what the CPU and
//                    the GPU wrote into it. Then everything is freed and the window must come back.
//                    TAKES THE WHOLE WINDOW for a few seconds: not while a game or benchmark runs (pgrep java/geekbench).
// Test only.   clang -arch x86_64 -O2 -I../uapi -o winfill winfill.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
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

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}
static uint32_t gem(uint64_t size, uint32_t placement, uint32_t flags) {
	struct drm_xe_gem_create g = {.size = size, .placement = placement, .flags = flags,
		.cpu_caching = placement & 2 ? DRM_XE_GEM_CPU_CACHING_WC : DRM_XE_GEM_CPU_CACHING_WB};
	return xioctl(DRM_IOCTL_XE_GEM_CREATE, &g) ? 0 : g.handle;
}
static void gemClose(uint32_t h) {
	struct drm_gem_close c = {.handle = h};
	xioctl(DRM_IOCTL_GEM_CLOSE, &c);
}
// As xemac_mmap: GEM_MMAP_OFFSET, then IOConnectMapMemory64 of type offset >> 12, write-combined for VRAM (bit 63).
static void *map(uint32_t handle, uint64_t size, uint32_t *type) {
	struct drm_xe_gem_mmap_offset m = {.handle = handle};
	if (xioctl(DRM_IOCTL_XE_GEM_MMAP_OFFSET, &m)) return NULL;
	mach_vm_address_t addr = 0;
	mach_vm_size_t sz = 0;
	*type = (uint32_t)(m.offset >> 12);
	if (IOConnectMapMemory64(conn, *type, mach_task_self(), &addr, &sz,
			kIOMapAnywhere | (m.offset >> 63 ? kIOMapWriteCombineCache : 0)) || sz < size)
		return NULL;
	return (void *)(uintptr_t)addr;
}
static kern_return_t unmap(uint32_t type, void *p) {
	return IOConnectUnmapMemory64(conn, type, mach_task_self(), (mach_vm_address_t)(uintptr_t)p);
}
static int bind(uint32_t vm, uint32_t bo, uint64_t addr, uint64_t range, uint32_t op) {
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1};
	b.bind.obj = op == DRM_XE_VM_BIND_OP_MAP ? bo : 0;
	b.bind.range = range;
	b.bind.addr = addr;
	b.bind.op = op;
	b.bind.pat_index = 2;
	return xioctl(DRM_IOCTL_XE_VM_BIND, &b);
}
static void line(const char *sysctl, const char *key, const char *what) {
	char buf[16384];
	size_t l = sizeof(buf);
	if (sysctlbyname(sysctl, buf, &l, NULL, 0)) return;
	char *p = strstr(buf, key);
	if (!p) return;
	char *e = strchr(p, '\n');
	if (e) *e = 0;
	printf("  %s: %s\n", what, p);
}
static void report(const char *what) {
	line("debug.intelxe.stats", "VRAM end", what);
	line("debug.intelxe.stats", "window:", what);
}
// The kernel's view of the CPU-visible window (DRM_XE_DEVICE_QUERY_MEM_REGIONS), and of system BOs.
static void regions(uint64_t *visUsed, uint64_t *visSize, uint64_t *sysUsed) {
	struct { struct drm_xe_query_mem_regions h; struct drm_xe_mem_region m[4]; } r;
	memset(&r, 0, sizeof(r));
	struct drm_xe_device_query q = {.query = DRM_XE_DEVICE_QUERY_MEM_REGIONS};
	*visUsed = *visSize = *sysUsed = 0;
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q) || q.size > sizeof(r)) return;   // size first, as Mesa asks
	q.data = (uint64_t)(uintptr_t)&r;
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q)) return;
	for (uint32_t i = 0; i < r.h.num_mem_regions && i < 4; i++) {
		if (r.m[i].mem_class == DRM_XE_MEM_REGION_CLASS_VRAM) {
			*visUsed = r.m[i].cpu_visible_used;
			*visSize = r.m[i].cpu_visible_size;
		} else {
			*sysUsed = r.m[i].used;
		}
	}
}

static uint32_t vmId, q, so, bbh;
static volatile uint32_t *bb;
static int gpuInit(void) {
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) return -1;
	vmId = vc.vm_id;
	uint32_t t;
	if (!(bbh = gem(0x10000, 1, 0)) || !(bb = map(bbh, 0x10000, &t)) || bind(vmId, bbh, 0x100000, 0x10000, DRM_XE_VM_BIND_OP_MAP))
		return -1;
	struct drm_xe_engine_class_instance ei = {.engine_class = DRM_XE_ENGINE_CLASS_RENDER};
	struct drm_xe_exec_queue_create qc = {.width = 1, .num_placements = 1, .vm_id = vmId, .instances = (uint64_t)(uintptr_t)&ei};
	if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &qc)) return -1;
	q = qc.exec_queue_id;
	struct drm_syncobj_create sc = {0};
	if (xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc)) return -1;
	so = sc.handle;
	return 0;
}
// MI_STORE_DATA_IMM of value ^ offset at every 64 KB of [va, va + size), at most 2000 stores per batch.
static int gpuPattern(uint64_t va, uint64_t size, uint32_t value) {
	uint32_t k = 0;
	for (uint64_t o = 0; o < size && k < 8000; o += 0x10000) {
		bb[k++] = 0x20 << 23 | 2;
		bb[k++] = (uint32_t)(va + o);
		bb[k++] = (uint32_t)((va + o) >> 32);
		bb[k++] = value ^ (uint32_t)o;
	}
	bb[k++] = 0xa << 23;
	bb[k++] = 0;
	__sync_synchronize();
	struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = so};
	struct drm_xe_exec x = {.exec_queue_id = q, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s, .address = 0x100000, .num_batch_buffer = 1};
	if (xioctl(DRM_IOCTL_XE_EXEC, &x)) return -1;
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&so, .count_handles = 1, .timeout_nsec = INT64_MAX};
	return xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w);
}
static int checkPattern(volatile uint32_t *p, uint64_t size, uint32_t value) {
	int bad = 0;
	for (uint64_t o = 0; o < size && o / 0x10000 < 2000; o += 0x10000)
		if (p[o / 4] != (value ^ (uint32_t)o)) bad++;
	return bad;
}

static int testUnmap(void) {
	uint64_t used0, size, sys0, used;
	regions(&used0, &size, &sys0);
	const uint64_t bs = 8ull << 20;
	uint32_t h = gem(bs, 3, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM);
	CHECK(h, "GEM_CREATE %d", errno);
	if (!h) return 1;
	uint32_t t1, t2;
	volatile uint32_t *a = map(h, bs, &t1), *b = map(h, bs, &t2);
	CHECK(a && b, "maps %p %p", (void *)a, (void *)b);
	if (!a || !b) return 1;
	printf("two maps of one 8 MB BO: types 0x%x 0x%x at %p %p\n", t1, t2, (void *)a, (void *)b);
	CHECK(a != b, "the two maps share one mapping: the first unmap would take the second down");
	a[0] = 0x12345678;
	a[bs / 4 - 1] = 0x9abcdef0;
	__sync_synchronize();
	CHECK(b[0] == 0x12345678 && b[bs / 4 - 1] == 0x9abcdef0, "the two maps do not show the same memory");
	kern_return_t kr = unmap(t1, (void *)a);
	CHECK(kr == KERN_SUCCESS, "IOConnectUnmapMemory64 of the first map: 0x%x (the mapping was not found)", kr);
	CHECK(b[0] == 0x12345678, "the second map lost its contents after the first was unmapped");
	kr = unmap(t2, (void *)b);
	CHECK(kr == KERN_SUCCESS, "IOConnectUnmapMemory64 of the second map: 0x%x", kr);
	gemClose(h);
	// many map / unmap / close rounds: nothing may stay behind (window use back where it was)
	for (int i = 0; i < 64; i++) {
		uint32_t hh = gem(1u << 20, 3, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM), tt;
		volatile uint32_t *p = hh ? map(hh, 1u << 20, &tt) : NULL;
		CHECK(p, "round %d: map", i);
		if (p) {
			p[0] = (uint32_t)i;
			kr = unmap(tt, (void *)p);
			CHECK(kr == KERN_SUCCESS, "round %d: unmap 0x%x", i, kr);
		}
		if (hh) gemClose(hh);
		if (fails > 4) break;
	}
	regions(&used, &size, &sys0);
	printf("window used before %llu MB, after %llu MB\n", used0 >> 20, used >> 20);
	report("after the unmap test");
	return fails;
}

#define MAXBO 4096
struct bo { uint32_t h, type; uint64_t size, va; volatile uint32_t *p; uint32_t value; };
static struct bo bos[MAXBO];
static uint32_t nbos;

// One Mesa-style BO: NEEDS_VISIBLE_VRAM, VRAM or system memory, mapped for good, bound, a CPU pattern written.
static int mesaBo(uint64_t size, uint64_t va) {
	struct bo *b = &bos[nbos];
	b->size = size;
	b->va = va;
	b->value = 0x51000000u | nbos;
	if (!(b->h = gem(size, 3, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM))) return -1;
	if (!(b->p = map(b->h, size, &b->type))) return -2;
	if (bind(vmId, b->h, va, size, DRM_XE_VM_BIND_OP_MAP)) return -3;
	for (uint64_t o = 0; o < size; o += 0x10000) b->p[o / 4] = b->value ^ (uint32_t)o;
	nbos++;
	return 0;
}

static int testFill(void) {
	const double t0 = now();
	uint64_t used, size, sys0, sys;
	regions(&used, &size, &sys0);
	printf("window %llu MB, %llu MB used; system BOs %llu MB\n", size >> 20, used >> 20, sys0 >> 20);
	report("before");
	uint64_t va = 1ull << 36;
	// 1. fill: 16 MB BOs until one lands in system memory, then 64 KB ones until those do too
	int err = 0;
	for (uint64_t each = 16ull << 20; each >= 0x10000 && nbos < MAXBO / 2; each >>= 4) {
		for (;;) {
			uint64_t s0;
			regions(&used, &size, &s0);
			if ((err = mesaBo(each, va)) != 0) break;
			va += each;
			regions(&used, &size, &sys);
			if (sys > s0 || now() - t0 > 20) break;   // spilled: the window has no room for this size any more
		}
		if (err) break;
	}
	CHECK(!err, "filling: Mesa-style BO %u failed at step %d (errno %d)", nbos, err, errno);
	regions(&used, &size, &sys);
	printf("filled: %u BOs, window %llu of %llu MB used, system BOs %llu MB (+%llu)\n", nbos, used >> 20, size >> 20,
		sys >> 20, (sys - sys0) >> 20);
	report("filled");
	// 2. keep allocating with the window full: mixed sizes, all must succeed (in system memory)
	const uint32_t before = nbos;
	for (uint32_t i = 0; i < 300 && nbos < MAXBO - 64 && !err && now() - t0 < 35; i++) {
		const uint64_t each = 0x10000ull << (i % 8);   // 64 KB .. 8 MB
		if ((err = mesaBo(each, va)) != 0) break;
		va += each;
	}
	CHECK(!err, "with the window full: BO %u failed at step %d (errno %d) - 1 create, 2 map, 3 bind (page tables)", nbos,
		err, errno);
	// system BOs bound with 4 KB pages need page-table pages, which live in the window
	uint32_t sysOk = 0;
	for (uint32_t i = 0; i < 16 && !err; i++) {
		uint32_t h = gem(32ull << 20, 1, 0);
		CHECK(h, "system BO %u: %d", i, errno);
		if (!h) break;
		if (bind(vmId, h, va + 0x1000, 8ull << 20, DRM_XE_VM_BIND_OP_MAP)) {   // 4 KB-aligned VA: 4 KB leaves
			CHECK(0, "bind of system BO %u with 4 KB pages: errno %d (no page-table pages?)", i, errno);
			break;
		}
		va += 64ull << 20;
		sysOk++;
	}
	// a new VM (its root table) and an exec queue on it
	struct drm_xe_vm_create vc = {0};
	CHECK(!xioctl(DRM_IOCTL_XE_VM_CREATE, &vc), "VM_CREATE with the window full: %d", errno);
	regions(&used, &size, &sys);
	printf("under pressure: %u more BOs, %u 4K-paged system binds; window %llu MB used, system BOs %llu MB\n",
		nbos - before, sysOk, used >> 20, sys >> 20);
	report("under pressure");
	// 3. contents: the CPU patterns, then GPU writes through each BO's VA (window or system memory alike)
	int bad = 0;
	for (uint32_t i = 0; i < nbos; i++) bad += checkPattern(bos[i].p, bos[i].size, bos[i].value) != 0;
	CHECK(!bad, "%d BOs lost CPU-written contents", bad);
	bad = 0;
	uint32_t gpu = 0;
	for (uint32_t i = 0; i < nbos && now() - t0 < 50; i += 1 + nbos / 200, gpu++) {
		if (gpuPattern(bos[i].va, bos[i].size, ~bos[i].value)) { bad++; continue; }
		bad += checkPattern(bos[i].p, bos[i].size, ~bos[i].value) != 0;
	}
	CHECK(!bad, "%d of %u BOs: the CPU does not see what the GPU wrote", bad, gpu);
	// 4. all gone again
	for (uint32_t i = 0; i < nbos; i++) {
		bind(vmId, 0, bos[i].va, bos[i].size, DRM_XE_VM_BIND_OP_UNMAP);
		kern_return_t kr = unmap(bos[i].type, (void *)bos[i].p);
		if (kr != KERN_SUCCESS && !fails) CHECK(0, "unmap of BO %u: 0x%x", i, kr);
		gemClose(bos[i].h);
	}
	regions(&used, &size, &sys);
	printf("freed: window %llu MB used, system BOs %llu MB (%.1f s)\n", used >> 20, sys >> 20, now() - t0);
	report("after");
	return fails;
}

int main(int argc, char **argv) {
	const char *mode = argc > 1 ? argv[1] : "";
	if (strcmp(mode, "unmap") && strcmp(mode, "fill")) {
		fprintf(stderr, "usage: winfill unmap | fill\n");
		return 2;
	}
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) {
		fprintf(stderr, "no IntelXe service\n");
		return 1;
	}
	if (gpuInit()) {
		fprintf(stderr, "VM / queue setup failed: %d\n", errno);
		return 1;
	}
	if (!strcmp(mode, "unmap")) testUnmap();
	else testFill();
	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
