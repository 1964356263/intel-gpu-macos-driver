#!/bin/sh
# SPDX-License-Identifier: MIT
# matrix.sh: the FPS matrix (runs inside the GUI session via WineRun.app). Lines: <label> <RESULT line or failure tail>
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
cd "$INTELXE_HOME/wine"; export WINEPREFIX="$INTELXE_HOME/wine/prefix-bench"  # benches never touch the Steam prefix
SEC=${SEC:-10}; RES="1920 1080"
run() { # label icd overrides exe iters
	label=$1 icd=$2 ovr=$3 exe=$4 it=$5
	rm -f "fps-$label.txt"
	ICD=$icd WINEDLLOVERRIDES="mscoree,mshtml=;$ovr" MESA_VK_WSI_FPS_LOG="$INTELXE_HOME/wine/fps-$label.txt" WINEDEBUG=-all \
		./wenv.sh wine "$exe" "$SEC" "$it" $RES > "m-$label.log" 2>&1
	shown=$(tail -2 "fps-$label.txt" 2>/dev/null | head -1)
	echo "$label :: $(grep -E '^(GPU0|adapter)' m-$label.log | head -1 | cut -c1-80) :: $(grep RESULT m-$label.log || tail -3 m-$label.log | tr '\n' ' ' | cut -c1-200) :: wsi[$shown]"
	./wenv.sh wineserver -w
}
for it in ${ITERS:-16 512}; do
	run vk-anv-$it anv "" vkbench.exe $it
	run vk-mvk-$it mvk "" vkbench.exe $it
	run d3d11-dxvk-anv-$it anv "" d3d11bench.exe $it
	[ -n "$FULL" ] && run d3d11-dxvk-mvk-$it mvk "" d3d11bench.exe $it
	[ -n "$FULL" ] && run d3d11-wined3d-$it anv "d3d11,dxgi,d3d10core=b" d3d11bench.exe $it
	run d3d12-vkd3dproton-anv-$it anv "" d3d12bench.exe $it
	[ -n "$FULL" ] && run d3d12-winevkd3d-mvk-$it mvk "d3d12,d3d12core,dxgi=b" d3d12bench.exe $it
done
echo MATRIX-DONE
