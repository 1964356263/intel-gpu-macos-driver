#!/bin/bash
# SPDX-License-Identifier: MIT
# pres.sh <out> [VAR=val...] -- [present args]: run present.app in the GUI session (open), output to <out>; guarded, <= 40 s
O=$1; shift; H=$(cd "$(dirname "$0")" && pwd); E=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do E+=(--env "$1"); shift; done; [ "$1" = "--" ] && shift
"$H/g.sh" /usr/bin/true >/dev/null || { "$H/g.sh" /usr/bin/true; exit 3; }
rm -f "$O"
/usr/bin/perl -e 'alarm 40; exec @ARGV' /usr/bin/open -W -n "${E[@]}" --stdout "$O" --stderr "$O" "$H/present.app" --args "$@"
grep -v "^interpose: MTL" "$O" | tail -12
