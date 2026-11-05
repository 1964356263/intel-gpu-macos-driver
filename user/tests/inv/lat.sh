# SPDX-License-Identifier: MIT
cd ~/b580/inv
B4=$HOME/b580/fix4/NVMTLDriver.bundle; B5=$HOME/b580/fix5/NVMTLDriver.bundle; NM=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib
run() { echo "== $1 / $2 / $3"; env NVMTL_ENABLE=1 NVMTL_BUNDLE=$1 ${2:+NVMTL_ICD_LIB=$2} ./mtl_lat_b $3 2>&1 | grep -E "total round trip|^\[inflight|per command|us each|throughput|cb/s|inflight" | head -4; }
case "$1" in
 a) run $B4 "" lat; run $B5 "" lat ;;
 b) run $B4 $NM lat; run $B5 $NM lat ;;
 c) run $B4 "" inflight; run $B5 "" inflight ;;
 d) run $B4 $NM inflight; run $B5 $NM inflight ;;
esac
