#!/bin/bash
# SPDX-License-Identifier: MIT
# efi.sh: the OpenCore part of intel-gpu-macos-driver, done on macOS: puts this package's IntelXe.kext and SSDT-ARCOFF.aml
# into the EFI that OpenCore booted from, with their config.plist entries, and takes the change back.
#
#   ./efi.sh --status               the EFI compared with this package, one "key=value" per line. Changes nothing.
#   ./efi.sh --plan                 what --apply would change (stage 4 of README-INSTALL.md). Changes nothing.
#   sudo ./efi.sh --apply           back up the whole EFI folder, then make those changes
#   ./efi.sh --settings-plan        what --settings-apply would change (stage 2: SIP, AMFI and surfvram boot-args, quirks)
#   sudo ./efi.sh --settings-apply  back up the whole EFI folder, then make those changes
#   ./efi.sh --undo-plan            what --undo would put back
#   sudo ./efi.sh --undo            put back, from the last backup, the files the last change replaced
#   sudo ./efi.sh --mount           mount the EFI partition (macOS mounts it read-write; it stays mounted until restart)
#
# Which EFI: the partition in OpenCore's NVRAM variable 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path, which OpenCore
# writes when Misc > Security > ExposeSensitiveData includes 1 (--apply adds it). Without it, name the partition with
# --part UUID, its partition UUID (--status lists every EFI partition as "candidate="). Never a disk number: those change
# between boots. --efi DIR works on a folder holding EFI/OC instead (a copy, or an EFI you mounted yourself).
# --package DIR takes the files from that package (default: this script's folder). --expect SHA256 with --apply,
# --settings-apply or --undo: change nothing unless the plan's SHA-256 is that one, the plan that was shown.
# Backups: /Library/Application Support/intel-gpu-macos-driver/efi-backups/<partition UUID>/<NNN-date>/EFI.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PKG=$(cd "$(dirname "$0")" && pwd)
STATE=${INTELXE_STATE_DIR:-/Library/Application Support/intel-gpu-macos-driver}   # tests point it at a throwaway folder
OCGUID=4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102
APPLE=7C436110-AB2A-4BBB-A880-FE41995C9F82
KEXT=IntelXe.kext OLDKEXT=B580.kext SSDT=SSDT-ARCOFF.aml   # intelxe-rename: keep
CMD="" EFIDIR="" PART="" EXPECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --status|--plan|--apply|--settings-plan|--settings-apply|--undo-plan|--undo|--mount) CMD=$1; shift;;
        --package) PKG=$(cd "$2" && pwd); shift 2;;
        --efi) EFIDIR=$(cd "$2" && pwd); shift 2;;
        --part) PART=$(printf '%s' "$2" | tr a-f A-F); shift 2;;
        --expect) EXPECT=$2; shift 2;;
        *) sed -n '3,21p' "$0"; exit 2;;
    esac
