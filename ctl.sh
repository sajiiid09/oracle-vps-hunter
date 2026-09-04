#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Control the hunter:  ./ctl.sh start | stop | status | log
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
[ -f ./config.env ] || { echo "config.env missing — run ./setup.sh first." >&2; exit 1; }
source ./config.env

PIDFILE="$DIR/.hunt.pid"
CAFFPID="$DIR/.caffeinate.pid"
LOG="$DIR/logs/hunt.log"
STATE="$DIR/logs/state"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

case "${1:-}" in

start)
  if alive "$PIDFILE"; then
    echo "Already running (pid $(cat "$PIDFILE")). Two loops would double the API rate and get you throttled."
    exit 1
  fi
  [ -f "$DIR/resolved.env" ] || { echo "Run ./setup.sh first."; exit 1; }
  rm -f "$PIDFILE" "$CAFFPID"
  mkdir -p "$DIR/logs"

  # caffeinate -i blocks idle sleep, -s blocks system sleep while on AC power.
  # Closing the lid on battery still sleeps the Mac and pauses the hunt.
  # hunt.sh already tees every line into $LOG; sending its stdout there too
  # would duplicate every entry. Crash output lands in nohup.err instead.
  nohup caffeinate -is "$DIR/hunt.sh" >> "$DIR/logs/nohup.err" 2>&1 &
  echo $! > "$CAFFPID"

  for _ in $(seq 1 20); do alive "$PIDFILE" && break; sleep 0.5; done
  if alive "$PIDFILE"; then
    echo "Hunting.  pid $(cat "$PIDFILE")  ·  ${OCPUS} OCPU / ${MEMORY_GB} GB / ${BOOT_VOLUME_GB} GB"
    echo "Watch it:  ./ctl.sh log     Stop it:  ./ctl.sh stop"
    echo "Leave the Mac plugged in and the lid open."
  else
    echo "Failed to start. Last lines of logs/nohup.err:"
    tail -20 "$DIR/logs/nohup.err"
    exit 1
  fi
  ;;

stop)
  stopped=0
  if alive "$PIDFILE"; then kill "$(cat "$PIDFILE")" 2>/dev/null && stopped=1; fi
  if alive "$CAFFPID"; then kill "$(cat "$CAFFPID")" 2>/dev/null && stopped=1; fi
  sleep 1
  # Anything that ignored SIGTERM gets SIGKILL.
  for f in "$PIDFILE" "$CAFFPID"; do alive "$f" && kill -9 "$(cat "$f")" 2>/dev/null; done
  rm -f "$PIDFILE" "$CAFFPID"
  if [ "$stopped" = 1 ]; then echo "Stopped."; else echo "Was not running."; fi
  pgrep -fl 'hunt\.sh' || true
  ;;

status)
  if alive "$PIDFILE"; then
    pid="$(cat "$PIDFILE")"
    echo "RUNNING   pid $pid   up $(ps -o etime= -p "$pid" | tr -d ' ')"
  else
    echo "STOPPED"
  fi
  echo "target    ${OCPUS} OCPU / ${MEMORY_GB} GB RAM / ${BOOT_VOLUME_GB} GB boot"
  echo "attempts  $(cat "$STATE" 2>/dev/null || echo 0)"
  if [ -f "$DIR/SUCCESS.txt" ]; then
    echo
    echo "--- SUCCESS.txt ---"
    cat "$DIR/SUCCESS.txt"
  elif [ -f "$LOG" ]; then
    echo
    echo "--- last 5 log lines ---"
    tail -5 "$LOG"
  fi
  ;;

log)
  [ -f "$LOG" ] || { echo "No log yet."; exit 1; }
  tail -f "$LOG"
  ;;

*)
  echo "usage: ./ctl.sh {start|stop|status|log}"
  exit 2
  ;;
esac
