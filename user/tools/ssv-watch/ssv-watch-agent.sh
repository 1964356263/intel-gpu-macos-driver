#!/bin/bash
# SPDX-License-Identifier: MIT
# ssv-watch-agent.sh: the user-session half of ssv-watch (LaunchAgent io.github.yusufklncc.intelxe.ssv-watch, at every login).
# A macOS update replaces the sealed system snapshot and drops the optional system-volume component
# (/System/Library/Extensions/NVMTLDriver.bundle, ssv-install.sh). The desktop keeps Metal through the /Library copy;
# Safari WebGL is lost. This agent notices that, as OpenCore Legacy Patcher does after an update, and asks:
#   "Yeniden kur"     -> macOS's administrator prompt -> ssv-watch-helper.sh apply (root) -> offer a restart
#   "Daha sonra"      -> ask again at the next login
#   "Bir daha sorma"  -> never ask again for this macOS build and this component (--reset forgets it)
# It writes nothing outside the user's own files; the system volume is written only by the helper, after the click.
#
#   ssv-watch-agent.sh                 launchd entry (check, dialog, re-apply on click)
#   ssv-watch-agent.sh --check         state and compatibility, no dialog, no change (exit 0 nothing to do, 1 action
#                                      needed, 2 needed but incompatible/unverifiable, 3 restart pending)
#   ssv-watch-agent.sh --reset         forget every "Bir daha sorma"
#   ssv-watch-agent.sh --test SCENARIO [--answer reinstall|later|never|ui] [--package DIR]
#       simulate SCENARIO (ok missing hash build major noaccel sandbox pending nomarker) against a private temp dir:
#       /System is only read, the helper runs as dry-run without a password prompt, no restart. --answer skips the
#       dialogs (for ssh); without it the real dialogs appear (run it in the GUI session).
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(/usr/bin/dirname "$0")" && pwd -P)
. "$HERE/ssv-watch-lib.sh"
[ "$(/usr/bin/id -u)" != 0 ] || { echo "ssv-watch-agent runs in the user session, not as root" >&2; exit 2; }

MODE=run; SCEN=""; ANSWER=""; TPKG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check;;
        --reset) MODE=reset;;
        --test) MODE=test; SCEN=${2:-}; shift;;
        --answer) ANSWER=${2:-}; shift
                  case "$ANSWER" in reinstall|later|never|ui) ;; *) echo "--answer reinstall|later|never|ui" >&2; exit 2;; esac;;
        --package) TPKG=${2:-}; shift;;
        *) /usr/bin/sed -n '2,/^umask/p' "$0" | /usr/bin/grep '^#' >&2; exit 2;;
    esac
    shift
done
[ "$ANSWER" != ui ] || ANSWER=""
{ [ -z "$ANSWER" ] && [ -z "$TPKG" ]; } || [ "$MODE" = test ] || { echo "--answer and --package are for --test only" >&2; exit 2; }

STATEDIR="$HOME/Library/Application Support/IntelXe/ssv-watch"
if [ "$MODE" = test ]; then
    TDIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ssv-watch-test.XXXXXX") || exit 1
    [ -z "$TPKG" ] || TPKG=$(cd "$TPKG" 2>/dev/null && pwd -P) || { echo "no package dir" >&2; exit 2; }
    ssvw_test_init "$SCEN" "$TDIR" "$TPKG"
    STATEDIR="$TDIR/state"
fi
/bin/mkdir -p "$STATEDIR" || exit 1
SUPPRESS="$STATEDIR/suppressed"
ssvw_log_init agent

if [ "$MODE" = reset ]; then /bin/rm -f "$SUPPRESS"; echo "ssv-watch: forgot every \"Bir daha sorma\""; exit 0; fi

# one agent per user at a time (two logins, a manual run during the launchd one)
/usr/bin/shlock -f "$STATEDIR/agent.lock" -p $$ || { ssvw_log "another agent is running"; exit 0; }
trap '/bin/rm -f "$STATEDIR/agent.lock"' EXIT

