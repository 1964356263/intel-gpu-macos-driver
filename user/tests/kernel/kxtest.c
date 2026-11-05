// SPDX-License-Identifier: MIT
// kxtest: drives IntelXe.kext's xe interface the way Mesa's ANV does, without Mesa. Build on the build Mac:
//   clang -arch x86_64 -O1 -I../uapi -o kxtest kxtest.c -framework IOKit -framework CoreFoundation
// Run on the hackintosh (no developer tools needed): ./kxtest
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
	kern_return_t kr = IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n);
	if (kr) {
		fprintf(stderr, "IOConnectCallScalarMethod 0x%x\n", kr);
		return -1;
	}
	errno = (int)out;
	return out ? -1 : 0;
}

#define CHECK(x) do { if ((x) != 0) { fprintf(stderr, "FAIL %s: errno %d\n", #x, errno); return 1; } } while (0)

static void *query(uint32_t kind, uint32_t *size) {
	struct drm_xe_device_query q = {.query = kind};
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q)) return NULL;
	void *buf = calloc(1, q.size);
	q.data = (uint64_t)(uintptr_t)buf;
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q)) return NULL;
	*size = q.size;
	return buf;
}

static uint32_t gem(uint64_t size, uint32_t placement, uint32_t flags, uint16_t caching) {
	struct drm_xe_gem_create g = {.size = size, .placement = placement, .flags = flags, .cpu_caching = caching};
	if (xioctl(DRM_IOCTL_XE_GEM_CREATE, &g)) {
		fprintf(stderr, "GEM_CREATE failed: %d\n", errno);
		exit(1);
	}
	return g.handle;
}

static void *map(uint32_t handle, uint64_t size) {
	struct drm_xe_gem_mmap_offset m = {.handle = handle};
	if (xioctl(DRM_IOCTL_XE_GEM_MMAP_OFFSET, &m)) return NULL;
	mach_vm_address_t addr = 0;
	mach_vm_size_t sz = size;
	if (IOConnectMapMemory64(conn, (uint32_t)(m.offset >> 12), mach_task_self(), &addr, &sz, kIOMapAnywhere)) return NULL;
	return (void *)(uintptr_t)addr;
}

static int bind(uint32_t vm, uint32_t bo, uint64_t addr, uint64_t range, uint16_t pat) {
	struct drm_xe_vm_bind b = {.vm_id = vm, .num_binds = 1};
	b.bind.obj = bo;
	b.bind.range = range;
	b.bind.addr = addr;
	b.bind.op = DRM_XE_VM_BIND_OP_MAP;
	b.bind.pat_index = pat;
	return xioctl(DRM_IOCTL_XE_VM_BIND, &b);
}

static uint64_t absNs(uint64_t fromNow) {
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return mach_absolute_time() * tb.numer / tb.denom + fromNow;
}

