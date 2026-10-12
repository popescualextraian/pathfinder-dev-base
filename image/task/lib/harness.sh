#!/usr/bin/env bash
# Per-harness facts for the hooks and the gate. Source after lib/common.sh.

# harness_hook_events HARNESS: "<HarnessEventName> <internal name>" per line (spec §13: confirmed under ACP).
harness_hook_events() {
  case "$1" in
    claude) printf '%s\n' 'SessionStart sessionstart' 'UserPromptSubmit userpromptsubmit' \
              'PreToolUse pretooluse' 'PostToolUse posttooluse' 'Stop stop' 'SessionEnd sessionend' ;;
    copilot) printf '%s\n' 'sessionStart sessionstart' 'userPromptSubmitted userpromptsubmit' \
              'preToolUse pretooluse' 'postToolUse posttooluse' 'agentStop stop' ;;
  esac
}

copilot_hooks_file() { printf '%s\n' "$(copilot_dir)/hooks/agentic.json"; }
copilot_instructions_file() { printf '%s\n' "$(copilot_dir)/copilot-instructions.md"; }

# payload_* P: a field of a hook payload from either harness; empty when absent or not JSON.
_pf() { jq -r "$1 // empty" <<<"$2" 2>/dev/null || true; }
payload_session() { _pf '.session_id // .sessionId' "$1"; }
payload_tool()    { _pf '.tool_name // .toolName' "$1"; }
payload_command() { _pf '.tool_input.command // (.toolArgs | if type == "object" then .command elif type == "string" then (fromjson? | .command?) else null end)' "$1"; }

is_shell_tool() { case "$1" in Bash|bash|shell) return 0 ;; *) return 1 ;; esac; }
is_chooser_tool() { case "$1" in AskUserQuestion|ExitPlanMode|ask_user|exit_plan_mode) return 0 ;; *) return 1 ;; esac; }

# harness_block HARNESS REASON: prints the refusal in the harness's format; returns the hook's exit code.
# Copilot drops a reason given with exit 2, so it gets its JSON deny decision on stdout and exit 0.
harness_block() {
  case "$1" in
    copilot) jq -cn --arg r "$2" '{permissionDecision: "deny", permissionDecisionReason: $r}'; return 0 ;;
    *) printf '%s\n' "$2" >&2; return 2 ;;
  esac
}

# harness_resume_argv HARNESS SESSION: the interactive command line that resumes SESSION, in ARGV.
# shellcheck disable=SC2034  # ARGV is read by the caller
harness_resume_argv() {
  case "$1" in
    claude) ARGV=(claude --dangerously-skip-permissions --resume "$2") ;;
    copilot) ARGV=(copilot --allow-all "--resume=$2") ;;
    *) say "unknown harness $1"; return 1 ;;
  esac
}