# --- the user interface: osascript in this (Aqua) session; every text goes in as an argument, never into the script ---
osa() { /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 /usr/bin/osascript "$@"; }
dialog() {   # dialog TITLE MESSAGE DEFAULT BUTTON... -> prints the button, "timeout" or "error N"
    osa - "$@" <<'OSA'
on run argv
	set ttl to item 1 of argv
	set msg to item 2 of argv
	set dflt to item 3 of argv
	set btns to items 4 thru -1 of argv
	try
		activate
		set r to display dialog msg with title ttl buttons btns default button dflt with icon caution giving up after 1800
	on error number n
		return "error " & n
	end try
	if gave up of r then return "timeout"
	return button returned of r
end run
OSA
}
notify() { osa - "$1" <<'OSA' >/dev/null 2>&1
on run argv
	display notification (item 1 of argv) with title "IntelXe Metal"
end run
OSA
}
ask() {   # ask TITLE MESSAGE DEFAULT BUTTON... ; --answer maps to the button in test mode
    local a
    if [ -n "$ANSWER" ]; then
        case "$ANSWER" in reinstall) a="Yeniden kur";; later) a="Daha sonra";; never) a="Bir daha sorma";; esac
        case " $* " in *" $a "*) ;; *) a=$3;; esac   # a dialog without that button: its default
        ssvw_log "dialog \"$1\" (auto-answer: $a)"; printf '%s\n' "$2" | /usr/bin/sed 's/^/    > /' >&2
        printf '%s' "$a"; return
    fi
    a=$(dialog "$@"); ssvw_log "dialog \"$1\" -> $a"; printf '%s' "$a"
}
# The privileged step. The command line is a constant: no path, build or text from anywhere else goes into it.
elevate_apply() {
    osa - "Bilgisayarı yeniden başlatmadan önce IntelXe Metal bileşenini (Safari WebGL) sistem birimine yeniden kurmak için yönetici parolası gerekiyor." <<'OSA'
on run argv
	try
		return do shell script "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p '/Library/Application Support/IntelXe/ssv-watch/ssv-watch-helper.sh' apply; echo \"EXIT=$?\"" with prompt (item 1 of argv) with administrator privileges without altering line endings
	on error m number n
		return "RC=" & n & linefeed & m
	end try
end run
OSA
}
run_helper() {
    if [ -n "$SSVW_TEST" ]; then   # test: the dry-run, as this user, no password prompt, nothing written outside $TDIR
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" INTELXE_SSVW_TEST=1 \
            INTELXE_SSVW_SIM="$SSVW_SIM" INTELXE_SSVW_TDIR="$SSVW_TDIR" INTELXE_SSVW_PKG="$TPKG" /bin/bash "$HERE/ssv-watch-helper.sh" dry-run
        return
    fi
    elevate_apply
}
restart() {
    if [ -n "$SSVW_TEST" ]; then ssvw_log "TEST: restart skipped"; return; fi
    # loginwindow's own restart (with its confirmation, apps may ask to save); if refused, say how
    osa -e 'tell application "loginwindow" to «event aevtrrst»' >/dev/null 2>&1 && return
    ask "IntelXe Metal" "Yeniden başlatma başlatılamadı. Lütfen Apple menüsünden Yeniden Başlat'ı seçin." "Tamam" "Tamam" >/dev/null
}
suppressed() { [ -f "$SUPPRESS" ] && /usr/bin/grep -qxF "$1" "$SUPPRESS"; }
suppress() { printf '%s\n' "$1" >>"$SUPPRESS"; ssvw_log "suppressed: $1"; }

# --- the check ---------------------------------------------------------------------------------------------------
[ "$MODE" != run ] || /bin/sleep 20   # after login items, so the dialog is not buried
ssvw_load_conf; CONFRC=$?
ssvw_state
ssvw_log "state $STATE: marker build ${MK_BUILD:-?} (${MK_DATE:-?}) plugin ${MK_SHA:0:12}, now $SSVW_CUR_VERS ($SSVW_CUR_BUILD), system copy ${SLE_SHA:-absent}${SSVW_TEST:+, TEST $SSVW_SIM}"
case "$STATE" in
    none|ok) [ "$MODE" = run ] || echo "ssv-watch: $STATE (nothing to do)"; exit 0;;
    badmarker) ssvw_log "marker $SSVW_MARK unreadable: ignoring"; [ "$MODE" = run ] || echo "ssv-watch: marker unreadable"; exit 0;;
    pending)
        [ "$MODE" = check ] && { echo "ssv-watch: re-applied on this build, restart pending"; exit 3; }
        key="pending $(ssvw_boottime)"
        if ! suppressed "$key"; then
            if [ -n "$ANSWER" ]; then ssvw_log "notification: restart pending"; else notify "Bileşen yeniden kuruldu; etkinleşmesi için yeniden başlatma bekleniyor."; fi
            suppress "$key"
        fi
        exit 0;;
esac
[ $CONFRC -ne 2 ] || ssvw_log "ssv-watch.conf is not root-owned or is writable: the package check will fail"
[ $CONFRC -ne 1 ] || [ "$SSVW_STRICT" != 1 ] || ssvw_log "no ssv-watch.conf: service not installed?"
ssvw_pkg_check; PKGRC=$?
ssvw_compat; COMPRC=$?
ssvw_log "package: ${PKG_FAIL:-ok}; compat ok: $(printf '%s' "$COMPAT_OK" | /usr/bin/tr '\n' ' ')"
[ -z "$COMPAT_WARN$COMPAT_FAIL" ] || ssvw_log "compat: $(printf '%s' "$COMPAT_FAIL$COMPAT_WARN" | /usr/bin/tr '\n' ' ')"

