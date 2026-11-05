#!/bin/bash
# SPDX-License-Identifier: MIT
# test-install-flow.sh PACKAGE_DIR: runs install.sh's whole flow against a throwaway root, without root and without kmutil:
# install, the same again, a damaged file, repair, an edited allow-list, undo (with the version it puts back), uninstall. Each step's --status is checked.
set -uo pipefail
PKG=$(cd "$1" && pwd)
ROOT=$(mktemp -d -t ixeflow)
T=$ROOT/pkg
ditto "$PKG" "$T"
# the same script with its paths under the throwaway root, and what needs root or a real Mac stubbed
sed -E -e "s#([^H])/Library/#\1$ROOT/Library/#g" -e "s#SSV=/System/#SSV=$ROOT/System/#" "$PKG/install.sh" > "$T/install.sh"
perl -0pi -e 's/^set -euo pipefail\n/set -euo pipefail\nid() { echo 0; }\nchown() { :; }\ninstall() { local a=(); while [ \$# -gt 0 ]; do case "\$1" in -o|-g|-m) shift 2;; *) a+=("\$1"); shift;; esac; done; cp "\${a[@]}"; }\n/m; s/^check\(\) \{\n/check() { return 0; }\ncheck_real() {\n/m; s/^rebuild_auxkc\(\) \{\n/rebuild_auxkc() { echo "  ok    (kernel collection step skipped in this test)"; }\nrebuild_real() {\n/m' "$T/install.sh"
chmod +x "$T/install.sh"
mkdir -p "$ROOT/Library/Extensions" "$ROOT/Library/GPUBundles" "$ROOT/Library/Application Support/intel-gpu-macos-driver"
fails=0
state() { "$T/install.sh" --status | sed -n "s/^$1=//p"; }
expect() { # expect WHAT KEY VALUE
    local got; got=$(state "$2")
    if [ "$got" = "$3" ]; then echo "ok    $1: $2=$got"; else echo "FAIL  $1: $2=$got, expected $3"; fails=$((fails + 1)); fi
}
step() { "$T/install.sh" "$1" > "$ROOT/last.log" 2>&1 || { echo "FAIL  $1 exited with an error:"; tail -5 "$ROOT/last.log"; fails=$((fails + 1)); }; }

expect "nothing installed" installed_state absent
expect "nothing installed" installed_version none
step --apply
expect "after --apply" installed_state same
expect "after --apply" installed_version "$(state package_version)"
[ -f "$ROOT/Library/GPUBundles/nvmtl-allow.txt" ] && echo "ok    allow-list installed" || { echo "FAIL  no allow-list"; fails=$((fails + 1)); }
expect "after --apply" guard_daemon yes
plutil -lint "$ROOT/Library/LaunchDaemons/io.github.yusufklncc.intelxe.guard.plist" >/dev/null && echo "ok    guard daemon plist is valid" || { echo "FAIL  guard daemon plist"; fails=$((fails + 1)); }
sh -n "$ROOT/Library/Application Support/intel-gpu-macos-driver/guard-clear.sh" && echo "ok    guard script parses" || { echo "FAIL  guard script"; fails=$((fails + 1)); }

K="$ROOT/Library/Extensions/IntelXeFB.kext/Contents/MacOS/IntelXeFB"
echo damaged >> "$K"
expect "a kext damaged" installed_state different
expect "a kext damaged" items_different 1
step --repair
expect "after --repair" installed_state same
grep -q "kernel collection step" "$ROOT/last.log" && echo "ok    repair of a kext rebuilds the collection" || { echo "FAIL  repair did not rebuild the collection"; fails=$((fails + 1)); }

M=$(find "$ROOT/Library/GPUBundles/nvmtl" -type f | head -1)
echo damaged >> "$M"
step --repair
expect "after a Metal file repair" installed_state same
grep -q "kernel collection step" "$ROOT/last.log" && { echo "FAIL  repair of a Metal file rebuilt the collection"; fails=$((fails + 1)); } || echo "ok    repair of a Metal file leaves the collection"

echo "+ my.app" >> "$ROOT/Library/GPUBundles/nvmtl-allow.txt"
touch "$ROOT/Library/GPUBundles/nvmtl/ssv-component.plist"
expect "an edited allow-list and the record of a system-volume copy are not differences" installed_state same
step --repair
grep -q "my.app" "$ROOT/Library/GPUBundles/nvmtl-allow.txt" && echo "ok    repair keeps an edited allow-list" || { echo "FAIL  repair lost the allow-list"; fails=$((fails + 1)); }
rm "$ROOT/Library/GPUBundles/nvmtl/ssv-component.plist"

backup=$(state backup)
step --repair
[ "$(state backup)" = "$backup" ] && echo "ok    repair leaves the last backup" || { echo "FAIL  repair changed the backup"; fails=$((fails + 1)); }

step --undo
expect "after --undo (there was nothing before)" installed_state absent
expect "after --undo" installed_version none
expect "after --undo (there was no guard daemon before)" guard_daemon no
step --apply
# undo puts back the version recorded with its backup (here an earlier version, written by hand)
echo 0.0.9-test > "$ROOT/Library/Application Support/intel-gpu-macos-driver/installed-version"
step --apply
expect "after --apply over 0.0.9-test" installed_version "$(state package_version)"
step --undo
expect "after --undo of that install" installed_version 0.0.9-test
expect "after --undo of that install" installed_state same
step --apply
step --uninstall
expect "after --uninstall" installed_state absent
expect "after --uninstall" guard_daemon no
expect "after --uninstall" installed_version none
[ -d "$backup" ] && echo "ok    uninstall keeps backups" || { echo "FAIL  backups are gone"; fails=$((fails + 1)); }
grep -q "remove IntelXe.kext" "$ROOT/last.log" && echo "ok    uninstall says to remove the kext from the EFI" || { echo "FAIL  no EFI note"; fails=$((fails + 1)); }

[ -n "$ROOT" ] && rm -rf -- "$ROOT"
echo "== $fails failure(s)"
exit $fails
