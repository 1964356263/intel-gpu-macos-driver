# intel-gpu-macos-driver 0.1.0 for macOS 26 Tahoe (Intel Arc B580)

Experimental. Tested on one machine only: an Arc B580 in a Z790 desktop, macOS 26.7.1, OpenCore. Unsigned, unsupported,
and it changes how your Mac boots. **Keep a USB stick with a working EFI before you start**, and know how to boot it.
Noncommercial use only (see `LICENSES/`).

What you get when it works: the desktop composited on the B580 with Metal (window dragging at the monitor's refresh
rate, up to 180 Hz tested), Metal apps and games, VideoToolbox decode (H.264, HEVC, AV1, VP9) and encode (H.264, HEVC,
AV1) on the GPU, one DisplayPort monitor with VRR, sleep and wake.
Known issues: Safari's GPU process and the Dock's helper stay on macOS's software path (listed in
`Library/GPUBundles/nvmtl-allow.txt`); the first seconds after the first login stutter while shaders are translated.

**Upgrading from a package with the earlier names?** The stack was renamed from B580 to IntelXe: `B580.kext` is now
`IntelXe.kext`, `B580FB.kext` is `IntelXeFB.kext`, and the boot-args start with `intelxe_` (table in step 2.4). Do both
halves before you reboot: swap the kext in your EFI (step 2.2) **and** run `install.sh --apply` (step 3), which backs up
and removes `B580FB.kext`. With only one of the two, macOS comes up without the driver (safe mode or your USB EFI gets
you back). If you installed the system-volume copy of the earlier release, update it too (step 4).

## Contents

| Path | Goes to |
|---|---|
| `EFI/OC/Kexts/IntelXe.kext` | your OpenCore EFI, `Kernel > Add` (the GPU driver: GuC/HuC firmware included) |
| `EFI/OC/ACPI/SSDT-ARCOFF.aml`, `.dsl` | your OpenCore EFI, `ACPI > Add`, **after adapting the ACPI path** (below) |
| `Library/Extensions/IntelXeFB.kext`, `NMXAccel.kext`, `NMXAGDC.kext` | `/Library/Extensions` (display, accelerator), via `install.sh` |
| `Library/GPUBundles/NVMTLDriverLib.bundle`, `nvmtl/`, `nvmtl-allow.txt` | `/Library/GPUBundles` (Metal driver, Mesa, codecs), via `install.sh` |
| `system-volume/` | optional: the copy of the Metal driver on the system volume (needed only for Safari WebGL; see below) |
| `SHA256SUMS`, `sigcheck` | the checks `install.sh` runs |

## 1. Firmware (BIOS) settings

Above 4G decoding **on**, Resizable BAR **on**. The monitor is connected to the B580 (DisplayPort).

## 2. OpenCore

1. `ACPI > Add`: `SSDT-ARCOFF.aml`. It hides the card from macOS's own display driver (on Tahoe that driver otherwise
   takes the card and the IntelXe kexts cannot start). **The ACPI path is board-specific**: the table declares the B580
   under `\_SB.PC00.PEG1.PEGP` with the card's own PCIe switch in between (`BRG1` at `_ADR 0x00010000`, then `GFX0`).
   Find your card's path (IORegistryExplorer, or `gfxutil -f GFX0`), edit `SSDT-ARCOFF.dsl` and compile it with
   `iasl SSDT-ARCOFF.dsl`.
2. `Kernel > Add`: `IntelXe.kext` (`BundlePath IntelXe.kext`, `ExecutablePath Contents/MacOS/IntelXe`,
   `PlistPath Contents/Info.plist`, `Enabled true`).
   **Upgrading:** replace `B580.kext` with `IntelXe.kext`: delete `EFI/OC/Kexts/B580.kext`, copy `IntelXe.kext` in its
   place, and change its `Kernel > Add` entry to the paths above (or remove that entry and add the new one). Only one of
   the two may be in your EFI.
