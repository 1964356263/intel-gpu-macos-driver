#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh: sv8 plugin = sv7 without the per-frame seed-bump lock (phase 4 marks only; the post-mark seed recorded as its own). sv7 = sv6 + phase 4 (debug.intelxe.surfvram >= 3: WindowServer composites skip their readback; needs the sv7 NMXAccel + IntelXe.kext). sv6 = sv5 + VRAM-shared surface writes scheduled at submission (no waitUntilScheduled wait for the GPU). sv5 = sv4 + SCHEDCENSUS (/tmp/nvmtl-schedcensus: why commits are scheduled late). sv4 = sv3 + /tmp/nvmtl-no-scanout-readback. sv3 = sv2 + WindowServer import-only at level 2, the switch re-read every second, non-blocking SURFACE_DIRTY at submission), user-space half (Mesa is sv2's, unchanged). Everything stays OFF until
# debug.intelxe.surfvram is 1 (apps) or 2 (apps + WindowServer; re-read every second, new surface textures follow it); at 0 the plugin and Mesa behave as
# fix32 / venc2 (svimg, gpt_bench surf and mtl_tests pass with the switch at 0).
#   NVMTLDriver.bundle     fix32 (src/nullmoth-vis/plugin) + sv2-plugin-vs-fix32.patch: item 7 on ANV (import / make the
#                          surface's VRAM backing through Mesa 0014, implicit sync of every read and write of it, marked
#                          newest at submission instead of copied out)
#   libvulkan_intel.dylib  src/mesa-venc-rel (installed venc2 base) + patches/mesa/0013 + 0014, same meson options, ad-hoc signed
# Refuses files that differ from SHA256SUMS or carry no code signature. No WindowServer restart: apps pick both up when they
# next start (WindowServer keeps its copies until relogin/reboot; with the switch at 1 it does not use VRAM sharing anyway).
#   install.sh plugin | mesa | all      back up the installed file(s) to ./previous/, then install
#   install.sh --undo plugin | mesa | all
set -euo pipefail
P=/Library/GPUBundles/NVMTLDriver.bundle
M=/Library/GPUBundles/nvmtl/libvulkan_intel.dylib
H=$(cd "$(dirname "$0")" && pwd)
B=$H/previous
sig() { "$H/sigcheck" "$1" >/dev/null || { "$H/sigcheck" "$1"; echo "REFUSED: $1 is not signed"; exit 1; }; }
bundle() { local m; for m in "$1/Contents/MacOS/NVMTLDriver" "$1/Contents/MacOS/libnvmtl_translate.dylib" $(find "$1/Contents/MacOS/air-runtime" -name '*.dylib'); do sig "$m"; done
           sudo rm -rf "$P.new" "$P.old"; sudo ditto "$1" "$P.new"; sudo chown -R root:wheel "$P.new"; sudo mv "$P" "$P.old"; sudo mv "$P.new" "$P"; sudo rm -rf "$P.old"; }
mesa() { sig "$1"; sudo cp "$1" "$M.new" && sudo chown root:wheel "$M.new" && sudo chmod 755 "$M.new" && sudo mv -f "$M.new" "$M"; }
what=${2:-${1:-}}
if [ "${1:-}" = --undo ]; then
  case "$what" in plugin|all) bundle "$B/NVMTLDriver.bundle"; echo "plugin restored";; esac
  case "$what" in mesa|all) mesa "$B/libvulkan_intel.dylib"; echo "mesa restored";; esac
  exit 0
fi
(cd "$H" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "REFUSED: files differ from SHA256SUMS"; exit 1; }
mkdir -p "$B"
case "$what" in
  plugin|all) [ -d "$B/NVMTLDriver.bundle" ] || { sudo ditto "$P" "$B/NVMTLDriver.bundle"; sudo chown -R "$(id -un)" "$B/NVMTLDriver.bundle"; }
              bundle "$H/NVMTLDriver.bundle"; shasum -a 256 "$P/Contents/MacOS/NVMTLDriver";;
esac
case "$what" in
  mesa|all) [ -f "$B/libvulkan_intel.dylib" ] || cp "$M" "$B/libvulkan_intel.dylib"
            mesa "$H/libvulkan_intel.dylib"; shasum -a 256 "$M";;
esac
case "$what" in plugin|mesa|all) ;; *) echo "usage: install.sh [--undo] plugin|mesa|all"; exit 1;; esac
