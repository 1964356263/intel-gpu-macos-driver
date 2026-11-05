// SPDX-License-Identifier: MIT
// vttest: VideoToolbox hardware encode/decode check + Metal device list.
//   vttest metal                  list Metal devices and the system default
//   vttest list                   list VT encoders (HW marked)
//   vttest enc h264|hevc [frames] encode 1920x1080 NV12 frames, hardware required; prints fps, GPU registry id,
//                                 then decodes the produced stream with a hardware-required decoder
//   vttest dec file.mp4 [frames]  decode the first video track with a hardware-required decoder
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

static double now_s(void) {
	static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
	return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static void metal(void) {
	NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
	for (id<MTLDevice> d in all)
		printf("device %-45s regID 0x%llx headless %d lowPower %d removable %d\n", d.name.UTF8String,
		       d.registryID, d.isHeadless, d.isLowPower, d.isRemovable);
	id<MTLDevice> md = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID());
	printf("main display 0x%x Metal device: %s (0x%llx)\n", CGMainDisplayID(), md ? md.name.UTF8String : "(none)", md ? md.registryID : 0);
	id<MTLDevice> def = MTLCreateSystemDefaultDevice();
	printf("default: %s (0x%llx)\n", def ? def.name.UTF8String : "(none)", def ? def.registryID : 0);
}
static void list(void) {
	CFArrayRef l = NULL;
	if (VTCopyVideoEncoderList(NULL, &l) || !l) { printf("no encoder list\n"); return; }
	for (CFIndex i = 0; i < CFArrayGetCount(l); i++) {
		NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(l, i);
		printf("%s %-45s %s\n", [d[@"IsHardwareAccelerated"] boolValue] ? "HW" : "  ",
		       [d[(__bridge NSString *)kVTVideoEncoderList_EncoderID] UTF8String],
		       [d[(__bridge NSString *)kVTVideoEncoderList_DisplayName] UTF8String]);
	}
	CFRelease(l);
}

