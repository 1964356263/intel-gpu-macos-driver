// SPDX-License-Identifier: MIT
// dupimport: rb7l regression test for two imports of one VRAM-shared IOSurface backing in one process (what WindowServer
// does when it makes a new wrapper for an app's window surface before it frees the old one). Mesa ANV releases a BO with
// DRM_XE_VM_BIND_OP_UNMAP_ALL of its handle (xe_vm_unbind_bo); the kernel must then drop only the bindings made through
// that handle, not those of the other import of the same backing. Before rb7l it dropped every binding of the BO, the
// second import's VA fell back to the scratch page and the window read zeros (Minecraft's black flicker, 2026-10-31).
// Needs debug.intelxe.surfvram >= 1 (sudo sysctl -w debug.intelxe.surfvram=1). Only when no game/benchmark runs. Steps:
//   1. a 2560x1440 BGRA IOSurface; SURFACE_VRAM CREATE -> handle h1; SURFACE_VRAM again (no CREATE) -> handle h2, same gen
//   2. a scratch VM (as Mesa makes it): h1 at VA1, h2 at VA2; the copy engine writes pattern A through VA1
//   3. reading through VA2 gives pattern A (both imports map the same VRAM)
//   4. UNMAP_ALL of h1, GEM_CLOSE h1 (Mesa's release of the first import)
//   5. reading through VA2 still gives pattern A. rb7k and before: all zeros (scratch) -> FAIL
//   6. UNMAP_ALL of h2 + GEM_CLOSE: VA2 now reads zeros (the unmap itself still works)
//   7. rb7m: an import with INTELXE_SURFACE_VRAM_SAME_HANDLE returns the client's existing handle; without it, a new one
// clang -arch x86_64 -O2 -I../uapi -o dupimport dupimport.c -framework IOKit -framework IOSurface -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurface.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "xe_drm.h"
#include "intelxe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) { errno = ENXIO; return -1; }
	errno = (int)out;
	return out ? -1 : 0;
}
static mach_timebase_info_data_t tb;
static uint64_t ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } \
	else { printf("PASS "); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { W = 2560, H = 1440, ROW = W * 4 };
static const uint64_t kBytes = (uint64_t)ROW * H;
static const uint64_t kBatch = 0x100000, kSys = 0x10000000, kVa1 = 0x40000000, kVa2 = 0x80000000;

static uint32_t gem(uint64_t size, uint32_t placement) {
	struct drm_xe_gem_create g = {.size = size, .placement = placement, .cpu_caching = DRM_XE_GEM_CPU_CACHING_WB};
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
static int vmBind(uint32_t vm, uint32_t op, uint32_t bo, uint64_t addr, uint64_t range, uint16_t pat) {
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1};
	b.bind.obj = bo; b.bind.range = range; b.bind.addr = addr; b.bind.op = op; b.bind.pat_index = pat;
	return xioctl(DRM_IOCTL_XE_VM_BIND, &b) ? errno : 0;
}
static uint32_t syncobj(void) {
	struct drm_syncobj_create sc = {0};
	if (xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc)) { fprintf(stderr, "syncobj %d\n", errno); exit(1); }
	return sc.handle;
}
static int waitBin(uint32_t h, uint64_t timeoutNs) {
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&h, .count_handles = 1, .timeout_nsec = (int64_t)(ns() + timeoutNs)};
	return xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w) ? errno : 0;
}
static void pattern(uint32_t *p, uint32_t seed) { for (uint32_t i = 0; i < kBytes / 4; i++) p[i] = (i * 2654435761u) ^ seed; }
static long mismatches(const uint32_t *p, uint32_t seed, long *zeros) {
	long bad = 0, z = 0;
	for (uint32_t i = 0; i < kBytes / 4; i++) { if (p[i] != ((i * 2654435761u) ^ seed)) bad++; if (!p[i]) z++; }
	if (zeros) *zeros = z;
	return bad;
}

