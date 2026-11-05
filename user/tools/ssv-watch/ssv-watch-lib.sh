# SPDX-License-Identifier: MIT
# ssv-watch-lib.sh: sourced by ssv-watch-agent.sh (the user's LaunchAgent) and ssv-watch-helper.sh (the only part that
# runs as root). Every path is fixed and absolute. The test overrides (ssvw_test_init) refuse to run as root, so nothing
# started as root can be pointed at another package, marker or system path.
# bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile, no ${x,,}.

SSVW_LABEL=io.github.yusufklncc.intelxe.ssv-watch
SSVW_ROOT="/Library/Application Support/IntelXe"
SSVW_PKG="$SSVW_ROOT/ssv"                                  # root-owned copy of the ssv-install.sh package
SSVW_DIR="$SSVW_ROOT/ssv-watch"                            # agent, helper, this file, ssv-watch.conf
SSVW_CONF="$SSVW_DIR/ssv-watch.conf"
SSVW_HELPER="$SSVW_DIR/ssv-watch-helper.sh"
SSVW_PLIST="/Library/LaunchAgents/$SSVW_LABEL.plist"
SSVW_LOGDIR=/Library/Logs/IntelXe
SSVW_LOCK="/var/run/$SSVW_LABEL.lock"                     # root's apply lock (shlock)
SSVW_SLE=/System/Library/Extensions/NVMTLDriver.bundle     # the component in the booted snapshot
SSVW_MARK=/Library/GPUBundles/nvmtl/ssv-component.plist    # written by ssv-install.sh --apply (data volume)
SSVW_LIBCOPY=/Library/GPUBundles/NVMTLDriverLib.bundle     # NMXAccel's fallback when the system copy is absent
# WebKit's GPU process sandbox: the reason the component exists (it may map code from /System/Library/Extensions only)
SSVW_WKSB_LIST="/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/Resources/com.apple.WebKit.GPUProcess.sb
/System/Library/Frameworks/WebKit.framework/Versions/A/Resources/com.apple.WebKit.GPUProcess.sb"
SSVW_CUR_BUILD=$(/usr/bin/sw_vers -buildVersion 2>/dev/null)
SSVW_CUR_VERS=$(/usr/bin/sw_vers -productVersion 2>/dev/null)
SSVW_STRICT=1          # ownership/permission checks and a pinned SHA256SUMS (off only in test mode)
SSVW_TEST=""; SSVW_SIM=""; SSVW_TDIR=""; SSVW_SIM_PENDING=""; SSVW_WS_OVERRIDE=""
SSVW_LOG=""; SSVW_ECHO=""; SSVW_WHO=ssv-watch

ssvw_log() {
    local line; line="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$SSVW_WHO $$] $*"
    [ -z "$SSVW_LOG" ] || printf '%s\n' "$line" >>"$SSVW_LOG" 2>/dev/null
    [ -z "$SSVW_ECHO" ] || printf '%s\n' "$line" >&2
}
ssvw_is_sha()   { local re='^[0-9a-f]{64}$'; [[ $1 =~ $re ]]; }
ssvw_is_build() { local re='^[0-9]{2}[A-Z][0-9]{1,6}[a-z]?$'; [[ $1 =~ $re ]]; }
ssvw_major()    { printf '%s' "${1%%[A-Z]*}"; }                # 24H32 -> 24 (Darwin 24 = macOS 15)
ssvw_sha()      { /usr/bin/shasum -a 256 "$1" 2>/dev/null | /usr/bin/cut -c1-64; }
ssvw_boottime() { /usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/sed -E 's/^\{ sec = ([0-9]+).*/\1/'; }
ssvw_mode_ok()  {   # $1: path; root-owned and not writable by group or others
    [ -e "$1" ] && [ ! -L "$1" ] || return 1
    [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || return 1
    local m; m=$(/usr/bin/stat -f %Lp "$1"); m=${m: -2}
    case "${m:0:1}" in 2|3|6|7) return 1;; esac; case "${m:1:1}" in 2|3|6|7) return 1;; esac
}

