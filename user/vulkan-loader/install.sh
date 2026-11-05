#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh: the Khronos Vulkan loader (Vulkan-Loader vulkan-sdk-1.4.363.0, Apache-2.0) and the B580 ANV ICD manifest,
# in the same places the LunarG Vulkan SDK uses on macOS, so ordinary Vulkan apps find the B580 the standard way:
#   /usr/local/lib/libvulkan.1.4.363.dylib (+ libvulkan.1.dylib, libvulkan.dylib symlinks)   the loader
#   /usr/local/share/vulkan/icd.d/intel_icd.x86_64.json   -> /Library/GPUBundles/nvmtl/libvulkan_intel.dylib (unchanged)
#   /usr/local/bin/vulkaninfo                              Vulkan-Tools vulkaninfo, same tag
# The Metal plug-in (NVMTLDriver.bundle) keeps loading ANV by its own path; nothing here touches /Library/GPUBundles.
#   sudo ./install.sh          install (files that already exist are moved to *.before-vkloader first)
#   sudo ./install.sh --undo   remove what this script installed and put any *.before-vkloader back
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
L=/usr/local/lib; I=/usr/local/share/vulkan/icd.d; B=/usr/local/bin
FILES="$L/libvulkan.1.4.363.dylib $L/libvulkan.1.dylib $L/libvulkan.dylib $I/intel_icd.x86_64.json $B/vulkaninfo"
if [ "${1:-}" = --undo ]; then
	for f in $FILES; do
		rm -f "$f"
		if [ -e "$f.before-vkloader" ] || [ -L "$f.before-vkloader" ]; then mv -f "$f.before-vkloader" "$f"; fi
	done
	echo "removed the B580 Vulkan loader install"; exit 0
fi
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p "$L" "$I" "$B"
for f in $FILES; do
	if { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -e "$f.before-vkloader" ] && [ ! -L "$f.before-vkloader" ]; then mv "$f" "$f.before-vkloader"; fi
done
install -m 755 -o root -g wheel "$H/lib/libvulkan.1.4.363.dylib" "$L/libvulkan.1.4.363.dylib"
ln -sfh libvulkan.1.4.363.dylib "$L/libvulkan.1.dylib"
ln -sfh libvulkan.1.dylib "$L/libvulkan.dylib"
install -m 644 -o root -g wheel "$H/icd.d/intel_icd.x86_64.json" "$I/intel_icd.x86_64.json"
install -m 755 -o root -g wheel "$H/bin/vulkaninfo" "$B/vulkaninfo"
echo "installed: $(shasum -a 256 "$L/libvulkan.1.4.363.dylib" | cut -c1-16) loader, ICD -> $(grep library_path "$I/intel_icd.x86_64.json" | cut -d'"' -f4)"
echo "check: vulkaninfo --summary"
