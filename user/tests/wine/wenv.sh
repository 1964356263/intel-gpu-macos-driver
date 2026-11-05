#!/bin/sh
# SPDX-License-Identifier: MIT
# wenv.sh: environment for Wine -> winevulkan -> native Mesa ANV (B580). Source it, or: wenv.sh <cmd...>
#   ICD=mvk  -> use the bundled MoltenVK instead (comparison runs)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
W="$INTELXE_HOME/wine/dist/Wine Devel.app/Contents/Resources/wine"
export PATH="$W/bin:$PATH"
export WINEPREFIX="${WINEPREFIX:-$INTELXE_HOME/wine/prefix}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
if [ "${ICD:-anv}" = mvk ]; then
	export VK_DRIVER_FILES="$W/share/vulkan/icd.d/MoltenVK_icd.json"
else
	export VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/intel_icd.x86_64.json
fi
export WINE="$W/bin/wine"
[ $# -gt 0 ] && exec "$@"
