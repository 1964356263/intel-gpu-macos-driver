#!/bin/bash
# SPDX-License-Identifier: MIT
# run_bind.sh <bundle> <outdir> [classic|buffer] [mtl_bind args...]: one mtl_bind run of a staged plugin (time-boxed 50 s)
B=$1; O=$2; M=${3:-classic}; shift 3
if pgrep -q java || pgrep -q geekbench; then echo "java/geekbench running - not testing"; exit 3; fi
H=$(cd "$(dirname "$0")" && pwd)
rm -rf "$O"; mkdir -p "$O"
if [ "$M" = buffer ]; then export NVMTL_DESC_MODEL=buffer; else unset NVMTL_DESC_MODEL; fi
NVMTL_ENABLE=1 NVMTL_BUNDLE="$B" /usr/bin/perl -e 'alarm 50; exec @ARGV' "$H/mtl_bind" -o "$O" "$@" | cut -c1-200
