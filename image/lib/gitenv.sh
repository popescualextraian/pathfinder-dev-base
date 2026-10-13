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

# git_cred_env SPEC...: export lines that make git send a token to each https://HOST, and rewrite
# git@HOST: and ssh://git@HOST/ to https (no SSH keys are mounted). SPEC is HOST, for
# ${GH_TOKEN:-$GIT_TOKEN} as x-access-token, or HOST=VAR[:USER]. The token is read when the helper
# runs; it is never written anywhere.
git_cred_env() {
  local spec host var user key helper rewrite i=0
  for spec in "$@"; do
    host="${spec%%=*}"; user=x-access-token
    # shellcheck disable=SC2016 # a variable reference for the helper, expanded when it runs
    var='GH_TOKEN:-$GIT_TOKEN'
    if [ "$spec" != "$host" ]; then
      var="${spec#*=}"
      if [ "$var" != "${var%%:*}" ]; then user="${var#*:}"; var="${var%%:*}"; fi
    fi
    key="credential.https://$host.helper"
    helper="!f() { test \"\$1\" = get && printf \"username=$user\\npassword=%s\\n\" \"\${$var}\"; }; f"
    rewrite="url.https://$host/.insteadOf"
    printf 'export GIT_CONFIG_KEY_%d=%q\nexport GIT_CONFIG_VALUE_%d=\n' "$i" "$key" "$i"
    printf 'export GIT_CONFIG_KEY_%d=%q\nexport GIT_CONFIG_VALUE_%d=%q\n' "$((i + 1))" "$key" "$((i + 1))" "$helper"
    printf 'export GIT_CONFIG_KEY_%d=%q\nexport GIT_CONFIG_VALUE_%d=%q\n' "$((i + 2))" "$rewrite" "$((i + 2))" "git@$host:"
    printf 'export GIT_CONFIG_KEY_%d=%q\nexport GIT_CONFIG_VALUE_%d=%q\n' "$((i + 3))" "$rewrite" "$((i + 3))" "ssh://git@$host/"
    i=$((i + 4))
  done
  printf 'export GIT_CONFIG_COUNT=%d\n' "$i"
}
