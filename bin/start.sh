#!/usr/bin/env bash

# Start one background poller for the current Herdr session. This script is
# intentionally safe to call on every workspace.focused event.

set -u

root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-git-dirty}"
socket_key="$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | cksum | awk '{print $1}')"
pid_file="$state_dir/poll-$socket_key.pid"
lock_dir="$pid_file.lock"

mkdir -p "$state_dir" || exit 1

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "herdr-git-dirty: git is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "herdr-git-dirty: jq is required" >&2
  exit 1
fi

is_running() {
  local pid
  [ -f "$pid_file" ] || return 1
  IFS= read -r pid < "$pid_file" || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

is_running && exit 0

# mkdir is an atomic, portable lock on both macOS and Linux.
mkdir "$lock_dir" 2>/dev/null || exit 0
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

is_running && exit 0

nohup bash "$root/bin/poll.sh" "$pid_file" >/dev/null 2>&1 &
poll_pid=$!
printf '%s\n' "$poll_pid" > "$pid_file"
