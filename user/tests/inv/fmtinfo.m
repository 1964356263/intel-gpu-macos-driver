// SPDX-License-Identifier: MIT
// fmtinfo: what Metal's format table says about pixel formats on the plugin device (CoreAnimation asks
// MTLPixelFormatGetInfoForDevice before it gives an image mipmaps: CA::OGL::MetalContext::can_generate_mipmaps_for_format)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
typedef struct { const char *name; uint64_t flags; uint64_t rest[5]; } PFI;
extern PFI MTLPixelFormatGetInfoForDevice(id device, MTLPixelFormat f);
static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
	if (![b loadAndReturnError:&e]) { printf("bundle: %s\n", e.localizedDescription.UTF8String); return nil; }
	Class cls = [b classNamed:@"NVMTLDevice"]; io_iterator_t it = 0;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice"))) dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name); }
	return dev;
}
int main(int argc, char **argv) { @autoreleasepool {
	const char *bp = getenv("NVMTL_BUNDLE"); id<MTLDevice> dev = nil;
	if (bp) dev = bundleDevice(bp); else for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	if (!dev) { printf("no device\n"); return 2; }
	printf("device %s\n", dev.name.UTF8String);
	for (MTLGPUFamily f = 1001; f <= 1010; f++) printf("supportsFamily(Apple%d) %d  ", (int)f - 1000, [dev supportsFamily:f]); printf("\n");
	for (MTLGPUFamily f = 2001; f <= 2002; f++) printf("supportsFamily(Mac%d) %d  ", (int)f - 2000, [dev supportsFamily:f]); printf("\n");
	printf("supportsFamily(Common1..3) %d %d %d, Metal3 %d\n", [dev supportsFamily:3001], [dev supportsFamily:3002], [dev supportsFamily:3003], [dev supportsFamily:5001]);
	if ([dev respondsToSelector:@selector(supports32BitFloatFiltering)]) printf("supports32BitFloatFiltering %d\n", dev.supports32BitFloatFiltering);
	const int fmts[] = { 1, 10, 11, 25, 30, 70, 71, 80, 81, 90, 94, 110, 115, 125, 550, 551, 552, 553, 554, 555 };
	for (unsigned i = 0; i < sizeof fmts / sizeof fmts[0]; i++) {
		PFI p = MTLPixelFormatGetInfoForDevice(dev, (MTLPixelFormat)fmts[i]);
		printf("  fmt %3d %-24s flags 0x%08llx  bit4(0x10, CA: mipmaps can be generated) %d\n", fmts[i], p.name ? p.name : "?", (unsigned long long)p.flags, (int)((p.flags >> 4) & 1));
	}
	return 0;
} }
