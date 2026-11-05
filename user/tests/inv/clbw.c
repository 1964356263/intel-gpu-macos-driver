// SPDX-License-Identifier: MIT
// clbw: OpenCL buffer bandwidth on the B580 plugin - a plain copy kernel and clEnqueueCopyBuffer over 64 MB buffers,
// timed with clFinish. Tells whether Apple's OpenCL buffers sit in VRAM or in system RAM behind PCIe.
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static const char *src =
	"__kernel void cp(__global const int4 *a, __global int4 *b) { size_t i = get_global_id(0); b[i] = a[i]; }\n";
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
int main(void) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
	  printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err);
	CK(clBuildProgram(p, 1, &dev, "", NULL, NULL));
	cl_kernel k = clCreateKernel(p, "cp", &err); CK(err);
	const size_t n = 64u << 20; void *h = malloc(n); memset(h, 1, n);
	// CLBW_FLAGS=use: CL_MEM_USE_HOST_PTR (page-aligned host memory), alloc: CL_MEM_ALLOC_HOST_PTR, else device buffers
	const char *fl = getenv("CLBW_FLAGS"); void *ha = NULL, *hb = NULL; posix_memalign(&ha, 16384, n); posix_memalign(&hb, 16384, n); memset(ha, 1, n);
	cl_mem_flags f = fl && !strcmp(fl, "use") ? CL_MEM_USE_HOST_PTR : fl && !strcmp(fl, "alloc") ? CL_MEM_ALLOC_HOST_PTR : 0;
	cl_mem a = clCreateBuffer(ctx, CL_MEM_READ_WRITE | (f ? f : CL_MEM_COPY_HOST_PTR), n, f == CL_MEM_ALLOC_HOST_PTR ? NULL : (f ? ha : h), &err); CK(err);
	cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE | f, n, f == CL_MEM_USE_HOST_PTR ? hb : NULL, &err); CK(err);
	CK(clSetKernelArg(k, 0, sizeof a, &a)); CK(clSetKernelArg(k, 1, sizeof b, &b));
	size_t g = n / 16, l = 256;
	for (int pass = 0; pass < 2; pass++) {
		CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q));
		double t0 = now_ms();
		for (int i = 0; i < 20; i++) CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
		CK(clFinish(q)); double t1 = now_ms();
		for (int i = 0; i < 20; i++) CK(clEnqueueCopyBuffer(q, a, b, 0, 0, n, 0, NULL, NULL));
		CK(clFinish(q)); double t2 = now_ms();
		CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, n, h, 0, NULL, NULL)); double t3 = now_ms();
		if (pass) printf("copy kernel %.1f GB/s (read+write), clEnqueueCopyBuffer %.1f GB/s, readback %.1f GB/s\n",
		                 2.0 * n * 20 / ((t1 - t0) / 1e3) / 1e9, 2.0 * n * 20 / ((t2 - t1) / 1e3) / 1e9, n / ((t3 - t2) / 1e3) / 1e9);
	}
	return 0;
}