3. `Booter > Quirks > ResizeAppleGpuBars = 10`, `Kernel > Quirks > DisableIoMapper = true`.
4. `NVRAM > 7C436110-AB2A-4BBB-A880-FE41995C9F82`:
   - `csr-active-config` = `03080000` (data; SIP relaxed for unsigned kexts in the Auxiliary Kernel Collection);
   - `boot-args` add `amfi_get_out_of_my_way=0x1` (WindowServer refuses the unsigned Metal driver otherwise) and
     `intelxe_surfvram=2` (IOSurfaces shared in VRAM between processes; leave it out to compare);
   - **upgrading:** rename the driver's boot-args. This release still reads the earlier names when the new one is
     absent and logs `boot-arg ... is deprecated` once per name (`log show --last boot --predicate 'eventMessage
     CONTAINS "is deprecated"'`); the next release reads only the new names. Values and meanings are unchanged:

     | Earlier name | New name |
     |---|---|
     | `b580surfvram=N`, `b580svwsfull=N`, `b580fds=N` | `intelxe_surfvram=N`, `intelxe_svwsfull=N`, `intelxe_fds=N` |
     | `-b580off`, `-b580lazy`, `-b580nometal`, `-b580novideo`, `-b580nohugepages`, `-b580nousm`, `-b580lrcsys`, `-b580vcssingle`, `-b580nowhitelist` | `-intelxe_off`, `-intelxe_lazy`, `-intelxe_nometal`, `-intelxe_novideo`, `-intelxe_nohugepages`, `-intelxe_nousm`, `-intelxe_lrcsys`, `-intelxe_vcssingle`, `-intelxe_nowhitelist` |
     | `-b580nofb`, `-b580noaccel` | `-intelxe_nofb`, `-intelxe_noaccel` |
     | `-b580fboff`, `-b580fbnoscale`, `-b580fbnorates`, `-b580fbedidonly`, `-b580fbnogamma`, `-b580fbnovrr`, `-b580fbnohwcursor`, `-b580fbnoirq`, `-b580fbnoedidfix` | `-intelxefb_off`, `-intelxefb_noscale`, `-intelxefb_norates`, `-intelxefb_edidonly`, `-intelxefb_nogamma`, `-intelxefb_novrr`, `-intelxefb_nohwcursor`, `-intelxefb_noirq`, `-intelxefb_noedidfix` |
     | `b580fbvrr=N`, `b580fbvrrmodes=N` | `intelxefb_vrr=N`, `intelxefb_vrrmodes=N` |

     NVRAM settings and sysctls have only the new names: the variable `b580fb-vrr-modes` is now `intelxefb-vrr-modes`,
     `debug.b580.*` is `debug.intelxe.*`, `debug.b580fb_*` is `debug.intelxefb_*`. The boot guard starts afresh under
     `intelxe-guard` / `intelxe-accel-off`; the earlier variables are not read any more and can be deleted:
     `sudo nvram -d b580-guard; sudo nvram -d b580-accel-off; sudo nvram -d b580-shutdown; sudo nvram -d b580fb-shutdown`.
   - for the optional system-volume copy only: `Misc > Security > SecureBootModel = Disabled`.
5. Reboot. macOS comes up on the B580 without acceleration (IntelXe.kext only). Check: `kmutil showloaded | grep IntelXe`.

## 3. The /Library part

```sh
./install.sh            # checks only: macOS, SIP, AMFI, the card, IntelXe.kext, checksums, signatures
sudo ./install.sh --apply
```

When upgrading, `--apply` also backs up and removes `/Library/Extensions/B580FB.kext` (two framebuffer kexts must never
both be in the Auxiliary Kernel Collection); `--undo` puts it back, and then your EFI needs `B580.kext` again.

`--apply` backs up what it replaces to `/Library/Application Support/intel-gpu-macos-driver/backup-<date>/`, copies the
kexts and the Metal driver, and rebuilds the Auxiliary Kernel Collection. Reboot. The desktop should now be accelerated
(transparency and blur, smooth window dragging; `About This Mac` names the Arc B580 with 12 GB).

Undo: `sudo ./install.sh --undo`, then reboot. If the Mac does not come up, boot in safe mode (hold Shift on the
OpenCore entry; the Auxiliary Kernel Collection is skipped) and run the undo there, or boot your USB EFI.

## 4. Optional: Safari WebGL (system volume)

Safari's GPU process may only load code from the system volume. `system-volume/ssv-install.sh` copies the Metal driver
there and blesses a new boot snapshot, as OpenCore Legacy Patcher's root patches do. It is not needed for anything
else, and in this release Safari's GPU process is kept off the driver anyway (`nvmtl-allow.txt`).

```sh
cd system-volume && ./ssv-install.sh          # read-only checks
sudo ./ssv-install.sh --apply                 # then reboot
```

A macOS update removes it again (`./ssv-install.sh --check` says so); run `--apply` once more after the update.

**Upgrading:** the system-volume copy of the earlier release cannot drive the renamed kexts. When `install.sh --apply`
finds it, it creates `/Library/GPUBundles/NVMTLDriver.use-library`, so NMXAccel gives every process the `/Library` copy
for now. Install this package's system-volume copy with `sudo ./ssv-install.sh --apply`, then
`sudo rm /Library/GPUBundles/NVMTLDriver.use-library`, and reboot.

## Reporting a problem

Open an issue on GitHub with the bug template. The repository's `tools/report/` collects logs and removes serial
numbers, UUIDs, MAC addresses and user names first. Please do not post raw system reports.

## Source

Every binary here is built from the repository at the tag of this release; `SOURCES.md` lists which directory and
build script made each one.
