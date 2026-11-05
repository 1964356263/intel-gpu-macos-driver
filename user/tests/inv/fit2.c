// SPDX-License-Identifier: MIT
// fit2 <icon.rgba (premultiplied RGBA8, w h header)> <crop.ppm> x0lo x0hi y0lo y0hi qlo qhi
// for each filter model, the tile size/position with the least error against the panel crop (opaque icon pixels only)
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
static int S, L; static float *lv[12];
static float tx(int l, int x, int y, int c) { int s = S >> l; if (s < 1) s = 1; x = x < 0 ? 0 : x >= s ? s - 1 : x; y = y < 0 ? 0 : y >= s ? s - 1 : y; return lv[l][((size_t)y * s + x) * 4 + c]; }
static float bil(int l, float u, float v, int c) { int s = S >> l; float fx = u * s - .5f, fy = v * s - .5f; int x0 = floorf(fx), y0 = floorf(fy); float ax = fx - x0, ay = fy - y0;
	return (1-ay)*((1-ax)*tx(l,x0,y0,c)+ax*tx(l,x0+1,y0,c)) + ay*((1-ax)*tx(l,x0,y0+1,c)+ax*tx(l,x0+1,y0+1,c)); }
static float model(int m, float u, float v, int c, float lod) {
	if (m == 0) return bil(0, u, v, c);                                   // bilinear, level 0 only
	if (m == 1) { if (lod < 0) lod = 0; int l0 = floorf(lod); float f = lod - l0; if (l0 + 1 >= L) return bil(L - 1, u, v, c); return (1-f)*bil(l0,u,v,c)+f*bil(l0+1,u,v,c); } // trilinear
	if (m == 2) return tx(0, (int)floorf(u * S), (int)floorf(v * S), c);   // nearest
	if (m == 3) { int l = (int)floorf(lod + 0.5f); if (l < 0) l = 0; if (l >= L) l = L - 1; return bil(l, u, v, c); } // bilinear, nearest mip
	return 0;
}
int main(int argc, char **argv) {
	FILE *f = fopen(argv[1], "rb"); int w, h; fread(&w, 4, 1, f); fread(&h, 4, 1, f); S = w; uint8_t *p = malloc((size_t)w * h * 4); fread(p, 4, (size_t)w * h, f); fclose(f);
	lv[0] = malloc((size_t)S * S * 16); for (size_t i = 0; i < (size_t)S * S * 4; i++) lv[0][i] = p[i] / 255.f;
	for (L = 1; (S >> L) >= 1; L++) { int s = S >> L, ps = 2 * s; lv[L] = malloc((size_t)s * s * 16); for (int y = 0; y < s; y++) for (int x = 0; x < s; x++) for (int c = 0; c < 4; c++)
		lv[L][(y*s+x)*4+c] = .25f * (lv[L-1][((2*y)*ps+2*x)*4+c] + lv[L-1][((2*y)*ps+2*x+1)*4+c] + lv[L-1][((2*y+1)*ps+2*x)*4+c] + lv[L-1][((2*y+1)*ps+2*x+1)*4+c]); }
	f = fopen(argv[2], "rb"); char mg[3]; int cw, ch, mx; fscanf(f, "%2s %d %d %d", mg, &cw, &ch, &mx); fgetc(f); uint8_t *d = malloc((size_t)cw * ch * 3); fread(d, 3, (size_t)cw * ch, f); fclose(f);
	int x0lo = atoi(argv[3]), x0hi = atoi(argv[4]), y0lo = atoi(argv[5]), y0hi = atoi(argv[6]), qlo = atoi(argv[7]), qhi = atoi(argv[8]);
	const char *nm[4] = { "bilinear level 0", "trilinear", "nearest", "bilinear nearest-mip" };
	for (int m = 0; m < 4; m++) {
		double best = 1e9; int bq = 0, bx = 0, by = 0, bn = 0;
		for (int q = qlo; q <= qhi; q++) for (int x0 = x0lo; x0 <= x0hi; x0++) for (int y0 = y0lo; y0 <= y0hi; y0++) {
			float lod = log2f((float)S / q); double e = 0; int n = 0;
			for (int y = 0; y < q; y++) for (int x = 0; x < q; x++) {
				float u = (x + .5f) / q, v = (y + .5f) / q;
				if (model(1, u, v, 3, lod) < 0.999f) continue;   // opaque icon pixels only
				int px = x0 + x, py = y0 + y; if (px < 0 || py < 0 || px >= cw || py >= ch) { n = 0; goto skip; }
				for (int c = 0; c < 3; c++) e += fabsf(model(m, u, v, c, lod) * 255.f - d[((size_t)py * cw + px) * 3 + c]);
				n++;
			}
			if (n > 200 && e / (n * 3) < best) { best = e / (n * 3); bq = q; bx = x0; by = y0; bn = n; }
			skip:;
		}
		printf("%-22s best mean |diff| %.2f at tile %d px, x %d y %d (%d px)\n", nm[m], best, bq, bx, by, bn);
	}
	return 0;
}
