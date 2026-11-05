#!/bin/bash
# SPDX-License-Identifier: MIT
# one_gl.sh <tag> <bundle> <classic|buffer> [VAR=val...]: one gl_bind run (-f 10, 4 modes) on a staged plugin; prints the
# mode hashes and the kernel's bans / GuC context resets / GT resets before and after. Exit 4 if any of those changed.
T=$1; B=$2; M=$3; shift 3; H=$(cd "$(dirname "$0")" && pwd)
k() { sysctl -n debug.intelxe.stats | awk '{for(i=1;i<=NF;i++){ if($i=="bans") b=$(i+1); if($i=="context"&&$(i+1)=="resets") r=$(i+2); if($i=="GT"&&$(i+1)=="resets") g=$(i+2)}} END{gsub(/[^0-9]/,"",b); gsub(/[^0-9]/,"",r); gsub(/[^0-9]/,"",g); print "bans="b" guc="r" gt="g}'; }
before=$(k)
mkdir -p /tmp/d3/gl-$T
env "$@" NVMTL_DESC_MODEL=$M NVMTL_ENABLE=1 NVMTL_BUNDLE="$B" NVMTL_LOG_PATH=/tmp/d3/gl-$T/nvmtl.log DYLD_INSERT_LIBRARIES="$H/nvmtl_interpose.dylib" \
  "$H/g.sh" "$H/gl_bind" -f 10 -o /tmp/d3/gl-$T 2>&1 | awk -v t="$T" '/^gl-/{h[$1]=$NF; d[$1]=$4} /BUSY/{print; bad=1} END{if(!bad) printf "%-26s uni %s vao %s mix %s tex %s | ns/draw %s %s %s %s\n", t, h["gl-uni"], h["gl-vao"], h["gl-mix"], h["gl-tex"], d["gl-uni"], d["gl-vao"], d["gl-tex"], d["gl-mix"]}'
after=$(k)
echo "  kernel $before -> $after"
[ "$before" = "$after" ] || { echo "  KERNEL COUNTERS CHANGED - STOP"; exit 4; }
