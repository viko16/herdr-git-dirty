# herdr-git-dirty

A small Herdr plugin that shows the number of uncommitted files in each Space.

Dirty repositories display `*N` (for example, `*3`). Clean repositories and
non-Git Spaces display nothing. Staged, unstaged, deleted, renamed, and
untracked files are included; ignored files are not. The status refreshes every
3 seconds after each polling cycle finishes. Spaces pointing at the same
worktree share one Git status scan per cycle; linked worktrees are scanned
separately. Cwd mappings are cached in memory. Each cycle compares the current
server token with the Git status and only reports differences, restoring missing
tokens after a server restart even when the poller keeps running.

Failed or timed-out Git commands leave the current token unchanged (unknown).
Each Git discovery/status command has a 5-second deadline; its process group is
terminated on timeout. A short-lived supervisor retains the process-group
identity until cleanup finishes, including on normal completion; descendants
left in that group are killed so inherited output pipes cannot hold up polling.
Failed status scans are shared across Spaces and retried
after 3, 6, 12, 24, then at most 30 seconds, rechecking only the affected root
mappings. Scanning stays serial, so a slow worktree can delay following Spaces
by up to the command deadline; multiple slow worktrees add up. Herdr CLI calls
and filesystem operations are not given deadlines. Shutdown during a Git scan
can wait for its deadline and cleanup.

Non-Git cwd results are cached for 30 seconds. Ancestor `.git` checks on every
cycle detect newly initialized parent/nested repositories immediately. Ambiguous
discovery failures (including inaccessible directories or broken Git markers)
retain tokens instead of being cached as non-Git. A kernel file lock is held for
the poller's lifetime; its file is deliberately never deleted. PID files are
informational, not used as evidence of lock ownership. The lock cannot exclude
pollers from older versions that never acquired it; follow the upgrade steps
below before replacing an older installation.

## Install

Requirements: Herdr 0.7.5 or newer, Git, Bash (3.2 or newer), `jq`, `awk`, and Perl with its core
`Fcntl`, `POSIX`, and `Time::HiRes` modules. No `flock` executable is required.

```bash
herdr plugin install viko16/herdr-git-dirty
```

Add `$git_dirty` to the Space rows in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  ["branch", "git_status", { token = "$git_dirty", fg = "#ff5f56" }],
]
```

Then reload the configuration:

```bash
herdr server reload-config
```

After installing, switch Spaces once or restart Herdr to start the plugin.

## Upgrade from the older PID/directory-lock poller

Restarting Herdr is **not** a stop guarantee: the old detached poller keeps
retrying when its socket or plugin-list request fails. The new file lock cannot
coordinate with that old process. Do not update or re-enable until all old
pollers for this installation have exited.

1. Keep the relevant Herdr session reachable, using the same socket/profile as
   the old poller. Record the installation's `manifest_path`, then disable it:

   ```sh
   herdr plugin list --plugin viko16.git-dirty --json
   herdr plugin disable viko16.git-dirty
   herdr plugin list --plugin viko16.git-dirty --json |
     jq -e '[.result.plugins[]? | select(.plugin_id == "viko16.git-dirty")] |
       length == 1 and .[0].enabled == false'
   ```

   A successful disable changes the registry; it does not terminate detached
   processes. The old poller checks it every ten cycles (about 30 seconds plus
   scan/CLI time), clears its tokens and exits only after observing disabled.

2. Wait at least that check interval, then inspect the full process commands:

   ```sh
   ps -ww -axo pid=,ppid=,lstart=,args= | awk '/[b]in\/poll\.sh/'
   ```

   Compare the script paths with the recorded `manifest_path` directory, and
   check every matching poller, including any using another session/socket.
   Repeat the check and confirm none remain for this installation. A missing
   PID file or a successful disable response alone is not proof of exit. Do
   not delete lock files or signal a PID copied from a PID file. If a poller
   remains, a Git/CLI call may be stuck or its old session may be unreachable:
   keep the plugin disabled and stop the upgrade until its exit can be verified.
   This procedure deliberately does not automatically kill any process.

3. Once the desired upstream ref includes this fix, update the stopped,
   GitHub-managed installation and verify that it is still disabled:

   ```sh
   herdr plugin update viko16.git-dirty
   herdr plugin list --plugin viko16.git-dirty --json |
     jq -e '[.result.plugins[]? | select(.plugin_id == "viko16.git-dirty")] |
       length == 1 and .[0].enabled == false'
   ```

   The update follows the installation's recorded ref; a pinned old ref will
   not acquire this fix. Verify the installed revision/files include
   `bin/lock.pl` and `bin/bounded.pl` before enabling. Locally linked plugins
   must instead be updated at their recorded path while disabled and stopped.

4. Enable the verified installation with `herdr plugin enable viko16.git-dirty`,
   then switch Spaces to invoke its focus hook. Repeat the process inspection:
   there should be one new poller per Herdr socket, with restored dirty tokens.

Command syntax was checked with Herdr 0.9.5 `--help`; registry-only disable and
preservation of the enabled flag during update were checked in its
[plugin implementation](https://github.com/herdrdev/herdr/blob/v0.9.5/src/cli/plugin.rs)
and [enable/disable handler](https://github.com/herdrdev/herdr/blob/v0.9.5/src/app/api/plugins/mod.rs).
No live plugin upgrade is performed by this project's tests.

## Use

No command is needed. Open Herdr normally; each dirty Space will show `*N` in
the sidebar. The indicator disappears after all changes in that repository are
committed or discarded.

To uninstall:

```bash
herdr plugin uninstall viko16.git-dirty
```

Remove `$git_dirty` from `ui.sidebar.spaces.rows` after uninstalling.

## Development

Run the complete isolated suite using real Git and a mock Herdr CLI:

```sh
/bin/bash -n bin/start.sh bin/poll.sh
perl -c bin/lock.pl
perl -c bin/bounded.pl
python3 tests/lifecycle.py
python3 tests/poll.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/reliability.py
git diff --check
```

The tests cover concurrent startup and crash recovery, shared failures and
backoff, token preservation, timeout/descendant cleanup, non-Git caching and
subsequent `git init`, plus the existing counting and server-restart regressions.
GitHub Actions runs this suite on macOS and Linux. Call-count assertions measure
mock command budgets, not real-world speedups.

Use `python3 tests/poll.py --benchmark` for two 60-second runs comparing the original
poller (`e936466`) with the current implementation; this requires that commit
to be available in local Git history. The harness requires Python 3, runs the
poller with `/bin/bash`, and leaves its fixtures in `/tmp`; it does not start or
enable a Herdr plugin. Benchmark results include mock CLI and wrapper overhead
and depend on the local machine and worktree contents.
Use `--benchmark --baseline HEAD` to compare against the current commit instead.
