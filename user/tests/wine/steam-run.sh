#!/bin/sh
# SPDX-License-Identifier: MIT
# steam-run.sh [logfile] [extra steam args...]: (re)starts Windows Steam in the user's prefix ($INTELXE_HOME/wine/prefix).
# Run it from Terminal or through WineRun.app (the GUI session). WINEDEBUG comes from the environment (default -all).
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
cd "$INTELXE_HOME/wine" || exit 1
export WINEPREFIX="$INTELXE_HOME/wine/prefix"
LOG=${1:-$INTELXE_HOME/wine/steam/steam-run.log}; [ $# -gt 0 ] && shift
./wenv.sh wineserver -k 2>/dev/null; ./wenv.sh wineserver -w 2>/dev/null
exec ./wenv.sh wine "C:\\Program Files (x86)\\Steam\\steam.exe" ${STEAM_FLAGS:--cef-disable-gpu -cef-disable-gpu-compositing -no-cef-sandbox} "$@" > "$LOG" 2>&1