done
[ -n "$CMD" ] || { sed -n '3,21p' "$0"; exit 2; }
if [ -n "$PART" ] && ! [[ "$PART" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
    echo "--part takes a partition UUID (see --status, candidate=), not a disk name"; exit 2
fi
T=$(mktemp -d -t intelxe-efi)
trap 'rm -rf "$T"' EXIT

pget() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }   # pget PLIST KEYPATH: the value, or nothing
upper() { tr a-z A-Z; }

# ---- which EFI ----------------------------------------------------------------------------------------------------
boot_path() {
    if [ -n "${INTELXE_BOOT_PATH+x}" ]; then printf '%s\n' "$INTELXE_BOOT_PATH"; else nvram "$OCGUID:boot-path" 2>/dev/null | cut -f2- || true; fi
}
# the GPT partition UUID in a device path such as PciRoot(0x0)/.../HD(1,GPT,<UUID>,0x28,0x64000)/\EFI\OC\OpenCore.efi
boot_uuid() { boot_path | sed -nE 's/.*HD\([0-9]+,GPT,([0-9A-Fa-f-]{36}),.*/\1/p' | head -1 | upper; }

SOURCE=none ROOTDIR="" DEV="" MODEL="" SIZE="" WHERE="" CONTENT="" MP="" KEY="" BOOTREC=no
[ -n "$(boot_uuid)" ] && BOOTREC=yes
if [ -n "$EFIDIR" ]; then
    SOURCE=folder ROOTDIR=$EFIDIR CONTENT=folder
    KEY=folder-$(printf '%s' "$EFIDIR" | shasum -a 256 | cut -c1-12)
else
    if [ -n "$PART" ]; then SOURCE=chosen; else PART=$(boot_uuid); [ -n "$PART" ] && SOURCE=boot-path; fi
    if [ -n "$PART" ]; then
        KEY=$PART
        if diskutil info -plist "$PART" > "$T/part.plist" 2>/dev/null; then
            DEV=$(pget "$T/part.plist" DeviceIdentifier)
            CONTENT=$(pget "$T/part.plist" Content)
            MP=$(pget "$T/part.plist" MountPoint)
            whole=$(pget "$T/part.plist" ParentWholeDisk)
            if [ -n "$whole" ] && diskutil info -plist "$whole" > "$T/disk.plist" 2>/dev/null; then
                MODEL=$(pget "$T/disk.plist" MediaName); [ -n "$MODEL" ] || MODEL=$(pget "$T/disk.plist" IORegistryEntryName)
                SIZE=$(pget "$T/disk.plist" Size)
                [ "$(pget "$T/disk.plist" Internal)" = true ] && WHERE=internal || WHERE=external
            fi
            [ -n "$MP" ] && ROOTDIR=$MP
        fi
    fi
fi
E=${ROOTDIR:+$ROOTDIR/EFI/OC}
CFG=${E:+$E/config.plist}
READABLE=no; [ -n "$CFG" ] && [ -r "$CFG" ] && READABLE=yes
OPENCORE=unknown
if [ -n "$ROOTDIR" ]; then
    if [ -f "$E/OpenCore.efi" ] && [ -f "$CFG" ]; then OPENCORE=yes; elif [ -d "$ROOTDIR/EFI" ]; then OPENCORE=no; fi
fi
gb() { [ -n "$1" ] && awk -v b="$1" 'BEGIN { printf "%.0f GB", b / 1e9 }'; }
describe() { # one line naming the EFI: the disk's model first, so that it can be recognised
    case $SOURCE in
        folder) echo "the folder $ROOTDIR";;
        none) echo "no EFI partition found";;
        *) local how="found through OpenCore's boot-path"; [ $SOURCE = chosen ] && how="chosen by partition UUID"
           echo "${MODEL:-unknown disk}${WHERE:+, $WHERE}${SIZE:+, $(gb "$SIZE")}; ${DEV:-not found} (partition $PART), $how";;
    esac
}

# ---- the package's files and the EFI's ----------------------------------------------------------------------------
PK=$PKG/EFI/OC/Kexts/$KEXT PS=$PKG/EFI/OC/ACPI/$SSDT
[ -f "$PK/Contents/MacOS/IntelXe" ] && [ -f "$PS" ] || { echo "no EFI/OC/Kexts/$KEXT and EFI/OC/ACPI/$SSDT in $PKG"; exit 1; }
kext_state() { # same|different|absent|unknown: the executable and Info.plist compared byte for byte
    [ "$READABLE" = yes ] || { echo unknown; return; }
    local k=$E/Kexts/$KEXT
    if [ ! -e "$k" ]; then echo absent
    elif cmp -s "$k/Contents/MacOS/IntelXe" "$PK/Contents/MacOS/IntelXe" && cmp -s "$k/Contents/Info.plist" "$PK/Contents/Info.plist"; then echo same
    else echo different; fi
}
ssdt_state() {
    [ "$READABLE" = yes ] || { echo unknown; return; }
    if [ ! -e "$E/ACPI/$SSDT" ]; then echo absent; elif cmp -s "$E/ACPI/$SSDT" "$PS"; then echo same; else echo different; fi
}
kext_version() { pget "$1/Contents/Info.plist" CFBundleVersion; }

