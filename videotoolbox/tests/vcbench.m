// SPDX-License-Identifier: MIT
// vcbench DIR SECONDS one|new|flush none|nv12|bgra|420f|420v [async 0|1]: decode throughput of the VideoToolbox decoders the
// way Video Codec Test drives them. DIR holds 0.<ext> ... N-1.<ext> (AVCC samples) and desc.<ext> (an ImageDescription
// with an avcC / hvcC atom), as in that app's Resources/h264_4k etc. A Metal device is created first, so the Metal
// plug-in registers the B580 decoders in this process.
//   one   one session, each loop: decode every sample, WaitForAsynchronousFrames
//   new   a new session per loop;  flush  FinishDelayedFrames + Wait per loop
//   420f/420v: the pixel buffer attributes that app asks for (its choice follows the format's FullRangeVideo)
// Environment: VCB_THREADS=n sessions in parallel (the app runs one per thread), VCB_PS=1 the format description from the
// parameter sets (as the app makes it: FullRangeVideo from the VUI), VCB_NOOUT=1 DoNotOutputFrame (decode only),
// VCB_SW=1 Apple's software decoder, VCB_SUM=1 a checksum of every output picture (hardware vs software).
// Build: clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O1 vcbench.m -framework Foundation -framework VideoToolbox \
//        -framework CoreMedia -framework CoreVideo -framework Metal -o vcbench
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

static _Atomic long g_out, g_err;
static int g_sum;
static void cb(void *a, void *b, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
	if (st) g_err++; else g_out++;
	if (g_sum && img && !st) {
		CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
		uint64_t hsh = 1469598103934665603ull;
		for (size_t p = 0; p < CVPixelBufferGetPlaneCount(img); p++) {
			const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(img, p);
			size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(img, p), rows = CVPixelBufferGetHeightOfPlane(img, p), wb = CVPixelBufferGetWidthOfPlane(img, p) * (p ? 2 : 1);
			for (size_t y = 0; y < rows; y++) for (size_t x = 0; x < wb; x++) { hsh ^= base[y * bpr + x]; hsh *= 1099511628211ull; }
		}
		OSType pf = CVPixelBufferGetPixelFormatType(img);
		CFTypeRef m = CVBufferCopyAttachment(img, kCVImageBufferYCbCrMatrixKey, NULL);
		printf("frame pts %lld fmt %.4s sum %016llx\n", pts.value, (char *)&(OSType){ CFSwapInt32HostToBig(pf) }, hsh);
		if (m) CFRelease(m);
		CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
	}
}
static double now(void) { return CFAbsoluteTimeGetCurrent(); }

