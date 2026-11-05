#!/bin/bash
# SPDX-License-Identifier: MIT
# package.sh: build the release zips from staged binaries and this directory's templates (macOS, uses ditto).
#
#   release/package.sh VERSION TAHOE_DIR SEQUOIA_DIR OUT_DIR
#
# TAHOE_DIR / SEQUOIA_DIR hold the binaries in the package layout (EFI/, Library/, system-volume/, LICENSES/, sigcheck,
# SOURCES.md), e.g. the unpacked previous release. install.sh and README-INSTALL.md come from templates/ with @VER@,
# @MACOS@, @MAJOR@, @CODENAME@ and @TESTED@ filled in, Library/GPUBundles/nvmtl-allow.txt comes from release/; SHA256SUMS is
# regenerated. The filled Tahoe copies are also
# written next to this script (release/install.sh, release/README-INSTALL.md), for reading in the repository.
# Writes to OUT_DIR:
#   intel-gpu-macos-driver-VERSION-tahoe.zip, -sequoia.zip   (unpack on macOS: ditto -x -k)
#   intel-gpu-macos-driver-VERSION-efi.zip                    (the OpenCore pieces, the same in both; any system)
#   intel-gpu-macos-driver-VERSION.sha256
# With ZINK_DIR set in the environment also intel-gpu-macos-driver-VERSION-zink-gl.zip (see below).
set -euo pipefail
[ $# = 4 ] || { sed -n '3,16p' "$0"; exit 2; }
VER=$1 T=$2 S=$3 OUT=$4
R=$(cd "$(dirname "$0")" && pwd)
N=intel-gpu-macos-driver-$VER
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

# the OpenCore pieces must be identical in both, or the one -efi.zip would be wrong for one of them
for f in EFI/OC/Kexts/IntelXe.kext/Contents/MacOS/IntelXe EFI/OC/Kexts/IntelXe.kext/Contents/Info.plist \
         EFI/OC/ACPI/SSDT-ARCOFF.aml EFI/OC/ACPI/SSDT-ARCOFF.dsl; do
    cmp -s "$T/$f" "$S/$f" || { echo "differs between the Tahoe and Sequoia inputs: $f"; exit 1; }
done

fill() { # fill SRC DST codename
    local macos major tested
    case $3 in
        tahoe) macos="macOS 26 Tahoe"; major=26
               tested="Experimental. Tested on one machine only: an Arc B580 in a Z790 desktop, macOS 26.7.1, OpenCore.";;
        sequoia) macos="macOS 15 Sequoia"; major=15
               tested="Experimental. **Not re-tested on Sequoia:** this package is built from the same sources as the Tahoe package, which was tested on one machine (an Arc B580 in a Z790 desktop, macOS 26.7.1, OpenCore); only NMXAccel is built for macOS 15. The same machine ran the previous build of this stack on macOS 15 until 4 November 2026.";;
    esac
    sed -e "s|@VER@|$VER|g" -e "s|@MACOS@|$macos|g" -e "s|@MAJOR@|$major|g" -e "s|@CODENAME@|$3|g" \
        -e "s|@TESTED@|$tested|g" "$1" > "$2"
    ! grep -n '@[A-Z]*@' "$2" || { echo "unfilled placeholder in $2"; exit 1; }
}

zipdir() { # zipdir PARENT NAME: NAME.zip with Unix modes, no resource forks, no extended attributes
    rm -f "$OUT/$2.zip"
    (cd "$1" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$2" "$OUT/$2.zip")
}

W=$(mktemp -d -t ixepkg)
trap 'rm -rf "$W"' EXIT
for c in tahoe sequoia; do
    src=$T; [ $c = sequoia ] && src=$S
    d=$W/$N-$c
    mkdir -p "$d"
    for x in EFI Library system-volume LICENSES sigcheck SOURCES.md; do ditto "$src/$x" "$d/$x"; done
    cp "$R/nvmtl-allow.txt" "$d/Library/GPUBundles/nvmtl-allow.txt"   # the allow-list is kept in the repository
    fill "$R/templates/install.sh" "$d/install.sh" $c; chmod 755 "$d/install.sh"
    fill "$R/templates/README-INSTALL.md" "$d/README-INSTALL.md" $c
    if [ $c = tahoe ]; then cp "$d/install.sh" "$R/install.sh"; cp "$d/README-INSTALL.md" "$R/README-INSTALL.md"; fi
    xattr -cr "$d"
    (cd "$d" && find . -type f ! -name SHA256SUMS ! -path './system-volume/*' | sed 's#^\./##' | LC_ALL=C sort |
        while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS
     find system-volume -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done >> SHA256SUMS)
    (cd "$d" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "SHA256SUMS check failed in $d"; exit 1; }
    (cd "$d/system-volume" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "system-volume/SHA256SUMS does not match"; exit 1; }
    zipdir "$W" "$N-$c"
done

e=$W/$N-efi
mkdir -p "$e"
ditto "$T/EFI" "$e/EFI"
cat > "$e/README.txt" <<EOF
intel-gpu-macos-driver $VER: the OpenCore pieces (the same for macOS 26 Tahoe and macOS 15 Sequoia)

EFI/OC/Kexts/IntelXe.kext       -> EFI/OC/Kexts/, config.plist Kernel > Add
EFI/OC/ACPI/SSDT-ARCOFF.aml     -> EFI/OC/ACPI/, config.plist ACPI > Add (check the ACPI path first)
EFI/OC/ACPI/SSDT-ARCOFF.dsl     its source, to adapt with iasl when your board's path differs

Add them in stage 4 of README-INSTALL.md (in the macOS package, and at
https://github.com/yusufklncc/intel-gpu-macos-driver/blob/v$VER/release/README-INSTALL.md), after
"sudo ./install.sh --apply" on macOS and before the reboot. Not earlier: SSDT-ARCOFF hides the B580 from
the display driver that shows the macOS installer.
EOF
xattr -cr "$e"
(cd "$e" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)
zipdir "$W" "$N-efi"

# ZINK_DIR: built zink-gl binaries (lib/, vulkan/, bin/, sigcheck): adds the optional -zink-gl.zip from zink-gl/ in this
# repository. Without it no zink package is made.
ZIPS=("$N-tahoe.zip" "$N-sequoia.zip" "$N-efi.zip")
if [ -n "${ZINK_DIR:-}" ]; then
    z=$W/$N-zink-gl
    mkdir -p "$z"
    ditto "$R/../zink-gl" "$z"
    for x in lib vulkan bin sigcheck; do ditto "$ZINK_DIR/$x" "$z/$x"; done
    chmod 755 "$z/install.sh" "$z/zink-gl-version.sh" "$z/sigcheck"
    xattr -cr "$z"
    (cd "$z" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)
    zipdir "$W" "$N-zink-gl"
    ZIPS+=("$N-zink-gl.zip")
fi
(cd "$OUT" && shasum -a 256 "${ZIPS[@]}" > "$N.sha256")
cat "$OUT/$N.sha256"
