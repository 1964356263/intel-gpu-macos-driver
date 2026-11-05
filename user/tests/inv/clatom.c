// SPDX-License-Identifier: MIT
// clatom: the atomic shapes of Geekbench's find_min_and_max and build_histograms on the plugin, timed per dispatch
// (best of 5, clFinish), with a reduction written without per-item global atomics as the achievable reference.
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
static const char *src =
"__kernel void minmax_global(__global const float *in, __global int *mm) { size_t i = get_global_id(0); int v = as_int(in[i]);\n"
"  atomic_min(&mm[0], v); atomic_max(&mm[1], v); }\n"
"__kernel void minmax_local(__global const float *in, __global int *mm) { __local int lmin, lmax; size_t i = get_global_id(0); int v = as_int(in[i]);\n"
"  if (get_local_id(0) == 0) { lmin = 0x7fffffff; lmax = 0; } barrier(CLK_LOCAL_MEM_FENCE);\n"
"  atomic_min(&lmin, v); atomic_max(&lmax, v); barrier(CLK_LOCAL_MEM_FENCE);\n"
"  if (get_local_id(0) == 0) { atomic_min(&mm[0], lmin); atomic_max(&mm[1], lmax); } }\n"
"__kernel void minmax_tree(__global const float *in, __global int *mm) { __local int a[256], b[256]; size_t l = get_local_id(0); int v = as_int(in[get_global_id(0)]);\n"
"  a[l] = v; b[l] = v; barrier(CLK_LOCAL_MEM_FENCE);\n"
"  for (int s = 128; s > 0; s >>= 1) { if (l < s) { a[l] = min(a[l], a[l + s]); b[l] = max(b[l], b[l + s]); } barrier(CLK_LOCAL_MEM_FENCE); }\n"
"  if (l == 0) { atomic_min(&mm[0], a[0]); atomic_max(&mm[1], b[0]); } }\n"
"__kernel void hist_local(__global const uchar *in, __global uint *h, uint n) { __local uint lh[256]; size_t l = get_local_id(0);\n"
"  lh[l] = 0; barrier(CLK_LOCAL_MEM_FENCE);\n"
"  for (size_t i = get_global_id(0); i < n; i += get_global_size(0)) atomic_inc(&lh[in[i]]);\n"
"  barrier(CLK_LOCAL_MEM_FENCE); atomic_add(&h[l], lh[l]); }\n"
"__kernel void hist_global(__global const uchar *in, __global uint *h) { atomic_inc(&h[in[get_global_id(0)]]); }\n";
int main(void) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
	  printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err);
	if (clBuildProgram(p, 1, &dev, "", NULL, NULL)) { char log[8192] = ""; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); printf("build: %s\n", log); return 1; }
	const size_t N = 16u << 20;
	float *f = malloc(N * 4); unsigned char *u = malloc(N);
	for (size_t i = 0; i < N; i++) { f[i] = (float)((i * 2654435761u) >> 8) / 16777216.0f + 0.001f; u[i] = (unsigned char)((i * 2654435761u) >> 24); }
	cl_mem bf = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * 4, f, &err); CK(err);
	cl_mem bu = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N, u, &err); CK(err);
	cl_mem bmm = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 8, NULL, &err); CK(err);
	cl_mem bh = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 1024, NULL, &err); CK(err);
	const char *names[5] = { "minmax_global", "minmax_local", "minmax_tree", "hist_local", "hist_global" };
	for (int kk = 0; kk < 5; kk++) {
		cl_kernel k = clCreateKernel(p, names[kk], &err); CK(err);
		size_t g = N, l = 256; cl_uint n = (cl_uint)N;
		if (kk < 3) { CK(clSetKernelArg(k, 0, sizeof bf, &bf)); CK(clSetKernelArg(k, 1, sizeof bmm, &bmm)); }
		else { CK(clSetKernelArg(k, 0, sizeof bu, &bu)); CK(clSetKernelArg(k, 1, sizeof bh, &bh)); if (kk == 3) { CK(clSetKernelArg(k, 2, sizeof n, &n)); g = 256 * 160; } }
		double best = 1e9; int mm[2] = { 0, 0 }; unsigned h[256];
		for (int r = 0; r < 5; r++) {
			int init[2] = { 0x7fffffff, 0 }; CK(clEnqueueWriteBuffer(q, bmm, CL_TRUE, 0, 8, init, 0, NULL, NULL));
			unsigned z[256] = { 0 }; CK(clEnqueueWriteBuffer(q, bh, CL_TRUE, 0, 1024, z, 0, NULL, NULL));
			const double t0 = now_ms(); CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q));
			const double t = now_ms() - t0; if (t < best) best = t;
			CK(clEnqueueReadBuffer(q, bmm, CL_TRUE, 0, 8, mm, 0, NULL, NULL)); CK(clEnqueueReadBuffer(q, bh, CL_TRUE, 0, 1024, h, 0, NULL, NULL));
		}
		unsigned long long hs = 0; for (int i = 0; i < 256; i++) hs += h[i];
		if (kk < 3) printf("%-14s %8.2f ms  min %g max %g\n", names[kk], best, *(float *)&mm[0], *(float *)&mm[1]);
		else printf("%-14s %8.2f ms  histogram total %llu of %zu\n", names[kk], best, hs, N);
		clReleaseKernel(k);
	}
	return 0;
}
