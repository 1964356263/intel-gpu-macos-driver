#!/bin/bash
# SPDX-License-Identifier: MIT
# g.sh <cmd...>: run a GPU test only when the GPU is free (no java; no geekbench_avx2; the Geekbench GUI idle, <=20% CPU);
# time-boxed to 50 s
busy=""
pgrep -q java && busy="java"
pgrep -q geekbench_avx2 && busy="$busy geekbench_avx2"
for p in $(pgrep -i geekbench); do c=$(ps -o %cpu= -p $p | awk '{printf "%d", $1}'); [ "${c:-0}" -gt 20 ] && busy="$busy geekbench($p ${c}%)"; done
if [ -n "$busy" ]; then echo "BUSY: $busy - not testing"; exit 3; fi
exec /usr/bin/perl -e 'alarm 50; exec @ARGV' "$@"
