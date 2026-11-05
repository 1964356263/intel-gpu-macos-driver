#!/bin/sh
# SPDX-License-Identifier: MIT
# deqp-vk shard runner for the hackintosh (plain sh; no dev tools).
# usage: nohup ./run.sh g1_basic g2_memory ... > results/nohup.out 2>&1 &
# Layout (BASE=$HOME/vk-cts):
#   deqp-vk, vulkan/ (archive data), caselists/<group>/sNNN.txt
#   results/<group>/sNNN.aK.qpa   one qpa per (re)start of a shard
#   results/<group>/events.txt    CRASH/TIMEOUT/HEALTH lines (case names)
#   results/run.log               everything the runner did
# Safety:
#   - watchdog (2 s): java or geekbench running -> kill -9 deqp-vk, write ABORT, stop.
#   - no qpa progress for HANG_S s -> kill -9, TIMEOUT event, stop the run.
#   - debug.intelxe.stats bans / GT resets change, new Kernel*.panic -> HEALTH event, stop the run.
#   - touch $BASE/STOP to stop after killing the current deqp-vk.
BASE=$HOME/vk-cts
DEQP=$BASE/deqp-vk
RES=$BASE/results
LOG=$RES/run.log
HANG_S=${HANG_S:-60}
LIB=/usr/local/lib/libvulkan.1.dylib
mkdir -p "$RES"
cd "$BASE" || exit 1
rm -f "$BASE/ABORT" "$BASE/STOP"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
stat_bans()   { sysctl -n debug.intelxe.stats 2>/dev/null | sed -n 's/.* bans \([0-9]*\).*/\1/p' | head -1; }
stat_resets() { sysctl -n debug.intelxe.stats 2>/dev/null | sed -n 's/.*GT resets \([0-9]*\).*/\1/p' | head -1; }
panics()      { ls /Library/Logs/DiagnosticReports/ 2>/dev/null | grep -c -i 'kernel.*panic'; }
gpurestarts() { ls /Library/Logs/DiagnosticReports/ 2>/dev/null | grep -c 'gpuRestart'; }
# busy = any java, any geekbench_avx2 worker, or the Geekbench GUI above 20% CPU.
# An idle Geekbench GUI does not block (coordinator rule update, 2026-10-29).
games() {
  pgrep -l java
  pgrep -l geekbench_avx2
  for p in $(pgrep -i geekbench); do
    c=$(ps -o %cpu= -p $p 2>/dev/null | tr -d ' '); c=${c%%.*}; [ -z "$c" ] && c=0
    [ "$c" -gt 20 ] && echo "$p geekbench busy ${c}%"
  done
}
fsize()       { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
lastcase()    { grep '^#beginTestCaseResult' "$1" 2>/dev/null | tail -1 | awk '{print $2}'; }

B0=$(stat_bans); R0=$(stat_resets); P0=$(panics); G0=$(gpurestarts)
log "START groups: $* ; bans=$B0 resets=$R0 panics=$P0 gpuRestart=$G0 hang=${HANG_S}s"

if [ -n "$(games)" ]; then
  log "ABORT: java/geekbench running before start: $(games | tr '\n' ' ')"
  touch "$BASE/ABORT"; exit 2
fi

# run one deqp-vk process; sets RC_KIND to ok|crash|timeout|abort|health|stop
run_deqp() {  # $1 caselist  $2 qpa  $3 events
  "$DEQP" --deqp-caselist-file="$1" --deqp-log-filename="$2" \
     --deqp-vk-library-path="$LIB" --deqp-archive-dir="$BASE" \
     --deqp-log-images=disable --deqp-log-shader-sources=disable \
     --deqp-shadercache-filename="$BASE/shadercache.bin" --deqp-shadercache-truncate=disable \
     > "$2.stdout" 2>&1 &
  PID=$!
  last_sz=0; still=0; RC_KIND=ok
  while kill -0 $PID 2>/dev/null; do
    sleep 2
    if [ -n "$(games)" ]; then
      kill -9 $PID 2>/dev/null; pkill -9 deqp-vk
      log "WATCHDOG: java/geekbench detected ($(games | tr '\n' ' ')) - deqp-vk killed; current case $(lastcase "$2")"
      echo "ABORT $(lastcase "$2")" >> "$3"; touch "$BASE/ABORT"; RC_KIND=abort; return
    fi
    if [ -f "$BASE/STOP" ]; then
      kill -9 $PID 2>/dev/null; log "STOP file - deqp-vk killed at $(lastcase "$2")"; RC_KIND=stop; return
    fi
    b=$(stat_bans); r=$(stat_resets)
    if [ "$b" != "$B0" ] || [ "$r" != "$R0" ]; then
      log "HEALTH: bans $B0->$b GT resets $R0->$r during $(lastcase "$2")"
      echo "HEALTH bans=$B0->$b resets=$R0->$r $(lastcase "$2")" >> "$3"
      B0=$b; R0=$r
      sleep 3; kill -9 $PID 2>/dev/null; RC_KIND=health; return
    fi
    sz=$(fsize "$2")
    if [ "$sz" = "$last_sz" ]; then still=$((still+2)); else still=0; last_sz=$sz; fi
    if [ $still -ge $HANG_S ]; then
      c=$(lastcase "$2")
      lm=$(grep -E '^#(begin|end|terminate)TestCaseResult' "$2" 2>/dev/null | tail -1 | awk '{print $1}')
      kill -9 $PID 2>/dev/null
      if [ "$lm" = "#beginTestCaseResult" ]; then tag=TIMEOUT; else tag=TIMEOUT_AFTER; fi
      log "$tag: no progress for ${HANG_S}s (last case $c, last marker $lm) - kill -9"
      echo "$tag $c" >> "$3"; RC_KIND=timeout
      sleep 3; st=$(ps -o pid=,stat=,time= -p $PID 2>/dev/null)
      log "after kill -9: ${st:-gone}"
      if [ -n "$st" ]; then sleep 10; st=$(ps -o pid=,stat=,time= -p $PID 2>/dev/null); fi
      if [ -n "$st" ]; then log "UNKILLABLE deqp-vk: $st"; echo "UNKILLABLE $c" >> "$3"; RC_KIND=stuck; fi
      return
    fi
  done
  wait $PID; RC=$?
  # crashed if the last marker is a begin without end
  lm=$(grep -E '^#(begin|end|terminate)TestCaseResult' "$2" 2>/dev/null | tail -1 | awk '{print $1}')
  if [ "$lm" = "#beginTestCaseResult" ]; then
    c=$(lastcase "$2"); echo "CRASH rc=$RC $c" >> "$3"; log "CRASH rc=$RC in $c"; RC_KIND=crash
  elif [ $RC -ne 0 ] && [ -z "$lm" ]; then
    log "deqp-vk rc=$RC before any case (see $2.stdout)"; RC_KIND=nostart
  fi
}

for g in "$@"; do
  [ -d "$BASE/caselists/$g" ] || { log "no caselists for $g"; continue; }
  mkdir -p "$RES/$g"; EV=$RES/$g/events.txt; touch "$EV"
  gstart=$(date +%s); log "GROUP $g begin"
  ncrash=0
  for cl in "$BASE"/caselists/$g/s*.txt; do
    s=$(basename "$cl" .txt)
    rem=$RES/$g/$s.remaining; cp "$cl" "$rem"; a=0
    while [ -s "$rem" ]; do
      qpa=$RES/$g/$s.a$a.qpa
      t0=$(date +%s)
      run_deqp "$rem" "$qpa" "$EV"
      log "$g/$s.a$a: $(grep -c '^#endTestCaseResult' "$qpa" 2>/dev/null) cases in $(( $(date +%s) - t0 ))s kind=$RC_KIND"
      case $RC_KIND in
        abort|stop) log "END (run stopped: $RC_KIND)"; exit 3 ;;
        health|stuck) log "STOP RUN after $RC_KIND in $g/$s (caller decides what is safe next)"; echo "$(date) $RC_KIND $g/$s" > "$BASE/STOPPED"; exit 4 ;;
        timeout) log "GROUP $g stopped after timeout in $g/$s (process killed); next group"; break 2 ;;
        nostart) log "shard $g/$s could not start; skipping it"; break ;;
      esac
      # drop the cases this attempt started (passed, failed or crashed)
      grep '^#beginTestCaseResult' "$qpa" | awk '{print $2}' > "$rem.done"
      awk 'NR==FNR{d[$1]=1;next} !($1 in d)' "$rem.done" "$rem" > "$rem.new"; mv "$rem.new" "$rem"
      if [ "$RC_KIND" = crash ]; then
        ncrash=$((ncrash+1))
        if [ $ncrash -ge 300 ]; then log "GROUP $g: 300 crashes - group stopped"; break 2; fi
      fi
      a=$((a+1))
      if [ $a -ge 300 ]; then log "$g/$s: too many restarts"; break; fi
    done
    p=$(panics); gr=$(gpurestarts)
    if [ "$p" != "$P0" ]; then log "HEALTH: new kernel panic report ($P0->$p)"; echo "HEALTH panic" >> "$EV"; exit 4; fi
    if [ "$gr" != "$G0" ]; then log "HEALTH: new gpuRestart report ($G0->$gr) after $g/$s"; echo "HEALTH gpuRestart $g/$s" >> "$EV"; G0=$gr; echo "$(date) gpuRestart $g/$s" > "$BASE/STOPPED"; exit 4; fi
  done
  log "GROUP $g end in $(( $(date +%s) - gstart ))s; status: $(cat "$RES"/$g/*.qpa 2>/dev/null | grep -o 'StatusCode="[A-Za-z]*"' | sort | uniq -c | tr '\n' ' ')"
done
log "ALL DONE"
touch "$BASE/DONE"
