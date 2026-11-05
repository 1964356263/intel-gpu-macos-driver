#!/bin/sh
# SPDX-License-Identifier: MIT
# bench.sh <exe> <seconds> <iters list> <icd list> [extra args]: runs inside the GUI session (WineRun.app), one result line per run
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
cd "$INTELXE_HOME/wine"; export WINEPREFIX="$INTELXE_HOME/wine/prefix-bench"  # benches never touch the Steam prefix
EXE=$1; SEC=$2; ITERS=$3; ICDS=$4; shift 4
for icd in $ICDS; do
	for it in $ITERS; do
		ICD=$icd WINEDEBUG=-all ./wenv.sh wine "$EXE" "$SEC" "$it" "$@" > "run-$icd-$it.log" 2>&1
		echo "[$icd] $(grep -E '^(GPU0|adapter)' run-$icd-$it.log | head -1 | cut -c1-90) :: $(grep RESULT run-$icd-$it.log || tail -2 run-$icd-$it.log | tr '\n' ' ')"
		./wenv.sh wineserver -w
	done
done
