// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
	FILE *f = fopen(argv[1], "rb"); int w, h; fread(&w, 4, 1, f); fread(&h, 4, 1, f); uint8_t *p = malloc((size_t)w * h * 4); fread(p, 4, (size_t)w * h, f); fclose(f);
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef s = CGBitmapContextCreate(p, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGImageRef img = CGBitmapContextCreateImage(s);
	const int q[5] = { kCGInterpolationDefault, kCGInterpolationNone, kCGInterpolationLow, kCGInterpolationMedium, kCGInterpolationHigh };
	const char *nm[5] = { "default", "none", "low", "medium", "high" };
	for (int i = 0; i < 5; i++) {
		int o = 64; uint8_t *d = calloc(o * o, 4);
		CGContextRef c = CGBitmapContextCreate(d, o, o, 8, o * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
		CGContextSetInterpolationQuality(c, q[i]); CGContextDrawImage(c, CGRectMake(0, 0, o, o), img);
		char fn[64]; snprintf(fn, sizeof fn, "cg_%s.rgba", nm[i]); FILE *g = fopen(fn, "wb"); fwrite(&o, 4, 1, g); fwrite(&o, 4, 1, g); fwrite(d, 4, o * o, g); fclose(g);
	}
	return 0; } }
