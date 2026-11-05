// SPDX-License-Identifier: MIT
// surfvram: end-to-end test of VRAM-shared IOSurfaces (gpuperf phase 1: IntelXe.kext SURFACE_VRAM / SURFACE_DIRTY and
// NMXAccel's family page-off). Needs debug.intelxe.surfvram >= 1 (sudo sysctl -w debug.intelxe.surfvram=1); reads
// debug.intelxe.surfvram_stats. Only when no game/benchmark runs. Each step prints PASS/FAIL:
//   1. a global 2560x1440 BGRA IOSurface; SURFACE_VRAM CREATE -> a handle to its VRAM backing; a second lookup without
//      CREATE -> the same backing (same size, same generation)
//   2. the copy engine writes pattern A into the backing (MEM_COPY from a system BO); WRITE fence attached; SURFACE_DIRTY
//   3. a CPU IOSurfaceLock (read-only) must show pattern A in the surface's pages: the family pages it off (timed)
//   4. another process (posix_spawn of this binary) looks the surface up, imports the same backing without CREATE, copies
//      it back with its own GPU job and finds pattern A; then writes pattern B into it, attaches its fence, marks it dirty
//      and exits (its handle and client go with it)
//   5. back here: a CPU lock shows pattern B (the other process's write, paged off after it exited)
//   6. errors: import of a surface without a backing ENOENT, plane 1 EINVAL, a backing over the budget ENOSPC
//   7. the surface released: its backing leaves the registry (debug.intelxe.surfvram_stats backings back to the start count)
// clang -arch x86_64 -O2 -I../uapi -o surfvram surfvram.c -framework IOKit -framework IOSurface -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurface.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include "xe_drm.h"
#include "intelxe_drm.h"

extern char **environ;
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
static const uint64_t kBytes = (uint64_t)ROW * H;   // 14745600 (3600 pages)
enum { kBatch = 0x100000, kSys = 0x10000000, kSurf = 0x40000000 };

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
static int bind(uint32_t vm, uint32_t bo, uint64_t addr, uint64_t range, uint16_t pat) {
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1};
	b.bind.obj = bo; b.bind.range = range; b.bind.addr = addr; b.bind.op = DRM_XE_VM_BIND_OP_MAP; b.bind.pat_index = pat;
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
static int waitBin(uint32_t h, uint64_t timeoutNs) {
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)&h, .count_handles = 1, .timeout_nsec = (int64_t)(ns() + timeoutNs)};
	return xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w) ? errno : 0;
}
static int surfVram(uint32_t sid, uint32_t plane, uint64_t size, uint32_t flags, struct drm_intelxe_surface_vram *out) {
	struct drm_intelxe_surface_vram v = {.surface_id = sid, .plane = plane, .size = size, .flags = flags};
	const int r = xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM, &v) ? errno : 0;
	if (out) *out = v;
	return r;
}
static int surfDirty(uint32_t sid) {
	struct drm_intelxe_surface_dirty d = {.surface_id = sid};
	return xioctl(DRM_IOCTL_INTELXE_SURFACE_DIRTY, &d) ? errno : 0;
}
static int attach(uint32_t surf, uint32_t so, uint32_t flags) {
	struct drm_intelxe_surface_fence_attach a = {.surface_id = surf, .syncobj = so, .flags = flags};
	return xioctl(DRM_IOCTL_INTELXE_SURFACE_FENCE_ATTACH, &a) ? errno : 0;
}
static void pattern(uint32_t *p, uint32_t seed) { for (uint32_t i = 0; i < kBytes / 4; i++) p[i] = (i * 2654435761u) ^ seed; }
static long mismatches(const uint32_t *p, uint32_t seed) {
	long bad = 0;
	for (uint32_t i = 0; i < kBytes / 4; i++) if (p[i] != ((i * 2654435761u) ^ seed)) bad++;
	return bad;
}

