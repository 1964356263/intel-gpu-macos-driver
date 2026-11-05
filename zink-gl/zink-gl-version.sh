#!/bin/bash
# zink-gl-version.sh <version> [game dir] [--write]
# Makes a launcher version "<version>-zink" that inherits <version> (the standard "inheritsFrom" mechanism Fabric and
# OptiFine profiles use) and only adds the two Java arguments that send LWJGL's GLFW and OpenGL to /Library/IntelXe/GL.
# The original version, its jar and the launcher's global Java arguments stay untouched: pick "<version>-zink" in the
# launcher to play with zink, "<version>" for Apple's OpenGL. Minecraft 1.13 and newer (the "arguments" JSON format,
# LWJGL 3 + GLFW). Without --write it only prints what it would write.
#   game dir: default ~/Library/Application Support/minecraft
#   remove:   delete <game dir>/versions/<version>-zink
set -euo pipefail
V=${1:?usage: zink-gl-version.sh <version> [game dir] [--write]}
D="$HOME/Library/Application Support/minecraft"; W=0
shift; for a in "$@"; do if [ "$a" = --write ]; then W=1; else D=$a; fi; done
L=/Library/IntelXe/GL
P="$D/versions/$V/$V.json"
[ -f "$P" ] || { echo "no $P: start $V once from the launcher first (it downloads it)"; exit 1; }
for f in libglfw.3.dylib libGLzink.dylib libEGL.1.dylib; do [ -f "$L/$f" ] || echo "warning: $L/$f is missing (install.sh not run yet)"; done
get() { /usr/bin/plutil -extract "$1" raw -o - "$P" 2>/dev/null || true; }
MC=$(get mainClass); TY=$(get type); TI=$(get time); RT=$(get releaseTime)
[ -n "$MC" ] || { echo "$P has no mainClass"; exit 1; }
/usr/bin/plutil -extract arguments.jvm json -o - "$P" >/dev/null 2>&1 || { echo "$V uses the old argument format (before 1.13): not supported"; exit 1; }
N="$V-zink"; O="$D/versions/$N/$N.json"
J=$(cat <<EOF
{
  "id": "$N",
  "inheritsFrom": "$V",
  "jar": "$V",
  "type": "${TY:-release}",
  "time": "$TI",
  "releaseTime": "$RT",
  "mainClass": "$MC",
  "arguments": {
    "game": [],
    "jvm": [
      "-Dorg.lwjgl.glfw.libname=$L/libglfw.3.dylib",
      "-Dorg.lwjgl.opengl.libname=$L/libGLzink.dylib"
    ]
  }
}
EOF
)
if [ $W = 0 ]; then echo "would write $O:"; echo "$J"; echo "(run again with --write to write it)"; exit 0; fi
[ ! -e "$O" ] || cp "$O" "$O.before-$(date +%Y%m%d%H%M%S)"
mkdir -p "$(dirname "$O")"; printf '%s\n' "$J" > "$O"
[ "$(/usr/bin/plutil -extract id raw -o - "$O")" = "$N" ] && echo "wrote $O: choose \"$N\" in the launcher"