# the ACPI path of the B580's upstream port (the bridge two PCI levels above the GPU), e.g. \_SB.PC00.PEG1.PEGP;
# "none" when that port has no ACPI name, nothing when there is no B580
card_acpi_path() {
    if [ -n "${INTELXE_CARD_ACPI_PATH+x}" ]; then printf '%s\n' "$INTELXE_CARD_ACPI_PATH"; return 0; fi
    { if [ -n "${INTELXE_IOREG_FILE:-}" ]; then cat "$INTELXE_IOREG_FILE"; else ioreg -p IOService -w0 -l 2>/dev/null || true; fi; } | awk '
        /\+-o / {
            c = index($0, "+-o")
            while (n > 0 && col[n] >= c) n--
            n++; col[n] = c; pci[n] = ($0 ~ /<class IOPCIDevice[,>]/); acpi[n] = ""; did[n] = 0; vid[n] = 0
            next
        }
        n == 0 || done { next }
        /"acpi-path" = "/ { s = $0; sub(/.*"acpi-path" = "/, "", s); sub(/".*/, "", s); acpi[n] = s }
        /"device-id" = <0be20000>/ { did[n] = 1 }
        /"vendor-id" = <86800000>/ { vid[n] = 1 }
        pci[n] && did[n] && vid[n] {
            done = 1; up = 0
            for (k = n - 1; k > 0; k--) if (pci[k] && ++up == 2) break
            s = k > 0 ? acpi[k] : ""
            if (s == "") { print "none"; exit }
            sub(/^IOACPIPlane:\//, "", s); m = split(s, parts, "/"); out = ""
            for (i = 1; i <= m; i++) { p = parts[i]; sub(/@.*/, "", p); out = out (i > 1 ? "." : "") p }
            print "\\" out; exit
        }'
}
CARD=$(card_acpi_path)
# an AML table names \_SB.PC00.PEG1.PEGP as the bytes "_SB_PC00PEG1PEGP": do the table's bytes name the card's port?
aml_names_card() {
    case "$CARD" in ""|none) return 1;; esac
    local seg="" s
    for s in $(printf '%s' "${CARD#\\}" | tr . ' '); do seg=$seg$(printf '%-4s' "$s" | tr ' ' _); done
    LC_ALL=C grep -a -qF "$seg" "$1"
}

