#!/bin/sh
# SPDX-License-Identifier: MIT
# Installs DXVK 3.1.1 and vkd3d-proton 3.1 into $WINEPREFIX (default $INTELXE_HOME/wine/prefix), the way their setup scripts do:
# DLLs into system32 (64-bit) / syswow64 (32-bit) and native DllOverrides in the prefix registry. Run under wenv.sh.
#   --undo  puts Wine's builtin DLLs back (wineboot -u restores the files, the overrides are deleted)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -e
B="$INTELXE_HOME/wine"; P="${WINEPREFIX:-$B/prefix}"
DX="$B/dxvk/dxvk-3.1.1"; VK="$B/vkd3d/vkd3d-proton-3.1"
DLLS_DXVK="d3d8 d3d9 d3d10core d3d11 dxgi"; DLLS_VKD3D="d3d12 d3d12core"
if [ "$1" = --undo ]; then
	for d in $DLLS_DXVK $DLLS_VKD3D; do wine reg delete 'HKCU\Software\Wine\DllOverrides' /v $d /f >/dev/null 2>&1 || true; done
	wineboot -u; exit 0
fi
for d in $DLLS_DXVK; do
	cp "$DX/x64/$d.dll" "$P/drive_c/windows/system32/$d.dll"
	cp "$DX/x32/$d.dll" "$P/drive_c/windows/syswow64/$d.dll"
	wine reg add 'HKCU\Software\Wine\DllOverrides' /v $d /d native /f >/dev/null
done
for d in $DLLS_VKD3D; do
	cp "$VK/x64/$d.dll" "$P/drive_c/windows/system32/$d.dll"
	cp "$VK/x86/$d.dll" "$P/drive_c/windows/syswow64/$d.dll"
	wine reg add 'HKCU\Software\Wine\DllOverrides' /v $d /d native /f >/dev/null
done
echo "DXVK + vkd3d-proton installed in $P"
