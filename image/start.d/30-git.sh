#!/usr/bin/env bash
# Git identity and GH_HOST. Identity from GIT_AUTHOR_* (.env, or the runner) wins over git.user_*.
# Credentials are not set here: GIT_CONFIG_* in .env reach every process (see .env.example).
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
name="${GIT_AUTHOR_NAME:-$(cfg .git.user_name)}"
email="${GIT_AUTHOR_EMAIL:-$(cfg .git.user_email)}"
host="$(cfg .git.host)"; host="${host:-github.com}"

if [ "$check" = 1 ]; then
  rc=0
  if [ -n "$name" ] && [ "$(git config --global user.name 2>/dev/null)" != "$name" ]; then say "git user.name is not set"; rc=2; fi
  if [ -z "$name$email" ]; then say "no git identity: set GIT_AUTHOR_NAME/EMAIL in .agentic/.env or git.user_name/user_email"; rc=2; fi
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
exit 0
