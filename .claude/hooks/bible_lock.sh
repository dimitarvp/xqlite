#!/usr/bin/env bash
# PreToolUse hook: CLAUDE.md is a thin pointer to AGENTS.md and is never edited
# by an agent. Denies file-tool edits of it and Bash commands that write to it.
set -uo pipefail
input=$(cat)
tool=$(printf '%s' "${input}" | jq -r '.tool_name // empty')

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

case "${tool}" in
  Bash)
    cmd=$(printf '%s' "${input}" | jq -r '.tool_input.command // empty')
    redirect_re='>>?[[:space:]]*[^[:space:]]*CLAUDE\.md'
    inplace_re='(sed|perl)[[:space:]]+-[a-zA-Z]*i[^|;&]*CLAUDE\.md'
    tool_re='(^|[[:space:]|;&])(tee|mv|cp|rm|truncate|git[[:space:]]+(rm|mv))[[:space:]][^|;&]*CLAUDE\.md'
    if [[ "${cmd}" =~ ${redirect_re} ]] || [[ "${cmd}" =~ ${inplace_re} ]] || [[ "${cmd}" =~ ${tool_re} ]]; then
      deny "CLAUDE.md is locked: it stays a thin pointer to AGENTS.md; edit AGENTS.md instead"
    fi
    ;;
  *)
    path=$(printf '%s' "${input}" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    if [ -n "${path}" ] && [ "$(basename "${path}")" = "CLAUDE.md" ]; then
      deny "CLAUDE.md is locked: it stays a thin pointer to AGENTS.md; edit AGENTS.md instead"
    fi
    ;;
esac
exit 0
