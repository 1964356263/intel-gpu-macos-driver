// SPDX-License-Identifier: MIT
// mtl_pools: the Metal plugin's descriptor pools - what they cost in the BAR window, growth, the full-pools path.
// Build on the build Mac:
//   clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O1 -o mtl_pools mtl_pools.m -framework Foundation -framework Metal -framework IOKit
// Run on the hackintosh (NVMTL_BUNDLE=<dir>/NVMTLDriver.bundle loads that plugin build into this process only):
//   mtl_pools cost      one dispatch, then this process's line of debug.intelxe.vram (window MB: ANV + the plugin's pools)
//   mtl_pools grow N    one command buffer of N dispatches, each with a new descriptor set (the bound texture alternates);
//                       every dispatch must have run (each writes its own slot)
//   mtl_pools cap N     the same, expecting the pools to run out (NVMTL_DESC_POOLS_MAX=1 or 2): the command buffer must
//                       end with MTLCommandBufferErrorOutOfMemory and none of it may have run (no slot written)
//   mtl_pools reclaim K N   K command buffers of N dispatches committed back to back: the later ones need the sets the
//                       earlier ones hold until they finish (fix30 waits for them); all must complete with every slot
// Each dispatch: out[k] = texture[k % 2].read(0, 0) (1111 or 2222), slot k of a buffer that starts zeroed.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString *const kSrc = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void put(device uint *out [[buffer(0)]], texture2d<uint, access::read> t [[texture(0)]]) { out[0] = t.read(uint2(0, 0)).x; }
kernel void tbuf(device uint *out [[buffer(0)]], texture_buffer<uint, access::read> tb [[texture(0)]],
                 texture2d<uint, access::write> st [[texture(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = tb.read(i).x * 3u; st.write(uint4(tb.read(i).x + 7u), uint2(i, 0)); }
)";

static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)];
	NSError *e = nil;
	if (![b loadAndReturnError:&e]) { printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String); return nil; }
	Class cls = [b classNamed:@"NVMTLDevice"];
	if (!cls) return nil;
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

static void myWindow(const char *what) {
	char *buf = malloc(65536);
	char key[32];
	snprintf(key, sizeof key, "pid %d ", getpid());
	for (int tries = 0;; tries++) {   // a connection whose lock is held right then shows as "busy": ask again
		size_t l = 65536;
		if (sysctlbyname("debug.intelxe.vram", buf, &l, NULL, 0)) { printf("%s: no debug.intelxe.vram (kernel before pv)\n", what); free(buf); return; }
		char *p = strstr(buf, key);
		int busy = 0;
		for (; p; p = strstr(p + 1, key)) { char *e = strchr(p, '\n'); if (e && strstr(p, ": busy") && strstr(p, ": busy") < e) busy = 1; }
		if (!busy || tries >= 200) break;
		usleep(5000);
	}
	for (char *p = buf; (p = strstr(p, key)); p++) {   // one line per connection; ANV opens one per VkDevice
		char *e = strchr(p, '\n');
		if (e) *e = 0;
		printf("%s: %s\n", what, p);
		if (e) *e = '\n';
	}
	free(buf);
}

static id<MTLDevice> dev;
static id<MTLCommandQueue> q;
static id<MTLComputePipelineState> ps;
static id<MTLTexture> tex[2];

