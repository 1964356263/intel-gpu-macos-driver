#!/bin/sh
# SPDX-License-Identifier: MIT
# gpu_busy.sh: exit 0 (and say why) when a GPU test must not run: java (Minecraft), geekbench_avx2, or a Geekbench GUI
# using more than 20% CPU.
if pgrep -q java; then echo "busy: java"; exit 0; fi
if pgrep -q geekbench_avx2; then echo "busy: geekbench_avx2"; exit 0; fi
for p in $(pgrep -i geekbench); do c=$(ps -o %cpu= -p $p | tr -d ' ' | cut -d. -f1); [ "${c:-0}" -gt 20 ] && { echo "busy: geekbench pid $p at ${c}% CPU"; exit 0; }; done
exit 1
