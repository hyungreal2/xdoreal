#!/usr/bin/env bash
# Picks the target terminals for run_env.sh/run_cmd.sh and writes them to
# $SELECTED_FILE, one full window title per line (see gen_hosts_list.sh for
# the identifier format). Neither run_env.sh nor run_cmd.sh does its own
# selection — they just read whatever this script last wrote, so re-running
# this is the only way to change the target set, and both of them always act
# on the exact same hosts until you run this again.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

N=""
IDS_CSV=""
OUT_FILE="$SELECTED_FILE"

usage() {
  cat <<EOF
Usage: $0 (-n <count> | -H id1,id2,...) [-f file]

  -n N        Pick N random identifiers (full window titles) from hosts.list
  -H LIST     Explicit comma-separated identifier list (full window titles,
              as stored in hosts.list; overrides -n)
  -f FILE     Output selection file path (default: $OUT_FILE)
EOF
  exit 1
}

while getopts "n:H:f:h" opt; do
  case "$opt" in
    n) N="$OPTARG" ;;
    H) IDS_CSV="$OPTARG" ;;
    f) OUT_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -z "$N" ] && [ -z "$IDS_CSV" ] && usage

if [ -n "$IDS_CSV" ]; then
  IFS=',' read -r -a TARGET_IDS <<< "$IDS_CSV"
else
  mapfile -t TARGET_IDS < <(select_hosts_random "$N")
fi

if [ -f "$OUT_FILE" ]; then
  cp "$OUT_FILE" "${OUT_FILE}.bak"
  log "backed up existing $OUT_FILE to ${OUT_FILE}.bak"
fi

printf '%s\n' "${TARGET_IDS[@]}" > "$OUT_FILE"
log "selected ${#TARGET_IDS[@]} identifier(s), saved to $OUT_FILE"
