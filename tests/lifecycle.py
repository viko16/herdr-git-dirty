#!/usr/bin/env python3
"""Exercise startup only in an isolated fake plugin; never touch real Herdr."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError('timed out')


def main():
    with tempfile.TemporaryDirectory(prefix='git-dirty-lock-', dir='/tmp') as tmp:
        base = Path(tmp)
        (base / 'bin').mkdir()
        shutil.copy(ROOT / 'bin/lock.pl', base / 'bin/lock.pl')
        (base / 'bin/poll.sh').write_text('exec "' + sys.executable + '" "' + str(base / 'poll.py') + '" "$@"\n')
        (base / 'poll.py').write_text('''import os, sys, time
from pathlib import Path
base = Path(os.environ['HERDR_PLUGIN_ROOT'])
with (base / 'started').open('a') as f:
    print(os.getpid(), file=f, flush=True)
time.sleep(.4)  # Exercise the interval before any PID is published.
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(60)
''')
        env = dict(os.environ, HERDR_PLUGIN_ROOT=str(base),
                   HERDR_PLUGIN_STATE_DIR=str(base), HERDR_SOCKET_PATH=str(base / 'socket'))
        started = base / 'started'
        def pids():
            return [int(p) for p in started.read_text().splitlines()] if started.exists() else []
        def burst():
            children = [subprocess.Popen(['/bin/bash', str(ROOT / 'bin/start.sh')], env=env)
                        for _ in range(24)]
            for child in children:
                assert child.wait(timeout=5) == 0
        try:
            for count, sig in [(1, signal.SIGTERM), (2, signal.SIGKILL)]:
                burst()
                wait_for(lambda: len(pids()) >= count)
                # The second burst overlaps the deliberately delayed PID write.
                burst()
                time.sleep(.5)
                assert len(pids()) == count, pids()
                os.kill(pids()[-1], sig)
                time.sleep(.1)
            burst()
            wait_for(lambda: len(pids()) == 3)
            time.sleep(.5)
            assert len(pids()) == 3
        finally:
            for pid in pids():
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
    print('PASS concurrent startup, delayed PID publication, TERM/KILL lock recovery')


if __name__ == '__main__':
    main()
