#!/bin/bash
# SPDX-License-Identifier: MIT
# bind_cmp.sh <bundle> <outdir> <classic|buffer> [mtl_bind args]: mtl_bind (all modes unless given) on a staged bundle; images to <outdir>
B=$1; O=$2; M=$3; shift 3
H=$(cd "$(dirname "$0")" && pwd)
rm -rf "$O"; mkdir -p "$O"
NVMTL_LOG_PATH=$O/nvmtl.log NVMTL_DESC_MODEL=$M NVMTL_ENABLE=1 NVMTL_BUNDLE="$B" "$H/g.sh" "$H/mtl_bind" -o "$O" "$@" | cut -c1-150
