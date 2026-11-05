#!/bin/bash -p
# SPDX-License-Identifier: MIT
# ssv-watch-helper.sh VERB: the only part of ssv-watch that runs as root. The agent starts it, after the user clicked
# "Yeniden kur", through macOS's own administrator prompt (osascript "do shell script ... with administrator privileges")
# with a constant command line: env -i, absolute paths, one fixed verb. Nothing listens and nothing runs as root otherwise.
#
#   apply     (root, from the installed location only) verify the staged package (pinned SHA256SUMS, every file, root
#             ownership, no extra files), check that this macOS still takes the component, run the package's
#             ssv-install.sh --preflight and, only if that passes, ssv-install.sh --apply. Log: /Library/Logs/IntelXe/ssv-watch.log
#   dry-run   all of the above except --apply (read-only; also as a normal user, and in the agent's test mode)
#
# Output (stdout): "RC=<n>" then a few lines for the user. 0 done, 10 package/integrity, 11 incompatible with this
# macOS, 12 preflight failed, 13 apply failed, 14 busy, 20 nothing to do, 2 usage. The exit status is the same number.
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
IFS=$' \t\n'
unset CDPATH ENV BASH_ENV
SELF_DIR=$(cd "$(/usr/bin/dirname "$0")" 2>/dev/null && pwd -P)
cd / || exit 1
FIXED_DIR="/Library/Application Support/IntelXe/ssv-watch"
usage() { echo "RC=2"; echo "usage: ssv-watch-helper.sh apply|dry-run"; exit 2; }
[ $# -eq 1 ] || usage
VERB=$1
case "$VERB" in apply|dry-run) ;; *) usage;; esac

if [ "$(/usr/bin/id -u)" = 0 ]; then
    # as root only the installed copy runs, and only with the installed, root-owned library
    [ "$0" = "$FIXED_DIR/ssv-watch-helper.sh" ] || { echo "RC=2"; echo "as root run only $FIXED_DIR/ssv-watch-helper.sh"; exit 2; }
    LIB="$FIXED_DIR/ssv-watch-lib.sh"
    for x in "$FIXED_DIR" "$LIB" "$0"; do
        [ ! -L "$x" ] && [ "$(/usr/bin/stat -f %u "$x" 2>/dev/null)" = 0 ] || { echo "RC=10"; echo "not root-owned: $x"; exit 10; }
        case "$(/usr/bin/stat -f %Lp "$x")" in *[2367][0-7]|*[2367]) echo "RC=10"; echo "writable by group/others: $x"; exit 10;; esac
    done
    . "$LIB" || { echo "RC=10"; echo "cannot load $LIB"; exit 10; }
else
    [ "$VERB" = dry-run ] || { echo "RC=2"; echo "apply needs root (the agent asks for the administrator password)"; exit 2; }
    LIB="$SELF_DIR/ssv-watch-lib.sh"
    . "$LIB" || { echo "RC=10"; echo "cannot load $LIB"; exit 10; }
    # the agent's test mode passes its scenario in the environment; honoured for a non-root dry-run only
    if [ "${INTELXE_SSVW_TEST:-}" = 1 ]; then ssvw_test_init "${INTELXE_SSVW_SIM:-}" "${INTELXE_SSVW_TDIR:-}" "${INTELXE_SSVW_PKG:-}"; fi
fi

ssvw_log_init helper
OUT=""
finish() {   # finish RC line...
    local rc=$1; shift
    OUT="RC=$rc"; local l; for l in "$@"; do [ -n "$l" ] && OUT="$OUT
$l"; done
    ssvw_log "result: $(printf '%s' "$OUT" | /usr/bin/tr '\n' '|')"
    printf '%s\n' "$OUT"
    [ -z "${LOCKED:-}" ] || /bin/rm -f "$SSVW_LOCK"
    exit "$rc"
}
ssvw_log "== $VERB, uid $(/usr/bin/id -u), macOS $SSVW_CUR_VERS ($SSVW_CUR_BUILD)${SSVW_TEST:+, TEST $SSVW_SIM}"
if [ "$(/usr/bin/id -u)" = 0 ]; then
    /usr/bin/shlock -f "$SSVW_LOCK" -p $$ || finish 14 "Başka bir ssv-watch işlemi sürüyor; daha sonra tekrar deneyin."
    LOCKED=1
