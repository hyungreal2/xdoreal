# Xdoreal

Runs a command on n chosen xterm terminals (shared with the master over X)
at the same target time, and aggregates each terminal's execution time via
a shared NAS.

## Files

| File | Purpose |
|---|---|
| `hosts.list` | Registry of target terminals, one full window title per line |
| `common.sh` | Shared config and helpers |
| `spawn_terminal.sh` | Run on a host to open its batch terminal on the master's shared DISPLAY |
| `gen_hosts_list.sh` | Scans open terminals and (re)generates `hosts.list` |
| `run_job.sh` | Master entry point: dispatch, run, collect timing |

No agent needs to run on the target hosts. `run_job.sh` writes small csh
scripts to the shared NAS per target and types/pastes only short one-line
commands (`source <file>` / `csh <file>`) into the shell that's already open
in each terminal — nothing multi-line or quoted gets typed directly, since
real interactive `csh` doesn't reliably continue an open quote across a
typed/pasted newline the way bash does.

Each target gets **two** separate injected commands, back to back:
1. **pre**: `source <prescript>` — waits for the barrier file, then runs
   `-e`'s setup command literally in that already-running shell (no subshell),
   so things like `setenv FOO bar` take effect there.
2. **post**: `csh <postscript>` — a genuine child csh process (not sourced)
   that runs `-c`'s benchmark timed and touches the completion marker.

They're split like this, and injected as independent commands rather than
one combined script, specifically so setup commands that *replace* the shell
process outright — `newgrp`, `exec`, `su`, `login` — still work correctly:
those exec() a new process image over whatever was reading the pre-script,
so anything appended after them in the *same* script would simply never run.
Characters typed into a terminal while its shell is busy (blocked on the
barrier, or mid-exec) queue at the pty level and are delivered to whichever
shell next reads from it — the original one, or a freshly exec'd replacement
— so the post command still arrives and runs either way. It's launched as a
plain `csh <file>` (not `source`d) rather than assuming that replacement is
also csh/tcsh: "word word" is parsed as "run this program with this
argument" identically by every common shell, so the csh syntax inside always
reaches a real csh no matter what shell typed it in.

`spawn_terminal.sh` has no dependency on `common.sh` (or any other file
here), so it can be copied to a target host on its own. Target terminals are
assumed to run csh (or tcsh).

## Identifier format

Each terminal's window title is `<WINDOW_PREFIX><host>_<id>_<pid>`
(e.g. `BATCH_host03_hyungreal_14007`), where `id` is the spawning user's login
name and `pid` is `spawn_terminal.sh`'s own PID (kept through `exec`). This
guarantees a unique title even if the same host gets a terminal spawned twice.

`hosts.list` stores this **entire title, prefix included**, and `run_job.sh`
matches on that exact string — it never needs to know or reconstruct
`WINDOW_PREFIX`. This also means a single `hosts.list` can mix entries spawned
under different prefixes (e.g. one batch from `-P "BATCH_"`, another from
`-P "OTHER_"` appended in) and `run_job.sh` still finds each one correctly.

## spawn_terminal.sh

```bash
./spawn_terminal.sh [-H <host>] [-d <display>] [-P <prefix>]
```
`-H` defaults to the machine's own `hostname` if omitted. `-P` overrides
`WINDOW_PREFIX` for this invocation only.

Env vars: `XTERM_BIN` (default `/usr/bin/xterm`, override for e.g. OpenWindows),
`XTERM_RESOURCE_CLASS` (default `XTerm`), `WINDOW_PREFIX` (default `BATCH_`).

## gen_hosts_list.sh

```bash
./gen_hosts_list.sh [-P prefix] [-o output_file]
```
Backs up any existing output file to `<file>.bak` before overwriting.

## run_job.sh

```bash
./run_job.sh (-e "<setup>" | -c "<command>" | both) (-n <count> | -H id1,id2,...) [-t "<time>"] [-w <sec>] [-p <sec>] [-I type|clip] [-f file] [-F]
```

Two independent, combinable command types:
- `-e` (setup): runs as-is, directly in the target shell, no subshell, no
  timing. Use it for things like `setenv FOO bar` — or commands that replace
  the shell process outright, like `newgrp <group>` — that need to take
  effect in that shell itself (see the pre/post split above for how this
  stays safe even when the shell gets replaced).
