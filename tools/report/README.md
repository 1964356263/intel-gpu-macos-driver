# Diagnostics reports

Three scripts collect what we need to debug the driver on your machine. Each one writes a single file named after a **report ID**, for example `xe-report-XR-1A2B3C4D.tar.gz`. The bug form asks for that ID, and you attach the file to the issue.

Nothing is uploaded. The scripts only read; they change no settings and install nothing. Each takes about a minute.

| Script | Run it on | What it is for |
|---|---|---|
| `collect-macos.sh` | macOS, with or without our driver | The main report: hardware, driver state, logs, panics, OpenCore config |
| `collect-linux.sh` | a Linux live USB, on the same machine | Reference: what Linux's own driver finds and programs on your hardware |
| `collect-windows.ps1` | Windows, on the same machine | Hardware inventory, if you dual-boot and have no Linux USB |

For a bug, the macOS report is required. The Linux and Windows reports are optional extras, but they help a lot for display and boot problems, and for hardware we have not seen yet.

## macOS

Open Terminal in the folder that holds the script and run:

```sh
sh collect-macos.sh
```

At the end it prints the report ID and the file's path. The options are:
- `--days N`: include panic and crash reports from the last N days (default 7);
- `--tests`: also run our quick GPU self-tests (`vk_smoke`, `mtl_tests`) if they are installed (off by default);
- `--no-mount`: do not try to mount an EFI partition to read the OpenCore config;
- `--sudo-mount`: if `sudo` works without a password, mount EFI partitions read-only as root and unmount them again. With a known boot partition, only that one is mounted; otherwise every EFI partition a user could not mount;
- `--probe`: also collect the results of the staged probe (`XeProbe`, see `docs/PROBE-MODE.md`) and the NVRAM breadcrumb the previous boot left;
- `--out DIR`: write the file somewhere else.

You do not need `sudo`. A few driver counters can only be read by root. If `sudo` works without a password, the script adds them; otherwise it skips them and says so in the summary.

The script uses only tools that ship with macOS. It does not need Xcode or the Command Line Tools, and it does not start their install dialog.

**OpenCore config.** The script reads `EFI/OC/config.plist` from any EFI partition that is already mounted. It also tries to mount the other EFI partitions read-only, which usually needs root. If it found no config, mount the EFI partition you boot from, for example with `sudo diskutil mount disk0s1` or MountEFI, and run the script again.

**Which EFI booted.** The script works this out without root, in this order:
1. the firmware's `BootCurrent` load option (its partition GUID and file path);
2. OpenCore's `boot-path`, if `ExposeSensitiveData` exposes it;
3. otherwise, it compares each EFI it could read with the running system: whether the OpenCore log was written during this boot, and whether the boot-args, `csr-active-config` and OpenCore version match.

A comparison only names an EFI when the OpenCore log of this boot is on it, or when every EFI partition was read. A copy of the same EFI on a USB stick would match the settings just as well. The result is in `opencore/booted-efi.txt` and on the "Booted from" line of the summary.

## Linux (live USB)

Our kernel driver follows Linux's `xe` and `i915` drivers. When something differs on your machine, the quickest way to find out why is to see what Linux does on the same hardware:
- the firmware it loads;
- how it sets up PCI and Resizable BAR;
- the GuC/HuC state;
- the display link, the VBT and the EDIDs.

`collect-linux.sh` records that ground truth.

1. Boot any recent live USB on the same machine, with the same monitor connected. A distribution with kernel 6.12 or newer is best; Ubuntu 25.04+ and Fedora 41+ both work. Battlemage needs the `xe` driver.
2. Copy `collect-linux.sh` to the live system, open a terminal in that folder, and run:

   ```sh
   sudo sh collect-linux.sh
   ```

   It also runs without `sudo`, but then it misses the debugfs state, the full PCI capability list (which holds Resizable BAR) and, on some systems, the kernel log.
3. Copy the resulting `xe-report-XR-….tar.gz` to a USB stick or to your macOS/Windows disk before you reboot. A live system forgets everything.

Optional extras, used if they are installed: `vulkaninfo` (package `vulkan-tools`), `glxinfo` (`mesa-utils`), and `intel_reg` (`intel-gpu-tools`, for a register dump).

## Windows

Open PowerShell in the folder that holds the script and run:

```powershell
powershell -ExecutionPolicy Bypass -File collect-windows.ps1
```

`-ExecutionPolicy Bypass` applies to this one run only; it does not change your system's policy. The script needs no administrator rights. Run it as administrator only if you want the TPM details too. It writes `xe-report-XR-….zip` in the current folder.

