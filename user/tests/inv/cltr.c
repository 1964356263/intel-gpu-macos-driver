// SPDX-License-Identifier: MIT
// cltr: OpenCL kernels that failed AIR->SPIR-V translation on the B580 plugin - a uchar4 buffer box filter and
// native_powr (Geekbench's HDR workloads) - run once each and checked against the CPU.
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static const char *src =
	"__kernel void boxu(__global const uchar4 *in, __global uchar4 *out, int w, int h) { int x = get_global_id(0), y = get_global_id(1);\n"
	"  float4 a = 0; for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = clamp(x + dx, 0, w - 1), yy = clamp(y + dy, 0, h - 1);\n"
	"  a += convert_float4(in[yy * w + xx]); } out[y * w + x] = convert_uchar4_sat_rte(a / 9.0f); }\n"
	"__kernel void amax(__global const float *in, __global int *m) { __local int lm; int i = get_global_id(0); if (get_local_id(0) == 0) lm = 0; barrier(CLK_LOCAL_MEM_FENCE);\n"
	"  atomic_max(&lm, as_int(in[i])); barrier(CLK_LOCAL_MEM_FENCE); if (get_local_id(0) == 0) atomic_max(m, lm); }\n"
	"__kernel void amaxf(__global const float *in, __global float *m) { int i = get_global_id(0); atomic_max((volatile __global int *)m, as_int(in[i])); }\n"
	"__kernel void amaxl(__global const float *in, __global float *m) { __local float lf[4]; int i = get_global_id(0), l = get_local_id(0); if (l < 4) lf[l] = 0; barrier(CLK_LOCAL_MEM_FENCE);\n"
	"  atomic_max((volatile __local int *)&lf[l & 3], as_int(in[i])); barrier(CLK_LOCAL_MEM_FENCE); if (l < 4) atomic_max((volatile __global int *)m, as_int(lf[l])); }\n"
	"__kernel void amaxarg(__global const float *in, __global int *m, __local int *lm) { int i = get_global_id(0), l = get_local_id(0);\n"
	"  if (l == 0) lm[0] = 0; barrier(CLK_LOCAL_MEM_FENCE); atomic_max(lm, (int)(in[i] * 1000.0f)); barrier(CLK_LOCAL_MEM_FENCE);\n"
	"  if (l == 0) atomic_max(m, convert_int(lm[0])); }\n"
	"__kernel void npow(__global const float4 *in, __global float4 *out) { int i = get_global_id(0); out[i] = native_powr(in[i], (float4)(2.2f)); }\n";
