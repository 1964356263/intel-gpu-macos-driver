// SPDX-License-Identifier: MIT
// churn: OpenCL-style buffer churn - create, use once, release - at sizes that vary a little (1-80 MB), per storage mode
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <mach/mach_time.h>
static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
	if (![b loadAndReturnError:&e]) return nil;
	Class cls = [b classNamed:@"NVMTLDevice"]; io_iterator_t it = 0;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
	id<MTLDevice> d = nil;
	for (io_service_t svc; !d && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice"))) d = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name); }
	return d;
}
static double now_us(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1000.0; }
int main(void) { @autoreleasepool {
	id<MTLDevice> dev = getenv("NVMTL_BUNDLE") ? bundleDevice(getenv("NVMTL_BUNDLE")) : nil;
	if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	id<MTLCommandQueue> q = [dev newCommandQueue];
	const MTLResourceOptions modes[2] = { MTLResourceStorageModePrivate, MTLResourceStorageModeShared };
	for (int m = 0; m < 2; m++) {
		unsigned seed = 1; double t0 = now_us(); int n = 300;
		for (int i = 0; i < n; i++) @autoreleasepool {
			seed = seed * 1103515245u + 12345u; const size_t base = (size_t)1 << (20 + (seed >> 16) % 7);   // 1-64 MB
			const size_t len = base + (seed >> 8) % (base / 8);                                               // + up to 12%
			id<MTLBuffer> b = [dev newBufferWithLength:len options:modes[m]];
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
			[e fillBuffer:b range:NSMakeRange(0, 4096) value:1]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
		}
		printf("%s: %.0f us per create + fill + release (%d buffers, 1-72 MB)\n", m ? "Shared " : "Private", (now_us() - t0) / n, n);
	}
	return 0;
} }
