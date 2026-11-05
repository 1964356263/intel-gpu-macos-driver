#!/bin/sh
# SPDX-License-Identifier: MIT
# configure.sh: meson setup for the B580 ANV driver on macOS, with the options of the installed build (prod9).
#   MESA_SRC=<patched mesa> mesa/configure.sh && ninja -C $MESA_SRC/build src/intel/vulkan/libvulkan_intel.dylib
# Needs: meson + ninja, python3 with mako/packaging/pyyaml, and mesa_clc + vtn_bindgen2 for the system CLC
# (-Dmesa-clc=system: a host build of Mesa's clc tools, which need LLVM/Clang with SPIR-V support).
# MESA_GIT_SHA1_OVERRIDE keeps the version string of the released build ("Mesa 27.0.0-devel (git-a3ad934832)").
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
: "${MESA_SRC:?set MESA_SRC to the patched Mesa source tree (mesa/apply.sh)}"
cd "$MESA_SRC"
export MESA_GIT_SHA1_OVERRIDE=${MESA_GIT_SHA1_OVERRIDE:-a3ad934832}
exec meson setup "${BUILD:-build}" --cross-file "$HERE/darwin-x86_64.ini" \
	-Dbuildtype=release -Db_ndebug=true '-Dc_args=-Xclang -fno-split-cold-code' '-Dcpp_args=-Xclang -fno-split-cold-code' \
	-Dplatforms=macos -Dvulkan-drivers=intel -Dgallium-drivers= -Dvulkan-layers= -Dtools= \
	-Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled \
	-Dllvm=disabled -Dintel-rt=enabled -Dintel-elk=false \
	-Dvideo-codecs=h264dec,h265dec,av1dec,vp9dec,h264enc,h265enc,av1enc \
	-Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
	-Dperfetto=false -Dbuild-tests=false -Dxmlconfig=disabled -Dexpat=disabled -Dspirv-tools=disabled \
	-Dmesa-clc=system -Dxemac="$REPO/user/xemac" \
	"$@"
