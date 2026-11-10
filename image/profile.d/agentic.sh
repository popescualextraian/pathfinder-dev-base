#!/usr/bin/env bash
# Shell helpers for every interactive shell. Sourced from /etc/profile.d and /etc/bash.bashrc.

# use-tool NAME VERSION: put another installed version of a preset first in this shell.
use-tool() {
  local name="${1:-}" v="${2:-}" tools="${AGENTIC_DIR:-/opt/agentic}/tools" line
  if [ -z "$name" ] || [ -z "$v" ]; then echo "usage: use-tool NAME VERSION" >&2; return 2; fi
  if [ ! -f "$tools/$name.sh" ]; then echo "use-tool: unknown tool $name" >&2; return 1; fi
  if ! bash "$tools/$name.sh" check "$v" >/dev/null 2>&1; then
    echo "use-tool: $name $v is not installed (add it to agentic.yaml and run agentic build)" >&2
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "${line%%=*}" = PATH ]; then export PATH="${line#PATH=}:$PATH"; else export "${line?}"; fi
  done < <(bash "$tools/$name.sh" env "$v")
}
use-java() { use-tool java "$@"; }
use-node() { use-tool node "$@"; }

# agentic_ssh_env FILE: an SSH session starts with a fresh environment, so take the container's from
# PID 1's NUL-separated environ (as docker exec would have it). Nothing is written to a file. PATH
# replaces sshd's default; anything else the session already set stays.
agentic_ssh_env() {
  local kv k
  [ -r "$1" ] || return 0
  while IFS= read -r -d '' kv; do
    k="${kv%%=*}"
    case "$k" in HOME|HOSTNAME|PWD|SHLVL|TERM|''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; PATH) ;; *) [ -z "${!k+x}" ] || continue ;; esac
    export "${kv?}"
  done < "$1"
}
[ -z "${SSH_CONNECTION:-}" ] || agentic_ssh_env "${AGENTIC_PID1_ENVIRON:-/proc/1/environ}"
