# Xdoreal

Runs a command on n chosen xterm terminals (shared with the master over X)
at the same target time, and aggregates each terminal's execution time via
a shared NAS.

## Files

| File | Purpose |
|---|---|
| `hosts.list` | Registry of target identifiers, one `host_id_pid` per line |
| `common.sh` | Shared config and helpers |
| `spawn_terminal.sh` | Run on a host to open its batch terminal on the master's shared DISPLAY |
| `gen_hosts_list.sh` | Scans open terminals and (re)generates `hosts.list` |
| `run_job.sh` | Master entry point: dispatch, run, collect timing |

No agent needs to run on the target hosts — commands are typed/pasted directly
into the shell that's already open in each terminal. `spawn_terminal.sh` has no
dependency on `common.sh` (or any other file here), so it can be copied to a
target host on its own.

## Identifier format

Each terminal's window title is `<WINDOW_PREFIX><host>_<id>_<pid>`
(e.g. `BATCH_host03_hyungreal_14007`), where `id` is the spawning user's login
name and `pid` is `spawn_terminal.sh`'s own PID (kept through `exec`). This
guarantees a unique title even if the same host gets a terminal spawned twice.
`hosts.list` stores the full `<host>_<id>_<pid>` string, and matching is always
an exact match — no ambiguity when a host has more than one terminal open.

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
./run_job.sh -c "<command>" (-n <count> | -H id1,id2,...) [-t "<time>"] [-w <sec>] [-p <sec>] [-I type|clip]
```

| Option | Meaning | Default |
|---|---|---|
| `-c` | Command to run | `run_batch.sh` |
| `-n` | Pick N random identifiers from `hosts.list` | - |
| `-H` | Explicit comma-separated identifier list (overrides `-n`) | - |
| `-t` | Target start time (`now` or anything `date -d` parses) | `now` |
| `-w` | Max time to wait for completion (sec) | `3600` |
| `-p` | Completion poll interval (sec) | `1` |
| `-I` | Injection method: `type` or `clip` (`clip` needs `xclip`, much faster for large n) | `type` |

```bash
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 10
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -H host03_alice_20441,host07_alice_20558 -t "16:30:00"
NAS_ROOT=/mnt/nas/dam_batch ./run_job.sh -n 100 -c "run_batch.sh" -t "23:00:00" -I clip
```

Env vars: `NAS_ROOT` (default `/nas/dam_batch`), `HOSTS_FILE`, `WINDOW_PREFIX`,
`BARRIER_POLL` (default `0.05`), `CLIP_SETTLE` (default `0.1`), `INJECT_METHOD`.

## Output

Results land in `$NAS_ROOT/results/<JOBID>/summary.tsv` (`id`, seconds, exit
code per line), plus per-id `.time`/`.rc` files. Status/barrier files are in
`$NAS_ROOT/status/<JOBID>/`.

```
ID                        TIME(s)  RC
host03_alice_20441        12.481   0
host07_alice_20558        12.479   0

Completed 2 | avg=12.480s max=12.481s min=12.479s
```
