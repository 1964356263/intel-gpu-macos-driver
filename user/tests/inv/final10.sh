# SPDX-License-Identifier: MIT
cd ~/b580
L=$(getconf DARWIN_USER_TEMP_DIR)nvmtl.log
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib
export NVMTL_BUNDLE=$HOME/b580/fix10/NVMTLDriver.bundle
echo "== fix10 (new Mesa)"
echo "tests: $(./mtl_tests 2>&1 | tail -1) | mip: $(./mtl_tests mip 2>&1 | tail -1) | bt: $(inv/bt | tail -1) | race: $(NVMTL_CAPTURE_WAIT=1 inv/surftest race frames 2 | tail -1)"
echo "empty: $(inv/emptytest 2>&1 | tail -1) | samp: $(inv/samptest2 2>&1 | tail -1)"
inv/cltr 2>&1 | grep -v "^objc\|is implemented in both" | tail -8
