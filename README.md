# Xdoreal

Picks terminals (xterm, shared with the master over X), runs an environment
command in them and/or a benchmarked command at a synchronized time, and
aggregates each terminal's execution time via a shared NAS.

## Files

| File | Purpose |
|---|---|
| `hosts.list` | Registry of all known target terminals, one full window title per line |
| `selected.hosts` | The subset `run_env.sh`/`run_cmd.sh` actually act on — written by `select_hosts.sh` |
| `common.sh` | Shared config and helpers |
| `spawn_terminal.sh` | Run on a host to open its batch terminal on the master's shared DISPLAY |
| `gen_hosts_list.sh` | Scans open terminals and (re)generates `hosts.list` |
| `select_hosts.sh` | Picks targets from `hosts.list` and writes `selected.hosts` |
| `run_env.sh` | Sends an environment/setup command to each selected terminal — no timing, no sync |
| `run_cmd.sh` | Runs a benchmarked command on each selected terminal, synchronized, timed |
| `check_hosts.sh` | Diagnostics/maintenance on selected terminals: liveness check, screen clear, Ctrl+C |

No agent needs to run on the target hosts — commands are typed/pasted
directly into the shell that's already open in each terminal.

## Why four separate scripts

Two fundamentally different jobs used to live in one script, and got tangled:
- Setup commands (`setenv`, `source`, `newgrp`, ...) need to take effect *in
  the interactive shell itself*, have no notion of "elapsed time", and don't
  need every terminal to start at the same instant.
- A benchmark needs exactly the opposite: run in a disposable child process,
  timed, ideally kicked off simultaneously across every terminal.

Bolting both onto one synchronized/timed pipeline made the setup side needlessly
complicated (see below) for no benefit to it. So they're now separate tools:
- **`run_env.sh`** just sends the command straight to each terminal via
  xdotool — no wrapper script, no barrier, no waiting, no timing. If it's
  `setenv FOO bar`, that shell now has `FOO` set. If it's `newgrp group`, that
  shell is now a member of `group` (see below for why this — and other
  shell-replacing commands — actually still works correctly here).
- **`run_cmd.sh`** keeps the synchronized-start/timing machinery, and only that.
- **`select_hosts.sh`** picks the target set once; `run_env.sh`, `run_cmd.sh`,
  and `check_hosts.sh` all just read whatever it last wrote, so a setup pass
  and a benchmark pass always hit the exact same hosts without re-specifying
  them.
- **`check_hosts.sh`** is neither of the above — it doesn't run a
  user-supplied command *inside* the shell at all. It acts *on* the terminal:
  is it still responding, clear its scrollback, or send it Ctrl+C. One of its
  actions (`interrupt`) is a raw key event, not even typed text, so it never
  fit the `-c "<command>"` shape either of the other two scripts use.

## Why `run_env.sh` still works for shell-replacing commands

`run_env.sh` types the setup command directly — no source, no wrapper file.
For most commands (`setenv`, `source`, plain aliases) that's the whole story.

Commands like `newgrp`, `exec`, `su`, or `login` are a special case: they
exec() a *new process image* over the shell that read them, so if anything
were queued to run right after in the same breath, it would be lost — the
process reading it is simply gone. `run_env.sh` never has this problem
because it doesn't queue anything after the command; it sends exactly one
line and stops. Whatever shell ends up attached to that terminal afterward —
the original one, or a freshly exec'd replacement — is simply what's there
the next time you type (or `run_env.sh`/`run_cmd.sh` types) something into
that window.

## Identifier format

Each terminal's window title is `<WINDOW_PREFIX><host>_<id>_<pid>`
(e.g. `BATCH_host03_hyungreal_14007`), where `id` is the spawning user's login
name and `pid` is `spawn_terminal.sh`'s own PID (kept through `exec`). This
guarantees a unique title even if the same host gets a terminal spawned twice.

`hosts.list` stores this **entire title, prefix included**, and every script
here matches on that exact string — none of them need to know or reconstruct
`WINDOW_PREFIX`. This also means a single `hosts.list` can mix entries spawned
under different prefixes (e.g. one batch from `-P "BATCH_"`, another from
`-P "OTHER_"` appended in) and lookups still find each one correctly.

## spawn_terminal.sh

```bash
./spawn_terminal.sh [-H <host>] [-d <display>] [-P <prefix>]
```
`-H` defaults to the machine's own `hostname` if omitted. `-P` overrides
`WINDOW_PREFIX` for this invocation only.

Env vars: `XTERM_BIN` (default `/usr/bin/xterm`, override for e.g. OpenWindows),
`XTERM_RESOURCE_CLASS` (default `XTerm`), `WINDOW_PREFIX` (default `BATCH_`).