# Logging. Root: /Library/Logs/IntelXe/ssv-watch.log (dir root:wheel 755, so no user can plant a link there). User: the
# per-user file install-service.sh pre-creates there, else ~/Library/Logs/IntelXe/ssv-watch-agent.log. Test: the temp dir.
ssvw_log_init() {
    SSVW_WHO=$1; SSVW_LOG=""
    if [ -n "$SSVW_TEST" ]; then SSVW_LOG="$SSVW_TDIR/$1.log"; SSVW_ECHO=1; return 0; fi
    if [ "$(/usr/bin/id -u)" = 0 ]; then
        [ -L "$SSVW_LOGDIR" ] && return 0
        /bin/mkdir -p "$SSVW_LOGDIR" && /usr/sbin/chown root:wheel "$SSVW_LOGDIR" && /bin/chmod 755 "$SSVW_LOGDIR" || return 0
        SSVW_LOG="$SSVW_LOGDIR/ssv-watch.log"
        [ ! -L "$SSVW_LOG" ] || /bin/rm -f "$SSVW_LOG"
        if [ -f "$SSVW_LOG" ] && [ "$(/usr/bin/stat -f %z "$SSVW_LOG")" -gt 1048576 ]; then /bin/mv -f "$SSVW_LOG" "$SSVW_LOG.1"; fi
        /usr/bin/touch "$SSVW_LOG" && /usr/sbin/chown root:wheel "$SSVW_LOG" && /bin/chmod 644 "$SSVW_LOG"
    else
        local f; f="$SSVW_LOGDIR/ssv-watch-agent.$(/usr/bin/id -un).log"
        if [ -f "$f" ] && [ ! -L "$f" ] && [ -w "$f" ]; then SSVW_LOG=$f
        else /bin/mkdir -p "$HOME/Library/Logs/IntelXe" 2>/dev/null; SSVW_LOG="$HOME/Library/Logs/IntelXe/ssv-watch-agent.log"; fi
        if [ -f "$SSVW_LOG" ] && [ "$(/usr/bin/stat -f %z "$SSVW_LOG")" -gt 1048576 ]; then : >"$SSVW_LOG"; fi
    fi
}

# Test mode: simulate a situation without touching /System. $1 scenario, $2 a private temp dir, $3 package dir (optional).
# Only the agent's checks and the helper's dry-run use it; the helper's apply needs root, and root refuses this.
ssvw_test_init() {
    [ "$(/usr/bin/id -u)" != 0 ] || { echo "ssv-watch: test mode is refused as root" >&2; exit 2; }
    [ -d "$2" ] && [ ! -L "$2" ] && [ "$(/usr/bin/stat -f %u "$2")" = "$(/usr/bin/id -u)" ] || { echo "ssv-watch: bad test dir $2" >&2; exit 2; }
    SSVW_TEST=1; SSVW_SIM=$1; SSVW_TDIR=$2; SSVW_STRICT=0
    if [ -n "${3:-}" ]; then SSVW_PKG=$3; SSVW_CONF="$SSVW_TDIR/no-such.conf"; fi   # a conf pins the installed package only
    local fake="$SSVW_TDIR/sle/NVMTLDriver.bundle"
    case "$SSVW_SIM" in
        ok) ;;                                                            # the real system, read-only
        missing|major|noaccel|sandbox|pending) SSVW_SLE=$fake;;          # a path that does not exist
        hash) /bin/mkdir -p "$fake/Contents/MacOS"; printf 'not the recorded plugin\n' >"$fake/Contents/MacOS/NVMTLDriver"; SSVW_SLE=$fake;;
        build) ;;                                                         # build changed, component still in place
        nomarker) SSVW_MARK="$SSVW_TDIR/no-such-marker.plist";;
        *) echo "ssv-watch: unknown test scenario '$SSVW_SIM' (ok missing hash build major noaccel sandbox pending nomarker)" >&2; exit 2;;
    esac
    case "$SSVW_SIM" in
        noaccel) SSVW_WS_OVERRIDE=0;;
        pending) SSVW_SIM_PENDING=1;;
        sandbox) printf '(version 1)\n(allow file-map-executable\n    (subpath "/System/Library/Frameworks")\n    (subpath "/usr/lib"))\n' >"$SSVW_TDIR/GPUProcess.sb"
                 SSVW_WKSB_LIST="$SSVW_TDIR/GPUProcess.sb";;
    esac
}

