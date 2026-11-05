# SPDX-License-Identifier: MIT
cd ~/b580
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib
for b in fix10 fix11 fix11h; do
  export NVMTL_BUNDLE=$HOME/b580/${b%h}/NVMTLDriver.bundle; [ $b = fix9h ] && export NVMTL_HITCH_MS=1000 || unset NVMTL_HITCH_MS
  echo "== $b: $(inv/mtl_lat_b lat 2>&1 | grep 'total round' | tr -s ' ') | $(inv/mtl_lat_b inflight 2>&1 | grep 'M=4' | tr -s ' ')"
done
