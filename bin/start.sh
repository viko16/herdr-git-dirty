#!/usr/bin/env bash

# Start one background poller for the current Herdr session. This script is
# intentionally safe to call on every workspace.focused event.

set -u

root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-git-dirty}"
socket_key="$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | cksum | awk '{print $1}')"
pid_file="$state_dir/poll-$socket_key.pid"
lock_file="$pid_file.flock"

mkdir -p "$state_dir" || exit 1

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "herdr-git-dirty: git is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "herdr-git-dirty: jq is required" >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  printf '%s\n' "herdr-git-dirty: perl is required" >&2
  exit 1
fi

nohup perl "$root/bin/lock.pl" "$lock_file" \
  /bin/bash "$root/bin/poll.sh" "$pid_file" >/dev/null 2>&1 &
