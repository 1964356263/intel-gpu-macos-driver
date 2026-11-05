// SPDX-License-Identifier: MIT
// Virtual USB mouse: nudges the pointer (or clicks) N times, one report every 100 ms (or every argv[3] us), so display wake on real HID input can be
// tested without anyone at the machine. Needs com.apple.developer.hid.virtual.device (ad-hoc entitlement, AMFI off).
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const uint8_t kDesc[] = {
	0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
	0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
	0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
	0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
	0xC0, 0xC0,
};

static void num(CFMutableDictionaryRef d, CFStringRef k, int v) {
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}

int main(int argc, char **argv) {
	int n = argc > 1 ? atoi(argv[1]) : 10;
	int click = argc > 2 && argv[2][0] == 'c';   // "click": press and release the left button instead of moving
	int us = argc > 3 ? atoi(argv[3]) : 100000;   // microseconds between reports
	CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDataRef desc = CFDataCreate(NULL, kDesc, sizeof(kDesc));
	CFDictionarySetValue(p, CFSTR(kIOHIDReportDescriptorKey), desc);
	num(p, CFSTR(kIOHIDVendorIDKey), 0x05ac);
	num(p, CFSTR(kIOHIDProductIDKey), 0x0b58);
	CFDictionarySetValue(p, CFSTR(kIOHIDTransportKey), CFSTR("USB"));
	CFDictionarySetValue(p, CFSTR(kIOHIDProductKey), CFSTR("B580 test mouse"));
	IOHIDUserDeviceRef dev = IOHIDUserDeviceCreateWithProperties(NULL, p, 0);
	if (!dev) { fprintf(stderr, "IOHIDUserDeviceCreate failed (entitlement?)\n"); return 1; }
	IOHIDUserDeviceSetDispatchQueue(dev, dispatch_queue_create("vmouse", NULL));
	IOHIDUserDeviceActivate(dev);
	sleep(2);   // let the HID event system attach the service
	for (int i = 0; i < n; i++) {
		int8_t dx = (i & 1) ? -20 : 20;
		uint8_t r[3] = {0, (uint8_t)dx, 0};
		if (click) { r[0] = (i & 1) ? 0 : 1; r[1] = 0; }
		IOReturn e = IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), r, sizeof(r));
		if (e) fprintf(stderr, "report %d: 0x%x\n", i, e);
		usleep(us);
	}
	printf("sent %d reports\n", n);
	IOHIDUserDeviceCancel(dev);
	sleep(1);
	CFRelease(dev);
	return 0;
}
