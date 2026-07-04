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

# Writes a csh script to $scriptfile on the shared NAS and prints the short
# one-line command to inject: "source <scriptfile>".
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
# The script body has two independent, combinable parts:
#   - setup_cmd: run literally, with no subshell/redirection, so things like
#     `setenv FOO bar` take effect in the sourcing shell itself (and are then
#     visible to bench_cmd below, since it's a child of this shell either way).
#   - bench_cmd: written to its own file ($scriptfile.bench) and run as
#     `csh $scriptfile.bench` — a genuine child csh process, not a "( )"
#     subshell of the sourcing shell — so its exit status and elapsed time
#     are captured the same way regardless of what bench_cmd itself does
#     (job control, nested shells, etc.), same as running `csh scriptfile`
#     used to work before commands were injected via `source`.
# Either can be empty; if both are given, setup_cmd always runs first.
#
# csh's `while`/`end` must not be crammed onto one line with `;` — `end` has
# to be the only thing on its own line, or the parser errors out
# ("while: end not found.").
#
# Assumes none of the paths contain spaces.
build_remote_cmd() {
  local barrier="$1" setup_cmd="$2" bench_cmd="$3" tfile="$4" rfile="$5" dfile="$6" scriptfile="$7"
  local benchfile="${scriptfile}.bench"
  local script="while ( ! -f $barrier )
sleep $BARRIER_POLL
end"

  if [ -n "$setup_cmd" ]; then
    script="$script
$setup_cmd"
  fi

  if [ -n "$bench_cmd" ]; then
    printf '%s\n' "$bench_cmd" > "$benchfile"
    # Piped through tee so output shows live in the terminal as well as
    # landing in $tfile.log. csh has no pipefail/PIPESTATUS, so $status after
    # a pipe would be tee's exit code, not the benchmark's — the inner
    # subshell writes its own $status to $rfile right after csh finishes,
    # before the outer pipe's status can overwrite anything.
    script="$script
set _t0 = \`date +%s\`
( csh $benchfile ; echo \$status > $rfile ) |& tee $tfile.log
set _t1 = \`date +%s\`
@ _dt = \$_t1 - \$_t0
echo \$_dt > $tfile"
  fi

  script="$script
touch $dfile"

  printf '%s\n' "$script" > "$scriptfile"
  printf 'source %s' "$scriptfile"
}
