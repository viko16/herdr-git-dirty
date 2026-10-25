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
terminated on timeout. Failed status scans are shared across Spaces and retried
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
informational, not used as evidence of lock ownership. Existing pollers from
older plugin versions should be restarted with Herdr when upgrading.

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
