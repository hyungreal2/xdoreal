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

# hosts.list stores the full window title, prefix included (see
# gen_hosts_list.sh). Finds the window whose title is an exact match — since
# the stored string already includes whatever prefix that window was spawned
# with, callers never need to know/reconstruct WINDOW_PREFIX, and entries
# spawned under different prefixes can coexist in the same hosts.list.
find_window_id() {
  local fullname="$1"
  xdotool search --name "^${fullname}\$" 2>/dev/null | head -n1
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

# Loads the PRIMARY selection via xclip and pastes with the Ctrl+Shift+V
# binding that spawn_terminal.sh sets up (see its -xrm translation). Fast
# regardless of string length, so better for large n (e.g. 100 hosts).
# `xclip -l 1` exits after serving one request, so no zombie process is left
# behind.
#
# Ctrl+Shift+V rather than xterm's default Shift+Insert: Insert isn't a native
# key in every keymap (many minimal/remote X setups don't define it), so
# xdotool has to temporarily remap a spare keycode to it — a real race that
# can misfire and send whatever that keycode used to mean instead (e.g. a
# stray "~"). Ctrl/Shift/V are always native keys, so no remapping ever
# happens.
inject_via_clip() {
  local wid="$1" cmd="$2"
  printf '%s' "$cmd" | xclip -i -selection primary -l 1 &
  sleep "$CLIP_SETTLE"
  xdotool key --window "$wid" ctrl+shift+v
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

# Writes a csh script (wait for the barrier file, run $cmd timed, report
# elapsed seconds/exit code/done marker to the given paths) to $scriptfile on
# the shared NAS, and prints the short one-line command to inject:
# "source <scriptfile>".
#
# Always csh, and always `source` rather than spawning a new interpreter
# process, because:
#   - the script is written to a file and just referenced by path, so the
#     interactive shell's own dialect never actually matters for typing it —
#     there's no multi-line/quoted text to get mis-parsed either way — so
#     there's no reason to support more than one target dialect.
#   - `source` runs it directly in the terminal's already-running csh, instead
#     of a child process, so it keeps that shell's full state (env, cwd,
#     aliases, non-exported variables) exactly as-is, matching the
#     requirement that the existing shell run the job, not a fresh one.
#
# csh's `while`/`end` must not be crammed onto one line with `;` — `end` has
# to be the only thing on its own line, or the parser errors out
# ("while: end not found.").
#
# Assumes none of the paths contain spaces.
build_remote_cmd() {
  local barrier="$1" cmd="$2" tfile="$3" rfile="$4" dfile="$5" scriptfile="$6"
  local script="while ( ! -f $barrier )
sleep $BARRIER_POLL
end
set _t0 = \`date +%s\`
( $cmd ) >& $tfile.log
set _rc = \$status
set _t1 = \`date +%s\`
@ _dt = \$_t1 - \$_t0
echo \$_dt > $tfile
echo \$_rc > $rfile
touch $dfile"

  printf '%s\n' "$script" > "$scriptfile"
  printf 'source %s' "$scriptfile"
}
