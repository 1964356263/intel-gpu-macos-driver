#!/bin/sh
# SPDX-License-Identifier: MIT
# install-boot1.sh: boot-time IntelXe stack (IntelXeFB matched from the AuxKC, NMXAGDC + NMXAccel armed in the kernel).
# Run with sudo from ~/b580/vrr/boot1. Backs up what it replaces to ~/b580/backups/before-boot1 (once), copies the three
# kexts to /Library/Extensions, installs the new intelxefb-load.sh (a no-op with these kexts) and takes the LaunchDaemon out
# (kept in /Library/IntelXe/legacy). The AuxKC still has to be rebuilt (kmutil) and the machine rebooted.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"
B=$HOME/b580/backups/before-boot1
if [ ! -d "$B" ]; then
	mkdir -p "$B"
	for k in IntelXeFB NMXAccel NMXAGDC; do cp -Rp /Library/Extensions/$k.kext "$B/"; done
	cp -p /Library/IntelXe/intelxefb-load.sh /Library/IntelXe/intelxe-accel.sh "$B/"
	cp -p /Library/LaunchDaemons/io.github.yusufklncc.intelxefb.plist "$B/" 2>/dev/null || true
	echo "backup: $B"
fi
for k in IntelXeFB NMXAccel NMXAGDC; do
	rm -rf /Library/Extensions/$k.kext
	cp -R $k.kext /Library/Extensions/
	chown -R root:wheel /Library/Extensions/$k.kext; chmod -R go-w /Library/Extensions/$k.kext
done
install -o root -g wheel -m 755 intelxefb-load.sh /Library/IntelXe/intelxefb-load.sh
mkdir -p /Library/IntelXe/legacy
if [ -e /Library/LaunchDaemons/io.github.yusufklncc.intelxefb.plist ]; then
	launchctl bootout system/io.github.yusufklncc.intelxefb 2>/dev/null || true
	mv /Library/LaunchDaemons/io.github.yusufklncc.intelxefb.plist /Library/IntelXe/legacy/
fi
rm -f /var/db/intelxefb.attempt
shasum -a 256 /Library/Extensions/IntelXeFB.kext/Contents/MacOS/IntelXeFB /Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel /Library/Extensions/NMXAGDC.kext/Contents/MacOS/NMXAGDC | cut -c1-12
echo "installed; now rebuild the AuxKC and reboot"