static id<MTLCommandBuffer> encode(id<MTLBuffer> out, uint32_t n) {
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:ps];
	for (uint32_t k = 0; k < n; k++) {
		[ce setBuffer:out offset:k * 4 atIndex:0];
		[ce setTexture:tex[k & 1] atIndex:0];
		[ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
	}
	[ce endEncoding];
	return cb;
}
static uint32_t check(id<MTLBuffer> out, uint32_t n, uint32_t *zero) {
	const uint32_t *p = out.contents;
	uint32_t bad = 0, z = 0;
	for (uint32_t k = 0; k < n; k++) {
		if (!p[k]) z++;
		if (p[k] != ((k & 1) ? 2222u : 1111u)) bad++;
	}
	*zero = z;
	return bad;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		setvbuf(stdout, NULL, _IONBF, 0);
		const char *mode = argc > 1 ? argv[1] : "cost";
		const char *bundle = getenv("NVMTL_BUNDLE");
		dev = bundle ? bundleDevice(bundle) : nil;
		if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
		if (!dev) { printf("no NVMTLDevice\n"); return 2; }
		printf("device %s (%s), pid %d\n", dev.name.UTF8String, bundle ? bundle : "installed plugin", getpid());
		q = [dev newCommandQueue];
		NSError *e = nil;
		id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&e];
		ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"put"] error:&e] : nil;
		if (!ps) { printf("FAIL: pipeline: %s\n", e.localizedDescription.UTF8String); return 1; }
		for (int i = 0; i < 2; i++) {
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
			td.usage = MTLTextureUsageShaderRead;
			tex[i] = [dev newTextureWithDescriptor:td];
			uint32_t v[16];
			for (int k = 0; k < 16; k++) v[k] = i ? 2222u : 1111u;
			[tex[i] replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:v bytesPerRow:16];
		}
		int fails = 0;
		if (!strcmp(mode, "cost")) {
			id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			memset(out.contents, 0, 4096);
			id<MTLCommandBuffer> cb = encode(out, 1);
			[cb commit]; [cb waitUntilCompleted];
			uint32_t z; fails += check(out, 1, &z) != 0;
			myWindow("after one dispatch");
		} else if (!strcmp(mode, "grow") || !strcmp(mode, "cap")) {
			const uint32_t n = argc > 2 ? (uint32_t)atoi(argv[2]) : 3000;
			id<MTLBuffer> out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
			memset(out.contents, 0, n * 4);
			NSDate *t0 = [NSDate date];
			id<MTLCommandBuffer> cb = encode(out, n);
			[cb commit]; [cb waitUntilCompleted];
			uint32_t z, bad = check(out, n, &z);
			printf("%u dispatches in one command buffer: status %ld, error %ld (%s), %u slots wrong (%u never written), %.0f ms\n", n,
				(long)cb.status, (long)cb.error.code, cb.error.localizedDescription.UTF8String ?: "-", bad, z, -[t0 timeIntervalSinceNow] * 1000);
			if (!strcmp(mode, "grow")) {
				if (cb.status != MTLCommandBufferStatusCompleted || bad) { printf("FAIL: not every dispatch ran\n"); fails++; }
			} else {
				if (cb.status != MTLCommandBufferStatusError || cb.error.code != MTLCommandBufferErrorOutOfMemory) { printf("FAIL: expected MTLCommandBufferErrorOutOfMemory\n"); fails++; }
				if (z != n) { printf("FAIL: %u dispatches of an errored command buffer ran (partial execution)\n", n - z); fails++; }
			}
			myWindow("after");
		} else if (!strcmp(mode, "reclaim")) {
			const uint32_t k = argc > 2 ? (uint32_t)atoi(argv[2]) : 8, n = argc > 3 ? (uint32_t)atoi(argv[3]) : 300;
			NSMutableArray *outs = [NSMutableArray new], *cbs = [NSMutableArray new];
			NSDate *t0 = [NSDate date];
			for (uint32_t i = 0; i < k; i++) {
				id<MTLBuffer> out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
				memset(out.contents, 0, n * 4);
				id<MTLCommandBuffer> cb = encode(out, n);
				[cb commit];
				[outs addObject:out]; [cbs addObject:cb];
			}
			for (id<MTLCommandBuffer> cb in cbs) [cb waitUntilCompleted];
			uint32_t badCb = 0;
			for (uint32_t i = 0; i < k; i++) {
				id<MTLCommandBuffer> cb = cbs[i];
				uint32_t z, bad = check(outs[i], n, &z);
				if (cb.status != MTLCommandBufferStatusCompleted || bad) {
					badCb++;
					printf("  command buffer %u: status %ld error %ld, %u slots wrong\n", i, (long)cb.status, (long)cb.error.code, bad);
				}
			}
			printf("%u command buffers x %u dispatches back to back: %u not complete or wrong, %.0f ms\n", k, n, badCb, -[t0 timeIntervalSinceNow] * 1000);
			fails += badCb != 0;
			myWindow("after");
		} else if (!strcmp(mode, "texbuf")) {   // a texel buffer (mutable sampled binding) and a storage texture (480+ band)
			id<MTLComputePipelineState> tp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tbuf"] error:&e];
			if (!tp) { printf("FAIL: tbuf pipeline: %s\n", e.localizedDescription.UTF8String); return 1; }
			const uint32_t n = 256;
			id<MTLBuffer> src = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared], out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
			for (uint32_t k = 0; k < n; k++) ((uint32_t *)src.contents)[k] = k + 100;
			memset(out.contents, 0, n * 4);
			MTLTextureDescriptor *bd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:n resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
			id<MTLTexture> tb = [src newTextureWithDescriptor:bd offset:0 bytesPerRow:n * 4];
			MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:n height:1 mipmapped:NO];
			sd.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead; sd.storageMode = MTLStorageModeShared;
			id<MTLTexture> st = [dev newTextureWithDescriptor:sd];
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
			[ce setComputePipelineState:tp]; [ce setBuffer:out offset:0 atIndex:0]; [ce setTexture:tb atIndex:0]; [ce setTexture:st atIndex:1];
			[ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
			[ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
			uint32_t got[256], bad = 0, bad2 = 0;
			[st getBytes:got bytesPerRow:n * 4 fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
			for (uint32_t k = 0; k < n; k++) { if (((uint32_t *)out.contents)[k] != (k + 100) * 3) bad++; if (got[k] != k + 107) bad2++; }
			printf("texel buffer read: %u wrong; storage texture write: %u wrong (status %ld)\n", bad, bad2, (long)cb.status);
			fails += bad || bad2 || cb.status != MTLCommandBufferStatusCompleted;
		} else {
			printf("usage: mtl_pools cost | grow N | cap N | reclaim K N | texbuf\n");
			return 2;
		}
		printf("%s\n", fails ? "FAILED" : "PASSED");
		return fails != 0;
	}
}
