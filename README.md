# herdr-git-dirty

A small Herdr plugin that shows the number of uncommitted files in each Space.

Dirty repositories display `*N` (for example, `*3`). Clean repositories and
non-Git Spaces display nothing. Staged, unstaged, deleted, renamed, and
untracked files are included; ignored files are not. The status refreshes every
3 seconds after each polling cycle finishes. Spaces pointing at the same
worktree share one Git status scan per cycle; linked worktrees are scanned
separately. Successfully reported tokens and cwd mappings are cached in memory.

## Install

Requirements: Herdr 0.7.5 or newer, Git, Bash, and `jq`.

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

Run `python3 tests/poll.py` for isolated integration checks using real Git and a
mock Herdr CLI. Add `--benchmark` for two 60-second runs comparing the original
poller (`e936466`) with the current implementation. The harness requires Python 3
and leaves its fixtures in `/tmp`; it does not start or enable a Herdr plugin.
