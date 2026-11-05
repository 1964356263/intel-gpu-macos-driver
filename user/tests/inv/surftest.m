// SPDX-License-Identifier: MIT
// surftest: render into a fresh 2560x1440 IOSurface texture on the plugin device and check, page by page, that the
// IOSurface's memory (this process, and a second process that looks the surface up) holds the GPU's pixels.
//   NVMTL_BUNDLE=<bundle> NVMTL_ENABLE=1 ./surftest [touch] [frames N]
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <unistd.h>
#include <sys/wait.h>

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

// pages whose first and last pixel are not the expected colour; prints ranges, returns the count
static int scan(const char *who, IOSurfaceRef s, uint32_t want) {
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *b = IOSurfaceGetBaseAddress(s);
	const size_t n = IOSurfaceGetBytesPerRow(s) * IOSurfaceGetHeight(s);
	int bad = 0, run = -1;
	for (size_t p = 0; p * 4096 < n; p++) {
		uint32_t a, z; memcpy(&a, b + p * 4096, 4); memcpy(&z, b + p * 4096 + 4092, 4);
		const int ok = a == want && z == want;
		if (!ok) { bad++; if (run < 0) run = (int)p; }
		if ((ok || (p + 1) * 4096 >= n) && run >= 0) {
			printf("  %s: pages %d..%zu wrong (rows %zu..%zu), first %08x\n", who, run, ok ? p - 1 : p, run * 4096 / IOSurfaceGetBytesPerRow(s),
				((ok ? p : p + 1) * 4096 - 1) / IOSurfaceGetBytesPerRow(s), *(const uint32_t *)(b + run * 4096));
			run = -1;
		}
	}
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	printf("  %s: %d of %zu pages wrong\n", who, bad, (n + 4095) / 4096);
	return bad;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc > 2 && !strcmp(argv[1], "child")) {   // the second process: look the surface up and scan it
			IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)atoi(argv[2]));
			if (!s) { printf("  child: no surface %s\n", argv[2]); return 2; }
			return scan("other process", s, (uint32_t)strtoul(argv[3], NULL, 16)) ? 1 : 0;
		}
		int touch = 0, frames = 1, w = 2560, h = 1440, race = 0;
		for (int a = 1; a < argc; a++) {
			if (!strcmp(argv[a], "touch")) touch = 1;
			if (!strcmp(argv[a], "race")) race = 1;   // SkyLight's capture: commitAndWaitUntilSubmitted, then a CPU copy at once
			if (!strcmp(argv[a], "frames") && a + 1 < argc) frames = atoi(argv[++a]);
		}
		const char *bp = getenv("NVMTL_BUNDLE");
		id<MTLDevice> dev = nil;
		if (bp) dev = bundleDevice(bp);
		else for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
		if (!dev) { printf("no device\n"); return 2; }
		printf("device %s\n", dev.name.UTF8String);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		int fails = 0;
		for (int f = 0; f < frames; f++) @autoreleasepool {
			IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
				(id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
				(id)kIOSurfaceIsGlobal: @YES });
			if (touch) { IOSurfaceLock(s, 0, NULL); memset(IOSurfaceGetBaseAddress(s), 0, IOSurfaceGetAllocSize(s)); IOSurfaceUnlock(s, 0, NULL); }
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
			id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
			const double g = 0.25 + 0.05 * (f % 10);
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(1, g, 0, 1);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
			if (race) {
				((BOOL (*)(id, SEL))objc_msgSend)(cb, sel_registerName("commitAndWaitUntilSubmitted"));
				// do_finish_and_clear_capture_state: IOSurfaceLock read-only, memcpy row by row, unlock (on a global queue)
				const size_t row = IOSurfaceGetBytesPerRow(s); uint8_t *copy = malloc(row * h);
				dispatch_semaphore_t done = dispatch_semaphore_create(0);
				dispatch_async(dispatch_get_global_queue(0, 0), ^{
					IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
					const uint8_t *b = IOSurfaceGetBaseAddress(s);
					for (int y = 0; y < h; y++) memcpy(copy + y * row, b + y * row, row);
					IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
					dispatch_semaphore_signal(done); });
				dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
				int zr = 0, first = -1, last = -1;
				for (int y = 0; y < h; y++) { uint32_t a; memcpy(&a, copy + y * row + row / 2, 4); if (a == 0) { zr++; if (first < 0) first = y; last = y; } }
				printf("[frame %d race: CPU copy right after commitAndWaitUntilSubmitted: %d rows unwritten (rows %d..%d)]\n", f, zr, first, last);
				fails += zr != 0; free(copy);
				[cb waitUntilCompleted];
			} else { [cb commit]; [cb waitUntilCompleted]; }
			const uint8_t gb = (uint8_t)lrint(g * 255.0);
			const uint32_t want = 0xff000000u | 0xff0000u | (uint32_t)gb << 8;   // BGRA in memory: B=0 G R=ff A=ff
			printf("[frame %d: surface %u, %s]\n", f, IOSurfaceGetID(s), touch ? "pages touched first" : "fresh pages");
			fails += scan("this process", s, want) != 0;
			char id[16], col[16]; snprintf(id, sizeof id, "%u", IOSurfaceGetID(s)); snprintf(col, sizeof col, "%08x", want);
			pid_t p = fork();
			if (!p) { execl(argv[0], argv[0], "child", id, col, (char *)NULL); _exit(3); }
			int st = 0; waitpid(p, &st, 0); fails += !WIFEXITED(st) || WEXITSTATUS(st) != 0;
			CFRelease(s);
		}
		printf("%s (%d)\n", fails ? "FAILED" : "PASSED", fails);
		return fails != 0;
	}
}
