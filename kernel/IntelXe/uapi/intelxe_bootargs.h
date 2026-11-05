// SPDX-License-Identifier: MIT
/* Boot-arg names of IntelXe.kext, IntelXeFB.kext, NMXAccel and NMXAGDC, and the names they had before the stack was
 * renamed from B580 to IntelXe (release 0.1.0). For this one release a kext still takes the old name when the new
 * one is absent and logs, once per old name, that it is deprecated; the release after it reads the new names only.
 * Values and meanings are unchanged. Kernel-only (included by the kexts, not by user space). */
#ifndef INTELXE_BOOTARGS_H
#define INTELXE_BOOTARGS_H
#include <IOKit/IOLib.h>
#include <libkern/OSAtomic.h>
#include <pexpert/pexpert.h>
#include <string.h>

/* PE_parse_boot_argn(name, val, size); if `name` is absent, its old name. `who` prefixes the deprecation message. */
static inline bool intelxeBootArg(const char *who, const char *name, void *val, int size)
{
	static const struct { const char *name, *old; } kOld[] = {
		{"-intelxe_off", "-b580off"},                         // intelxe-rename: keep
		{"-intelxe_nohugepages", "-b580nohugepages"},         // intelxe-rename: keep
		{"-intelxe_novideo", "-b580novideo"},                 // intelxe-rename: keep
		{"-intelxe_nousm", "-b580nousm"},                     // intelxe-rename: keep
		{"-intelxe_lrcsys", "-b580lrcsys"},                   // intelxe-rename: keep
		{"-intelxe_vcssingle", "-b580vcssingle"},             // intelxe-rename: keep
		{"-intelxe_nowhitelist", "-b580nowhitelist"},         // intelxe-rename: keep
		{"-intelxe_lazy", "-b580lazy"},                       // intelxe-rename: keep
		{"-intelxe_nometal", "-b580nometal"},                 // intelxe-rename: keep
		{"intelxe_surfvram", "b580surfvram"},                 // intelxe-rename: keep
		{"intelxe_svwsfull", "b580svwsfull"},                 // intelxe-rename: keep
		{"intelxe_fds", "b580fds"},                           // intelxe-rename: keep
		{"-intelxe_nofb", "-b580nofb"},                       // intelxe-rename: keep
		{"-intelxe_noaccel", "-b580noaccel"},                 // intelxe-rename: keep
		{"-intelxefb_off", "-b580fboff"},                     // intelxe-rename: keep
		{"-intelxefb_noedidfix", "-b580fbnoedidfix"},         // intelxe-rename: keep
		{"-intelxefb_noscale", "-b580fbnoscale"},             // intelxe-rename: keep
		{"-intelxefb_norates", "-b580fbnorates"},             // intelxe-rename: keep
		{"-intelxefb_edidonly", "-b580fbedidonly"},           // intelxe-rename: keep
		{"-intelxefb_nogamma", "-b580fbnogamma"},             // intelxe-rename: keep
		{"-intelxefb_novrr", "-b580fbnovrr"},                 // intelxe-rename: keep
		{"-intelxefb_nohwcursor", "-b580fbnohwcursor"},       // intelxe-rename: keep
		{"-intelxefb_noirq", "-b580fbnoirq"},                 // intelxe-rename: keep
		{"intelxefb_vrr", "b580fbvrr"},                       // intelxe-rename: keep
		{"intelxefb_vrrmodes", "b580fbvrrmodes"},             // intelxe-rename: keep
	};
	static volatile UInt32 warned;   // bit i: kOld[i]'s deprecation was logged
	if (PE_parse_boot_argn(name, val, size)) return true;
	for (UInt32 i = 0; i < sizeof kOld / sizeof kOld[0]; i++) {
		if (strcmp(kOld[i].name, name)) continue;
		if (!PE_parse_boot_argn(kOld[i].old, val, size)) return false;
		if (!(OSBitOrAtomic(1u << i, &warned) & (1u << i)))
			IOLog("%s: boot-arg %s is deprecated, use %s (the old name is read in this release only)\n", who, kOld[i].old,
			      name);
		return true;
	}
	return false;
}
#endif
