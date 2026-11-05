#!/bin/sh
# SPDX-License-Identifier: MIT
# Turn on WindowServer acceleration on the B580 for this boot (phase 5): AppleGraphicsDeviceControl with link
# answers (NMXAGDC K5), the accelerator's display pipe for IntelXeFramebuffer (NMXAccel), display-pipe transactions,
# then restart displaypolicyd and WindowServer so both start on the armed pipe. Nothing persists: a reboot (or
# `sudo killall -9 WindowServer` after a reboot) is the unaccelerated desktop again.
# A logged-in session is closed by the WindowServer restart; the login window comes back accelerated.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
ioreg -rc IntelXeFramebuffer -d1 | grep -q IntelXeFramebuffer || { echo "IntelXeFramebuffer is not up" >&2; exit 1; }
sysctl -w debug.nvrmfb_agdc_k5=1 >/dev/null
sysctl -w debug.nvrmfb_agdc=1 >/dev/null
# Pipe gamma in hardware (NMXAGDC answers the AGDC gamma capability): CoreDisplay then skips its own full-screen GPU
# pass per frame (73 -> 103 frames/s, 2026-10-28). IOPresentment reads it when WindowServer starts, so set it first.
sysctl -w debug.nmxagdc_gamma=1 >/dev/null 2>&1 || true
sleep 2
for l in 1 3 4; do sysctl -w debug.nmxaccelfb=$l >/dev/null; done
sysctl -w debug.nmxaccel_iop=1 >/dev/null
# Async swap (the kernel waits for the composite, WindowServer does not: 104 -> 178 frames/s) and real flips (the plane
# scans the composite's VRAM buffer, no full-frame copy). Both off: sysctl debug.nmxaccel_flip=0 debug.nmxaccel_async=0.
sysctl -w debug.nmxaccel_async=1 >/dev/null 2>&1 || true
sysctl -w debug.nmxaccel_flip=1 >/dev/null 2>&1 || true
killall -9 displaypolicyd 2>/dev/null || true
sleep 3
pkill -9 -x WindowServer || true
echo "armed: agdc $(sysctl -n debug.nvrmfb_agdc), pipe $(sysctl -n debug.nmxaccelfb), transactions $(sysctl -n debug.nmxaccel_iop), gamma $(sysctl -n debug.nmxagdc_gamma 2>/dev/null || echo -), async $(sysctl -n debug.nmxaccel_async 2>/dev/null || echo -), flip $(sysctl -n debug.nmxaccel_flip 2>/dev/null || echo -)"
