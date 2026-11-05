// SPDX-License-Identifier: MIT
// mtl_lat: latency / small-kernel throughput / buffer-mode bandwidth profile of the B580 Metal stack (NVMTLDevice over
// our ANV). Measurement only. Build on the build Mac:
//   clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O2 -o mtl_lat mtl_lat.m -framework Foundation -framework Metal
// Run on the hackintosh: NVMTL_ENABLE=1 ./mtl_lat [igpu] test [args]
//   lat [n]            empty dispatch per command buffer, commit + waitUntilCompleted, n iterations (default 1000)
//   latk [n]           K tiny dispatches in one command buffer (K = 1, 4, 16, 64, 256)
//   inflight [n]       M command buffers committed back-to-back, then one wait (M = 1, 2, 4, 8, 16, 32)
//   handler [n]        completion via addCompletedHandler + semaphore instead of waitUntilCompleted
//   small              Geekbench-like: 64 KB-1 MB kernels, sync / pipelined / batched
//   buf                shared vs private vs managed bandwidth (copy and sum kernels), CPU writes before dispatch
//   alu                ALU (FMA) throughput and device-memory bandwidth against the B580 peaks, GPU-timestamped
//   loop <sec> <mode>  keep a workload running for <sec> seconds (mode lat|small|alu) - for clock sampling / sample(1)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <stdlib.h>

static NSString *const kSource = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void nop(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i == 0xffffffffu) o[0] = 1; }
kernel void saxpy(device const float4 *x [[buffer(0)]], device float4 *y [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    y[i] = fma(x[i], float4(1.0001f), y[i]);
}
kernel void copyk(device const float4 *in [[buffer(0)]], device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = in[i];
}
kernel void sumk(device const float4 *in [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]],
                 uint n [[threads_per_grid]]) {
    float4 a = 0; for (uint k = i; k < n * 16; k += n) a += in[k];
    out[i] = a.x + a.y + a.z + a.w;
}
kernel void flops(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float a = float(i & 1023) * 1e-3f, b = 1.0001f, c = 0.9999f;
    for (int k = 0; k < 1024; k++) { a = fma(a, b, c); a = fma(a, c, -b); }
    out[i] = a;
}
kernel void flops4(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float4 a = float4(i & 1023, i & 511, i & 255, i & 127) * 1e-3f, d = a + 0.5f, b = 1.0001f, c = 0.9999f;
    for (int k = 0; k < 512; k++) { a = fma(a, b, c); d = fma(d, c, b); a = fma(a, c, -b); d = fma(d, b, -c); }
    out[i] = a + d;
}
)";

