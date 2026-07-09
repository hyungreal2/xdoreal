#!/usr/bin/env bash
# Terminal maintenance/diagnostics for the terminals in $SELECTED_FILE:
# probe whether each one's shell is actually responsive (not just whether
# its X window still exists — that's check_windows_exist, run as a
# pre-flight here too), clear its scrollback, or send it a Ctrl+C to
# interrupt whatever's running in the foreground.
#
# Deliberately its own script, not a flag bolted onto run_env.sh/run_cmd.sh:
# those two run user-supplied setup/benchmark commands *inside* the shell;
# this one acts *on* the terminal/session itself, and one of its actions
# (-a interrupt) isn't even a typed command at all, just a raw Ctrl+C key
# event — a different enough operating model to not squeeze into either of
# the "-c <command>" scripts.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ACTION=""
CHECK_TIMEOUT=5
INJECT_METHOD="${INJECT_METHOD:-type}"

usage() {
  cat <<EOF
Usage: $0 -a check|clear|interrupt [-w <sec>] [-I type|clip]

  -a ACTION   check     - probe each terminal for a live, responsive shell;
                          one that doesn't answer within -w seconds is
                          reported as NO RESPONSE (window exists, but
                          whatever's inside it isn't reading input — e.g.
                          blocked on a stale NFS mount, or a runaway
                          foreground process)
              clear     - send the "clear" command (scrollback/screen reset)
              interrupt - send Ctrl+C, to cancel whatever's running in the
                          foreground. Best-effort: won't unstick a shell
                          blocked in an uninterruptible syscall (e.g. a hard
                          NFS mount that's gone away) — SIGINT can't touch
                          that either way; only the mount coming back, or
                          killing/respawning the terminal, will.
  -w SECONDS  Liveness probe timeout, -a check only (default: 5)
  -I METHOD   Injection method: type (char-by-char typing, default) | clip
              (clipboard+paste, needs xclip). Only used by check/clear —
              interrupt is always a raw key event.

Reads targets from \$SELECTED_FILE (see select_hosts.sh) — run that first.
EOF
  exit 1
}

while getopts "a:w:I:h" opt; do
  case "$opt" in
    a) ACTION="$OPTARG" ;;
    w) CHECK_TIMEOUT="$OPTARG" ;;
    I) INJECT_METHOD="$OPTARG" ;;
    *) usage ;;
  esac
done

case "$ACTION" in
  check|clear|interrupt) ;;
  *) usage ;;
esac

if [ "$ACTION" != "interrupt" ]; then
  case "$INJECT_METHOD" in
    type) ;;
    clip) command -v xclip >/dev/null 2>&1 || { log "ERROR: -I clip requires xclip (sudo dnf install xclip)"; exit 1; } ;;
    *) log "ERROR: -I must be type or clip"; exit 1 ;;
  esac
fi

require_selection_file || exit 1
mapfile -t TARGET_IDS < <(load_selected_hosts)

log "target count=${#TARGET_IDS[@]}, action=$ACTION"

# Same pre-flight guard as run_env.sh/run_cmd.sh: fail up front, before
# sending anything, if a selected terminal's window has disappeared.
check_windows_exist TARGET_IDS || { log "ERROR: one or more selected terminals not found — aborting"; exit 1; }

case "$ACTION" in
  interrupt)
    for id in "${TARGET_IDS[@]}"; do
      wid="$(find_window_id "$id")"
      if ! xdotool key --window "$wid" ctrl+c; then
        log "WARN: interrupt failed for $id, skipping"
        continue
      fi
      log "sent Ctrl+C to $id (wid=$wid)"
    done
    ;;

  clear)
    for id in "${TARGET_IDS[@]}"; do
      wid="$(find_window_id "$id")"
      if ! inject_command "$INJECT_METHOD" "$wid" "clear"; then
        log "WARN: clear failed for $id, skipping"
        continue
      fi
      log "cleared $id (wid=$wid)"
    done
    ;;

  check)
    JOBID="$(date +%Y%m%d-%H%M%S)-$$"
    PROBE_D="$NAS_ROOT/status/_check/$JOBID"
    mkdir_shared "$PROBE_D"

    for id in "${TARGET_IDS[@]}"; do
      wid="$(find_window_id "$id")"
      if ! inject_command "$INJECT_METHOD" "$wid" "echo alive > $PROBE_D/${id}.alive"; then
        log "WARN: probe injection failed for $id, skipping"
        continue
      fi
    done

    log "waiting up to ${CHECK_TIMEOUT}s for responses"
    elapsed=0
    while (( elapsed < CHECK_TIMEOUT )); do
      done_count=$(find "$PROBE_D" -maxdepth 1 -name '*.alive' | wc -l)
      (( done_count >= ${#TARGET_IDS[@]} )) && break
      sleep 1
      elapsed=$((elapsed + 1))
    done

    RESPONSIVE=0
    for id in "${TARGET_IDS[@]}"; do
      if [ -f "$PROBE_D/${id}.alive" ]; then
        log "RESPONSIVE: $id"
        RESPONSIVE=$((RESPONSIVE + 1))
      else
        log "NO RESPONSE: $id"
      fi
    done
    log "responsive: $RESPONSIVE/${#TARGET_IDS[@]}"
    ;;
esac
