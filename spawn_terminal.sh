#!/usr/bin/env bash
# Run on a target host to open a batch terminal on the given X DISPLAY (the
# one shared by the master). Title is "${WINDOW_PREFIX}${HOST}_${ID}_$$",
# where the trailing $$ (this script's own PID) guarantees uniqueness. The
# script execs into xterm at the end, so the PID is preserved, and the kernel
# never assigns the same PID to two concurrently running processes — so the
# title can never collide with another running terminal. This works even
# without xdotool on the host running spawn.
#
# This full title, prefix included, is what gets stored as-is in hosts.list
# (see gen_hosts_list.sh), so multiple windows for the same host can still be
# told apart precisely.

set -euo pipefail

# Self-contained on purpose: this script runs on each target host (not the
# master), so it shouldn't need common.sh or anything else copied alongside it.
WINDOW_PREFIX="${WINDOW_PREFIX:-BATCH_}"
XTERM_BIN="${XTERM_BIN:-/usr/bin/xterm}"
XTERM_RESOURCE_CLASS="${XTERM_RESOURCE_CLASS:-XTerm}"

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }

HOST=""
DISPLAY_TARGET="${DISPLAY:-}"

usage() {
  cat <<EOF
Usage: $0 [-H <host>] [-d <display>] [-P <prefix>]

  -H HOST     Host label for the terminal title (default: this machine's
              own hostname, from \`hostname\`)
  -d DISPLAY  X DISPLAY to connect to (e.g. master:10.0). Defaults to the
              current \$DISPLAY if omitted
  -P PREFIX   Window title prefix (default: \$WINDOW_PREFIX = "$WINDOW_PREFIX")

Env vars:
  XTERM_BIN             xterm (or compatible terminal) binary path (default: $XTERM_BIN)
                        e.g. XTERM_BIN=/usr/openwin/bin/xterm for OpenWindows
  XTERM_RESOURCE_CLASS  X resource class name for allowSendEvents (default: $XTERM_RESOURCE_CLASS)
  WINDOW_PREFIX         Window title prefix (same as -P)
EOF
  exit 1
}

while getopts "H:d:P:h" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    d) DISPLAY_TARGET="$OPTARG" ;;
    P) WINDOW_PREFIX="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -z "$HOST" ] && HOST="$(hostname)"
[ -z "$DISPLAY_TARGET" ] && { log "ERROR: set DISPLAY via -d or export \$DISPLAY"; exit 1; }
command -v "$XTERM_BIN" >/dev/null 2>&1 || [ -x "$XTERM_BIN" ] || { log "ERROR: XTERM_BIN='$XTERM_BIN' not found"; exit 1; }

id="$(id -un)"
title="${WINDOW_PREFIX}${HOST}_${id}_$$"

log "launching terminal titled '$title' on DISPLAY=$DISPLAY_TARGET"
exec "$XTERM_BIN" -display "$DISPLAY_TARGET" -T "$title" -xrm "${XTERM_RESOURCE_CLASS}*allowSendEvents: true"
