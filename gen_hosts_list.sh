#!/usr/bin/env bash
# Scans xterm windows titled "<PREFIX><host>_<id>_<pid>" on the current X
# display and generates hosts.list. Stores the full window title, prefix
# included, as-is — run_job.sh then matches on that exact string, so it never
# needs to know/reconstruct the prefix, and a hosts.list can even mix entries
# spawned with different prefixes. Multiple windows for the same host each
# survive as separate lines instead of collapsing into one.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

OUT_FILE="$HOSTS_FILE"

usage() {
  cat <<EOF
Usage: $0 [-P prefix] [-o output_file]

  -P PREFIX   Window title prefix (default: \$WINDOW_PREFIX = "$WINDOW_PREFIX")
  -o FILE     Output file path (default: $HOSTS_FILE)
EOF
  exit 1
}

while getopts "P:o:h" opt; do
  case "$opt" in
    P) WINDOW_PREFIX="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done

command -v xdotool >/dev/null 2>&1 || { log "ERROR: xdotool is required"; exit 1; }

mapfile -t WIDS < <(xdotool search --name "^${WINDOW_PREFIX}")

if [ "${#WIDS[@]}" -eq 0 ]; then
  log "WARN: no window found starting with '${WINDOW_PREFIX}'"
  exit 1
fi

IDS_FOUND=()
for wid in "${WIDS[@]}"; do
  title="$(xdotool getwindowname "$wid" 2>/dev/null || true)"
  [[ "$title" == "${WINDOW_PREFIX}"* ]] || continue
  IDS_FOUND+=("$title")
done

if [ "${#IDS_FOUND[@]}" -eq 0 ]; then
  log "WARN: windows found but no titles could be extracted"
  exit 1
fi

if [ -f "$OUT_FILE" ]; then
  cp "$OUT_FILE" "${OUT_FILE}.bak"
  log "backed up existing $OUT_FILE to ${OUT_FILE}.bak"
fi

printf '%s\n' "${IDS_FOUND[@]}" | sort -u > "$OUT_FILE"
log "scanned ${#WIDS[@]} window(s) -> wrote $(wc -l < "$OUT_FILE") unique title(s) to $OUT_FILE"