It records:
- Windows, the machine and its board, the BIOS version and date, and the CPU;
- the GPUs with their hardware IDs, driver versions and memory ranges. From the memory ranges it tells whether Resizable BAR and Above 4G decoding are active;
- the monitors (EDID);
- Secure Boot and the TPM;
- the disk and network adapter models;
- a `dxdiag /t` report.

## What is collected

**macOS:**
- macOS version and build; CPU, SMBIOS model and board-id; the OpenCore version and boot-args from NVRAM; SIP state;
- every PCI device's IDs. For GPUs, also the BAR sizes and the PCIe path to the root port. A discrete Arc card sits behind its own PCIe switch, whose downstream port and GPU function always report Gen1 x1, so the summary gives the link into the root port (in `gpu/pcie-links.txt`, each hop in the path);
- framebuffer and display properties from the I/O Registry, the EDIDs, and `system_profiler SPDisplaysDataType` (Metal devices);
- loaded kexts: ours, Lilu, WhateverGreen and WhateverXe, plus the other graphics kexts;
- our driver state: `debug.intelxe.*`, `debug.intelxefb_*` and `debug.nmxaccel*`. Only read-only values are read: never a screen capture (`intelxefb_thumb`/`crop`), register peeks or batch dumps. If the kernel has `debug.intelxe.dump`, that one call replaces the list;
- the version and SHA-256 of each installed piece: kexts, NVMTLDriver.bundle, Mesa, the Vulkan loader and the VideoToolbox codecs;
- `vulkaninfo --summary`, if installed;
- kernel log lines from our kexts, Lilu, WhateverGreen/WhateverXe and IOGraphics, since the last boot (the first 2000 and the last 3000);
- WindowServer errors and log lines from our user-space parts: since the boot, or from the last 2 hours if the machine has been up longer. Both log queries run in the background while the rest is collected;
- panic reports: the list of all of them, and the panic text of those from the last 7 days;
- crash, hang and GPU-restart reports that involve our stack;
- power settings and recent sleep/wake events;
- from a mounted EFI: `config.plist`, the newest OpenCore log, and the names, versions and hashes of the kexts and drivers.

**Linux:**
- kernel and distribution; the machine, board and BIOS (DMI, without serials); Secure Boot;
- `lspci -nnvv` for each GPU and the bridges above it; sysfs PCI and link data; BAR sizes;
- the loaded driver, `modinfo xe`/`i915`, module parameters, and the firmware files present;
- kernel log lines about xe/i915/drm/GuC/HuC/DMC;
- with root, selected debugfs files: device info, GuC/HuC info and log, frequency, engines, topology, workarounds, display info, DMC, the VBT, and per-connector DPCD/PSR/DSC state;
- connectors with their status, modes and EDIDs;
- `vulkaninfo --summary` / `glxinfo -B`, and `intel_reg dump` if installed.

Each archive also holds `summary.txt`, a one-page overview to read first, and `manifest.txt` with the SHA-256 of every file.

## Privacy

Before the archive is written, every script removes:
- serial numbers: the machine, board and disks, and the monitor's serial inside its EDID;
- the platform UUID and machine IDs: on macOS the hardware UUID, MLB and ROM; on Linux the machine-id; on Windows the MachineGuid;
- MAC addresses;
- your user name and full name, and your user name in file paths;
- the computer's host names;
- the names of Wi-Fi networks your machine knows;
- in the OpenCore config: `SystemSerialNumber`, `MLB`, `SystemUUID`, `ROM`, `BoardSerialNumber`, `ChassisSerialNumber` and `ApECID`. The keys stay, the values become `REDACTED`.

The scripts first read these values from your own machine, then remove each one from every file. Before packing, they search the output once more. If any value is still there, or anything shaped like a Windows product key, they stop without writing a file and tell you.

**Never collected:**
- ACPI tables, or any file in an EFI `ACPI` folder. On macOS only the file names in `EFI/OC/ACPI` are listed. ACPI tables can carry your Windows product key (the MSDM table).
- The Windows product key and licensing data.
- Screen contents.
- Wi-Fi passwords.
- Your documents.
- Full system logs: only the log lines that concern graphics are kept.

The archive is plain text plus a few small binaries: the VBT on Linux, and the GuC hwconfig table on macOS. You can unpack it and read every file before you share it:

```sh
tar -xzf xe-report-XR-1A2B3C4D.tar.gz
```

## Attaching the report to an issue

1. Open a new issue with the **Something is broken** form.
2. Put the report ID (`XR-…`) in the first field. If you made more than one report, for example macOS and Linux, list all their IDs, separated by commas.
3. Drag the `.tar.gz` or `.zip` file into the description box. GitHub accepts both, up to 25 MB.

If GitHub rejects the file as too large, rerun the macOS script with `--days 2`.
