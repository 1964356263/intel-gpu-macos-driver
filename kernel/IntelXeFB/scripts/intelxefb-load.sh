#!/bin/sh
# SPDX-License-Identifier: MIT
# Loads IntelXeFB once userspace is up (LaunchDaemon io.github.yusufklncc.intelxefb). The kext never matches during kernel boot
# (IOPropertyMatch intelxe-fb-armed, set by its own start routine on this load). Guard: the marker file is written before
# the load and removed only after the desktop has run on the framebuffer for a while, so a load that panics leaves it
# behind and the next boot skips the load. Re-enable: sudo rm /var/db/intelxefb.attempt. Disable: touch /var/db/intelxefb.disabled
G=/var/db/intelxefb.attempt
exec >>/var/log/intelxefb-load.log 2>&1
echo "$(date '+%F %T') boot"
[ "$(sysctl -n kern.safeboot)" = 1 ] && { echo "safe mode: skipped"; exit 0; }
[ -e /var/db/intelxefb.disabled ] && { echo "disabled: skipped"; exit 0; }
# IntelXeFB builds from 2026-10-29 match at boot from the AuxKC and arm acceleration in the kernel, with their own NVRAM
# guard (intelxe-guard / intelxe-accel-off): nothing to do here. This script only serves the older, intelxe-fb-armed builds
# (rollback); the LaunchDaemon can stay installed with either.
if ! grep -q intelxe-fb-armed /Library/Extensions/IntelXeFB.kext/Contents/Info.plist 2>/dev/null; then
	echo "IntelXeFB matches at boot (no intelxe-fb-armed in its personality): nothing to do"; exit 0
fi
[ -e "$G" ] && { echo "the last load did not finish (panic?): skipped, rm $G to retry"; exit 0; }
date > "$G"; sync
n=0
until kmutil load -b io.github.yusufklncc.IntelXeFB; do
	n=$((n + 1)); [ $n -ge 5 ] && { echo "kmutil load failed"; rm -f "$G"; exit 0; }
	sleep 2
done
n=0
until ioreg -rc IntelXeFramebuffer -d1 | grep -q IntelXeFB; do n=$((n + 1)); [ $n -ge 20 ] && break; sleep 0.5; done
# A WindowServer that started before the framebuffer existed never opens it: restart it, only while the login window
# is the console (no user session to lose).
n=0
until pgrep -x WindowServer >/dev/null; do n=$((n + 1)); [ $n -ge 60 ] && break; sleep 1; done
sleep 3
# With the iGPU enabled (headless, for Quick Sync) WindowServer starts on its framebuffers before this one exists and
# does not adopt it later (CoreDisplay: "Unable to find display pipe for IOFB service"), so the B580's monitor keeps the
# boot logo. Nobody can be working on a screen that shows the boot logo, so the restart no longer depends on who owns
# the console (2026-10-29: an auto-login session had taken it, and the restart was skipped).
n=0
until ioreg -rc IntelXeFramebuffer -l -w0 | grep -q IOFBConfig; do n=$((n + 1)); [ $n -ge 10 ] && break; sleep 1; done
if ioreg -rc IntelXeFramebuffer -l -w0 | grep -q IOFBConfig; then echo "WindowServer opened the framebuffer"
else echo "WindowServer has not opened the framebuffer (console $(stat -f %Su /dev/console)): restarting it"; pkill -9 -x WindowServer; fi
# Opt-in acceleration (phase 5): touch /var/db/intelxefb.accel. It arms after the framebuffer is up and restarts
# WindowServer onto the B580's Metal device. The same panic guard covers it.
if [ -e /var/db/intelxefb.accel ]; then
	sleep 5
	if /bin/sh /Library/IntelXe/intelxe-accel.sh; then echo "acceleration armed"; else echo "acceleration NOT armed"; fi
fi
# A clean shutdown inside the window (launchd sends SIGTERM) is not a panic: clear the guard then too.
trap 'rm -f "$G"; sync; echo "$(date "+%F %T") shutdown before the window ended: guard cleared"; exit 0' TERM
sleep 60 &
wait $!
rm -f "$G"; sync
echo "$(date '+%F %T') ok"