static double tbase;
static double now_us(void) {
	static mach_timebase_info_data_t tb;
	if (!tb.denom) mach_timebase_info(&tb);
	return (double)mach_absolute_time() * tb.numer / tb.denom / 1000.0;
}
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void stats(const char *name, double *v, int n) {
	qsort(v, n, sizeof *v, dcmp);
	double s = 0; for (int i = 0; i < n; i++) s += v[i];
	printf("  %-34s n %5d  min %8.1f  p50 %8.1f  p90 %8.1f  p99 %8.1f  max %8.1f  mean %8.1f us\n", name, n, v[0], v[n / 2],
	       v[(int)(n * 0.9)], v[(int)(n * 0.99)], v[n - 1], s / n);
}

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static id<MTLComputePipelineState> pipe_(NSString *n) {
	NSError *e = nil;
	id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:n] error:&e];
	if (!p) { printf("pipeline %s: %s\n", n.UTF8String, e.localizedDescription.UTF8String); exit(1); }
	return p;
}
static void disp(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> p, NSUInteger n, NSUInteger tg) {
	[enc setComputePipelineState:p];
	[enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
}

static void testLat(int n) {
	id<MTLComputePipelineState> p = pipe_(@"nop");
	id<MTLBuffer> o = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	double *tot = calloc(n, 8), *enc_ = calloc(n, 8), *com = calloc(n, 8), *wt = calloc(n, 8), *gpu = calloc(n, 8), *sch = calloc(n, 8);
	double *launch = calloc(n, 8), *tail = calloc(n, 8);
	double *pc = calloc(n, 8), *pe = calloc(n, 8), *pd = calloc(n, 8), *pn = calloc(n, 8);
	int ng = 0;
	for (int w = 0; w < 50; w++) {   // warm-up
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
		[e setBuffer:o offset:0 atIndex:0]; disp(e, p, 32, 32); [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
	}
	for (int i = 0; i < n; i++) @autoreleasepool {
		__block double ts = 0;
		double t0 = now_us();
		id<MTLCommandBuffer> cb = [q commandBuffer];
		double ta = now_us();
		[cb addScheduledHandler:^(id<MTLCommandBuffer> b) { ts = now_us(); }];
		id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
		double tb = now_us();
		[e setBuffer:o offset:0 atIndex:0]; disp(e, p, 32, 32);
		double tc = now_us();
		[e endEncoding];
		double t1 = now_us();
		pc[i] = ta - t0; pe[i] = tb - ta; pd[i] = tc - tb; pn[i] = t1 - tc;
		[cb commit];
		double t2 = now_us();
		[cb waitUntilCompleted];
		double t3 = now_us();
		tot[i] = t3 - t0; enc_[i] = t1 - t0; com[i] = t2 - t1; wt[i] = t3 - t2; sch[i] = ts ? ts - t1 : 0;
		if (cb.GPUEndTime > cb.GPUStartTime) { launch[ng] = cb.GPUStartTime * 1e6 - t2; tail[ng] = t3 - cb.GPUEndTime * 1e6;
			gpu[ng++] = (cb.GPUEndTime - cb.GPUStartTime) * 1e6; }
	}
	printf("[lat] 1 empty dispatch (32 threads) per command buffer, commit + waitUntilCompleted\n");
	stats("total round trip", tot, n); stats("  create+encode", enc_, n);
	stats("    commandBuffer", pc, n); stats("    computeCommandEncoder", pe, n); stats("    set+dispatch", pd, n); stats("    endEncoding", pn, n); stats("  commit call", com, n);
	stats("  waitUntilCompleted", wt, n); stats("  commit -> scheduled handler", sch, n);
	if (ng) { stats("  GPU time (GPUEnd-GPUStart)", gpu, ng); stats("  commit return -> GPUStart", launch, ng);
		stats("  GPUEnd -> waitUntilCompleted ret", tail, ng); }
}

static void testHandler(int n) {
	id<MTLComputePipelineState> p = pipe_(@"nop");
	id<MTLBuffer> o = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	double *tot = calloc(n, 8), *cbk = calloc(n, 8);
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	for (int i = 0; i < n + 20; i++) @autoreleasepool {
		__block double tc = 0;
		double t0 = now_us();
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) { tc = now_us(); dispatch_semaphore_signal(sem); }];
		id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
		[e setBuffer:o offset:0 atIndex:0]; disp(e, p, 32, 32); [e endEncoding];
		[cb commit];
		dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
		double t3 = now_us();
		if (i >= 20) { tot[i - 20] = t3 - t0; cbk[i - 20] = t3 - tc; }
	}
	printf("[handler] completion handler + semaphore\n");
	stats("total round trip", tot, n); stats("  handler -> waiter wakes", cbk, n);
}

