# herdr-git-dirty

A small Herdr plugin that shows the number of uncommitted files in each Space.

Dirty repositories display `*N` (for example, `*3`). Clean repositories and
non-Git Spaces display nothing. Staged, unstaged, deleted, renamed, and
untracked files are included; ignored files are not. Counts refresh every
3 seconds after each polling cycle finishes.

If a Git check fails or times out, the previous count stays visible. Each Git
command has a 5-second timeout; repeated failures are retried with delays of up
to 30 seconds. Slow repositories can delay updates in other Spaces. Herdr CLI
calls and filesystem operations have no timeout.

## Install

Requirements: Herdr 0.7.5 or newer, Git, Bash 3.2 or newer, `jq`, `awk`, and
Perl with its core `Fcntl`, `POSIX`, and `Time::HiRes` modules.

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

## Upgrade from an older version

Restarting Herdr does **not** guarantee that an old background poller exits.
Stop the old installation before updating to avoid running duplicate pollers.

1. Keep its Herdr session reachable, using the same socket/profile. Disable the
   plugin, then confirm `enabled` is `false` and note its `manifest_path`:

   ```sh
   herdr plugin disable viko16.git-dirty
   herdr plugin list --plugin viko16.git-dirty --json
   ```

2. Allow about 30 seconds plus any ongoing scan time for the old poller to
   notice, then inspect the running processes:

   ```sh
   ps -ww -axo pid=,ppid=,lstart=,args= | awk '/[b]in\/poll\.sh/'
   ```

   Match script paths against the `manifest_path` directory. Repeat the check
   until **all old pollers for this installation**, across sessions, have exited.
   A missing PID file or successful disable response is not proof of exit.
   Do not delete locks, kill unidentified processes, or kill using only a PID
   file. If any old poller remains or its exit is uncertain, keep the plugin
   disabled and **stop the upgrade**; this procedure does not kill it automatically.

3. Update, then confirm the plugin is still disabled and its installed revision
   includes this fix before proceeding:

   ```sh
   herdr plugin update viko16.git-dirty
   herdr plugin list --plugin viko16.git-dirty --json
   ```

   Updates follow the installation's recorded ref, so a pinned old ref may not
   include the fix. For a locally linked plugin, update its checkout instead,
   while keeping it disabled and stopped.

4. Run `herdr plugin enable viko16.git-dirty`, then switch Spaces. Check that
   counts return and only one new poller runs per Herdr socket.

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

Run the isolated tests with Python 3, real Git and a mock Herdr CLI:

```sh
python3 tests/lifecycle.py
python3 tests/poll.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/reliability.py
```

For an optional comparison, run `python3 tests/poll.py --benchmark --baseline REF`
with a baseline commit available locally. Results include mock CLI overhead.