int main(void) {
	// NVMTL_BUNDLE: preload that plugin build so its classes are the ones Metal instantiates for OpenCL (a test hook)
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
	  printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err);
	if (clBuildProgram(p, 1, &dev, "", NULL, NULL)) { char log[8192] = ""; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); printf("build: %s\n", log); return 1; }
	int fails = 0;
	{ const int W = 256, H = 256; size_t n = (size_t)W * H * 4; unsigned char *in = malloc(n), *out = calloc(n, 1);
	  for (size_t i = 0; i < n; i++) in[i] = (unsigned char)(i * 2654435761u >> 24);
	  cl_kernel k = clCreateKernel(p, "boxu", &err);
	  if (err) { printf("uchar4 box: clCreateKernel -> %d (translation failed)\n", err); fails++; } else {
	  cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, n, in, &err); CK(err);
	  cl_mem bo = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, n, NULL, &err); CK(err);
	  CK(clSetKernelArg(k, 0, sizeof bi, &bi)); CK(clSetKernelArg(k, 1, sizeof bo, &bo)); CK(clSetKernelArg(k, 2, 4, &W)); CK(clSetKernelArg(k, 3, 4, &H));
	  size_t g[2] = {W, H}; err = clEnqueueNDRangeKernel(q, k, 2, NULL, g, NULL, 0, NULL, NULL);
	  if (err) { printf("uchar4 box: enqueue -> %d\n", err); fails++; }
	  else { CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, n, out, 0, NULL, NULL)); int bad = 0;
	    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (int c = 0; c < 4; c++) { float a = 0;
	      for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = x + dx < 0 ? 0 : x + dx >= W ? W - 1 : x + dx, yy = y + dy < 0 ? 0 : y + dy >= H ? H - 1 : y + dy; a += in[((size_t)yy * W + xx) * 4 + c]; }
	      int ref = (int)lrintf(a / 9.0f); if (abs(ref - out[((size_t)y * W + x) * 4 + c]) > 1) bad++; }
	    printf("uchar4 box: %d of %zu values wrong\n", bad, n); fails += bad != 0; } } }
	{ const int N = 4096; float *in = malloc(N * 16), *out = calloc(N, 16); for (int i = 0; i < 4 * N; i++) in[i] = (i % 1000) / 1000.0f;
	  cl_kernel k = clCreateKernel(p, "npow", &err);
	  if (err) { printf("native_powr: clCreateKernel -> %d (translation failed)\n", err); fails++; } else {
	  cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * 16, in, &err); CK(err);
	  cl_mem bo = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, N * 16, NULL, &err); CK(err);
	  CK(clSetKernelArg(k, 0, sizeof bi, &bi)); CK(clSetKernelArg(k, 1, sizeof bo, &bo));
	  size_t g = N; err = clEnqueueNDRangeKernel(q, k, 1, NULL, &g, NULL, 0, NULL, NULL);
	  if (err) { printf("native_powr: enqueue -> %d\n", err); fails++; }
	  else { CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, N * 16, out, 0, NULL, NULL)); int bad = 0;
	    for (int i = 0; i < 4 * N; i++) if (fabsf(out[i] - powf(in[i], 2.2f)) > 1e-3f + 1e-3f * powf(in[i], 2.2f)) bad++;
	    printf("native_powr: %d of %d values wrong\n", bad, 4 * N); fails += bad != 0; } } }
	{ const int N = 1 << 16; float *in = malloc(N * 4); float mx = 0; for (int i = 0; i < N; i++) { in[i] = (float)((i * 2654435761u) >> 8) / 65536.0f; if (in[i] > mx) mx = in[i]; }
	  cl_kernel k = clCreateKernel(p, "amax", &err);
	  if (err) { printf("atomic_max: clCreateKernel -> %d (translation failed)\n", err); fails++; } else {
	  int zero = 0; cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * 4, in, &err); CK(err);
	  cl_mem bm = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, 4, &zero, &err); CK(err);
	  CK(clSetKernelArg(k, 0, sizeof bi, &bi)); CK(clSetKernelArg(k, 1, sizeof bm, &bm));
	  size_t g = N, l = 256; CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
	  int got = 0; CK(clEnqueueReadBuffer(q, bm, CL_TRUE, 0, 4, &got, 0, NULL, NULL)); float gf; memcpy(&gf, &got, 4);
	  printf("atomic_max: %g (CPU %g) %s\n", gf, mx, gf == mx ? "ok" : "WRONG"); fails += gf != mx; } }
	{ const int N = 1 << 16; float *in = malloc(N * 4); float mx = 0; for (int i = 0; i < N; i++) { in[i] = (float)((i * 2654435761u) >> 8) / 65536.0f; if (in[i] > mx) mx = in[i]; }
	  for (int kk = 0; kk < 2; kk++) {
	  cl_kernel k = clCreateKernel(p, kk ? "amaxl" : "amaxf", &err);
	  if (err) { printf("atomic_max via a float buffer: clCreateKernel -> %d (translation failed)\n", err); fails++; } else {
	  float zero = 0; cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * 4, in, &err); CK(err);
	  cl_mem bm = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, 4, &zero, &err); CK(err);
	  CK(clSetKernelArg(k, 0, sizeof bi, &bi)); CK(clSetKernelArg(k, 1, sizeof bm, &bm));
	  size_t g = N; size_t lsz = 256; CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &lsz, 0, NULL, NULL));
	  float got = 0; CK(clEnqueueReadBuffer(q, bm, CL_TRUE, 0, 4, &got, 0, NULL, NULL));
	  printf("atomic_max via a %s float: %g (CPU %g) %s\n", kk ? "local" : "global", got, mx, got == mx ? "ok" : "WRONG"); fails += got != mx; } } }
	{ /* Geekbench 7 find_max_brightness's shape: a __local int * kernel argument and atomic_max on it, then on a global */
	  const int N = 1 << 16; float *in = malloc(N * 4); int mx = 0; for (int i = 0; i < N; i++) { in[i] = (float)((i * 2654435761u) >> 8) / 65536.0f; if ((int)(in[i] * 1000.0f) > mx) mx = (int)(in[i] * 1000.0f); }
	  cl_kernel k = clCreateKernel(p, "amaxarg", &err);
	  if (err) { printf("atomic_max on a __local argument: clCreateKernel -> %d (translation failed)\n", err); fails++; } else {
	  int zero = 0; cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * 4, in, &err); CK(err);
	  cl_mem bm = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, 4, &zero, &err); CK(err);
	  CK(clSetKernelArg(k, 0, sizeof bi, &bi)); CK(clSetKernelArg(k, 1, sizeof bm, &bm)); CK(clSetKernelArg(k, 2, 16, NULL));
	  size_t g = N, l = 256; CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
	  int got = 0; CK(clEnqueueReadBuffer(q, bm, CL_TRUE, 0, 4, &got, 0, NULL, NULL));
	  printf("atomic_max on a __local argument: %d (CPU %d) %s\n", got, mx, got == mx ? "ok" : "WRONG"); fails += got != mx; } }
	printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails != 0;
}
