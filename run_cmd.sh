#!/usr/bin/env bash
# Master: runs a benchmarked command on the terminals selected by
# select_hosts.sh, at the same target time, and collects each terminal's
# execution time via the NAS.
#
# Targets always come from $SELECTED_FILE (see select_hosts.sh) — this script
# has no -n/-H of its own, so the same selection stays fixed across repeated
# runs until select_hosts.sh is run again. Environment/setup commands
# (setenv, source, newgrp, etc.) are run_env.sh's job, not this script's —
# see its header for why those are handled completely separately.
#
# How simultaneity is achieved:
#   1) Each target terminal first gets a "wait until the START file exists" command.
#   2) At the target time, the master touches one START file; every waiting
#      terminal starts within BARRIER_POLL's polling interval of each other.
#   This keeps actual start times aligned even if the xdotool injection itself
#   takes a while sequentially.
#
# Completion is detected via polling rather than inotify: since the NAS is
# shared across different hosts' NFS clients, there's no guarantee that a file
# created by one host is immediately visible via the master's local inotify.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

BENCH_CMD=""
TARGET_TIME="now"
WAIT_TIMEOUT=3600
POLL_INTERVAL=1
INJECT_METHOD="${INJECT_METHOD:-type}"

usage() {
  cat <<EOF
Usage: $0 -c "<command>" [-t "<time>"] [-w <sec>] [-p <sec>] [-I type|clip]

  -c CMD      Benchmarked command: run as a child csh process, timed, with
              exit code and elapsed seconds collected (required)
  -t TIME     Target start time. "now" or anything date -d can parse (default: now)
              e.g. -t "16:30:00"  -t "2026-07-04 23:00:00"  -t "+5 minutes"
  -w SECONDS  Max time to wait for completion (default: 3600)
  -p SECONDS  Completion poll interval (default: 1)
  -I METHOD   Injection method: type (char-by-char typing, default) | clip
              (clipboard+paste, needs xclip). clip is much faster for large n.

Reads targets from \$SELECTED_FILE (see select_hosts.sh) — run that first.
EOF
  exit 1
}

while getopts "c:t:w:p:I:h" opt; do
  case "$opt" in
    c) BENCH_CMD="$OPTARG" ;;
    t) TARGET_TIME="$OPTARG" ;;
    w) WAIT_TIMEOUT="$OPTARG" ;;
    p) POLL_INTERVAL="$OPTARG" ;;
    I) INJECT_METHOD="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -z "$BENCH_CMD" ] && usage

case "$INJECT_METHOD" in
  type) ;;
  clip) command -v xclip >/dev/null 2>&1 || { log "ERROR: -I clip requires xclip (sudo dnf install xclip)"; exit 1; } ;;
  *) log "ERROR: -I must be type or clip"; exit 1 ;;
esac

require_selection_file || exit 1
mapfile -t TARGET_IDS < <(load_selected_hosts)

# Fail up front, before touching the NAS or sending anything, if a selected
# terminal has disappeared (closed, crashed, host rebooted) rather than
# silently dispatching to whatever subset still exists.
check_windows_exist TARGET_IDS || { log "ERROR: one or more selected terminals not found — aborting"; exit 1; }

# Every selected terminal writes its own .time/.rc/.done into these
# directories, and each one polls $BARRIER_FILE for existence — potentially
# as a different login user on a different host than whoever runs this
# script. mkdir_shared (common.sh) makes sure that works regardless of
# whoever's umask created them — see its comment for why a restrictive one
# can otherwise make a terminal look permanently stuck at "csh <script>".
JOBID="$(date +%Y%m%d-%H%M%S)-$$"
RESULTS_D="$(RESULTS_DIR "$JOBID")"
STATUS_D="$(STATUS_DIR "$JOBID")"
mkdir_shared "$RESULTS_D" "$STATUS_D"
umask 000
BARRIER_FILE="$STATUS_D/START"

log "JOBID=$JOBID target count=${#TARGET_IDS[@]}"
printf '%s\n' "${TARGET_IDS[@]}" > "$STATUS_D/targets.list"

FAILED_IDS=()

for id in "${TARGET_IDS[@]}"; do
  wid="$(find_window_id "$id")"
  if [ -z "$wid" ]; then
    log "WARN: couldn't find terminal window for $id, skipping"
    FAILED_IDS+=("$id")
    continue
  fi

  cmd="$(build_cmd_script "$BARRIER_FILE" "$BENCH_CMD" "$RESULTS_D/${id}.time" "$RESULTS_D/${id}.rc" "$STATUS_D/${id}.done" "$STATUS_D/${id}.script")"

  # Guarded rather than a bare call: under `set -e`, an unwrapped failing
  # command aborts the whole script immediately, so one bad terminal would
  # silently strand every id still left in the loop, including the barrier
  # touch and completion wait below. Wrapping it as an `if` condition is
  # exempt from that, so a single failure here is just recorded and the loop
  # moves on to the rest.
  if ! inject_command "$INJECT_METHOD" "$wid" "$cmd"; then
    log "WARN: injection failed for $id, skipping"
    FAILED_IDS+=("$id")
    continue
  fi
  log "injected command for $id (wid=$wid, method=$INJECT_METHOD)"
done

if [ "$TARGET_TIME" = "now" ]; then
  sleep_secs=0
else
  target_epoch=$(date -d "$TARGET_TIME" +%s)
  now_epoch=$(date +%s)
  sleep_secs=$(( target_epoch - now_epoch ))
  if (( sleep_secs < 0 )); then
    log "WARN: target time already passed, starting immediately"
    sleep_secs=0
  fi
fi

log "waiting ${sleep_secs}s until target time, then sending the start signal"
(( sleep_secs > 0 )) && sleep "$sleep_secs"

touch "$BARRIER_FILE"
log "START signal sent, execution begins"

expected=$(( ${#TARGET_IDS[@]} - ${#FAILED_IDS[@]} ))
elapsed=0
while :; do
  done_count=$(find "$STATUS_D" -maxdepth 1 -name '*.done' | wc -l)
  (( done_count >= expected )) && break
  (( elapsed >= WAIT_TIMEOUT )) && { log "WARN: wait timed out (${WAIT_TIMEOUT}s), some targets incomplete"; break; }
  sleep "$POLL_INTERVAL"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

log "collecting results"
SUMMARY="$RESULTS_D/summary.tsv"
: > "$SUMMARY"
for id in "${TARGET_IDS[@]}"; do
  tfile="$RESULTS_D/${id}.time"
  rfile="$RESULTS_D/${id}.rc"
  if [ -f "$tfile" ]; then
    printf '%s\t%s\t%s\n' "$id" "$(cat "$tfile")" "$(cat "$rfile" 2>/dev/null || echo NA)" >> "$SUMMARY"
  else
    printf '%s\tNA\tNA\n' "$id" >> "$SUMMARY"
  fi
done

{ printf 'ID\tTIME(s)\tRC\n'; cat "$SUMMARY"; } | column -t -s $'\t'

awk -F'\t' '$2 != "NA" { s+=$2; n++; if (n==1||$2>mx) mx=$2; if (n==1||$2<mn) mn=$2 }
  END { if (n>0) printf "\nCompleted %d | avg=%.3fs max=%.3fs min=%.3fs\n", n, s/n, mx, mn }' "$SUMMARY"

log "result file: $SUMMARY"
