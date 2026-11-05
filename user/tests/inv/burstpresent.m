// SPDX-License-Identifier: MIT
// burstpresent: a game's swapchain under irregular present timing, against a reader in another process (WindowServer's
// role). A pool of IOSurfaces is reused as soon as the reader hands one back (race A: seed/reuse); each frame writes its
// surface in two parts (a render-pass clear of the whole surface, an event signal that seals the part, then a copy into
// the bottom half), so a frame's surface-out spans two submission parts. Frames are committed in bursts of 1-8
// back-to-back with random gaps of 0-25 ms between bursts, sometimes from a second queue, some with
// commitAndWaitUntilSubmitted (SkyLight's capture shape). At completion the surface goes to the reader process, which
// locks it and checks every row: top half = frame k's colour, bottom half = its second colour. A row from another frame
// is a stale or reused surface-out. In "race" mode (with NVMTL_CAPTURE_WAIT=1) the reader also gets every 4th frame
// right after commitAndWaitUntilSubmitted, before completion, as a capture does.
// "gpu": the reader samples the surface with its own GPU (a texture over the IOSurface, blitted to a buffer: the plugin's
// surface-in, as WindowServer composites a game's frame) instead of locking it. "sched": the surface goes to the reader
// when the writer's command buffer is scheduled, not completed: CoreAnimation and Apple's GL hand a surface to
// WindowServer after waitUntilScheduled and rely on the driver to order the reader's GPU work after the writer's. The slot
// is reused once the reader is done and the writer has completed.
//   NVMTL_BUNDLE=<bundle> NVMTL_ENABLE=1 ./burstpresent [frames N] [pool P] [race] [gpu] [sched] [seed S]
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <unistd.h>
#include <sys/wait.h>
#include <stdatomic.h>

static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)];
	NSError *e = nil;
	if (![b loadAndReturnError:&e]) { printf("bundle: %s\n", e.localizedDescription.UTF8String); return nil; }
	Class cls = [b classNamed:@"NVMTLDevice"];
	io_iterator_t it = 0;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice")))
			dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name);
	}
	return dev;
}

// BGRA in memory, A = ff; frame k's two colours differ from every other frame's in the low 24 bits
static uint32_t top_col(uint32_t k) { return 0xff000000u | ((k * 2654435761u) & 0xffffffu) | 1u; }
static uint32_t bot_col(uint32_t k) { return 0xff000000u | ((k * 2246822519u + 0x5a5a5au) & 0xffffffu) | 2u; }

typedef struct { uint32_t sid, frame, slot, capture; } msg_t;   // capture: read before completion (race mode)
typedef struct { uint32_t slot, bad, frame; } ack_t;

