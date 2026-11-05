#!/bin/sh
# SPDX-License-Identifier: MIT
# chk.sh <tag> "<dxvk config 1>" "<dxvk config 2>" ...: d3d11bench check mode under each DXVK_CONFIG (runs in the GUI session)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
cd "$INTELXE_HOME/wine"; export WINEPREFIX="$INTELXE_HOME/wine/prefix-bench"; TAG=$1; shift  # benches never touch the Steam prefix
mkdir -p "chk-$TAG"
i=0
for cfg in "$@"; do
	i=$((i + 1)); d="chk-$TAG/$i"; mkdir -p "$d"
	DXVK_CONFIG="$cfg" DXVK_LOG_LEVEL=${DXVK_LOG_LEVEL:-debug} DXVK_LOG_PATH="$INTELXE_HOME/wine/$d" WINEDEBUG=-all \
		./wenv.sh wine d3d11bench.exe 1 0 64 64 0 check > "$d/out.log" 2>&1
	echo "== [$cfg]"; grep -E "CHECK|FAIL|adapter" "$d/out.log"
done
echo CHK-DONE
