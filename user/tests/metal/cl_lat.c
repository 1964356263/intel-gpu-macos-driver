// SPDX-License-Identifier: MIT
// cl_lat: OpenCL.framework round trip and small-kernel throughput on the B580 (Apple's CL over our Metal plugin),
// the OpenCL twin of mtl_lat's lat/inflight/small. Measurement only.
//   clang -arch x86_64 -mmacosx-version-min=15.0 -O2 -Wno-deprecated-declarations -o cl_lat cl_lat.c -framework OpenCL
// Run on the hackintosh: NVMTL_ENABLE=1 ./cl_lat [n]
#include <OpenCL/opencl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static mach_timebase_info_data_t tb;
static double now_us(void) { return (double)mach_absolute_time() * tb.numer / tb.denom / 1e3; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void stats(const char *nm, double *v, int n) {
	qsort(v, n, 8, dcmp); double s = 0; for (int i = 0; i < n; i++) s += v[i];
	printf("  %-40s n %5d  p50 %8.1f  p90 %8.1f  p99 %8.1f  mean %8.1f us\n", nm, n, v[n / 2], v[n * 9 / 10], v[n * 99 / 100], s / n);
}
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); exit(1); } } while (0)

static const char *src =
	"__kernel void nop(__global uint *o) { if (get_global_id(0) == 0xffffffffu) o[0] = 1; }\n"
	"__kernel void saxpy(__global const float4 *x, __global float4 *y) { size_t i = get_global_id(0); y[i] = fma(x[i], (float4)(1.0001f), y[i]); }\n"
	"__kernel void sum(__global const float4 *x, __global float *o) { size_t i = get_global_id(0), n = get_global_size(0);\n"
	"  float4 a = 0; for (size_t k = i; k < n * 16; k += n) a += x[k]; o[i] = a.x + a.y + a.z + a.w; }\n";

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	int N = argc > 1 ? atoi(argv[1]) : 1000;
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id devs[8]; cl_uint nd = 0; CK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 8, devs, &nd));
	cl_device_id dev = NULL;
	for (cl_uint i = 0; i < nd; i++) {
		char name[256] = ""; clGetDeviceInfo(devs[i], CL_DEVICE_NAME, sizeof name, name, NULL);
		printf("GPU %u: %s\n", i, name);
		if (strstr(name, "IntelXe") || strstr(name, "NVMTL") || strstr(name, "Arc")) dev = devs[i];
	}
	if (!dev) { printf("no B580 CL device\n"); return 2; }
	cl_int err;
	cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, CL_QUEUE_PROFILING_ENABLE, &err); CK(err);
	double t0 = now_us();
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err);
	err = clBuildProgram(p, 1, &dev, "", NULL, NULL);
	if (err) { char log[8192] = ""; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); printf("build %d: %s\n", err, log); return 1; }
	printf("program built in %.0f ms\n", (now_us() - t0) / 1e3);
	cl_kernel kn = clCreateKernel(p, "nop", &err); CK(err);
	cl_kernel ks = clCreateKernel(p, "saxpy", &err); CK(err);
	cl_kernel ksum = clCreateKernel(p, "sum", &err); CK(err);
	cl_mem o = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 4096, NULL, &err); CK(err);
	CK(clSetKernelArg(kn, 0, sizeof o, &o));
	size_t g = 32, l = 32;
	for (int i = 0; i < 50; i++) { CK(clEnqueueNDRangeKernel(q, kn, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q)); }

	double *tot = calloc(N, 8), *enq = calloc(N, 8), *gpu = calloc(N, 8), *qs = calloc(N, 8), *se = calloc(N, 8), *ef = calloc(N, 8);
	for (int i = 0; i < N; i++) {
		cl_event ev;
		double a = now_us();
		CK(clEnqueueNDRangeKernel(q, kn, 1, NULL, &g, &l, 0, NULL, &ev));
		double b = now_us();
		CK(clFinish(q));
		double c = now_us();
		cl_ulong tq = 0, ts = 0, tst = 0, te = 0;
		clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_QUEUED, 8, &tq, NULL);
		clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_SUBMIT, 8, &ts, NULL);
		clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, 8, &tst, NULL);
		clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, 8, &te, NULL);
		clReleaseEvent(ev);
		tot[i] = c - a; enq[i] = b - a; gpu[i] = (te - tst) / 1e3; qs[i] = (tst - tq) / 1e3; se[i] = (double)(ts - tq) / 1e3;
	}
	printf("[cl lat] 1 tiny kernel: clEnqueueNDRangeKernel + clFinish\n");
	stats("total", tot, N); stats("  clEnqueueNDRangeKernel call", enq, N);
	stats("  profiling QUEUED->SUBMIT", se, N); stats("  profiling QUEUED->START", qs, N); stats("  profiling START->END", gpu, N);

	printf("[cl inflight] M kernels enqueued, one clFinish\n");
	int ms[] = {1, 4, 16, 64, 256};
	for (int mi = 0; mi < 5; mi++) {
		int M = ms[mi], it = N / M < 10 ? 10 : N / M; double *per = calloc(it, 8);
		for (int i = 0; i < it; i++) {
			double a = now_us();
			for (int m = 0; m < M; m++) CK(clEnqueueNDRangeKernel(q, kn, 1, NULL, &g, &l, 0, NULL, NULL));
			CK(clFinish(q));
			per[i] = (now_us() - a) / M;
		}
		char nm[64]; snprintf(nm, sizeof nm, "M=%d per kernel", M); stats(nm, per, it); free(per);
	}

	printf("[cl small] saxpy, device buffers: sync (enqueue+finish) and pipelined (finish every 100)\n");
	size_t sizes[] = {64 << 10, 256 << 10, 1 << 20, 4 << 20};
	for (int si = 0; si < 4; si++) {
		size_t S = sizes[si], n = S / 16, lw = 256;
		cl_mem x = clCreateBuffer(ctx, CL_MEM_READ_WRITE, S, NULL, &err); CK(err);
		cl_mem y = clCreateBuffer(ctx, CL_MEM_READ_WRITE, S, NULL, &err); CK(err);
		CK(clSetKernelArg(ks, 0, sizeof x, &x)); CK(clSetKernelArg(ks, 1, sizeof y, &y));
		for (int i = 0; i < 10; i++) CK(clEnqueueNDRangeKernel(q, ks, 1, NULL, &n, &lw, 0, NULL, NULL));
		CK(clFinish(q));
		int K = 1000; double a = now_us();
		for (int i = 0; i < K; i++) { CK(clEnqueueNDRangeKernel(q, ks, 1, NULL, &n, &lw, 0, NULL, NULL)); CK(clFinish(q)); }
		double s1 = (now_us() - a) / K;
		K = 4000; a = now_us();
		for (int i = 0; i < K; i++) { CK(clEnqueueNDRangeKernel(q, ks, 1, NULL, &n, &lw, 0, NULL, NULL)); if (i % 100 == 99) CK(clFinish(q)); }
		CK(clFinish(q));
		double s2 = (now_us() - a) / K;
		printf("  S %5zu KB: sync %7.1f us/kernel (%6.0f /s) | pipelined %6.1f us/kernel (%7.0f /s)\n", S >> 10, s1, 1e6 / s1, s2, 1e6 / s2);
		clReleaseMemObject(x); clReleaseMemObject(y);
	}

	printf("[cl buffers] 64 MB sum kernel by allocation flag (profiling time, best of 5)\n");
	const size_t S = 64 << 20; size_t nsum = S / 16 / 16, lw = 256;
	cl_mem out = clCreateBuffer(ctx, CL_MEM_READ_WRITE, nsum * 4, NULL, &err); CK(err);
	struct { cl_mem_flags f; const char *nm; } fl[] = {{CL_MEM_READ_WRITE, "READ_WRITE"}, {CL_MEM_READ_ONLY, "READ_ONLY"},
		{CL_MEM_ALLOC_HOST_PTR | CL_MEM_READ_WRITE, "ALLOC_HOST_PTR"}, {CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE, "USE_HOST_PTR"},
		{CL_MEM_COPY_HOST_PTR | CL_MEM_READ_WRITE, "COPY_HOST_PTR"}};
	void *host = NULL; posix_memalign(&host, 1 << 16, S); memset(host, 1, S);
	for (int fi = 0; fi < 5; fi++) {
		cl_mem b = clCreateBuffer(ctx, fl[fi].f, S, (fl[fi].f & (CL_MEM_USE_HOST_PTR | CL_MEM_COPY_HOST_PTR)) ? host : NULL, &err);
		if (err) { printf("  %-16s: create %d\n", fl[fi].nm, err); continue; }
		CK(clSetKernelArg(ksum, 0, sizeof b, &b)); CK(clSetKernelArg(ksum, 1, sizeof out, &out));
		double best = 1e18, bw = 1e18;
		for (int r = 0; r < 6; r++) {
			cl_event ev; double a = now_us();
			CK(clEnqueueNDRangeKernel(q, ksum, 1, NULL, &nsum, &lw, 0, NULL, &ev)); CK(clFinish(q));
			double w = now_us() - a;
			cl_ulong s0 = 0, s1 = 0; clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, 8, &s0, NULL);
			clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, 8, &s1, NULL); clReleaseEvent(ev);
			if (r) { if (s1 > s0) best = best < (s1 - s0) / 1e3 ? best : (s1 - s0) / 1e3; bw = bw < w ? bw : w; }
		}
		printf("  %-16s: %6.1f GB/s profiled (%7.0f us), %6.1f GB/s wall\n", fl[fi].nm, best < 1e17 ? S / (best * 1e3) : 0, best, S / (bw * 1e3));
		clReleaseMemObject(b);
	}
	// host <-> device transfer
	cl_mem d = clCreateBuffer(ctx, CL_MEM_READ_WRITE, S, NULL, &err); CK(err);
	double a = now_us(); CK(clEnqueueWriteBuffer(q, d, CL_TRUE, 0, S, host, 0, NULL, NULL)); double w1 = now_us() - a;
	a = now_us(); CK(clEnqueueWriteBuffer(q, d, CL_TRUE, 0, S, host, 0, NULL, NULL)); w1 = fmin(w1, now_us() - a);
	a = now_us(); CK(clEnqueueReadBuffer(q, d, CL_TRUE, 0, S, host, 0, NULL, NULL)); double r1 = now_us() - a;
	a = now_us(); CK(clEnqueueReadBuffer(q, d, CL_TRUE, 0, S, host, 0, NULL, NULL)); r1 = fmin(r1, now_us() - a);
	printf("  clEnqueueWriteBuffer 64 MB: %.1f GB/s, clEnqueueReadBuffer 64 MB: %.1f GB/s\n", S / (w1 * 1e3), S / (r1 * 1e3));
	double *sm = calloc(N, 8);
	for (int i = 0; i < N; i++) { a = now_us(); CK(clEnqueueReadBuffer(q, d, CL_TRUE, 0, 64, host, 0, NULL, NULL)); sm[i] = now_us() - a; }
	stats("blocking clEnqueueReadBuffer 64 B", sm, N);
	return 0;
}
