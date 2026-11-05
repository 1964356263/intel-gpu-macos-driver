# IntelXe Manager

A macOS app for what otherwise takes Terminal: see the state of the machine and the driver, and install, repair, undo, uninstall and
update it. It is a front end: `install.sh` from the package does the work, so a change made here and one made in Terminal are the same
change. **It never changes the EFI:** when `IntelXe.kext` has to change there, it says so and shows the file.

Not in a release yet. Run on the build Mac only (Apple silicon, without the card): **nothing has been installed through it on a real
machine.**

| Page | What |
|---|---|
| System | macOS, processor, card, SIP, AMFI boot-arg, `IntelXe.kext`, Metal device, boot guard; installed version and latest release |
| Driver | choose a package (download the latest release, or a folder you unpacked); check, install, repair, undo, uninstall |
| OpenGL (Zink) | the same for the optional Zink package; on or off for every LWJGL application |
| Log | what the scripts print, while they run |

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
