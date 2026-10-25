#!/usr/bin/env python3
"""Failure, timeout, cache and process-cleanup integration tests (fake Herdr)."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from poll import ROOT, Session, run


def rounds(session):
    calls = session.log.read_text().splitlines() if session.log.exists() else []
    indices = [i for i, c in enumerate(calls) if c == 'herdr api snapshot']
    return [calls[a:b] for a, b in zip(indices, indices[1:])]


def install_git_faults(session):
    wrapper = session.directory / 'bin/git'
    real = shutil.which('git')
    wrapper.write_text('#!' + sys.executable + '\n' + '''import os, signal, subprocess, sys, time
from pathlib import Path
base = Path(os.environ['TEST_DIR'])
args = sys.argv[1:]
command = args[3]
with (base / 'calls').open('a') as f:
    print('git ' + command, file=f)
fault = base / 'fault'
if fault.exists() and args[2] == (base / 'target').read_text():
    mode = fault.read_text()
    if mode == 'resolve' and command == 'rev-parse':
        sys.exit(128)
    if command == 'status':
        if mode == 'fail':
            sys.exit(1)
        if mode == 'hang':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = subprocess.Popen([sys.executable, '-c',
                'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'])
            (base / 'hung-pids').write_text(str(os.getpid()) + '\\n' + str(child.pid))
            time.sleep(60)
os.execv(''' + repr(real) + ''', ['git'] + args)
''')
    wrapper.chmod(0o755)


def assert_dead(pid):
    # macOS may briefly retain a reparented zombie; it cannot run or hold pipes.
    result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], text=True, capture_output=True)
    assert result.returncode in (0, 1) and not result.stderr, result
    assert not result.stdout.strip() or result.stdout.strip().startswith('Z'), (pid, result.stdout)


def check_normal_completion(base):
    # A successful/failing command can leave a child holding stdout open. The
    # supervisor must clean it up before reaping its own group leader, without
    # changing the command status or waiting for the full command deadline.
    for code in (0, 7, -signal.SIGUSR1):
        pidfile = base / ('normal-' + str(code))
        command = ("import os, signal, subprocess, sys; from pathlib import Path; "
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(60)']); "
            "Path(" + repr(str(pidfile)) + ").write_text("
            "str(os.getpid()) + ' ' + str(os.getpgrp()) + ' ' + str(child.pid)); "
            "print('complete', flush=True); " +
            ("os.kill(os.getpid(), " + str(-code) + ")" if code < 0 else
             "sys.exit(" + str(code) + ")"))
        started = time.monotonic()
        proc = subprocess.run(['perl', str(ROOT / 'bin/bounded.pl'), '5',
                               sys.executable, '-c', command],
                              text=True, capture_output=True, timeout=3)
        assert proc.returncode == (128 - code if code < 0 else code), proc
        assert proc.stdout == 'complete\n' and not proc.stderr, proc
        assert time.monotonic() - started < 3
        command_pid, group_pid, child_pid = map(int, pidfile.read_text().split())
        assert command_pid != group_pid  # leader is the retained supervisor
        for pid in (command_pid, group_pid, child_pid):
            assert_dead(pid)
    print('PASS normal success/error/signal status and lingering stdout-child cleanup')


def main():
    base = Path(tempfile.mkdtemp(prefix='git-dirty-reliability-', dir='/tmp'))
    check_normal_completion(base)
    bad, good, nongit = [base / name for name in ('bad', 'good', 'nongit')]
    for repo in (bad, good):
        repo.mkdir()
        run('git', 'init', '-q', str(repo))
        (repo / 'file').write_text('untracked')
    nongit.mkdir()
    nested = nongit / 'child'
    nested.mkdir()
    s = Session(base / 'failures', ROOT / 'bin/poll.sh')
    install_git_faults(s)
    (s.directory / 'target').write_text(str(bad.resolve()))
    (s.directory / 'fault').write_text('fail')
    s.set_cwds([bad, bad, good])
    s.set_tokens('0', git_dirty='*7')
    s.set_tokens('1', git_dirty='*8')
    s.start()
    try:
        s.wait_for(lambda: len(rounds(s)) >= 4)
        assert json.loads((s.tokens / '0').read_text())['git_dirty'] == '*7'
        assert json.loads((s.tokens / '1').read_text())['git_dirty'] == '*8'
        assert len(s.reports()) == 1 and 'git_dirty=*1' in s.reports()[0]
        completed = rounds(s)
        assert completed[0].count('git status') == 2  # bad once, good once
        assert all(r.count('git status') == 1 for r in completed[1:4])
        assert all(r.count('git rev-parse') == 0 for r in completed[1:4])
        (s.directory / 'fault').unlink()
        s.wait_for(lambda: len(s.reports()) == 3)
        assert s.log.read_text().splitlines().count('git rev-parse') == 3  # healthy mapping survived
        assert all(json.loads((s.tokens / str(i)).read_text())['git_dirty'] == '*1' for i in (0, 1))
        # A failed worktree identity lookup is also unknown, not clean.
        (s.directory / 'fault').write_text('resolve')
        s.set_cwds([nongit])
        s.wait_for(lambda: len(s.reports()) == 4)
        s.set_tokens('0', git_dirty='*9')
        s.set_cwds([bad])
        time.sleep(.4)
        assert json.loads((s.tokens / '0').read_text())['git_dirty'] == '*9'
    finally:
        s.stop()

    cache_script = base / 'short-cache.sh'
    cache_script.write_text((ROOT / 'bin/poll.sh').read_text().replace(
        'readonly negative_ttl_seconds=30', 'readonly negative_ttl_seconds=2'))
    s = Session(base / 'negative-cache', cache_script)
    s.set_cwds([nested, nested])
    s.start()
    try:
        s.wait_for(lambda: len(rounds(s)) >= 5)
        completed = rounds(s)
        assert completed[0].count('git rev-parse') == 1
        assert all(r.count('git rev-parse') == 0 for r in completed[1:5])
        s.wait_for(lambda: s.log.read_text().splitlines().count('git rev-parse') >= 2)
        assert s.log.read_text().splitlines().count('git rev-parse') == 2
        run('git', 'init', '-q', str(nongit))  # newly created parent repository
        (nongit / 'file').write_text('new')
        s.wait_for(lambda: len(s.reports()) == 2)
        assert all('git_dirty=*1' in r for r in s.reports())
    finally:
        s.stop()

    s = Session(base / 'timeout', ROOT / 'bin/poll.sh')
    install_git_faults(s)
    (s.directory / 'target').write_text(str(bad.resolve()))
    (s.directory / 'fault').write_text('hang')
    s.set_cwds([bad, bad, good])
    s.set_tokens('0', git_dirty='*7')
    s.set_tokens('1', git_dirty='*8')
    started = time.monotonic()
    s.start()
    try:
        s.wait_for(lambda: len(s.reports()) == 1)
        elapsed = time.monotonic() - started
        assert 4.8 <= elapsed < 8, elapsed
        assert 'report-metadata 2' in s.reports()[0]
        assert json.loads((s.tokens / '0').read_text())['git_dirty'] == '*7'
        assert json.loads((s.tokens / '1').read_text())['git_dirty'] == '*8'
        s.wait_for(lambda: len(rounds(s)) >= 3)
        completed = rounds(s)
        assert completed[0].count('git status') == 2
        assert all(r.count('git status') == 1 for r in completed[1:3])
        for pid in (s.directory / 'hung-pids').read_text().splitlines():
            assert_dead(int(pid))
        print('PASS timeout reaches healthy Space in', round(elapsed, 3), 'seconds')
    finally:
        s.stop()

    # Interrupt the watchdog itself and verify its whole command group is gone.
    pidfile = base / 'interrupt-pid'
    proc = subprocess.Popen(['perl', str(ROOT / 'bin/bounded.pl'), '5', sys.executable,
        '-c', 'import os,signal,time; from pathlib import Path; '
        'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
        'Path(' + repr(str(pidfile)) + ').write_text(str(os.getpid())); time.sleep(60)'])
    try:
        deadline = time.monotonic() + 3
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        assert pidfile.exists()
        proc.terminate()
        assert proc.wait(timeout=2) == 125
        assert_dead(int(pidfile.read_text()))
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=6)
    print('PASS failure dedup/backoff/token preservation, discovery failure, non-Git cache/git init, process cleanup; fixtures:', base)


if __name__ == '__main__':
    main()