// the reader: locks the surface read-only, checks first/middle/last pixel of every row
static id<MTLDevice> bundleDevice(const char *path);
static int reader(int in, int out, int w, int h, int gpu, int war) {
	msg_t m; int fails = 0, n = 0;
	NSMutableDictionary *surfs = [NSMutableDictionary new], *texs = [NSMutableDictionary new];
	id<MTLDevice> dev = nil; id<MTLCommandQueue> q = nil; id<MTLBuffer> out_buf = nil; id<MTLComputePipelineState> pso = nil;
	if (gpu) {
		const char *bp = getenv("NVMTL_BUNDLE");
		dev = bp ? bundleDevice(bp) : nil;
		if (!dev) { printf("  reader: no device\n"); return 2; }
		q = [dev newCommandQueue]; out_buf = [dev newBufferWithLength:(size_t)w * 4 * h options:MTLResourceStorageModeShared];
		// a shader samples the surface (as a compositor's draw does), so nothing on the reader's side forces its upload
		// of the surface to land early (a blit readback would)
		NSError *e = nil;
		id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
			"kernel void rd(texture2d<float, access::read> t [[texture(0)]], device uint *o [[buffer(0)]], constant uint &w [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
			"  if (g.x >= t.get_width() || g.y >= t.get_height()) return;\n"
			"  float4 c = t.read(g); o[g.y * w + g.x] = pack_float_to_unorm4x8(float4(c.b, c.g, c.r, c.a)); }\n" options:nil error:&e];
		pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&e] : nil;
		if (!pso) { fprintf(stderr, "  reader: no compute pipeline: %s\n", e.localizedDescription.UTF8String); return 2; }
	}
	while (read(in, &m, sizeof m) == sizeof m) @autoreleasepool {
		IOSurfaceRef s = (__bridge IOSurfaceRef)surfs[@(m.sid)];
		if (!s) { s = IOSurfaceLookup(m.sid); if (!s) { printf("  reader: no surface %u\n", m.sid); return 2; } surfs[@(m.sid)] = CFBridgingRelease(s); }
		const uint8_t *b; size_t row;
		if (gpu) {   // a texture over the surface, copied out on the GPU: what the reader's compositor would sample
			id<MTLTexture> t = texs[@(m.sid)];
			if (!t) {
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
				td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
				texs[@(m.sid)] = t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
			}
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
			const uint32_t wu = (uint32_t)w;
			[ce setComputePipelineState:pso]; [ce setTexture:t atIndex:0]; [ce setBuffer:out_buf offset:0 atIndex:0]; [ce setBytes:&wu length:4 atIndex:1];
			[ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
			[ce endEncoding]; [cb commit];
			if (war && !m.capture) {   // hand the surface back as soon as the read is submitted: the writer may reuse it now
				ack_t a = { m.slot, 0, m.frame };
				if (write(out, &a, sizeof a) != sizeof a) return 2;
			}
			[cb waitUntilCompleted];
			b = out_buf.contents; row = (size_t)w * 4;
		} else {
			IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
			b = IOSurfaceGetBaseAddress(s); row = IOSurfaceGetBytesPerRow(s);
		}
		const uint32_t t = top_col(m.frame), z = bot_col(m.frame);
		int bad = 0, first = -1; uint32_t seen = 0;
		for (int y = 0; y < h; y++) {
			const uint32_t want = y < h / 2 ? t : z;
			const uint32_t *r = (const uint32_t *)(b + y * row);
			if (r[0] != want || r[w / 2] != want || r[w - 1] != want) { if (first < 0) { first = y; seen = r[w / 2]; } bad++; }
		}
		if (!gpu) IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		if (bad) {
			fails++;
			if (fails <= 12) printf("  reader: frame %u (surface %u, %s): %d rows wrong, first row %d holds %08x (want %08x)\n", m.frame, m.sid,
			                        m.capture ? "captured after submit" : m.capture == 0 && getenv("BP_SCHED") ? "at scheduled" : "at completion", bad, first, seen, first < h / 2 ? t : z);
		}
		n++;
		ack_t a = { m.slot, (uint32_t)bad, m.frame };
		if (!m.capture && !(gpu && war) && write(out, &a, sizeof a) != sizeof a) return 2;
	}
	printf("  reader: %d frames read, %d wrong\n", n, fails);
	return fails ? 1 : 0;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc == 8 && !strcmp(argv[1], "reader")) {
			const int r = reader(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), atoi(argv[6]), atoi(argv[7]));
			fflush(stdout); return r;
		}
		int frames = 600, pool = 3, race = 0, gpu = 0, sched = 0, war = 0, w = 1920, h = 1080; unsigned seed = (unsigned)time(NULL);
		for (int a = 1; a < argc; a++) {
			if (!strcmp(argv[a], "race")) race = 1;
			if (!strcmp(argv[a], "gpu")) gpu = 1;
			if (!strcmp(argv[a], "war")) war = 1;   // with gpu: the reader returns the surface once its GPU read is submitted
			if (!strcmp(argv[a], "sched")) { sched = 1; setenv("BP_SCHED", "1", 1); }
			if (!strcmp(argv[a], "frames") && a + 1 < argc) frames = atoi(argv[++a]);
			if (!strcmp(argv[a], "pool") && a + 1 < argc) pool = atoi(argv[++a]);
			if (!strcmp(argv[a], "seed") && a + 1 < argc) seed = (unsigned)strtoul(argv[++a], NULL, 0);
		}
		if (pool < 2 || pool > 32) pool = 3;
		int toR[2], fromR[2];
		if (pipe(toR) || pipe(fromR)) return 2;
		pid_t p = fork();
		if (!p) { close(toR[1]); close(fromR[0]); // a fresh process (exec): Metal's compiler service is not usable in a forked child
			char a0[16], a1[16], a2[16], a3[16], a4[16], a5[16];
			snprintf(a0, 16, "%d", toR[0]); snprintf(a1, 16, "%d", fromR[1]); snprintf(a2, 16, "%d", w); snprintf(a3, 16, "%d", h);
			snprintf(a4, 16, "%d", gpu); snprintf(a5, 16, "%d", war);
			execl(argv[0], argv[0], "reader", a0, a1, a2, a3, a4, a5, (char *)NULL); _exit(3); }
		close(toR[0]); close(fromR[1]);
		const char *bp = getenv("NVMTL_BUNDLE");
		id<MTLDevice> dev = nil;
		if (bp) dev = bundleDevice(bp);
		else for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
		if (!dev) { printf("no device\n"); return 2; }
		printf("device %s, %d frames, pool %d, %dx%d, seed %u%s%s%s\n", dev.name.UTF8String, frames, pool, w, h, seed, race ? ", race" : "",
		       gpu ? (war ? ", GPU reader returning surfaces at submit (WAR)" : ", GPU reader") : "", sched ? ", handed over at scheduled" : "");
		srandom(seed);
		id<MTLCommandQueue> q[2] = { [dev newCommandQueue], [dev newCommandQueue] };
		id<MTLSharedEvent> ev = [dev newSharedEvent]; uint64_t evv = 0;
		IOSurfaceRef surf[32]; id<MTLTexture> tex[32]; int busy[32] = { 0 }; static _Atomic int done[32];
		for (int i = 0; i < pool; i++) {
			surf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
				(id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
				(id)kIOSurfaceIsGlobal: @YES });
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
			tex[i] = [dev newTextureWithDescriptor:td iosurface:surf[i] plane:0];
		}
		// the completion handlers queue their slot here; the main thread sends it to the reader in completion order
		NSMutableArray *landed = [NSMutableArray new]; NSCondition *cv = [NSCondition new];
		__block _Atomic int inflight = 0; int sent = 0, acked = 0, captures = 0, waits = 0, wrong = 0;
		uint64_t gapSum = 0; const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		int f = 0;
		while (f < frames || acked < sent || atomic_load(&inflight) || ({ [cv lock]; const NSUInteger nl = landed.count; [cv unlock]; nl; })) @autoreleasepool {
			// hand landed frames to the reader, take its acks back
			[cv lock]; NSArray *ready = [landed copy]; [landed removeAllObjects]; [cv unlock];
			for (NSArray *e in ready) {
				msg_t m = { IOSurfaceGetID(surf[[e[0] intValue]]), [e[1] unsignedIntValue], [e[0] unsignedIntValue], 0 };
				if (write(toR[1], &m, sizeof m) != sizeof m) { printf("reader gone\n"); return 2; }
				sent++;
			}
			while (acked < sent) {
				fd_set rs; FD_ZERO(&rs); FD_SET(fromR[0], &rs); struct timeval tv = { 0, 0 };
				if (select(fromR[0] + 1, &rs, NULL, NULL, &tv) <= 0) break;
				ack_t a; if (read(fromR[0], &a, sizeof a) != sizeof a) { printf("reader gone\n"); return 2; }
				busy[a.slot] = 2; acked++; wrong += a.bad != 0;   // read; free once the writer has completed too
			}
			for (int i = 0; i < pool; i++) if (busy[i] == 2 && atomic_load(&done[i])) busy[i] = 0;
			if (f >= frames) { usleep(200); continue; }
			// a burst of 1-8 frames into whichever surfaces are free, then a gap of 0-25 ms (sometimes none)
			const int burst = 1 + (int)(random() % 8);
			for (int b = 0; b < burst && f < frames; b++) {
				int slot = -1;
				for (int i = 0; i < pool; i++) if (!busy[i]) { slot = i; break; }
				if (slot < 0) break;   // every surface is with the GPU or the reader: the burst ends early, as a blocked nextDrawable
				busy[slot] = 1; atomic_store(&done[slot], 0);
				const uint32_t k = (uint32_t)f++;
				id<MTLCommandQueue> qq = q[(random() % 5) == 0];
				id<MTLCommandBuffer> cb = [qq commandBuffer];
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = tex[slot]; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;
				const uint32_t tc = top_col(k);
				rp.colorAttachments[0].clearColor = MTLClearColorMake(((tc >> 16) & 0xff) / 255.0, ((tc >> 8) & 0xff) / 255.0, (tc & 0xff) / 255.0, 1);
				[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
				if (random() & 1) [cb encodeSignalEvent:ev value:++evv];   // seals the first part: the frame spans two
				const size_t bytes = (size_t)w * 4 * (h - h / 2);
				id<MTLBuffer> src = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
				const uint32_t bc = bot_col(k); uint32_t *px = src.contents; for (size_t i = 0; i < bytes / 4; i++) px[i] = bc;
				id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
				[bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:bytes sourceSize:MTLSizeMake(w, h - h / 2, 1)
				         toTexture:tex[slot] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, h / 2, 0)];
				[bl endEncoding];
				atomic_fetch_add(&inflight, 1);
				if (sched) [cb addScheduledHandler:^(id<MTLCommandBuffer> c) { [cv lock]; [landed addObject:@[ @(slot), @(k) ]]; [cv unlock]; }];
				[cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
					if (!sched) { [cv lock]; [landed addObject:@[ @(slot), @(k) ]]; [cv unlock]; }
					atomic_store(&done[slot], 1);
					atomic_fetch_sub(&inflight, 1);
				}];
				if (race && (k % 4) == 0) {
					((BOOL (*)(id, SEL))objc_msgSend)(cb, sel_registerName("commitAndWaitUntilSubmitted"));
					msg_t m = { IOSurfaceGetID(surf[slot]), k, (uint32_t)slot, 1 };
					if (write(toR[1], &m, sizeof m) != sizeof m) { printf("reader gone\n"); return 2; }
					captures++;
				} else if ((random() % 6) == 0) {
					((BOOL (*)(id, SEL))objc_msgSend)(cb, sel_registerName("commitAndWaitUntilSubmitted"));
				} else [cb commit];
				if ((random() % 10) == 0) { [cb waitUntilScheduled]; waits++; }
			}
			const long r = random() % 10;
			const useconds_t gap = r < 3 ? 0 : r < 8 ? (useconds_t)(random() % 8000) : (useconds_t)(8000 + random() % 17000);
			gapSum += gap; if (gap) usleep(gap);
		}
		close(toR[1]);
		int st = 0; waitpid(p, &st, 0);
		const double secs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e9;
		const int rfail = !WIFEXITED(st) || WEXITSTATUS(st) != 0;
		printf("%d frames in %.1f s (%.0f fps, mean gap %.1f ms), %d read at completion (%d wrong), %d captures, %d scheduled waits\n",
		       frames, secs, frames / secs, gapSum / 1000.0 / frames, sent, wrong, captures, waits);
		for (int i = 0; i < pool; i++) CFRelease(surf[i]);
		printf("%s\n", (wrong || rfail) ? "FAILED" : "PASSED");
		return (wrong || rfail) ? 1 : 0;
	}
}
