#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh (zink-gl): OpenGL through Mesa's zink on the Intel Arc B580, for applications that open their OpenGL
# context through GLFW / EGL (LWJGL 3 games such as Minecraft Java). Apple's OpenGL, Mesa ANV and the kexts are not
# touched; nothing here is loaded by a process that does not ask for these libraries.
#
#   sudo ./install.sh              install (backs up what it replaces to ./previous/, once)
#   sudo ./install.sh --undo       put back what was there before
#   ./install.sh --test            offscreen self-test (EGL pbuffer, GL core through zink on the B580, ~1 s)
#   sudo ./install.sh --global on  every LWJGL 3 application of every user uses zink (JAVA_TOOL_OPTIONS, set by a
#                                  LaunchAgent at login; applies to applications started after the next login, or
#                                  right away for the logged-in user)
#   sudo ./install.sh --global off back to Apple's OpenGL for them
#   ./install.sh --status
#
# Installs:
#   /Library/IntelXe/GL/                   libEGL (Mesa EGL, macOS platform), libgallium (zink), libGLzink (LWJGL's
#                                          OpenGL library), libglfw.3 (GLFW 3.4 + the zink EGL patch)
#   /usr/local/lib/libvulkan.1.4.363.dylib the Khronos Vulkan loader (+ libvulkan.1.dylib, libvulkan.dylib links),
#                                          which zink and ordinary Vulkan applications use to find the B580
#   /usr/local/share/vulkan/icd.d/intel_icd.x86_64.json  -> /Library/GPUBundles/nvmtl/libvulkan_intel.dylib
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
B=$H/previous
GL=/Library/IntelXe/GL
VL=/usr/local/lib VLIB=libvulkan.1.4.363.dylib
ICDD=/usr/local/share/vulkan/icd.d ICD=intel_icd.x86_64.json
LA=/Library/LaunchAgents/io.github.yusufklncc.intelxe.zink-gl.plist
LIBS="libEGL.1.dylib libgallium-27.0.0-devel.dylib libGLzink.dylib libglfw.3.dylib"
JOPTS="-Dorg.lwjgl.glfw.libname=$GL/libglfw.3.dylib -Dorg.lwjgl.opengl.libname=$GL/libGLzink.dylib"

root() { [ "$(id -u)" = 0 ] || { echo "needs root: sudo $0 $*"; exit 1; }; }
sums() { (cd "$H" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "REFUSED: files differ from SHA256SUMS"; exit 1; }; }
sig() { "$H/sigcheck" "$1" >/dev/null || { "$H/sigcheck" "$1"; echo "REFUSED: $1 is not signed"; exit 1; }; }
console_user() { stat -f %Su /dev/console 2>/dev/null || true; }

status() {
    echo "zink-gl:"
    [ -d $GL ] && echo "  $GL: $(cd $GL && ls *.dylib | tr '\n' ' ')" || echo "  $GL: not installed"
    [ -e $VL/$VLIB ] && echo "  Vulkan loader: $VL/$VLIB" || echo "  Vulkan loader: not installed"
    [ -e $ICDD/$ICD ] && echo "  ICD: $ICDD/$ICD -> $(sed -n 's/.*"library_path": *"\([^"]*\)".*/\1/p' $ICDD/$ICD)" || echo "  ICD: none"
    if [ -e $LA ]; then echo "  global: on ($LA)"; else echo "  global: off"; fi
    local u; u=$(console_user)
    if [ -n "$u" ] && [ "$u" != root ]; then
        if [ "$(id -u)" = 0 ]; then echo "  JAVA_TOOL_OPTIONS for $u: $(launchctl asuser "$(id -u "$u")" launchctl getenv JAVA_TOOL_OPTIONS 2>/dev/null || true)"
        else echo "  JAVA_TOOL_OPTIONS for $u: (sudo $0 --status shows it)"; fi
    fi
    echo "  surfvram: $(sysctl -n debug.intelxe.surfvram 2>/dev/null || echo '?') (2 = no present copy)"
}

global() {
    root "--global $1"
    local u; u=$(console_user)
    case "$1" in
    on)
        [ -d $GL ] || { echo "install first: sudo $0"; exit 1; }
        cat > $LA.new <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>io.github.yusufklncc.intelxe.zink-gl</string>
	<key>ProgramArguments</key>
	<array><string>/bin/launchctl</string><string>setenv</string><string>JAVA_TOOL_OPTIONS</string><string>$JOPTS</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
        chown root:wheel $LA.new; chmod 644 $LA.new; mv $LA.new $LA
        if [ -n "$u" ] && [ "$u" != root ]; then
            launchctl asuser "$(id -u "$u")" launchctl setenv JAVA_TOOL_OPTIONS "$JOPTS"
            echo "on: LWJGL 3 applications started from now on by $u (and by every user after login) use zink."
        else echo "on: from the next login."; fi
        echo "Applications started before this keep Apple's OpenGL until they are restarted." ;;
    off)
        rm -f $LA
        if [ -n "$u" ] && [ "$u" != root ]; then launchctl asuser "$(id -u "$u")" launchctl unsetenv JAVA_TOOL_OPTIONS; fi
        echo "off: LWJGL applications started from now on use Apple's OpenGL." ;;
    *) echo "usage: $0 --global on|off"; exit 2 ;;
    esac
}

