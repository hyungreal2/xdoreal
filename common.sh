#!/usr/bin/env bash
# Shared config/helpers for the master orchestration scripts

NAS_ROOT="${NAS_ROOT:-/nas/dam_batch}"
HOSTS_FILE="${HOSTS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosts.list}"
SELECTED_FILE="${SELECTED_FILE:-$(dirname "$HOSTS_FILE")/selected.hosts}"
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

# run_env.sh and run_cmd.sh both act on whatever select_hosts.sh last wrote
# to $SELECTED_FILE — neither does its own host selection. This check gives a
# consistent error/guidance message in both instead of each re-implementing it.
require_selection_file() {
  if [ ! -s "$SELECTED_FILE" ]; then
    log "ERROR: no selection file at $SELECTED_FILE — run select_hosts.sh -n <count> (or -H id1,id2,...) first"
    return 1
  fi
}

load_selected_hosts() {
  cat "$SELECTED_FILE"
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
#
# keydown/keyup are sent as separate xdotool invocations rather than one
# `xdotool key ctrl+shift+v` (with or without --clearmodifiers) because both
# of those were observed to deliver a bare, unmodified "v"/"V" instead of
# triggering the translation — xdotool's internal modifier bookkeeping for a
# single combined combo isn't reliable here. Splitting into separate
# processes forces the ctrl+shift keydown to actually land at the X server
# before "v" is pressed, closer to how a real keypress sequence looks.
inject_via_clip() {
  local wid="$1" cmd="$2"
  printf '%s' "$cmd" | xclip -i -selection primary -l 1 &
  sleep "$CLIP_SETTLE"
  xdotool keydown --window "$wid" ctrl+shift
  xdotool key     --window "$wid" v
  xdotool keyup   --window "$wid" ctrl+shift
  xdotool key     --window "$wid" Return
}

inject_command() {
  local method="$1" wid="$2" cmd="$3"
  case "$method" in
    type) inject_via_type "$wid" "$cmd" ;;
    clip) inject_via_clip "$wid" "$cmd" ;;
    *) log "ERROR: unknown injection method: $method"; return 1 ;;
  esac
}

# Writes run_cmd.sh's dispatched script: wait for the barrier file, then run
# bench_cmd timed, capturing exit code and elapsed seconds, then touch the
# completion marker. Writes to $scriptfile and returns the one-line
# "csh <scriptfile>" command to inject — a plain command invocation, not
# `source`. run_cmd.sh has no setup step of its own (that's run_env.sh's
# entire job, run separately beforehand), so there's no shell-replacement
# concern here and no reason to source this into the listening shell; running
# it as a genuine child process is simpler and works the same regardless of
# what shell is currently interactive in the terminal.
#
# bench_cmd is written to its own file ($scriptfile.bench) and run as
# `csh $scriptfile.bench` — a further, separate child csh process — so its
# exit status and elapsed time are captured the same way regardless of what
# bench_cmd itself does (job control, nested shells, etc.). Piped through tee
# so output shows live in the terminal as well as landing in $tfile.log. csh
# has no pipefail/PIPESTATUS, so $status after a pipe would be tee's exit
# code, not the benchmark's — the inner subshell writes its own $status to
# $rfile right after csh finishes, before the outer pipe's status can
# overwrite anything.
#
# csh's `while`/`end` must not be crammed onto one line with `;` — `end` has
# to be the only thing on its own line, or the parser errors out
# ("while: end not found.").
#
# Assumes none of the paths contain spaces.
build_cmd_script() {
  local barrier="$1" bench_cmd="$2" tfile="$3" rfile="$4" dfile="$5" scriptfile="$6"
  local benchfile="${scriptfile}.bench"

  printf '%s\n' "$bench_cmd" > "$benchfile"

  local script="while ( ! -f $barrier )
sleep $BARRIER_POLL
end
set _t0 = \`date +%s\`
( csh $benchfile ; echo \$status > $rfile ) |& tee $tfile.log
set _t1 = \`date +%s\`
@ _dt = \$_t1 - \$_t0
echo \$_dt > $tfile
touch $dfile"

  printf '%s\n' "$script" > "$scriptfile"
  printf 'csh %s' "$scriptfile"
}
