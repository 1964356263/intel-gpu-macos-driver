// SPDX-License-Identifier: MIT
// xbench: time (and sample) the in-process translator on .ll files: xbench <dylib> <reps> <stage> file.ll...
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <mach/mach_time.h>
typedef int (*tr_fn)(const char *, const char *, uint8_t **, size_t *, char *, size_t);
typedef void (*fr_fn)(uint8_t *, size_t);
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) {
	if (argc < 5) return 2;
	void *h = dlopen(argv[1], RTLD_NOW); if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
	tr_fn tr = (tr_fn)dlsym(h, "nvmtl_translate"); fr_fn fr = (fr_fn)dlsym(h, "nvmtl_translate_free");
	void (*caps)(uint32_t) = (void (*)(uint32_t))dlsym(h, "nvmtl_translate_set_caps"); if (caps) caps(3);
	const int reps = atoi(argv[2]);
	for (int a = 4; a < argc; a++) {
		FILE *f = fopen(argv[a], "rb"); if (!f) continue; fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
		char *s = malloc(n + 1); fread(s, 1, n, f); s[n] = 0; fclose(f);
		double best = 1e9, sum = 0; int rc = 0; size_t outn = 0;
		for (int r = 0; r < reps; r++) { uint8_t *o = NULL; size_t on = 0; char e[512] = ""; double t0 = now_ms(); rc = tr(s, argv[3], &o, &on, e, sizeof e); double t = now_ms() - t0;
			if (t < best) best = t; sum += t; outn = on; if (o && fr) fr(o, on); }
		printf("%-40s rc %d out %zu  best %.1f ms  mean %.1f ms\n", argv[a], rc, outn, best, sum / reps);
		free(s);
	}
	return 0;
}