static void testLatK(int n) {
	id<MTLComputePipelineState> p = pipe_(@"nop");
	id<MTLBuffer> o = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	printf("[latk] K empty dispatches in one command buffer (one encoder), commit + wait\n");
	int ks[] = {1, 4, 16, 64, 256, 1024};
	for (int ki = 0; ki < 6; ki++) {
		int K = ks[ki], it = K >= 256 ? n / 10 : n / 2; if (it < 20) it = 20;
		double *tot = calloc(it, 8), *gpu = calloc(it, 8), *encd = calloc(it, 8); int ng = 0;
		for (int i = 0; i < it; i++) @autoreleasepool {
			double t0 = now_us();
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:o offset:0 atIndex:0]; [e setComputePipelineState:p];
			for (int k = 0; k < K; k++) [e dispatchThreads:MTLSizeMake(32, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
			[e endEncoding];
			double t1 = now_us();
			[cb commit]; [cb waitUntilCompleted];
			tot[i] = now_us() - t0; encd[i] = t1 - t0;
			if (cb.GPUEndTime > cb.GPUStartTime) gpu[ng++] = (cb.GPUEndTime - cb.GPUStartTime) * 1e6;
		}
		char nm[64];
		snprintf(nm, sizeof nm, "K=%d total", K); stats(nm, tot, it);
		snprintf(nm, sizeof nm, "K=%d encode", K); stats(nm, encd, it);
		if (ng) { snprintf(nm, sizeof nm, "K=%d GPU", K); stats(nm, gpu, ng); }
		qsort(tot, it, 8, dcmp);
		printf("    -> %.2f us per dispatch (p50)\n", tot[it / 2] / K);
	}
}

static void testInflight(int n) {
	id<MTLComputePipelineState> p = pipe_(@"nop");
	id<MTLBuffer> o = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
	printf("[inflight] M command buffers (1 empty dispatch each) committed back to back, then wait for the last\n");
	int ms[] = {1, 2, 4, 8, 16, 32, 63};
	for (int mi = 0; mi < 7; mi++) {
		int M = ms[mi], it = n / M; if (it < 10) it = 10;
		double *per = calloc(it, 8);
		for (int i = 0; i < it; i++) @autoreleasepool {
			double t0 = now_us();
			id<MTLCommandBuffer> last = nil;
			for (int m = 0; m < M; m++) {
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
				[e setBuffer:o offset:0 atIndex:0]; disp(e, p, 32, 32); [e endEncoding];
				[cb commit]; last = cb;
			}
			[last waitUntilCompleted];
			per[i] = (now_us() - t0) / M;
		}
		char nm[64]; snprintf(nm, sizeof nm, "M=%d per command buffer", M); stats(nm, per, it);
	}
}

// Geekbench-like many small kernels: saxpy over S bytes (two private buffers)
static void testSmall(void) {
	id<MTLComputePipelineState> p = pipe_(@"saxpy");
	printf("[small] saxpy kernels (read 2x + write 1x S bytes), private buffers\n");
	size_t sizes[] = {64 << 10, 256 << 10, 1 << 20, 4 << 20, 64 << 10, 256 << 10};
	for (int si = 0; si < 6; si++) {
		size_t S = sizes[si]; NSUInteger nthr = S / 16;
		id<MTLBuffer> x = [dev newBufferWithLength:S options:MTLResourceStorageModePrivate];
		id<MTLBuffer> y = [dev newBufferWithLength:S options:MTLResourceStorageModePrivate];
		// a) 1 kernel per command buffer, wait each
		int N = 2000;
		double t0 = now_us();
		for (int i = 0; i < N; i++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:x offset:0 atIndex:0]; [e setBuffer:y offset:0 atIndex:1]; disp(e, p, nthr, 256); [e endEncoding];
			[cb commit]; [cb waitUntilCompleted];
		}
		double a = (now_us() - t0) / N;
		// b) 1 kernel per command buffer, pipelined (wait only on the last)
		N = 4000; t0 = now_us(); id<MTLCommandBuffer> last = nil;
		for (int i = 0; i < N; i++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:x offset:0 atIndex:0]; [e setBuffer:y offset:0 atIndex:1]; disp(e, p, nthr, 256); [e endEncoding];
			[cb commit]; last = cb;
		}
		[last waitUntilCompleted];
		double b = (now_us() - t0) / N;
		// c) 100 kernels per command buffer (one encoder), wait each
		N = 10000; t0 = now_us(); double gsum = 0; int gn = 0;
		for (int i = 0; i < N / 100; i++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:x offset:0 atIndex:0]; [e setBuffer:y offset:0 atIndex:1]; [e setComputePipelineState:p];
			for (int k = 0; k < 100; k++) [e dispatchThreads:MTLSizeMake(nthr, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
			[e endEncoding]; [cb commit]; [cb waitUntilCompleted];
			if (cb.GPUEndTime > cb.GPUStartTime) { gsum += (cb.GPUEndTime - cb.GPUStartTime) * 1e6; gn++; }
		}
		double c = (now_us() - t0) / N;
		double g = gn ? gsum / gn / 100 : 0;
		printf("  S %5zu KB: sync 1/cb %7.1f us/kernel (%6.0f k/s) | pipelined 1/cb %7.1f us (%6.0f k/s) | 100/cb %6.2f us (%7.0f k/s), GPU %6.2f us/kernel = %.0f GB/s\n",
		       S >> 10, a, 1e6 / a, b, 1e6 / b, c, 1e6 / c, g, g > 0 ? 3.0 * S / (g * 1e3) : 0);
	}
}

