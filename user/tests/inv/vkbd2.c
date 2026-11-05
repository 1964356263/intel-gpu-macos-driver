// SPDX-License-Identifier: MIT
// Virtual USB keyboard (IOHIDUserDevice, boot-protocol report), based on user/tests/kernel/vmouse.c. Needs the
// com.apple.developer.hid.virtual.device entitlement (ad-hoc signed with vmouse.ent, AMFI off).
//   vkbd step...      t:text   type letters/digits/space (US key positions; avoid i and punctuation on Turkish Q)
//                     k:cmd+space | k:cmd+a | k:esc | k:right | k:left | k:bs | k:enter   one key chord
//                     w:ms     wait
//   env GAP=ms between keys (default 120), HOLD=ms a key stays down (default 30)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>

static const uint8_t kDesc[] = {   // standard boot keyboard: modifiers, reserved, 6 keys
	0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
	0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
	0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
	0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
	0xC0,
};
static IOHIDUserDeviceRef dev;
static int gap = 120, hold = 30;
static void num(CFMutableDictionaryRef d, CFStringRef k, int v) {
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}
static void report(uint8_t mods, uint8_t key) {
	uint8_t r[8] = {mods, 0, key, 0, 0, 0, 0, 0};
	IOReturn e = IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), r, sizeof(r));
	if (e) fprintf(stderr, "report: 0x%x\n", e);
}
static void press(uint8_t mods, uint8_t key) {
	if (mods) { report(mods, 0); usleep(15000); }
	report(mods, key); usleep(hold * 1000);
	report(mods, 0);
	if (mods) { usleep(15000); report(0, 0); }
	usleep(gap * 1000);
}
static uint8_t usage(char c) {
	if (c >= 'a' && c <= 'z') return 0x04 + (c - 'a');
	if (c >= '1' && c <= '9') return 0x1E + (c - '1');
	if (c == '0') return 0x27;
	if (c == ' ') return 0x2C;
	return 0;
}
int main(int argc, char **argv) {
	if (getenv("GAP")) gap = atoi(getenv("GAP"));
	if (getenv("HOLD")) hold = atoi(getenv("HOLD"));
	CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDataRef desc = CFDataCreate(NULL, kDesc, sizeof(kDesc));
	CFDictionarySetValue(p, CFSTR(kIOHIDReportDescriptorKey), desc);
	num(p, CFSTR(kIOHIDVendorIDKey), 0x05ac);
	num(p, CFSTR(kIOHIDProductIDKey), 0x024f);
	num(p, CFSTR(kIOHIDCountryCodeKey), 0);
	CFDictionarySetValue(p, CFSTR(kIOHIDTransportKey), CFSTR("USB"));
	CFDictionarySetValue(p, CFSTR(kIOHIDProductKey), CFSTR("B580 test keyboard"));
	dev = IOHIDUserDeviceCreateWithProperties(NULL, p, 0);
	if (!dev) { fprintf(stderr, "IOHIDUserDeviceCreate failed (entitlement?)\n"); return 1; }
	IOHIDUserDeviceSetDispatchQueue(dev, dispatch_queue_create("vkbd", NULL));
	IOHIDUserDeviceActivate(dev);
	sleep(2);
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strncmp(a, "t:", 2)) {
			for (const char *c = a + 2; *c; c++) if (usage(*c)) press(0, usage(*c));
		} else if (!strncmp(a, "s:", 2)) {   // panel thumbnail (debug.intelxefb_thumb) as a binary PPM
			static uint8_t b[320 * 180 * 4]; size_t n = sizeof b;
			if (sysctlbyname("debug.intelxefb_thumb", b, &n, NULL, 0)) { perror("thumb"); continue; }
			FILE *f = fopen(a + 2, "wb"); if (!f) { perror(a + 2); continue; }
			fprintf(f, "P6\n320 180\n255\n");
			for (int i = 0; i < 320 * 180; i++) { uint8_t px[3] = { b[i*4+2], b[i*4+1], b[i*4] }; fwrite(px, 1, 3, f); }
			fclose(f);
		} else if (!strncmp(a, "f:", 2)) {   // create (f:+path) or remove (f:-path) a flag file
			if (a[2] == '+') { FILE *f = fopen(a + 3, "w"); if (f) fclose(f); } else unlink(a + 3);
		} else if (!strncmp(a, "w:", 2)) {
			usleep(atoi(a + 2) * 1000);
		} else if (!strncmp(a, "k:", 2)) {
			const char *k = a + 2; uint8_t m = 0;
			for (;;) {   // modifiers: cmd+ shift+ ctrl+ opt+ (left keys), any order
				if (!strncmp(k, "cmd+", 4)) { m |= 0x08; k += 4; } else if (!strncmp(k, "shift+", 6)) { m |= 0x02; k += 6; }
				else if (!strncmp(k, "ctrl+", 5)) { m |= 0x01; k += 5; } else if (!strncmp(k, "opt+", 4)) { m |= 0x04; k += 4; } else break; }
			uint8_t u = !strcmp(k, "space") ? 0x2C : !strcmp(k, "esc") ? 0x29 : !strcmp(k, "right") ? 0x4F : !strcmp(k, "left") ? 0x50
			          : !strcmp(k, "bs") ? 0x2A : !strcmp(k, "enter") ? 0x28 : !strcmp(k, "up") ? 0x52 : !strcmp(k, "down") ? 0x51 : (strlen(k) == 1 ? usage(k[0]) : 0);
			if (!u) { fprintf(stderr, "unknown key %s\n", k); continue; }
			press(m, u);
		}
	}
	usleep(200000);
	IOHIDUserDeviceCancel(dev);
	usleep(300000);
	CFRelease(dev);
	return 0;
}
