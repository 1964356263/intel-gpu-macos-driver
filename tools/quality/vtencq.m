// SPDX-License-Identifier: MIT
// vtencq: VTCompressionSession encode test (derived from vtenctest). Input is mmapped, not preloaded.
//   vtencq [--metal] [--id EncoderID | --any] codec(hevc|h264|av1) WxH raw.nv12 frames out|- [--bitrate N | --cbr N | --quality Q]
//          [--maxrate N] [--realtime] [--noreorder] [--keyint N] [--10bit] [--fps F] [--seconds S]
// raw.nv12: NV12 (P010 with --10bit) frames, wrapped around when frames > file. Output: Annex B (.hevc/.h264) or IVF (.ivf for
// AV1); "-" discards. --seconds S: encode for S seconds (stability), a status line every 30 s.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach.h>

static FILE *out; static FourCharCode codec; static int64_t emitted, keys, bytes, errors, async_ok;
static int wrote_ivf_hdr; static double g_fps = 30; static char g_encid[128];
static double footprint_mb(void) { task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n)) return -1; return vi.phys_footprint / 1048576.0; }
static void put_le32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static void write_param_sets(CMFormatDescriptionRef fd) {
	size_t n = 0; int nal = 0;
	if (codec == 'hvc1') CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &n, &nal);
	else CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &n, &nal);
	for (size_t i = 0; i < n; i++) {
		const uint8_t *p; size_t sz;
		OSStatus r = codec == 'hvc1' ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &sz, NULL, NULL)
		                             : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &p, &sz, NULL, NULL);
		if (r) continue;
		fwrite("\0\0\0\1", 1, 4, out); fwrite(p, 1, sz, out);
	}
}

static void cb(void *ref, void *src, OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb) {
	if (st || !sb) { if (!(fl & kVTEncodeInfo_FrameDropped)) { errors++; fprintf(stderr, "frame error %d flags 0x%x\n", (int)st, fl); } return; }
	if (fl & kVTEncodeInfo_Asynchronous) async_ok++;
	CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
	CFDictionaryRef a = att && CFArrayGetCount(att) ? CFArrayGetValueAtIndex(att, 0) : NULL;
	int key = !(a && CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue);
	CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
	CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
	size_t len = CMBlockBufferGetDataLength(bb);
	uint8_t *d = malloc(len); CMBlockBufferCopyDataBytes(bb, 0, len, d);
	if (getenv("VTENC_VERBOSE") && (emitted < 3 || (key && keys < 3))) {
		CMTime p = CMSampleBufferGetPresentationTimeStamp(sb), dt = CMSampleBufferGetDecodeTimeStamp(sb);
		fprintf(stderr, "out %lld: pts %lld/%d dts %lld/%d key %d %zu bytes\n", emitted, p.value, p.timescale, dt.value, dt.timescale, key, len);
	}
	if (!out) { free(d); emitted++; keys += key; bytes += len; return; }
	if (codec == 'av01') {
		if (!wrote_ivf_hdr) {
			CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fd);
			uint8_t h[32] = "DKIF"; h[4] = 0; h[5] = 0; h[6] = 32; h[7] = 0; memcpy(h + 8, "AV01", 4);
			h[12] = dim.width; h[13] = dim.width >> 8; h[14] = dim.height; h[15] = dim.height >> 8;
			put_le32(h + 16, (uint32_t)g_fps); put_le32(h + 20, 1); put_le32(h + 24, 0); put_le32(h + 28, 0);
			fwrite(h, 1, 32, out); wrote_ivf_hdr = 1;
		}
		// a temporal unit: temporal delimiter, then the sequence header (from av1C) on key frames, then the sample
		CFDictionaryRef atoms = CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
		CFDataRef av1c = atoms ? CFDictionaryGetValue(atoms, CFSTR("av1C")) : NULL;
		size_t seqn = key && av1c ? CFDataGetLength(av1c) - 4 : 0;
		uint8_t fh[12]; put_le32(fh, (uint32_t)(2 + seqn + len)); put_le32(fh + 4, (uint32_t)emitted); put_le32(fh + 8, 0);
		fwrite(fh, 1, 12, out); fwrite("\x12\x00", 1, 2, out);
		if (seqn) fwrite(CFDataGetBytePtr(av1c) + 4, 1, seqn, out);
		fwrite(d, 1, len, out);
	} else {
		if (key) write_param_sets(fd);
		for (size_t o = 0; o + 4 <= len;) {
			uint32_t n = d[o] << 24 | d[o + 1] << 16 | d[o + 2] << 8 | d[o + 3];
			fwrite("\0\0\0\1", 1, 4, out); fwrite(d + o + 4, 1, n, out); o += 4 + n;
		}
	}
	free(d);
	emitted++; keys += key; bytes += len;
}

