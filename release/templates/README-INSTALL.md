# intel-gpu-macos-driver @VER@ for @MACOS@ (Intel Arc B580)

[Türkçe](README-INSTALL.tr.md)

@TESTED@ Unsigned, unsupported, and it changes how your PC boots macOS. **Keep a USB stick with a working OpenCore EFI
before you start**, and know how to boot from it (your firmware's boot menu key). Noncommercial use only (see `LICENSES/`).

What you get when it works: the desktop composited on the B580 with Metal (window dragging at the monitor's refresh
rate, up to 180 Hz tested), desktop widgets, Metal apps and games, Safari on the GPU (with the optional
system-volume copy, 3.3), VideoToolbox decode (H.264, HEVC, AV1, VP9) and encode (H.264, HEVC, AV1) on the GPU,
one DisplayPort monitor with VRR, sleep and wake. Optional: OpenGL through Mesa's zink for LWJGL games such as
Minecraft Java (the `-zink-gl.zip`, [below](#optional-opengl-through-zink)).
Known issues: the first seconds after the first login stutter while shaders are translated; a light grey band on the
login screen after a restart; ffmpeg-style tools that bring Metal up through a VideoToolbox encode miss our encoders in
their first session. Only 1 GB of the card's 12 GB can be mapped by the CPU (a macOS limit, stage 2 item 1): the
driver keeps that window for what needs it and puts background processes' buffers in system memory, but many open
GPU-heavy apps can still fill it.

Already running an earlier build of this driver? Go to [Upgrading](#upgrading-from-an-earlier-build).

## What you need

- A PC that OpenCore can boot macOS on (Intel CPU, x86_64), with the Arc B580 and **one monitor on the B580's
  DisplayPort**. An integrated GPU is not needed: on the test machine macOS was installed on the B580 alone.
- Any computer with Windows, Linux or macOS to prepare the USB stick and edit the EFI. You do not need a Mac.
- Files from the [release page](https://github.com/yusufklncc/intel-gpu-macos-driver/releases/tag/v@VER@):

  | File | What | Unpack it on |
  |---|---|---|
  | `intel-gpu-macos-driver-@VER@-efi.zip` | the OpenCore pieces: `IntelXe.kext`, `SSDT-ARCOFF.aml` and its source; `IntelXe-EFI.ps1`, which makes stages 2 and 4 on Windows | any system |
  | `IntelXe-Manager-@VER@.zip` | the IntelXe Manager app: stages 3 and 4 (and later updates) with buttons instead of Terminal; it downloads the next file itself | macOS on the PC |
  | `intel-gpu-macos-driver-@VER@-@CODENAME@.zip` | everything else, with `install.sh` and `efi.sh` | **macOS on the PC** (stage 3) |
  | `intel-gpu-macos-driver-@VER@-zink-gl.zip` | optional: OpenGL through zink for LWJGL games | macOS on the PC, after stage 4 |

  Unpack the macOS files on macOS only: Windows and most Linux unzip tools drop the executable bits and the code
  signatures that the installer checks. The `.sha256` file on the release page lists their checksums.
- [Dortania's OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/), for everything that is not
  about the GPU: your board's EFI, ACPI tables, SMBIOS, USB mapping.
- A config.plist editor for your system, for example [ProperTree](https://github.com/corpnewt/ProperTree) (Windows,
  Linux and macOS; needs Python).

## The stages

| Stage | Done on | What | The screen afterwards |
|---|---|---|---|
| 1 | Windows, Linux or macOS, then the PC | macOS installed with a plain OpenCore EFI | the B580's firmware output: no acceleration, slow |
| 2 | config.plist, from any system | SIP, AMFI, two quirks, one output setting | the same |
| 3 | macOS on the PC | the app's **Install**, or `sudo ./install.sh --apply`; **no reboot yet** | the same |
| 4 | the EFI, from macOS on the PC or any system | `IntelXe.kext` and `SSDT-ARCOFF.aml` (the app's EFI page, `efi.sh`, `IntelXe-EFI.ps1` or by hand), then reboot | accelerated |

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

**On Windows**, `IntelXe-EFI.ps1` in the `-efi.zip` makes items 1 to 5 for you in an EFI folder you choose (a USB
stick's, or the EFI partition, which it can mount): right-click > Run with PowerShell, *Settings: plan*, then
*Settings: apply*. It backs up the whole EFI folder first, keeps the rest of `config.plist` as it is, and can undo the
change; see `README-Windows.md` in the zip. Its test suite passes on Windows; the window itself has not yet been used
on an EFI that a PC then booted. **On macOS on the PC**, the IntelXe Manager app's EFI page (*Change these settings*)
or `sudo ./efi.sh --settings-apply` from the macOS package make the same changes in the EFI OpenCore booted from (see
3.1).

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
6. For the system-volume copy (Safari on the GPU, 3.3):
   `Misc > Security > SecureBootModel = Disabled`.

Reboot into macOS. The screen still runs on the firmware output.

## 3. The macOS part (on the PC)

### 3.1 With the IntelXe Manager app

The app does stages 3 and 4 on the PC with buttons and shows what each step will change before it asks for your
password; `install.sh` and `efi.sh` from the package do the work, so it is the same as the Terminal steps in 3.2.

1. Download `IntelXe-Manager-@VER@.zip` in Terminal, which leaves no "downloaded from the internet" mark, and unpack it
   into your Applications folder:

   ```sh
   cd ~/Downloads
   curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v@VER@/IntelXe-Manager-@VER@.zip
   mkdir -p ~/Applications && ditto -x -k IntelXe-Manager-@VER@.zip ~/Applications
   open ~/Applications/"IntelXe Manager.app"
   ```

   The app is signed ad hoc, not by an Apple developer ID. Downloaded with a browser, macOS refuses to open it; then
   run `xattr -dr com.apple.quarantine ~/Applications/"IntelXe Manager.app"`, or open it once and allow it under System
   Settings > Privacy & Security (*Open Anyway*).
2. **System** shows what the driver needs (macOS, SIP, the AMFI boot-arg, the card) and what is installed.
3. **Driver:** *Download v@VER@* fetches the package for your macOS and compares it with the release's checksum list.
   The EFI page takes its files from this package too.
4. Stage 2 not done yet? The install needs it (it refuses to run without relaxed SIP and the AMFI boot-arg): on
   **EFI (OpenCore)** choose the EFI partition OpenCore booted from (or *Use an EFI folder…*), press *Change these
   settings* under "Settings (stage 2)", reboot, and open the app again.
5. **Driver:** *Install this package* (the same as `sudo ./install.sh --apply`). **Do not reboot yet.**
6. **EFI (OpenCore):** *Make these changes* under "IntelXe.kext and SSDT-ARCOFF (stage 4)"; stage 4 below explains
   what it changes. Every EFI change shows its list of changes and asks first. Then reboot.

The app also repairs, undoes and uninstalls the driver, installs the optional zink package, and later installs a new
release over the old one. The system-volume copy for Safari (3.3) is not in the app: it is two commands in Terminal,
in the `system-volume` folder of the package the app downloaded (the Driver page shows its folder). It contacts only GitHub and sends no data. The Driver page was used on the test machine; the
EFI page was used there on the EFI of its SSD; *Undo* on a real EFI and a whole install from a fresh macOS were not
repeated with the app.

### 3.2 In Terminal

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
   driver into `/Library`, installs the boot guard's LaunchDaemon (see [If it does not come up](#if-it-does-not-come-up)),
   and rebuilds the Auxiliary Kernel Collection.
3. **Do not reboot yet:** do stage 4 first.

### 3.3 Recommended for Safari: the system-volume copy

Safari's GPU process may only load code from the system volume. Without this copy Safari runs on macOS's software
path: slower, and some page elements with CSS colour filters are not drawn (a CoreGraphics problem without a Metal
device; turning off *GraphicsContext Filter Rendering* in Safari > Settings > Feature Flags works around it; the tab
appears after Advanced > *Show features for web developers*).
`system-volume/ssv-install.sh` copies the Metal driver there and blesses a new boot snapshot, as OpenCore Legacy
Patcher's root patches do. It needs `Misc > Security > SecureBootModel = Disabled` (stage 2, item 6). Nothing else
needs it. A macOS update removes it again (`./ssv-install.sh --check` says so; install it again). Tested on macOS
26.7.1: Safari runs on the B580 and its pages draw correctly, filters included. Safari's GPU process cannot keep translated shaders between starts (its sandbox), so its
first pages after each start wait a few seconds.

```sh
cd system-volume && ./ssv-install.sh          # read-only checks
sudo ./ssv-install.sh --apply
```

## 4. IntelXe.kext and SSDT-ARCOFF (the EFI)

Take the files from `intel-gpu-macos-driver-@VER@-efi.zip` (the macOS package has the same files under `EFI/OC/`).
Mount the EFI partition as in stage 2; on the PC itself, `sudo diskutil mount disk0s1` with your partition.

On the PC itself, `efi.sh` in the macOS package does steps 1 to 3 (and stage 2's settings) for you: it finds the EFI
OpenCore booted from, backs up the whole EFI folder, copies the files, enables their `config.plist` entries, and adds
`SSDT-ARCOFF.aml` only when its ACPI path is your card's. `./efi.sh --plan` shows the changes, `sudo ./efi.sh --apply`
makes them, `sudo ./efi.sh --undo` takes them back; `--settings-plan` / `--settings-apply` do stage 2. `./efi.sh` alone
lists every option. The IntelXe Manager app has the same on its EFI page.

**On Windows**, `IntelXe-EFI.ps1` in the `-efi.zip` does steps 1 and 3 (*Driver: plan*, *Driver: apply*) in the EFI
folder you choose, with a backup and an undo. Windows cannot check the ACPI path the way `efi.sh` does on macOS, so it
adds `SSDT-ARCOFF.aml` only when you tick its box and give your card's path from step 2 (it reads it from Device
Manager when Windows runs on the PC with the card). See `README-Windows.md` in the zip.

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

## Optional: OpenGL through zink

macOS's own OpenGL runs on top of Metal and is slow on this driver. LWJGL 3 Java games (Minecraft Java 1.13 and later)
can use Mesa's zink instead, which turns OpenGL straight into Vulkan for the driver. Only applications that open
OpenGL through GLFW/LWJGL use it; everything else stays on Apple's OpenGL. It needs the driver installed and
`intelxe_surfvram=2` (stage 2). The IntelXe Manager app's **OpenGL (Zink)** page installs it and turns it on, or in
Terminal:

```sh
cd ~/Downloads
curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v@VER@/intel-gpu-macos-driver-@VER@-zink-gl.zip
ditto -x -k intel-gpu-macos-driver-@VER@-zink-gl.zip .
cd intel-gpu-macos-driver-@VER@-zink-gl
sudo ./install.sh                # /Library/IntelXe/GL and the Vulkan loader; backs up what it replaces
./install.sh --test              # a GL context through zink on the B580
sudo ./install.sh --global on    # every LWJGL 3 application started afterwards uses zink
```

`--global off` switches back, `--undo` removes it; `README.md` in the zip has the rest. Measured on the test machine
(macOS 26.7.1, Minecraft 1.21.1 with Sodium and Iris, windowed, the same spot): with the BSL shader pack 197–205 fps with
zink, 214–218 on the same PC under Windows with Intel's driver; without a shader pack 1400–1500 fps with
zink against 700–1000 on Windows. A launcher that macOS reopens by itself at login can start before the setting is in
place and then runs on Apple's OpenGL: quit it and start it again (Java prints "Picked up JAVA_TOOL_OPTIONS" when zink
is on).

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
  version. The kernel log of 0.1.0 and 0.1.1 still named `nvram -d`.) The IntelXe Manager app's System page has a
  *Clear the boot guard* button for the boots in between, when the guard is armed but the desktop runs.
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

**From 0.1.0 or 0.1.1:** every kext, the Metal driver and the video libraries are new, **`IntelXe.kext` in the EFI
too** (it closes a security hole: an unprivileged process could get writable GPU mappings of pages it may only read).
Install the package (the app: *Download v@VER@*, then *Install this package*; or `sudo ./install.sh --apply`), then
replace `IntelXe.kext` in the EFI before you reboot (the app's EFI page or `sudo ./efi.sh --apply` on macOS,
`IntelXe-EFI.ps1` on Windows, or copy it by hand; its `config.plist` entry stays as it is).
`--apply` also installs the boot guard's LaunchDaemon and replaces the allow-list of 0.1.0 and 0.1.1 (with or without
the `-NotificationCenter` line 0.1.1's guide asked for), so that Safari's GPU process, the Dock's icons and the desktop
widgets use the driver again. An allow-list you changed in another way is kept: compare it with the package's
`Library/GPUBundles/nvmtl-allow.txt`. If you had installed the system-volume copy, `--apply` makes every process use
the `/Library` copy until you install this package's (3.3) and remove `/Library/GPUBundles/NVMTLDriver.use-library`.
Check `UEFI > Output > ReconnectGraphicsOnConnect = false` in your `config.plist` (stage 2, item 5), above all before
you move OpenCore to a RELEASE build.

**From the private builds named B580 (before 0.1.0):** `B580.kext` is now `IntelXe.kext`, `B580FB.kext` is
`IntelXeFB.kext`, and the boot-args start with `intelxe_`. Do both halves before you reboot:

- in the EFI, delete `EFI/OC/Kexts/B580.kext`, copy `IntelXe.kext` in its place and change its `Kernel > Add` entry to
  the paths in stage 4 (only one of the two may be in your EFI);
- run `sudo ./install.sh --apply`, which backs up and removes `/Library/Extensions/B580FB.kext` (`--undo` puts it back,
  and then your EFI needs `B580.kext` again).

With only one of the two, macOS comes up without the driver. If you installed the system-volume copy of the earlier
build, `--apply` creates `/Library/GPUBundles/NVMTLDriver.use-library`, so that every process uses the `/Library` copy;
install this package's system-volume copy (3.3), then `sudo rm /Library/GPUBundles/NVMTLDriver.use-library`, and
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
| (made by `install.sh`) | `/Library/LaunchDaemons/io.github.yusufklncc.intelxe.guard.plist`: clears the boot guard once a boot has run for a minute |
| `system-volume/` | optional: the copy of the Metal driver on the system volume (Safari on the GPU, 3.3) |
| `efi.sh` | optional, on macOS: stages 2 and 4 in the EFI OpenCore booted from, with a backup and an undo |
| `SHA256SUMS`, `sigcheck` | the checks `install.sh` runs |
| `SOURCES.md`, `LICENSES/` | which source and script built each binary; the licence texts |

## Reporting a problem

Open an issue on GitHub with the bug template. The repository's `tools/report/` collects logs and removes serial
numbers, UUIDs, MAC addresses and user names first. Please do not post raw system reports.
