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

# Writes the "pre" phase: wait for the barrier file, then run setup_cmd (if
# any) literally — no subshell, no redirection — so things like `setenv FOO
# bar` take effect in the sourcing shell itself. Writes to $scriptfile and
# returns the one-line "source <scriptfile>" command to inject.
#
# setup_cmd is deliberately run as its own separate injected command, not
# merged into the same script as the benchmark (see build_post_cmd), because
# some setup commands users actually rely on — newgrp, exec, su, login —
# exec() a whole new process image over the shell that's reading this
# script. Nothing placed after such a command in the SAME script would ever
# run (the process executing it is simply gone). Since build_post_cmd is
# injected as an independent follow-up command instead, it still gets
# delivered and run: characters typed into a terminal while its shell is
# busy (blocked in this while loop, or mid-exec) queue at the pty level and
# are read by whichever shell next does a read() on that terminal — the
# original one, or a freshly exec'd replacement.
#
# csh's `while`/`end` must not be crammed onto one line with `;` — `end` has
# to be the only thing on its own line, or the parser errors out
# ("while: end not found.").
build_pre_cmd() {
  local barrier="$1" setup_cmd="$2" scriptfile="$3"
  local script="while ( ! -f $barrier )
sleep $BARRIER_POLL
end"

  if [ -n "$setup_cmd" ]; then
    script="$script
$setup_cmd"
  fi

  printf '%s\n' "$script" > "$scriptfile"
  printf 'source %s' "$scriptfile"
}

# Writes the "post" phase: the timed bench_cmd (if any) plus the completion
# marker. Writes to $scriptfile and returns the one-line "csh <scriptfile>"
# command to inject — note this is a plain command invocation, NOT `source`.
#
# Always injected as its own command right after build_pre_cmd's (see that
# function's comment) — this is what makes setup commands that replace the
# shell process (newgrp, exec, su, login) still work: this "post" command
# gets delivered and read regardless of whether the pre-phase's shell
# survived setup_cmd unchanged or got replaced by something else entirely.
# But that replacement shell isn't guaranteed to be csh/tcsh — e.g. newgrp
# execs whatever the target user's login shell is configured to be, which may
# not match the terminal's original shell. So unlike the pre-phase (which
# must `source` its script so setup_cmd's env changes land in the listening
# shell), this post-phase script has no such requirement — nothing runs after
# it — so it's launched as a genuine `csh scriptfile` child process instead.
# "word word" is parsed as "run this program with this argument" identically
# by every common shell (bash, sh, csh, tcsh, zsh), so the csh syntax below
# is always interpreted by a real csh, no matter what shell typed it in.
#
# bench_cmd is written to its own file ($scriptfile.bench) and run as
# `csh $scriptfile.bench` — a genuine child csh process, not a "( )" subshell
# — so its exit status and elapsed time are captured the same way regardless
# of what bench_cmd itself does (job control, nested shells, etc.). Piped
# through tee so output shows live in the terminal as well as landing in
# $tfile.log. csh has no pipefail/PIPESTATUS, so $status after a pipe would
# be tee's exit code, not the benchmark's — the inner subshell writes its own
# $status to $rfile right after csh finishes, before the outer pipe's status
# can overwrite anything.
#
# Assumes none of the paths contain spaces.
build_post_cmd() {
  local bench_cmd="$1" tfile="$2" rfile="$3" dfile="$4" scriptfile="$5"
  local benchfile="${scriptfile}.bench"
  local script=""

  if [ -n "$bench_cmd" ]; then
    printf '%s\n' "$bench_cmd" > "$benchfile"
    script="set _t0 = \`date +%s\`
( csh $benchfile ; echo \$status > $rfile ) |& tee $tfile.log
set _t1 = \`date +%s\`
@ _dt = \$_t1 - \$_t0
echo \$_dt > $tfile"
  fi

  script="$script
touch $dfile"

  printf '%s\n' "$script" > "$scriptfile"
  printf 'csh %s' "$scriptfile"
}