# ssv-watch.conf: written by install-service.sh, root:wheel 644. Parsed, never sourced; unknown keys and bad values ignored.
ssvw_load_conf() {
    CONF_SUMS=""; CONF_PLUGIN=""; CONF_MAJOR=""; CONF_TESTED=""
    [ -f "$SSVW_CONF" ] || return 1
    if [ "$SSVW_STRICT" = 1 ]; then ssvw_mode_ok "$SSVW_CONF" || return 2; fi
    local k v b re='^[0-9]{2}$'
    while IFS='=' read -r k v; do
        case "$k" in
            PKG_SUMS_SHA256) ssvw_is_sha "$v" && CONF_SUMS=$v;;
            PKG_PLUGIN_SHA256) ssvw_is_sha "$v" && CONF_PLUGIN=$v;;
            PKG_DARWIN_MAJOR) [[ $v =~ $re ]] && CONF_MAJOR=$v;;
            TESTED_BUILDS) for b in $v; do ssvw_is_build "$b" && CONF_TESTED="$CONF_TESTED $b"; done;;
        esac
    done <"$SSVW_CONF"
    return 0
}

ssvw_read_marker() {   # 1: no marker (component not installed), 2: marker unreadable
    MK_BUILD=""; MK_SHA=""; MK_DATE=""; MK_MTIME=0
    [ -f "$SSVW_MARK" ] || return 1
    MK_BUILD=$(/usr/bin/plutil -extract build raw -o - "$SSVW_MARK" 2>/dev/null)
    MK_SHA=$(/usr/bin/plutil -extract sha raw -o - "$SSVW_MARK" 2>/dev/null)
    MK_DATE=$(/usr/bin/plutil -extract date raw -o - "$SSVW_MARK" 2>/dev/null | /usr/bin/tr -cd '0-9T:-')
    MK_MTIME=$(/usr/bin/stat -f %m "$SSVW_MARK")
    ssvw_is_build "$MK_BUILD" && ssvw_is_sha "$MK_SHA" || return 2
}

# STATE: none | badmarker | ok | missing | hash | build | pending
ssvw_state() {
    STATE=""; SLE_SHA=""
    ssvw_read_marker; local rc=$?
    case $rc in 1) STATE=none; return 0;; 2) STATE=badmarker; return 0;; esac
    case "$SSVW_SIM" in   # simulated updates: same major with a new build, or the next major
        build) SSVW_CUR_BUILD="$(ssvw_major "$MK_BUILD")Z999";;
        major) SSVW_CUR_BUILD="$(( $(ssvw_major "$MK_BUILD") + 1 ))A100";;
    esac
    if [ ! -e "$SSVW_SLE" ]; then STATE=missing
    else
        SLE_SHA=$(ssvw_sha "$SSVW_SLE/Contents/MacOS/NVMTLDriver")
        if [ "$SLE_SHA" != "$MK_SHA" ]; then STATE=hash
        elif [ "$SSVW_CUR_BUILD" != "$MK_BUILD" ]; then STATE=build
        else STATE=ok; fi
    fi
    # re-applied on this build after this boot: the new snapshot is blessed but not booted yet
    if { [ "$STATE" = missing ] || [ "$STATE" = hash ]; } && [ "$MK_BUILD" = "$SSVW_CUR_BUILD" ]; then
        local bt; bt=$(ssvw_boottime)
        if [ -n "$SSVW_SIM_PENDING" ] || { [ -z "$SSVW_TEST" ] && [ -n "$bt" ] && [ "$MK_MTIME" -gt "$bt" ]; }; then STATE=pending; fi
    fi
    return 0
}

