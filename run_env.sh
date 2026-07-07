#!/usr/bin/env bash
# Runs an environment/setup command (setenv, source, newgrp, etc.) directly
# in each selected terminal's already-running shell — no wrapper script, no
# barrier, no simultaneous-start requirement, no timing. The command is typed
# or pasted as-is via xdotool; that's it.
#
# This is deliberately separate from run_cmd.sh: setup commands like these
# either need to persist in the interactive shell (setenv, source) or may
# replace the shell process outright (newgrp, exec, su, login) — neither
# case has anything to do with measuring how long a benchmark takes, or
# starting it at a synchronized time across hosts, so there's no reason to
# route it through run_cmd.sh's barrier/timing machinery at all.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CMD=""
INJECT_METHOD="${INJECT_METHOD:-type}"

usage() {
  cat <<EOF
Usage: $0 -c "<command>" [-I type|clip]

  -c CMD      Command to run as-is in each selected terminal (required)
  -I METHOD   Injection method: type (char-by-char typing, default) | clip
              (clipboard+paste, needs xclip). clip is much faster for large n.

Reads targets from \$SELECTED_FILE (see select_hosts.sh) — run that first.
EOF
  exit 1
}

while getopts "c:I:h" opt; do
  case "$opt" in
    c) CMD="$OPTARG" ;;
    I) INJECT_METHOD="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -z "$CMD" ] && usage

case "$INJECT_METHOD" in
  type) ;;
  clip) command -v xclip >/dev/null 2>&1 || { log "ERROR: -I clip requires xclip (sudo dnf install xclip)"; exit 1; } ;;
  *) log "ERROR: -I must be type or clip"; exit 1 ;;
esac

require_selection_file || exit 1
mapfile -t TARGET_IDS < <(load_selected_hosts)

log "target count=${#TARGET_IDS[@]}"

# Fail up front, before sending anything, if a selected terminal has
# disappeared (closed, crashed, host rebooted) rather than silently sending
# to whatever subset still exists.
check_windows_exist TARGET_IDS || { log "ERROR: one or more selected terminals not found — aborting"; exit 1; }

FAILED=0
for id in "${TARGET_IDS[@]}"; do
  wid="$(find_window_id "$id")"
  if [ -z "$wid" ]; then
    log "WARN: couldn't find terminal window for $id, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Guarded rather than a bare call: under `set -e`, an unwrapped failing
  # command aborts the whole script immediately, so one bad terminal would
  # silently strand every id still left in the loop. Wrapping it as an `if`
  # condition is exempt from that, so a single failure here is just recorded
  # and the loop moves on to the rest.
  if ! inject_command "$INJECT_METHOD" "$wid" "$CMD"; then
    log "WARN: injection failed for $id, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi
  log "sent to $id (wid=$wid, method=$INJECT_METHOD)"
done

log "done: $(( ${#TARGET_IDS[@]} - FAILED ))/${#TARGET_IDS[@]} sent"
