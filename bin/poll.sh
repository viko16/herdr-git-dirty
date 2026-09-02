#!/usr/bin/env bash

# Poll every Herdr Space and publish a $git_dirty workspace metadata token. The
# value is "*N" for a dirty Git worktree and absent for clean/non-Git Spaces.

set -u
set -o pipefail

readonly interval_seconds=3
readonly source_id="viko16.git-dirty"
readonly herdr="${HERDR_BIN_PATH:-herdr}"
readonly state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-git-dirty}"
readonly pid_file="${1:?missing pid file}"
readonly plugin_root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$state_dir" || exit 1
cache_file="$(mktemp "$state_dir/cache.XXXXXX")" || exit 1

cleanup() {
  local recorded_pid=""
  if [ -f "$pid_file" ]; then
    IFS= read -r recorded_pid < "$pid_file" || true
  fi
  if [ "$recorded_pid" = "$$" ]; then
    rm -f "$pid_file"
  fi
  rm -f "$cache_file"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

cached_state() {
  local workspace_id="$1"
  awk -F '\t' -v id="$workspace_id" '
    $1 == id { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$cache_file"
}

report_state() {
  local workspace_id="$1"
  local state="$2"

  if [ "$state" = "clear" ]; then
    "$herdr" workspace report-metadata "$workspace_id" \
      --source "$source_id" --clear-token git_dirty >/dev/null 2>&1
  else
    "$herdr" workspace report-metadata "$workspace_id" \
      --source "$source_id" --token "git_dirty=$state" >/dev/null 2>&1
  fi
}

plugin_is_enabled() {
  local plugins enabled

  [ -f "$plugin_root/herdr-plugin.toml" ] || return 1

  # If the registry cannot be read temporarily, keep running. Exit only when
  # Herdr definitively reports that the plugin is disabled or uninstalled.
  if ! plugins="$("$herdr" plugin list --plugin "$source_id" --json 2>/dev/null)"; then
    return 0
  fi
  enabled="$(printf '%s' "$plugins" | jq -r --arg id "$source_id" '
    [ .result.plugins[]? | select(.plugin_id == $id) ][0].enabled // false
  ' 2>/dev/null)" || return 0
  [ "$enabled" = "true" ]
}

clear_all_tokens() {
  local snapshot workspace_id
  snapshot="$("$herdr" api snapshot 2>/dev/null)" || return 0

  printf '%s' "$snapshot" | jq -r '.result.snapshot.workspaces[]?.workspace_id' \
    2>/dev/null | while IFS= read -r workspace_id; do
      [ -n "$workspace_id" ] && report_state "$workspace_id" clear
    done
}

plugin_check_count=0

while :; do
  if [ "$plugin_check_count" -eq 0 ] && ! plugin_is_enabled; then
    clear_all_tokens
    exit 0
  fi
  plugin_check_count=$(( (plugin_check_count + 1) % 10 ))

  if ! snapshot="$("$herdr" api snapshot 2>/dev/null)"; then
    sleep "$interval_seconds"
    continue
  fi

  if ! printf '%s' "$snapshot" | jq -e '.result.snapshot' >/dev/null 2>&1; then
    sleep "$interval_seconds"
    continue
  fi

  next_cache="$(mktemp "$state_dir/cache.XXXXXX")" || exit 1

  while IFS= read -r -d '' workspace_id && IFS= read -r -d '' cwd; do
    # A pane may not have a cwd yet during session restore. Retry next cycle
    # instead of clearing a potentially valid token during that short race.
    [ -n "$cwd" ] || continue

    if count="$(LC_ALL=C git --no-optional-locks -C "$cwd" status \
      --porcelain=v1 --untracked-files=all 2>/dev/null | awk 'END { print NR }')"; then
      if [ "$count" -gt 0 ]; then
        state="*$count"
      else
        state="clear"
      fi
    else
      state="clear"
    fi

    if previous="$(cached_state "$workspace_id")" && [ "$previous" = "$state" ]; then
      printf '%s\t%s\n' "$workspace_id" "$state" >> "$next_cache"
      continue
    fi

    # Do not cache a failed report, so the next cycle retries it.
    if report_state "$workspace_id" "$state"; then
      printf '%s\t%s\n' "$workspace_id" "$state" >> "$next_cache"
    fi
  done < <(
    printf '%s' "$snapshot" | jq -j '
      .result.snapshot as $snapshot
      | ($snapshot.panes // []) as $panes
      | ($snapshot.workspaces // [])[]
      | .workspace_id as $workspace_id
      | ([ $panes[] | select(.workspace_id == $workspace_id and .focused) ][0]
         // [ $panes[] | select(.workspace_id == $workspace_id) ][0]) as $pane
      | $workspace_id, "\u0000", ($pane.cwd // ""), "\u0000"
    ' 2>/dev/null
  )

  mv "$next_cache" "$cache_file"
  sleep "$interval_seconds"
done
