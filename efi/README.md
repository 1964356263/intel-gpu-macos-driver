# OpenCore notes

This directory holds notes only: no `config.plist`, no SMBIOS data and no ACPI tables. These are the settings the B580 stack depends on, as used on the development machine: an Intel Z790 desktop with an i7/UHD 770 iGPU and an Arc B580 in the x16 slot, running macOS 26 (x86_64) through OpenCore.

## Firmware (BIOS)

- **Above 4G decoding and Resizable BAR on.** The firmware then gives the B580 a 16 GB BAR2.
- **iGPU Multi-Monitor (iGPU kept on while a dGPU drives the display) enabled.** Optional. With it, the UHD 770 stays available headless for Quick Sync / VideoToolbox.

## Booter quirks

- **`ResizeAppleGpuBars = 10`** (2^10 MB = 1 GB). macOS cannot map a 16 GB BAR, so without this quirk BAR2 stays unassigned. With `0` (256 MB) the driver also works, but the CPU-visible VRAM window is smaller. IntelXe.kext reads the window size from BAR2's length. VRAM beyond the window is used for buffers the CPU does not map, and allocations that do not fit spill to system memory.

## Kernel quirks

- **`DisableIoMapper = true`.** Keep it.
  - IntelXe.kext's DMA goes through `IODMACommand` and is ready for VT-d.
  - Other kexts on such systems are not: AppleIGC uses raw physical DMA, and WhateverXe has physical GGTT paths.

## ACPI

- **An SSDT that sets the B580's `class-code` to `FFFFFFFF`** (here: `SSDT-ARCOFF`). It keeps `IONDRVFramebuffer` and Apple's display drivers off the card.
  - `IOPCIMatch` still lets IntelXe.kext match.
  - Once IntelXeFB holds the IOFramebuffer category, it writes a display class code back to the PCI nub, because IOPresentment's GPU node match needs one.

## Kext placement

| Kext | Where | Why |
|---|---|---|
| `IntelXe.kext` | OpenCore `Kernel > Add` (EFI), `OSBundleRequired = Root` | plain IOKit, no Lilu; matches `8086:e20b`, brings the GPU up at start |
| `IntelXeFB.kext` | `/Library/Extensions` + Auxiliary KC | links IOGraphicsFamily, which is not available to OpenCore-injected kexts at that stage; matches at boot from the AuxKC |
| `NMXAccel.kext`, `NMXAGDC.kext` | `/Library/Extensions` + Auxiliary KC | IOAccelerator and AppleGraphicsDeviceControl services for WindowServer |
| `NVMTLDriver.bundle` | `/Library/GPUBundles/` | Metal driver plugin; `/Library/GPUBundles/nvmtl/` holds `intel_icd.json` + `libvulkan_intel.dylib`, and `/Library/GPUBundles/nvmtl-allow.txt` the allow-list |

Rebuild the AuxKC after changing any of the AuxKC kexts (`kmutil create` with all `/Library/Extensions` kexts, as nullmoth's installer does), then reboot.

**Recovery:** Shift+Enter in the OpenCore picker boots safe mode, which skips the AuxKC. Keep a known-good EFI on a USB stick.

## Security settings

- **SIP must allow unsigned kexts:** `csr-active-config` `0x803` (custom), so no approval dialog appears.
- **Boot-args `amfi_get_out_of_my_way=0x1 amfi=0x80`:**
  - used during development, so WindowServer accepts the ad-hoc-signed Metal plugin;
  - also for the virtual HID test tools (entitlements);
  - meant to be removed once the plugin is signed properly.

## Driver boot-args (all optional)

| Boot-arg | Effect |
|---|---|
| `-intelxe_off` | IntelXe.kext does nothing |
| `-intelxe_nometal` | no `nmxgpu-claimed` / NMXAccel |
| `-intelxe_novideo` | no media GT |
| `-intelxe_noaccel` | no in-kernel arming of acceleration |
| `-intelxe_lazy` | bring-up on first use instead of at start |
| `-intelxe_nohugepages` | 4 KB page-table leaves only |
| `-intelxe_nofb` / `-intelxefb_off` | IntelXeFB stays off |
| `-intelxefb_noscale`, `-intelxefb_norates`, `-intelxefb_novrr`, `-intelxefb_nohwcursor`, `-intelxefb_nogamma`, `-intelxefb_noirq`, `-intelxefb_noedidfix` | turn off single IntelXeFB features |
| `intelxefb_vrr=`, `intelxefb_vrrmodes=` | VRR policy |
| `-nvoff` | NMXAccel stays off |
| `nmxgamma=`, `nmxearlyreg=` | NMXAccel gamma / early registration |

NVRAM variables: `intelxefb-vrr-modes` (1 = publish Adaptive-Sync modes), `intelxe-guard` / `intelxe-accel-off` (panic-loop guard of the boot-time arming).

Before 0.1.0 (private builds) these boot-args started with `b580` (`-b580off`, `b580surfvram=`, `-b580fbnovrr`, ...; the full list is in <!-- intelxe-rename: keep -->
`kernel/IntelXe/uapi/intelxe_bootargs.h`). Release 0.1.x still reads an earlier name when the new one is absent and
logs once that it is deprecated; later releases read only the names above. The NVRAM variables have only the new names. <!-- intelxe-rename: keep -->
