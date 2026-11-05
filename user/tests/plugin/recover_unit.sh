#!/bin/bash
# SPDX-License-Identifier: MIT
# recover_unit.sh: build and run tests/recover_unit.c on the host (no GPU): the plugin's GPU reset recovery state machine
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); O=${TMPDIR:-/tmp}/recover_unit.$$
clang -std=gnu11 -O1 -Wall -Wno-unused-function -I"${MESA_SRC:-$HOME/mesa}/include" -o "$O" "$H/recover_unit.c" -lpthread
"$O"; rc=$?; rm -f "$O"; exit $rc
