// SPDX-License-Identifier: MIT
// mtl_tests: a wider Metal check of the B580 (NVMTLDevice over our ANV) than mtl_smoke, with the system's iGPU as the
// reference for the timings. Build on the build Mac:
//   clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O1 -o mtl_tests mtl_tests.m -framework Foundation -framework Metal \
//     -framework IOKit -framework IOSurface
// Run on the hackintosh: NVMTL_ENABLE=1 ./mtl_tests [igpu] [test...]   (the plugin only serves allow-listed processes;
// "bw" (checked bandwidth) and "mip" (minified texture quality against a CPU reference) run only when named;
// NVMTL_BUNDLE=<dir>/NVMTLDriver.bundle tests that plugin build instead of the installed one)
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <objc/message.h>

static int failures;

#define CHECKF(cond, ...) do { if (!(cond)) { printf("  FAIL: " __VA_ARGS__); printf("\n"); failures++; return; } } while (0)

static NSString *const kSource = @R"(
#include <metal_stdlib>
using namespace metal;

kernel void vadd(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *c [[buffer(2)]],
                 uint i [[thread_position_in_grid]]) { c[i] = a[i] + b[i] * 2.0f; }

kernel void reduce(device const uint *in [[buffer(0)]], device atomic_uint *sum [[buffer(1)]],
                   threadgroup uint *tg [[threadgroup(0)]], uint i [[thread_position_in_grid]],
                   uint l [[thread_position_in_threadgroup]], uint n [[threads_per_threadgroup]]) {
    tg[l] = in[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = n / 2; s > 0; s >>= 1) {
        if (l < s) tg[l] += tg[l + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (l == 0) atomic_fetch_add_explicit(sum, tg[0], memory_order_relaxed);
}

kernel void mathk(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float x = float(i) * 0.001f;
    out[i] = float4(sin(x), sqrt(x + 1.0f), exp(-x), fma(x, 2.0f, 1.0f));
}

kernel void texwrite(texture2d<float, access::write> t [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    t.write(float4(float(p.x) / 255.0f, float(p.y) / 255.0f, 0.5f, 1.0f), p);
}

kernel void texread(texture2d<float, access::read> t [[texture(0)]], device uint *out [[buffer(0)]],
                    uint2 p [[thread_position_in_grid]]) {
    float4 c = t.read(p);
    out[p.y * 256 + p.x] = uint(round(c.r * 255.0f)) | uint(round(c.g * 255.0f)) << 8;
}

kernel void flops(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    float a = float(i & 1023) * 1e-3f, b = 1.0001f, c = 0.9999f;
    for (int k = 0; k < 1024; k++) { a = fma(a, b, c); a = fma(a, c, -b); }
    out[i] = a;
}

kernel void copyk(device const float4 *in [[buffer(0)]], device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = in[i];
}

struct VOut { float4 pos [[position]]; float4 col; };
vertex VOut vs(uint v [[vertex_id]], device const float2 *pos [[buffer(0)]]) {
    VOut o; o.pos = float4(pos[v], 0.0f, 1.0f); o.col = float4(v == 0, v == 1, v == 2, 1.0f); return o;
}
fragment float4 fs(VOut in [[stage_in]]) { return float4(1.0f, 0.0f, 1.0f, 1.0f); }

// mip: a full-screen triangle, so pixel (x, y) samples uv ((x + 0.5) / W, (y + 0.5) / H) with constant derivatives
struct QOut { float4 pos [[position]]; float2 uv; };
vertex QOut quadvs(uint v [[vertex_id]]) {
    float2 p = float2((v << 1) & 2, v & 2);
    QOut o; o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f); o.uv = float2(p.x, 1.0f - p.y); return o;
}
fragment float4 mipfs(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv);
}
fragment float4 mipfs_const(QOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
fragment float4 mipfs_level(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                            constant float &lod [[buffer(0)]]) {
    return t.sample(s, in.uv, level(lod));
}
fragment float4 mipfs_grad(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                           constant float &lod [[buffer(0)]]) {
    float g = exp2(lod) / float(t.get_width());
    return t.sample(s, in.uv, gradient2d(float2(g, 0.0f), float2(0.0f, g)));
}
fragment float4 mipfs_bias(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                           constant float &lod [[buffer(0)]]) {
    return t.sample(s, in.uv, bias(lod));
}
fragment float4 mipfs_lod(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return float4(t.calculate_unclamped_lod(s, in.uv) / 16.0f, t.calculate_clamped_lod(s, in.uv) / 16.0f,
                  length(dfdx(in.uv)) * 64.0f, length(dfdy(in.uv)) * 64.0f);
}
)";

static BOOL run(id<MTLCommandBuffer> cb, double *ms) {
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[cb addCompletedHandler:^(id<MTLCommandBuffer> b) { dispatch_semaphore_signal(sem); }];
	NSDate *t0 = [NSDate date];
	[cb commit];
	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
		printf("  TIMEOUT (command buffer never completed)\n");
		return NO;
	}
	if (ms) *ms = -[t0 timeIntervalSinceNow] * 1000.0;
	if (cb.error) {
		printf("  command buffer error: %s\n", cb.error.localizedDescription.UTF8String);
		return NO;
	}
	return YES;
}

