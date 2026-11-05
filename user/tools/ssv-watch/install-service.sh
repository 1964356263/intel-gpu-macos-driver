#!/bin/bash -p
# SPDX-License-Identifier: MIT
# install-service.sh: install / update / remove ssv-watch (see README.md).
#   sudo ./install-service.sh install --package DIR [--no-load]
#        DIR = the ssv-install.sh package that is installed now (e.g. ~/b580/ssv8). Copies ONLY the files listed in its
#        SHA256SUMS (after checking them) to /Library/Application Support/IntelXe/ssv (root:wheel, 755/644), the agent,
#        helper and library to .../IntelXe/ssv-watch, pins the package's SHA256SUMS in ssv-watch.conf, installs
#        /Library/LaunchAgents/io.github.yusufklncc.intelxe.ssv-watch.plist and (unless --no-load) loads it for the sudo user.
#   sudo ./install-service.sh update-package --package DIR    re-stage a new package (after a manual ssv-install.sh --apply)
#   sudo ./install-service.sh uninstall [--keep-package]      unload and remove everything except the logs
#   ./install-service.sh status                               files, owners, the pinned package, the agent's --check
# Writes nothing to the system volume; the component itself stays as it is.
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
IFS=$' \t\n'
unset CDPATH ENV BASH_ENV
H=$(cd "$(/usr/bin/dirname "$0")" && pwd -P)
. "$H/ssv-watch-lib.sh"
die() { echo "install-service: $*" >&2; exit 1; }
VERB=${1:-}; [ $# -gt 0 ] && shift
SRC=""; NOLOAD=""; KEEPPKG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --package) SRC=${2:-}; shift;;
        --no-load) NOLOAD=1;;
        --keep-package) KEEPPKG=1;;
        *) die "unknown option $1";;
    esac; shift
