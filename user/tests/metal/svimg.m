// SPDX-License-Identifier: MIT
// svimg: two-process image test of B580 VRAM-shared IOSurfaces (gpuperf phase 2: plugin item 7 on ANV, Mesa 0014,
// IntelXe.kext SURFACE_VRAM, NMXAccel page-off). Needs debug.intelxe.surfvram >= 1 before it starts (both processes read the
// switch once). Run on the hackintosh, game and Geekbench closed:
//   NVMTL_ENABLE=1 NVMTL_BUNDLE=<staged>/NVMTLDriver.bundle NVMTL_ICD_LIB=<staged>/libvulkan_intel.dylib ./svimg
// Every comparison is a byte-exact FNV-1a hash of the 2560x1440 BGRA8 image (14.7 MB):
//   1. parent renders pattern P into a render-target texture over a global IOSurface (it makes the VRAM backing) and the
//      same pass into a private texture (reference); the surface texture read back by the GPU == reference
//   2. a CPU IOSurfaceLock in the parent: the pages == reference (paged off from VRAM)
//   3. a second process imports the surface (read-only texture), reads it back on its GPU: == reference; then wraps it as
//      a render target, renders pattern Q into it, publishes (commit) and reports Q's reference hash
//   4. parent: GPU readback of its own texture == Q (the same VRAM, written by the other process), CPU lock == Q
//   5. parent: CPU writes pattern W into the pages; the GPU readback == W (uploaded into the shared VRAM)
// "mode" in the log: whether the plugin really put the surface in VRAM (item 7 log lines), otherwise the copy path ran.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#include <spawn.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern char **environ;
enum { W = 2560, H = 1440, ROW = W * 4 };
static NSString *const kSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V vtri(uint id [[vertex_id]]) { V o; float2 q = float2((id << 1) & 2, id & 2); o.p = float4(q * 2.0 - 1.0, 0.5, 1); o.uv = q; return o; }\n"
"fragment float4 fpat(V i [[stage_in]], constant uint &n [[buffer(0)]]) {\n"
"  float2 z = i.uv; float a = 0;\n"
"  for (uint k = 0; k < n; k++) { z = float2(z.x * z.x - z.y * z.y, 2 * z.x * z.y) * 0.5 + i.uv; a += fract(z.x * 3.1 + z.y); }\n"
"  return float4(fract(a), fract(z.x), fract(z.y), 1); }\n";

static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
	if (![b loadAndReturnError:&e]) { printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String); return nil; }
	Class cls = [b classNamed:@"NVMTLDevice"]; if (!cls) return nil;
	io_iterator_t it = 0; if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return nil;
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice"))) dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name);
	}
	IOObjectRelease(it); return dev;
}
static uint32_t fnv(const void *p, size_t n) { uint32_t h = 2166136261u; const uint8_t *b = p; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 16777619u; } return h; }
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL "); } else printf("PASS "); printf(__VA_ARGS__); printf("\n"); } while (0)

static id<MTLDevice> d; static id<MTLCommandQueue> q; static id<MTLRenderPipelineState> ps; static id<MTLBuffer> rb;
static void draw(id<MTLTexture> t, uint32_t n) {
	id<MTLCommandBuffer> c = [q commandBuffer];
	MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
	r.colorAttachments[0].texture = t; r.colorAttachments[0].loadAction = MTLLoadActionClear; r.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:r];
	[e setRenderPipelineState:ps]; [e setFragmentBytes:&n length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
	[c commit]; [c waitUntilCompleted];
}
static uint32_t readback(id<MTLTexture> t) {
	memset(rb.contents, 0, (size_t)ROW * H);
	id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
	[b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:rb
	  destinationOffset:0 destinationBytesPerRow:ROW destinationBytesPerImage:(NSUInteger)ROW * H];
	[b endEncoding]; [c commit]; [c waitUntilCompleted];
	return fnv(rb.contents, (size_t)ROW * H);
}
static uint32_t pages(IOSurfaceRef s) {
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	const uint32_t h = fnv(IOSurfaceGetBaseAddress(s), (size_t)ROW * H);
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	return h;
}
static id<MTLTexture> surfTex(IOSurfaceRef s, MTLTextureUsage u) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
	td.usage = u; td.storageMode = MTLStorageModeShared;
	return [d newTextureWithDescriptor:td iosurface:s plane:0];
}
static id<MTLTexture> privTex(void) {
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
	return [d newTextureWithDescriptor:td];
}
static int setup(void) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) d = bundleDevice(bp); else for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) d = x;
	if (!d) { printf("no B580 device\n"); return 2; }
	NSError *e = nil; id<MTLLibrary> lib = [d newLibraryWithSource:kSrc options:nil error:&e];
	if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 1; }
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vtri"]; pd.fragmentFunction = [lib newFunctionWithName:@"fpat"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	ps = [d newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { printf("pso: %s\n", e.localizedDescription.UTF8String); return 1; }
	q = [d newCommandQueue];
	rb = [d newBufferWithLength:(size_t)ROW * H options:MTLResourceStorageModeShared];
	return 0;
}

