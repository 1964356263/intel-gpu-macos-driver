#!/bin/sh
# SPDX-License-Identifier: MIT
# tb.sh MAXSEC cmd args...: run cmd, kill -9 it after MAXSEC seconds (prints KILLED, exit 124); else cmd's exit status.
# Pass environment for cmd with "env VAR=x cmd": DYLD_INSERT_LIBRARIES must not reach this loop's sleep (AMFI is off).
max=$1; shift
"$@" &
p=$!
t0=$(date +%s)
while kill -0 $p 2>/dev/null; do
	[ $(( $(date +%s) - t0 )) -ge $max ] && { kill -9 $p; echo "KILLED after ${max}s: $*"; exit 124; }
	sleep 0.2
done
wait $p