# The staged package: complete, unmodified, root-owned, and the very build that the marker says was installed.
ssvw_pkg_check() {
    PKG_FAIL=""; PKG_SHA=""
    local p="$SSVW_PKG" s="$SSVW_PKG/SHA256SUMS" out bad x
    pf() { PKG_FAIL="$PKG_FAIL- $*
"; }
    if [ ! -d "$p" ] || [ -L "$p" ] || [ ! -f "$s" ]; then pf "paket yok: $p"; return 1; fi
    if [ "$SSVW_STRICT" = 1 ]; then
        for x in /Library "/Library/Application Support" "$SSVW_ROOT" "$SSVW_DIR" "$p"; do ssvw_mode_ok "$x" || pf "root'a ait değil ya da yazılabilir: $x"; done
        x=$(/usr/bin/find "$p" "$SSVW_DIR" \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print 2>/dev/null | /usr/bin/head -3)
        [ -z "$x" ] || pf "root'a ait değil ya da yazılabilir: $(printf '%s' "$x" | /usr/bin/tr '\n' ' ')"
        if [ -z "$CONF_SUMS" ]; then pf "ssv-watch.conf'ta sabitlenmiş SHA256SUMS özeti yok"
        elif [ "$(ssvw_sha "$s")" != "$CONF_SUMS" ]; then pf "SHA256SUMS kurulumdakinden farklı (sabitlenmiş özet tutmuyor)"; fi
    elif [ -n "$CONF_SUMS" ] && [ "$(ssvw_sha "$s")" != "$CONF_SUMS" ]; then pf "SHA256SUMS sabitlenmiş özetle tutmuyor"; fi
    x=$(/usr/bin/find "$p" -type l -print 2>/dev/null | /usr/bin/head -1); [ -z "$x" ] || pf "pakette sembolik bağ var: $x"
    bad=$(/usr/bin/grep -Ev '^[0-9a-f]{64}  \*?[A-Za-z0-9._+/-]+$' "$s" | /usr/bin/head -1)
    [ -z "$bad" ] || pf "SHA256SUMS biçimi bozuk: $bad"
    /usr/bin/grep -Eq '  \*?(/|(.*/)?\.\.(/|$))' "$s" && pf "SHA256SUMS paketin dışına işaret ediyor"
    for x in ssv-install.sh sigcheck system-layout/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver; do
        /usr/bin/grep -Eq "^[0-9a-f]{64}  \\*?$x\$" "$s" || pf "SHA256SUMS içinde yok: $x"; done
    [ -z "$PKG_FAIL" ] || return 1
    out=$(cd "$p" && /usr/bin/shasum -a 256 -c SHA256SUMS 2>&1); local rc=$?
    bad=$(printf '%s\n' "$out" | /usr/bin/grep -v ': OK$' | /usr/bin/head -3)
    [ $rc -eq 0 ] && [ -z "$bad" ] || pf "dosyalar SHA256SUMS ile tutmuyor: $(printf '%s' "$bad" | /usr/bin/tr '\n' ' ')"
    bad=$(/usr/bin/comm -13 <(/usr/bin/sed -E 's/^[0-9a-f]{64}  \*?//' "$s" | LC_ALL=C /usr/bin/sort) \
                             <(cd "$p" && /usr/bin/find . -type f ! -path ./SHA256SUMS | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort) | /usr/bin/head -3)
    [ -z "$bad" ] || pf "SHA256SUMS'ta olmayan dosyalar: $(printf '%s' "$bad" | /usr/bin/tr '\n' ' ')"
    PKG_SHA=$(ssvw_sha "$p/system-layout/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver")
    [ -z "$CONF_PLUGIN" ] || [ "$PKG_SHA" = "$CONF_PLUGIN" ] || pf "paketteki eklenti kurulumda sabitlenenden farklı"
    [ -z "$MK_SHA" ] || [ "$PKG_SHA" = "$MK_SHA" ] || pf "hazırdaki paket (${PKG_SHA:0:12}) kurulu olan bileşen değil (${MK_SHA:0:12}): paketi install-service.sh update-package ile yenileyin"
    [ -z "$PKG_FAIL" ]
}

# Does this macOS still take the component? Hard failures (COMPAT_FAIL) mean: say so, do not offer to install.
ssvw_ws_metal() {   # Metal devices WindowServer opened on NMXAccel (= the plugin, here the /Library copy, works on this build)
    if [ -n "$SSVW_WS_OVERRIDE" ]; then printf '%s' "$SSVW_WS_OVERRIDE"; return; fi
    /usr/sbin/ioreg -r -c NMXAccel -l -w0 2>/dev/null | /usr/bin/awk '
        /\+-o / { c = $0; sub(/.*\+-o /, "", c); sub(/ .*/, "", c) }
        /"IOUserClientCreator" = "pid [0-9]+, WindowServer"/ { if (c == "IOAccelDevice2" || c == "IOAccelSharedUserClient2") n++ }
        END { print n + 0 }'
}
ssvw_compat() {
    COMPAT_FAIL=""; COMPAT_WARN=""; COMPAT_OK=""; TESTED=no
    cf() { COMPAT_FAIL="$COMPAT_FAIL- $*
"; }; cw() { COMPAT_WARN="$COMPAT_WARN- $*
"; }; co() { COMPAT_OK="$COMPAT_OK- $*
"; }
    local cur pkg ior from ws sb f
    cur=$(ssvw_major "$SSVW_CUR_BUILD"); pkg=${CONF_MAJOR:-$(ssvw_major "$MK_BUILD")}
    if [ "$cur" != "$pkg" ]; then cf "macOS ana sürümü değişti (Darwin $pkg -> $cur, build $SSVW_CUR_BUILD): bu paket o macOS için yapılmadı"
    else co "aynı macOS ana sürümü (Darwin $cur)"; fi
    case " $CONF_TESTED $MK_BUILD " in *" $SSVW_CUR_BUILD "*) TESTED=yes;; esac
    ior=$(/usr/sbin/ioreg -r -c NMXAccel -d 1 -w0 2>/dev/null)
    from=$(printf '%s\n' "$ior" | /usr/bin/awk -F'= ' '/"NMXMetalPluginFrom"/{gsub(/"/, "", $2); print $2; exit}')
    if [ -z "$ior" ]; then cf "NMXAccel yüklü değil: kext bu macOS'ta yüklenmedi"
    elif [ -z "$from" ]; then cf "bu NMXAccel /System/Library/Extensions'ı yoklamıyor (NMXMetalPluginFrom yok)"
    else co "NMXAccel yüklü (eklenti şu an: $from)"; fi
    ws=$(ssvw_ws_metal)
    if [ "${ws:-0}" -gt 0 ]; then co "masaüstü Metal bu build'de çalışıyor (WindowServer'ın $ws B580 Metal istemcisi var)"
    else cf "WindowServer'ın B580 Metal aygıtı yok: eklenti bu build'de masaüstünde de çalışmıyor"; fi
    [ -d "$SSVW_LIBCOPY" ] && co "/Library yedeği NVMTLDriverLib.bundle yerinde" || cw "/Library/GPUBundles/NVMTLDriverLib.bundle yok: sistem kopyası giderse yedek yok"
    sb=""; while IFS= read -r f; do [ -n "$f" ] && [ -f "$f" ] && { sb=$f; break; }; done <<EOF
$SSVW_WKSB_LIST
EOF
    if [ -z "$sb" ]; then cw "WebKit GPU süreci sandbox profili bulunamadı: denetlenemedi"
    elif /usr/bin/perl -0777 -ne 'my $ok = 0; while (/\(allow\s+file-map-executable\b((?:[^()]++|\((?1)\))*)\)/g) { $ok = 1 if $1 =~ m{"/System/Library/Extensions"} } exit($ok ? 0 : 1)' "$sb"
    then co "Safari'nin GPU süreci /System/Library/Extensions'tan kod yükleyebiliyor"
    else cf "Safari'nin GPU süreci sandbox'ı artık /System/Library/Extensions'tan kod yüklemeye izin vermiyor: bileşen Safari'ye yaramaz"; fi
    [ -z "$COMPAT_FAIL" ]
}
