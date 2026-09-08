#!/usr/bin/env python3
"""Isolated integration checks and optional 60-second baseline comparison."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from collections import Counter


ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, text=True).strip()


class Session:
    def __init__(self, directory, script, fast=True):
        self.directory = directory
        directory.mkdir()
        self.log = directory / 'calls'
        self.snapshot = directory / 'snapshot.json'
        self.snapshot.write_text('{"result":{"snapshot":{"workspaces":[],"panes":[]}}}')
        wrappers = directory / 'bin'
        wrappers.mkdir()
        for name in ('git', 'jq', 'awk', 'mktemp', 'mv'):
            real = shutil.which(name)
            wrapper = wrappers / name
            label = 'git ${4}' if name == 'git' else name
            wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "' + label + '" >> "$TEST_DIR/calls"\nexec "' + real + '" "$@"\n')
            wrapper.chmod(0o755)
        herdr = wrappers / 'herdr'
        herdr.write_text('''#!/bin/bash
printf '%s\\n' "herdr $*" >> "$TEST_DIR/calls"
case "$1 $2" in
  'plugin list')
    if [ -f "$TEST_DIR/disabled" ]; then enabled=false; else enabled=true; fi
    printf '{"result":{"plugins":[{"plugin_id":"viko16.git-dirty","enabled":%s}]}}' "$enabled" ;;
  'api snapshot') cat "$TEST_DIR/snapshot.json" ;;
  'workspace report-metadata')
    [ ! -f "$TEST_DIR/fail-report" ] || exit 1
    printf '%s\\n' "$*" >> "$TEST_DIR/reports" ;;
esac
''')
        herdr.chmod(0o755)
        if fast:
            sleeper = wrappers / 'sleep'
            sleeper.write_text('#!/bin/bash\nexec /bin/sleep 0.05\n')
            sleeper.chmod(0o755)
        self.env = dict(os.environ, PATH=str(wrappers) + ':' + os.environ['PATH'],
                        TEST_DIR=str(directory), HERDR_BIN_PATH=str(herdr),
                        HERDR_PLUGIN_ROOT=str(ROOT), HERDR_PLUGIN_STATE_DIR=str(directory))
        self.script = script
        self.process = None

    def set_cwds(self, cwds):
        self.set_snapshot({'result': {'snapshot': {
            'workspaces': [{'workspace_id': str(i)} for i in range(len(cwds))],
            'panes': [{'workspace_id': str(i), 'cwd': str(cwd), 'focused': True}
                      for i, cwd in enumerate(cwds)]}}})

    def set_snapshot(self, value):
        pending = self.directory / 'pending.json'
        pending.write_text(json.dumps(value))
        pending.replace(self.snapshot)

    def start(self):
        self.stderr = (self.directory / 'stderr').open('w')
        self.process = subprocess.Popen(['/bin/bash', str(self.script), str(self.directory / 'pid')],
                                        env=self.env, stderr=self.stderr)

    def reports(self):
        path = self.directory / 'reports'
        return path.read_text().splitlines() if path.exists() else []

    def wait_for(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            assert self.process.poll() is None, (self.directory / 'stderr').read_text()
            time.sleep(.03)
        raise AssertionError('timeout: ' + str(self.directory) + '\n' + '\n'.join(self.reports()))

    def stop(self):
        self.process.terminate()
        _, status, usage = os.wait4(self.process.pid, 0)
        self.process.returncode = os.waitstatus_to_exitcode(status)
        self.stderr.close()
        assert not (self.directory / 'stderr').read_text(), (self.directory / 'stderr').read_text()
        return usage.ru_utime + usage.ru_stime


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()
    # Leave fixtures in /tmp for inspection; no user repositories or sessions.
    base = Path(tempfile.mkdtemp(prefix='git-dirty-test-', dir='/tmp'))
    repo = base / 'repo\twith\nnewline\n'
    repo.mkdir()
    run('git', 'init', '-q', str(repo))
    run('git', '-C', str(repo), 'config', 'user.email', 'test@example.com')
    run('git', '-C', str(repo), 'config', 'user.name', 'Test')
    for name in ('modified', 'deleted', 'renamed', '.gitignore'):
        (repo / name).write_text('ignored\n')
    run('git', '-C', str(repo), 'add', '.')
    run('git', '-C', str(repo), 'commit', '-qm', 'fixture')
    linked = base / 'linked'
    run('git', '-C', str(repo), 'worktree', 'add', '-qb', 'linked', str(linked))
    (repo / 'modified').write_text('changed')
    (repo / 'deleted').unlink()
    run('git', '-C', str(repo), 'mv', 'renamed', 'new-name')
    (repo / 'untracked\nfile').write_text('new')
    (repo / 'ignored').write_text('ignored')
    subdir = repo / 'subdir'
    subdir.mkdir()
    alias = base / 'alias'
    alias.symlink_to(repo, target_is_directory=True)
    script = ROOT / 'bin/poll.sh'
    s = Session(base / 'checks', script)
    s.set_cwds([repo, subdir, alias, linked, base, ''])
    s.start()
    try:
        s.wait_for(lambda: len(s.reports()) >= 5)
        assert all('--token git_dirty=*4' in line for line in s.reports()[:3])
        assert all('--clear-token' in line for line in s.reports()[3:5])
        time.sleep(.3)
        assert len(s.reports()) == 5
        calls = s.log.read_text().splitlines()
        assert sum('rev-parse' in c for c in calls if c.startswith('git')) >= 4
        assert not any(c in ('awk', 'mktemp', 'mv') for c in calls)
        rounds = [i for i, call in enumerate(calls) if call == 'herdr api snapshot']
        assert len(rounds) >= 2
        for start, end in zip(rounds, rounds[1:]):
            assert calls[start:end].count('git status') == 2
        # Invalid/partial snapshots and empty cwd must not clear existing tokens.
        s.set_snapshot({'result': {'snapshot': {'workspaces': [{'workspace_id': '0'}, {}], 'panes': []}}})
        time.sleep(.2)
        assert len(s.reports()) == 5
        s.set_cwds([''])
        time.sleep(.2)
        assert len(s.reports()) == 5
        s.set_cwds([repo])
        (s.directory / 'fail-report').touch()
        (repo / 'extra').write_text('extra')
        time.sleep(.2)
        assert len(s.reports()) == 5
        (s.directory / 'fail-report').unlink()
        s.wait_for(lambda: any('git_dirty=*5' in r for r in s.reports()))
        run('git', '-C', str(repo), 'add', '.')
        run('git', '-C', str(repo), 'commit', '-qm', 'clean')
        s.wait_for(lambda: '--clear-token' in s.reports()[-1])
        # A new repository inside a cached worktree must get its own identity.
        s.set_cwds([subdir])
        time.sleep(.2)
        run('git', 'init', '-q', str(subdir))
        (subdir / 'new').write_text('nested')
        s.wait_for(lambda: 'git_dirty=*1' in s.reports()[-1])
        s.set_cwds([])
        time.sleep(.2)
        before = len(s.reports())
        s.set_cwds([subdir])
        s.wait_for(lambda: len(s.reports()) > before)
        (s.directory / 'disabled').touch()
        s.wait_for(lambda: s.process.poll() is not None)
    finally:
        if s.process.poll() is None:
            s.stop()
        else:
            s.stderr.close()
            assert not (s.directory / 'stderr').read_text()
    print('PASS integration (Bash 3.2); fixtures:', base, flush=True)
    latency = Session(base / 'latency', script, fast=False)
    latency.set_cwds([linked])
    latency.start()
    try:
        latency.wait_for(lambda: bool(latency.reports()))
        started = time.monotonic()
        bulk = linked / 'bulk'
        bulk.mkdir()
        for i in range(1000):
            (bulk / str(i)).write_text('untracked')
        latency.wait_for(lambda: 'git_dirty=*1000' in latency.reports()[-1])
        print('1000 untracked files; update latency seconds:', round(time.monotonic() - started, 3), flush=True)
    finally:
        latency.stop()
    if args.benchmark:
        baseline = base / 'baseline.sh'
        baseline.write_text(run('git', '-C', str(ROOT), 'show', 'e936466:bin/poll.sh') + '\n')
        for label, target in [('baseline', baseline), ('optimized', script)]:
            session = Session(base / label, target, fast=False)
            session.set_cwds([repo, repo, repo, repo, linked])
            session.start()
            time.sleep(60)
            cpu = session.stop()
            counts = Counter()
            for call in session.log.read_text().splitlines():
                if call.startswith('git '):
                    counts[call] += 1
                elif call.startswith('herdr '):
                    counts[' '.join(call.split()[:3])] += 1
                elif call in ('jq', 'awk', 'mktemp', 'mv'):
                    counts[call.split()[0]] += 1
            print(label, dict(counts), 'tree CPU seconds:', round(cpu, 3), flush=True)


if __name__ == '__main__':
    main()
