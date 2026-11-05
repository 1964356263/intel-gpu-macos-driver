#!/bin/sh
# SPDX-License-Identifier: MIT
# rollback-boot1.sh: back to the v8b kexts and the LaunchDaemon load (intelxefb-load.sh + intelxe-accel.sh), as before boot1.
# Then rebuild the AuxKC and reboot. Acceleration then needs /var/db/intelxefb.accel or a manual `sudo /Library/IntelXe/intelxe-accel.sh`.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
B=$HOME/b580/backups/before-boot1
[ -d "$B" ] || { echo "no backup at $B" >&2; exit 1; }
for k in IntelXeFB NMXAccel NMXAGDC; do rm -rf /Library/Extensions/$k.kext; cp -Rp "$B/$k.kext" /Library/Extensions/; done
install -o root -g wheel -m 755 "$B/intelxefb-load.sh" /Library/IntelXe/intelxefb-load.sh
install -o root -g wheel -m 755 "$B/intelxe-accel.sh" /Library/IntelXe/intelxe-accel.sh
if [ -e "$B/io.github.yusufklncc.intelxefb.plist" ]; then
	install -o root -g wheel -m 644 "$B/io.github.yusufklncc.intelxefb.plist" /Library/LaunchDaemons/io.github.yusufklncc.intelxefb.plist
fi
nvram intelxe-guard=ok 2>/dev/null || true   # nvram -d does not remove it on macOS 26; the kext reads "ok" as absent
echo "rolled back; now rebuild the AuxKC and reboot"
