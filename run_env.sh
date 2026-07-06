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

FAILED=0
for id in "${TARGET_IDS[@]}"; do
  wid="$(find_window_id "$id")"
  if [ -z "$wid" ]; then
    log "WARN: couldn't find terminal window for $id, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  inject_command "$INJECT_METHOD" "$wid" "$CMD"
  log "sent to $id (wid=$wid, method=$INJECT_METHOD)"
done

log "done: $(( ${#TARGET_IDS[@]} - FAILED ))/${#TARGET_IDS[@]} sent"
