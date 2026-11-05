// SPDX-License-Identifier: MIT
// emptytest: Apple GL's flush pattern - a busy command buffer in flight, then an EMPTY command buffer committed with
// commitAndWaitUntilSubmitted. Prints how long that call blocks (it used to wait for the busy one's GPU work).
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
	NSError *e = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void spin(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { float x = i; for (int k = 0; k < 20000; k++) x = fma(x, 1.000001f, 0.5f); o[i] = x; }\n" options:nil error:&e];
	id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"spin"] error:&e];
	id<MTLBuffer> o = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModePrivate];
	id<MTLCommandQueue> q = [dev newCommandQueue];
	double tot = 0, busy = 0; int n = 50;
	for (int i = 0; i < n; i++) @autoreleasepool {
		id<MTLCommandBuffer> a = [q commandBuffer]; id<MTLComputeCommandEncoder> c = [a computeCommandEncoder];
		[c setComputePipelineState:ps]; [c setBuffer:o offset:0 atIndex:0];
		[c dispatchThreads:MTLSizeMake(1 << 18, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [c endEncoding]; [a commit];
		id<MTLCommandBuffer> b = [q commandBuffer];
		const double t0 = now_us();
		((BOOL (*)(id, SEL))objc_msgSend)(b, sel_registerName("commitAndWaitUntilSubmitted"));
		tot += now_us() - t0;
		[b waitUntilCompleted]; busy += (a.GPUEndTime - a.GPUStartTime) * 1e6;
	}
	printf("empty commitAndWaitUntilSubmitted behind a busy command buffer: mean %.1f us (busy one's GPU time %.0f us)\n", tot / n, busy / n);
	return 0;
} }
