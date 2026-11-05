// SPDX-License-Identifier: MIT
// gpt_bench: a synthetic frame loop with known GPU work, to validate GPUTIME (/tmp/nvmtl-gputime) and to time fixes.
// Run on the hackintosh (game closed): NVMTL_ENABLE=1 NVMTL_BUNDLE=<staged>/NVMTLDriver.bundle ./gpt_bench [secs] [iters] [mode]
//   mode "gt": GPUTIME off for the first half, on for the second half (overhead + the GPUTIME lines in $TMPDIR/nvmtl.log)
//   mode "off": never on. Frame: CB1 = pass A 2560x1440 BGRA8 + D32F (fullscreen triangle, fragment loop of `iters`),
//   pass B 1280x720 RGBA16F sampling A (light); CB2 = blit A -> shared buffer (14.75 MB to system memory) + a compute
//   dispatch over 4M floats. The frame ends at CB2's completion (waitUntilCompleted), then nvmtl_hitch_frame("present").
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <IOSurface/IOSurface.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const kSrc = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V vtri(uint id [[vertex_id]]) { V o; float2 q = float2((id << 1) & 2, id & 2); o.p = float4(q * 2.0 - 1.0, 0.5, 1); o.uv = q; return o; }\n"
"fragment float4 fheavy(V i [[stage_in]], constant uint &n [[buffer(0)]]) {\n"
"  float2 z = i.uv; float a = 0;\n"
"  for (uint k = 0; k < n; k++) { z = float2(z.x * z.x - z.y * z.y, 2 * z.x * z.y) * 0.5 + i.uv; a += fract(z.x * 3.1 + z.y); }\n"
"  return float4(fract(a), z.x, z.y, 1); }\n"
"fragment half4 flight(V i [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return half4(t.sample(s, i.uv)); }\n"
"kernel void kadd(device float *a [[buffer(0)]], uint id [[thread_position_in_grid]]) { a[id] = a[id] * 1.0001f + 1.0f; }\n";

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

