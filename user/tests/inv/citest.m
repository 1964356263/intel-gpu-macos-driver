// SPDX-License-Identifier: MIT
// citest <icon.rgba> : CoreImage 2:1 downscales of the icon on the plugin device (and on the CPU renderer), written out
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
	if (![b loadAndReturnError:&e]) return nil;
	Class cls = [b classNamed:@"NVMTLDevice"]; io_iterator_t it = 0;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice"))) dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name); }
	return dev;
}
static void out(CIContext *c, CIImage *im, const char *path, int s) {
	uint8_t *p = calloc(s * s, 4);
	[c render:im toBitmap:p rowBytes:s * 4 bounds:CGRectMake(0, 0, s, s) format:kCIFormatRGBA8 colorSpace:CGColorSpaceCreateWithName(kCGColorSpaceSRGB)];
	FILE *f = fopen(path, "wb"); fwrite(&s, 4, 1, f); fwrite(&s, 4, 1, f); fwrite(p, 4, (size_t)s * s, f); fclose(f); free(p);
}
int main(int argc, char **argv) { @autoreleasepool {
	FILE *f = fopen(argv[1], "rb"); int w, h; fread(&w, 4, 1, f); fread(&h, 4, 1, f); uint8_t *p = malloc((size_t)w * h * 4); fread(p, 4, (size_t)w * h, f); fclose(f);
	CIImage *src = [CIImage imageWithBitmapData:[NSData dataWithBytes:p length:(size_t)w * h * 4] bytesPerRow:w * 4 size:CGSizeMake(w, h)
		format:kCIFormatRGBA8 colorSpace:CGColorSpaceCreateWithName(kCGColorSpaceSRGB)];
	const char *bp = getenv("NVMTL_BUNDLE"); id<MTLDevice> dev = bp ? bundleDevice(bp) : nil;
	if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	CIContext *g = [CIContext contextWithMTLDevice:dev], *c = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
	CIImage *aff = [src imageByApplyingTransform:CGAffineTransformMakeScale(.5, .5)];
	CIImage *lan = [src imageByApplyingFilter:@"CILanczosScaleTransform" withInputParameters:@{ @"inputScale": @.5, @"inputAspectRatio": @1 }];
	out(g, aff, "ci_gpu_affine.rgba", w / 2); out(c, aff, "ci_cpu_affine.rgba", w / 2);
	out(g, lan, "ci_gpu_lanczos.rgba", w / 2); out(c, lan, "ci_cpu_lanczos.rgba", w / 2);
	printf("device %s\n", dev.name.UTF8String);
	return 0;
} }
