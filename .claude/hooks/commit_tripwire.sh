#!/usr/bin/env bash
# PreToolUse hook on Bash: a `git commit` is allowed only when the repo being
# committed to carries a verify stamp (written by a green `mix verify`) that
# matches its working tree right now. See scripts/tree_fingerprint.exs.
set -uo pipefail
input=$(cat)
cmd=$(printf '%s' "${input}" | jq -r '.tool_input.command // empty')
commit_re='(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'
[[ "${cmd}" =~ ${commit_re} ]] || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# The repo being committed to: `git -C <dir>`, else the last `cd <dir>` before
# the commit, else the hook's working directory.
before=${cmd%%git*commit*}
dir=""
if [[ "${cmd}" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  dir=${BASH_REMATCH[1]}
elif [[ "${before}" =~ cd[[:space:]]+([^[:space:]\;\&\|]+)[^a-z]*$ ]] || [[ "${before}" =~ .*cd[[:space:]]+([^[:space:]\;\&\|]+) ]]; then
  dir=${BASH_REMATCH[1]}
fi
dir=${dir:-$(printf '%s' "${input}" | jq -r '.cwd // empty')}
dir=${dir:-${CLAUDE_PROJECT_DIR:-$PWD}}
dir=${dir/#\~/$HOME}
dir=${dir//\"/}

cd "${dir}" 2>/dev/null || deny "commit tripwire: cannot enter ${dir}"
[ -f scripts/tree_fingerprint.exs ] || exit 0
out=$(elixir scripts/tree_fingerprint.exs --check 2>&1) || deny "commit tripwire (${dir}): ${out}"
exit 0
