# Sample OpenCore EFI: the test machine (Z790, i7-14700K, Arc B580)

The OpenCore 1.0.8 configuration the driver is tested with, with the machine's identity removed. It is a starting
point for the same kind of PC, **not a drop-in EFI**: there are no binaries here, the serial numbers are placeholders,
and several parts are specific to this board. Read [Dortania's guide](https://dortania.github.io/OpenCore-Install-Guide/)
for anything that differs on your machine.

| Part | Test machine |
|---|---|
| Board | ASUS ROG STRIX Z790-A GAMING WIFI II |
| CPU | Intel Core i7-14700K (Raptor Lake, 8 P + 12 E cores), integrated GPU off |
| GPU | Intel Arc B580, one DisplayPort monitor |
| Network | Intel I226-V Ethernet (AppleIGC), Intel BE202 Wi-Fi + Bluetooth |
| macOS | 26.7.1 Tahoe, SMBIOS `MacBookPro16,2` |

## Files

| File | What |
|---|---|
| `config.plist` | the configuration. `PlatformInfo > Generic` has placeholders; `IntelXe.kext` and `SSDT-ARCOFF.aml` are present but **disabled** (they are enabled in stage 4 of the install guide) |
| `acpi/*.dsl` | the sources of every SSDT the config loads; compile each with `iasl` to the `.aml` name the config lists |

## Building the EFI from it

1. **OpenCore 1.0.8** ([release](https://github.com/acidanthera/OpenCorePkg/releases), RELEASE build is fine): from
   `X64/EFI` take `BOOT/BOOTx64.efi`, `OC/OpenCore.efi`, and `OC/Drivers/OpenRuntime.efi`, `OpenCanopy.efi`,
   `ResetNvramEntry.efi`, `ToggleSipEntry.efi`; `OC/Tools/OpenShell.efi`, `CleanNvram.efi`. `OpenHfsPlus.efi` and the
   picker's `Resources` come from [OcBinaryData](https://github.com/acidanthera/OcBinaryData). Without `Resources`,
   set `Misc > Boot > PickerMode` to `Builtin` and remove `OpenCanopy.efi`.
2. **Kexts** into `EFI/OC/Kexts`, the versions the test machine runs:

   | Kext | Version | Source | Why |
   |---|---|---|---|
   | Lilu | 1.7.2 | [acidanthera/Lilu](https://github.com/acidanthera/Lilu/releases) | plugin base |
   | VirtualSMC, SMCProcessor, SMCSuperIO | 1.3.8 | [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC/releases) | SMC; CPU and board sensors |
   | AppleIGC | 1.9 | [SongXiaoXi/AppleIGC](https://github.com/SongXiaoXi/AppleIGC/releases) | Intel I226-V Ethernet |
   | NVMeFix | 1.1.3 | [acidanthera/NVMeFix](https://github.com/acidanthera/NVMeFix/releases) | NVMe power management |
   | CpuTscSync | 1.1.2 | [acidanthera/CpuTscSync](https://github.com/acidanthera/CpuTscSync/releases) | TSC sync across cores |
   | CpuTopologyRebuild | 2.0.2 | [b00t0x/CpuTopologyRebuild](https://github.com/b00t0x/CpuTopologyRebuild/releases) | P and E cores as macOS expects them (boot-arg `ctrsmt=off`) |
   | RestrictEvents | 1.1.6 | [acidanthera/RestrictEvents](https://github.com/acidanthera/RestrictEvents/releases) | CPU name (`revcpu=1`, NVRAM `revcpuname`) |
   | USBWakeFixup | 1.0 | [osy/USBWakeFixup](https://github.com/osy/USBWakeFixup/releases) | wake from USB keyboard (with `SSDT-USBW`) |
   | BlueToolFixup | 2.7.2 | [acidanthera/BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM/releases) | Bluetooth on macOS 12+ |
   | IntelBluetoothFirmware, IntelBTPatcher | 2.5.0 | [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware/releases) | Intel Bluetooth |
   | AirportItlwm | 2.4.0 | [OpenIntelWireless/itlwm](https://github.com/OpenIntelWireless/itlwm/releases) | Intel Wi-Fi; take the build for your macOS. The test machine's BE202 needed a patched build that is not published |
   | IntelXe | from the `-efi.zip` | this project | the GPU driver, stage 4 only |
   | HybridPM | | not published yet | the test machine's power management for hybrid CPUs; the entry is disabled. Without it the CPU stayed near 4.4 GHz instead of 5.5 GHz on macOS 26 |

   Leave out what your machine does not have (another Ethernet chip, Wi-Fi card or Bluetooth) and remove its
   `Kernel > Add` entry.
3. **ACPI:** compile `acpi/*.dsl` (`iasl SSDT-EC.dsl` and so on) into `EFI/OC/ACPI`.
   - `SSDT-EC`, `SSDT-HPET`, `SSDT-PLUG-ALT`, `SSDT-RTCAWAC`, `SSDT-USBX` were made by
     [SSDTTime](https://github.com/corpnewt/SSDTTime) from this board's DSDT. On another board, run SSDTTime on yours
     and use its output, including the `ACPI > Patch` entries it lists (the HPET renames and IRQ patches here are this
     board's).
   - `SSDT-XHUB` is this board's USB map. Make your own (for example with USBToolBox on Windows), or remove it and
     map USB another way.
   - `SSDT-PCHWAKE` (with the `HDAS _PRW` rename) stops the onboard audio from waking the machine; `SSDT-USBW` lets a
     USB key press wake it fully. Both name this board's devices; check the paths against your DSDT.
   - `SSDT-ARCOFF` hides the B580 from macOS's generic display driver. Stage 4 of the install guide says how to check
     its path for your board.
4. **Serial numbers:** generate a `MacBookPro16,2` identity with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS)
   and put it in `PlatformInfo > Generic`: `SystemSerialNumber`, `MLB`, `SystemUUID`; `ROM` is the MAC address of your
   Ethernet port (6 bytes).
5. **For the macOS installer (stage 1 of the install guide):** this config is the finished state, so turn it back first.
   The test machine's installer EFI differed from it as follows; put each back after the setup assistant:
   - `IntelXe.kext` and `SSDT-ARCOFF.aml` disabled (they already are here; they come in stage 4);
   - `CpuTopologyRebuild.kext`, `AirportItlwm.kext` and `HybridPM.kext` disabled, and `ctrsmt=off`, `itlwm_he=1`
     removed from the boot-args. So the install needs Ethernet (AppleIGC here);
   - `csr-active-config` = `00000000` and no `amfi_get_out_of_my_way=0x1`, `intelxe_surfvram=2` (stage 2 adds them);
   - `-v` added to the boot-args, to see where it stops. Remove it afterwards: CpuTopologyRebuild warns of random boot
     failures with verbose boot, and the test machine saw that too.

## Settings worth knowing

- **`UEFI > Output > ReconnectGraphicsOnConnect = false`.** With `true`, OpenCore's RELEASE build panics the boot
  (`watchdogd`); see `efi/README.md`.
- **CPU:** Dortania's guide stops at Comet Lake; it has no Alder Lake or Raptor Lake page, so these come from this
  machine, not from the guide. `Kernel > Emulate > Cpuid1Data` `55060A00 00000080 00000000 00000000` with mask
  `FFFFFFFF 0000FF00 00000000 00000000` (Comet Lake's CPUID, plus leaf 1 EBX[23:16] = 0x80, used on macOS 26). On
  macOS 15 this machine hung during multi-CPU start-up with that EBX part and used EAX only: `55060A00 00000000 ...`,
  mask `FFFFFFFF 00000000 ...`. Neither was proven necessary beyond that one machine. Also `ProvideCurrentCpuInfo`,
  `AppleXcpmCfgLock` (for a locked CFG register; drop it if your BIOS unlocks it), CpuTopologyRebuild with `ctrsmt=off`.
- **Booter:** start from [Dortania's Comet Lake page](https://dortania.github.io/OpenCore-Install-Guide/config.plist/comet-lake.html).
  Differences here: `SetupVirtualMap = true` (added on this machine with its macOS 26 boot-hang fixes) and
  `ResizeAppleGpuBars = 10` for the B580's BAR.
- **SMBIOS:** `MacBookPro16,2` is what was tested. It dates from when this machine's display was on the iGPU, where
  `iMac20,1` did not work; Dortania's Comet Lake page suggests `iMac20,1`/`iMac20,2`, not tried with the B580.
- **Boot-args:** `keepsyms=1 debug=0x100` (readable panics, no automatic reboot), `darkwake=0`, `-btlfxboardid`
  (Bluetooth firmware on this SMBIOS), `revcpu=1`, `amfi_get_out_of_my_way=0x1`, `intelxe_surfvram=2`, `ctrsmt=off`,
  `itlwm_he=1` (AirportItlwm option of the patched BE202 build; leave it out with the official one).
- **Security:** `SecureBootModel = Disabled` (with `Default` this machine looped at `macos_seal_system_volume` on
  macOS 26, and the optional system-volume copy of the Metal driver needs `Disabled` anyway), `Vault = Optional`.