static id<MTLComputePipelineState> computePipe(id<MTLDevice> d, id<MTLLibrary> lib, NSString *name) {
	NSError *e = nil;
	id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&e];
	if (!p) printf("  pipeline %s: %s\n", name.UTF8String, e.localizedDescription.UTF8String);
	return p;
}

static void dispatch1(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> p, NSUInteger n, NSUInteger tg) {
	[enc setComputePipelineState:p];
	[enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
}

static void testVadd(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	const NSUInteger n = 1 << 20;
	id<MTLBuffer> a = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> b = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> c = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	float *pa = a.contents, *pb = b.contents;
	for (NSUInteger i = 0; i < n; i++) { pa[i] = i; pb[i] = 0.5f * i; }
	id<MTLComputePipelineState> p = computePipe(d, lib, @"vadd");
	CHECKF(p, "vadd pipeline");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
	[enc setBuffer:a offset:0 atIndex:0];
	[enc setBuffer:b offset:0 atIndex:1];
	[enc setBuffer:c offset:0 atIndex:2];
	dispatch1(enc, p, n, 256);
	[enc endEncoding];
	double ms;
	CHECKF(run(cb, &ms), "vadd did not run");
	float *pc = c.contents;
	NSUInteger bad = 0;
	for (NSUInteger i = 0; i < n; i++) bad += pc[i] != pa[i] + pb[i] * 2.0f;
	CHECKF(!bad, "vadd: %lu of %lu wrong (c[1]=%f)", (unsigned long)bad, (unsigned long)n, pc[1]);
	printf("  PASS vadd: 1M floats in %.2f ms\n", ms);
}

static void testReduce(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	const NSUInteger n = 1 << 20;
	id<MTLBuffer> in = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> sum = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
	uint32_t *pi = in.contents, expect = 0;
	for (NSUInteger i = 0; i < n; i++) { pi[i] = (uint32_t)(i % 7); expect += pi[i]; }
	*(uint32_t *)sum.contents = 0;
	id<MTLComputePipelineState> p = computePipe(d, lib, @"reduce");
	CHECKF(p, "reduce pipeline");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
	[enc setBuffer:in offset:0 atIndex:0];
	[enc setBuffer:sum offset:0 atIndex:1];
	[enc setThreadgroupMemoryLength:256 * 4 atIndex:0];
	dispatch1(enc, p, n, 256);
	[enc endEncoding];
	CHECKF(run(cb, NULL), "reduce did not run");
	uint32_t got = *(uint32_t *)sum.contents;
	CHECKF(got == expect, "reduce: got %u expected %u", got, expect);
	printf("  PASS threadgroup memory + barriers + atomics: sum %u\n", got);
}

static void testMath(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	const NSUInteger n = 4096;
	id<MTLBuffer> out = [d newBufferWithLength:n * 16 options:MTLResourceStorageModeShared];
	id<MTLComputePipelineState> p = computePipe(d, lib, @"mathk");
	CHECKF(p, "math pipeline");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
	[enc setBuffer:out offset:0 atIndex:0];
	dispatch1(enc, p, n, 64);
	[enc endEncoding];
	CHECKF(run(cb, NULL), "math did not run");
	float *o = out.contents;
	double worst = 0;
	for (NSUInteger i = 0; i < n; i++) {
		float x = i * 0.001f;
		double e[4] = {sin(x), sqrt(x + 1.0), exp(-x), x * 2.0 + 1.0};
		for (int k = 0; k < 4; k++) worst = fmax(worst, fabs(o[i * 4 + k] - e[k]));
	}
	CHECKF(worst < 1e-3, "math: worst error %g", worst);
	printf("  PASS sin/sqrt/exp/fma: worst error %.2e\n", worst);
}

static void testTexture(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256
		height:256 mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	id<MTLBuffer> out = [d newBufferWithLength:256 * 256 * 4 options:MTLResourceStorageModeShared];
	id<MTLComputePipelineState> pw = computePipe(d, lib, @"texwrite"), pr = computePipe(d, lib, @"texread");
	CHECKF(t && pw && pr, "texture setup");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
	[enc setComputePipelineState:pw];
	[enc setTexture:t atIndex:0];
	[enc dispatchThreads:MTLSizeMake(256, 256, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[enc memoryBarrierWithScope:MTLBarrierScopeTextures];
	[enc setComputePipelineState:pr];
	[enc setTexture:t atIndex:0];
	[enc setBuffer:out offset:0 atIndex:0];
	[enc dispatchThreads:MTLSizeMake(256, 256, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[enc endEncoding];
	CHECKF(run(cb, NULL), "texture kernels did not run");
	uint32_t *o = out.contents, bad = 0;
	for (uint32_t y = 0; y < 256; y++)
		for (uint32_t x = 0; x < 256; x++) bad += o[y * 256 + x] != (x | y << 8);
	CHECKF(!bad, "texture: %u of 65536 texels wrong (o[257]=0x%x)", bad, o[257]);
	printf("  PASS compute texture write + read (256x256 RGBA8, private storage)\n");
}

static void testBlit(id<MTLDevice> d, id<MTLCommandQueue> q) {
	const NSUInteger n = 1 << 20;
	id<MTLBuffer> src = [d newBufferWithLength:n options:MTLResourceStorageModeShared];
	id<MTLBuffer> mid = [d newBufferWithLength:n options:MTLResourceStorageModePrivate];
	id<MTLBuffer> dst = [d newBufferWithLength:n options:MTLResourceStorageModeShared];
	id<MTLBuffer> fill = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
	uint8_t *ps = src.contents;
	for (NSUInteger i = 0; i < n; i++) ps[i] = (uint8_t)(i * 31 + 7);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromBuffer:src sourceOffset:0 toBuffer:mid destinationOffset:0 size:n];
	[b copyFromBuffer:mid sourceOffset:0 toBuffer:dst destinationOffset:0 size:n];
	[b fillBuffer:fill range:NSMakeRange(0, 4096) value:0x5a];
	[b endEncoding];
	CHECKF(run(cb, NULL), "blit did not run");
	CHECKF(!memcmp(src.contents, dst.contents, n), "blit: shared -> private -> shared copy differs");
	uint8_t *pf = fill.contents;
	for (int i = 0; i < 4096; i++) CHECKF(pf[i] == 0x5a, "blit fill: byte %d = 0x%x", i, pf[i]);
	printf("  PASS blit: copy through private (VRAM) storage, fillBuffer\n");
}

static void testRender(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128
		height:128 mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> rt = [d newTextureWithDescriptor:td];
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	NSError *e = nil;
	id<MTLRenderPipelineState> rp = [d newRenderPipelineStateWithDescriptor:pd error:&e];
	CHECKF(rp, "render pipeline: %s", e.localizedDescription.UTF8String);
	const float tri[6] = {-1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f};   // lower-left half of the target
	id<MTLBuffer> vb = [d newBufferWithBytes:tri length:sizeof(tri) options:MTLResourceStorageModeShared];
	id<MTLBuffer> out = [d newBufferWithLength:128 * 128 * 4 options:MTLResourceStorageModeShared];
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
	rpd.colorAttachments[0].texture = rt;
	rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
	rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0.5, 0, 1);
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rpd];
	[r setRenderPipelineState:rp];
	[r setVertexBuffer:vb offset:0 atIndex:0];
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(128, 128, 1)
		toBuffer:out destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:512 * 128];
	[b endEncoding];
	CHECKF(run(cb, NULL), "render pass did not run");
	const uint32_t *px = out.contents;
	// BGRA8 little endian: magenta 0xffff00ff, clear green (0, 0.5, 0) 0xff008000 (0.5 -> 0x80 or 0x7f)
	uint32_t nTri = 0, clear = 0, other = 0;
	for (uint32_t y = 0; y < 128; y++)
		for (uint32_t x = 0; x < 128; x++) {
			uint32_t p = px[y * 128 + x];
			bool inTri = x + (127 - y) < 126;   // NDC lower-left triangle: screen bottom-left (y grows downwards)
			bool onEdge = x + (127 - y) >= 126 && x + (127 - y) <= 128;
			if (onEdge) continue;
			if (inTri ? p == 0xffff00ff : (p & 0xffffff00) == 0xff008000 || (p & 0xffffff00) == 0xff007f00) inTri ? nTri++ : clear++;
			else other++;
		}
	CHECKF(!other, "render: %u pixels wrong (tri %u clear %u; px[0]=0x%08x px[127*128]=0x%08x)", other, nTri, clear,
		px[0], px[127 * 128]);
	printf("  PASS render: clear + triangle (vertex + fragment shader), %u magenta, %u clear pixels\n", nTri, clear);
}

static void testPerf(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	const NSUInteger n = 1 << 22;   // 4M threads x 2048 FMA = 17.2 GFLOP
	id<MTLBuffer> out = [d newBufferWithLength:n * 4 options:MTLResourceStorageModePrivate];
	id<MTLComputePipelineState> p = computePipe(d, lib, @"flops");
	const NSUInteger m = 1 << 24;   // 16M float4 = 256 MB read + 256 MB written
	id<MTLBuffer> a = [d newBufferWithLength:m * 16 options:MTLResourceStorageModePrivate];
	id<MTLBuffer> c = [d newBufferWithLength:m * 16 options:MTLResourceStorageModePrivate];
	id<MTLComputePipelineState> pc = computePipe(d, lib, @"copyk");
	CHECKF(p && pc && out && a && c, "perf setup");
	double best = 1e9, bestCopy = 1e9;
	for (int r = 0; r < 4; r++) {
		double ms;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
		[enc setBuffer:out offset:0 atIndex:0];
		dispatch1(enc, p, n, 256);
		[enc endEncoding];
		CHECKF(run(cb, &ms), "flops did not run");
		best = fmin(best, ms);
		cb = [q commandBuffer];
		enc = [cb computeCommandEncoder];
		[enc setBuffer:a offset:0 atIndex:0];
		[enc setBuffer:c offset:0 atIndex:1];
		dispatch1(enc, pc, m, 256);
		[enc endEncoding];
		CHECKF(run(cb, &ms), "copy did not run");
		bestCopy = fmin(bestCopy, ms);
	}
	printf("  PERF fma: %.1f GFLOPS (%.2f ms), device-memory copy: %.1f GB/s (%.2f ms; wall clock incl. submit)\n",
		2.0 * 2048 * n / (best * 1e6), best, 2.0 * m * 16 / (bestCopy * 1e6), bestCopy);
}

// Memory bandwidth, checked: the copy kernel over random and over all-zero data at several sizes, every byte of the
// result compared with the source, timed with the command buffer's GPU timestamps when the driver fills them (wall
// clock otherwise). Xe2 compresses VRAM (flat CCS), so zero data can move faster than the 456 GB/s GDDR6 peak.
static void testBw(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	id<MTLComputePipelineState> pc = computePipe(d, lib, @"copyk");
	CHECKF(pc, "bw setup");
	for (NSUInteger mb = 16; mb <= 256; mb *= 4) {
		const NSUInteger bytes = mb << 20, m = bytes / 16;
		id<MTLBuffer> a = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
		id<MTLBuffer> c = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
		id<MTLBuffer> src = [d newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		id<MTLBuffer> dst = [d newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		CHECKF(a && c && src && dst, "bw: %lu MB buffers", (unsigned long)mb);
		for (int zero = 0; zero < 2; zero++) {
			uint64_t *w = src.contents, x = 0x9E3779B97F4A7C15ull;
			for (NSUInteger i = 0; i < bytes / 8; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = zero ? 0 : x; }
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
			[b copyFromBuffer:src sourceOffset:0 toBuffer:a destinationOffset:0 size:bytes];
			[b fillBuffer:c range:NSMakeRange(0, bytes) value:0x5A];   // a copy that never ran cannot pass
			[b endEncoding];
			CHECKF(run(cb, NULL), "bw upload did not run");
			double wall = 1e9, gpu = 1e9;
			for (int r = 0; r < 5; r++) {
				double ms;
				cb = [q commandBuffer];
				id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
				[enc setBuffer:a offset:0 atIndex:0];
				[enc setBuffer:c offset:0 atIndex:1];
				dispatch1(enc, pc, m, 256);
				[enc endEncoding];
				CHECKF(run(cb, &ms), "bw copy did not run");
				wall = fmin(wall, ms);
				if (cb.GPUEndTime > cb.GPUStartTime) gpu = fmin(gpu, (cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
			}
			cb = [q commandBuffer];
			b = [cb blitCommandEncoder];
			[b copyFromBuffer:c sourceOffset:0 toBuffer:dst destinationOffset:0 size:bytes];
			[b endEncoding];
			CHECKF(run(cb, NULL), "bw readback did not run");
			CHECKF(!memcmp(src.contents, dst.contents, bytes), "bw: %lu MB %s copy is wrong", (unsigned long)mb,
				zero ? "zero" : "random");
			printf("  PASS bw %4lu MB %-6s: %.1f GB/s wall (%.2f ms)", (unsigned long)mb, zero ? "zero" : "random",
				2.0 * bytes / (wall * 1e6), wall);
			if (gpu < 1e9) printf(", %.1f GB/s GPU time (%.2f ms)", 2.0 * bytes / (gpu * 1e6), gpu);
			printf("\n");
		}
	}
}

// Minified texture quality, against a CPU reference (the iGPU is not always there to compare with). Level 0 is a 512x512
// pattern with detail at every scale; level n+1 is the rounded 2x2 box of level n (what generateMipmapsForTexture makes,
// in linear light for sRGB); a pixel of the minified quad is the trilinear (or the sampler's) sample of those levels.
// Each variant reports the mean and max error per channel in 1/255 and the worst mip level the GPU holds.
#define MIP_N 512
#define MIP_LEVELS 10
typedef struct {
	const char *name;
	int gen;            // 0 levels poisoned, level 0 replaceRegion, blit generateMipmaps; 1 replaceRegion of every level;
	                    // 2 private, blit copyFromBuffer level 0 + generateMipmaps (CA's upload); 3 replaceRegion level 0 only;
	                    // 4 as 2 from a private heap (a recycled heap texture, as WindowServer's CA gets them); 5 an IOSurface
	                    // texture blit-copied to level 0 + generateMipmaps (CA's IOSurface contents)
	MTLPixelFormat fmt;
	uint32_t w;         // the quad is w x w pixels
	int minLinear, mip; // mip: 0 not mipmapped, 1 nearest, 2 linear
	NSString *fs;
	float lodMin, lodMax, param;
	NSUInteger aniso;
} MipVariant;

// half floats for the RGBA16Float variant (values in [0, 1]: normal numbers and zero only)
static uint16_t floatToHalf(float f) {
	if (f <= 0.0f) return 0;
	int e; float m = frexpf(f, &e);   // f = m * 2^e, m in [0.5, 1)
	uint32_t man = (uint32_t)lrintf((m * 2.0f - 1.0f) * 1024.0f);
	if (man == 1024) { man = 0; e++; }
	return (uint16_t)(((e - 1 + 15) << 10) | man);
}
static float halfToFloat(uint16_t h) {
	int e = (h >> 10) & 31, m = h & 1023;
	return e ? ldexpf(1.0f + m / 1024.0f, e - 15) : ldexpf(m / 1024.0f, -14);
}

static float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }
static float linearToSrgb(float c) { return c <= 0.0031308f ? c * 12.92f : 1.055f * powf(c, 1.0f / 2.4f) - 0.055f; }

static void mipPattern(uint8_t *p) {
	uint32_t h = 0x12345678u;
	for (uint32_t y = 0; y < MIP_N; y++)
		for (uint32_t x = 0; x < MIP_N; x++) {
			uint8_t *t = p + ((size_t)y * MIP_N + x) * 4;
			h ^= h << 13; h ^= h >> 17; h ^= h << 5;
			t[0] = ((x ^ y) & 1) ? 255 : 0;                                           // 1-texel checker: moire without mips
			t[1] = ((x >> 3) & 1) ? 255 : 0;                                          // 8-texel stripes: 1 texel at level 3
			t[2] = (uint8_t)(((x + y) & 7) == 0 ? 255 : (h >> 24) & 63);             // thin diagonals over noise
			t[3] = (uint8_t)(((x / 5 + y / 3) & 1) ? 255 : 96);                      // alpha detail
		}
}

// levels[l] holds level l as RGBA8 (sRGB-encoded when srgb); box in linear light for sRGB, alpha always linear
static void mipBuildLevels(uint8_t *levels[MIP_LEVELS], int srgb) {
	for (int l = 1; l < MIP_LEVELS; l++) {
		uint32_t s = MIP_N >> l, ps = s * 2;
		const uint8_t *src = levels[l - 1];
		for (uint32_t y = 0; y < s; y++)
			for (uint32_t x = 0; x < s; x++)
				for (int c = 0; c < 4; c++) {
					const uint8_t *q[4] = { src + ((size_t)(2 * y) * ps + 2 * x) * 4, src + ((size_t)(2 * y) * ps + 2 * x + 1) * 4,
						src + ((size_t)(2 * y + 1) * ps + 2 * x) * 4, src + ((size_t)(2 * y + 1) * ps + 2 * x + 1) * 4 };
					float v = 0;
					for (int k = 0; k < 4; k++) v += srgb && c < 3 ? srgbToLinear(q[k][c] / 255.0f) : q[k][c] / 255.0f;
					v *= 0.25f;
					if (srgb && c < 3) v = linearToSrgb(v);
					levels[l][((size_t)y * s + x) * 4 + c] = (uint8_t)lrintf(fminf(fmaxf(v, 0.0f), 1.0f) * 255.0f);
				}
	}
}

static float mipTexel(uint8_t *levels[MIP_LEVELS], int l, int x, int y, int c, int srgb) {
	int s = MIP_N >> l;
	x = x < 0 ? 0 : x >= s ? s - 1 : x;
	y = y < 0 ? 0 : y >= s ? s - 1 : y;
	float v = levels[l][((size_t)y * s + x) * 4 + c] / 255.0f;
	return srgb && c < 3 ? srgbToLinear(v) : v;
}

static float mipSample2D(uint8_t *levels[MIP_LEVELS], int l, float u, float v, int c, int linear, int srgb) {
	int s = MIP_N >> l;
	if (!linear) return mipTexel(levels, l, (int)floorf(u * s), (int)floorf(v * s), c, srgb);
	float fx = u * s - 0.5f, fy = v * s - 0.5f;
	int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
	float ax = fx - x0, ay = fy - y0;
	return (1 - ay) * ((1 - ax) * mipTexel(levels, l, x0, y0, c, srgb) + ax * mipTexel(levels, l, x0 + 1, y0, c, srgb)) +
		ay * ((1 - ax) * mipTexel(levels, l, x0, y0 + 1, c, srgb) + ax * mipTexel(levels, l, x0 + 1, y0 + 1, c, srgb));
}

static float mipReference(uint8_t *levels[MIP_LEVELS], const MipVariant *v, float lod, float u, float t, int c, int srgb) {
	if (v->mip == 0) return mipSample2D(levels, 0, u, t, c, v->minLinear, srgb);
	lod = fminf(fmaxf(lod, fmaxf(v->lodMin, 0.0f)), fminf(v->lodMax, MIP_LEVELS - 1));
	if (v->mip == 1) return mipSample2D(levels, (int)ceilf(lod + 0.5f) - 1, u, t, c, v->minLinear, srgb);
	int l0 = (int)floorf(lod), l1 = l0 + 1 < MIP_LEVELS ? l0 + 1 : l0;
	float f = lod - l0;
	return (1 - f) * mipSample2D(levels, l0, u, t, c, v->minLinear, srgb) + f * mipSample2D(levels, l1, u, t, c, v->minLinear, srgb);
}

static id<MTLRenderPipelineState> mipPipe(id<MTLDevice> d, id<MTLLibrary> lib, NSString *fs) {
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"quadvs"];
	pd.fragmentFunction = [lib newFunctionWithName:fs];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	NSError *e = nil;
	id<MTLRenderPipelineState> rp = [d newRenderPipelineStateWithDescriptor:pd error:&e];
	if (!rp) printf("  pipeline %s: %s\n", fs.UTF8String, e.localizedDescription.UTF8String);
	return rp;
}

// Draws the minified quad: tex through sampler s (nil: the shader's own) into a w x w RGBA8 target, read back into out
static BOOL mipDraw(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLRenderPipelineState> rp, id<MTLTexture> tex,
	id<MTLSamplerState> s, float param, uint32_t w, uint8_t *out) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w
		height:w mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> rt = [d newTextureWithDescriptor:td];
	id<MTLBuffer> rb = [d newBufferWithLength:w * w * 4 options:MTLResourceStorageModeShared];
	if (!rt || !rb) return NO;
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
	rpd.colorAttachments[0].texture = rt;
	rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
	rpd.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:rpd];
	[r setRenderPipelineState:rp];
	[r setFragmentTexture:tex atIndex:0];
	if (s) [r setFragmentSamplerState:s atIndex:0];
	[r setFragmentBytes:&param length:sizeof param atIndex:0];
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1)
		toBuffer:rb destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * w * 4];
	[b endEncoding];
	if (!run(cb, NULL)) return NO;
	memcpy(out, rb.contents, w * w * 4);
	return YES;
}

