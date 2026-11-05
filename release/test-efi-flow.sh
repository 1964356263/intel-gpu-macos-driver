#!/bin/bash
# SPDX-License-Identifier: MIT
# test-efi-flow.sh [PACKAGE_DIR]: runs templates/efi.sh against a fake EFI folder made from efi/sample-z790/config.plist,
# set back to how stage 1 leaves it, in a throwaway folder: no root, no EFI partition, no NVRAM. Without PACKAGE_DIR the
# package's IntelXe.kext and SSDT-ARCOFF.aml are stand-ins. Checks status, plan, apply, settings, undo, the plan hash,
# a different kext, the ACPI path check, an earlier B580.kext entry, the boot-path parsing and the ioreg parsing.
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
S=$R/templates/efi.sh
ROOT=$(mktemp -d -t ixeefi)
trap 'rm -rf -- "$ROOT"' EXIT
fails=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

# the package: the real one, or stand-ins
P=$ROOT/pkg
if [ $# -ge 1 ]; then
    mkdir -p "$P"; ditto "$1/EFI" "$P/EFI"; [ -f "$1/SHA256SUMS" ] && cp "$1/SHA256SUMS" "$P/"
else
    mkdir -p "$P/EFI/OC/Kexts/IntelXe.kext/Contents/MacOS" "$P/EFI/OC/ACPI"
    printf 'stand-in IntelXe executable\n' > "$P/EFI/OC/Kexts/IntelXe.kext/Contents/MacOS/IntelXe"
    plutil -create xml1 "$P/EFI/OC/Kexts/IntelXe.kext/Contents/Info.plist"
    plutil -insert CFBundleVersion -string 9.9.9 "$P/EFI/OC/Kexts/IntelXe.kext/Contents/Info.plist"
    printf 'SSDT\x2f\x04_SB_PC00PEG1PEGP stand-in' > "$P/EFI/OC/ACPI/SSDT-ARCOFF.aml"
    (cd "$P" && find EFI -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)
fi

# the EFI as stage 1 leaves it: IntelXe.kext and SSDT-ARCOFF disabled (as in the sample), no SIP/AMFI settings, the quirks
# not set, boot-args not in NVRAM > Delete
F=$ROOT/efi
mkdir -p "$F/EFI/OC/Kexts" "$F/EFI/OC/ACPI" "$F/EFI/BOOT"
: > "$F/EFI/OC/OpenCore.efi"
C=$F/EFI/OC/config.plist
cp "$R/../efi/sample-z790/config.plist" "$C"
A=NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82
plutil -replace $A.csr-active-config -data AAAAAA== "$C"
plutil -replace $A.boot-args -string "keepsyms=1 debug=0x100 darkwake=0 -btlfxboardid revcpu=1 ctrsmt=off" "$C"
plutil -replace Booter.Quirks.ResizeAppleGpuBars -integer -1 "$C"
plutil -replace Kernel.Quirks.DisableIoMapper -bool false "$C"
plutil -replace UEFI.Output.ReconnectGraphicsOnConnect -bool true "$C"
plutil -remove NVRAM.Delete.7C436110-AB2A-4BBB-A880-FE41995C9F82.0 "$C"   # boot-args
cp "$C" "$ROOT/config.stage1"

export INTELXE_STATE_DIR=$ROOT/state INTELXE_BOOT_PATH="" INTELXE_CARD_ACPI_PATH='\_SB.PC00.PEG1.PEGP'
efi() { "$S" --package "$P" --efi "$F" "$@"; }
state() { efi --status | sed -n "s/^$1=//p"; }
expect() { # expect WHAT KEY VALUE
    local got; got=$(state "$2")
    if [ "$got" = "$3" ]; then ok "$1: $2=$got"; else bad "$1: $2=$got, expected $3"; fi
}
has() { # has WHAT FILE TEXT
    if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: no '$3' in:"; sed 's/^/        /' "$2"; fi
}
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1: '$3' in:"; sed 's/^/        /' "$2"; else ok "$1"; fi; }
hash() { shasum -a 256 < "$1" | cut -d' ' -f1; }
pp() { plutil -p "$1"; }   # the parsed contents, for comparing two config.plists

expect "stage 1" opencore yes
expect "stage 1" efi_source folder
expect "stage 1" kext_file absent
expect "stage 1" kext_entry disabled
expect "stage 1" ssdt_file absent
expect "stage 1" ssdt_entry disabled
expect "stage 1" ssdt_package_names_card yes
expect "stage 1" plan_changes 5
expect "stage 1" settings_changes 6
expect "stage 1" backup none

efi --plan > "$ROOT/plan" 2>&1 || bad "--plan exited with an error"
has "plan copies the kext" "$ROOT/plan" "copy     EFI/OC/Kexts/IntelXe.kext"
has "plan enables the kext entry" "$ROOT/plan" "Kernel > Add, item 15 (IntelXe.kext): Enabled false -> true"
has "plan copies the SSDT" "$ROOT/plan" "copy     EFI/OC/ACPI/SSDT-ARCOFF.aml"
has "plan enables the SSDT entry" "$ROOT/plan" "ACPI > Add, item 5 (SSDT-ARCOFF.aml): Enabled false -> true"
has "plan records the boot path from now on" "$ROOT/plan" "ExposeSensitiveData: 6 -> 7"
has "plan names the EFI" "$ROOT/plan" "EFI: the folder $F"

efi --apply --expect 0000 > "$ROOT/out" 2>&1 && bad "--apply with another plan's hash went ahead" || ok "--apply with another plan's hash refuses"
cmp -s "$C" "$ROOT/config.stage1" && [ ! -e "$F/EFI/OC/Kexts/IntelXe.kext" ] && ok "... and changes nothing" || bad "it changed the EFI"

efi --apply --expect "$(hash "$ROOT/plan")" > "$ROOT/out" 2>&1 || { bad "--apply exited with an error"; cat "$ROOT/out"; }
expect "after --apply" kext_file same
expect "after --apply" kext_entry enabled
expect "after --apply" ssdt_file same
expect "after --apply" ssdt_entry enabled
expect "after --apply" plan_changes 0
expect "after --apply" backup_kind "IntelXe files"
cp "$ROOT/config.stage1" "$ROOT/want"
plutil -replace Kernel.Add.15.Enabled -bool true "$ROOT/want"
plutil -replace ACPI.Add.5.Enabled -bool true "$ROOT/want"
plutil -replace Misc.Security.ExposeSensitiveData -integer 7 "$ROOT/want"
[ "$(pp "$C")" = "$(pp "$ROOT/want")" ] && ok "config.plist: those three values changed, the rest is the same" || { bad "config.plist differs from the expected edit:"; diff <(pp "$ROOT/want") <(pp "$C") | head -20; }
head -c 5 "$C" | grep -q '<?xml' && plutil -lint -s "$C" && ok "config.plist stays an XML property list" || bad "config.plist is not XML"
[ -z "$(find "$F" -name '._*')" ] && ok "no AppleDouble files on the EFI" || bad "AppleDouble files on the EFI"
b=$(state backup); [ -f "$b/EFI/OC/config.plist" ] && cmp -s "$b/EFI/OC/config.plist" "$ROOT/config.stage1" && ok "the backup holds the EFI as it was" || bad "backup $b is not the EFI as it was"
cp "$C" "$ROOT/config.files"
efi --plan > "$ROOT/plan" 2>&1; has "plan after --apply" "$ROOT/plan" "nothing to change"

efi --settings-plan > "$ROOT/splan" 2>&1 || bad "--settings-plan exited with an error"
has "settings: ResizeAppleGpuBars" "$ROOT/splan" "ResizeAppleGpuBars: -1 -> 10"
has "settings: DisableIoMapper" "$ROOT/splan" "DisableIoMapper: false -> true"
has "settings: ReconnectGraphicsOnConnect" "$ROOT/splan" "ReconnectGraphicsOnConnect: true -> false"
has "settings: SIP" "$ROOT/splan" "csr-active-config: 0x0 -> 0x803"
has "settings: boot-args" "$ROOT/splan" "add amfi_get_out_of_my_way=0x1 intelxe_surfvram=2"
has "settings: NVRAM > Delete" "$ROOT/splan" "add boot-args (so that"
efi --settings-apply --expect "$(hash "$ROOT/splan")" > "$ROOT/out" 2>&1 || { bad "--settings-apply exited with an error"; cat "$ROOT/out"; }
expect "after --settings-apply" settings_changes 0
[ "$(plutil -extract $A.csr-active-config raw -o - "$C")" = AwgAAA== ] && ok "csr-active-config is 03080000" || bad "csr-active-config"
[ "$(plutil -extract $A.boot-args raw -o - "$C")" = "keepsyms=1 debug=0x100 darkwake=0 -btlfxboardid revcpu=1 ctrsmt=off amfi_get_out_of_my_way=0x1 intelxe_surfvram=2" ] \
    && ok "boot-args: added to, the rest kept" || bad "boot-args: $(plutil -extract $A.boot-args raw -o - "$C")"
plutil -replace $A.csr-active-config -data 7w8AAA== "$C"
expect "a wider SIP setting (0xfef) is kept" settings_changes 0

efi --undo-plan > "$ROOT/uplan" 2>&1
has "undo plan puts config.plist back" "$ROOT/uplan" "restore  EFI/OC/config.plist"
has "undo plan warns about the later edit" "$ROOT/uplan" "config.plist was changed after that change"
efi --undo --expect "$(hash "$ROOT/uplan")" > "$ROOT/out" 2>&1 || { bad "--undo exited with an error"; cat "$ROOT/out"; }
cmp -s "$C" "$ROOT/config.files" && ok "--undo of the settings: config.plist as after --apply" || bad "--undo of the settings"
efi --undo-plan > "$ROOT/uplan" 2>&1
has "second undo removes the kext" "$ROOT/uplan" "remove   EFI/OC/Kexts/IntelXe.kext (it was not there before)"
efi --undo > "$ROOT/out" 2>&1 || { bad "second --undo exited with an error"; cat "$ROOT/out"; }
cmp -s "$C" "$ROOT/config.stage1" && ok "--undo of the files: config.plist byte for byte as in stage 1" || bad "config.plist not back"
expect "after both --undo" kext_file absent
expect "after both --undo" ssdt_file absent
efi --undo > "$ROOT/out" 2>&1 && bad "a third --undo went ahead" || ok "nothing left to undo"
has "... and says so" "$ROOT/out" "no backup to put back"

# a package whose EFI files differ from its SHA256SUMS is not copied
if [ -f "$P/SHA256SUMS" ]; then
    cp -p "$P/EFI/OC/ACPI/SSDT-ARCOFF.aml" "$ROOT/aml"; printf 'x' >> "$P/EFI/OC/ACPI/SSDT-ARCOFF.aml"
    efi --apply > "$ROOT/out" 2>&1 && bad "--apply copied from a damaged package" || has "a damaged package is refused" "$ROOT/out" "differ from its SHA256SUMS"
    cmp -s "$C" "$ROOT/config.stage1" && ok "... and nothing changed" || bad "the EFI changed"
    cp -p "$ROOT/aml" "$P/EFI/OC/ACPI/SSDT-ARCOFF.aml"
fi

# a different IntelXe.kext in the EFI is replaced; the same one is left alone
efi --apply > /dev/null 2>&1
printf 'older build\n' >> "$F/EFI/OC/Kexts/IntelXe.kext/Contents/MacOS/IntelXe"
expect "an older kext in the EFI" kext_file different
efi --plan > "$ROOT/plan" 2>&1; has "plan replaces it" "$ROOT/plan" "replace  EFI/OC/Kexts/IntelXe.kext"
efi --apply > /dev/null 2>&1; expect "after --apply" kext_file same
efi --undo > /dev/null 2>&1; efi --undo > /dev/null 2>&1

# the ACPI path: SSDT-ARCOFF only when a table names the card's port
INTELXE_CARD_ACPI_PATH='\_SB.PC00.PEG0.PEGP' efi --plan > "$ROOT/plan" 2>&1
hasnt "another port: the SSDT is not copied" "$ROOT/plan" "EFI/OC/ACPI/SSDT-ARCOFF.aml"
has "another port: says why" "$ROOT/plan" "the card's port here is \\_SB.PC00.PEG0.PEGP"
INTELXE_CARD_ACPI_PATH=none efi --plan > "$ROOT/plan" 2>&1; has "no ACPI name: says so" "$ROOT/plan" "has no ACPI name"
INTELXE_CARD_ACPI_PATH= efi --plan > "$ROOT/plan" 2>&1; has "no card: says so" "$ROOT/plan" "No Arc B580 found"
printf 'SSDT\x2f\x04_SB_PC00PEG0PEGP my own build' > "$F/EFI/OC/ACPI/SSDT-ARCOFF.aml"
INTELXE_CARD_ACPI_PATH='\_SB.PC00.PEG0.PEGP' efi --plan > "$ROOT/plan" 2>&1
has "your own table for this port is kept" "$ROOT/plan" "kept: EFI/OC/ACPI/SSDT-ARCOFF.aml differs"
has "... and its entry enabled" "$ROOT/plan" "ACPI > Add, item 5 (SSDT-ARCOFF.aml): Enabled false -> true"
rm "$F/EFI/OC/ACPI/SSDT-ARCOFF.aml"

# an earlier B580.kext entry is turned off   # intelxe-rename: keep
plutil -insert Kernel.Add -json '{"BundlePath":"B580.kext","Enabled":true,"ExecutablePath":"Contents/MacOS/B580","PlistPath":"Contents/Info.plist"}' -append "$C"   # intelxe-rename: keep
efi --plan > "$ROOT/plan" 2>&1; has "the earlier name is turned off" "$ROOT/plan" "item 16 (B580.kext, the earlier name of IntelXe.kext): Enabled true -> false"   # intelxe-rename: keep
cp "$ROOT/config.stage1" "$C"

# a recorded boot path: no ExposeSensitiveData change
INTELXE_BOOT_PATH='PciRoot(0x0)/Pci(0x1B,0x4)/Pci(0x0,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)/HD(1,GPT,0b8f5a2c-0000-4000-8000-000000000001,0x28,0x64000)/\EFI\OC\OpenCore.efi%00' efi --plan > "$ROOT/plan" 2>&1
hasnt "with a recorded boot path ExposeSensitiveData stays" "$ROOT/plan" "ExposeSensitiveData"

# OpenCore's boot-path, without --efi: the partition UUID is read from it (this one does not exist)
INTELXE_BOOT_PATH='PciRoot(0x0)/Pci(0x1B,0x4)/Pci(0x0,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)/HD(1,GPT,0b8f5a2c-0000-4000-8000-000000000001,0x28,0x64000)/\EFI\OC\OpenCore.efi%00' \
    "$S" --package "$P" --status > "$ROOT/out" 2>&1
has "boot-path: source" "$ROOT/out" "efi_source=boot-path"
has "boot-path: partition UUID" "$ROOT/out" "efi_partition=0B8F5A2C-0000-4000-8000-000000000001"
has "a partition that is not there: not checked" "$ROOT/out" "kext_file=unknown"
INTELXE_BOOT_PATH='PciRoot(0x0)/HD(1,MBR,0x1234,0x800,0x1000)' "$S" --package "$P" --status > "$ROOT/out" 2>&1
has "no GPT partition in the boot path: none" "$ROOT/out" "efi_source=none"
"$S" --package "$P" --part disk0s1 --status > "$ROOT/out" 2>&1 && bad "--part took a disk number" || ok "--part takes no disk number"
if [ "$(id -u)" != 0 ]; then
    "$S" --package "$P" --part 0B8F5A2C-0000-4000-8000-000000000001 --apply > "$ROOT/out" 2>&1
    has "--apply on a partition needs root" "$ROOT/out" "needs root"
fi

# the card's ACPI path from ioreg's IOService plane: the bridge two PCI levels above the GPU
cat > "$ROOT/ioreg" <<'EOF'
+-o Root  <class IORegistryEntry, id 0x100000100, retain 30>
  +-o PC00@0  <class IOPCIDevice, id 0x100000200, registered, matched, active, busy 0 (1 ms), retain 20>
  | | {
  | |   "acpi-path" = "IOACPIPlane:/_SB/PC00@0"
  | | }
  | +-o PEG1@1  <class IOPCIDevice, id 0x100000300, registered, matched, active, busy 0 (1 ms), retain 12>
  | | | {
  | | |   "acpi-path" = "IOACPIPlane:/_SB/PC00@0/PEG1@10000"
  | | | }
  | | +-o IOPP  <class IOPCI2PCIBridge, id 0x100000310, registered, matched, active, busy 0 (1 ms), retain 8>
  | |   +-o PEGP@0  <class IOPCIDevice, id 0x100000400, registered, matched, active, busy 0 (1 ms), retain 12>
  | |   | | {
  | |   | |   "vendor-id" = <86800000>
  | |   | |   "device-id" = <e2e20000>
  | |   | |   "acpi-path" = "IOACPIPlane:/_SB/PC00@0/PEG1@10000/PEGP@0"
  | |   | | }
  | |   | +-o IOPP  <class IOPCI2PCIBridge, id 0x100000410, registered, matched, active, busy 0 (1 ms), retain 8>
  | |   |   +-o pci-bridge@1  <class IOPCIDevice, id 0x100000500, registered, matched, active, busy 0 (1 ms), retain 12>
  | |   |   | | {
  | |   |   | |   "vendor-id" = <86800000>
  | |   |   | |   "device-id" = <e3e20000>
  | |   |   | | }
  | |   |   | +-o IOPP  <class IOPCI2PCIBridge, id 0x100000510, registered, matched, active, busy 0 (1 ms), retain 8>
  | |   |   |   +-o display@0  <class IOPCIDevice, id 0x100000600, registered, matched, active, busy 0 (1 ms), retain 12>
  | |   |   |   | {
  | |   |   |   |   "device-id" = <0be20000>
  | |   |   |   |   "vendor-id" = <86800000>
  | |   |   |   | }
  | |   |   |   +-o pci8086,e2f7@0,1  <class IOPCIDevice, id 0x100000700, registered, matched, active, busy 0 (1 ms), retain 9>
  | +-o RP01@1C  <class IOPCIDevice, id 0x100000800, registered, matched, active, busy 0 (1 ms), retain 12>
EOF
got=$(env -u INTELXE_CARD_ACPI_PATH INTELXE_IOREG_FILE="$ROOT/ioreg" "$S" --package "$P" --efi "$F" --status | sed -n 's/^card_acpi_path=//p')
[ "$got" = '\_SB.PC00.PEG1.PEGP' ] && ok "ioreg: the card's port is $got" || bad "ioreg: card_acpi_path=$got"
sed '/PEG1@10000\/PEGP@0/d' "$ROOT/ioreg" > "$ROOT/ioreg2"
got=$(env -u INTELXE_CARD_ACPI_PATH INTELXE_IOREG_FILE="$ROOT/ioreg2" "$S" --package "$P" --efi "$F" --status | sed -n 's/^card_acpi_path=//p')
[ "$got" = none ] && ok "ioreg: a port without an ACPI name is 'none'" || bad "ioreg without the port's name: $got"
grep -v 0be20000 "$ROOT/ioreg" > "$ROOT/ioreg3"
got=$(env -u INTELXE_CARD_ACPI_PATH INTELXE_IOREG_FILE="$ROOT/ioreg3" "$S" --package "$P" --efi "$F" --status | sed -n 's/^card_acpi_path=//p')
[ -z "$got" ] && ok "ioreg: no card, no path" || bad "ioreg without a card: $got"

echo "== $fails failure(s)"
exit $fails
