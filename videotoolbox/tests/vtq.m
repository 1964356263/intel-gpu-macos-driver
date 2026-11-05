// SPDX-License-Identifier: MIT
// vtq: what VideoToolbox offers for a codec in this process: the decoder list entries, hardware support, and the AV1
// capability dictionary (private).   vtq [fourcc=av01]
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
extern OSStatus VTCopyVideoDecoderList(CFDictionaryRef, CFArrayRef *);
extern const CFStringRef kVTVideoDecoderList_CodecType, kVTVideoDecoderList_DisplayName, kVTVideoDecoderList_DecoderID;
#include "pickdev.h"
int main(int argc, char **argv) { @autoreleasepool {
	if (getenv("VT_INTELXE_METAL")) { id<MTLDevice> d = mtl_pick_intelxe(); printf("metal: %s\n", d ? d.name.UTF8String : "none"); }
	const char *cc = argc > 1 ? argv[1] : "av01";
	const FourCharCode c = (FourCharCode)((cc[0] << 24) | (cc[1] << 16) | (cc[2] << 8) | cc[3]);
	extern void VTRegisterVideoDecoderBundleDirectory(CFURLRef);
	if (argc > 2) { VTRegisterVideoDecoderBundleDirectory((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])]); printf("registered bundle directory %s\n", argv[2]); }
	CFArrayRef list = NULL;
	VTCopyVideoDecoderList(NULL, &list);
	int n = 0;
	for (NSDictionary *d in (__bridge NSArray *)list) {
		NSNumber *t = d[(__bridge NSString *)kVTVideoDecoderList_CodecType];
		if (t.unsignedIntValue != c) continue;
		n++;
		printf("decoder: %s | id %s | hw %s\n", [d[(__bridge NSString *)kVTVideoDecoderList_DisplayName] UTF8String],
		       [d[(__bridge NSString *)kVTVideoDecoderList_DecoderID] UTF8String], [[d[@"IsHardwareAccelerated"] description] UTF8String]);
	}
	printf("%d decoder(s) for '%s' of %ld in all\n", n, cc, list ? (long)CFArrayGetCount(list) : 0L);
	printf("VTIsHardwareDecodeSupported('%s') = %d\n", cc, VTIsHardwareDecodeSupported(c));
	CFDictionaryRef (*caps)(void) = dlsym(RTLD_DEFAULT, "VTCopyAV1DecoderCapabilitiesDictionary");
	if (caps) { CFDictionaryRef d = caps(); printf("VTCopyAV1DecoderCapabilitiesDictionary: %s\n", d ? [[(__bridge NSDictionary *)d description] UTF8String] : "NULL"); }
	if (list) CFRelease(list);
	return 0; } }
