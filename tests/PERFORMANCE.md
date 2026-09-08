# Poller performance verification

Measured on macOS with system Bash 3.2 on 2026-09-08. The baseline is
`e936466`; the optimized version uses in-memory state, one snapshot parser,
and one status scan per distinct worktree per cycle.

## 60-second comparison

Both runs used the same repositories and five workspace entries: four pointing
at one dirty repository and one pointing at a separate linked worktree.
Real Git and jq ran behind counting wrappers; a mock Herdr CLI served snapshots
and accepted metadata. No installed plugin or user session was enabled.

| Calls / measurement | Baseline | Optimized |
| --- | ---: | ---: |
| Git status | 82 | 38 |
| Git rev-parse | 0 | 2 |
| Herdr snapshot | 17 | 19 |
| Herdr plugin list | 2 | 2 |
| Herdr metadata report | 5 | 5 |
| jq, including registry checks | 36 | 21 |
| awk | 163 | 0 |
| mktemp | 18 | 0 |
| mv | 16 | 0 |
| Process tree CPU seconds | 3.642 | 1.643 |

CPU is user + system time returned by `wait4` for the poller and its waited-for
descendants. It includes mock CLI and wrapper overhead. These are isolated
measurements, not production CPU predictions or measurements of other plugins.
The window can end during a cycle. Since the poller sleeps after its work,
the faster implementation completes more cycles in the same window.
Completed-cycle integration assertions separately verify two status calls for
two worktrees even when multiple cwd spellings and subdirectories are present.

## Behavior checks

`python3 tests/poll.py` passed using Bash 3.2 and real Git for:

- Shared repositories, linked worktrees, symlink aliases and subdirectories.
- Paths containing tabs and trailing newlines.
- Modified, staged renamed, deleted and untracked files; ignored files excluded.
- No redundant successful reports; failed reports retried.
- Invalid partial snapshots and empty cwd do not clear existing tokens.
- Valid empty workspace lists discard cached state.
- New nested repositories invalidate cached parent-worktree mappings.
- Dirty-to-clean transitions and exit after a definitive disabled response.
- 1,000 untracked files counted individually; observed update latency 3.228 s
  with the normal three-second sleep.

`bash -n` and `git diff --check` passed. ShellCheck was unavailable. Linux,
real Herdr rendering latency, concurrent startup and real-time disable latency
were not measured. Startup locking and the existing every-ten-cycles enablement
check are unchanged; this change addresses the first-stage polling costs and
does not introduce background-workspace throttling or a new lifecycle API.

To reproduce, run `python3 tests/poll.py --benchmark`. It also includes the
1,000-file fixture in the benchmark worktree, so absolute timings can differ
from the small-repository comparison above. Fixtures and logs remain in the
printed `/tmp/git-dirty-test-*` directory.
