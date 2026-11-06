#!/bin/bash
# SPDX-License-Identifier: MIT
# hidpi.sh: HiDPI modes ("Larger Text ... More Space" in System Settings > Displays) for the monitor on the Arc B580.
# Needs IntelXeFB from release 0.1.3 on. Changes take effect after a restart.
#
#   ./hidpi.sh              what is set now (read-only)
#   ./hidpi.sh --status     the same as key=value lines (for IntelXe Manager)
#   sudo ./hidpi.sh --on    turns them on: NVRAM intelxefb-hidpi=1 (the framebuffer offers scaled modes, scaled on the
#                           GPU), a display override with HiDPI sizes for the connected monitor, and WindowServer's
#                           DisplayResolutionEnabled; restart afterwards
#   sudo ./hidpi.sh --off   takes back what --on wrote; restart afterwards
#
# The override goes to /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>, the
# place and format other HiDPI tools use (one-key-hidpi): scale-resolutions entries of twice each "looks like" size. An
# override this script did not write is left alone (--on stops; remove it yourself or keep using it).
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH   # ioreg, nvram and plutil wherever this is started from
OVR=/Library/Displays/Contents/Resources/Overrides
WS=/Library/Preferences/com.apple.windowserver
BK="/Library/Application Support/intel-gpu-macos-driver"
MARK=IntelXeHiDPI                      # a key in the override: written by this script
MAXW=4096 MAXH=2304                    # the largest scaled size IntelXeFB accepts (its IOFBScalerInfo)

display_ids() { # vid pid (decimal) of the connected monitor
    ioreg -lw0 -r -c IODisplayConnect 2>/dev/null | awk -F' = ' '/"DisplayVendorID"/{v=$2} /"DisplayProductID"/{p=$2} END{if (v != "" && p != "") print v, p}'
}
native_size() { # WxH of the panel: the first size in IntelXeFB's mode list
    ioreg -lw0 -r -c IntelXeFramebuffer 2>/dev/null | sed -n 's/.*"IntelXeFBModes" = "\([0-9]*x[0-9]*\).*/\1/p' | head -1
}
fb_supports() { # the installed IntelXeFB knows intelxefb-hidpi
    grep -qa "intelxefb-hidpi" /Library/Extensions/IntelXeFB.kext/Contents/MacOS/IntelXeFB 2>/dev/null
}
ovr_path() { printf '%s/DisplayVendorID-%x/DisplayProductID-%x' "$OVR" "$1" "$2"; }

status() {
    local ids vid="" pid="" f nv ws fbp
    ids=$(display_ids)
    if [ -n "$ids" ]; then read -r vid pid <<<"$ids"; fi   # an if: a failed && list ends the script under bash 3.2's set -e
    nv=$(nvram intelxefb-hidpi 2>/dev/null | cut -f2 || true); [ "$nv" = 1 ] || nv=0   # unset: nvram fails
    ws=$(defaults read "$WS" DisplayResolutionEnabled 2>/dev/null || echo 0)
    fbp=$(ioreg -lw0 -r -c IntelXeFramebuffer 2>/dev/null | grep -c '"IOFBScalerInfo"' || true)
    local ovr=none
    if [ -n "$vid" ]; then
        f=$(ovr_path "$vid" "$pid")
        if [ -f "$f" ]; then
            if /usr/libexec/PlistBuddy -c "Print :$MARK" "$f" >/dev/null 2>&1; then ovr=ours; else ovr=other; fi
        fi
    fi
    echo "hidpi_supported=$(fb_supports && echo 1 || echo 0)"
    echo "hidpi_nvram=$nv"
    echo "hidpi_override=$ovr"
    echo "hidpi_windowserver=$ws"
    echo "hidpi_active=$([ "$fbp" -gt 0 ] 2>/dev/null && echo 1 || echo 0)"
    echo "display=${vid:+$(printf '%04x:%04x' "$vid" "$pid")}"
    echo "native=$(native_size)"
}

human() {
    local s; s=$(status)
    get() { sed -n "s/^$1=//p" <<<"$s"; }
    echo "== HiDPI modes for the Arc B580"
    echo "  framebuffer support (0.1.3+)   $( [ "$(get hidpi_supported)" = 1 ] && echo yes || echo 'no: install release 0.1.3 or later first')"
    echo "  monitor                        $(get display) $(get native)"
    echo "  NVRAM intelxefb-hidpi          $(get hidpi_nvram)"
    echo "  display override               $(get hidpi_override)"
    echo "  DisplayResolutionEnabled       $(get hidpi_windowserver)"
    echo "  in effect this boot            $( [ "$(get hidpi_active)" = 1 ] && echo yes || echo no)"
}

entry() { # entry W H [flags setflags]: base64 of the big-endian words
    local hex; hex=$(printf '%08x%08x' "$1" "$2"); shift 2
    for x in "$@"; do hex+=$(printf '%08x' "$x"); done
    printf '%s' "$hex" | xxd -r -p | base64
}

