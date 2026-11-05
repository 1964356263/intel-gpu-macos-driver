// SPDX-License-Identifier: MIT
// sigcheck FILE...: is each Mach-O (thin or fat, every slice) code-signed? Checks for LC_CODE_SIGNATURE and that it points
// at an embedded-signature SuperBlob holding a CodeDirectory, the minimum dyld needs ("Code has to be at least ad-hoc
// signed"). No Apple tools needed, so install scripts can run it on the B580 machine. Exit 0 only if all are signed.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <libkern/OSByteOrder.h>
static int slice(FILE *f, long base, const char *path) {
	struct mach_header_64 h;
	if (fseek(f, base, SEEK_SET) || fread(&h, sizeof h, 1, f) != 1 || h.magic != MH_MAGIC_64) { printf("%s: not a 64-bit Mach-O\n", path); return 1; }
	long off = base + sizeof h;
	for (uint32_t i = 0; i < h.ncmds; i++) {
		struct load_command lc;
		if (fseek(f, off, SEEK_SET) || fread(&lc, sizeof lc, 1, f) != 1) break;
		if (lc.cmd == LC_CODE_SIGNATURE) {
			struct linkedit_data_command cs; uint32_t sb[3], idx[2];
			if (fseek(f, off, SEEK_SET) || fread(&cs, sizeof cs, 1, f) != 1) break;
			if (fseek(f, base + cs.dataoff, SEEK_SET) || fread(sb, sizeof sb, 1, f) != 1) break;
			if (OSSwapBigToHostInt32(sb[0]) != 0xfade0cc0) { printf("%s: LC_CODE_SIGNATURE without an embedded signature\n", path); return 1; }
			uint32_t n = OSSwapBigToHostInt32(sb[2]);
			for (uint32_t k = 0; k < n; k++) {
				uint32_t magic;
				if (fseek(f, base + cs.dataoff + 12 + 8 * k, SEEK_SET) || fread(idx, sizeof idx, 1, f) != 1) break;
				if (fseek(f, base + cs.dataoff + OSSwapBigToHostInt32(idx[1]), SEEK_SET) || fread(&magic, 4, 1, f) != 1) break;
				if (OSSwapBigToHostInt32(magic) == 0xfade0c02) { printf("%s: signed (CodeDirectory present)\n", path); return 0; }
			}
			printf("%s: signature has no CodeDirectory\n", path); return 1;
		}
		off += lc.cmdsize;
	}
	printf("%s: NOT SIGNED (no LC_CODE_SIGNATURE)\n", path);
	return 1;
}
int main(int argc, char **argv) {
	int bad = 0;
	for (int a = 1; a < argc; a++) {
		FILE *f = fopen(argv[a], "rb"); uint32_t m;
		if (!f || fread(&m, 4, 1, f) != 1) { printf("%s: cannot read\n", argv[a]); bad++; if (f) fclose(f); continue; }
		if (OSSwapBigToHostInt32(m) == FAT_MAGIC) {
			struct fat_header fh; fseek(f, 0, SEEK_SET); fread(&fh, sizeof fh, 1, f);
			for (uint32_t i = 0; i < OSSwapBigToHostInt32(fh.nfat_arch); i++) {
				struct fat_arch fa; fseek(f, sizeof fh + i * sizeof fa, SEEK_SET); fread(&fa, sizeof fa, 1, f);
				bad += slice(f, OSSwapBigToHostInt32(fa.offset), argv[a]);
			}
		} else bad += slice(f, 0, argv[a]);
		fclose(f);
	}
	return bad ? 1 : 0;
}
