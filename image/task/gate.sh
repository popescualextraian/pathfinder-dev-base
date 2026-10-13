#!/usr/bin/env bash
# gate.sh: PreToolUse check of shell commands for outward-facing actions. Payload on stdin; exit 0
# allows, exit 2 blocks with the reason on stderr. A guard against slips inside permission-bypass
# mode, not a sandbox. Allowed actions come from the task's state.json, else from
# AGENTIC_ALLOWED_ACTIONS (comma-separated), else none. Merges and protected environments
# (AGENTIC_GATE_PROTECTED, default "prod production") are always blocked.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/task/lib/harness.sh"

payload="$(cat)"
is_shell_tool "$(payload_tool "$payload")" || exit 0
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0

state="${AGENTIC_TASK_DIR:-/task}/state.json"
if [ -f "$state" ]; then
  allowed="$(jq -r '.allowed_actions[]?' "$state" 2>/dev/null || true)"
else
  allowed="$(tr ',' '\n' <<<"${AGENTIC_ALLOWED_ACTIONS:-}" | tr -d '[:blank:]')"
fi
prot_re="$(tr -s ' ,' '\n' <<<"${AGENTIC_GATE_PROTECTED:-prod production}" | sed '/^$/d' | paste -sd'|')"
deploy_target="$(grep -oE '^deploy:[A-Za-z0-9_.-]+$' <<<"$allowed" | head -1 | cut -d: -f2)"

has()  { grep -qxF -- "$1" <<<"$allowed"; }
deny() { echo "agentic gate: $1; not allowed in this task. Use agentic-ask if you need it." >&2; exit 2; }
# names RE TEXT: TEXT holds RE as a whole word (letters, digits, _ and - bound a word).
names() { grep -Eiq -- "(^|[^A-Za-z0-9_-])($1)([^A-Za-z0-9_-]|$)" <<<"$2"; }

# deploy_like SEGMENT: needs deploy:<target>, the segment must name the target, and no protected word.
deploy_like() {
  if names "$prot_re" "$1"; then deny "deploying to a protected environment is never allowed"; fi
  [ -n "$deploy_target" ] || deny "deploy is not in allowed_actions"
  if grep -Eixq -- "$prot_re" <<<"$deploy_target"; then deny "a protected environment cannot be a deploy target"; fi
  names "$deploy_target" "$1" || deny "the deploy must name the allowed target $deploy_target"
}

# skip_opts "VALUED OPTIONS": moves i past options; the listed ones take a value.
skip_opts() {
  local valued=" $1 "
  while [ "$i" -lt "$n" ]; do
    case "${words[$i]}" in
      --*=*) i=$((i + 1)) ;;
      -*) if [[ "$valued" == *" ${words[$i]} "* ]]; then i=$((i + 2)); else i=$((i + 1)); fi ;;
      *) break ;;
    esac
  done
}
# next_tool: the command word at i (path stripped) into tool; i moves past it.
next_tool() { tool="${words[$i]:-}"; tool="${tool#\\}"; tool="${tool##*/}"; i=$((i + 1)); }

# Line continuations join; command substitutions and subshells split like ; does.
cmd="${cmd//\\$'\n'/ }"
segments="$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||;|\||\$\(|`|\(|\))/\n/g' \
  | sed -E 's/([^>&])&([^>&]|$)/\1\n\2/g')"

