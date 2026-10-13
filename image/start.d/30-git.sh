#!/usr/bin/env bash
# Git identity, and a credential helper for each git host with a token: git.hosts entries with their
# own variable, and git.host with GH_TOKEN or GIT_TOKEN. Tokens are referenced, never written.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
name="$(cfg .git.user_name)"; name="${name:-${GIT_AUTHOR_NAME:-}}"
email="$(cfg .git.user_email)"; email="${email:-${GIT_AUTHOR_EMAIL:-}}"
host="$(cfg .git.host)"; host="${host:-github.com}"
# git.hosts as host<TAB>kind<TAB>VAR lines
mapfile -t entries < <(jq -r '.git.hosts // {} | to_entries[]
  | [.key, (.value.kind // "github"), (.value.token | ltrimstr("${") | rtrimstr("}"))] | @tsv' "$RESOLVED" 2>/dev/null)

if [ "$check" = 1 ]; then
  rc=0
  if [ -n "$name" ] && [ "$(git config --global user.name 2>/dev/null)" != "$name" ]; then say "git user.name is not set"; rc=2; fi
  if [ -z "$name$email" ]; then say "no git identity: set git.user_name/user_email or GIT_AUTHOR_NAME/EMAIL"; rc=2; fi
  exit "$rc"
fi

if [ -n "$name" ]; then
  git config --global user.name "$name"
  env_export GIT_AUTHOR_NAME "$name"; env_export GIT_COMMITTER_NAME "$name"
fi
if [ -n "$email" ]; then
  git config --global user.email "$email"
  env_export GIT_AUTHOR_EMAIL "$email"; env_export GIT_COMMITTER_EMAIL "$email"
fi

specs=(); shown=(); host_kind=github; host_ref=""; listed=0; gitlab=0
for e in "${entries[@]}"; do
  IFS=$'\t' read -r h kind var <<<"$e"
  if [ "$h" = "$host" ]; then listed=1; host_kind="$kind"; fi
  [ -n "$(token "$var")" ] || continue
  user=x-access-token; [ "$kind" = gitlab ] && user=oauth2
  specs+=("$h=$var:$user"); shown+=("$h=$var")
  if [ "$h" = "$host" ]; then host_ref="\${$var:-}"; fi
  # glab takes one default host: the first gitlab entry with a token
  if [ "$kind" = gitlab ] && [ "$gitlab" = 0 ]; then
    gitlab=1
    env_export GITLAB_HOST "https://$h"
    # shellcheck disable=SC2016 # a reference, expanded when the env file is sourced
    printf 'export GITLAB_TOKEN="${%s:-}"\n' "$var" >> "$ENV_FILE"
  fi
done
if [ "$listed" = 0 ] && [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then v=GH_TOKEN; else v=GIT_TOKEN; fi
  specs=("$host" "${specs[@]}"); shown=("$host=$v" "${shown[@]}")
  # shellcheck disable=SC2016 # a reference, expanded when the env file is sourced
  host_ref='${GH_TOKEN:-${GIT_TOKEN:-}}'
fi

if [ "$host" != github.com ] && [ "$host_kind" = github ]; then
  env_export GH_HOST "$host"
  # gh reads GH_ENTERPRISE_TOKEN for enterprise hosts; the reference stays literal.
  if [ -n "$host_ref" ]; then printf 'export GH_ENTERPRISE_TOKEN="%s"\n' "$host_ref" >> "$ENV_FILE"; fi
fi
if [ "${#specs[@]}" -gt 0 ]; then
  mkdir -p "$AGENTIC_STATE"
  git_cred_env "${specs[@]}" >> "$ENV_FILE"
  env_export AGENTIC_GIT_HOSTS "${shown[*]}"
fi
exit 0
