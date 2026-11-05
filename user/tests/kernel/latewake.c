// SPDX-License-Identifier: MIT
// latewake: are completion wakeups late, per engine class, independent of when the GPU ran the job? Each job is the rtt
// batch (MI_STORE_DATA_IMM of a sequence number into system memory + MI_BATCH_BUFFER_END). A spinner thread timestamps
// the moment the store becomes visible; the main thread sleeps in SYNCOBJ_WAIT. A wait that returns more than 1 ms after
// the store was visible was not woken by the job's interrupt (the kernel's 2 ms fallback slice caught it). Also prints
// the kernel's rescue counter before and after (debug.intelxe.stats, global: other clients count too).
// Measurement only.   clang -arch x86_64 -O2 -I../uapi -o latewake latewake.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
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
static mach_timebase_info_data_t tb;
static uint64_t ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }
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
static unsigned rescues(void) {
	char buf[2048]; size_t l = sizeof(buf);
	if (sysctlbyname("debug.intelxe.stats", buf, &l, NULL, 0)) return 0;
	const char *p = strstr(buf, "(missed interrupt) ");
	return p ? (unsigned)strtoul(p + 19, NULL, 10) : 0;
}

static volatile uint32_t *tg;
static volatile uint32_t want, stop;
static volatile uint64_t seenAt, releaseAt;
// Releases the batch's MI_SEMAPHORE_WAIT (dword 16 of the target) at releaseAt, then timestamps the store.
static void *spinner(void *a) {
	while (!stop) {
		const uint32_t w = want;
		if (w && releaseAt && ns() >= releaseAt && tg[16] != w) { tg[16] = w; __sync_synchronize(); }
		if (w && tg[0] == w && !seenAt) seenAt = ns();
		__asm__ volatile("pause");
	}
	return a;
}

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	const int N = argc > 1 ? atoi(argv[1]) : 400;
	const uint64_t gap = (argc > 2 ? strtoull(argv[2], NULL, 0) : 200) * 1000;
	// hold: the batch first waits (MI_SEMAPHORE_WAIT, polling) until the CPU releases it this many us after the exec
	const uint64_t hold = (argc > 3 ? strtoull(argv[3], NULL, 0) : 0) * 1000;
	struct drm_xe_vm_create vc = {0};
	if (xioctl(DRM_IOCTL_XE_VM_CREATE, &vc)) { fprintf(stderr, "vm create\n"); return 1; }
	uint32_t batch = gem(0x10000), target = gem(0x1000);
	volatile uint32_t *bb = map(batch, 0x10000);
	tg = map(target, 0x1000);
	if (!bb || !tg || bind(vc.vm_id, batch, 0x100000, 0x10000) || bind(vc.vm_id, target, 0x200000, 0x1000)) { fprintf(stderr, "setup\n"); return 1; }
	struct drm_syncobj_create sc = {0};
	xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc);
	uint32_t h[1] = {sc.handle};
	pthread_t th;
	pthread_create(&th, NULL, spinner, NULL);
	const char *names[] = {"render", "copy", "", "", "compute"};
	const uint16_t classes[] = {DRM_XE_ENGINE_CLASS_RENDER, DRM_XE_ENGINE_CLASS_COMPUTE, DRM_XE_ENGINE_CLASS_COPY};
	for (int ci = 0; ci < 3; ci++) {
		struct drm_xe_engine_class_instance ei = {.engine_class = classes[ci]};
		struct drm_xe_exec_queue_create q = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id, .instances = (uint64_t)(uintptr_t)&ei};
		if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &q)) { printf("%s: no queue (%d)\n", names[classes[ci]], errno); continue; }
		const unsigned r0 = rescues();
		int late = 0, gpuLate = 0, unseen = 0;
		double worst = 0, sumLate = 0;
		for (int i = 0; i < N; i++) {
			const uint32_t seq = 0x20000000u | ci << 24 | (i & 0xffffff);
			uint32_t k = 0;
			if (hold) {   // MI_SEMAPHORE_WAIT | POLL | SAD_EQ_SDD, PPGTT, 5 dwords
				bb[k++] = 0x1c << 23 | 1u << 15 | 4u << 12 | 3; bb[k++] = seq; bb[k++] = 0x200040; bb[k++] = 0; bb[k++] = 0;
			}
			bb[k++] = 0x20 << 23 | 2; bb[k++] = 0x200000; bb[k++] = 0; bb[k++] = seq; bb[k++] = 0xa << 23; bb[k++] = 0;
			__sync_synchronize();
			releaseAt = 0;
			const uint64_t g0 = ns();
			while (ns() - g0 < gap) __asm__ volatile("pause");
			seenAt = 0;
			want = seq;
			struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle};
			struct drm_xe_exec x = {.exec_queue_id = q.exec_queue_id, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s,
				.address = 0x100000, .num_batch_buffer = 1};
			const uint64_t t0 = ns();
			if (xioctl(DRM_IOCTL_XE_EXEC, &x)) { printf("exec failed %d\n", errno); return 1; }
			if (hold) releaseAt = t0 + hold;
			struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)h, .count_handles = 1, .timeout_nsec = (int64_t)(ns() + 2000000000ull)};
			if (xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w)) { printf("wait failed %d\n", errno); return 1; }
			const uint64_t t3 = ns();
			want = 0;
			const uint64_t seen = seenAt;
			if (!seen) { unseen++; continue; }   // the spinner was descheduled: no visibility time
			const double after = seen < t3 ? (t3 - seen) / 1e3 : 0;
			if (seen - t0 > hold + 1000000) gpuLate++;
			if (after > 1000) { late++; sumLate += after; }
			if (after > worst) worst = after;
		}
		const unsigned r1 = rescues();
		printf("%-7s n %d gap %llu us hold %llu us: wait returned >1 ms after the store was visible: %d (mean %.0f us), worst %.0f us; "
			"store visible >1 ms after the release: %d; spinner missed %d; kernel rescues meanwhile %u (all clients)\n",
			names[classes[ci]], N, gap / 1000, hold / 1000, late, late ? sumLate / late : 0, worst, gpuLate, unseen, r1 - r0);
		struct drm_xe_exec_queue_destroy d = {.exec_queue_id = q.exec_queue_id};
		xioctl(DRM_IOCTL_XE_EXEC_QUEUE_DESTROY, &d);
	}
	stop = 1;
	pthread_join(th, NULL);
	return 0;
}