while IFS= read -r seg; do
  [ -n "${seg// /}" ] || continue
  # Quotes are dropped after splitting: a quoted ; still splits, which only makes the gate stricter.
  seg="${seg//[\'\"]/}"

  if [ -n "$prot_re" ]; then
    if grep -Eiq -- "(^|[^A-Za-z0-9_])[A-Z_]*WORKSPACE=($prot_re)([^A-Za-z0-9_-]|$)" <<<"$seg" \
       || grep -Eiq -- "--(profile|namespace|stage|context|env)[= ][^[:space:]]*($prot_re)" <<<"$seg" \
       || grep -Eiq -- "workspace[[:space:]]+select[[:space:]]+($prot_re)([^A-Za-z0-9_-]|$)" <<<"$seg"; then
      deny "a protected environment ($(tr '|' ' ' <<<"$prot_re")) is never allowed"
    fi
  fi

  # shellcheck disable=SC2206 # intentional word split; quotes are not honoured
  words=($seg)
  n=${#words[@]}
  i=0
  # VAR=value, sudo and env (with their options) before the command
  while [ "$i" -lt "$n" ]; do
    w="${words[$i]#\\}"; w="${w##*/}"
    case "${words[$i]}" in [A-Za-z_]*=*) i=$((i + 1)); continue ;; esac
    case "$w" in
      then|do|else|elif|if|while|until|'{'|'}'|'!') i=$((i + 1)) ;;
      sudo) i=$((i + 1)); skip_opts "-u -g -h -p -C -D -U -T" ;;
      env) i=$((i + 1)); skip_opts "-u -C -S" ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  case "${words[$i]}" in -*) continue ;; esac
  next_tool
  # wrappers that run another command: look at that command
  while :; do
    case "$tool" in
      bash|sh|zsh|dash)
        while [ "$i" -lt "$n" ] && [[ "${words[$i]}" != -c ]] && [[ "${words[$i]}" != -[a-z]*c* ]]; do i=$((i + 1)); done
        [ "$i" -lt "$n" ] || break
        i=$((i + 1)); next_tool ;;
      timeout) skip_opts "-s -k --signal --kill-after"; i=$((i + 1)); next_tool ;;
      eval|exec|command|nohup|time|xargs|npx|nice) skip_opts "-n"; next_tool ;;
      *) break ;;
    esac
  done

  case "$tool" in
    git)
      skip_opts "-C -c --git-dir --work-tree --namespace"
      if [ "${words[$i]:-}" = push ]; then has push || deny "git push is not in allowed_actions"; fi ;;
    gh|glab)
      skip_opts "-R --repo"
      sub="${words[$i]:-}"; sub2="${words[$((i + 1))]:-}"
      if [ "$sub" = api ] && [[ "$seg" == */merge* ]]; then deny "merging is never allowed"; fi
      if [ "$sub" = pr ] || [ "$sub" = mr ]; then
        case "$sub2" in
          merge) deny "merging is never allowed" ;;
          create) has open-pr || deny "opening a pull request is not in allowed_actions" ;;
        esac
      fi ;;
    terraform|tofu)
      skip_opts ""
      case "${words[$i]:-}" in
        apply|destroy) deploy_like "$seg" ;;
        workspace) [ "${words[$((i + 1))]:-}" = select ] && deploy_like "$seg" ;;
      esac ;;
    helm)
      skip_opts "-n --namespace --kube-context"
      case "${words[$i]:-}" in install|upgrade|uninstall|rollback|delete) deploy_like "$seg" ;; esac ;;
    kubectl|oc)
      skip_opts "-n --namespace --context --cluster -l -f"
      case "${words[$i]:-}" in
        rollout) case "${words[$((i + 1))]:-}" in status|history) ;; *) deploy_like "$seg" ;; esac ;;
        apply|create|delete|patch|replace|scale|set|edit) deploy_like "$seg" ;;
      esac ;;
    npm|pnpm|yarn)
      skip_opts ""
      case "${words[$i]:-}" in
        run|run-script) i=$((i + 1)); skip_opts "" ;;
      esac
      script="${words[$i]:-}"
      case "${script,,}" in *deploy*|*apply*|*destroy*) deploy_like "$seg" ;; esac ;;
    cdk) skip_opts ""; case "${words[$i]:-}" in deploy|destroy) deploy_like "$seg" ;; esac ;;
    sam) skip_opts ""; case "${words[$i]:-}" in deploy|delete) deploy_like "$seg" ;; esac ;;
    serverless|sls) skip_opts ""; case "${words[$i]:-}" in deploy|remove) deploy_like "$seg" ;; esac ;;
    az) skip_opts ""; [ "${words[$i]:-}" = deployment ] && deploy_like "$seg" ;;
    aws)
      skip_opts "--profile --region --output --endpoint-url --query"
      if [ "${words[$i]:-}" = cloudformation ]; then
        case "${words[$((i + 1))]:-}" in deploy|create-stack|update-stack|delete-stack) deploy_like "$seg" ;; esac
      fi ;;
    make)
      while [ "$i" -lt "$n" ]; do
        case "${words[$i]}" in
          -C|-f|-j|-I|-o|-W) i=$((i + 2)) ;;
          -*|*=*) i=$((i + 1)) ;;
          *) case "${words[$i],,}" in *deploy*|*apply*|*destroy*) deploy_like "$seg" ;; esac; i=$((i + 1)) ;;
        esac
      done ;;
  esac
done <<<"$segments"
exit 0
