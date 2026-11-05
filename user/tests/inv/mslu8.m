// SPDX-License-Identifier: MIT
// mslu8: MSL versions of the OpenCL kernels the translator refused (uchar4 buffer box filter, atomic max on a buffer)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
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
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void boxu(device const uchar4 *in [[buffer(0)]], device uchar4 *out [[buffer(1)]], constant int &w [[buffer(2)]], constant int &h [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"  int x = g.x, y = g.y; float4 a = 0; for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = clamp(x + dx, 0, w - 1), yy = clamp(y + dy, 0, h - 1);\n"
"  a += float4(in[yy * w + xx]); } out[y * w + x] = uchar4(clamp(rint(a / 9.0f), 0.0f, 255.0f)); }\n"
"kernel void amax(device const int *in [[buffer(0)]], device atomic_int *m [[buffer(1)]], uint i [[thread_position_in_grid]]) { atomic_fetch_max_explicit(m, in[i], memory_order_relaxed); }\n";
int main(void) { @autoreleasepool {
	id<MTLDevice> dev = getenv("NVMTL_BUNDLE") ? bundleDevice(getenv("NVMTL_BUNDLE")) : nil;
	if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
	if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
	int fails = 0;
	for (NSString *n in @[@"boxu", @"amax"]) {
		id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:n] error:&e];
		printf("%s: pipeline %s%s\n", n.UTF8String, ps ? "OK" : "FAILED ", ps ? "" : e.localizedDescription.UTF8String); fails += !ps;
	}
	return fails != 0;
} }