int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc < 5) { fprintf(stderr, "usage: vcbench DIR SECONDS one|new|flush none|nv12|bgra [async 0|1]\n"); return 2; }
		id<MTLDevice> dev = getenv("VCB_NOMETAL") ? nil : MTLCreateSystemDefaultDevice(); printf("metal %s\n", dev ? dev.name.UTF8String : "-");
		NSString *dir = @(argv[1]); double secs = atof(argv[2]); const char *mode = argv[3], *fmt = argv[4];
		int async = argc > 5 ? atoi(argv[5]) : 1;
		NSString *ext = [dir hasSuffix:@"5_4k"] || [dir hasSuffix:@"5_2k"] || [dir containsString:@"h265"] ? @"h265" : @"h264";
		NSData *desc = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/desc.%@", ext]];
		const uint8_t *d = desc.bytes; size_t dn = desc.length;
		FourCharCode codec = (FourCharCode)d[4] | (FourCharCode)d[5] << 8 | (FourCharCode)d[6] << 16 | (FourCharCode)d[7] << 24;
		int32_t w = d[0x20] | d[0x21] << 8, h = d[0x22] | d[0x23] << 8;
		// the atoms after the 86-byte ImageDescription header: big-endian size + type
		NSMutableDictionary *atoms = [NSMutableDictionary dictionary];
		for (size_t o = 86; o + 8 <= dn;) {
			uint32_t sz = (uint32_t)d[o] << 24 | (uint32_t)d[o + 1] << 16 | (uint32_t)d[o + 2] << 8 | d[o + 3];
			if (sz < 8 || o + sz > dn) break;
			NSString *t = [[NSString alloc] initWithBytes:d + o + 4 length:4 encoding:NSASCIIStringEncoding];
			atoms[t] = [NSData dataWithBytes:d + o + 8 length:sz - 8];
			o += sz;
		}
		printf("codec %.4s %dx%d atoms %s\n", (char *)&(FourCharCode){ CFSwapInt32HostToBig(codec) }, w, h, [[atoms.allKeys componentsJoinedByString:@","] UTF8String]);
		NSDictionary *ext2 = @{ (id)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms };
		CMVideoFormatDescriptionRef fd = NULL;
		OSStatus r = CMVideoFormatDescriptionCreate(NULL, codec, w, h, (__bridge CFDictionaryRef)ext2, &fd);
		if (r) { printf("fd %d\n", r); return 1; }
		if (getenv("VCB_PS") && codec == 'avc1' && atoms[@"avcC"]) {   // like the app: from the parameter sets
			const uint8_t *a = [atoms[@"avcC"] bytes];
			size_t o = 5; int nsps = a[o++] & 31; const uint8_t *ps[8]; size_t pl[8]; int n = 0;
			for (int k = 0; k < nsps; k++) { size_t l = a[o] << 8 | a[o + 1]; ps[n] = a + o + 2; pl[n++] = l; o += 2 + l; }
			int npps = a[o++]; for (int k = 0; k < npps; k++) { size_t l = a[o] << 8 | a[o + 1]; ps[n] = a + o + 2; pl[n++] = l; o += 2 + l; }
			CMVideoFormatDescriptionRef fd2 = NULL;
			OSStatus r2 = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, (size_t)n, ps, pl, 4, &fd2);
			printf("from parameter sets: %d\n", (int)r2);
			if (!r2) { fd = fd2; CFShow(CMFormatDescriptionGetExtensions(fd)); }
		}
		if (getenv("VCB_PS") && codec == 'hvc1' && atoms[@"hvcC"]) {
			const uint8_t *a = [atoms[@"hvcC"] bytes]; size_t an = [atoms[@"hvcC"] length];
			size_t o = 22; int narr = a[o++]; const uint8_t *ps[16]; size_t pl[16]; int n = 0;
			for (int k = 0; k < narr && o < an; k++) { o++; int cnt = a[o] << 8 | a[o + 1]; o += 2;
				for (int m = 0; m < cnt; m++) { size_t l = a[o] << 8 | a[o + 1]; if (n < 16) { ps[n] = a + o + 2; pl[n++] = l; } o += 2 + l; } }
			CMVideoFormatDescriptionRef fd2 = NULL;
			OSStatus r2 = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, (size_t)n, ps, pl, 4, NULL, &fd2);
			printf("from parameter sets: %d\n", (int)r2);
			if (!r2) { fd = fd2; CFShow(CMFormatDescriptionGetExtensions(fd)); }
		}
		NSMutableArray<NSData *> *frames = [NSMutableArray array];
		for (int i = 0;; i++) {
			NSData *f = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/%d.%@", i, ext]];
			if (!f) break;
			[frames addObject:f];
		}
		NSMutableArray *samples = [NSMutableArray array];
		for (NSUInteger i = 0; i < frames.count; i++) {
			CMBlockBufferRef bb = NULL;
			CMBlockBufferCreateWithMemoryBlock(NULL, (void *)frames[i].bytes, frames[i].length, kCFAllocatorNull, NULL, 0, frames[i].length, 0, &bb);
			CMSampleTimingInfo ti = { CMTimeMake(1, 60), CMTimeMake((int64_t)i, 60), kCMTimeInvalid };
			size_t sz = frames[i].length;
			CMSampleBufferRef sb = NULL;
			CMSampleBufferCreateReady(NULL, bb, fd, 1, 1, &ti, 1, &sz, &sb);
			[samples addObject:(__bridge_transfer id)sb];
			CFRelease(bb);
		}
		int nthreads = getenv("VCB_THREADS") ? atoi(getenv("VCB_THREADS")) : 1;
		__block double tstart = now();
		dispatch_group_t g = dispatch_group_create();
		for (int ti = 0; ti < nthreads; ti++) {
			dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
				OSStatus r;
		g_sum = getenv("VCB_SUM") != NULL;
		NSDictionary *spec = getenv("VCB_SW") ? @{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO }
		                                      : @{ (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES };
		NSDictionary *attrs = nil;
		if (!strcmp(fmt, "nv12")) attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
		if (!strcmp(fmt, "420f") || !strcmp(fmt, "420v")) attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(fmt[3] == 'f' ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
			(id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h), (id)kCVPixelBufferMetalCompatibilityKey: @YES, (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
		if (!strcmp(fmt, "bgra")) attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
		VTDecompressionOutputCallbackRecord rec = { cb, NULL };
		VTDecompressionSessionRef s = NULL;
		double t_create = 0; int creates = 0;
#define CREATE() do { double t0 = now(); r = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)attrs, &rec, &s); t_create += now() - t0; creates++; if (r) { printf("create %d\n", r); return; } } while (0)
		CREATE();
		CFBooleanRef hw = NULL;
		VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &hw);
		printf("hardware %d\n", hw == kCFBooleanTrue);
		VTDecodeFrameFlags fl = async ? kVTDecodeFrame_EnableAsynchronousDecompression : 0;
		if (getenv("VCB_NOOUT")) fl |= kVTDecodeFrame_DoNotOutputFrame;
		if (getenv("VCB_NOOUT")) printf("DoNotOutputFrame\n");
		double t0 = now(), t_wait = 0; long loops = 0;
		while (now() - t0 < secs) {
			if (!strcmp(mode, "new") && loops) { VTDecompressionSessionInvalidate(s); CFRelease(s); CREATE(); }
			for (id sb in samples) {
				r = VTDecompressionSessionDecodeFrame(s, (__bridge CMSampleBufferRef)sb, fl, NULL, NULL);
				if (r) { g_err++; }
			}
			double tw = now();
			if (!strcmp(mode, "flush")) VTDecompressionSessionFinishDelayedFrames(s);
			VTDecompressionSessionWaitForAsynchronousFrames(s);
			t_wait += now() - tw;
			loops++;
		}
		double el = now() - t0;
		printf("%s %s async %d: %ld frames in %.2f s = %.0f fps, errors %ld, loops %ld, wait per loop %.2f ms, creates %d (%.2f ms each)\n",
		       mode, fmt, async, (long)g_out, el, g_out / el, (long)g_err, loops, t_wait / loops * 1e3, creates, t_create / creates * 1e3);
		VTDecompressionSessionInvalidate(s); CFRelease(s);
			}});
		}
		dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
		double tel = now() - tstart;
		printf("TOTAL threads %d: %ld frames in %.2f s = %.0f fps, errors %ld\n", nthreads, (long)g_out, tel, g_out / tel, (long)g_err);
	}
	return 0;
}
