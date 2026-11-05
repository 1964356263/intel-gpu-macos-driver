#!/bin/bash
# SPDX-License-Identifier: MIT
# gl_cmp.sh <bundle> <classic|buffer> <outdir> [modes]: gl_bind on a staged plugin (interposed)
B=$1; M=$2; O=$3; shift 3; H=$(cd "$(dirname "$0")" && pwd)
rm -rf "$O"; mkdir -p "$O"
NVMTL_DESC_MODEL=$M NVMTL_ENABLE=1 NVMTL_BUNDLE="$B" DYLD_INSERT_LIBRARIES="$H/nvmtl_interpose.dylib" "$H/g.sh" "$H/gl_bind" -o "$O" "$@" 2>&1 | grep "^gl-\|BUSY" | cut -c1-140
