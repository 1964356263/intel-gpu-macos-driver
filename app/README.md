# IntelXe Manager

A macOS app for what otherwise takes Terminal: see the state of the machine and the driver, and install, repair, undo, uninstall and
update it, and do stages 2 and 4 of the install guide in the OpenCore EFI. It is a front end: `install.sh` and `efi.sh` from the package
do the work, so a change made here and one made in Terminal are the same change.

Not in a release yet. The Driver page's install was used on the test machine (test packages of 0.1.3); **the EFI page has not been run
on a real machine yet**, only against fake EFI folders on the build Mac (Apple silicon, without the card).

| Page | What |
|---|---|
| System | macOS, processor, card, SIP, AMFI boot-arg, `IntelXe.kext`, Metal device, boot guard; installed version and latest release |
| Driver | choose a package (download the latest release, or a folder you unpacked); check, install, repair, undo, uninstall |
| EFI (OpenCore) | the EFI OpenCore booted from: mount it; `IntelXe.kext` and `SSDT-ARCOFF.aml` with their `config.plist` entries (stage 4); SIP, boot-args and quirks (stage 2, separate); undo the last change |
| OpenGL (Zink) | the same for the optional Zink package; on or off for every LWJGL application |
| Log | what the scripts print, while they run |

After an install the app compares the EFI's `IntelXe.kext` with the package's (executable and `Info.plist`, byte for byte). It
warns only when they differ, the kext or its `Kernel > Add` entry is missing or off, or the EFI could not be read (then it says
"could not be checked", not "update it").

### The EFI page

`efi.sh` decides what changes; the app shows it. **Which EFI:** OpenCore's NVRAM variable
`4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path` names the partition it booted from, which `diskutil` resolves by its
partition UUID; disk numbers are never used, they change between boots. OpenCore writes that variable only when
`Misc > Security > ExposeSensitiveData` includes 1 (`efi/sample-z790` has 6, without it): then the page lists the EFI
partitions with their disk's name and size to choose from, remembers the choice by UUID, and the stage-4 change adds 1
to `ExposeSensitiveData` so that the next boot records it.

**Every write** shows the disk (name, internal or external, size, device, partition UUID) and efi.sh's plan, line by
line, then asks; the password dialog follows. The app passes the plan's SHA-256 with the command, and efi.sh writes
nothing if the EFI no longer gives that plan. Before a change efi.sh copies the whole EFI folder to
`/Library/Application Support/intel-gpu-macos-driver/efi-backups/<partition UUID>/<NNN-date>/`; **Undo** puts back,
from the newest backup, only the files that change touched (`config.plist`, `IntelXe.kext`, `SSDT-ARCOFF.aml`), and
each undo goes one change further back.

- **Stage 4:** copies `IntelXe.kext` when it is missing or differs, adds or enables its `Kernel > Add` entry (and turns
  off an earlier `B580.kext` entry), copies `SSDT-ARCOFF.aml` and adds or enables its `ACPI > Add` entry, but only when
  a table names the B580's upstream port as `ioreg` shows it (`\_SB.PC00.PEG1.PEGP` for the shipped one). With another
  path it says so and leaves the SSDT out; an `SSDT-ARCOFF.aml` of your own that names the port is kept.
- **Stage 2 (separate button):** `csr-active-config` with at least `0x803` (a wider value stays), `amfi_get_out_of_my_way=0x1`
  and `intelxe_surfvram=2` added to the boot-args (the rest kept), `csr-active-config` and `boot-args` in
  `NVRAM > Delete`, `ResizeAppleGpuBars = 10`, `DisableIoMapper = true`, `ReconnectGraphicsOnConnect = false`.
- `config.plist` is edited with `plutil` on a copy, written back as XML and checked with `plutil -lint` before it
  replaces the EFI's. The values are kept; dictionary keys come out in plutil's (alphabetical) order.
- Nothing for stage 1: installing macOS needs another machine or the USB installer.

Changes go through the macOS administrator password dialog (`osascript ... with administrator privileges`); there is no helper tool and
nothing stays running. A download is compared with the `.sha256` file of the same GitHub release. That finds a damaged file, it does
not prove who made the release. Files go to `~/Library/Application Support/IntelXe Manager`. It contacts only GitHub, and sends no data.

English and Turkish, following the system language (`Resources/`).

## Building

`app/build.sh OUTDIR` needs the Command Line Tools and gives a universal, ad-hoc signed `IntelXe Manager.app`. `@State` is avoided, because
on the macOS 27 SDK it is a macro and the Command Line Tools have no SwiftUI macro plugin.

## Testing without the card

- `IntelXeManager --selftest [PACKAGE] [--snapshot FOLDER]`: version comparison, hash list, quoting, a release as GitHub sends it, the facts
  read from this machine, the package's `--status` and `--check`, and a PNG of each page.
- `release/test-install-flow.sh PACKAGE`: `install.sh` through install, damage, repair, undo and uninstall, in a throwaway root, with `kmutil`
  and the root checks stubbed. It does not test the real kernel collection step.
- `release/test-efi-flow.sh [PACKAGE]`: `efi.sh` against a fake EFI folder made from `efi/sample-z790/config.plist` as stage 1 leaves it:
  status, plans, apply, settings, undo, the plan hash, the ACPI path check, the boot-path and `ioreg` parsing. No root, no partition.
- With a package, `--selftest` also runs efi.sh through the app's own functions against a fake EFI (plan, hash, apply, the notice after
  an install, undo), and `--snapshot` adds the EFI page. Not tested without the real machine: OpenCore's `boot-path` on a real boot,
  mounting a real EFI partition, the password dialog, and `ioreg` with a real B580.
