#!/usr/bin/env bash
# Git credential wiring. Source after common.sh.

# url_host URL: the host part of an https, ssh or scp-style URL.
url_host() { sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##' <<<"$1"; }

# redact_url [TEXT]: TEXT (or stdin) with the userinfo of every scheme://user:pass@ URL masked.
redact_url() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$*" | redact_url; return; fi
  sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

# git_clone URL DEST [ARGS...]: a quiet clone that never prompts; git's messages are redacted.
git_clone() {
  local url="$1" dest="$2" err rc
  shift 2
  err="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git clone --quiet "$@" "$url" "$dest" 2>&1)"
  rc=$?
  if [ -n "$err" ]; then redact_url "$err" >&2; fi
  return "$rc"
}

# git_cred_env HOST: export lines that make git send ${GH_TOKEN:-$GIT_TOKEN} to https://HOST, and
# rewrite git@HOST: and ssh://git@HOST/ to https (no SSH keys are mounted). The token is read
# when the helper runs; it is never written anywhere.
git_cred_env() {
  local key="credential.https://$1.helper"
  # shellcheck disable=SC2016 # expanded by git's shell when the helper runs
  local helper='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "${GH_TOKEN:-$GIT_TOKEN}"; }; f'
  local rewrite="url.https://$1/.insteadOf"
  printf 'export GIT_CONFIG_COUNT=4\n'
  printf 'export GIT_CONFIG_KEY_0=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_0=\n'
  printf 'export GIT_CONFIG_KEY_1=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_1=%q\n' "$helper"
  printf 'export GIT_CONFIG_KEY_2=%q\n' "$rewrite"
  printf 'export GIT_CONFIG_VALUE_2=%q\n' "git@$1:"
  printf 'export GIT_CONFIG_KEY_3=%q\n' "$rewrite"
  printf 'export GIT_CONFIG_VALUE_3=%q\n' "ssh://git@$1/"
}