# ---- config.plist ---------------------------------------------------------------------------------------------------
count() { local n; n=$(pget "$1" "$2"); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
find_entry() { # find_entry PLIST ARRAY FIELD VALUE: the index of the first entry whose FIELD is VALUE (any case), or nothing
    local n i v want; n=$(count "$1" "$2"); want=$(printf '%s' "$4" | upper)
    for ((i = 0; i < n; i++)); do
        v=$(pget "$1" "$2.$i.$3" | upper)
        [ "$v" = "$want" ] && { echo $i; return 0; }
    done
    return 0
}
entry_state() { # enabled|disabled|absent|unknown
    [ "$READABLE" = yes ] || { echo unknown; return; }
    local i; i=$(find_entry "$CFG" "$1" "$2" "$3")
    if [ -z "$i" ]; then echo absent; elif [ "$(pget "$CFG" "$1.$i.Enabled")" = true ]; then echo enabled; else echo disabled; fi
}

# A plan is two lists: PLAN, the lines shown, and OPS, what --apply does (tab-separated):
#   copy SRC REL           replace EFI/OC/REL with a copy of SRC
#   set KEYPATH TYPE VALUE plutil -replace in config.plist
#   append KEYPATH TYPE VALUE   append to the array at KEYPATH
#   mkdict KEYPATH / mkarray KEYPATH
PLAN=() OPS=() NOTES=()
TAB=$'\t'
op() { local IFS=$TAB; OPS+=("$*"); }

plan_files() {
    local i ks ss pkgok efiok cur
    ks=$(kext_state)
    case $ks in
        absent) PLAN+=("copy     EFI/OC/Kexts/$KEXT (version $(kext_version "$PK"))"); op copy "$PK" "Kexts/$KEXT";;
        different) PLAN+=("replace  EFI/OC/Kexts/$KEXT (version $(kext_version "$E/Kexts/$KEXT") in the EFI, $(kext_version "$PK") in the package; the files differ)")
                   op copy "$PK" "Kexts/$KEXT";;
    esac
    i=$(find_entry "$CFG" Kernel.Add BundlePath "$KEXT")
    if [ -z "$i" ]; then
        PLAN+=("config   Kernel > Add: add $KEXT (ExecutablePath Contents/MacOS/IntelXe, PlistPath Contents/Info.plist, Enabled)")
        op append Kernel.Add json '{"Arch":"Any","BundlePath":"IntelXe.kext","Comment":"IntelXe.kext: intel-gpu-macos-driver","Enabled":true,"ExecutablePath":"Contents/MacOS/IntelXe","MaxKernel":"","MinKernel":"","PlistPath":"Contents/Info.plist"}'
    else
        [ "$(pget "$CFG" Kernel.Add.$i.Enabled)" = true ] || { PLAN+=("config   Kernel > Add, item $i ($KEXT): Enabled false -> true"); op set Kernel.Add.$i.Enabled bool true; }
        cur=$(pget "$CFG" Kernel.Add.$i.ExecutablePath)
        [ "$cur" = Contents/MacOS/IntelXe ] || { PLAN+=("config   Kernel > Add, item $i ($KEXT): ExecutablePath '$cur' -> 'Contents/MacOS/IntelXe'"); op set Kernel.Add.$i.ExecutablePath string Contents/MacOS/IntelXe; }
        cur=$(pget "$CFG" Kernel.Add.$i.PlistPath)
        [ "$cur" = Contents/Info.plist ] || { PLAN+=("config   Kernel > Add, item $i ($KEXT): PlistPath '$cur' -> 'Contents/Info.plist'"); op set Kernel.Add.$i.PlistPath string Contents/Info.plist; }
    fi
    i=$(find_entry "$CFG" Kernel.Add BundlePath "$OLDKEXT")
    if [ -n "$i" ] && [ "$(pget "$CFG" Kernel.Add.$i.Enabled)" = true ]; then
        PLAN+=("config   Kernel > Add, item $i ($OLDKEXT, the earlier name of $KEXT): Enabled true -> false (only one of the two may load)")
        op set Kernel.Add.$i.Enabled bool false
    fi

    # SSDT-ARCOFF only when a table names the card's upstream port: the shipped one names \_SB.PC00.PEG1.PEGP
    ss=$(ssdt_state)
    pkgok=no; aml_names_card "$PS" && pkgok=yes
    efiok=no; [ "$ss" = absent ] || ! aml_names_card "$E/ACPI/$SSDT" || efiok=yes
    if [ -z "$CARD" ]; then
        NOTES+=("not added: $SSDT. No Arc B580 found on this machine, so its ACPI path cannot be checked (stage 4, step 2 of README-INSTALL.md)")
    elif [ "$CARD" = none ]; then
        NOTES+=("not added: $SSDT. The B580's upstream port has no ACPI name on this board; the table needs one more bridge level (stage 4, step 2 of README-INSTALL.md; please open an issue)")
    elif [ $efiok = no ] && [ $pkgok = no ]; then
        NOTES+=("not added: $SSDT. The package's table is for \\_SB.PC00.PEG1.PEGP; the card's port here is $CARD. Put that path into SSDT-ARCOFF.dsl, compile it with iasl and copy it to EFI/OC/ACPI (stage 4, step 2 of README-INSTALL.md); then this adds its entry")
    else
        if [ $efiok = yes ] && [ "$ss" = different ]; then
            NOTES+=("kept: EFI/OC/ACPI/$SSDT differs from the package's but names this card's port ($CARD): yours stays")
        elif [ "$ss" != same ]; then
            if [ "$ss" = absent ]; then cur=copy; else cur=replace; fi
            PLAN+=("$(printf '%-8s' $cur) EFI/OC/ACPI/$SSDT (names $CARD, this card's port)")
            op copy "$PS" "ACPI/$SSDT"
        fi
        i=$(find_entry "$CFG" ACPI.Add Path "$SSDT")
        if [ -z "$i" ]; then
            PLAN+=("config   ACPI > Add: add $SSDT (Enabled)")
            op append ACPI.Add json '{"Comment":"SSDT-ARCOFF: hides the Arc B580 from the generic display driver (intel-gpu-macos-driver)","Enabled":true,"Path":"SSDT-ARCOFF.aml"}'
        elif [ "$(pget "$CFG" ACPI.Add.$i.Enabled)" != true ]; then
            PLAN+=("config   ACPI > Add, item $i ($SSDT): Enabled false -> true"); op set ACPI.Add.$i.Enabled bool true
        fi
    fi

    # so that OpenCore records which EFI it booted from, and the next run finds it without being told
    cur=$(pget "$CFG" Misc.Security.ExposeSensitiveData)
    if [ "$BOOTREC" = no ] && [[ "$cur" =~ ^[0-9]+$ ]] && [ $((cur & 1)) = 0 ]; then
        PLAN+=("config   Misc > Security > ExposeSensitiveData: $cur -> $((cur | 1)) (OpenCore then records which EFI it booted from, for this script)")
        op set Misc.Security.ExposeSensitiveData integer $((cur | 1))
    fi
    return 0
}