int main(int argc, char **argv) {
	@autoreleasepool {
		const double secs = argc > 1 ? atof(argv[1]) : 8; const uint32_t iters = argc > 2 ? (uint32_t)atoi(argv[2]) : 64;
		const char *mode = argc > 3 ? argv[3] : "gt";
		const char *bp = getenv("NVMTL_BUNDLE"); id<MTLDevice> d = nil;
		if (bp) d = bundleDevice(bp); else for (id<MTLDevice> x in MTLCopyAllDevices()) if ([NSStringFromClass([x class]) isEqualToString:@"NVMTLDevice"]) d = x;
		if (!d) { printf("no B580 device\n"); return 2; }
		void (*frame)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "nvmtl_hitch_frame");
		if (!frame && bp) { char ex[1024]; snprintf(ex, sizeof ex, "%s/Contents/MacOS/NVMTLDriver", bp); void *h = dlopen(ex, RTLD_NOLOAD | RTLD_LAZY);
			if (h) frame = (void (*)(const char *))dlsym(h, "nvmtl_hitch_frame"); }
		printf("device %s, frame hook %s, %.0f s, iters %u, mode %s\n", d.name.UTF8String, frame ? "found" : "MISSING", secs, iters, mode);
		NSError *e = nil; id<MTLLibrary> lib = [d newLibraryWithSource:kSrc options:nil error:&e];
		if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 1; }
		MTLRenderPipelineDescriptor *pa = [MTLRenderPipelineDescriptor new];
		pa.vertexFunction = [lib newFunctionWithName:@"vtri"]; pa.fragmentFunction = [lib newFunctionWithName:@"fheavy"];
		pa.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; pa.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		id<MTLRenderPipelineState> psa = [d newRenderPipelineStateWithDescriptor:pa error:&e]; if (!psa) { printf("pso A: %s\n", e.localizedDescription.UTF8String); return 1; }
		MTLRenderPipelineDescriptor *pb = [MTLRenderPipelineDescriptor new];
		pb.vertexFunction = pa.vertexFunction; pb.fragmentFunction = [lib newFunctionWithName:@"flight"];
		pb.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
		id<MTLRenderPipelineState> psb = [d newRenderPipelineStateWithDescriptor:pb error:&e]; if (!psb) { printf("pso B: %s\n", e.localizedDescription.UTF8String); return 1; }
		id<MTLComputePipelineState> cps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kadd"] error:&e];
		if (!cps) { printf("cps: %s\n", e.localizedDescription.UTF8String); return 1; }
		MTLTextureDescriptor *ta = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2560 height:1440 mipmapped:NO];
		ta.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; ta.storageMode = MTLStorageModePrivate;
		id<MTLTexture> A = [d newTextureWithDescriptor:ta];
		MTLTextureDescriptor *tz = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:2560 height:1440 mipmapped:NO];
		tz.usage = MTLTextureUsageRenderTarget; tz.storageMode = MTLStorageModePrivate;
		id<MTLTexture> Z = [d newTextureWithDescriptor:tz];
		MTLTextureDescriptor *tb = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1280 height:720 mipmapped:NO];
		tb.usage = MTLTextureUsageRenderTarget; tb.storageMode = MTLStorageModePrivate;
		id<MTLTexture> B = [d newTextureWithDescriptor:tb];
		id<MTLBuffer> rb = [d newBufferWithLength:2560 * 1440 * 4 options:MTLResourceStorageModeShared];
		id<MTLBuffer> cb = [d newBufferWithLength:4u << 22 options:MTLResourceStorageModePrivate];
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
		id<MTLSamplerState> smp = [d newSamplerStateWithDescriptor:sd];
		id<MTLCommandQueue> q = [d newCommandQueue];
		if (!strcmp(mode, "surf")) {   // IOSurface out/in correctness + timing (the staged host copies)
			NSDictionary *sp = @{ (id)kIOSurfaceWidth: @2560, (id)kIOSurfaceHeight: @1440, (id)kIOSurfaceBytesPerElement: @4,
			                      (id)kIOSurfaceBytesPerRow: @(10240), (id)kIOSurfacePixelFormat: @(0x42475241) };
			IOSurfaceRef sf = IOSurfaceCreate((__bridge CFDictionaryRef)sp); if (!sf) { printf("no IOSurface\n"); return 1; }
			MTLTextureDescriptor *sd2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2560 height:1440 mipmapped:NO];
			sd2.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; sd2.storageMode = MTLStorageModeShared;
			id<MTLTexture> ST = [d newTextureWithDescriptor:sd2 iosurface:sf plane:0];
			if (!ST) { printf("no IOSurface texture\n"); return 1; }
			int bad = 0; double tout = 0, tin = 0; int nout = 0, nin = 0;
			for (int it = 0; it < 6; it++) { @autoreleasepool {
				const uint32_t k = it == 0 ? 64 : 64 + it * 7;
				// out: render into the IOSurface texture and into A (private), read both, compare
				for (int pass = 0; pass < 2; pass++) {
					id<MTLCommandBuffer> c = [q commandBuffer];
					MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
					r.colorAttachments[0].texture = pass ? A : ST; r.colorAttachments[0].loadAction = MTLLoadActionClear; r.colorAttachments[0].storeAction = MTLStoreActionStore;
					r.depthAttachment.texture = Z; r.depthAttachment.loadAction = MTLLoadActionClear; r.depthAttachment.storeAction = MTLStoreActionDontCare;
					id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:r];
					[e setRenderPipelineState:psa]; [e setFragmentBytes:&k length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
					if (pass) { id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
						[bl copyFromTexture:A sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(2560, 1440, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:10240 destinationBytesPerImage:10240 * 1440]; [bl endEncoding]; }
					[c commit]; [c waitUntilCompleted];
					if (!pass) { tout += c.GPUEndTime - c.GPUStartTime; nout++; }
				}
				IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
				if (memcmp(IOSurfaceGetBaseAddress(sf), rb.contents, 10240 * 1440)) { bad++; printf("OUT MISMATCH at iteration %d\n", it); }
				IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
				// in: CPU writes a pattern into the IOSurface, the GPU copies the texture to rb, compare
				IOSurfaceLock(sf, 0, NULL); uint32_t *px = IOSurfaceGetBaseAddress(sf);
				for (uint32_t i = 0; i < 2560u * 1440u; i++) px[i] = (i * 2654435761u) ^ (uint32_t)(it * 0x01010101u);
				IOSurfaceUnlock(sf, 0, NULL);
				id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
				[bl copyFromTexture:ST sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(2560, 1440, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:10240 destinationBytesPerImage:10240 * 1440];
				[bl endEncoding]; [c commit]; [c waitUntilCompleted];
				IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
				if (memcmp(IOSurfaceGetBaseAddress(sf), rb.contents, 10240 * 1440)) { bad++; printf("IN MISMATCH at iteration %d\n", it); }
				IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
				nin++; (void)tin;
			} }
			uint32_t h = 2166136261u; IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL); const uint8_t *pb = IOSurfaceGetBaseAddress(sf);
			for (size_t i = 0; i < 10240u * 1440u; i++) { h ^= pb[i]; h *= 16777619u; } IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
			printf("surf: %d iterations, %d mismatches, render+surface-out cb %.3f ms GPU avg, final pages fnv %08x\n", nout, bad, tout * 1e3 / nout, h);
			CFRelease(sf); return bad ? 1 : 0;
		}
		if (!strncmp(mode, "xfer", 4)) {
			id<MTLBuffer> vb = [d newBufferWithLength:2560 * 1440 * 4 options:MTLResourceStorageModePrivate];
			id<MTLBuffer> mb = [d newBufferWithLength:2560 * 1440 * 4 options:MTLResourceStorageModeManaged];
			MTLTextureDescriptor *tc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2560 height:1440 mipmapped:NO];
			tc.usage = MTLTextureUsageShaderRead; tc.storageMode = MTLStorageModePrivate;
			id<MTLTexture> C = [d newTextureWithDescriptor:tc];
			if (!strcmp(mode, "xfer2")) {   // two-step copies through a linear VRAM buffer, one command buffer each
				double t2[2] = {0, 0}; int n2 = 0; const double y0 = CFAbsoluteTimeGetCurrent();
				while (CFAbsoluteTimeGetCurrent() - y0 < secs) { @autoreleasepool {
					MTLOrigin o = MTLOriginMake(0, 0, 0); MTLSize sz = MTLSizeMake(2560, 1440, 1);
					id<MTLCommandBuffer> a1 = [q commandBuffer]; id<MTLBlitCommandEncoder> b1 = [a1 blitCommandEncoder];
					[b1 copyFromTexture:A sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:sz toBuffer:vb destinationOffset:0 destinationBytesPerRow:10240 destinationBytesPerImage:10240 * 1440];
					[b1 copyFromBuffer:vb sourceOffset:0 toBuffer:rb destinationOffset:0 size:10240 * 1440]; [b1 endEncoding]; [a1 commit];
					id<MTLCommandBuffer> a2 = [q commandBuffer]; id<MTLBlitCommandEncoder> b2 = [a2 blitCommandEncoder];
					[b2 copyFromBuffer:rb sourceOffset:0 toBuffer:vb destinationOffset:0 size:10240 * 1440];
					[b2 copyFromBuffer:vb sourceOffset:0 sourceBytesPerRow:10240 sourceBytesPerImage:10240 * 1440 sourceSize:sz toTexture:C destinationSlice:0 destinationLevel:0 destinationOrigin:o];
					[b2 endEncoding]; [a2 commit]; [a2 waitUntilCompleted];
					t2[0] += a1.GPUEndTime - a1.GPUStartTime; t2[1] += a2.GPUEndTime - a2.GPUStartTime; n2++; if (frame) frame("present"); } }
				printf("xfer2 tex->VRAM buf->sysmem buf   %.3f ms GPU\nxfer2 sysmem buf->VRAM buf->tex   %.3f ms GPU\n", t2[0] * 1e3 / n2, t2[1] * 1e3 / n2);
				return 0;
			}
			const char *nm[6] = { "tex->shared buf (VRAM->sysmem)", "tex->private buf (VRAM->VRAM)", "shared buf->tex (sysmem->VRAM)", "private buf->tex (VRAM->VRAM)", "tex->tex copy", "shared->private buf" };
			double tot[6] = {0}; int n = 0;
			const double x0 = CFAbsoluteTimeGetCurrent();
			while (CFAbsoluteTimeGetCurrent() - x0 < secs) {
				@autoreleasepool {
					id<MTLCommandBuffer> cbs[6];
					for (int k = 0; k < 6; k++) {
						cbs[k] = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cbs[k] blitCommandEncoder];
						MTLOrigin o = MTLOriginMake(0, 0, 0); MTLSize sz = MTLSizeMake(2560, 1440, 1);
						switch (k) {
						case 0: [bl copyFromTexture:A sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:sz toBuffer:rb destinationOffset:0 destinationBytesPerRow:10240 destinationBytesPerImage:10240 * 1440]; break;
						case 1: [bl copyFromTexture:A sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:sz toBuffer:vb destinationOffset:0 destinationBytesPerRow:10240 destinationBytesPerImage:10240 * 1440]; break;
						case 2: [bl copyFromBuffer:rb sourceOffset:0 sourceBytesPerRow:10240 sourceBytesPerImage:10240 * 1440 sourceSize:sz toTexture:C destinationSlice:0 destinationLevel:0 destinationOrigin:o]; break;
						case 3: [bl copyFromBuffer:vb sourceOffset:0 sourceBytesPerRow:10240 sourceBytesPerImage:10240 * 1440 sourceSize:sz toTexture:C destinationSlice:0 destinationLevel:0 destinationOrigin:o]; break;
						case 4: [bl copyFromTexture:A toTexture:C]; break;
						case 5: [bl copyFromBuffer:rb sourceOffset:0 toBuffer:vb destinationOffset:0 size:10240 * 1440]; break;
						}
						[bl endEncoding]; [cbs[k] commit];
					}
					[cbs[5] waitUntilCompleted];
					for (int k = 0; k < 6; k++) tot[k] += cbs[k].GPUEndTime - cbs[k].GPUStartTime;
					n++; if (frame) frame("present");
				}
			}
			for (int k = 0; k < 6; k++) printf("xfer %-34s %.3f ms GPU, %.1f GB/s\n", nm[k], tot[k] * 1e3 / n, 14.7456e-3 / (tot[k] / n));
			(void)mb; return 0;
		}
		unlink("/tmp/nvmtl-gputime");
		const double t0 = CFAbsoluteTimeGetCurrent(); int on = 0; unsigned frames[2] = {0, 0}; double gpu[2][2] = {{0, 0}, {0, 0}}, wall[2] = {0, 0};
		double tl = t0;
		for (;;) {
			const double now = CFAbsoluteTimeGetCurrent(); if (now - t0 >= secs) break;
			if (!on && !strcmp(mode, "gt") && now - t0 >= secs / 2) { int fd = open("/tmp/nvmtl-gputime", O_CREAT | O_WRONLY, 0644); if (fd >= 0) close(fd); on = 1; usleep(300000); tl = CFAbsoluteTimeGetCurrent(); continue; }
			@autoreleasepool {
				id<MTLCommandBuffer> c1 = [q commandBuffer];
				MTLRenderPassDescriptor *ra = [MTLRenderPassDescriptor renderPassDescriptor];
				ra.colorAttachments[0].texture = A; ra.colorAttachments[0].loadAction = MTLLoadActionClear; ra.colorAttachments[0].storeAction = MTLStoreActionStore;
				ra.depthAttachment.texture = Z; ra.depthAttachment.loadAction = MTLLoadActionClear; ra.depthAttachment.storeAction = MTLStoreActionDontCare;
				id<MTLRenderCommandEncoder> ea = [c1 renderCommandEncoderWithDescriptor:ra];
				[ea setRenderPipelineState:psa]; [ea setFragmentBytes:&iters length:4 atIndex:0];
				[ea drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [ea endEncoding];
				MTLRenderPassDescriptor *rbd = [MTLRenderPassDescriptor renderPassDescriptor];
				rbd.colorAttachments[0].texture = B; rbd.colorAttachments[0].loadAction = MTLLoadActionDontCare; rbd.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> eb = [c1 renderCommandEncoderWithDescriptor:rbd];
				[eb setRenderPipelineState:psb]; [eb setFragmentTexture:A atIndex:0]; [eb setFragmentSamplerState:smp atIndex:0];
				[eb drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [eb endEncoding];
				[c1 commit];
				id<MTLCommandBuffer> c2 = [q commandBuffer];
				id<MTLBlitCommandEncoder> bl = [c2 blitCommandEncoder];
				[bl copyFromTexture:A sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(2560, 1440, 1)
				          toBuffer:rb destinationOffset:0 destinationBytesPerRow:2560 * 4 destinationBytesPerImage:2560 * 1440 * 4];
				[bl endEncoding];
				id<MTLComputeCommandEncoder> ce = [c2 computeCommandEncoder];
				[ce setComputePipelineState:cps]; [ce setBuffer:cb offset:0 atIndex:0];
				[ce dispatchThreads:MTLSizeMake(4u << 20, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [ce endEncoding];
				[c2 commit]; [c2 waitUntilCompleted];
				if (c1.status != MTLCommandBufferStatusCompleted || c2.status != MTLCommandBufferStatusCompleted) { printf("command buffer failed\n"); return 1; }
				gpu[on][0] += c1.GPUEndTime - c1.GPUStartTime; gpu[on][1] += c2.GPUEndTime - c2.GPUStartTime; frames[on]++;
				if (frame) frame("present");
			}
			wall[on] = CFAbsoluteTimeGetCurrent() - (on ? tl : t0);
		}
		unlink("/tmp/nvmtl-gputime");
		for (int k = 0; k < 2; k++) if (frames[k])
			printf("GPUTIME %s: %u frames, %.1f fps, Metal GPU time per frame: cb1 (passes A+B) %.3f ms, cb2 (blit+compute) %.3f ms\n", k ? "ON " : "off",
			       frames[k], frames[k] / wall[k], gpu[k][0] * 1e3 / frames[k], gpu[k][1] * 1e3 / frames[k]);
		uint32_t px = 0; memcpy(&px, (char *)rb.contents + (720 * 2560 + 1280) * 4, 4);
		printf("centre pixel 0x%08x\n", px);
		return 0;
	}
}