on() {
    [ "$(id -u)" = 0 ] || { echo "--on needs root: sudo $0 --on"; exit 1; }
    fb_supports || { echo "IntelXeFB does not support HiDPI modes yet: install release 0.1.3 or later first"; exit 1; }
    local ids vid pid size w h f tmp
    ids=$(display_ids); [ -n "$ids" ] || { echo "no monitor found (IODisplayConnect)"; exit 1; }
    read -r vid pid <<<"$ids"
    size=$(native_size); [ -n "$size" ] || { echo "IntelXeFB's panel size not found"; exit 1; }
    w=${size%x*} h=${size#*x}
    f=$(ovr_path "$vid" "$pid")
    if [ -f "$f" ] && ! /usr/libexec/PlistBuddy -c "Print :$MARK" "$f" >/dev/null 2>&1; then
        echo "$f exists and was not written by this script: left as it is (remove it first to use this one)"; exit 1
    fi
    # "looks like" sizes: the panel times 4/5, 3/4, 2/3, 5/8 and 1/2 (scale 125, 133, 150, 160, 200 %), even, whose
    # doubles IntelXeFB can take (2560x1440: 2048x1152, 1920x1080, 1706x960, 1600x900, 1280x720)
    local looks=() fx
    for fx in 4/5 3/4 2/3 5/8 1/2; do
        local lw=$(( (w * ${fx%/*} / ${fx#*/}) & ~1 )) lh=$(( (h * ${fx%/*} / ${fx#*/}) & ~1 ))
        if [ $((2 * lw)) -le $MAXW ] && [ $((2 * lh)) -le $MAXH ]; then looks+=("$lw $lh"); fi
    done
    [ ${#looks[@]} -gt 0 ] || { echo "no HiDPI size fits for a ${size} panel (IntelXeFB takes up to ${MAXW}x${MAXH})"; exit 1; }
    tmp=$(mktemp -t hidpi)
    plutil -create xml1 "$tmp"
    plutil -insert DisplayVendorID -integer "$vid" "$tmp"
    plutil -insert DisplayProductID -integer "$pid" "$tmp"
    plutil -insert "$MARK" -bool YES "$tmp"
    plutil -insert target-default-ppmm -float 10.0699301 "$tmp"
    plutil -insert scale-resolutions -array "$tmp"
    # each size four ways, as one-key-hidpi writes them (with fewer kinds macOS did not offer the HiDPI modes, B580 test)
    local n=0 l lw lh
    for l in "${looks[@]}"; do read -r lw lh <<<"$l"; plutil -insert "scale-resolutions.$n" -data "$(entry $((2*lw)) $((2*lh)))" "$tmp"; n=$((n+1)); done
    for l in "${looks[@]}"; do read -r lw lh <<<"$l"; plutil -insert "scale-resolutions.$n" -data "$(entry $((2*lw)) $((2*lh)) 1 $((0x00200000)))" "$tmp"; n=$((n+1)); done
    for l in "${looks[@]}"; do read -r lw lh <<<"$l"; plutil -insert "scale-resolutions.$n" -data "$(entry $((2*lw)) $((2*lh)) 1)" "$tmp"; n=$((n+1)); done
    for l in "${looks[@]}"; do read -r lw lh <<<"$l"; plutil -insert "scale-resolutions.$n" -data "$(entry $((2*lw)) $((2*lh)) 9 $((0x00A00000)))" "$tmp"; n=$((n+1)); done
    plutil -lint "$tmp" >/dev/null
    mkdir -p "$(dirname "$f")" "$BK"
    install -o root -g wheel -m 644 "$tmp" "$f"; rm -f "$tmp"
    echo "  ok    $f (${#looks[@]} sizes: $(printf '%s ' "${looks[@]/ /x}"))"
    # remember whether DisplayResolutionEnabled was already on, so --off leaves it as it found it
    if [ ! -f "$BK/hidpi-ws-was-set" ]; then
        defaults read "$WS" DisplayResolutionEnabled >/dev/null 2>&1 && echo 1 > "$BK/hidpi-ws-was-set" || echo 0 > "$BK/hidpi-ws-was-set"
    fi
    defaults write "$WS" DisplayResolutionEnabled -bool YES
    echo "  ok    DisplayResolutionEnabled"
    nvram intelxefb-hidpi=1
    echo "  ok    NVRAM intelxefb-hidpi=1"
    echo "== restart; then choose a size in System Settings > Displays"
}

off() {
    [ "$(id -u)" = 0 ] || { echo "--off needs root: sudo $0 --off"; exit 1; }
    local ids vid pid f
    ids=$(display_ids)
    if [ -n "$ids" ]; then
        read -r vid pid <<<"$ids"; f=$(ovr_path "$vid" "$pid")
        if [ -f "$f" ] && /usr/libexec/PlistBuddy -c "Print :$MARK" "$f" >/dev/null 2>&1; then rm -f "$f"; echo "  ok    removed $f"
        elif [ -f "$f" ]; then echo "  keep  $f (not written by this script)"; fi
    fi
    if [ -f "$BK/hidpi-ws-was-set" ]; then
        [ "$(cat "$BK/hidpi-ws-was-set")" = 1 ] || { defaults delete "$WS" DisplayResolutionEnabled 2>/dev/null || true; echo "  ok    DisplayResolutionEnabled removed"; }
        rm -f "$BK/hidpi-ws-was-set"
    fi
    nvram intelxefb-hidpi=0   # nvram -d does not delete on some macOS 26 machines; 0 reads as off
    echo "  ok    NVRAM intelxefb-hidpi=0"
    echo "== restart; a HiDPI size chosen before goes back to the panel's own"
}

case "${1:-}" in
    "") human ;;
    --status) status ;;
    --on) on ;;
    --off) off ;;
    *) sed -n '3,15p' "$0"; exit 2 ;;
esac
