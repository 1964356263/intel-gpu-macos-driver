#!/bin/sh
# SPDX-License-Identifier: MIT
# apply.sh <mesa-checkout>: turn an upstream Mesa checkout at f01e9b07a91 into the exact source of the released
# libvulkan_intel.dylib: prod9 (installed as a7021b7e) with the B580 -> IntelXe rename of patches/0101. intelxe.diff is
# the whole difference; patches/ and xe2-venc/ hold the same changes split into reviewable steps.
#   git clone https://gitlab.freedesktop.org/mesa/mesa.git && git -C mesa checkout f01e9b07a91f7e7ab730edfbb383b083f146067b
#   mesa/apply.sh mesa
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "${1:?usage: apply.sh <mesa-checkout at f01e9b07a91>}"
[ "$(git rev-parse HEAD 2>/dev/null)" = f01e9b07a91f7e7ab730edfbb383b083f146067b ] || { echo "the checkout is not at f01e9b07a91" >&2; exit 1; }
patch -p1 -s < "$HERE/intelxe.diff"
# an empty generated header the diff cannot carry
mkdir -p src/intel/blorp/stub && : > src/intel/blorp/stub/blorp_shaders.h
echo "patched: now run $HERE/configure.sh with MESA_SRC=$(pwd)"
