// SPDX-License-Identifier: MIT
// vtdec <movie> [frames] [--register <decoder binary>] [--md5]: decode a movie's video track through VTDecompressionSession
// (hardware decoder required for av01), report which decoder ran (hardware or not), frames and a checksum per frame.
// --register: register the given decoder binary's IntelXeAV1_CreateInstance in this process first (stage S1(a)).
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonDigest.h>
extern OSStatus VTRegisterVideoDecoderWithInfo(FourCharCode, CFDictionaryRef, void *);
static int frames, bad, md5;
static void cb(void *ref, void *src, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
	if (st || !img) { bad++; if (bad < 4) printf("  frame error %d\n", (int)st); return; }
	frames++;
	if (md5 || frames <= 2) {
		CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
		unsigned char h[16]; CC_MD5_CTX c; CC_MD5_Init(&c);
		for (size_t p = 0; p < CVPixelBufferGetPlaneCount(img); p++) {
			const uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(img, p); const size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
			const size_t w = CVPixelBufferGetWidthOfPlane(img, p) * (p ? 2 : 1) * (CVPixelBufferGetPixelFormatType(img) == 'x420' ? 2 : 1);
			for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(img, p); y++) CC_MD5_Update(&c, b + y * bpr, (CC_LONG)w);
		}
		CC_MD5_Final(h, &c);
		const uint8_t *y0 = CVPixelBufferGetBaseAddressOfPlane(img, 0);
		printf("%s frame %d %zux%zu fmt %.4s Y[0]=%u md5 ", md5 ? "" : " ", frames, CVPixelBufferGetWidth(img), CVPixelBufferGetHeight(img),
		       (char *)&(uint32_t){ CFSwapInt32HostToBig(CVPixelBufferGetPixelFormatType(img)) }, y0 ? y0[0] : 0);
		for (int i = 0; i < 16; i++) printf("%02x", h[i]);
		printf("\n");
		CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
	}
}
#include "pickdev.h"
int main(int argc, char **argv) { @autoreleasepool {
	if (getenv("VT_INTELXE_METAL")) { id<MTLDevice> d = mtl_pick_intelxe(); printf("metal: %s\n", d ? d.name.UTF8String : "none"); }
	if (argc < 2) { printf("usage: vtdec <movie> [frames] [--register bin] [--md5]\n"); return 2; }
	int max = 60; const char *reg = NULL;
	for (int a = 2; a < argc; a++) {
		if (!strcmp(argv[a], "--register") && a + 1 < argc) reg = argv[++a];
		else if (!strcmp(argv[a], "--md5")) md5 = 1;
		else max = atoi(argv[a]);
	}
	if (reg) {
		void *h = dlopen(reg, RTLD_NOW); void *f = h ? dlsym(h, "IntelXeAV1_CreateInstance") : NULL;
		NSDictionary *info = @{ @"CMClassImplementationID": @"io.github.yusufklncc.intelxe.videodecoder.av1", @"VTIsHardwareAccelerated": @YES, @"VTRating": @1000 };
		printf("register %s: %d\n", reg, f ? (int)VTRegisterVideoDecoderWithInfo('av01', (__bridge CFDictionaryRef)info, f) : -1);
	}
	printf("VTIsHardwareDecodeSupported('av01') = %d\n", VTIsHardwareDecodeSupported('av01'));
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	if (!track) { printf("no video track\n"); return 1; }
	NSError *e = nil;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&e];
	AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
	[r addOutput:out]; [r startReading];
	VTDecompressionSessionRef s = NULL; CMVideoFormatDescriptionRef fd = NULL;
	const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); int sent = 0;
	for (CMSampleBufferRef sb; sent < max && (sb = [out copyNextSampleBuffer]); CFRelease(sb)) {
		if (!CMSampleBufferGetNumSamples(sb) || !CMSampleBufferGetFormatDescription(sb)) continue;
		if (!s) {
			fd = (CMVideoFormatDescriptionRef)CMSampleBufferGetFormatDescription(sb);
			NSDictionary *spec = getenv("VTDEC_NOSPEC") ? nil : @{ (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES };
			if (getenv("VTDEC_FD")) printf("format: %s\n", [[(__bridge id)fd description] UTF8String]);
			VTDecompressionOutputCallbackRecord rec = { (VTDecompressionOutputCallback)cb, NULL };
			OSStatus st = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)spec, NULL, &rec, &s);
			CFBooleanRef hw = NULL;
			if (!st) VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw);
			printf("session (%.4s, hardware required) -> %d, using hardware %s\n", (char *)&(uint32_t){ CFSwapInt32HostToBig(CMFormatDescriptionGetMediaSubType(fd)) },
			       (int)st, hw == kCFBooleanTrue ? "yes" : "no");
			if (st) return 1;
		}
		if (!CMSampleBufferGetNumSamples(sb)) continue;
		VTDecompressionSessionDecodeFrame(s, sb, 0, NULL, NULL); sent++;
	}
	if (s) { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s); CFRelease(s); }
	printf("%d samples sent, %d frames out, %d errors, %.1f ms\n", sent, frames, bad, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
	return 0; } }