// The GPU side of one process: a VM with a system BO (CPU-mapped) and the surface's backing, a copy queue.
static struct { uint32_t vm, q, so, batch, sys; uint32_t *bp, *sp; } g;
static void gpuSetup(uint32_t surfHandle, uint64_t surfSize) {
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create %d\n", errno); exit(1); }
	g.vm = vc.vm_id;
	g.batch = gem(0x10000, 1); g.sys = gem((kBytes + 0xffff) & ~0xffffull, 1);
	g.bp = map(g.batch, 0x10000); g.sp = map(g.sys, (kBytes + 0xffff) & ~0xffffull);
	if (!g.bp || !g.sp || bind(g.vm, g.batch, kBatch, 0x10000, 2) || bind(g.vm, g.sys, kSys, (kBytes + 0xffff) & ~0xffffull, 2) ||
		bind(g.vm, surfHandle, kSurf, surfSize, 0)) { fprintf(stderr, "gpu setup %d\n", errno); exit(1); }
	g.q = queue(g.vm, DRM_XE_ENGINE_CLASS_COPY);
	g.so = syncobj();
}
// MEM_COPY (page mode, 4 MB per command) of kBytes between the system BO and the backing; waits; 0 = done
static int gpuCopy(int toSurface) {
	uint32_t k = 0;
	for (uint64_t off = 0; off < kBytes; off += 4u << 20) {
		const uint64_t chunk = kBytes - off < (4u << 20) ? kBytes - off : (4u << 20);
		const uint64_t s = (toSurface ? kSys : kSurf) + off, d = (toSurface ? kSurf : kSys) + off;
		g.bp[k++] = (2u << 29 | 0x5au << 22) | 1u << 19 | (10 - 2);
		g.bp[k++] = (uint32_t)(chunk / 256) - 1; g.bp[k++] = (uint32_t)(chunk / 0x1000) - 1; g.bp[k++] = 0xfff; g.bp[k++] = 0xfff;
		g.bp[k++] = (uint32_t)s; g.bp[k++] = (uint32_t)(s >> 32); g.bp[k++] = (uint32_t)d; g.bp[k++] = (uint32_t)(d >> 32);
		g.bp[k++] = 3u << 28 | 3u << 3;
	}
	g.bp[k++] = 0xa << 23; g.bp[k++] = 0;
	__sync_synchronize();
	struct drm_syncobj_destroy dd = {.handle = g.so};
	xioctl(DRM_IOCTL_SYNCOBJ_DESTROY, &dd);
	g.so = syncobj();
	struct drm_xe_sync sy = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = g.so};
	struct drm_xe_exec x = {.exec_queue_id = g.q, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&sy, .address = kBatch, .num_batch_buffer = 1};
	if (xioctl(DRM_IOCTL_XE_EXEC, &x)) return errno;
	return 0;
}
static int open_intelxe(void) {
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	struct drm_get_cap cap = {.capability = INTELXE_CAP_SURFACE_VRAM};
	if (xioctl(DRM_IOCTL_GET_CAP, &cap) || !cap.value) {
		fprintf(stderr, "debug.intelxe.surfvram is 0 (or this IntelXe.kext has no SURFACE_VRAM): sudo sysctl -w debug.intelxe.surfvram=1\n");
		return 2;
	}
	return 0;
}
static void stats(const char *when) {
	char b[512] = ""; size_t n = sizeof b;
	if (!sysctlbyname("debug.intelxe.surfvram_stats", b, &n, NULL, 0)) printf("  [%s] %s", when, b);
}
static unsigned backings(void) {
	char b[512] = ""; size_t n = sizeof b; unsigned c = 0;
	if (!sysctlbyname("debug.intelxe.surfvram_stats", b, &n, NULL, 0)) { const char *p = strstr(b, "): "); if (p) c = (unsigned)atoi(p + 3); }
	return c;
}

