# SPDX-License-Identifier: MIT
cd ~/b580
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib NVMTL_BUNDLE=$HOME/b580/fix12/NVMTLDriver.bundle
echo "== fix12 (new Mesa)"
echo "tests: $(./mtl_tests 2>&1 | tail -1) | mip: $(./mtl_tests mip 2>&1 | tail -1) | bt: $(inv/bt | tail -1) | race: $(NVMTL_CAPTURE_WAIT=1 inv/surftest race frames 2 | tail -1)"
echo "empty: $(inv/emptytest 2>&1 | tail -1)"
echo "cltr: $(inv/cltr 2>&1 | tail -1) | glflat: $(inv/glflat 1 short 2>&1 | grep -o "^PASS\|^FAIL") $(inv/glflat 1 byte 2>&1 | grep -o "^PASS\|^FAIL")"
echo "ppool: $(inv/ppool 2>&1 | grep -v "implemented in both\|preload" | tr "\n" " ")"
echo "memory: $(inv/clchurn 3000 25 2>&1 | grep "PASSED\|FAILED\|->")"
echo "metal churn: $(inv/churn 2>&1 | grep Private | cut -c1-70) | $(./mtl_tests bw 2>&1 | grep "256 MB random" | tr -s " ")"