fi

ssvw_load_conf; case $? in
    1) [ "$SSVW_STRICT" = 1 ] && finish 10 "ssv-watch.conf yok: servis kurulu değil ($SSVW_CONF).";;
    2) finish 10 "ssv-watch.conf root'a ait değil ya da yazılabilir.";;
esac
ssvw_state
ssvw_log "state $STATE: marker build ${MK_BUILD:-?} plugin ${MK_SHA:0:12}, now $SSVW_CUR_BUILD, system copy ${SLE_SHA:0:12}${SLE_SHA:+ }at $SSVW_SLE"
case "$STATE" in
    none) finish 20 "Bileşen kurulu değil (işaretçi yok): yapılacak bir şey yok.";;
    badmarker) finish 10 "İşaretçi okunamadı: $SSVW_MARK";;
    ok) finish 20 "Bileşen zaten yerinde ve kayıtla aynı: yapılacak bir şey yok.";;
    pending) finish 20 "Bileşen bu açılıştan sonra zaten yeniden kuruldu: yeniden başlatma bekleniyor.";;
esac

ssvw_pkg_check || finish 10 "Paket doğrulanamadı; sistem birimine dokunulmadı:" "$PKG_FAIL"
ssvw_log "package $SSVW_PKG verified (plugin ${PKG_SHA:0:12})"
ssvw_compat; ssvw_log "compat ok: $(printf '%s' "$COMPAT_OK" | /usr/bin/tr '\n' ' ')"
[ -z "$COMPAT_WARN" ] || ssvw_log "compat warn: $(printf '%s' "$COMPAT_WARN" | /usr/bin/tr '\n' ' ')"
[ -z "$COMPAT_FAIL" ] || finish 11 "Bu macOS ($SSVW_CUR_VERS, $SSVW_CUR_BUILD) bu paketle uyumsuz; sistem birimine dokunulmadı:" "$COMPAT_FAIL"
[ "$TESTED" = yes ] || ssvw_log "build $SSVW_CUR_BUILD is not among the tested builds ($CONF_TESTED $MK_BUILD)"

INSTALL="$SSVW_PKG/ssv-install.sh"
ssvw_log "running $INSTALL --preflight"
PF=$(/bin/bash "$INSTALL" --preflight 2>&1); rc=$?
[ -z "$SSVW_LOG" ] || printf '%s\n' "$PF" | /usr/bin/sed 's/^/    | /' >>"$SSVW_LOG"
[ -z "$SSVW_ECHO" ] || printf '%s\n' "$PF" | /usr/bin/sed 's/^/    | /' >&2
[ $rc -eq 0 ] || finish 12 "Ön denetim (ssv-install.sh --preflight) başarısız; sistem birimine dokunulmadı:" \
    "$(printf '%s\n' "$PF" | /usr/bin/grep 'FAIL' | /usr/bin/head -5)"

if [ "$VERB" = dry-run ]; then
    finish 0 "DRY-RUN: paket, uyumluluk ve ön denetim geçti. Gerçek kurulumda çalışacak olan: \"$INSTALL\" --apply (sistem birimine dokunulmadı)."
fi

ssvw_log "running $INSTALL --apply"
AP=$(/bin/bash "$INSTALL" --apply 2>&1); rc=$?
[ -z "$SSVW_LOG" ] || printf '%s\n' "$AP" | /usr/bin/sed 's/^/    | /' >>"$SSVW_LOG"
[ $rc -eq 0 ] || finish 13 "Kurulum başarısız (ssv-install.sh --apply, çıkış $rc). Ayrıntı: $SSVW_LOG" \
    "$(printf '%s\n' "$AP" | /usr/bin/tail -3)"
ssvw_read_marker
[ "$MK_BUILD" = "$SSVW_CUR_BUILD" ] && [ "$MK_SHA" = "$PKG_SHA" ] || \
    finish 13 "ssv-install.sh bitti ama işaretçi beklenen değil (build $MK_BUILD, eklenti ${MK_SHA:0:12}). Ayrıntı: $SSVW_LOG"
finish 0 "Bileşen kuruldu ve yeni açılış snapshot'ı hazırlandı. Safari WebGL için bilgisayarı yeniden başlatın."