static int child(uint32_t sid, uint32_t seedA, uint32_t seedB) {
	if (open_intelxe()) return 3;
	IOSurfaceRef sf = IOSurfaceLookup(sid);
	CHECK(sf != NULL, "child: IOSurfaceLookup(%u)", sid);
	if (!sf) return 1;
	struct drm_intelxe_surface_vram v;
	const int r = surfVram(sid, 0, kBytes, 0, &v);
	CHECK(r == 0, "child: import without CREATE -> handle %u, %llu bytes, gen %u (err %d)", v.handle, (unsigned long long)v.size_out, v.gen, r);
	if (r) return 1;
	gpuSetup(v.handle, v.size_out);
	memset(g.sp, 0, kBytes);
	CHECK(!gpuCopy(0) && !waitBin(g.so, 2000000000ull), "child: GPU copy backing -> system BO");
	const long bad = mismatches(g.sp, seedA);
	CHECK(bad == 0, "child: the backing holds the parent's pattern A (%ld dwords differ)", bad);
	pattern(g.sp, seedB);
	CHECK(!gpuCopy(1), "child: GPU writes pattern B into the backing");
	CHECK(!attach(sid, g.so, INTELXE_SURFACE_FENCE_WRITE), "child: WRITE fence attached");
	CHECK(!surfDirty(sid), "child: SURFACE_DIRTY");
	CHECK(!waitBin(g.so, 2000000000ull), "child: write completed");
	CFRelease(sf);
	return fails ? 1 : 0;   // exits holding its handle: the client teardown drops it
}

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 5 && !strcmp(argv[1], "child")) return child((uint32_t)strtoul(argv[2], 0, 0), (uint32_t)strtoul(argv[3], 0, 0), (uint32_t)strtoul(argv[4], 0, 0));
	int r0 = open_intelxe();
	if (r0) return r0;
	stats("start");
	const unsigned base = backings();
	int one = 1;
	CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, (int[]){W}), h = CFNumberCreate(NULL, kCFNumberIntType, (int[]){H}),
	            bpe = CFNumberCreate(NULL, kCFNumberIntType, (int[]){4}), bpr = CFNumberCreate(NULL, kCFNumberIntType, (int[]){ROW}),
	            pf = CFNumberCreate(NULL, kCFNumberIntType, (int[]){0x42475241});
	const void *k[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow, kIOSurfacePixelFormat, kIOSurfaceIsGlobal};
	const void *v[] = {w, h, bpe, bpr, pf, kCFBooleanTrue};
	(void)one;
	CFDictionaryRef props = CFDictionaryCreate(NULL, k, v, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef sf = IOSurfaceCreate(props);
	if (!sf) { fprintf(stderr, "IOSurfaceCreate\n"); return 1; }
	const uint32_t sid = IOSurfaceGetID(sf);
	printf("surface %u, %zu bytes allocated\n", sid, IOSurfaceGetAllocSize(sf));
	const uint32_t seedA = 0xa0000000u ^ (uint32_t)(ns() & 0xffffff), seedB = seedA ^ 0x0b0b0b0bu;

	// 1
	struct drm_intelxe_surface_vram v1, v2;
	int r = surfVram(sid, 0, kBytes, INTELXE_SURFACE_VRAM_CREATE, &v1);
	CHECK(r == 0 && v1.handle && v1.size_out >= kBytes, "CREATE -> handle %u, %llu bytes, gen %u (err %d)", v1.handle, (unsigned long long)v1.size_out, v1.gen, r);
	if (r) { stats("after create"); return 1; }
	r = surfVram(sid, 0, kBytes, 0, &v2);
	CHECK(r == 0 && v2.size_out == v1.size_out && v2.gen == v1.gen, "second lookup without CREATE -> same backing (gen %u, %llu bytes)", v2.gen, (unsigned long long)v2.size_out);
	// 2
	gpuSetup(v1.handle, v1.size_out);
	pattern(g.sp, seedA);
	CHECK(!gpuCopy(1), "GPU writes pattern A into the backing");
	CHECK(!attach(sid, g.so, INTELXE_SURFACE_FENCE_WRITE), "WRITE fence attached");
	CHECK(!surfDirty(sid), "SURFACE_DIRTY");
	// 3 (the lock may come before the copy finished: the page-off waits for the surface's writers)
	uint64_t t0 = ns();
	IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
	const uint64_t lockUs = (ns() - t0) / 1000;
	long bad = mismatches(IOSurfaceGetBaseAddress(sf), seedA);
	IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
	CHECK(bad == 0, "CPU lock sees pattern A (paged off; lock took %llu us; %ld dwords differ)", (unsigned long long)lockUs, bad);
	// 4
	char a1[16], a2[16], a3[16];
	snprintf(a1, sizeof a1, "%u", sid); snprintf(a2, sizeof a2, "0x%x", seedA); snprintf(a3, sizeof a3, "0x%x", seedB);
	char *cargv[] = {argv[0], "child", a1, a2, a3, NULL};
	pid_t pid = 0; int st = 0;
	r = posix_spawn(&pid, argv[0], NULL, NULL, cargv, environ);
	CHECK(r == 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 0, "child process (import, read A, write B, exit): status %d", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
	// 5
	t0 = ns();
	IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
	const uint64_t lock2Us = (ns() - t0) / 1000;
	bad = mismatches(IOSurfaceGetBaseAddress(sf), seedB);
	IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
	CHECK(bad == 0, "CPU lock sees the other process's pattern B (lock took %llu us; %ld dwords differ)", (unsigned long long)lock2Us, bad);
	// a second lock with nothing new: no copy needed
	t0 = ns();
	IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
	const uint64_t lock3Us = (ns() - t0) / 1000;
	IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
	printf("INFO third lock (nothing newer on the GPU): %llu us\n", (unsigned long long)lock3Us);
	// 6
	IOSurfaceRef s2 = IOSurfaceCreate(props);
	r = s2 ? surfVram(IOSurfaceGetID(s2), 0, kBytes, 0, NULL) : -1;
	CHECK(r == ENOENT, "import of a surface without a backing: ENOENT (%d)", r);
	r = surfVram(sid, 1, kBytes, 0, NULL);
	CHECK(r == EINVAL, "plane 1: EINVAL (%d)", r);
	r = s2 ? surfVram(IOSurfaceGetID(s2), 0, 3ull << 30, INTELXE_SURFACE_VRAM_CREATE, NULL) : -1;
	CHECK(r == ENOSPC, "a 3 GB backing over the budget: ENOSPC (%d)", r);
	r = surfVram(999999, 0, kBytes, INTELXE_SURFACE_VRAM_CREATE, NULL);
	CHECK(r == ENOENT, "a surface ID this task cannot see: ENOENT (%d)", r);
	stats("before release");
	// 7
	struct drm_gem_close gc1 = {.handle = v1.handle}, gc2 = {.handle = v2.handle};
	struct drm_xe_vm_destroy vd = {.vm_id = g.vm};
	xioctl(DRM_IOCTL_XE_VM_DESTROY, &vd);
	xioctl(DRM_IOCTL_GEM_CLOSE, &gc1); xioctl(DRM_IOCTL_GEM_CLOSE, &gc2);
	CFRelease(sf); if (s2) CFRelease(s2);
	usleep(300000);
	const unsigned after = backings();
	CHECK(after == base, "surfaces released: %u backings in the registry (%u at the start)", after, base);
	stats("end");
	printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
