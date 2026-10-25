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
# Index zero is a sentinel, keeping empty arrays compatible with Bash 3.2 -u.
mapped_cwds=("")
mapped_roots=("")

cleanup() {
  local recorded_pid=""
  if [ -f "$pid_file" ]; then
    IFS= read -r recorded_pid < "$pid_file" || true
  fi
  if [ "$recorded_pid" = "$$" ]; then
    rm -f "$pid_file"
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP
printf '%s\n' "$$" > "$pid_file" || exit 1

find_index() {
  local needle="$1" item
  shift
  found_index=0
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
    found_index=$((found_index + 1))
  done
  return 1
}

resolve_root() {
  local cwd="$1" candidate path
  root=""
  if find_index "$cwd" "${mapped_cwds[@]}"; then
    candidate="${mapped_roots[$found_index]}"
    path="$cwd"
    # Detect removed repositories and newly created nested repositories without
    # another Git process. Never key linked worktrees by their common directory.
    while [ "$path" != "$candidate" ] && [ "$path" != / ]; do
      [ -e "$path/.git" ] && break
      path="${path%/*}"
      [ -n "$path" ] || path=/
    done
    if [ "$path" = "$candidate" ] && [ -e "$candidate/.git" ]; then
      root="$candidate"
      return
    fi
  fi
  root="$(git --no-optional-locks -C "$cwd" rev-parse --show-toplevel 2>/dev/null && printf '.')" || return 1
  root="${root%.}"
  root="${root%$'\n'}"
  # Canonicalize symlinks so different spellings share the same scan.
  root="$(cd -P "$root" && printf '%s.' "$PWD")" || return 1
  root="${root%.}"
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

  workspace_ids=("")
  workspace_cwds=("")
  workspace_tokens=("")
  parsed=false
  while IFS= read -r -d '' workspace_id && IFS= read -r -d '' cwd && IFS= read -r -d '' token; do
    if [ "$workspace_id" = "" ]; then
      parsed=true
      break
    fi
    workspace_ids+=("$workspace_id")
    workspace_cwds+=("$cwd")
    workspace_tokens+=("$token")
  done < <(
    printf '%s' "$snapshot" | jq -j '
      .result.snapshot
      | if type != "object" or (.workspaces | type) != "array"
          or ((.panes // []) | type) != "array"
        then error("invalid snapshot") else . end
      | . as $snapshot
      | ($snapshot.panes // []) as $panes
      | $snapshot.workspaces[]
      | .workspace_id as $workspace_id
      | (.tokens.git_dirty // "") as $token
      | ([ $panes[] | select(.workspace_id == $workspace_id and .focused) ][0]
         // [ $panes[] | select(.workspace_id == $workspace_id) ][0]) as $pane
      | ($pane.cwd // "") as $cwd
      | if ($workspace_id | type) != "string" or $workspace_id == ""
          or ($workspace_id | contains("\u0000"))
          or ($cwd | type) != "string" or ($cwd | contains("\u0000"))
          or ($token | type) != "string" or ($token | contains("\u0000"))
        then error("invalid workspace")
        else $workspace_id, "\u0000", $cwd, "\u0000", $token, "\u0000" end
    ' 2>/dev/null && printf '\0\0\0'
  )
  # The success sentinel carries jq failure across process substitution. Discard
  # partial output on failure without modifying any previously reported state.
  if [ "$parsed" != true ]; then
    sleep "$interval_seconds"
    continue
  fi

  next_cwds=("")
  next_roots=("")
  scanned_roots=("")
  scanned_states=("")
  for ((i=1; i<${#workspace_ids[@]}; i++)); do
    workspace_id="${workspace_ids[$i]}"
    cwd="${workspace_cwds[$i]}"
    # A pane may not have a cwd yet during session restore. Retry next cycle
    # instead of clearing a potentially valid token during that short race.
    [ -n "$cwd" ] || continue

    state=clear
    # Appending a marker preserves cwd paths ending in newlines through command
    # substitution, which otherwise strips trailing newlines.
    if canonical="$(cd -P "$cwd" 2>/dev/null && printf '%s.' "$PWD")"; then
      cwd="${canonical%.}"
      if find_index "$cwd" "${next_cwds[@]}"; then
        root="${next_roots[$found_index]}"
      elif resolve_root "$cwd"; then
        next_cwds+=("$cwd")
        next_roots+=("$root")
      else
        root=""
        next_cwds+=("$cwd")
        next_roots+=("")
      fi
      if [ -n "$root" ]; then
        if find_index "$root" "${scanned_roots[@]}"; then
          state="${scanned_states[$found_index]}"
        elif count="$(LC_ALL=C git --no-optional-locks -C "$root" status \
          --porcelain=v1 --untracked-files=all 2>/dev/null | awk 'END { print NR }')"; then
          [ "$count" -eq 0 ] || state="*$count"
          scanned_roots+=("$root")
          scanned_states+=("$state")
        else
          # Force identity resolution after a failed scan.
          mapped_cwds=("")
          next_cwds=("")
          next_roots=("")
        fi
      fi
    fi

    # Server tokens are ephemeral across restarts, even if this poller survives.
    # Compare the current snapshot rather than trusting a previous report.
    token="${workspace_tokens[$i]}"
    if { [ "$state" = clear ] && [ -z "$token" ]; } ||
       { [ "$state" != clear ] && [ "$token" = "$state" ]; }; then
      continue
    fi

    # A failed report leaves a mismatch for the next cycle to retry.
    report_state "$workspace_id" "$state"
  done

  mapped_cwds=("${next_cwds[@]}")
  mapped_roots=("${next_roots[@]}")
  sleep "$interval_seconds"
done