// debug.intelxe.surfvram and its counters: the test proves the VRAM path really ran (adopted/imported, dirty marks,
// page-offs moved) instead of passing on the copy path
struct svst { int level; unsigned adopted, imports, dirty, pageoffs; };
static struct svst svstats(void) {
	struct svst r = { -1, 0, 0, 0, 0 }; int lv = 0; size_t n = sizeof lv;
	if (!sysctlbyname("debug.intelxe.surfvram", &lv, &n, NULL, 0)) r.level = lv;
	char b[512] = ""; n = sizeof b;
	if (!sysctlbyname("debug.intelxe.surfvram_stats", b, &n, NULL, 0)) {
		const char *p;
		if ((p = strstr(b, "adopted "))) r.adopted = (unsigned)atoi(p + 8);
		if ((p = strstr(b, "imports "))) r.imports = (unsigned)atoi(p + 8);
		if ((p = strstr(b, "dirty "))) r.dirty = (unsigned)atoi(p + 6);
		if ((p = strstr(b, "page-offs "))) r.pageoffs = (unsigned)atoi(p + 10);
	}
	return r;
}
// NVMTL_ICD_LIB given: that exact file must be the Vulkan driver in this process (a typo or an unexpanded ~ silently
// falls back to the installed one)
static int icdCheck(const char *who) {
	const char *e = getenv("NVMTL_ICD_LIB");
	if (!e) return 1;
	char want[PATH_MAX];
	if (!realpath(e, want)) { printf("FAIL %s: NVMTL_ICD_LIB=%s does not exist (an unexpanded ~?)\n", who, e); fails++; return 0; }
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		char got[PATH_MAX]; const char *nm = _dyld_get_image_name(i);
		if (nm && realpath(nm, got) && !strcmp(got, want)) { printf("PASS %s: the staged Vulkan driver is loaded (%s)\n", who, want); return 1; }
	}
	printf("FAIL %s: NVMTL_ICD_LIB=%s is NOT the loaded Vulkan driver\n", who, want); fails++;
	return 0;
}
// "readnow": import the surface and read it back at once; the parent handed it over right after waitUntilScheduled (its
// write may still be running): implicit sync must make this read wait for that write on the GPU
static int childReadNow(uint32_t sid, const char *out) {
	if (setup()) return 3;
	IOSurfaceRef s = IOSurfaceLookup(sid);
	if (!s) return 1;
	const uint32_t got = readback(surfTex(s, MTLTextureUsageShaderRead));
	FILE *f = fopen(out, "w"); if (f) { fprintf(f, "%08x\n", got); fclose(f); }
	CFRelease(s);
	return 0;
}
static int child(uint32_t sid, uint32_t refP, const char *out) {
	if (setup()) return 3;
	IOSurfaceRef s = IOSurfaceLookup(sid);
	CHECK(s != NULL, "child: IOSurfaceLookup(%u)", sid);
	if (!s) return 1;
	id<MTLTexture> rd = surfTex(s, MTLTextureUsageShaderRead);
	const uint32_t got = readback(rd);
	icdCheck("child");
	CHECK(got == refP, "child: reads the parent's pattern P from the surface (%08x, expected %08x)", got, refP);
	id<MTLTexture> wr = surfTex(s, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	draw(wr, 9);
	id<MTLTexture> ref = privTex(); draw(ref, 9);
	const uint32_t refQ = readback(ref), gotQ = readback(wr);
	CHECK(gotQ == refQ, "child: renders pattern Q into the surface (%08x, reference %08x)", gotQ, refQ);
	FILE *f = fopen(out, "w"); if (f) { fprintf(f, "%08x\n", refQ); fclose(f); }
	CFRelease(s);
	return fails ? 1 : 0;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		if (argc == 4 && !strcmp(argv[1], "readnow")) return childReadNow((uint32_t)strtoul(argv[2], 0, 0), argv[3]);
		if (argc == 5 && !strcmp(argv[1], "child")) return child((uint32_t)strtoul(argv[2], 0, 0), (uint32_t)strtoul(argv[3], 0, 16), argv[4]);
		const struct svst st0 = svstats();
		if (setup()) return 2;
		NSDictionary *sp = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(ROW),
		                      (id)kIOSurfacePixelFormat: @(0x42475241), (id)kIOSurfaceIsGlobal: @YES };
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)sp);
		if (!s) { printf("IOSurfaceCreate failed\n"); return 1; }
		const uint32_t sid = IOSurfaceGetID(s);
		printf("surface %u\n", sid);
		// 1
		id<MTLTexture> t = surfTex(s, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead), ref = privTex();
		draw(t, 5); draw(ref, 5);
		const uint32_t refP = readback(ref), gotP = readback(t);
		icdCheck("parent");
		CHECK(gotP == refP, "parent: renders pattern P into the surface (%08x, reference %08x)", gotP, refP);
		// 2
		uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		const uint32_t pg = pages(s);
		CHECK(pg == refP, "parent: CPU lock sees P in the pages (%08x; lock + hash %.2f ms)", pg, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
		// 3
		char a1[16], a2[16], out[1024];
		snprintf(a1, sizeof a1, "%u", sid); snprintf(a2, sizeof a2, "%08x", refP);
		snprintf(out, sizeof out, "%s/svimg-%d.txt", getenv("TMPDIR") ?: "/tmp", (int)getpid());
		char *cargv[] = { argv[0], "child", a1, a2, out, NULL };
		pid_t pid = 0; int st = 0;
		const int r = posix_spawn(&pid, argv[0], NULL, NULL, cargv, environ);
		CHECK(r == 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 0, "child process (import, read P, render Q): status %d", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
		uint32_t refQ = 0; FILE *f = fopen(out, "r"); if (f) { if (fscanf(f, "%x", &refQ) != 1) refQ = 0; fclose(f); } unlink(out);
		// 4
		const uint32_t gotQ = readback(t);
		CHECK(refQ && gotQ == refQ, "parent: its texture shows the child's pattern Q (%08x, expected %08x)", gotQ, refQ);
		t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		const uint32_t pq = pages(s);
		CHECK(refQ && pq == refQ, "parent: CPU lock sees Q in the pages (%08x; lock + hash %.2f ms)", pq, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
		// 5
		IOSurfaceLock(s, 0, NULL); uint32_t *px = IOSurfaceGetBaseAddress(s);
		for (uint32_t i = 0; i < (uint32_t)W * H; i++) px[i] = (i * 2654435761u) ^ 0x5a5a5a5au;
		const uint32_t refW = fnv(px, (size_t)ROW * H);
		IOSurfaceUnlock(s, 0, NULL);
		const uint32_t gotW = readback(t);
		CHECK(gotW == refW, "parent: CPU-written pattern W reaches the GPU (%08x, expected %08x)", gotW, refW);
		// 6: hand-over at submission: a long render (pattern R) into the surface, only waitUntilScheduled, then another
		// process reads it at once
		{
			id<MTLTexture> refR = privTex(); draw(refR, 400);
			const uint32_t hR = readback(refR);
			id<MTLCommandBuffer> c = [q commandBuffer];
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:rp];
			uint32_t n = 400; [e setRenderPipelineState:ps]; [e setFragmentBytes:&n length:4 atIndex:0];
			[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
			const uint64_t c0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			[c commit]; [c waitUntilScheduled];
			const double schedMs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c0) / 1e6;
			char *rargv[] = { argv[0], "readnow", a1, out, NULL };
			pid_t p2 = 0; int st2 = 0;
			const int r2 = posix_spawn(&p2, argv[0], NULL, NULL, rargv, environ);
			uint32_t gotR = 0;
			if (!r2 && waitpid(p2, &st2, 0) == p2) { FILE *g = fopen(out, "r"); if (g) { if (fscanf(g, "%x", &gotR) != 1) gotR = 0; fclose(g); } unlink(out); }
			[c waitUntilCompleted];
			CHECK(gotR == hR, "hand-over at submission: another process reads the full long render (%08x, expected %08x; waitUntilScheduled took %.2f ms, GPU time %.2f ms)",
			      gotR, hR, schedMs, (c.GPUEndTime - c.GPUStartTime) * 1e3);
		}
		CFRelease(s);
		const struct svst st1 = svstats();
		if (st0.level >= 1) {
			const unsigned got = (st1.adopted - st0.adopted) + (st1.imports - st0.imports);
			CHECK(got >= 3, "VRAM path engaged: %u backings adopted, %u imports (expected >= 3 together)", st1.adopted - st0.adopted, st1.imports - st0.imports);
			CHECK(st1.dirty - st0.dirty >= 2, "GPU writes marked newest: %u SURFACE_DIRTY", st1.dirty - st0.dirty);
			CHECK(st1.pageoffs - st0.pageoffs >= 2, "CPU locks paged off: %u", st1.pageoffs - st0.pageoffs);
		} else printf("INFO debug.intelxe.surfvram is %d: the copy path was tested, not the VRAM path\n", st0.level);
		printf("%s: %d failure(s)\n", fails ? "FAILED" : "PASSED", fails);
		return fails != 0;
	}
}