static const char *modeName(MTLResourceOptions o) {
	switch ((o >> MTLResourceStorageModeShift) & 0xF) { case MTLStorageModeShared: return "shared"; case MTLStorageModeManaged: return "managed"; default: return "private"; }
}
static double gpuOrWall(id<MTLCommandBuffer> cb, double wall) { return cb.GPUEndTime > cb.GPUStartTime ? (cb.GPUEndTime - cb.GPUStartTime) * 1e6 : wall; }

static void testBuf(void) {
	id<MTLComputePipelineState> pc = pipe_(@"copyk"), ps = pipe_(@"sumk");
	printf("[buf] 64 MB copy (read 64 + write 64) and sum (read 64) by storage mode; best of 5, GPU time where available\n");
	const size_t S = 64 << 20;
	MTLResourceOptions modes[] = {MTLResourceStorageModePrivate, MTLResourceStorageModeShared, MTLResourceStorageModeManaged};
	for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) {
		if (a != b && !(a == 1 && b == 0) && !(a == 0 && b == 1)) continue;
		id<MTLBuffer> src = [dev newBufferWithLength:S options:modes[a]], dst = [dev newBufferWithLength:S options:modes[b]];
		double best = 1e18, bestw = 1e18;
		for (int r = 0; r < 6; r++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:src offset:0 atIndex:0]; [e setBuffer:dst offset:0 atIndex:1]; disp(e, pc, S / 16, 256); [e endEncoding];
			double t0 = now_us(); [cb commit]; [cb waitUntilCompleted]; double w = now_us() - t0;
			if (r) { best = fmin(best, gpuOrWall(cb, w)); bestw = fmin(bestw, w); }
		}
		printf("  copy %-7s -> %-7s : %6.1f GB/s GPU (%7.0f us), %6.1f GB/s wall (%7.0f us)\n", modeName(modes[a]), modeName(modes[b]),
		       2.0 * S / (best * 1e3), best, 2.0 * S / (bestw * 1e3), bestw);
	}
	for (int a = 0; a < 3; a++) {
		id<MTLBuffer> src = [dev newBufferWithLength:S options:modes[a]], out = [dev newBufferWithLength:(S / 16 / 16) * 4 options:MTLResourceStorageModePrivate];
		double best = 1e18, bestw = 1e18;
		for (int r = 0; r < 6; r++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:src offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1]; disp(e, ps, S / 16 / 16, 256); [e endEncoding];
			double t0 = now_us(); [cb commit]; [cb waitUntilCompleted]; double w = now_us() - t0;
			if (r) { best = fmin(best, gpuOrWall(cb, w)); bestw = fmin(bestw, w); }
		}
		printf("  sum  %-7s           : %6.1f GB/s GPU (%7.0f us), %6.1f GB/s wall (%7.0f us)\n", modeName(modes[a]),
		       1.0 * S / (best * 1e3), best, 1.0 * S / (bestw * 1e3), bestw);
	}
	// CPU writes to a shared/managed buffer, then a small dispatch reading it: CPU write time + round trip
	printf("  CPU memset of the buffer, then a nop dispatch that references it (does the commit copy anything?)\n");
	id<MTLComputePipelineState> pn = pipe_(@"nop");
	size_t ws[] = {64 << 10, 1 << 20, 16 << 20, 64 << 20};
	for (int a = 1; a < 3; a++) for (int wi = 0; wi < 4; wi++) {
		id<MTLBuffer> b = [dev newBufferWithLength:ws[wi] options:modes[a]];
		double wmin = 1e18, rmin = 1e18, rnw = 1e18;
		for (int r = 0; r < 8; r++) @autoreleasepool {
			double t0 = now_us();
			memset(b.contents, r, ws[wi]);
			if (a == 2) [b didModifyRange:NSMakeRange(0, ws[wi])];
			double t1 = now_us();
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:b offset:0 atIndex:0]; disp(e, pn, 32, 32); [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
			double t2 = now_us();
			// same, no CPU write
			cb = [q commandBuffer]; e = [cb computeCommandEncoder];
			[e setBuffer:b offset:0 atIndex:0]; disp(e, pn, 32, 32); [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
			double t3 = now_us();
			if (r) { wmin = fmin(wmin, t1 - t0); rmin = fmin(rmin, t2 - t1); rnw = fmin(rnw, t3 - t2); }
		}
		printf("    %-7s %6zu KB: memset %8.0f us (%5.1f GB/s), round trip after write %8.0f us, without write %6.0f us\n",
		       modeName(modes[a]), ws[wi] >> 10, wmin, ws[wi] / (wmin * 1e3), rmin, rnw);
	}
}

