#!/usr/bin/env bash
# Master: runs a command on n selected X-shared terminals (xterm) at the same
# target time, and collects each terminal's execution time via the NAS.
#
# hosts.list is assumed to hold full window titles, prefix included (see
# gen_hosts_list.sh). find_window_id matches these exactly, so multiple
# windows for the same host are never confused, and there's no need to know
# or pass WINDOW_PREFIX here at all.
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

SETUP_CMD=""
BENCH_CMD=""
N=""
IDS_CSV=""
TARGET_TIME="now"
WAIT_TIMEOUT=3600
POLL_INTERVAL=1
INJECT_METHOD="${INJECT_METHOD:-type}"
SELECTED_FILE="${SELECTED_FILE:-$(dirname "$HOSTS_FILE")/selected.hosts}"
FORCE_RESELECT=0

usage() {
  cat <<EOF
Usage: $0 (-e "<setup>" | -c "<command>" | both) (-n <count> | -H id1,id2,...) [-t "<time>"] [-w <sec>] [-p <sec>] [-I type|clip] [-f file] [-F]

  -e SETUP    Command run as-is, directly in the target shell — no subshell,
              no timing. Use for things like "setenv FOO bar" that must take
              effect in that shell itself. If -c is also given, -e runs first,
              injected as a separate follow-up command so it still works even
              for setup commands that replace the shell process outright
              (newgrp, exec, su, login) rather than just returning.
  -c CMD      Benchmarked command: run in a subshell, timed, with exit code
              and elapsed seconds collected. Runs after -e if both are given.
              At least one of -e/-c is required.
  -n N        Pick N random identifiers (full window titles) from hosts.list.
              The first time -n is used (no existing selection file), the
              chosen N are saved to the selection file (see -f). On later
              runs, if that file exists, its contents are reused as-is
              instead of picking a fresh random N — use -F to force a new
              random pick.
  -H LIST     Explicit comma-separated identifier list (full window titles,
              as stored in hosts.list; overrides -n and the selection file)
  -t TIME     Target start time. "now" or anything date -d can parse (default: now)
              e.g. -t "16:30:00"  -t "2026-07-04 23:00:00"  -t "+5 minutes"
  -w SECONDS  Max time to wait for completion (default: 3600)
  -p SECONDS  Completion poll interval (default: 1)
  -I METHOD   Injection method: type (char-by-char typing, default) | clip
              (clipboard+paste, needs xclip). clip is much faster for large n.
  -f FILE     Selection file path for -n (default: $SELECTED_FILE)
  -F          Force a fresh random -n selection, overwriting the selection file
EOF
  exit 1
}

while getopts "e:c:n:H:t:w:p:I:f:Fh" opt; do
  case "$opt" in
    e) SETUP_CMD="$OPTARG" ;;
    c) BENCH_CMD="$OPTARG" ;;
    n) N="$OPTARG" ;;
    H) IDS_CSV="$OPTARG" ;;
    t) TARGET_TIME="$OPTARG" ;;
    w) WAIT_TIMEOUT="$OPTARG" ;;
    p) POLL_INTERVAL="$OPTARG" ;;
    I) INJECT_METHOD="$OPTARG" ;;
    f) SELECTED_FILE="$OPTARG" ;;
    F) FORCE_RESELECT=1 ;;
    *) usage ;;
  esac
done

[ -z "$N" ] && [ -z "$IDS_CSV" ] && usage
[ -z "$SETUP_CMD" ] && [ -z "$BENCH_CMD" ] && { log "ERROR: at least one of -e or -c is required"; exit 1; }

case "$INJECT_METHOD" in
  type) ;;
  clip) command -v xclip >/dev/null 2>&1 || { log "ERROR: -I clip requires xclip (sudo dnf install xclip)"; exit 1; } ;;
  *) log "ERROR: -I must be type or clip"; exit 1 ;;
esac

if [ -n "$IDS_CSV" ]; then
  IFS=',' read -r -a TARGET_IDS <<< "$IDS_CSV"
elif [ "$FORCE_RESELECT" -eq 0 ] && [ -s "$SELECTED_FILE" ]; then
  mapfile -t TARGET_IDS < "$SELECTED_FILE"
  log "reusing ${#TARGET_IDS[@]} previously selected identifier(s) from $SELECTED_FILE"
else
  mapfile -t TARGET_IDS < <(select_hosts_random "$N")
  printf '%s\n' "${TARGET_IDS[@]}" > "$SELECTED_FILE"
  log "selected ${#TARGET_IDS[@]} random identifier(s), saved to $SELECTED_FILE"
fi

JOBID="$(date +%Y%m%d-%H%M%S)-$$"
RESULTS_D="$(RESULTS_DIR "$JOBID")"
STATUS_D="$(STATUS_DIR "$JOBID")"
mkdir -p "$RESULTS_D" "$STATUS_D"
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

  pre_cmd="$(build_pre_cmd "$BARRIER_FILE" "$SETUP_CMD" "$STATUS_D/${id}.pre.script")"
  post_cmd="$(build_post_cmd "$BENCH_CMD" "$RESULTS_D/${id}.time" "$RESULTS_D/${id}.rc" "$STATUS_D/${id}.done" "$STATUS_D/${id}.post.script")"

  inject_command "$INJECT_METHOD" "$wid" "$pre_cmd"
  inject_command "$INJECT_METHOD" "$wid" "$post_cmd"
  log "injected pre/post commands for $id (wid=$wid, method=$INJECT_METHOD)"
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