# place SRC DST: replace DST (file or directory) with a root-owned copy of SRC
place() { rm -rf "$2.new"; ditto "$1" "$2.new"; chown -R root:wheel "$2.new"; chmod -R go-w "$2.new"; rm -rf "$2"; mv "$2.new" "$2"; }

install_all() {
    root
    sums
    [ -f /Library/GPUBundles/nvmtl/libvulkan_intel.dylib ] || { echo "REFUSED: the driver is not installed (no /Library/GPUBundles/nvmtl/libvulkan_intel.dylib)"; exit 1; }
    local f; for f in $LIBS; do sig "$H/lib/$f"; done; sig "$H/vulkan/$VLIB"
    if [ ! -d "$B" ]; then
        mkdir -p "$B"
        if [ -d $GL ]; then ditto $GL "$B/GL"; else touch "$B/no-GL"; fi
        if [ -e $VL/$VLIB ]; then cp -p $VL/$VLIB "$B/$VLIB"; else touch "$B/no-loader"; fi
        if [ -e $ICDD/$ICD ]; then cp -p $ICDD/$ICD "$B/$ICD"; else touch "$B/no-icd"; fi
        echo "backup: $B"
    fi
    mkdir -p /Library/IntelXe "$H/.stage"
    rm -rf "$H/.stage/GL"; mkdir "$H/.stage/GL"
    for f in $LIBS; do cp "$H/lib/$f" "$H/.stage/GL/"; done
    ln -s libEGL.1.dylib "$H/.stage/GL/libEGL.dylib"
    place "$H/.stage/GL" $GL; rm -rf "$H/.stage"
    mkdir -p $VL $ICDD
    install -o root -g wheel -m 755 "$H/vulkan/$VLIB" $VL/$VLIB
    ln -sf $VLIB $VL/libvulkan.1.dylib; ln -sf libvulkan.1.dylib $VL/libvulkan.dylib
    install -o root -g wheel -m 644 "$H/vulkan/icd.d/$ICD" $ICDD/$ICD
    status
    echo "installed. Try: $0 --test; then sudo $0 --global on (all LWJGL 3 apps) or ./zink-gl-version.sh (one game)."
}

undo() {
    root
    [ -d "$B" ] || { echo "nothing to undo (not installed from this folder)"; exit 1; }
    [ -e $LA ] && global off
    if [ -d "$B/GL" ]; then place "$B/GL" $GL; else rm -rf $GL; rmdir /Library/IntelXe 2>/dev/null || true; fi
    if [ -e "$B/$VLIB" ]; then install -o root -g wheel -m 755 "$B/$VLIB" $VL/$VLIB
    else rm -f $VL/$VLIB $VL/libvulkan.1.dylib $VL/libvulkan.dylib; fi
    if [ -e "$B/$ICD" ]; then install -o root -g wheel -m 644 "$B/$ICD" $ICDD/$ICD; else rm -f $ICDD/$ICD; fi
    rm -rf "$B"
    status
}

case "${1:-}" in
    "") install_all ;;
    --undo) undo ;;
    --test) sums; exec /usr/bin/perl -e 'alarm shift; exec @ARGV' 30 "$H/bin/zink-gl-selftest" 200 native ;;
    --global) global "${2:-}" ;;
    --status) status ;;
    *) sed -n '5,13p' "$0"; exit 2 ;;
esac
