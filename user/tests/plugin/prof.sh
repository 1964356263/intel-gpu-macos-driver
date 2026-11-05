#!/bin/bash
# SPDX-License-Identifier: MIT
# prof.sh <bundle> <classic|buffer> <out.txt> <prog> [args...]: run <prog> -loop 14 under the staged bundle (interposed for GL) and
# sample it 8 s. Guarded like g.sh.
B=$1; M=$2; O=$3; shift 3
H=$(cd "$(dirname "$0")" && pwd)
"$H/g.sh" /usr/bin/true >/dev/null || { "$H/g.sh" /usr/bin/true; exit 3; }
if [ "$M" = buffer ]; then export NVMTL_DESC_MODEL=buffer; else export NVMTL_DESC_MODEL=classic; fi
export NVMTL_ENABLE=1 NVMTL_BUNDLE="$B" DYLD_INSERT_LIBRARIES="$H/nvmtl_interpose.dylib"
P=$1; shift
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$P" -loop 14 "$@" > "$O.run" 2>&1 &
sleep 3
unset DYLD_INSERT_LIBRARIES
/usr/bin/sample $(pgrep -n "$(basename "$P")") 8 1 -mayDie -file "$O" >/dev/null 2>&1
wait; tail -1 "$O.run"