Has no dependency on `common.sh` (or any other file here), so it can be
copied to a target host on its own. Target terminals are assumed to run csh
(or tcsh) — see `run_cmd.sh` below.

## gen_hosts_list.sh

```bash
./gen_hosts_list.sh [-P prefix] [-o output_file]
```
Scans currently-open terminals and writes `hosts.list` (the full registry,
not the selection). Backs up any existing output file to `<file>.bak` before
overwriting.

## select_hosts.sh

```bash
./select_hosts.sh (-n <count> | -H id1,id2,...) [-f file]
```

| Option | Meaning | Default |
|---|---|---|
| `-n` | Pick N random identifiers (full window titles) from `hosts.list` | - |
| `-H` | Explicit comma-separated identifier list (full window titles, overrides `-n`) | - |
| `-f` | Output selection file path | `<dir of hosts.list>/selected.hosts` |

Always performs the pick and overwrites the selection file (backing up any
existing one to `<file>.bak`, same convention as `gen_hosts_list.sh`) — that's
this script's entire job, so running it again with `-n` gets you a fresh
random subset. Neither `run_env.sh` nor `run_cmd.sh` does any selection of
its own; they only ever read whatever this last wrote.

```bash
./select_hosts.sh -n 10                                    # fresh random 10
./select_hosts.sh -H BATCH_host03_alice_20441,BATCH_host07_alice_20558
```

## run_env.sh

```bash
./run_env.sh -c "<command>" [-I type|clip]
```

| Option | Meaning | Default |
|---|---|---|
| `-c` | Command to run as-is in each selected terminal (required) | - |
| `-I` | Injection method: `type` or `clip` (`clip` needs `xclip`) | `type` |

If `selected.hosts` doesn't exist yet, it errors out telling you to run
`select_hosts.sh` first, rather than guessing a target set.

Before sending anything, it checks that every selected terminal's window
still exists — a terminal that closed, crashed, or whose host rebooted since
`select_hosts.sh` ran is reported (one `ERROR: no terminal window found for
<id>` line per missing one) and the whole run is aborted, rather than
silently sending to whatever subset happens to still be around.

If an individual injection still fails partway through (e.g. a terminal
closes in the instant between that check and its turn), it's logged as a
`WARN` and skipped — that one host is excluded from the count, but every
other selected terminal still gets the command; a single bad terminal can't
strand the rest of the run.

```bash
SELECTED_FILE=/mnt/nas/dam_batch/selected.hosts ./run_env.sh -c "setenv DATA_DIR /mnt/data"
SELECTED_FILE=/mnt/nas/dam_batch/selected.hosts ./run_env.sh -c "newgrp projgroup"
SELECTED_FILE=/mnt/nas/dam_batch/selected.hosts ./run_env.sh -c "source ~/setup.csh"
```

## run_cmd.sh

```bash
./run_cmd.sh -c "<command>" [-t "<time>"] [-w <sec>] [-p <sec>] [-I type|clip]
```

| Option | Meaning | Default |
|---|---|---|
| `-c` | Benchmarked command (required) | - |
| `-t` | Target start time (`now` or anything `date -d` parses) | `now` |
| `-w` | Max time to wait for completion (sec) | `3600` |
| `-p` | Completion poll interval (sec) | `1` |
| `-I` | Injection method: `type` or `clip` (`clip` needs `xclip`, much faster for large n) | `type` |

