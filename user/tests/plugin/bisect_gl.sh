#!/bin/bash
# SPDX-License-Identifier: MIT
# bisect_gl.sh <base bundle> <new bundle>: GL image determinism and the stage-1d switches, both models. One gl_bind run per
# line (each <= 50 s, guarded by g.sh); prints the 4 mode hashes of each configuration.
A=$1; B=$2; H=$(cd "$(dirname "$0")" && pwd)
run() { local tag=$1 b=$2 m=$3; shift 3
  env "$@" NVMTL_DESC_MODEL=$m NVMTL_ENABLE=1 NVMTL_BUNDLE="$b" DYLD_INSERT_LIBRARIES="$H/nvmtl_interpose.dylib" "$H/g.sh" "$H/gl_bind" -f 10 2>&1 \
    | awk -v t="$tag" '/^gl-/{h[$1]=$NF} /BUSY/{print; exit 3} END{printf "%-28s %s %s %s %s\n", t, h["gl-uni"], h["gl-vao"], h["gl-tex"], h["gl-mix"]}'; }
for m in classic buffer; do
  run "$m base#1" "$A" $m X=1
  run "$m base#2" "$A" $m X=1
  run "$m new" "$B" $m X=1
  run "$m new TABLE_FULL" "$B" $m NVMTL_TABLE_FULL=1
  run "$m new BINDCACHE_OFF" "$B" $m NVMTL_BINDCACHE_OFF=1
  run "$m new both off" "$B" $m NVMTL_TABLE_FULL=1 NVMTL_BINDCACHE_OFF=1
done