static void testAlu(void) {
	id<MTLComputePipelineState> p1 = pipe_(@"flops"), p4 = pipe_(@"flops4"), pc = pipe_(@"copyk");
	printf("[alu] FMA throughput and memory bandwidth (GPU timestamps; best of 5)\n");
	printf("  pipeline flops: maxTotalThreadsPerThreadgroup %lu, threadExecutionWidth %lu\n",
	       (unsigned long)p1.maxTotalThreadsPerThreadgroup, (unsigned long)p1.threadExecutionWidth);
	NSUInteger n = 1 << 22;
	id<MTLBuffer> out = [dev newBufferWithLength:n * 16 options:MTLResourceStorageModePrivate];
	struct { id<MTLComputePipelineState> p; double flop_per_thread; const char *nm; NSUInteger tg; } k[] = {
		{p1, 2.0 * 2048, "scalar fma chain, tg 256", 256}, {p1, 2.0 * 2048, "scalar fma chain, tg 64", 64},
		{p4, 2.0 * 4 * 4 * 512, "float4 2 chains, tg 256", 256}, {p4, 2.0 * 4 * 4 * 512, "float4 2 chains, tg 1024", 1024}};
	for (int i = 0; i < 4; i++) {
		if (k[i].tg > k[i].p.maxTotalThreadsPerThreadgroup) continue;
		double best = 1e18;
		for (int r = 0; r < 6; r++) @autoreleasepool {
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setBuffer:out offset:0 atIndex:0]; disp(e, k[i].p, n, k[i].tg); [e endEncoding];
			double t0 = now_us(); [cb commit]; [cb waitUntilCompleted]; double w = now_us() - t0;
			if (r) best = fmin(best, gpuOrWall(cb, w));
		}
		printf("  %-28s: %7.0f GFLOPS (%.0f us)\n", k[i].nm, k[i].flop_per_thread * n / (best * 1e3), best);
	}
	size_t S = 256 << 20;
	id<MTLBuffer> a = [dev newBufferWithLength:S options:MTLResourceStorageModePrivate], c = [dev newBufferWithLength:S options:MTLResourceStorageModePrivate];
	{   // random-ish data so compression does not help
		id<MTLBuffer> s = [dev newBufferWithLength:S options:MTLResourceStorageModeShared];
		uint64_t *w = s.contents, x = 0x9E3779B97F4A7C15ull;
		for (size_t i = 0; i < S / 8; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = x; }
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		[b copyFromBuffer:s sourceOffset:0 toBuffer:a destinationOffset:0 size:S]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
	}
	double best = 1e18, bestw = 1e18;
	for (int r = 0; r < 6; r++) @autoreleasepool {
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
		[e setBuffer:a offset:0 atIndex:0]; [e setBuffer:c offset:0 atIndex:1]; disp(e, pc, S / 16, 256); [e endEncoding];
		double t0 = now_us(); [cb commit]; [cb waitUntilCompleted]; double w = now_us() - t0;
		if (r) { best = fmin(best, gpuOrWall(cb, w)); bestw = fmin(bestw, w); }
	}
	printf("  copy 256 MB private (random)  : %6.1f GB/s GPU (%.0f us), %6.1f GB/s wall\n", 2.0 * S / (best * 1e3), best, 2.0 * S / (bestw * 1e3));
	best = 1e18;
	for (int r = 0; r < 6; r++) @autoreleasepool {
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		[b copyFromBuffer:a sourceOffset:0 toBuffer:c destinationOffset:0 size:S]; [b endEncoding];
		double t0 = now_us(); [cb commit]; [cb waitUntilCompleted]; double w = now_us() - t0;
		if (r) best = fmin(best, gpuOrWall(cb, w));
	}
	printf("  blit copy 256 MB private      : %6.1f GB/s (%.0f us)\n", 2.0 * S / (best * 1e3), best);
}

