#!/usr/bin/env bash
# Git identity, and a credential helper for git.host when GH_TOKEN or GIT_TOKEN is set.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
name="$(cfg .git.user_name)"; name="${name:-${GIT_AUTHOR_NAME:-}}"
email="$(cfg .git.user_email)"; email="${email:-${GIT_AUTHOR_EMAIL:-}}"
host="$(cfg .git.host)"; host="${host:-github.com}"

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
if [ "$host" != github.com ]; then env_export GH_HOST "$host"; fi
if [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
  git_cred_env "$host" >> "$ENV_FILE"
  # gh reads GH_ENTERPRISE_TOKEN for enterprise hosts; the reference stays literal.
  # shellcheck disable=SC2016
  if [ "$host" != github.com ]; then printf 'export GH_ENTERPRISE_TOKEN="${GH_TOKEN:-${GIT_TOKEN:-}}"\n' >> "$ENV_FILE"; fi
fi
exit 0