static NSMutableArray *gSamples; static atomic_int gOut, gErr;
static void encCB(void *r, void *s, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
	if (st || !sb) { atomic_fetch_add(&gErr, 1); return; }
	@synchronized (gSamples) { [gSamples addObject:(__bridge id)sb]; }
	atomic_fetch_add(&gOut, 1);
}
static atomic_int gDec, gDecErr; static OSType gDecFmt;
static void decCB(void *r, void *s, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
	if (st || !img) { if (atomic_fetch_add(&gDecErr, 1) < 3) printf("  decode frame error %d\n", (int)st); return; }
	gDecFmt = CVPixelBufferGetPixelFormatType(img);
	atomic_fetch_add(&gDec, 1);
}
static int decode(CMFormatDescriptionRef fmt, NSArray *samples, const char *what) {
	NSDictionary *spec = @{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
	NSDictionary *attrs = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
	                        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
	VTDecompressionOutputCallbackRecord cb = {decCB, NULL};
	VTDecompressionSessionRef ds = NULL;
	OSStatus st = VTDecompressionSessionCreate(NULL, fmt, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)attrs, &cb, &ds);
	if (st) { printf("%s decode: hardware decoder session failed %d\n", what, (int)st); return 1; }
	CFBooleanRef hw = NULL; CFNumberRef gpu = NULL;
	VTSessionCopyProperty(ds, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw);
	VTSessionCopyProperty(ds, kVTDecompressionPropertyKey_UsingGPURegistryID, NULL, &gpu);
	long long gid = 0; if (gpu) CFNumberGetValue(gpu, kCFNumberLongLongType, &gid);
	atomic_store(&gDec, 0); atomic_store(&gDecErr, 0);
	double t0 = now_s();
	for (id s in samples) {
		VTDecodeFrameFlags fl = kVTDecodeFrame_EnableAsynchronousDecompression; VTDecodeInfoFlags inf = 0;
		st = VTDecompressionSessionDecodeFrame(ds, (__bridge CMSampleBufferRef)s, fl, NULL, &inf);
		if (st) { printf("  DecodeFrame %d\n", (int)st); break; }
	}
	VTDecompressionSessionWaitForAsynchronousFrames(ds);
	double t = now_s() - t0;
	printf("%s decode: %d/%lu frames in %.3f s = %.0f fps, errors %d, hardware %s, GPU regID 0x%llx, out %.4s\n", what,
	       atomic_load(&gDec), (unsigned long)samples.count, t, atomic_load(&gDec) / t, atomic_load(&gDecErr),
	       hw == kCFBooleanTrue ? "YES" : "no", gid, (char *)&(OSType){CFSwapInt32HostToBig(gDecFmt)});
	VTDecompressionSessionInvalidate(ds); CFRelease(ds);
	return atomic_load(&gDec) == (int)samples.count ? 0 : 1;
}
static int enc(const char *codec, int frames) {
	const int W = 1920, H = 1080;
	CMVideoCodecType ct = !strcmp(codec, "hevc") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
	NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
	VTCompressionSessionRef cs = NULL;
	gSamples = [NSMutableArray array];
	OSStatus st = VTCompressionSessionCreate(NULL, W, H, ct, (__bridge CFDictionaryRef)spec, NULL, NULL, encCB, NULL, &cs);
	if (st) { printf("%s encode: hardware encoder session failed %d\n", codec, (int)st); return 1; }
	VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
	VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
	VTSessionSetProperty(cs, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(8000000));
	VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(60));
	CFBooleanRef hw = NULL; CFNumberRef gpu = NULL; CFStringRef eid = NULL;
	VTSessionCopyProperty(cs, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hw);
	VTSessionCopyProperty(cs, kVTCompressionPropertyKey_UsingGPURegistryID, NULL, &gpu);
	VTSessionCopyProperty(cs, CFSTR("EncoderID"), NULL, &eid);
	long long gid = 0; if (gpu) CFNumberGetValue(gpu, kCFNumberLongLongType, &gid);
	CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(cs);
	if (!pool) { printf("no pixel buffer pool\n"); return 1; }
	double t0 = now_s();
	for (int i = 0; i < frames; i++) {
		CVPixelBufferRef pb = NULL;
		if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb)) { printf("pool alloc failed\n"); break; }
		CVPixelBufferLockBaseAddress(pb, 0);
		for (size_t p = 0; p < CVPixelBufferGetPlaneCount(pb); p++) {   // moving gradient
			uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(pb, p); size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
			size_t h = CVPixelBufferGetHeightOfPlane(pb, p), w = CVPixelBufferGetWidthOfPlane(pb, p) * (p ? 2 : 1);
			for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x += 4) *(uint32_t *)(b + y * bpr + x) = (uint32_t)((x + y + i * 4) * 0x01010101u);
		}
		CVPixelBufferUnlockBaseAddress(pb, 0);
		st = VTCompressionSessionEncodeFrame(cs, pb, CMTimeMake(i, 60), CMTimeMake(1, 60), NULL, NULL, NULL);
		CVPixelBufferRelease(pb);
		if (st) { printf("EncodeFrame %d\n", (int)st); break; }
	}
	VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
	double t = now_s() - t0;
	size_t bytes = 0; for (id s in gSamples) bytes += CMSampleBufferGetTotalSampleSize((__bridge CMSampleBufferRef)s);
	printf("%s encode: %d/%d frames 1920x1080 in %.3f s = %.0f fps (incl. CPU frame fill), %zu KB, errors %d, hardware %s, "
	       "encoder %s, GPU regID 0x%llx\n", codec, atomic_load(&gOut), frames, t, atomic_load(&gOut) / t, bytes / 1024,
	       atomic_load(&gErr), hw == kCFBooleanTrue ? "YES" : "no", eid ? CFStringGetCStringPtr(eid, kCFStringEncodingUTF8) : "?", gid);
	VTCompressionSessionInvalidate(cs); CFRelease(cs);
	if (!gSamples.count) return 1;
	return decode(CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)gSamples[0]), gSamples, codec);
}
static int decfile(const char *path, int frames) {
	AVAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path)] options:nil];
	__block NSArray *tracks = nil; dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[a loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray *t, NSError *e) { tracks = t; dispatch_semaphore_signal(sem); }];
	dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
	if (!tracks.count) { printf("no video track\n"); return 1; }
	NSError *err = nil; AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:a error:&err];
	AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks[0] outputSettings:nil];
	[rd addOutput:o]; [rd startReading];
	NSMutableArray *s = [NSMutableArray array]; CMFormatDescriptionRef fmt = NULL;
	CMSampleBufferRef sb;
	while ((int)s.count < frames && (sb = [o copyNextSampleBuffer])) {
		if (CMSampleBufferGetNumSamples(sb)) { if (!fmt) fmt = CMSampleBufferGetFormatDescription(sb); [s addObject:(__bridge_transfer id)sb]; }
		else CFRelease(sb);
	}
	if (!fmt) { printf("no samples\n"); return 1; }
	FourCharCode c = CFSwapInt32HostToBig(CMFormatDescriptionGetMediaSubType(fmt));
	char what[64]; snprintf(what, sizeof what, "%.4s %s", (char *)&c, path);
	return decode(fmt, s, what);
}
int main(int argc, char **argv) {
	@autoreleasepool {
		const char *m = argc > 1 ? argv[1] : "metal";
		if (!strcmp(m, "metal")) { metal(); return 0; }
		if (!strcmp(m, "list")) { list(); return 0; }
		if (!strcmp(m, "enc") && argc > 2) return enc(argv[2], argc > 3 ? atoi(argv[3]) : 600);
		if (!strcmp(m, "dec") && argc > 2) return decfile(argv[2], argc > 3 ? atoi(argv[3]) : 100000);
		fprintf(stderr, "usage: vttest metal | list | enc h264|hevc [frames] | dec file.mp4 [frames]\n");
		return 2;
	}
}
