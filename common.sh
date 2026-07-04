#!/usr/bin/env bash
# Shared config/helpers for the master orchestration scripts

NAS_ROOT="${NAS_ROOT:-/nas/dam_batch}"
HOSTS_FILE="${HOSTS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosts.list}"
WINDOW_PREFIX="${WINDOW_PREFIX:-BATCH_}"
BARRIER_POLL="${BARRIER_POLL:-0.05}"
CLIP_SETTLE="${CLIP_SETTLE:-0.1}"

# Binary path is a variable so OpenWindows/other xterm-compatible terminals
# (different path than /usr/bin/xterm) work too. Resource class name may also
# differ for non-xterm implementations, so it's a variable as well.
XTERM_BIN="${XTERM_BIN:-/usr/bin/xterm}"
XTERM_RESOURCE_CLASS="${XTERM_RESOURCE_CLASS:-XTerm}"

RESULTS_DIR() { echo "$NAS_ROOT/results/$1"; }
STATUS_DIR()  { echo "$NAS_ROOT/status/$1"; }

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }

# hosts.list stores the full "host_id_pid" identifier (spawn_terminal.sh's
# window title with WINDOW_PREFIX stripped). Finds the window whose title is
# an exact match for "${WINDOW_PREFIX}${id}" — since id is already unique,
# no prefix/partial matching is needed, so multiple windows for the same host
# never get confused with each other.
find_window_id() {
  local id="$1"
  xdotool search --name "^${WINDOW_PREFIX}${id}\$" 2>/dev/null | head -n1
}

select_hosts_random() {
  local n="$1"
  shuf -n "$n" "$HOSTS_FILE"
}

# Character-by-character typing (most compatible, but takes seconds per host
# for long strings)
inject_via_type() {
  local wid="$1" cmd="$2"
  xdotool type --window "$wid" -- "$cmd"
  xdotool key  --window "$wid" Return
}

# Loads the PRIMARY selection via xclip and pastes with xterm's default
# Shift+Insert binding. Fast regardless of string length, so better for large
# n (e.g. 100 hosts). `xclip -l 1` exits after serving one request, so no
# zombie process is left behind.
inject_via_clip() {
  local wid="$1" cmd="$2"
  printf '%s' "$cmd" | xclip -i -selection primary -l 1 &
  sleep "$CLIP_SETTLE"
  xdotool key --window "$wid" shift+Insert
  xdotool key --window "$wid" Return
}

inject_command() {
  local method="$1" wid="$2" cmd="$3"
  case "$method" in
    type) inject_via_type "$wid" "$cmd" ;;
    clip) inject_via_clip "$wid" "$cmd" ;;
    *) log "ERROR: unknown injection method: $method"; return 1 ;;
  esac
}