done
need_root() { [ "$(/usr/bin/id -u)" = 0 ] || die "$VERB needs root: sudo $0 $VERB ..."; }
user_uid() { [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && /usr/bin/id -u "$SUDO_USER" 2>/dev/null; }

verify_own() {   # the agent, helper, library and plist next to this script, against ./SHA256SUMS
    [ -f "$H/SHA256SUMS" ] || die "no $H/SHA256SUMS"
    (cd "$H" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || die "ssv-watch files differ from $H/SHA256SUMS"
    local f; for f in ssv-watch-agent.sh ssv-watch-helper.sh ssv-watch-lib.sh "$SSVW_LABEL.plist"; do
        /usr/bin/grep -q "  $f\$" "$H/SHA256SUMS" || die "$f not in $H/SHA256SUMS"; done
}
# the source package: the same checks the helper makes, minus ownership (it is the user's copy)
verify_src() {
    [ -n "$SRC" ] || die "--package DIR is required"
    SRC=$(cd "$SRC" 2>/dev/null && pwd -P) || die "no package dir"
    local save_pkg=$SSVW_PKG save_strict=$SSVW_STRICT
    SSVW_PKG=$SRC; SSVW_STRICT=0; CONF_SUMS=""; CONF_PLUGIN=""
    ssvw_read_marker
    ssvw_pkg_check; local rc=$?
    SSVW_PKG=$save_pkg; SSVW_STRICT=$save_strict
    if [ $rc -ne 0 ]; then
        case "$PKG_FAIL" in
            *"kurulu olan bileşen değil"*) echo "WARNING: $SRC is not the installed component (marker plugin ${MK_SHA:0:12}, package ${PKG_SHA:0:12})."
                                         echo "         ssv-watch will refuse to re-apply until the installed one and the staged one agree.";;
            *) printf '%s' "$PKG_FAIL" >&2; die "package $SRC refused";;
        esac
        [ "$(printf "%s" "$PKG_FAIL" | /usr/bin/grep -c .)" -le 1 ] || { printf "%s" "$PKG_FAIL" >&2; die "package $SRC refused"; }
    fi
    echo "package $SRC verified: plugin ${PKG_SHA:0:12}, $(/usr/bin/wc -l <"$SRC/SHA256SUMS" | /usr/bin/tr -d ' ') files"
}
mkroot() { /usr/bin/install -d -o root -g wheel -m 755 "$1" || die "mkdir $1"; }
put() {   # put SRC DST: root:wheel, 755 if the source is executable by its owner, else 644, no ACLs or flags
    local m=644; [ -x "$1" ] && m=755
    /usr/bin/install -o root -g wheel -m $m "$1" "$2" || die "copy $1"
}
stage_package() {
    local new="$SSVW_PKG.new" old="$SSVW_PKG.old" f
    /bin/rm -rf "$new" "$old"; mkroot "$SSVW_ROOT"; mkroot "$new"
    while IFS= read -r f; do
        f=${f#\*}
        mkroot "$new/$(/usr/bin/dirname "$f")"
        put "$SRC/$f" "$new/$f"
    done < <(/usr/bin/sed -E 's/^[0-9a-f]{64}  //' "$SRC/SHA256SUMS")
    put "$SRC/SHA256SUMS" "$new/SHA256SUMS"
    /usr/bin/find "$new" -type d -exec /bin/chmod 755 {} +
    /bin/chmod -RN "$new" 2>/dev/null; /usr/bin/chflags -R 0 "$new" 2>/dev/null
    (cd "$new" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || { /bin/rm -rf "$new"; die "staged copy does not match SHA256SUMS"; }
    [ ! -e "$SSVW_PKG" ] || /bin/mv "$SSVW_PKG" "$old"
    /bin/mv "$new" "$SSVW_PKG" && /bin/rm -rf "$old"
    echo "staged $SSVW_PKG"
}
write_conf() {
    local tested="" t="$SSVW_DIR/ssv-watch.conf.new"
    [ -n "$MK_SHA" ] && [ "$MK_SHA" = "$PKG_SHA" ] && tested=$MK_BUILD
    local major; major=$(ssvw_major "${MK_BUILD:-$SSVW_CUR_BUILD}")
    {
        echo "# ssv-watch.conf: written by install-service.sh $(/bin/date '+%Y-%m-%dT%H:%M:%S'); parsed, not sourced"
        echo "PKG_SUMS_SHA256=$(ssvw_sha "$SSVW_PKG/SHA256SUMS")"
        echo "PKG_PLUGIN_SHA256=$(ssvw_sha "$SSVW_PKG/system-layout/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver")"
        echo "PKG_DARWIN_MAJOR=$major"
        echo "TESTED_BUILDS=$tested"
    } >"$t" && /usr/sbin/chown root:wheel "$t" && /bin/chmod 644 "$t" && /bin/mv "$t" "$SSVW_CONF" || die "conf"
    echo "pinned in $SSVW_CONF:"; /usr/bin/sed 's/^/    /' "$SSVW_CONF"
}
logs() {
    mkroot "$SSVW_LOGDIR"
    [ -e "$SSVW_LOGDIR/ssv-watch.log" ] || { /usr/bin/touch "$SSVW_LOGDIR/ssv-watch.log"; /usr/sbin/chown root:wheel "$SSVW_LOGDIR/ssv-watch.log"; /bin/chmod 644 "$SSVW_LOGDIR/ssv-watch.log"; }
    if user_uid >/dev/null; then   # the agent's log: owned by that user, in a directory only root can write
        local f="$SSVW_LOGDIR/ssv-watch-agent.$SUDO_USER.log"
        [ -L "$f" ] && /bin/rm -f "$f"
        /usr/bin/touch "$f" && /usr/sbin/chown "$SUDO_USER" "$f" && /bin/chmod 644 "$f"
    fi
}
load_for_user() {
    local uid; uid=$(user_uid) || { echo "no sudo user: the agent loads at the next login"; return; }
    /bin/launchctl print "gui/$uid" >/dev/null 2>&1 || { echo "$SUDO_USER has no GUI session: the agent loads at the next login"; return; }
    /bin/launchctl bootout "gui/$uid/$SSVW_LABEL" 2>/dev/null
    /bin/launchctl bootstrap "gui/$uid" "$SSVW_PLIST" && echo "loaded for $SUDO_USER (it checks now; silent while the component is in place)"
}
unload_all() {
    local u uid; for u in $(/usr/bin/stat -f %Su /dev/console) ${SUDO_USER:-}; do
        uid=$(/usr/bin/id -u "$u" 2>/dev/null) || continue; [ "$uid" != 0 ] || continue
        /bin/launchctl bootout "gui/$uid/$SSVW_LABEL" 2>/dev/null && echo "unloaded for $u"; done
}

case "$VERB" in
    install)
        need_root; verify_own; verify_src
        stage_package
        mkroot "$SSVW_DIR"
        put "$H/ssv-watch-agent.sh" "$SSVW_DIR/ssv-watch-agent.sh"; /bin/chmod 755 "$SSVW_DIR/ssv-watch-agent.sh"
        put "$H/ssv-watch-helper.sh" "$SSVW_HELPER"; /bin/chmod 755 "$SSVW_HELPER"
        put "$H/ssv-watch-lib.sh" "$SSVW_DIR/ssv-watch-lib.sh"; /bin/chmod 644 "$SSVW_DIR/ssv-watch-lib.sh"
        write_conf; logs
        /usr/bin/plutil -lint "$H/$SSVW_LABEL.plist" >/dev/null || die "plist"
        /usr/bin/install -o root -g wheel -m 644 "$H/$SSVW_LABEL.plist" "$SSVW_PLIST" || die "plist copy"
        echo "installed $SSVW_PLIST"
        [ -n "$NOLOAD" ] && echo "--no-load: the agent starts at the next login" || load_for_user;;
    update-package)
        need_root; [ -d "$SSVW_DIR" ] || die "ssv-watch is not installed"; verify_src; stage_package; write_conf;;
    uninstall)
        need_root; unload_all
        /bin/rm -f "$SSVW_PLIST"; /bin/rm -rf "$SSVW_DIR"
        [ -n "$KEEPPKG" ] || /bin/rm -rf "$SSVW_PKG"
        /bin/rmdir "$SSVW_ROOT" 2>/dev/null
        echo "removed (logs kept in $SSVW_LOGDIR; the system-volume component itself is untouched)";;
    status)
        /bin/ls -ld "$SSVW_ROOT" "$SSVW_PKG" "$SSVW_DIR" "$SSVW_PLIST" "$SSVW_LOGDIR" 2>&1
        [ ! -f "$SSVW_CONF" ] || /usr/bin/sed 's/^/    /' "$SSVW_CONF"
        uid=$(/usr/bin/id -u); [ "$uid" = 0 ] && uid=$(user_uid)
        [ -z "$uid" ] || /bin/launchctl print "gui/$uid/$SSVW_LABEL" 2>/dev/null | /usr/bin/grep -E '^\s*(state|last exit code|runs) ' | /usr/bin/sed 's/^/    /'
        if [ "$(/usr/bin/id -u)" != 0 ] && [ -f "$SSVW_DIR/ssv-watch-agent.sh" ]; then /bin/bash "$SSVW_DIR/ssv-watch-agent.sh" --check; fi;;
    *) /usr/bin/sed -n '3,12p' "$0"; exit 2;;
esac