static void gpu_bundles(const char *when) {
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *n = _dyld_get_image_name(i);
		if (strstr(n, "GPUBundles") || strstr(n, "intelxevenc") || strstr(n, "libavcodec")) fprintf(stderr, "[%s] image %s\n", when, n);
	}
}
// what HandBrake does to decide whether a hardware encoder exists for a codec
static void probe(FourCharCode c) {
	NSDictionary *spec = @{ (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES };
	CFStringRef eid = NULL; CFDictionaryRef sup = NULL;
	OSStatus r = VTCopySupportedPropertyDictionaryForEncoder(1920, 1080, c, (__bridge CFDictionaryRef)spec, &eid, &sup);
	NSDictionary *pl = sup ? ((__bridge NSDictionary *)sup)[(__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel] : nil;
	printf("probe %c%c%c%c: %d encoder %s, %ld properties, Main10 listed: %s\n", c >> 24, c >> 16, c >> 8, c, (int)r,
	       eid ? [(__bridge NSString *)eid UTF8String] : "-", sup ? (long)CFDictionaryGetCount(sup) : 0L,
	       [pl[(__bridge NSString *)kVTPropertySupportedValueListKey] containsObject:(__bridge id)kVTProfileLevel_HEVC_Main10_AutoLevel] ? "yes" : "no");
}

static void list(void) {
	CFArrayRef l = NULL;
	VTCopyVideoEncoderList(NULL, &l);
	for (CFIndex i = 0; l && i < CFArrayGetCount(l); i++) {
		NSDictionary *e = (__bridge NSDictionary *)CFArrayGetValueAtIndex(l, i);
		uint32_t t = [e[(__bridge NSString *)kVTVideoEncoderList_CodecType] unsignedIntValue];
		printf("%c%c%c%c  %-45s  %-32s  hw=%s\n", t >> 24, t >> 16, t >> 8, t, [e[(__bridge NSString *)kVTVideoEncoderList_EncoderID] UTF8String],
		       [e[(__bridge NSString *)kVTVideoEncoderList_DisplayName] UTF8String], [[e[(__bridge NSString *)kVTVideoEncoderList_IsHardwareAccelerated] description] UTF8String]);
	}
	if (l) CFRelease(l);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		const char *lib = NULL, *encid = NULL; int any = 0, listonly = 0, realtime = 0, noreorder = 0, keyint = 0, ten = 0;
		long bitrate = 0, cbr = 0, maxrate = 0; double quality = -1, fps = 30, seconds = 0;
		const char *pos[8]; int np = 0;
		for (int i = 1; i < argc; i++) {
			if (!strcmp(argv[i], "--lib")) lib = argv[++i];
			else if (!strcmp(argv[i], "--metal")) {    // bring Metal up first, as OBS or an app with Metal views does
				uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				NSArray *d = MTLCopyAllDevices();
				fprintf(stderr, "Metal: %lu devices (%.1f ms)\n", (unsigned long)d.count, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
			}
			else if (!strcmp(argv[i], "--preload")) {   // load a binary first (the GPU plug-in, as Metal would), nothing else
				const char *p = argv[++i]; uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				void *h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
				fprintf(stderr, "preload %s: %s (%.1f ms)\n", p, h ? "ok" : dlerror(), (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
			}
			else if (!strcmp(argv[i], "--id")) encid = argv[++i];
			else if (!strcmp(argv[i], "--any")) any = 1;
			else if (!strcmp(argv[i], "--list")) listonly = 1;
			else if (!strcmp(argv[i], "--bitrate")) bitrate = atol(argv[++i]);
			else if (!strcmp(argv[i], "--cbr")) cbr = atol(argv[++i]);
			else if (!strcmp(argv[i], "--quality")) quality = atof(argv[++i]);
			else if (!strcmp(argv[i], "--realtime")) realtime = 1;
			else if (!strcmp(argv[i], "--noreorder")) noreorder = 1;
			else if (!strcmp(argv[i], "--keyint")) keyint = atoi(argv[++i]);
			else if (!strcmp(argv[i], "--10bit")) ten = 1;
			else if (!strcmp(argv[i], "--fps")) fps = atof(argv[++i]);
			else if (!strcmp(argv[i], "--seconds")) seconds = atof(argv[++i]);
			else if (!strcmp(argv[i], "--maxrate")) maxrate = atol(argv[++i]);
			else if (np < 8) pos[np++] = argv[i];
		}
		if (lib) {
			void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
			int (*reg)(void) = h ? (int (*)(void))dlsym(h, "IntelXeVEnc_Register") : NULL;
			if (!reg) { fprintf(stderr, "dlopen %s: %s\n", lib, dlerror()); return 1; }
			fprintf(stderr, "IntelXeVEnc_Register -> %d\n", reg());
		}
		if (listonly) { gpu_bundles("start"); list(); probe('hvc1'); probe('avc1'); gpu_bundles("after list"); return 0; }
		if (np < 5) { fprintf(stderr, "usage: see source\n"); return 2; }
		codec = !strcmp(pos[0], "hevc") ? 'hvc1' : !strcmp(pos[0], "h264") ? 'avc1' : 'av01';
		int w = atoi(pos[1]), hh = atoi(strchr(pos[1], 'x') + 1), frames = atoi(pos[3]);
		int fdin = open(pos[2], O_RDONLY); out = !strcmp(pos[4], "-") ? NULL : fopen(pos[4], "wb");
		if (fdin < 0 || (!out && strcmp(pos[4], "-"))) { perror("open"); return 1; }
		g_fps = fps;
		size_t fsz = (size_t)w * hh * 3 / 2 * (ten ? 2 : 1);
		off_t isz = lseek(fdin, 0, SEEK_END); long nraw = (long)(isz / (off_t)fsz);
		if (nraw < 1) { fprintf(stderr, "input smaller than one frame\n"); return 1; }
		const uint8_t *raw = mmap(NULL, fsz * nraw, PROT_READ, MAP_SHARED, fdin, 0);
		if (raw == MAP_FAILED) { perror("mmap"); return 1; }
		madvise((void *)raw, fsz * nraw, MADV_SEQUENTIAL);
		NSMutableDictionary *spec = [NSMutableDictionary dictionary];
		if (encid) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EncoderID] = @(encid);
		else if (!any) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EncoderID] =
			codec == 'hvc1' ? @"io.github.yusufklncc.intelxe.videoencoder.hevc" : codec == 'avc1' ? @"io.github.yusufklncc.intelxe.videoencoder.h264" : @"io.github.yusufklncc.intelxe.videoencoder.av1";
		else spec[(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = @YES;
		VTCompressionSessionRef s = NULL;
		OSStatus r = VTCompressionSessionCreate(NULL, w, hh, codec, (__bridge CFDictionaryRef)spec, NULL, NULL, cb, NULL, &s);
		if (r) { fprintf(stderr, "VTCompressionSessionCreate -> %d\n", (int)r); return 1; }
		CFStringRef eid = NULL; CFBooleanRef hw = NULL;
		VTSessionCopyProperty(s, kVTCompressionPropertyKey_EncoderID, NULL, &eid);
		VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hw);
		snprintf(g_encid, sizeof g_encid, "%s", eid ? [(__bridge NSString *)eid UTF8String] : "?");
		fprintf(stderr, "session: encoder %s, hardware %s\n", g_encid, hw == kCFBooleanTrue ? "yes" : "no");
		CFDictionaryRef sup = NULL; VTSessionCopySupportedPropertyDictionary(s, &sup);
		fprintf(stderr, "supported properties: %ld\n", sup ? (long)CFDictionaryGetCount(sup) : -1L);
#define SET(k, v) do { OSStatus e_ = VTSessionSetProperty(s, k, (__bridge CFTypeRef)(v)); if (e_) fprintf(stderr, "set %s -> %d\n", #k, (int)e_); } while (0)
		SET(kVTCompressionPropertyKey_RealTime, realtime ? @YES : @NO);
		SET(kVTCompressionPropertyKey_AllowFrameReordering, noreorder ? @NO : @YES);
		SET(kVTCompressionPropertyKey_ExpectedFrameRate, @(fps));
		if (keyint) SET(kVTCompressionPropertyKey_MaxKeyFrameInterval, @(keyint));
		if (bitrate) SET(kVTCompressionPropertyKey_AverageBitRate, @(bitrate));
		if (cbr) SET(kVTCompressionPropertyKey_ConstantBitRate, @(cbr));
		if (maxrate) SET(kVTCompressionPropertyKey_DataRateLimits, (@[ @(maxrate / 8), @1.0 ]));
		if (quality >= 0) SET(kVTCompressionPropertyKey_Quality, @(quality));
		if (codec == 'hvc1') SET(kVTCompressionPropertyKey_ProfileLevel, ten ? (__bridge id)kVTProfileLevel_HEVC_Main10_AutoLevel : (__bridge id)kVTProfileLevel_HEVC_Main_AutoLevel);
		if (codec == 'avc1') SET(kVTCompressionPropertyKey_ProfileLevel, (__bridge id)kVTProfileLevel_H264_High_AutoLevel);
		SET(kVTCompressionPropertyKey_ColorPrimaries, (__bridge id)kCVImageBufferColorPrimaries_ITU_R_709_2);
		SET(kVTCompressionPropertyKey_TransferFunction, (__bridge id)kCVImageBufferTransferFunction_ITU_R_709_2);
		SET(kVTCompressionPropertyKey_YCbCrMatrix, (__bridge id)kCVImageBufferYCbCrMatrix_ITU_R_709_2);
		r = VTCompressionSessionPrepareToEncodeFrames(s);
		if (r) fprintf(stderr, "PrepareToEncodeFrames -> %d\n", (int)r);

		OSType pf = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
		NSDictionary *pba = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
		uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		int i;
		uint64_t tlast = t0;
		for (i = 0; seconds > 0 || i < frames; i++) {
			if (seconds > 0) {
				uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				if ((now - t0) / 1e9 >= seconds) break;
				if ((now - tlast) / 1e9 >= 30) { tlast = now; printf("t %.0f s: %d in, %lld out, %lld errors, %.1f fps, footprint %.1f MB\n", (now - t0) / 1e9, i, emitted, errors, i / ((now - t0) / 1e9), footprint_mb()); fflush(stdout); }
			}
			CVPixelBufferRef pb = NULL;
			// the session's pool when it hands out the source format (what OBS/HandBrake/AVAssetWriter use), else our own
			static CVPixelBufferPoolRef own;
			CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(s);
			if (pool && !CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb) && CVPixelBufferGetPixelFormatType(pb) != pf) { CVPixelBufferRelease(pb); pb = NULL; }
			if (!pb) {
				if (!own) {
					NSDictionary *pa = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(pf), (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(hh),
					                      (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
					CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)pa, &own);
				}
				if (!own || CVPixelBufferPoolCreatePixelBuffer(NULL, own, &pb)) { fprintf(stderr, "CVPixelBufferCreate failed\n"); return 1; }
			}
			CVPixelBufferLockBaseAddress(pb, 0);
			const uint8_t *f = raw + fsz * (i % nraw);
			size_t bpp = ten ? 2 : 1;
			for (int p = 0; p < 2; p++) {
				uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pb, p); size_t pitch = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
				int rows = p ? hh / 2 : hh; const uint8_t *srcp = f + (p ? (size_t)w * hh * bpp : 0);
				for (int y = 0; y < rows; y++) memcpy(dst + y * pitch, srcp + (size_t)y * w * bpp, w * bpp);
			}
			CVPixelBufferUnlockBaseAddress(pb, 0);
			CMTime pts = CMTimeMake((int64_t)i * 1000, (int32_t)(fps * 1000)), dur = CMTimeMake(1000, (int32_t)(fps * 1000));
			VTEncodeInfoFlags fl = 0;
			r = VTCompressionSessionEncodeFrame(s, pb, pts, dur, NULL, NULL, &fl);
			CVPixelBufferRelease(pb);
			if (r) { fprintf(stderr, "EncodeFrame %d -> %d\n", i, (int)r); errors++; break; }
		}
		r = VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
		uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		if (r) fprintf(stderr, "CompleteFrames -> %d\n", (int)r);
		VTCompressionSessionInvalidate(s); CFRelease(s);
		if (out) fclose(out);
		frames = i;
		double sec = (t1 - t0) / 1e9;
		printf("RESULT %s %dx%d: %lld/%d frames out, %lld key, %lld bytes (%.0f kbit/s at %.0f fps), %lld errors, %.1f fps wall\n",
		       pos[0], w, hh, emitted, frames, keys, bytes, bytes * 8.0 / 1000 / (frames / fps), fps, errors, frames / sec);
		printf("footprint %.1f MB, encoder %s\n", footprint_mb(), g_encid);
		return errors ? 1 : 0;
	}
}
