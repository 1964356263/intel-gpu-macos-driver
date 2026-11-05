// SPDX-License-Identifier: MIT
// fbcrop: a 256x128 full-resolution window of the panel's live scan-out surface (IntelXeFB debug.intelxefb_crop) as a PPM.
//   clang -arch x86_64 -O1 -o fbcrop fbcrop.c
//   sudo ./fbcrop X Y out.ppm
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: fbcrop X Y out.ppm\n"); return 2; }
	uint32_t xy = (uint32_t)atoi(argv[1]) << 16 | ((uint32_t)atoi(argv[2]) & 0xFFFF);
	if (sysctlbyname("debug.intelxefb_cropxy", NULL, NULL, &xy, sizeof(xy))) { perror("cropxy"); return 1; }
	static uint32_t px[256 * 128];
	size_t len = sizeof(px);
	if (sysctlbyname("debug.intelxefb_crop", px, &len, NULL, 0) || len != sizeof(px)) { perror("crop"); return 1; }
	FILE *f = fopen(argv[3], "wb");
	if (!f) { perror("out"); return 1; }
	fprintf(f, "P6\n256 128\n255\n");
	for (int i = 0; i < 256 * 128; i++) { uint8_t rgb[3] = {(uint8_t)(px[i] >> 16), (uint8_t)(px[i] >> 8), (uint8_t)px[i]}; fwrite(rgb, 1, 3, f); }
	fclose(f);
	return 0;
}