static void testMip(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
	const float lod48 = log2f(MIP_N / 48.0f);
	const MipVariant vs[] = {
		{ "blit generateMipmaps, trilinear, 64", 0, MTLPixelFormatRGBA8Unorm, 64, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "blit generateMipmaps, trilinear, 48", 0, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, trilinear, 64", 1, MTLPixelFormatRGBA8Unorm, 64, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, trilinear, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, mip nearest, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 1, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, not mipmapped, 64", 1, MTLPixelFormatRGBA8Unorm, 64, 1, 0, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, nearest+nearest, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 0, 1, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "replaceRegion levels, anisotropy 16, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 16 },
		{ "replaceRegion levels, lodMaxClamp 2, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs", 0, 2, 0, 1 },
		{ "replaceRegion levels, lodMinClamp 4, 64", 1, MTLPixelFormatRGBA8Unorm, 64, 1, 2, @"mipfs", 4, FLT_MAX, 0, 1 },
		{ "constexpr sampler trilinear, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs_const", 0, FLT_MAX, 0, 1 },
		{ "sample level(lod), 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs_level", 0, FLT_MAX, lod48, 1 },
		{ "sample gradient2d, 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs_grad", 0, FLT_MAX, lod48, 1 },
		{ "sample bias(0), 48", 1, MTLPixelFormatRGBA8Unorm, 48, 1, 2, @"mipfs_bias", 0, FLT_MAX, 0, 1 },
		{ "CA-like private BGRA8, blit upload + generateMipmaps, 64", 2, MTLPixelFormatBGRA8Unorm, 64, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "CA-like BGRA8, level 0 only, 64", 3, MTLPixelFormatBGRA8Unorm, 64, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "CA-like recycled heap texture, blit upload + generateMipmaps, 52", 4, MTLPixelFormatBGRA8Unorm, 52, 1, 2, @"mipfs", 0, FLT_MAX, 0, 8 },
		{ "CA-like IOSurface -> blit level 0 + generateMipmaps, 52", 5, MTLPixelFormatBGRA8Unorm, 52, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "sRGB, blit generateMipmaps, 48", 0, MTLPixelFormatRGBA8Unorm_sRGB, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "sRGB, replaceRegion levels, 48", 1, MTLPixelFormatRGBA8Unorm_sRGB, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "CA-like sRGB, level 0 only, 48", 3, MTLPixelFormatRGBA8Unorm_sRGB, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
		{ "CA-like RGBA16Float (wide colour), level 0 only, 48", 3, MTLPixelFormatRGBA16Float, 48, 1, 2, @"mipfs", 0, FLT_MAX, 0, 1 },
	};
	uint8_t *lin[MIP_LEVELS], *srgb[MIP_LEVELS];
	for (int l = 0; l < MIP_LEVELS; l++) {
		size_t s = MIP_N >> l;
		lin[l] = malloc(s * s * 4);
		srgb[l] = malloc(s * s * 4);
	}
	mipPattern(lin[0]);
	memcpy(srgb[0], lin[0], MIP_N * MIP_N * 4);
	mipBuildLevels(lin, 0);
	mipBuildLevels(srgb, 1);
	uint8_t *swz = malloc(MIP_N * MIP_N * 8), *got = malloc(MIP_N * MIP_N * 4);
	NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipes = [NSMutableDictionary new];
	int bad = 0;
	for (size_t vi = 0; vi < sizeof vs / sizeof vs[0]; vi++) {
		const MipVariant *v = &vs[vi];
		const int isSrgb = v->fmt == MTLPixelFormatRGBA8Unorm_sRGB, bgra = v->fmt == MTLPixelFormatBGRA8Unorm;
		const int half = v->fmt == MTLPixelFormatRGBA16Float;
		const uint32_t tb = half ? 8 : 4;   // bytes per texel
		uint8_t **lv = isSrgb ? srgb : lin;
		id<MTLRenderPipelineState> rp = pipes[v->fs];
		if (!rp) rp = pipes[v->fs] = mipPipe(d, lib, v->fs);
		CHECKF(rp, "mip: pipeline %s", v->fs.UTF8String);
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:v->fmt width:MIP_N height:MIP_N mipmapped:YES];
		td.usage = MTLTextureUsageShaderRead;
		td.storageMode = v->gen == 2 || v->gen == 4 || v->gen == 5 ? MTLStorageModePrivate : MTLStorageModeManaged;
		id<MTLHeap> heap = nil;
		if (v->gen == 4) {
			MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
			hd.storageMode = MTLStorageModePrivate;
			hd.size = 8 << 20;
			heap = [d newHeapWithDescriptor:hd];
			CHECKF(heap, "mip: heap");
			@autoreleasepool { id<MTLTexture> first = [heap newTextureWithDescriptor:td]; (void)first; }   // parked; the next is recycled
		}
		id<MTLTexture> tex = heap ? [heap newTextureWithDescriptor:td] : [d newTextureWithDescriptor:td];
		CHECKF(tex && tex.mipmapLevelCount == MIP_LEVELS, "mip: texture (%lu levels)", (unsigned long)tex.mipmapLevelCount);
		for (int l = 0; l < MIP_LEVELS; l++) {
			if (l && v->gen != 0 && v->gen != 1) break;
			uint32_t s = MIP_N >> l;
			const uint8_t *src = lv[l];
			if (bgra || (v->gen == 0 && l)) {
				for (size_t i = 0; i < (size_t)s * s; i++) {
					static const uint8_t magenta[4] = { 255, 0, 255, 255 };
					const uint8_t *p = v->gen == 0 && l ? magenta : lv[l] + i * 4;
					swz[i * 4 + 0] = p[bgra ? 2 : 0]; swz[i * 4 + 1] = p[1]; swz[i * 4 + 2] = p[bgra ? 0 : 2]; swz[i * 4 + 3] = p[3];
				}
				src = swz;
			} else if (half) {
				uint16_t *h = (uint16_t *)swz;
				for (size_t i = 0; i < (size_t)s * s * 4; i++) h[i] = floatToHalf(lv[l][i] / 255.0f);
				src = swz;
			}
			if (v->gen == 2 || v->gen == 4 || v->gen == 5) {
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
				if (v->gen == 5) {
					IOSurfaceRef io = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(s), (id)kIOSurfaceHeight: @(s),
						(id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
					CHECKF(io, "mip: IOSurface");
					IOSurfaceLock(io, 0, NULL);
					for (uint32_t y = 0; y < s; y++)
						memcpy((uint8_t *)IOSurfaceGetBaseAddress(io) + y * IOSurfaceGetBytesPerRow(io), src + (size_t)y * s * 4, (size_t)s * 4);
					IOSurfaceUnlock(io, 0, NULL);
					MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:v->fmt width:s height:s mipmapped:NO];
					sd.usage = MTLTextureUsageShaderRead;
					sd.storageMode = MTLStorageModeManaged;
					id<MTLTexture> st = [d newTextureWithDescriptor:sd iosurface:io plane:0];
					CFRelease(io);
					CHECKF(st, "mip: IOSurface texture");
					[b copyFromTexture:st sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(s, s, 1)
						toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
				} else {
					id<MTLBuffer> up = [d newBufferWithBytes:src length:(size_t)s * s * 4 options:MTLResourceStorageModeShared];
					[b copyFromBuffer:up sourceOffset:0 sourceBytesPerRow:s * 4 sourceBytesPerImage:s * s * 4 sourceSize:MTLSizeMake(s, s, 1)
						toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
				}
				[b generateMipmapsForTexture:tex];
				[b endEncoding];
				CHECKF(run(cb, NULL), "mip: CA-like upload did not run");
			} else   // gen 0: level 0, then magenta over the levels the plugin filled from it, so only generateMipmaps can fix them
				[tex replaceRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:l withBytes:src bytesPerRow:s * tb];
		}
		if (v->gen == 0) {
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
			[b generateMipmapsForTexture:tex];
			[b endEncoding];
			CHECKF(run(cb, NULL), "mip: generateMipmaps did not run");
		}
		// the levels the GPU holds
		int worstLevel = 0, worstLevelAt = -1;
		for (int l = 1; l < MIP_LEVELS; l++) {
			uint32_t s = MIP_N >> l;
			id<MTLBuffer> rb = [d newBufferWithLength:(size_t)s * s * tb options:MTLResourceStorageModeShared];
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
			[b copyFromTexture:tex sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(s, s, 1)
				toBuffer:rb destinationOffset:0 destinationBytesPerRow:s * tb destinationBytesPerImage:s * s * tb];
			[b endEncoding];
			CHECKF(run(cb, NULL), "mip: level %d readback did not run", l);
			const uint8_t *g = rb.contents;
			for (size_t i = 0; i < (size_t)s * s; i++)
				for (int c = 0; c < 4; c++) {
					int gv = half ? (int)lrintf(halfToFloat(((const uint16_t *)g)[i * 4 + c]) * 255.0f) : g[i * 4 + (bgra && c != 1 && c != 3 ? 2 - c : c)];
					int e = abs(gv - (int)lv[l][i * 4 + c]);
					if (e > worstLevel) { worstLevel = e; worstLevelAt = l; }
				}
		}
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
		sd.minFilter = v->minLinear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.mipFilter = v->mip == 2 ? MTLSamplerMipFilterLinear : v->mip == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
		sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
		sd.maxAnisotropy = v->aniso;
		sd.lodMinClamp = v->lodMin;
		sd.lodMaxClamp = v->lodMax;
		id<MTLSamplerState> s = [d newSamplerStateWithDescriptor:sd];
		CHECKF(s, "mip: sampler");
		const uint32_t w = v->w;
		CHECKF(mipDraw(d, q, rp, tex, s, v->param, w, got), "mip: %s did not draw", v->name);
		const float lod = log2f((float)MIP_N / w);
		double sum[4] = {0}, alias = 0; int worst = 0;
		for (uint32_t y = 0; y < w; y++)
			for (uint32_t x = 0; x < w; x++)
				for (int c = 0; c < 4; c++) {
					float u = (x + 0.5f) / w, t = (y + 0.5f) / w;
					float ref = mipReference(lv, v, lod, u, t, c, isSrgb) * 255.0f;
					int e = abs((int)got[((size_t)y * w + x) * 4 + c] - (int)lrintf(ref));
					sum[c] += e; if (e > worst) worst = e;
					alias += fabsf(mipSample2D(lv, 0, u, t, c, 1, isSrgb) * 255.0f - ref);
				}
		const double n = (double)w * w;
		// levels the GPU made may round differently from the CPU's (sum + 2) / 4 by a step per level, so 2 is allowed
		const BOOL ok = worstLevel <= 2 && worst <= 6 && (sum[0] + sum[1] + sum[2] + sum[3]) / (4 * n) <= 1.25;
		bad += !ok;
		printf("  %s mip %-56s err mean r %5.2f g %5.2f b %5.2f a %5.2f max %3d | levels max %3d%s%.0d | no-mip ref %5.2f\n",
			ok ? "PASS" : "FAIL", v->name, sum[0] / n, sum[1] / n, sum[2] / n, sum[3] / n, worst, worstLevel,
			worstLevelAt >= 0 ? " @L" : "", worstLevelAt >= 0 ? worstLevelAt : 0, alias / (4 * n));
	}
	// what LOD and derivatives the fragment shader sees at 512 -> 64 (expect lod 3, |dfdx| = |dfdy| = 1/64)
	{
		id<MTLRenderPipelineState> rp = mipPipe(d, lib, @"mipfs_lod");
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:MIP_N height:MIP_N mipmapped:YES];
		td.usage = MTLTextureUsageShaderRead;
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
		sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.mipFilter = MTLSamplerMipFilterLinear;
		id<MTLTexture> tex = [d newTextureWithDescriptor:td];
		id<MTLSamplerState> s = [d newSamplerStateWithDescriptor:sd];
		if (rp && tex && s && mipDraw(d, q, rp, tex, s, 0, 64, got))
			printf("  INFO mip shader at 512->64: lod unclamped %.2f clamped %.2f, |dfdx| %.4f |dfdy| %.4f (x 1/64)\n",
				got[0] * 16.0f / 255.0f, got[1] * 16.0f / 255.0f, got[2] / 255.0f, got[3] / 255.0f);
	}
	for (int l = 0; l < MIP_LEVELS; l++) { free(lin[l]); free(srgb[l]); }
	free(swz); free(got);
	CHECKF(!bad, "mip: %d variant(s) off the CPU reference", bad);
}

// NVMTL_BUNDLE=<path>/NVMTLDriver.bundle: load that plugin build into this process and make its device on the B580's
// IOAccelerator directly, instead of the installed /Library/GPUBundles one Metal would load (nothing to install)
static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)];
	NSError *e = nil;
	if (![b loadAndReturnError:&e]) {
		printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String);
		return nil;
	}
	Class cls = [b classNamed:@"NVMTLDevice"];
	if (!cls) { printf("bundle %s has no NVMTLDevice\n", path); return nil; }
	io_iterator_t it = 0;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return nil;
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice")))
			dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name);
	}
	IOObjectRelease(it);
	return dev;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		BOOL igpu = argc > 1 && !strcmp(argv[1], "igpu");
		id<MTLDevice> dev = nil;
		const char *bundle = getenv("NVMTL_BUNDLE");
		if (bundle && !igpu)
			dev = bundleDevice(bundle);
		else
			for (id<MTLDevice> d in MTLCopyAllDevices())
				if (igpu ? ![NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"] : [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"])
					dev = d;
		if (!dev) {
			printf("no %s Metal device\n", igpu ? "iGPU" : "B580 (NVMTLDevice)");
			return 2;
		}
		printf("device: %s\n", dev.name.UTF8String);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		NSError *e = nil;
		NSDate *t0 = [NSDate date];
		id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&e];
		if (!lib) {
			printf("FAIL: library: %s\n", e.localizedDescription.UTF8String);
			return 1;
		}
		printf("library compiled in %.0f ms\n", -[t0 timeIntervalSinceNow] * 1000.0);
		const char *names[] = {"vadd", "reduce", "math", "texture", "blit", "render", "perf", "bw", "mip"};
		for (int t = 0; t < 9; t++) {
			BOOL want = t < 7;   // test names after the options pick a subset; bw and mip run only by name
			for (int a = 1; a < argc; a++)
				if (strcmp(argv[a], "igpu")) want = NO;
			for (int a = 1; a < argc; a++)
				if (!strcmp(argv[a], names[t])) want = YES;
			if (!want) continue;
			printf("[%s]\n", names[t]);
			fflush(stdout);
			@autoreleasepool {
				switch (t) {
					case 0: testVadd(dev, q, lib); break;
					case 1: testReduce(dev, q, lib); break;
					case 2: testMath(dev, q, lib); break;
					case 3: testTexture(dev, q, lib); break;
					case 4: testBlit(dev, q); break;
					case 5: testRender(dev, q, lib); break;
					case 6: testPerf(dev, q, lib); break;
					case 7: testBw(dev, q, lib); break;
					case 8: testMip(dev, q, lib); break;
				}
			}
			fflush(stdout);
		}
		printf("%s: %d failure(s)\n", failures ? "FAILED" : "ALL PASSED", failures);
		return failures ? 1 : 0;
	}
}
