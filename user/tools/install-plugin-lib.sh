#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh: libC3 = libC with plugin sc6dn (speccst6 + b580-webkit-armed.patch + b580-webkit-devnull.patch: /dev/null by dup where a sandbox refuses it;
# the arm state from IOAccelDisplayPipeCapabilities
# where WebKit sandboxes NMXAutoArm; NVMTLDriver eba1965f, translator aa356713; speccst6 was recover1 +
# function constants as specialization constants) as /Library/GPUBundles/NVMTLDriverLib.bundle - NMXAccel nmx-ssv2's
# fallback when the system copy (/System/Library/Extensions/NVMTLDriver.bundle, ssv-install.sh) is absent - and REMOVES
# /Library/GPUBundles/NVMTLDriver.bundle, which would shadow the system copy (Metal's bundle lookup takes the first
# NVMTLDriver.bundle it finds, /Library/GPUBundles before /System/Library/Extensions, and WebKit's GPU process cannot
# load it from /Library). Companions stay in /Library/GPUBundles/nvmtl (Mesa there: d8860b17).
# Refuses files that differ from SHA256SUMS or carry no code signature. Takes effect for processes started afterwards.
#   install.sh           back up /Library/GPUBundles/NVMTLDriver.bundle and NVMTLDriverLib.bundle (what exists) to
#                        ./previous/ (once), install NVMTLDriverLib.bundle, remove NVMTLDriver.bundle
#   install.sh --undo    put ./previous/ back exactly (NVMTLDriver.bundle restored; NVMTLDriverLib.bundle restored or removed)
set -euo pipefail
L=/Library/GPUBundles; P=$L/NVMTLDriverLib.bundle; X=$L/NVMTLDriver.bundle
H=$(cd "$(dirname "$0")" && pwd); B=$H/previous
sig() { "$H/sigcheck" "$1" >/dev/null || { "$H/sigcheck" "$1"; echo "REFUSED: $1 is not signed"; exit 1; }; }
sigs() { local m; for m in "$1/Contents/MacOS/NVMTLDriver" "$1/Contents/MacOS/libnvmtl_translate.dylib" $(find "$1/Contents/MacOS/air-runtime" -name '*.dylib'); do sig "$m"; done; }
put() { sigs "$1"; sudo rm -rf "$2.new" "$2.old"; sudo ditto "$1" "$2.new"; sudo chown -R root:wheel "$2.new"
        { [ ! -e "$2" ] || sudo mv "$2" "$2.old"; }; sudo mv "$2.new" "$2"; sudo rm -rf "$2.old"; }
if [ "${1:-}" = --undo ]; then
    [ -d "$B" ] || { echo "no $B"; exit 1; }
    if [ -d "$B/NVMTLDriver.bundle" ]; then put "$B/NVMTLDriver.bundle" "$X"; echo "restored $X"; fi
    if [ -d "$B/NVMTLDriverLib.bundle" ]; then put "$B/NVMTLDriverLib.bundle" "$P"; echo "restored $P"
    else sudo rm -rf "$P"; echo "removed $P (there was none before)"; fi
    exit 0
fi
(cd "$H" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "REFUSED: files differ from SHA256SUMS"; exit 1; }
if [ ! -f "$B/.taken" ]; then
    mkdir -p "$B"
    [ ! -d "$X" ] || { sudo ditto "$X" "$B/NVMTLDriver.bundle"; sudo chown -R "$(id -un)" "$B/NVMTLDriver.bundle"; }
    [ ! -d "$P" ] || { sudo ditto "$P" "$B/NVMTLDriverLib.bundle"; sudo chown -R "$(id -un)" "$B/NVMTLDriverLib.bundle"; }
    touch "$B/.taken"
fi
put "$H/NVMTLDriverLib.bundle" "$P"
sudo rm -rf "$X"
echo "installed $P ($(shasum -a 256 "$P/Contents/MacOS/NVMTLDriver" | cut -c1-12)); removed $X (backup in $B)"
