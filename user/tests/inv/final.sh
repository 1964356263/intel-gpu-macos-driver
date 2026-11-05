# SPDX-License-Identifier: MIT
cd ~/b580
NM=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib
for icd in "" $NM; do
  export NVMTL_BUNDLE=$HOME/b580/fix5/NVMTLDriver.bundle NVMTL_ENABLE=1; [ -n "$icd" ] && export NVMTL_ICD_LIB=$icd || unset NVMTL_ICD_LIB
  echo "== mesa ${icd:-installed}"
  echo "tests: $(./mtl_tests 2>&1 | tail -1) | mip: $(./mtl_tests mip 2>&1 | tail -1) | bt: $(inv/bt | tail -1) | race: $(NVMTL_CAPTURE_WAIT=1 inv/surftest race frames 2 | tail -1)"
  ./mtl_tests bw 2>&1 | grep "256 MB random"
  inv/mtl_lat_b lat 2>&1 | grep "total round"
  inv/mtl_lat_b inflight 2>&1 | grep "M=4"
done