# csr-active-config as a number (little-endian data)
csr_value() { local b; b=$(printf '%s' "$1" | base64 -D 2>/dev/null | od -An -tu1 | tr -s ' \n' ' '); set -- $b; echo $(( ${1:-0} | ${2:-0} << 8 | ${3:-0} << 16 | ${4:-0} << 24 )); }
csr_data() { printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $(($1 >> 8 & 255)))\\x$(printf %02x $(($1 >> 16 & 255)))\\x$(printf %02x $(($1 >> 24 & 255)))" | base64; }

plan_settings() {
    local cur v args add=() del re=' (amfi_get_out_of_my_way=(1|0x1)|amfi=(0x80|128)) '
    cur=$(pget "$CFG" Booter.Quirks.ResizeAppleGpuBars)
    [ "$cur" = 10 ] || { PLAN+=("config   Booter > Quirks > ResizeAppleGpuBars: ${cur:-missing} -> 10 (a 1 GB window on the B580's VRAM)"); op set Booter.Quirks.ResizeAppleGpuBars integer 10; }
    cur=$(pget "$CFG" Kernel.Quirks.DisableIoMapper)
    [ "$cur" = true ] || { PLAN+=("config   Kernel > Quirks > DisableIoMapper: ${cur:-missing} -> true"); op set Kernel.Quirks.DisableIoMapper bool true; }
    cur=$(pget "$CFG" UEFI.Output.ReconnectGraphicsOnConnect)
    [ "$cur" = true ] && { PLAN+=("config   UEFI > Output > ReconnectGraphicsOnConnect: true -> false (with true, OpenCore's RELEASE build boots without a console and watchdogd panics)"); op set UEFI.Output.ReconnectGraphicsOnConnect bool false; }
    [ -n "$(pget "$CFG" NVRAM.Add)" ] || { NOTES+=("config.plist has no NVRAM > Add: not changed"); return 0; }
    if [ -z "$(pget "$CFG" NVRAM.Add.$APPLE)" ] && ! plutil -extract NVRAM.Add.$APPLE xml1 -o /dev/null "$CFG" 2>/dev/null; then
        PLAN+=("config   NVRAM > Add > $APPLE: add (missing)"); op mkdict NVRAM.Add.$APPLE
    fi
    cur=$(pget "$CFG" NVRAM.Add.$APPLE.csr-active-config); v=$(csr_value "$cur")
    if [ $((v & 0x803)) != $((0x803)) ]; then
        PLAN+=("config   NVRAM > Add > $APPLE > csr-active-config: $(printf '0x%x' "$v") -> $(printf '0x%x' $((v | 0x803))) (SIP lets unsigned kexts load from the Auxiliary Kernel Collection)")
        op set NVRAM.Add.$APPLE.csr-active-config data "$(csr_data $((v | 0x803)))"
    fi
    args=$(pget "$CFG" NVRAM.Add.$APPLE.boot-args)
    [[ " $args " =~ $re ]] || add+=(amfi_get_out_of_my_way=0x1)
    [[ " $args " == *" intelxe_surfvram="* ]] || add+=(intelxe_surfvram=2)
    if [ ${#add[@]} -gt 0 ]; then
        v=$(printf '%s %s' "$args" "${add[*]}" | sed -E 's/^ +//')
        PLAN+=("config   NVRAM > Add > $APPLE > boot-args: add ${add[*]} ('$args' -> '$v')")
        op set NVRAM.Add.$APPLE.boot-args string "$v"
    fi
    if ! plutil -extract NVRAM.Delete.$APPLE xml1 -o /dev/null "$CFG" 2>/dev/null; then
        PLAN+=("config   NVRAM > Delete > $APPLE: add (missing)"); op mkarray NVRAM.Delete.$APPLE; del=""
    else del=$(plutil -extract NVRAM.Delete.$APPLE xml1 -o - "$CFG" 2>/dev/null); fi
    for v in csr-active-config boot-args; do
        [[ "$del" == *"<string>$v</string>"* ]] || { PLAN+=("config   NVRAM > Delete > $APPLE: add $v (so that the new value replaces the old one at boot)"); op append NVRAM.Delete.$APPLE string $v; }
    done
    return 0
}

# ---- backups --------------------------------------------------------------------------------------------------------
BKD=$STATE/efi-backups/$KEY
last_backup() { # the newest backup not yet put back
    [ -n "$KEY" ] && [ -d "$BKD" ] || return 0
    local b; for b in $(ls -1 "$BKD" 2>/dev/null | grep -E '^[0-9]{3}-' | LC_ALL=C sort -r); do
        [ -e "$BKD/$b/restored" ] || { echo "$BKD/$b"; return 0; }
    done
    return 0
}
plan_undo() {
    local B rel; B=$(last_backup)
    [ -n "$B" ] || { NOTES+=("no backup to put back for this EFI"); return 0; }
    PLAN+=("from     $B ($(cat "$B/kind" 2>/dev/null || echo change), $(cat "$B/date" 2>/dev/null))")
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -e "$B/EFI/OC/$rel" ]; then PLAN+=("restore  EFI/OC/$rel"); else PLAN+=("remove   EFI/OC/$rel (it was not there before)"); fi
    done < "$B/changed"
    if [ -f "$B/config-after.sha256" ] && [ "$(shasum -a 256 < "$CFG" | cut -d' ' -f1)" != "$(cat "$B/config-after.sha256")" ]; then
        NOTES+=("config.plist was changed after that change: putting it back loses those later edits")
    fi
    return 0
}

print_plan() {
    echo "EFI: $(describe)"
    local l
    if [ ${#PLAN[@]} = 0 ]; then echo "nothing to change"; else for l in "${PLAN[@]}"; do echo "$l"; done; fi
    for l in ${NOTES[@]+"${NOTES[@]}"}; do echo "note     $l"; done
}

# ---- doing it -------------------------------------------------------------------------------------------------------
need_root() {
    [ "$SOURCE" = folder ] || [ "$(id -u)" = 0 ] || { echo "$CMD needs root: sudo $0 $CMD"; exit 1; }
}
need_efi() {
    [ "$SOURCE" != none ] || { echo "OpenCore did not record which EFI it booted from; name it: --part UUID (see --status, candidate=)"; exit 1; }
    [ "$SOURCE" = folder ] || [ -n "$DEV" ] || { echo "partition $PART not found"; exit 1; }
    [ "$SOURCE" = folder ] || [ "$CONTENT" = EFI ] || { echo "$DEV is not an EFI partition ($CONTENT)"; exit 1; }
    [ -n "$ROOTDIR" ] || { echo "the EFI partition is not mounted: sudo $0 --mount${PART:+ --part $PART}"; exit 1; }
    [ "$OPENCORE" = yes ] || { echo "no EFI/OC/OpenCore.efi and EFI/OC/config.plist in $ROOTDIR: not an OpenCore EFI"; exit 1; }
    [ "$READABLE" = yes ] || { echo "cannot read $CFG"; exit 1; }
}
check_expect() {
    local h; h=$(print_plan | shasum -a 256 | cut -d' ' -f1)
    [ -z "$EXPECT" ] || [ "$EXPECT" = "$h" ] || { echo "the EFI changed since the plan was shown (plan $h, expected $EXPECT): nothing changed"; exit 1; }
}
backup() { # backup KIND: the whole EFI folder, and the list of what this change touches
    mkdir -p "$BKD"
    local n; n=$(ls -1 "$BKD" | grep -cE '^[0-9]{3}-' || true)
    B=$BKD/$(printf %03d $((n + 1)))-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$B"
    ditto --norsrc --noextattr --noacl "$ROOTDIR/EFI" "$B/EFI"
    echo "$1" > "$B/kind"; date '+%Y-%m-%d %H:%M:%S' > "$B/date"; describe > "$B/where"
    echo "== backup of the whole EFI folder: $B"
}
put_copy() { # put_copy SRC DST: DST replaced by a copy of SRC, without resource forks or extended attributes (FAT)
    rm -rf "$2.new"; ditto --norsrc --noextattr --noacl "$1" "$2.new"; rm -rf "$2"; mv "$2.new" "$2"
}
run_ops() {
    local o a b c d edited=no; local -a changed=()
    cp "$CFG" "$T/config.plist"
    for o in "${OPS[@]}"; do
        IFS=$TAB read -r a b c d <<< "$o"
        case $a in
            copy) mkdir -p "$(dirname "$E/$c")"; put_copy "$b" "$E/$c"; changed+=("$c"); echo "  ok    EFI/OC/$c";;
            set) plutil -replace "$b" -"$c" "$d" "$T/config.plist"; edited=yes;;
            append) plutil -insert "$b" -"$c" "$d" -append "$T/config.plist"; edited=yes;;
            mkdict) plutil -insert "$b" -dictionary "$T/config.plist"; edited=yes;;
            mkarray) plutil -insert "$b" -array "$T/config.plist"; edited=yes;;
        esac
    done
    if [ $edited = yes ]; then
        plutil -convert xml1 "$T/config.plist"   # OpenCore reads XML only
        plutil -lint -s "$T/config.plist" || { echo "  FAIL  the edited config.plist does not parse; the EFI's is unchanged"; exit 1; }
        cp "$T/config.plist" "$CFG.new"; mv -f "$CFG.new" "$CFG"
        changed+=(config.plist); echo "  ok    EFI/OC/config.plist"
        shasum -a 256 < "$CFG" | cut -d' ' -f1 > "$B/config-after.sha256"
    fi
    printf '%s\n' ${changed[@]+"${changed[@]}"} > "$B/changed"
    sync
}
verify_package() { # the EFI files of the package against its SHA256SUMS, when it has one
    [ -f "$PKG/SHA256SUMS" ] || return 0
    (cd "$PKG" && grep -E '  EFI/OC/(Kexts/IntelXe\.kext/|ACPI/SSDT-ARCOFF\.aml$)' SHA256SUMS | shasum -a 256 -c -s) \
        || { echo "the package's EFI files differ from its SHA256SUMS (damaged or changed): nothing changed"; exit 1; }
}