static struct { uint32_t vm, q, batch, sys; uint32_t *bp, *sp; } g;
// MEM_COPY (page mode, 4 MB per command) of kBytes from src to dst on the copy engine; waits for it. 0 = done.
static int gpuCopy(uint64_t src, uint64_t dst) {
	uint32_t k = 0;
	for (uint64_t off = 0; off < kBytes; off += 4u << 20) {
		const uint64_t chunk = kBytes - off < (4u << 20) ? kBytes - off : (4u << 20);
		const uint64_t s = src + off, d = dst + off;
		g.bp[k++] = (2u << 29 | 0x5au << 22) | 1u << 19 | (10 - 2);
		g.bp[k++] = (uint32_t)(chunk / 256) - 1; g.bp[k++] = (uint32_t)(chunk / 0x1000) - 1; g.bp[k++] = 0xfff; g.bp[k++] = 0xfff;
		g.bp[k++] = (uint32_t)s; g.bp[k++] = (uint32_t)(s >> 32); g.bp[k++] = (uint32_t)d; g.bp[k++] = (uint32_t)(d >> 32);
		g.bp[k++] = 3u << 28 | 3u << 3;
	}
	g.bp[k++] = 0xa << 23; g.bp[k++] = 0;
	__sync_synchronize();
	const uint32_t so = syncobj();
	struct drm_xe_sync sy = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = so};
	struct drm_xe_exec x = {.exec_queue_id = g.q, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&sy, .address = kBatch, .num_batch_buffer = 1};
	int r = xioctl(DRM_IOCTL_XE_EXEC, &x) ? errno : waitBin(so, 2000000000ull);
	struct drm_syncobj_destroy dd = {.handle = so};
	xioctl(DRM_IOCTL_SYNCOBJ_DESTROY, &dd);
	return r;
}

