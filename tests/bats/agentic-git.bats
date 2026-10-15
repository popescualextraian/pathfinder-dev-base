#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_WORK/.agentic"
  git init -q "$AGENTIC_WORK"
  E="$AGENTIC_WORK/.agentic/.env"
  AG="$REPO_ROOT/image/bin/agentic-git"
  unset GH_TOKEN GITLAB_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  # a git in front of the real one: ls-remote logs what it was given and answers LSREMOTE_RC
  local real; real="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = ls-remote ]; then
  { echo "args: \$*"; env | grep -E '^(GIT_CONFIG_|GIT_TERMINAL_PROMPT|GH_TOKEN|GITLAB_TOKEN)' | sort; } > "$BATS_TEST_TMPDIR/lsremote.log"
  [ "\${LSREMOTE_RC:-0}" = 0 ] || echo "fatal: Authentication failed for 'https://x:ghp_leak@github.com/'" >&2
  exit "\${LSREMOTE_RC:-0}"
fi
exec "$real" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

origin() { git -C "$AGENTIC_WORK" remote add origin "$1"; }
envval() { sed -n "s/^$1=//p" "$E"; }

@test "login for a GitHub origin writes a helper for GH_TOKEN scoped to github.com" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=ghp_secretvalue\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  [ "$(envval GIT_CONFIG_COUNT)" = 2 ]
  [ "$(envval GIT_CONFIG_KEY_0)" = credential.https://github.com.helper ]
  [ "$(envval GIT_CONFIG_VALUE_0)" = "" ]
  [ "$(envval GIT_CONFIG_KEY_1)" = credential.https://github.com.helper ]
  [ "$(envval GIT_CONFIG_VALUE_1)" = '!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f' ]
  [[ "$output" != *ghp_secretvalue* ]]
  [ "$(grep -c '^GH_TOKEN=' "$E")" = 1 ]
}

@test "login for a GitLab host uses oauth2 and GITLAB_TOKEN" {
  origin https://gitlab.example.com/team/api.git
  printf 'GITLAB_TOKEN=glpat_x\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  [ "$(envval GIT_CONFIG_KEY_1)" = credential.https://gitlab.example.com.helper ]
  [[ "$(envval GIT_CONFIG_VALUE_1)" == *'username=oauth2'*'$GITLAB_TOKEN'* ]]
}

@test "login for another host needs --user and reads GIT_TOKEN unless --token-var names another" {
  origin https://git.example.com/team/api.git
  run "$AG" login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--user"* ]]
  [ ! -e "$E" ] || ! grep -q GIT_CONFIG "$E"
  printf 'GIT_TOKEN=t\n' > "$E"
  run "$AG" login --user bot
  [ "$status" -eq 0 ]
  [[ "$(envval GIT_CONFIG_VALUE_1)" == *'username=bot'*'$GIT_TOKEN'* ]]
  printf 'FORGE_TOKEN=t\n' > "$E"
  run "$AG" login --token-var FORGE_TOKEN --user bot
  [ "$status" -eq 0 ]
  [[ "$(envval GIT_CONFIG_VALUE_1)" == *'username=bot'*'$FORGE_TOKEN'* ]]
}

@test "login refuses a token passed as --token-var and never shows or stores it" {
  origin https://git.example.com/team/api.git
  run "$AG" login --token-var ghp_AbCdEf0123456789xyz --user bot
  [ "$status" -eq 2 ]
  [[ "$output" == *"--token-var"*"name"* ]]
  [[ "$output" != *ghp_AbCdEf0123456789xyz* ]]
  [ ! -e "$E" ] || ! grep -q ghp_AbCdEf0123456789xyz "$E"
}

@test "login takes a URL instead of the origin" {
  printf 'GH_TOKEN=t\n' > "$E"
  run "$AG" login https://github.com/example/docs.git
  [ "$status" -eq 0 ]
  [ "$(envval GIT_CONFIG_KEY_0)" = credential.https://github.com.helper ]
  [[ "$(cat "$BATS_TEST_TMPDIR/lsremote.log")" == *"https://github.com/example/docs.git"* ]]
}

@test "login without an origin or URL says what to pass" {
  run "$AG" login
  [ "$status" -eq 2 ]
  [[ "$output" == *"no origin"* ]]
}

@test "login for an ssh origin also rewrites ssh to https, since no SSH keys are mounted" {
  origin git@github.com:example/api.git
  printf 'GH_TOKEN=t\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  [ "$(envval GIT_CONFIG_COUNT)" = 4 ]
  [ "$(envval GIT_CONFIG_KEY_2)" = url.https://github.com/.insteadOf ]
  [ "$(envval GIT_CONFIG_VALUE_2)" = git@github.com: ]
  [ "$(envval GIT_CONFIG_KEY_3)" = url.https://github.com/.insteadOf ]
  [ "$(envval GIT_CONFIG_VALUE_3)" = ssh://git@github.com/ ]
}

@test "login keeps other git config entries, renumbers them and is the same when run again" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=t\nGIT_CONFIG_COUNT=2\nGIT_CONFIG_KEY_0=core.autocrlf\nGIT_CONFIG_VALUE_0=input\nGIT_CONFIG_KEY_1=credential.https://github.com.helper\nGIT_CONFIG_VALUE_1=old\nOTHER=1\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  first="$(cat "$E")"
  [ "$(envval GIT_CONFIG_COUNT)" = 3 ]
  [ "$(envval GIT_CONFIG_KEY_0)" = core.autocrlf ]
  [ "$(envval GIT_CONFIG_VALUE_0)" = input ]
  [ "$(envval GIT_CONFIG_KEY_1)" = credential.https://github.com.helper ]
  [ "$(envval GIT_CONFIG_VALUE_1)" = "" ]
  ! grep -qx 'GIT_CONFIG_VALUE_.=old' "$E"
  grep -qx 'OTHER=1' "$E"
  run "$AG" login
  [ "$(cat "$E")" = "$first" ]
}

@test "login keeps .env private" {
  origin https://github.com/example/api.git
  run "$AG" login
  [ "$(stat -c %a "$E")" = 600 ]
}

@test "login without the token adds an empty placeholder and says where to put it" {
  origin https://github.com/example/api.git
  run "$AG" login
  [ "$status" -eq 1 ]
  grep -qx 'GH_TOKEN=' "$E"
  [[ "$output" == *"GH_TOKEN"*".agentic/.env"* ]]
  [ "$(envval GIT_CONFIG_COUNT)" = 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/lsremote.log" ]
}

@test "login checks access with the new entries and the token from .env, never prompting" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=ghp_secretvalue\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  log="$(cat "$BATS_TEST_TMPDIR/lsremote.log")"
  [[ "$log" == *"args: ls-remote"*"https://github.com/example/api.git HEAD"* ]]
  [[ "$log" == *"GIT_CONFIG_COUNT=2"* ]]
  [[ "$log" == *"GIT_TERMINAL_PROMPT=0"* ]]
  [[ "$log" == *"GH_TOKEN=ghp_secretvalue"* ]]
  [[ "$output" == *"ok"*"github.com"* ]]
  [[ "$output" == *"push"* ]]
}

@test "a failed check fails, with git's message redacted" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=t\n' > "$E"
  LSREMOTE_RC=128 run "$AG" login
  [ "$status" -eq 1 ]
  [[ "$output" == *"Authentication failed"* ]]
  [[ "$output" != *ghp_leak* ]]
}

@test "--no-check writes the entries without calling the remote" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=t\n' > "$E"
  run "$AG" login --no-check
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/lsremote.log" ]
}

@test "an identity from the host is left alone" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=t\n' > "$E"
  GIT_AUTHOR_NAME="Jane Doe" GIT_AUTHOR_EMAIL=jane@example.com run "$AG" login
  [ "$status" -eq 0 ]
  ! grep -q '^GIT_AUTHOR' "$E"
  [[ "$output" == *"Jane Doe"* ]]
}

@test "without an identity, --name and --email write it; without them it says how" {
  origin https://github.com/example/api.git
  printf 'GH_TOKEN=t\n' > "$E"
  run "$AG" login
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name"*"--email"* ]]
  run "$AG" login --name "Jane Doe" --email jane@example.com
  [ "$status" -eq 0 ]
  [ "$(envval GIT_AUTHOR_NAME)" = "Jane Doe" ]
  [ "$(envval GIT_COMMITTER_NAME)" = "Jane Doe" ]
  [ "$(envval GIT_AUTHOR_EMAIL)" = jane@example.com ]
  [ "$(envval GIT_COMMITTER_EMAIL)" = jane@example.com ]
}

@test "an unknown option or command prints the usage" {
  run "$AG" login --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: agentic-git"* ]]
  run "$AG" frobnicate
  [ "$status" -eq 2 ]
}