status() {
    local i
    echo "efi_source=$SOURCE"
    echo "efi_partition=$PART"
    echo "efi_device=$DEV"
    echo "efi_disk=$MODEL"
    echo "efi_disk_size=$SIZE"
    echo "efi_disk_location=$WHERE"
    echo "efi_content=$CONTENT"
    [ -n "$ROOTDIR" ] && echo "efi_mounted=yes" || echo "efi_mounted=no"
    echo "efi_mount_point=$ROOTDIR"
    echo "efi_readable=$READABLE"
    echo "efi_description=$(describe)"
    echo "opencore=$OPENCORE"
    echo "boot_path_recorded=$BOOTREC"
    echo "kext_file=$(kext_state)"
    echo "kext_entry=$(entry_state Kernel.Add BundlePath "$KEXT")"
    echo "kext_version_package=$(kext_version "$PK")"
    [ "$READABLE" = yes ] && [ -e "$E/Kexts/$KEXT" ] && echo "kext_version_efi=$(kext_version "$E/Kexts/$KEXT")" || echo "kext_version_efi="
    echo "old_kext_entry=$(entry_state Kernel.Add BundlePath "$OLDKEXT")"
    echo "ssdt_file=$(ssdt_state)"
    echo "ssdt_entry=$(entry_state ACPI.Add Path "$SSDT")"
    echo "card_acpi_path=$CARD"
    aml_names_card "$PS" && echo "ssdt_package_names_card=yes" || echo "ssdt_package_names_card=no"
    if [ "$READABLE" = yes ]; then
        PLAN=() OPS=() NOTES=(); plan_files; echo "plan_changes=${#PLAN[@]}"
        PLAN=() OPS=() NOTES=(); plan_settings; echo "settings_changes=${#PLAN[@]}"
    else echo "plan_changes="; echo "settings_changes="; fi
    i=$(last_backup); echo "backup=${i:-none}"; echo "backup_kind=$( [ -n "$i" ] && cat "$i/kind" 2>/dev/null || true)"
    candidates
}
candidates() { # every EFI partition, "candidate=UUID|device|disk|size|mount point|OpenCore"
    [ "$SOURCE" = folder ] && return 0
    diskutil list -plist > "$T/list.plist" 2>/dev/null || return 0
    local d p n m uuid dev mp disk model oc
    n=$(count "$T/list.plist" AllDisksAndPartitions)
    for ((d = 0; d < n; d++)); do
        m=$(count "$T/list.plist" AllDisksAndPartitions.$d.Partitions)
        for ((p = 0; p < m; p++)); do
            [ "$(pget "$T/list.plist" AllDisksAndPartitions.$d.Partitions.$p.Content)" = EFI ] || continue
            uuid=$(pget "$T/list.plist" AllDisksAndPartitions.$d.Partitions.$p.DiskUUID)
            dev=$(pget "$T/list.plist" AllDisksAndPartitions.$d.Partitions.$p.DeviceIdentifier)
            mp=$(pget "$T/list.plist" AllDisksAndPartitions.$d.Partitions.$p.MountPoint)
            disk=$(pget "$T/list.plist" AllDisksAndPartitions.$d.DeviceIdentifier)
            diskutil info -plist "$disk" > "$T/c.plist" 2>/dev/null || true
            model=$(pget "$T/c.plist" MediaName); [ -n "$model" ] || model=$(pget "$T/c.plist" IORegistryEntryName)
            oc=unknown; [ -n "$mp" ] && { [ -f "$mp/EFI/OC/OpenCore.efi" ] && oc=yes || oc=no; }
            echo "candidate=$uuid|$dev|$model|$(gb "$(pget "$T/c.plist" Size)")|$mp|$oc"
        done
    done
}