Same missing-`selected.hosts` guard, pre-flight window check, and per-host
injection-failure resilience as `run_env.sh` (a host that fails to inject is
excluded from the completion count too, so the wait loop doesn't hang on it).

`-c` is written to its own script file and run as `csh <benchscript>`, piped
through `tee` — a genuine child csh process, timed, with exit code and
elapsed seconds collected, and its output shown live in the terminal as well
as saved to `<id>.time.log`. csh has no pipefail/`PIPESTATUS`, so capturing
the exit code through a pipe takes a small trick:
`( csh <benchscript> ; echo $status > <rcfile> ) |& tee ...` — the inner
subshell writes its own status before the outer pipe's status (tee's, not
the benchmark's) could clobber it.

**Simultaneity**: each target terminal first gets a "wait until the START
file exists" command; at the target time the master touches that one file,
and every waiting terminal starts within `BARRIER_POLL`'s polling interval of
each other. This keeps actual start times aligned even if injecting the
command itself takes a while sequentially across many terminals.

**Permissions**: the `results/`/`status/` job directories this script (and
`check_hosts.sh -a check`) creates under `$NAS_ROOT` go through
`common.sh`'s `mkdir_shared`, which `chmod 0777`s the whole chain from each
directory up to (but not including) `$NAS_ROOT` right after creating it (and
`umask 000` is set for anything else `run_cmd.sh` writes), regardless of the
caller's own umask. Each target terminal may be logged in as a different
user on a different host, and needs to write its own `.time`/`.rc`/`.done`
files into these same directories — a restrictive default (e.g. the common
`022`) would block those writes outright, and a stricter one (e.g. `077`) is
worse: a directory without traverse permission makes `[ -f barrier ]`
evaluate to false forever rather than erroring, which looks exactly like a
terminal permanently stuck at `csh <script>`, spinning in the barrier-wait
loop and never seeing the START file the master already touched. (`$NAS_ROOT`
itself is left alone — it's assumed to already be a properly shared mount,
not something this project should be chmod-ing.)

`clip` pastes via Ctrl+Shift+V, a binding `spawn_terminal.sh` sets up at
launch — not xterm's default Shift+Insert, since `Insert` isn't a native key
in every keymap and xdotool's fallback (temporarily remapping a spare keycode
to it) can race and send the wrong character. Terminals not spawned through
`spawn_terminal.sh` won't have this binding, so `-I clip` won't work there.

```bash
select_hosts.sh -n 10
run_env.sh -c "setenv DATA_DIR /mnt/data"
NAS_ROOT=/mnt/nas/dam_batch run_cmd.sh -c "run_batch.sh" -t "16:30:00"
NAS_ROOT=/mnt/nas/dam_batch run_cmd.sh -c "run_batch.sh" -t "23:00:00" -I clip
```

Env vars (shared, `common.sh`): `NAS_ROOT` (default `/nas/dam_batch`, used by
`run_cmd.sh`/`check_hosts.sh -a check`), `HOSTS_FILE`, `SELECTED_FILE` (same
as `-f`/default target for `run_env.sh`/`run_cmd.sh`/`check_hosts.sh`),
`WINDOW_PREFIX` (only `spawn_terminal.sh`/`gen_hosts_list.sh`),
`BARRIER_POLL` (default `0.05`), `CLIP_SETTLE` (default `0.1`),
`INJECT_METHOD`.

## check_hosts.sh

```bash
./check_hosts.sh -a check|clear|interrupt [-w <sec>] [-I type|clip]
```

| Option | Meaning | Default |
|---|---|---|
| `-a` | `check` (liveness probe), `clear` (scrollback reset), or `interrupt` (Ctrl+C) — required | - |
| `-w` | Liveness probe timeout in seconds, `-a check` only | `5` |
| `-I` | Injection method for `check`/`clear`: `type` or `clip` (`interrupt` is always a raw key event, ignores this) | `type` |

Same missing-`selected.hosts` guard and pre-flight window check as
`run_env.sh`/`run_cmd.sh`.

- **`check`**: types `echo alive > <marker file>` into each terminal and
  polls for that file to appear, up to `-w` seconds. A terminal whose window
  exists but whose shell isn't actually reading input — e.g. blocked in an
  uninterruptible syscall on a stale NFS mount, or busy with a runaway
  foreground process — never creates its marker, and is reported as
  `NO RESPONSE` rather than `RESPONSIVE`. This is a different failure mode
  than the window simply not existing (that's the pre-flight check above).
- **`clear`**: sends the `clear` command, like any other typed command — only
  helps a terminal that's already responsive; it can't do anything for one
  that's genuinely stuck (that input just queues, unread, same as any other
  command would).
- **`interrupt`**: sends Ctrl+C (`xdotool key ctrl+c`) to cancel whatever's
  running in the foreground. Best-effort — SIGINT can't touch a process
  blocked in an uninterruptible syscall either, so a hard NFS hang won't be
  fixed by this; only the mount recovering, or killing/respawning the
  terminal, will.

```bash
check_hosts.sh -a check -w 10
check_hosts.sh -a interrupt
check_hosts.sh -a clear
```

## Output

`run_cmd.sh` results land in `$NAS_ROOT/results/<JOBID>/summary.tsv` (`id`,
seconds, exit code per line), plus per-id `.time`/`.rc` files. Status/barrier
files, along with each id's generated `.script`/`.script.bench`, are in
`$NAS_ROOT/status/<JOBID>/`.

```
ID                                   TIME(s)  RC
BATCH_host03_alice_20441             12.481   0
BATCH_host07_alice_20558             12.479   0

Completed 2 | avg=12.480s max=12.481s min=12.479s
```

`run_env.sh` doesn't produce timing output — it just logs which ids it
successfully sent the command to.
