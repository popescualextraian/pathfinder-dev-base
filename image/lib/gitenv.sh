#!/usr/bin/env bash
# Git credential wiring. Source after common.sh.

# url_host URL: the host part of an https, ssh or scp-style URL.
url_host() { sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##' <<<"$1"; }

# git_cred_env HOST: export lines that make git send ${GH_TOKEN:-$GIT_TOKEN} to https://HOST.
# The token is read when the helper runs; it is never written anywhere.
git_cred_env() {
  local key="credential.https://$1.helper"
  # shellcheck disable=SC2016 # expanded by git's shell when the helper runs
  local helper='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "${GH_TOKEN:-$GIT_TOKEN}"; }; f'
  printf 'export GIT_CONFIG_COUNT=2\n'
  printf 'export GIT_CONFIG_KEY_0=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_0=\n'
  printf 'export GIT_CONFIG_KEY_1=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_1=%q\n' "$helper"
}
