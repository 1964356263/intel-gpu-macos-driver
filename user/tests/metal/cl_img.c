// SPDX-License-Identifier: MIT
// cl_img: OpenCL image path on the B580 (Geekbench's CL workloads are image-heavy): a 3x3 box filter image -> image,
// the same filter on float4 buffers (4x the bytes; a uchar4 buffer kernel fails AIR->SPIR-V translation), and image upload/readback. Measurement only.
//   clang -arch x86_64 -mmacosx-version-min=15.0 -O2 -Wno-deprecated-declarations -o cl_img cl_img.c -framework OpenCL
#include <OpenCL/opencl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static mach_timebase_info_data_t tb;
static double now_us(void) { return (double)mach_absolute_time() * tb.numer / tb.denom / 1e3; }
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); exit(1); } } while (0)
static const char *src =
	"__constant sampler_t s = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_NEAREST;\n"
	"__kernel void boxi(__read_only image2d_t in, __write_only image2d_t out) { int2 p = (int2)(get_global_id(0), get_global_id(1));\n"
	"  float4 a = 0; for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) a += read_imagef(in, s, p + (int2)(x, y));\n"
	"  write_imagef(out, p, a / 9.0f); }\n"
	"__kernel void boxb(__global const float4 *in, __global float4 *out, int w, int h) { int x = get_global_id(0), y = get_global_id(1);\n"
	"  float4 a = 0; for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = clamp(x + dx, 0, w - 1), yy = clamp(y + dy, 0, h - 1);\n"
	"  a += in[yy * w + xx]; } out[y * w + x] = a / 9.0f; }\n";

static double prof(cl_event ev) {
	cl_ulong a = 0, b = 0; clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, 8, &a, NULL);
	clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, 8, &b, NULL); clReleaseEvent(ev); return (b - a) / 1e3;
}
int main(void) {
	mach_timebase_info(&tb);
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL));
	cl_int err;
	cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, CL_QUEUE_PROFILING_ENABLE, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err);
	if (clBuildProgram(p, 1, &dev, "", NULL, NULL)) { char log[8192] = ""; clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); printf("%s\n", log); return 1; }
	cl_kernel ki = clCreateKernel(p, "boxi", &err); CK(err);
	cl_kernel kb = clCreateKernel(p, "boxb", &err); CK(err);
	for (int W = 512; W <= 4096; W *= 2) {
		const int H = W; const size_t bytes = (size_t)W * H * 4;
		unsigned char *host = malloc(bytes); for (size_t i = 0; i < bytes; i++) host[i] = (unsigned char)(i * 2654435761u >> 24);
		cl_image_format f = {CL_RGBA, CL_UNORM_INT8};
		cl_image_desc d = {.image_type = CL_MEM_OBJECT_IMAGE2D, .image_width = W, .image_height = H};
		cl_mem ii = clCreateImage(ctx, CL_MEM_READ_ONLY, &f, &d, NULL, &err); CK(err);
		cl_mem io = clCreateImage(ctx, CL_MEM_WRITE_ONLY, &f, &d, NULL, &err); CK(err);
		cl_mem bi = clCreateBuffer(ctx, CL_MEM_READ_ONLY, bytes * 4, NULL, &err); CK(err);
		cl_mem bo = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, bytes * 4, NULL, &err); CK(err);
		size_t org[3] = {0, 0, 0}, reg[3] = {W, H, 1};
		double t = now_us(); CK(clEnqueueWriteImage(q, ii, CL_TRUE, org, reg, 0, 0, host, 0, NULL, NULL)); double wi = now_us() - t;
		t = now_us(); CK(clEnqueueWriteBuffer(q, bi, CL_TRUE, 0, bytes, host, 0, NULL, NULL)); double wb = now_us() - t;
		CK(clSetKernelArg(ki, 0, sizeof ii, &ii)); CK(clSetKernelArg(ki, 1, sizeof io, &io));
		CK(clSetKernelArg(kb, 0, sizeof bi, &bi)); CK(clSetKernelArg(kb, 1, sizeof bo, &bo));
		CK(clSetKernelArg(kb, 2, sizeof(int), &W)); CK(clSetKernelArg(kb, 3, sizeof(int), &H));
		size_t g[2] = {W, H}, l[2] = {16, 16};
		double gi = 1e18, gb = 1e18, wwi = 1e18, wwb = 1e18;
		for (int r = 0; r < 6; r++) {
			cl_event e; t = now_us(); CK(clEnqueueNDRangeKernel(q, ki, 2, NULL, g, l, 0, NULL, &e)); CK(clFinish(q)); double w = now_us() - t;
			double x = prof(e); if (r) { gi = fmin(gi, x); wwi = fmin(wwi, w); }
			t = now_us(); CK(clEnqueueNDRangeKernel(q, kb, 2, NULL, g, l, 0, NULL, &e)); CK(clFinish(q)); w = now_us() - t;
			x = prof(e); if (r) { gb = fmin(gb, x); wwb = fmin(wwb, w); }
		}
		t = now_us(); CK(clEnqueueReadImage(q, io, CL_TRUE, org, reg, 0, 0, host, 0, NULL, NULL)); double ri = now_us() - t;
		t = now_us(); CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, bytes, host, 0, NULL, NULL)); double rb = now_us() - t;
		printf("%4dx%-4d: box image %7.0f us GPU (%7.0f wall) | box buffer %7.0f us GPU (%7.0f wall) | write img %6.0f buf %6.0f us | read img %6.0f buf %6.0f us\n",
		       W, H, gi, wwi, gb, wwb, wi, wb, ri, rb);
		clReleaseMemObject(ii); clReleaseMemObject(io); clReleaseMemObject(bi); clReleaseMemObject(bo); free(host);
	}
	return 0;
}