case $CMD in
    --status) status;;
    --plan|--settings-plan|--undo-plan)
        need_efi
        case $CMD in --plan) plan_files;; --settings-plan) plan_settings;; --undo-plan) plan_undo;; esac
        print_plan;;
    --apply|--settings-apply)
        need_root; need_efi
        if [ $CMD = --apply ]; then plan_files; verify_package; else plan_settings; fi
        check_expect
        print_plan
        [ ${#OPS[@]} -gt 0 ] || { echo "== nothing to change"; exit 0; }
        B=""; if [ $CMD = --apply ]; then backup "IntelXe files"; else backup settings; fi
        run_ops
        echo "== done. Restart to use it. To go back: sudo $0 --undo${PART:+ --part $PART}"
        ;;
    --undo)
        need_root; need_efi
        plan_undo; check_expect; print_plan
        B=$(last_backup); [ -n "$B" ] || exit 1
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if [ -e "$B/EFI/OC/$rel" ]; then put_copy "$B/EFI/OC/$rel" "$E/$rel"; echo "  ok    restored EFI/OC/$rel"
            else rm -rf "${E:?}/$rel"; echo "  ok    removed EFI/OC/$rel"; fi
        done < "$B/changed"
        date '+%Y-%m-%d %H:%M:%S' > "$B/restored"
        sync
        echo "== done. The backup stays in $B."
        ;;
    --mount)
        need_root
        [ "$SOURCE" != folder ] || { echo "--mount is for a partition, not --efi"; exit 1; }
        [ "$SOURCE" != none ] || { echo "OpenCore did not record which EFI it booted from; name it: --part UUID (see --status, candidate=)"; exit 1; }
        [ "$CONTENT" = EFI ] || { echo "partition $PART is not an EFI partition (${CONTENT:-not found})"; exit 1; }
        echo "== mounting $(describe)"
        [ -n "$MP" ] && { echo "  ok    already mounted at $MP"; exit 0; }
        diskutil mount "$PART"
        ;;
esac