static void testLoop(double sec, const char *mode) {
	id<MTLComputePipelineState> pn = pipe_(@"nop"), ps = pipe_(@"saxpy"), pf = pipe_(@"flops");
	id<MTLBuffer> x = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModePrivate];
	id<MTLBuffer> y = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModePrivate];
	double t0 = now_us(); long it = 0;
	while (now_us() - t0 < sec * 1e6) @autoreleasepool {
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
		[e setBuffer:x offset:0 atIndex:0]; [e setBuffer:y offset:0 atIndex:1];
		if (!strcmp(mode, "lat")) disp(e, pn, 32, 32);
		else if (!strcmp(mode, "small")) disp(e, ps, (256 << 10) / 16, 256);
		else disp(e, pf, 1 << 20, 256);
		[e endEncoding]; [cb commit]; [cb waitUntilCompleted]; it++;
	}
	printf("[loop %s] %ld command buffers in %.1f s: %.1f us each\n", mode, it, sec, sec * 1e6 / it);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		int ai = 1; BOOL igpu = argc > 1 && !strcmp(argv[1], "igpu"); if (igpu) ai++;
		for (id<MTLDevice> d in MTLCopyAllDevices()) {
			BOOL nv = [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"];
			if (igpu ? !nv : nv) dev = d;
		}
		if (!dev) { printf("no device\n"); return 2; }
		printf("device: %s\n", dev.name.UTF8String);
		q = [dev newCommandQueue];
		NSError *e = nil;
		lib = [dev newLibraryWithSource:kSource options:nil error:&e];
		if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 1; }
		tbase = now_us();
		const char *t = ai < argc ? argv[ai] : "lat";
		int n = ai + 1 < argc ? atoi(argv[ai + 1]) : 1000;
		if (!strcmp(t, "lat")) testLat(n);
		else if (!strcmp(t, "handler")) testHandler(n);
		else if (!strcmp(t, "latk")) testLatK(n);
		else if (!strcmp(t, "inflight")) testInflight(n);
		else if (!strcmp(t, "small")) testSmall();
		else if (!strcmp(t, "buf")) testBuf();
		else if (!strcmp(t, "alu")) testAlu();
		else if (!strcmp(t, "loop")) testLoop(ai + 1 < argc ? atof(argv[ai + 1]) : 10, ai + 2 < argc ? argv[ai + 2] : "lat");
		else printf("unknown test %s\n", t);
		fflush(stdout);
	}
	return 0;
}
