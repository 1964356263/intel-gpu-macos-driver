// SPDX-License-Identifier: MIT
// rtt: job round trip through IntelXe.kext alone (no Mesa, no Metal plugin): a 2-dword batch (MI_STORE_DATA_IMM of a
// sequence number into system memory + MI_BATCH_BUFFER_END) per exec, on each engine class, timed in three pieces:
//   exec ioctl duration | exec return -> the GPU's store is visible to a spinning CPU | store visible -> SYNCOBJ_WAIT returns
// Modes: "wait" = SYNCOBJ_WAIT right after exec (interrupt path, what ANV does); "poll" = spin on the store first, then
// SYNCOBJ_WAIT (so the third piece is pure completion-notification latency). Gap = CPU spin between jobs.
// Measurement only.   clang -arch x86_64 -O2 -I../uapi -o rtt rtt.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xe_drm.h"

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
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static uint32_t gem(uint64_t size, uint32_t placement, uint32_t flags, uint16_t caching) {
	struct drm_xe_gem_create g = {.size = size, .placement = placement, .flags = flags, .cpu_caching = caching};
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
static void spin_ns(uint64_t d) { uint64_t t = ns(); while (ns() - t < d) __asm__ volatile("pause"); }
static void st(const char *nm, double *v, int n) {
	qsort(v, n, 8, dcmp); double s = 0; for (int i = 0; i < n; i++) s += v[i];
	printf("    %-26s p50 %7.1f  p90 %7.1f  p99 %7.1f  mean %7.1f us\n", nm, v[n / 2], v[n * 9 / 10], v[n * 99 / 100], s / n);
}

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	int N = argc > 1 ? atoi(argv[1]) : 500;
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create\n"); return 1; }
	uint32_t batch = gem(0x10000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB), target = gem(0x1000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
	volatile uint32_t *bb = map(batch, 0x10000), *tg = map(target, 0x1000);
	if (!bb || !tg) { fprintf(stderr, "map\n"); return 1; }
	if (bind(vc.vm_id, batch, 0x100000, 0x10000, 2) || bind(vc.vm_id, target, 0x200000, 0x1000, 2)) { fprintf(stderr, "bind\n"); return 1; }
	struct drm_syncobj_create sc = {0};
	xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc);
	uint32_t h[1] = {sc.handle};
	const char *cls[] = {"render", "copy", "", "", "compute"};
	uint16_t classes[] = {DRM_XE_ENGINE_CLASS_RENDER, DRM_XE_ENGINE_CLASS_COMPUTE, DRM_XE_ENGINE_CLASS_COPY};
	uint64_t gaps[] = {0, 20000, 100000, 1000000};
	double *ex = calloc(N, 8), *vis = calloc(N, 8), *wk = calloc(N, 8), *tot = calloc(N, 8);
	for (int ci = 0; ci < 3; ci++) {
		struct drm_xe_engine_class_instance ei = {.engine_class = classes[ci]};
		struct drm_xe_exec_queue_create q = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id, .instances = (uint64_t)(uintptr_t)&ei};
		if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &q)) { printf("%s: no queue (%d)\n", cls[classes[ci]], errno); continue; }
		for (int mode = 0; mode < 2; mode++) for (int gi = 0; gi < 4; gi++) {
			int n = gi == 3 ? N / 5 : N; if (n < 20) n = 20;
			for (int i = 0; i < n + 5; i++) {
				uint32_t seq = 0x10000000u | ci << 24 | mode << 20 | gi << 16 | (i & 0xffff);
				bb[0] = 0x20 << 23 | 2; bb[1] = 0x200000; bb[2] = 0; bb[3] = seq; bb[4] = 0xa << 23; bb[5] = 0;
				__sync_synchronize();
				spin_ns(gaps[gi]);
				struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle};
				struct drm_xe_exec x = {.exec_queue_id = q.exec_queue_id, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s,
					.address = 0x100000, .num_batch_buffer = 1};
				uint64_t t0 = ns();
				if (xioctl(DRM_IOCTL_XE_EXEC, &x)) { printf("exec failed %d\n", errno); return 1; }
				uint64_t t1 = ns(), t2 = t1;
				if (mode == 1) { while (tg[0] != seq && ns() - t1 < 1000000000ull) __asm__ volatile("pause"); t2 = ns(); }
				struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)h, .count_handles = 1, .timeout_nsec = (int64_t)(ns() + 2000000000ull)};
				if (xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w)) { printf("wait failed %d\n", errno); return 1; }
				uint64_t t3 = ns();
				if (tg[0] != seq) printf("store missing\n");
				if (i >= 5) { ex[i - 5] = (t1 - t0) / 1e3; vis[i - 5] = (t2 - t1) / 1e3; wk[i - 5] = (t3 - t2) / 1e3; tot[i - 5] = (t3 - t0) / 1e3; }
			}
			printf("  %-7s %s gap %5llu us (n %d)\n", cls[classes[ci]], mode ? "poll+wait" : "wait     ", gaps[gi] / 1000, n);
			st("exec ioctl", ex, n);
			if (mode) { st("exec ret -> store visible", vis, n); st("visible -> wait returns", wk, n); }
			else st("exec ret -> wait returns", wk, n);
			st("total", tot, n);
		}
		struct drm_xe_exec_queue_destroy d = {.exec_queue_id = q.exec_queue_id};
		xioctl(DRM_IOCTL_XE_EXEC_QUEUE_DESTROY, &d);
	}
	return 0;
}