case "$STATE" in
    missing) WHY="Bir macOS güncellemesi sistem birimindeki IntelXe Metal bileşenini (NVMTLDriver.bundle) kaldırmış görünüyor.";;
    hash) WHY="Sistem birimindeki NVMTLDriver.bundle kurulan sürüm değil (kayıtlı ${MK_SHA:0:12}, bulunan ${SLE_SHA:0:12}).";;
    build) WHY="macOS build'i değişti ($MK_BUILD -> $SSVW_CUR_BUILD); bileşen yerinde ama bu build için kurulmadı.";;
esac
VERS="Kurulduğu build: $MK_BUILD. Şimdiki: macOS $SSVW_CUR_VERS ($SSVW_CUR_BUILD)."
KEEP="Masaüstü hızlandırması /Library'deki kopyayla sürüyor; yalnızca Safari WebGL etkileniyor."
KEEP2=$KEEP; case "$COMPAT_FAIL" in *WindowServer*|*NMXAccel*) KEEP2="";; esac
if [ "$MODE" = check ]; then
    echo "ssv-watch: $STATE - $WHY"; echo "  $VERS"
    printf '%s' "$COMPAT_OK" | /usr/bin/sed 's/^/  ok   /'; printf '%s' "$COMPAT_WARN" | /usr/bin/sed 's/^/  warn /'
    printf '%s%s' "$PKG_FAIL" "$COMPAT_FAIL" | /usr/bin/sed 's/^/  FAIL /'
    [ "$TESTED" = yes ] || echo "  note this build is not among the tested ones ($(echo $CONF_TESTED $MK_BUILD))"
    [ $PKGRC -eq 0 ] && [ $COMPRC -eq 0 ] && exit 1 || exit 2
fi

KEY="$STATE $SSVW_CUR_BUILD $MK_SHA"
if suppressed "$KEY"; then ssvw_log "not asking: \"Bir daha sorma\" for $KEY"; exit 0; fi
if [ $PKGRC -ne 0 ] || [ $COMPRC -ne 0 ]; then
    a=$(ask "IntelXe Metal: yeniden kurulamıyor" "$WHY
$VERS

Ancak bileşen bu durumda kurulamaz:
$PKG_FAIL$COMPAT_FAIL
Sistem birimine dokunulmadı. Bu macOS için yeni bir paket gerekiyor (ssv-install.sh, sonra install-service.sh update-package). $KEEP2" "Tamam" "Bir daha sorma" "Tamam")
    [ "$a" != "Bir daha sorma" ] || suppress "$KEY"
    exit 0
fi
NOTE=""
[ "$TESTED" = yes ] || NOTE="
Not: bu paket $SSVW_CUR_BUILD üzerinde denenmedi (denenen: $(echo $CONF_TESTED $MK_BUILD)). Denetimler geçti:
$COMPAT_OK"
a=$(ask "IntelXe Metal: Safari WebGL bileşeni" "$WHY
$VERS
$KEEP
$NOTE
Yeniden kurulsun mu? Yönetici parolası istenecek; önce ön denetim çalışır, sonra yeniden başlatma gerekir." \
    "Yeniden kur" "Bir daha sorma" "Daha sonra" "Yeniden kur")
case "$a" in
    "Bir daha sorma") suppress "$KEY"; exit 0;;
    "Yeniden kur") ;;
    *) ssvw_log "later ($a)"; exit 0;;
esac

[ -n "$ANSWER" ] || notify "Ön denetim ve kurulum çalışıyor…"
R=$(run_helper)
ssvw_log "helper: $(printf '%s' "$R" | /usr/bin/tr '\n' '|')"
RC=$(printf '%s\n' "$R" | /usr/bin/sed -n 's/^RC=\(-\{0,1\}[0-9]*\).*/\1/p' | /usr/bin/head -1)
MSG=$(printf '%s\n' "$R" | /usr/bin/grep -v -e '^RC=' -e '^EXIT=')
LOGHINT="Kayıt: $SSVW_LOGDIR/ssv-watch.log"; [ -z "$SSVW_TEST" ] || LOGHINT="Kayıt: $SSVW_TDIR"
case "$RC" in
    0)
        a=$(ask "IntelXe Metal: kuruldu" "$MSG

Şimdi yeniden başlatılsın mı?${SSVW_TEST:+ (TEST: yeniden başlatılmaz)}" "Yeniden başlat" "Daha sonra" "Yeniden başlat")
        [ "$a" != "Yeniden başlat" ] || restart;;
    -128) ssvw_log "administrator prompt cancelled";;
    *) ask "IntelXe Metal: kurulmadı" "${MSG:-Beklenmeyen sonuç (RC=${RC:-?}).}

$LOGHINT" "Tamam" "Tamam" >/dev/null;;
esac
[ -z "$SSVW_TEST" ] || echo "ssv-watch test: logs and state in $SSVW_TDIR" >&2
exit 0