int main(void) {
	mach_timebase_info(&tb);
	setvbuf(stdout, NULL, _IOLBF, 0);
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	struct drm_get_cap cap = {.capability = INTELXE_CAP_SURFACE_VRAM};
	if (xioctl(DRM_IOCTL_GET_CAP, &cap) || !cap.value) {
		fprintf(stderr, "debug.intelxe.surfvram is 0: sudo sysctl -w debug.intelxe.surfvram=1\n");
		return 2;
	}
	CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, (int[]){W}), h = CFNumberCreate(NULL, kCFNumberIntType, (int[]){H}),
	            bpe = CFNumberCreate(NULL, kCFNumberIntType, (int[]){4}), bpr = CFNumberCreate(NULL, kCFNumberIntType, (int[]){ROW}),
	            pf = CFNumberCreate(NULL, kCFNumberIntType, (int[]){0x42475241});
	const void *k[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow, kIOSurfacePixelFormat};
	const void *v[] = {w, h, bpe, bpr, pf};
	CFDictionaryRef props = CFDictionaryCreate(NULL, k, v, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef sf = IOSurfaceCreate(props);
	if (!sf) { fprintf(stderr, "IOSurfaceCreate\n"); return 1; }
	const uint32_t sid = IOSurfaceGetID(sf), seed = 0xa0000000u ^ (uint32_t)(ns() & 0xffffff);
	// 1
	struct drm_intelxe_surface_vram v1 = {.surface_id = sid, .size = kBytes, .flags = INTELXE_SURFACE_VRAM_CREATE};
	struct drm_intelxe_surface_vram v2 = {.surface_id = sid, .size = kBytes};
	int r = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v1) ? errno : 0;
	CHECK(!r && v1.handle, "CREATE -> handle %u, %llu bytes, gen %u (err %d)", v1.handle, (unsigned long long)v1.size_out, v1.gen, r);
	if (r) return 1;
	r = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v2) ? errno : 0;
	CHECK(!r && v2.handle && v2.handle != v1.handle && v2.gen == v1.gen, "second import -> handle %u (gen %u, err %d)", v2.handle, v2.gen, r);
	if (r) return 1;
	// 2
	struct drm_xe_vm_create vc = {.flags = DRM_XE_VM_CREATE_FLAG_SCRATCH_PAGE};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create %d\n", errno); return 1; }
	g.vm = vc.vm_id;
	const uint64_t sysSize = (kBytes + 0xffff) & ~0xffffull;
	g.batch = gem(0x10000, 1); g.sys = gem(sysSize, 1);
	g.bp = map(g.batch, 0x10000); g.sp = map(g.sys, sysSize);
	r = (!g.bp || !g.sp) ? ENOMEM : vmBind(g.vm, DRM_XE_VM_BIND_OP_MAP, g.batch, kBatch, 0x10000, 2);
	if (!r) r = vmBind(g.vm, DRM_XE_VM_BIND_OP_MAP, g.sys, kSys, sysSize, 2);
	if (!r) r = vmBind(g.vm, DRM_XE_VM_BIND_OP_MAP, v1.handle, kVa1, v1.size_out, 0);
	if (!r) r = vmBind(g.vm, DRM_XE_VM_BIND_OP_MAP, v2.handle, kVa2, v2.size_out, 0);
	CHECK(!r, "VM with scratch: system BO, h1 at 0x%llx, h2 at 0x%llx (err %d)", (unsigned long long)kVa1, (unsigned long long)kVa2, r);
	if (r) return 1;
	struct drm_xe_engine_class_instance ei = {.engine_class = DRM_XE_ENGINE_CLASS_COPY};
	struct drm_xe_exec_queue_create q = {.width = 1, .num_placements = 1, .vm_id = g.vm, .instances = (uint64_t)(uintptr_t)&ei};
	if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &q)) { fprintf(stderr, "queue %d\n", errno); return 1; }
	g.q = q.exec_queue_id;
	pattern(g.sp, seed);
	CHECK(!gpuCopy(kSys, kVa1), "copy engine writes pattern A through h1");
	// 3
	long z = 0, bad;
	memset(g.sp, 0, kBytes);
	r = gpuCopy(kVa2, kSys);
	bad = mismatches(g.sp, seed, &z);
	CHECK(!r && !bad, "read through h2: pattern A (%ld dwords differ, %ld zero)", bad, z);
	// 4
	r = vmBind(g.vm, DRM_XE_VM_BIND_OP_UNMAP_ALL, v1.handle, 0, 0, 0);
	struct drm_gem_close c1 = {.handle = v1.handle};
	CHECK(!r && !xioctl(DRM_IOCTL_GEM_CLOSE, &c1), "UNMAP_ALL h1 + GEM_CLOSE h1 (Mesa releasing the first import; err %d)", r);
	// 5
	memset(g.sp, 0, kBytes);
	r = gpuCopy(kVa2, kSys);
	bad = mismatches(g.sp, seed, &z);
	CHECK(!r && !bad, "read through h2 after h1 went: still pattern A (%ld dwords differ, %ld zero%s)", bad, z,
	      z == (long)(kBytes / 4) ? ": h2's mapping is gone, the scratch page answered - the rb7k bug" : "");
	// 6
	r = vmBind(g.vm, DRM_XE_VM_BIND_OP_UNMAP_ALL, v2.handle, 0, 0, 0);
	struct drm_gem_close c2 = {.handle = v2.handle};
	xioctl(DRM_IOCTL_GEM_CLOSE, &c2);
	memset(g.sp, 0xff, kBytes);
	const int r2 = gpuCopy(kVa2, kSys);
	mismatches(g.sp, seed, &z);
	CHECK(!r && !r2 && z == (long)(kBytes / 4), "UNMAP_ALL h2: VA2 reads the scratch page's zeros (%ld of %llu dwords zero; err %d/%d)", z,
	      (unsigned long long)(kBytes / 4), r, r2);
	// 7 (rb7m): INTELXE_SURFACE_VRAM_SAME_HANDLE gives back the handle this client already holds for the backing
	struct drm_intelxe_surface_vram v3 = {.surface_id = sid, .size = kBytes};
	struct drm_intelxe_surface_vram v4 = {.surface_id = sid, .size = kBytes, .flags = INTELXE_SURFACE_VRAM_SAME_HANDLE};
	struct drm_intelxe_surface_vram v5 = {.surface_id = sid, .size = kBytes};
	r = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v3) ? errno : 0;
	const int r4 = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v4) ? errno : 0;
	const int r5 = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v5) ? errno : 0;
	if (r4 == EINVAL)
		printf("INFO SAME_HANDLE: EINVAL (a kernel before rb7m)\n");
	else
		CHECK(!r && !r4 && v4.handle == v3.handle && v4.gen == v3.gen, "SAME_HANDLE import -> the existing handle %u (got %u, err %d/%d)", v3.handle, v4.handle, r, r4);
	CHECK(!r5 && v5.handle != v3.handle, "import without SAME_HANDLE -> a handle of its own (%u, err %d)", v5.handle, r5);
	struct drm_gem_close c3 = {.handle = v3.handle}, c5 = {.handle = v5.handle};
	xioctl(DRM_IOCTL_GEM_CLOSE, &c3); xioctl(DRM_IOCTL_GEM_CLOSE, &c5);
	struct drm_xe_vm_destroy vd = {.vm_id = g.vm};
	xioctl(DRM_IOCTL_XE_VM_DESTROY, &vd);
	CFRelease(sf);
	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