int main(int argc, char **argv) {
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) {
		fprintf(stderr, "no IntelXe service\n");
		return 1;
	}
	char name[16] = {0};
	struct drm_version v = {.name = name, .name_len = sizeof(name) - 1};
	CHECK(xioctl(DRM_IOCTL_VERSION, &v));
	printf("driver \"%s\" %d.%d\n", name, v.version_major, v.version_minor);

	uint32_t sz;
	struct drm_xe_query_config *cfg = query(DRM_XE_DEVICE_QUERY_CONFIG, &sz);
	struct drm_xe_query_engines *eng = query(DRM_XE_DEVICE_QUERY_ENGINES, &sz);
	struct drm_xe_query_mem_regions *mem = query(DRM_XE_DEVICE_QUERY_MEM_REGIONS, &sz);
	struct drm_xe_query_gt_list *gts = query(DRM_XE_DEVICE_QUERY_GT_LIST, &sz);
	uint32_t hwsz, topsz;
	void *hw = query(DRM_XE_DEVICE_QUERY_HWCONFIG, &hwsz);
	uint8_t *top = query(DRM_XE_DEVICE_QUERY_GT_TOPOLOGY, &topsz);
	if (!cfg || !eng || !mem || !gts || !hw || !top) {
		fprintf(stderr, "query failed\n");
		return 1;
	}
	printf("config: devid 0x%llx flags 0x%llx align %llu va_bits %llu\n", cfg->info[0], cfg->info[1], cfg->info[2], cfg->info[3]);
	printf("engines: %u (class %u inst %u)\n", eng->num_engines, eng->engines[0].instance.engine_class,
		eng->engines[0].instance.engine_instance);
	for (uint32_t i = 0; i < eng->num_engines; i++)
		printf("  engine %u: class %u inst %u gt %u\n", i, eng->engines[i].instance.engine_class,
			eng->engines[i].instance.engine_instance, eng->engines[i].instance.gt_id);
	for (uint32_t i = 0; i < gts->num_gt; i++)
		printf("  gt %u: type %u ip %u.%u\n", gts->gt_list[i].gt_id, gts->gt_list[i].type, gts->gt_list[i].ip_ver_major,
			gts->gt_list[i].ip_ver_minor);
	for (uint32_t i = 0; i < mem->num_mem_regions; i++)
		printf("mem %u: class %u inst %u total %llu MB visible %llu MB\n", i, mem->mem_regions[i].mem_class,
			mem->mem_regions[i].instance, mem->mem_regions[i].total_size >> 20, mem->mem_regions[i].cpu_visible_size >> 20);
	printf("gt0: refclk %u Hz, IP %u.%u; hwconfig %u bytes; topology %u bytes\n", gts->gt_list[0].reference_clock,
		gts->gt_list[0].ip_ver_major, gts->gt_list[0].ip_ver_minor, hwsz, topsz);

	struct drm_xe_vm_create vc = {0};
	CHECK(xioctl(DRM_IOCTL_XE_VM_CREATE, &vc));

	if (argc > 1 && !strcmp(argv[1], "load")) {
		// GPU load for frequency tests: a 4 MB batch of 65535 MI_STORE_DATA_IMM, submitted N times on the render queue.
		uint32_t lb = gem(0x400000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB), lt = gem(0x1000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
		uint32_t *lbb = map(lb, 0x400000);
		CHECK(bind(vc.vm_id, lb, 0x1000000, 0x400000, 2));
		CHECK(bind(vc.vm_id, lt, 0x2000000, 0x1000, 2));
		uint32_t k = 0;
		uint32_t stores = argc > 3 ? (uint32_t)atoi(argv[3]) : 65535;
		for (uint32_t i = 0; i < stores; i++) {
			lbb[k++] = 0x20 << 23 | 2;
			lbb[k++] = 0x2000000 + (i & 1023) * 4;
			lbb[k++] = 0;
			lbb[k++] = i;
		}
		lbb[k++] = 0xa << 23;
		lbb[k++] = 0;
		__sync_synchronize();
		struct drm_xe_engine_class_instance ei = {.engine_class = DRM_XE_ENGINE_CLASS_RENDER};
		struct drm_xe_exec_queue_create lq = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id, .instances = (uint64_t)(uintptr_t)&ei};
		CHECK(xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &lq));
		struct drm_syncobj_create ls = {0};
		CHECK(xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &ls));
		uint32_t lh[1] = {ls.handle};
		int rounds = argc > 2 ? atoi(argv[2]) : 300;
		uint64_t t0 = absNs(0);
		for (int r = 0; r < rounds; r++) {
			struct drm_xe_sync s = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = ls.handle};
			struct drm_xe_exec x = {.exec_queue_id = lq.exec_queue_id, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s,
				.address = 0x1000000, .num_batch_buffer = 1};
			CHECK(xioctl(DRM_IOCTL_XE_EXEC, &x));
			struct drm_syncobj_wait lw = {.handles = (uint64_t)(uintptr_t)lh, .count_handles = 1, .timeout_nsec = (int64_t)absNs(5000000000ull)};
			CHECK(xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &lw));
		}
		uint64_t t1 = absNs(0);
		printf("load: %d batches of %u stores in %llu ms (%.1f us per batch)\n", rounds, stores, (t1 - t0) / 1000000,
			(double)(t1 - t0) / 1000.0 / rounds);
		return 0;
	}
	uint32_t batch = gem(0x10000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
	uint32_t target = gem(0x1000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
	uint32_t vbo = gem(0x10000, 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC);
	uint32_t *bb = map(batch, 0x10000), *tg = map(target, 0x1000), *vr = map(vbo, 0x10000);
	if (!bb || !tg || !vr) {
		fprintf(stderr, "map failed\n");
		return 1;
	}
	CHECK(bind(vc.vm_id, batch, 0x100000, 0x10000, 2));
	CHECK(bind(vc.vm_id, target, 0x200000, 0x1000, 2));
	CHECK(bind(vc.vm_id, vbo, 0x300000, 0x10000, 3));

	tg[0] = 0;
	vr[0] = 0;
	uint32_t n = 0;
	bb[n++] = 0x20 << 23 | 2;   // MI_STORE_DATA_IMM, 1 dword, PPGTT
	bb[n++] = 0x200000;
	bb[n++] = 0;
	bb[n++] = 0xa11ce001;
	bb[n++] = 0x20 << 23 | 2;
	bb[n++] = 0x300000;
	bb[n++] = 0;
	bb[n++] = 0xa11ce002;
	bb[n++] = 0xa << 23;         // MI_BATCH_BUFFER_END
	bb[n++] = 0;
	__sync_synchronize();

	struct drm_xe_engine_class_instance eci = {.engine_class = DRM_XE_ENGINE_CLASS_COPY};
	struct drm_xe_exec_queue_create qc = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id,
		.instances = (uint64_t)(uintptr_t)&eci};
	CHECK(xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &qc));
	struct drm_syncobj_create sc = {0}, tl = {0};
	CHECK(xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &sc));
	CHECK(xioctl(DRM_IOCTL_SYNCOBJ_CREATE, &tl));

	struct drm_xe_sync syncs[2] = {
		{.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle},
		{.type = DRM_XE_SYNC_TYPE_TIMELINE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = tl.handle, .timeline_value = 5},
	};
	struct drm_xe_exec ex = {.exec_queue_id = qc.exec_queue_id, .num_syncs = 2, .syncs = (uint64_t)(uintptr_t)syncs,
		.address = 0x100000, .num_batch_buffer = 1};
	uint64_t t0 = absNs(0);
	CHECK(xioctl(DRM_IOCTL_XE_EXEC, &ex));
	uint32_t handles[1] = {sc.handle};
	struct drm_syncobj_wait w = {.handles = (uint64_t)(uintptr_t)handles, .count_handles = 1,
		.timeout_nsec = (int64_t)absNs(2000000000ull)};
	int werr = xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w);
	uint64_t t1 = absNs(0);
	uint64_t point = 5;
	uint32_t th[1] = {tl.handle};
	struct drm_syncobj_timeline_wait tw = {.handles = (uint64_t)(uintptr_t)th, .points = (uint64_t)(uintptr_t)&point,
		.count_handles = 1, .timeout_nsec = (int64_t)absNs(2000000000ull)};
	int twerr = xioctl(DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT, &tw);
	uint64_t qv = 0;
	struct drm_syncobj_timeline_array qa = {.handles = (uint64_t)(uintptr_t)th, .points = (uint64_t)(uintptr_t)&qv, .count_handles = 1};
	CHECK(xioctl(DRM_IOCTL_SYNCOBJ_QUERY, &qa));
	printf("exec: binary wait %s in %llu us, timeline wait %s, timeline value %llu\n", werr ? "FAILED" : "ok",
		(t1 - t0) / 1000, twerr ? "FAILED" : "ok", qv);
	printf("system BO 0x%08x, VRAM BO 0x%08x -> %s\n", tg[0], vr[0],
		tg[0] == 0xa11ce001 && vr[0] == 0xa11ce002 ? "MESA-STYLE SUBMISSION WORKS" : "unexpected");

	// a second round on the same queue, timeline point 6
	tg[0] = 0;
	bb[3] = 0xa11ce003;
	__sync_synchronize();
	syncs[1].timeline_value = 6;
	ex.num_syncs = 2;
	CHECK(xioctl(DRM_IOCTL_XE_EXEC, &ex));
	point = 6;
	CHECK(xioctl(DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT, &tw));
	printf("second exec: system BO 0x%08x\n", tg[0]);

	struct drm_xe_exec_queue_destroy qd = {.exec_queue_id = qc.exec_queue_id};
	CHECK(xioctl(DRM_IOCTL_XE_EXEC_QUEUE_DESTROY, &qd));

	// every engine the kext reports: its own queue, a store of a per-engine tag, a binary syncobj wait
	for (uint32_t e = 0; e < eng->num_engines; e++) {
		struct drm_xe_engine_class_instance ei = eng->engines[e].instance;
		struct drm_xe_exec_queue_create c2 = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id,
			.instances = (uint64_t)(uintptr_t)&ei};
		if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &c2)) {
			printf("engine class %u inst %u: queue create failed (%d)\n", ei.engine_class, ei.engine_instance, errno);
			continue;
		}
		for (uint32_t round = 0; round < 3; round++) {   // three jobs on the same queue (later ones: SCHED_CONTEXT)
		uint32_t tag = 0xe0000000u | round << 16 | ei.engine_class << 8 | ei.engine_instance;
		tg[0] = 0;
		bb[3] = tag;
		__sync_synchronize();
		struct drm_xe_sync s1 = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle};
		struct drm_xe_exec x2 = {.exec_queue_id = c2.exec_queue_id, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s1,
			.address = 0x100000, .num_batch_buffer = 1};
		uint64_t a = absNs(0);
		int xerr = xioctl(DRM_IOCTL_XE_EXEC, &x2);
		w.timeout_nsec = (int64_t)absNs(2000000000ull);
		int werr2 = xerr ? -1 : xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w);
		printf("engine class %u inst %u job %u: exec %s, wait %s in %llu us, target 0x%08x %s\n", ei.engine_class,
			ei.engine_instance, round, xerr ? "FAILED" : "ok", werr2 ? "FAILED" : "ok", (absNs(0) - a) / 1000, tg[0],
			tg[0] == tag ? "OK" : "WRONG");
		}
		struct drm_xe_exec_queue_destroy d2 = {.exec_queue_id = c2.exec_queue_id};
		xioctl(DRM_IOCTL_XE_EXEC_QUEUE_DESTROY, &d2);
	}
	// Mesa's layout: batch in CPU-visible VRAM written through the WC mapping, target in system memory bound with
	// PAT 1 (Mesa's cached-coherent index), and the same target again with PAT 0.
	{
		uint32_t vb = gem(0x10000, 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC);
		uint32_t t1 = gem(0x1000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB), t0 = gem(0x1000, 1, 0, DRM_XE_GEM_CPU_CACHING_WB);
		uint32_t *vbb = map(vb, 0x10000), *m1 = map(t1, 0x1000), *m0 = map(t0, 0x1000);
		CHECK(bind(vc.vm_id, vb, 0x400000, 0x10000, 0));
		CHECK(bind(vc.vm_id, t1, 0x500000, 0x1000, 1));
		CHECK(bind(vc.vm_id, t0, 0x600000, 0x1000, 0));
		uint32_t k = 0;
		vbb[k++] = 0x20 << 23 | 2; vbb[k++] = 0x500000; vbb[k++] = 0; vbb[k++] = 0xb0000001;
		vbb[k++] = 0x20 << 23 | 2; vbb[k++] = 0x600000; vbb[k++] = 0; vbb[k++] = 0xb0000000;
		vbb[k++] = 0xa << 23; vbb[k++] = 0;
		__sync_synchronize();
		for (uint32_t e = 0; e < eng->num_engines; e += 1) {
			struct drm_xe_engine_class_instance ei = eng->engines[e].instance;
			struct drm_xe_exec_queue_create c3 = {.width = 1, .num_placements = 1, .vm_id = vc.vm_id,
				.instances = (uint64_t)(uintptr_t)&ei};
			if (xioctl(DRM_IOCTL_XE_EXEC_QUEUE_CREATE, &c3)) continue;
			m1[0] = m0[0] = 0;
			struct drm_xe_sync s3 = {.type = DRM_XE_SYNC_TYPE_SYNCOBJ, .flags = DRM_XE_SYNC_FLAG_SIGNAL, .handle = sc.handle};
			struct drm_xe_exec x3 = {.exec_queue_id = c3.exec_queue_id, .num_syncs = 1, .syncs = (uint64_t)(uintptr_t)&s3,
				.address = 0x400000, .num_batch_buffer = 1};
			int e3 = xioctl(DRM_IOCTL_XE_EXEC, &x3);
			w.timeout_nsec = (int64_t)absNs(2000000000ull);
			int w3 = e3 ? -1 : xioctl(DRM_IOCTL_SYNCOBJ_WAIT, &w);
			printf("VRAM batch on class %u inst %u: exec %s wait %s, PAT1 target 0x%08x, PAT0 target 0x%08x\n",
				ei.engine_class, ei.engine_instance, e3 ? "FAIL" : "ok", w3 ? "FAIL" : "ok", m1[0], m0[0]);
			struct drm_xe_exec_queue_destroy d3 = {.exec_queue_id = c3.exec_queue_id};
			xioctl(DRM_IOCTL_XE_EXEC_QUEUE_DESTROY, &d3);
		}
	}

	struct drm_xe_vm_destroy vd = {.vm_id = vc.vm_id};
	CHECK(xioctl(DRM_IOCTL_XE_VM_DESTROY, &vd));
	IOServiceClose(conn);
	printf("done\n");
	return 0;
}