- `-c` (benchmark): written to its own script file and run as `csh
  <benchscript>`, piped through `tee` — a genuine child csh process, timed,
  with exit code and elapsed seconds collected, and its output shown live in
  the terminal as well as saved to `<id>.time.log`. csh has no
  pipefail/`PIPESTATUS`, so capturing the exit code through a pipe takes a
  small trick: `( csh <benchscript> ; echo $status > <rcfile> ) |& tee ...` —
  the inner subshell writes its own status before the outer pipe's status
  (tee's, not the benchmark's) could clobber it.

At least one of `-e`/`-c` is required; if both are given, `-e` always runs
first, so `-c`'s command sees whatever `-e` set up (e.g. env vars from
`setenv`, since child processes inherit their parent's environment either way).

| Option | Meaning | Default |
|---|---|---|
| `-e` | Setup command (see above) | - |
| `-c` | Benchmarked command (see above) | - |
| `-n` | Pick N random identifiers (full window titles) from `hosts.list` | - |
| `-H` | Explicit comma-separated identifier list (full window titles, overrides `-n` and the selection file) | - |
| `-t` | Target start time (`now` or anything `date -d` parses) | `now` |
| `-w` | Max time to wait for completion (sec) | `3600` |
| `-p` | Completion poll interval (sec) | `1` |
| `-I` | Injection method: `type` or `clip` (`clip` needs `xclip`, much faster for large n) | `type` |
| `-f` | Selection file path for `-n` (see below) | `<dir of hosts.list>/selected.hosts` |
| `-F` | Force a fresh random `-n` pick, overwriting the selection file | - |

**`-n` selection persistence**: the first time `-n` picks a random subset (no
existing selection file), the chosen identifiers are saved to the selection
file. Subsequent `-n` runs reuse that exact file's contents instead of
picking a new random subset — handy for re-running the same benchmark
against the same hosts (e.g. a warm-up pass, then a timed pass). Pass `-F` to
force a fresh random pick, overwriting the file.

`clip` pastes via Ctrl+Shift+V, a binding `spawn_terminal.sh` sets up at
launch — not xterm's default Shift+Insert, since `Insert` isn't a native key
in every keymap and xdotool's fallback (temporarily remapping a spare keycode
to it) can race and send the wrong character. Terminals not spawned through
`spawn_terminal.sh` won't have this binding, so `-I clip` won't work there.

```bash
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -c "run_batch.sh" -n 10
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -H BATCH_host03_alice_20441,BATCH_host07_alice_20558 -c "run_batch.sh" -t "16:30:00"
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 100 -c "run_batch.sh" -t "23:00:00" -I clip
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10 -e "setenv DATA_DIR /mnt/data" -c "run_batch.sh"
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10 -e "setenv DATA_DIR /mnt/data"
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10 -e "newgrp projgroup" -c "run_batch.sh"
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10 -c "run_batch.sh --warmup"   # picks & saves the selection
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10 -c "run_batch.sh"            # reuses the same 10 hosts
```

Env vars: `NAS_ROOT` (default `/nas/dam_batch`), `HOSTS_FILE`, `SELECTED_FILE`
(same as `-f`), `WINDOW_PREFIX` (only used by `spawn_terminal.sh`/
`gen_hosts_list.sh`, not `run_job.sh`), `BARRIER_POLL` (default `0.05`),
`CLIP_SETTLE` (default `0.1`), `INJECT_METHOD`.

## Output

Results land in `$NAS_ROOT/results/<JOBID>/summary.tsv` (`id`, seconds, exit
code per line), plus per-id `.time`/`.rc` files. Status/barrier files, along
with each id's generated `.pre.script` and `.post.script` (plus
`.post.script.bench` when `-c` is used), are in `$NAS_ROOT/status/<JOBID>/`.
Setup-only (`-e` with no `-c`) runs show `NA`/`NA` — nothing timed.

```
ID                                   TIME(s)  RC
BATCH_host03_alice_20441             12.481   0
BATCH_host07_alice_20558             12.479   0

Completed 2 | avg=12.480s max=12.481s min=12.479s
```
