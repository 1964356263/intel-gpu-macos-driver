#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh: fix32 = fix31 + fix32-vs-fix31.patch (fix31 = fix29b + fix29c-vs-fix29b.patch + fix31-vs-fix29c.patch):
#  the plugin's descriptor set layout has one binding per binding number (0..640; unused numbers descriptorCount 0), so
#  pMutableDescriptorTypeLists[i] belongs to binding number i. ANV reads that array by binding number (radv/nvk and the
#  spec by pBindings index): with the old sparse layout the storage textures at 480-607 were past the list array and ANV
#  sized them for any type, a sampler state each, so every pool held a fifth of its sets (256 -> 51). Now a pool holds
#  what it was made for (256 -> 255); one command buffer of 3000 dispatches: 4 pools / 122 MB of the BAR window instead of
#  7 / 352 MB, 40 ms instead of 116 ms (mtl_pools grow 3000).
# fix31: descriptor pools grow with the need (256 sets first) and no silent drops (an unrecordable draw ends the command
#  buffer with MTLCommandBufferErrorOutOfMemory/Internal; NVMTL_SUBMIT_PARTIAL=1 = old), plus fix29c's staged IOSurface
#  host copies and SURFCENSUS.
# Only the NVMTLDriver.bundle changes. Refuses unsigned or altered files (SHA256SUMS, sigcheck). No WindowServer restart:
# apps load it when they next start, WindowServer at the next login/boot.
#   install.sh           back up the installed bundle (fix31) to ./previous/, then install
#   install.sh --undo    put ./previous/ back (fix31; ~/b580/fix31/install.sh --undo goes on to fix29b)
set -euo pipefail
P=/Library/GPUBundles/NVMTLDriver.bundle
H=$(cd "$(dirname "$0")" && pwd)
B=$H/previous
bundle() { local m; for m in "$1/Contents/MacOS/NVMTLDriver" "$1/Contents/MacOS/libnvmtl_translate.dylib" $(find "$1/Contents/MacOS/air-runtime" -name '*.dylib'); do
             "$H/sigcheck" "$m" >/dev/null || { "$H/sigcheck" "$m"; echo "REFUSED: $m is not signed"; exit 1; }; done
           sudo rm -rf "$P.new" "$P.old"; sudo ditto "$1" "$P.new"; sudo chown -R root:wheel "$P.new"; sudo mv "$P" "$P.old"; sudo mv "$P.new" "$P"; sudo rm -rf "$P.old"; }
case "${1:-}" in
  --undo) [ -d "$B/NVMTLDriver.bundle" ] || { echo "no $B"; exit 1; }
          bundle "$B/NVMTLDriver.bundle"; echo "restored $B"; shasum -a 256 "$P/Contents/MacOS/NVMTLDriver"; exit 0 ;;
esac
(cd "$H" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "REFUSED: files differ from SHA256SUMS"; exit 1; }
if [ ! -d "$B" ]; then
  mkdir -p "$B"; sudo ditto "$P" "$B/NVMTLDriver.bundle"; sudo chown -R "$(id -un)" "$B/NVMTLDriver.bundle"
fi
bundle "$H/NVMTLDriver.bundle"
shasum -a 256 "$P/Contents/MacOS/NVMTLDriver"
