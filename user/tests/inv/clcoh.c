// SPDX-License-Identifier: MIT
// clcoh: OpenCL host/device coherence on the plugin, for every buffer kind (device, COPY_HOST_PTR, USE_HOST_PTR,
// ALLOC_HOST_PTR) and several sizes (64 B .. 8 MB):
//   1. host data in at creation -> kernel adds 1 -> clEnqueueReadBuffer sees it
//   2. clEnqueueWriteBuffer of a partial range (at a 256-byte offset: unaligned offsets are a known bug, see clpw) -> kernel
//   3. map for write, host writes a partial range, unmap -> kernel -> map for read sees it
//   4. USE_HOST_PTR: after clFinish + map, the host pointer itself holds the kernel's result
//   5. atomics on a small buffer from many work-items (a counter) -> exact total
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static const char *src =
"__kernel void inc(__global uint *a, uint n) { size_t i = get_global_id(0); if (i < n) a[i] += 1u; }\n"
"__kernel void count(__global uint *c) { atomic_inc(&c[get_global_id(0) & 7]); }\n";
static int fails;
static void check(const char *what, const char *kind, size_t n, const unsigned *got, unsigned (*want)(size_t)) {
	size_t bad = 0, first = (size_t)-1;
	for (size_t i = 0; i < n; i++) if (got[i] != want(i)) { if (first == (size_t)-1) first = i; bad++; }
	if (bad) { fails++; printf("FAIL %-6s %-22s %8zu words: %zu wrong (first at %zu: %u, want %u)\n", kind, what, n, bad, first, got[first], want(first)); }
}
static unsigned w1(size_t i) { return (unsigned)i * 3u + 1u; }
static unsigned w2(size_t i) { return (i >= 64 && i < 64 + 100) ? 1000u + (unsigned)i + 1u : (unsigned)i * 3u + 2u; }
static unsigned w3(size_t i) { return (i % 5 == 0) ? 77u + 1u : w2(i) + 1u; }
int main(void) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
	  printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err); CK(clBuildProgram(p, 1, &dev, "", NULL, NULL));
	cl_kernel kinc = clCreateKernel(p, "inc", &err); CK(err); cl_kernel kcnt = clCreateKernel(p, "count", &err); CK(err);
	static const size_t words[] = { 16, 1024, 16384, 262144, 2u << 20 };
	const char *kinds[4] = { "device", "copy", "use", "alloc" };
	for (int kd = 0; kd < 4; kd++) for (int si = 0; si < 5; si++) {
		const size_t n = words[si], bytes = n * 4;
		unsigned *init = malloc(bytes); for (size_t i = 0; i < n; i++) init[i] = (unsigned)i * 3u;
		void *host = NULL; posix_memalign(&host, 16384, (bytes + 16383) & ~(size_t)16383); memcpy(host, init, bytes);
		cl_mem_flags f = CL_MEM_READ_WRITE | (kd == 1 ? CL_MEM_COPY_HOST_PTR : kd == 2 ? CL_MEM_USE_HOST_PTR : kd == 3 ? CL_MEM_ALLOC_HOST_PTR : 0);
		cl_mem b = clCreateBuffer(ctx, f, bytes, kd == 1 ? init : kd == 2 ? host : NULL, &err); CK(err);
		if (kd == 0 || kd == 3) CK(clEnqueueWriteBuffer(q, b, CL_TRUE, 0, bytes, init, 0, NULL, NULL));
		cl_uint nn = (cl_uint)n; size_t g = (n + 63) / 64 * 64, l = 64;
		CK(clSetKernelArg(kinc, 0, sizeof b, &b)); CK(clSetKernelArg(kinc, 1, sizeof nn, &nn));
		unsigned *got = malloc(bytes);
		// 1
		CK(clEnqueueNDRangeKernel(q, kinc, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, bytes, got, 0, NULL, NULL));
		check("kernel -> read", kinds[kd], n, got, w1);
		// 2: partial write between enqueues
		const size_t pn = n > 164 ? 100 : 0; unsigned part[100]; for (int i = 0; i < 100; i++) part[i] = 1000u + 64u + (unsigned)i;
		if (pn) CK(clEnqueueWriteBuffer(q, b, getenv("CLCOH_BLOCK") ? CL_TRUE : CL_FALSE, 64 * 4, pn * 4, part, 0, NULL, NULL));
		CK(clEnqueueNDRangeKernel(q, kinc, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q));
		CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, bytes, got, 0, NULL, NULL));
		if (pn) check("partial write -> kernel", kinds[kd], n, got, w2);
		// 3: map, host writes every 5th word, unmap, kernel, map for read
		unsigned *m = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_READ | CL_MAP_WRITE, 0, bytes, 0, NULL, NULL, &err); CK(err);
		for (size_t i = 0; i < n; i += 5) m[i] = 77u;
		CK(clEnqueueUnmapMemObject(q, b, m, 0, NULL, NULL));
		CK(clEnqueueNDRangeKernel(q, kinc, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q));
		m = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_READ, 0, bytes, 0, NULL, NULL, &err); CK(err);
		if (pn) check("map write -> kernel -> map", kinds[kd], n, m, w3);
		CK(clEnqueueUnmapMemObject(q, b, m, 0, NULL, NULL)); CK(clFinish(q));
		// 4: USE_HOST_PTR: the host pointer holds the result once mapped
		if (kd == 2 && pn) { m = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_READ, 0, bytes, 0, NULL, NULL, &err); CK(err);
			check("use_host_ptr pointer", kinds[kd], n, (unsigned *)host, w3); CK(clEnqueueUnmapMemObject(q, b, m, 0, NULL, NULL)); CK(clFinish(q)); }
		clReleaseMemObject(b); free(init); free(got); free(host);
	}
	// 5: a small counter buffer of each kind under 1M atomic increments
	for (int kd = 0; kd < 4; kd++) {
		unsigned z[8] = { 0 }; void *host = NULL; posix_memalign(&host, 16384, 16384); memset(host, 0, 16384);
		cl_mem_flags f = CL_MEM_READ_WRITE | (kd == 1 ? CL_MEM_COPY_HOST_PTR : kd == 2 ? CL_MEM_USE_HOST_PTR : kd == 3 ? CL_MEM_ALLOC_HOST_PTR : 0);
		cl_mem c = clCreateBuffer(ctx, f, 32, kd == 1 ? z : kd == 2 ? host : NULL, &err); CK(err);
		if (kd == 0 || kd == 3) CK(clEnqueueWriteBuffer(q, c, CL_TRUE, 0, 32, z, 0, NULL, NULL));
		CK(clSetKernelArg(kcnt, 0, sizeof c, &c)); size_t g = 1u << 20, l = 256;
		CK(clEnqueueNDRangeKernel(q, kcnt, 1, NULL, &g, &l, 0, NULL, NULL));
		unsigned r[8]; CK(clEnqueueReadBuffer(q, c, CL_TRUE, 0, 32, r, 0, NULL, NULL));
		for (int i = 0; i < 8; i++) if (r[i] != (1u << 17)) { fails++; printf("FAIL %-6s counter[%d] = %u, want %u\n", kinds[kd], i, r[i], 1u << 17); break; }
		clReleaseMemObject(c); free(host);
	}
	printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
