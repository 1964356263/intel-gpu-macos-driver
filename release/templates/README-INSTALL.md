# intel-gpu-macos-driver @VER@ for @MACOS@ (Intel Arc B580)

[Türkçe](README-INSTALL.tr.md)

@TESTED@ Unsigned, unsupported, and it changes how your PC boots macOS. **Keep a USB stick with a working OpenCore EFI
before you start**, and know how to boot from it (your firmware's boot menu key). Noncommercial use only (see `LICENSES/`).

What you get when it works: the desktop composited on the B580 with Metal (window dragging at the monitor's refresh
rate, up to 180 Hz tested), Metal apps and games, VideoToolbox decode (H.264, HEVC, AV1, VP9) and encode (H.264, HEVC,
AV1) on the GPU, one DisplayPort monitor with VRR, sleep and wake.
Known issues: Safari's GPU process, the Dock's icon helper and NotificationCenter (desktop widgets) stay on macOS's
software path (listed in
`Library/GPUBundles/nvmtl-allow.txt`); the first seconds after the first login stutter while shaders are translated;
a light grey band on the login screen after a restart; ffmpeg-style tools that bring Metal up through a VideoToolbox
encode miss our encoders in their first session.

Already running an earlier build of this driver? Go to [Upgrading](#upgrading-from-an-earlier-build).

## What you need

- A PC that OpenCore can boot macOS on (Intel CPU, x86_64), with the Arc B580 and **one monitor on the B580's
  DisplayPort**. An integrated GPU is not needed: on the test machine macOS was installed on the B580 alone.
- Any computer with Windows, Linux or macOS to prepare the USB stick and edit the EFI. You do not need a Mac.
- Two files from the release page:

  | File | What | Unpack it on |
  |---|---|---|
  | `intel-gpu-macos-driver-@VER@-efi.zip` | the OpenCore pieces: `IntelXe.kext`, `SSDT-ARCOFF.aml` and its source | any system |
  | `intel-gpu-macos-driver-@VER@-@CODENAME@.zip` | everything else, with `install.sh` | **macOS on the PC** (stage 3) |

  Unpack the second one on macOS only: Windows and most Linux unzip tools drop the executable bits and the code
  signatures that the installer checks.
- [Dortania's OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/), for everything that is not
  about the GPU: your board's EFI, ACPI tables, SMBIOS, USB mapping.
- A config.plist editor for your system, for example [ProperTree](https://github.com/corpnewt/ProperTree) (Windows,
  Linux and macOS; needs Python).

## The stages

| Stage | Done on | What | The screen afterwards |
|---|---|---|---|
| 1 | Windows, Linux or macOS, then the PC | macOS installed with a plain OpenCore EFI | the B580's firmware output: no acceleration, slow |
| 2 | config.plist, from any system | SIP, AMFI, two quirks, one output setting | the same |
| 3 | macOS on the PC | `sudo ./install.sh --apply`, **no reboot yet** | the same |
| 4 | the EFI, from any system | `IntelXe.kext` and `SSDT-ARCOFF.aml`, then reboot | accelerated |

Do not put `IntelXe.kext` or `SSDT-ARCOFF.aml` into the EFI before stage 4: the table hides the B580 from the generic
display driver that shows the installer, and nothing takes its place until stage 3 has installed the driver's own
display kext. Each stage's end state is one the test machine ran in; the four stages were not repeated end to end on a
fresh install.

## 1. Install macOS with a plain OpenCore EFI

1. **Firmware (BIOS):** Above 4G decoding **on**, Resizable BAR **on**, CSM **off**; the rest as Dortania describes for
   your platform.
2. **USB installer:** follow Dortania for the system you have:
   - [on Windows](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/windows-install.html) or
     [on Linux](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/linux-install.html): both fetch macOS
     recovery with `macrecovery.py`, and recovery downloads macOS during the install, so the PC needs a network
     connection that works in recovery (Ethernet with the right kext, or a Wi-Fi kext);
   - [on macOS](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/mac-install.html): the full installer.
3. **EFI:** build it as Dortania describes for your CPU and board. Dortania's newest desktop page is
   [Comet Lake](https://dortania.github.io/OpenCore-Install-Guide/config.plist/comet-lake.html); for Alder Lake and
   Raptor Lake (12th to 14th generation) it has none, so use that page plus the
   [sample of the test machine](https://github.com/yusufklncc/intel-gpu-macos-driver/tree/main/efi/sample-z790) (Z790,
   i7-14700K): its config without serial numbers, the SSDT sources, the kext list with versions, and what it changes
   for the installer. The tools run on Windows too:
   [SSDTTime](https://github.com/corpnewt/SSDTTime) (the SSDTs from your board's DSDT; Windows and Linux can dump the
   DSDT), [USBToolBox](https://github.com/USBToolBox/tool) (USB map, on Windows) and
   [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) (serial numbers). Nothing GPU-specific for the B580 yet: no
   `DeviceProperties` and no WhateverGreen settings for it. Keep `UEFI > Output > ReconnectGraphicsOnConnect = false`
   (Dortania's sample has it so); see stage 2.
4. Install macOS and finish the setup assistant. The screen runs on the B580's firmware output (UEFI GOP) through
   macOS's generic display driver: one resolution, no acceleration, everything slow, and sleep does not work yet.
   That is expected.

## 2. SIP, AMFI, quirks and the console setting (config.plist)

The EFI partition is a small FAT32 partition, which every system can mount:

| System | Mount the EFI partition |
|---|---|
| Windows | in an administrator Command Prompt: `mountvol S: /S`, then start ProperTree from the same prompt and open `S:\EFI\OC\config.plist`; `mountvol S: /D` when done |
| Linux | `lsblk -o NAME,FSTYPE,PARTTYPENAME` shows it (`vfat`, type "EFI System"), then `sudo mount /dev/nvme0n1p1 /mnt` with your partition |
| macOS | `diskutil list` shows it (`EFI` on the disk you boot from), then `sudo diskutil mount disk0s1` with your partition |

In `config.plist`:

1. `Booter > Quirks > ResizeAppleGpuBars = 10`. macOS cannot map the B580's 16 GB BAR; this gives it a 1 GB window.
2. `Kernel > Quirks > DisableIoMapper = true`.
3. `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82`:
   - `csr-active-config` = `03080000` (Data): SIP relaxed, so that unsigned kexts load from the Auxiliary Kernel
     Collection;
   - `boot-args`: add `amfi_get_out_of_my_way=0x1` (otherwise WindowServer refuses the unsigned Metal driver) and
     `intelxe_surfvram=2` (IOSurfaces shared in VRAM between processes).
4. `NVRAM > Delete > 7C436110-AB2A-4BBB-A880-FE41995C9F82` must list `csr-active-config` and `boot-args` (Dortania's
   sample config does), so that the new values replace the old ones.
5. `UEFI > Output > ReconnectGraphicsOnConnect = false`. With `true`, OpenCore's RELEASE build sets up the console
   before the B580's firmware display (GOP) is back from the reconnect; macOS then boots without a console framebuffer,
   Lilu never completes its start, VirtualSMC's SMC device is not hooked up, and `watchdogd` panics the boot about
   20 seconds in. OpenCore's DEBUG build is slow enough to hide this.
6. For the optional Safari WebGL copy only (step 3.4): `Misc > Security > SecureBootModel = Disabled`.

Reboot into macOS. The screen still runs on the firmware output.

## 3. The macOS part (on the PC)

1. Download and unpack the package in Terminal. Files fetched with `curl` carry no "downloaded from the internet" mark,
   so Gatekeeper leaves them alone:

   ```sh
   cd ~/Downloads
   curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v@VER@/intel-gpu-macos-driver-@VER@-@CODENAME@.zip
   ditto -x -k intel-gpu-macos-driver-@VER@-@CODENAME@.zip .
   cd intel-gpu-macos-driver-@VER@-@CODENAME@
   ```

   Downloaded with a browser instead? Unpack it with a double click, open Terminal in the folder and run
   `xattr -dr com.apple.quarantine .` first.
2. Check, then install:

   ```sh
   ./install.sh                # checks only: macOS, SIP, AMFI, the card, checksums, signatures
   sudo ./install.sh --apply
   ```

   At this stage the check warns that `IntelXe.kext` is not loaded; it comes in stage 4. `--apply` backs up what it
   replaces to `/Library/Application Support/intel-gpu-macos-driver/backup-<date>/`, copies the kexts and the Metal
   driver into `/Library`, and rebuilds the Auxiliary Kernel Collection.
3. **Do not reboot yet:** do stage 4 first.
4. Optional, Safari WebGL. Safari's GPU process may only load code from the system volume.
   `system-volume/ssv-install.sh` copies the Metal driver there and blesses a new boot snapshot, as OpenCore Legacy
   Patcher's root patches do. Nothing else needs it, and in this release Safari's GPU process is kept off the driver
   anyway (`nvmtl-allow.txt`). A macOS update removes it again (`./ssv-install.sh --check` says so).

   ```sh
   cd system-volume && ./ssv-install.sh          # read-only checks
   sudo ./ssv-install.sh --apply
   ```

## 4. IntelXe.kext and SSDT-ARCOFF (the EFI)

Take the files from `intel-gpu-macos-driver-@VER@-efi.zip` (the macOS package has the same files under `EFI/OC/`).
Mount the EFI partition as in stage 2; on the PC itself, `sudo diskutil mount disk0s1` with your partition.

1. Copy `IntelXe.kext` to `EFI/OC/Kexts/` and add it under `Kernel > Add`: `BundlePath IntelXe.kext`,
   `ExecutablePath Contents/MacOS/IntelXe`, `PlistPath Contents/Info.plist`, `Enabled true`. This is the GPU driver
   (GuC/HuC firmware included); it does not need Lilu.
2. `SSDT-ARCOFF.aml` hides the card from macOS's generic display driver (on Tahoe that driver otherwise takes the card
   and the IntelXe kexts cannot start). **Its ACPI path depends on the board.** The shipped table is for a board whose
   ACPI names the slot's root port `\_SB.PC00.PEG1` and the card's own PCIe switch below it `PEGP`. Below `PEGP` every
   B580 looks the same: a downstream port at `PCI(0100)`, then the GPU at `PCI(0000)`. Find your path:

   | System | How |
   |---|---|
   | Windows | Device Manager → Display adapters → the B580 (or "Microsoft Basic Display Adapter" without Intel's driver) → Properties → Details → **Location paths**. The `ACPI(...)` line looks like `ACPI(_SB_)#ACPI(PC00)#ACPI(PEG1)#ACPI(PEGP)#PCI(0100)#PCI(0000)`, which is `\_SB.PC00.PEG1.PEGP` |
   | Linux | `lspci -nn \| grep e20b` gives the GPU (e.g. `03:00.0`); `lspci -tv` shows the card's upstream port two levels above it (e.g. `01:00.0`); `cat /sys/bus/pci/devices/0000:01:00.0/firmware_node/path` prints its ACPI path, e.g. `\_SB_.PC00.PEG1.PEGP` |
   | macOS | [gfxutil](https://github.com/acidanthera/gfxutil/releases) lists every PCI device with its ACPI path: take the `8086:e20b` line. IORegistryExplorer shows the same names in the IOService plane (`PC00@0` → `PEG1@1` → `PEGP@0` → ...) |

   If your path is the shipped one (`\_SB.PC00.PEG1.PEGP`), use `SSDT-ARCOFF.aml` as it is. Otherwise put your path in
   the two places of `SSDT-ARCOFF.dsl` that name it (the `External` line and the `Scope` line) and compile it with
   `iasl SSDT-ARCOFF.dsl`. `iasl` is part of ACPICA: on Windows ACPICA's Windows binary tools (acpica.org, Downloads),
   on Linux the `acpica-tools` (or `iasl`) package, on macOS `brew install acpica` or the `iasl` inside
   [MaciASL](https://github.com/acidanthera/MaciASL/releases). If no `ACPI(...)` part names the card's upstream port
   (the last `ACPI(...)` part is followed by three `PCI(...)` parts instead of two), the table needs one more bridge
   level: open an issue with your Location paths line.
3. Copy the `.aml` to `EFI/OC/ACPI/` and add it under `ACPI > Add` (`Path SSDT-ARCOFF.aml`, `Enabled true`).
4. Reboot. The desktop should now be accelerated: transparency and blur, smooth window dragging, and `About This Mac`
   names the Arc B580 with 12 GB. In Terminal, `kmutil showloaded | grep -i intelxe` lists `IntelXe` and `IntelXeFB`,
   and `sysctl debug.nmxaccelfb` prints `1`.

## If it does not come up

- **Black screen or a reboot loop:** boot from your USB stick with the working EFI, or press Shift with the OpenCore
  entry selected to boot safe mode (it skips the Auxiliary Kernel Collection). Then run `sudo ./install.sh --undo` and
  remove `IntelXe.kext` and `SSDT-ARCOFF.aml` from the EFI.
- **Crashes during the first minute (boot guard):** one boot that ends inside its first accelerated minute (a panic, or
  the power button held) only makes the next one try again. After two in a row the next boots arm with the safest
  settings (no async swaps, no flips; `ioreg -rc IntelXeFramebuffer -d1 | grep AccelSafe` says `Yes`), and the guard
  returns to normal after a boot that runs for a minute. After four in a row acceleration is held, and **on macOS 26 the
  monitor then stays on the Apple logo** (macOS itself runs: WindowServer has no display without acceleration; tested on
  the B580). To get out: restart, and in the OpenCore picker choose **Reset NVRAM** (press Space if it is hidden). That
  clears the guard; OpenCore writes its own boot-args and SIP setting again at every boot (tested on the B580). Or, from
  another computer over SSH (Remote Login turned on beforehand), turn acceleration back on and reboot:

  ```sh
  sudo nvram intelxe-accel-off=ok
  ```

  (`sudo nvram -d intelxe-accel-off` reports no error on macOS 26 but leaves the variable in place; `=ok` works on every
  version. The kernel log of 0.1.x still names `nvram -d`; the source is fixed and the next kernel build has the new text.)
- **Panic about 20 seconds into the boot, `watchdogd ... exited`** (the report in
  `/Library/Logs/DiagnosticReports/Kernel-*.panic` names `watchdogd`): `UEFI > Output > ReconnectGraphicsOnConnect`
  is `true`; set it to `false` (stage 2, item 5).
- **Undo everything:** `sudo ./install.sh --undo`, then reboot with `IntelXe.kext` and `SSDT-ARCOFF.aml` removed from
  the EFI.
- **Other install.sh commands:** `./install.sh --status` compares what is installed with this package and changes
  nothing. `sudo ./install.sh --repair` puts back installed files that differ from the package and leaves the last
  backup alone. `sudo ./install.sh --uninstall` removes the kexts and the Metal driver from `/Library` and keeps the
  backups; `--undo` instead goes back to what the last install replaced. After `--uninstall`, remove `IntelXe.kext`
  from the EFI before you reboot.

## Upgrading from an earlier build

**From 0.1.0 or 0.1.1:** the driver binaries are the same in 0.1.0, 0.1.1 and 0.1.2; nothing needs to be reinstalled.
Check `UEFI > Output > ReconnectGraphicsOnConnect = false` in your `config.plist` (stage 2, item 5), above all before
you move OpenCore to a RELEASE build. Add `-NotificationCenter` to `/Library/GPUBundles/nvmtl-allow.txt` (after the `-com.apple.dock.extra` line) so that
the desktop widgets are drawn again, then `killall NotificationCenter`; `install.sh --apply` keeps an existing
allow-list that differs from the package's, so it does not add the line for you.

**From the private builds named B580 (before 0.1.0):** `B580.kext` is now `IntelXe.kext`, `B580FB.kext` is
`IntelXeFB.kext`, and the boot-args start with `intelxe_`. Do both halves before you reboot:

- in the EFI, delete `EFI/OC/Kexts/B580.kext`, copy `IntelXe.kext` in its place and change its `Kernel > Add` entry to
  the paths in stage 4 (only one of the two may be in your EFI);
- run `sudo ./install.sh --apply`, which backs up and removes `/Library/Extensions/B580FB.kext` (`--undo` puts it back,
  and then your EFI needs `B580.kext` again).

With only one of the two, macOS comes up without the driver. If you installed the system-volume copy of the earlier
build, `--apply` creates `/Library/GPUBundles/NVMTLDriver.use-library`, so that every process uses the `/Library` copy;
install this package's system-volume copy (step 3.4), then `sudo rm /Library/GPUBundles/NVMTLDriver.use-library`, and
reboot.

Rename the boot-args too. 0.1.x still reads the earlier names when the new one is absent and logs
`boot-arg ... is deprecated` once per name (`log show --last boot --predicate 'eventMessage CONTAINS "is deprecated"'`);
later releases read only the new names. Values and meanings are unchanged:

| Earlier name | New name |
|---|---|
| `b580surfvram=N`, `b580svwsfull=N`, `b580fds=N` | `intelxe_surfvram=N`, `intelxe_svwsfull=N`, `intelxe_fds=N` |
| `-b580off`, `-b580lazy`, `-b580nometal`, `-b580novideo`, `-b580nohugepages`, `-b580nousm`, `-b580lrcsys`, `-b580vcssingle`, `-b580nowhitelist` | `-intelxe_off`, `-intelxe_lazy`, `-intelxe_nometal`, `-intelxe_novideo`, `-intelxe_nohugepages`, `-intelxe_nousm`, `-intelxe_lrcsys`, `-intelxe_vcssingle`, `-intelxe_nowhitelist` |
| `-b580nofb`, `-b580noaccel` | `-intelxe_nofb`, `-intelxe_noaccel` |
| `-b580fboff`, `-b580fbnoscale`, `-b580fbnorates`, `-b580fbedidonly`, `-b580fbnogamma`, `-b580fbnovrr`, `-b580fbnohwcursor`, `-b580fbnoirq`, `-b580fbnoedidfix` | `-intelxefb_off`, `-intelxefb_noscale`, `-intelxefb_norates`, `-intelxefb_edidonly`, `-intelxefb_nogamma`, `-intelxefb_novrr`, `-intelxefb_nohwcursor`, `-intelxefb_noirq`, `-intelxefb_noedidfix` |
| `b580fbvrr=N`, `b580fbvrrmodes=N` | `intelxefb_vrr=N`, `intelxefb_vrrmodes=N` |

NVRAM settings and sysctls have only the new names: the variable `b580fb-vrr-modes` is now `intelxefb-vrr-modes`,
`debug.b580.*` is `debug.intelxe.*`, `debug.b580fb_*` is `debug.intelxefb_*`. The boot guard starts afresh under
`intelxe-guard` / `intelxe-accel-off`. The earlier variables (`b580-guard`, `b580-accel-off`, `b580-shutdown`,
`b580fb-shutdown`, `b580fb-vrr-modes`) are not read any more; they can stay.

## Contents

| Path | Goes to |
|---|---|
| `EFI/OC/Kexts/IntelXe.kext` | the EFI, `Kernel > Add` (stage 4); the same file as in the `-efi.zip` |
| `EFI/OC/ACPI/SSDT-ARCOFF.aml`, `.dsl` | the EFI, `ACPI > Add`, after checking the path (stage 4) |
| `Library/Extensions/IntelXeFB.kext`, `NMXAccel.kext`, `NMXAGDC.kext` | `/Library/Extensions` (display, accelerator), via `install.sh` |
| `Library/GPUBundles/NVMTLDriverLib.bundle`, `nvmtl/`, `nvmtl-allow.txt` | `/Library/GPUBundles` (Metal driver, Mesa, codecs), via `install.sh` |
| `system-volume/` | optional: the copy of the Metal driver on the system volume (Safari WebGL, step 3.4) |
| `SHA256SUMS`, `sigcheck` | the checks `install.sh` runs |
| `SOURCES.md`, `LICENSES/` | which source and script built each binary; the licence texts |

## Reporting a problem

Open an issue on GitHub with the bug template. The repository's `tools/report/` collects logs and removes serial
numbers, UUIDs, MAC addresses and user names first. Please do not post raw system reports.
