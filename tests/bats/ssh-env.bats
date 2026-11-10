#!/usr/bin/env bats
load helpers

setup() {
  export P="$REPO_ROOT/image/profile.d/agentic.sh"
  E="$BATS_TEST_TMPDIR/environ"
  printf '%s\0' PATH=/opt/tool/bin:/usr/bin X=from-pid1 HOME=/root TERM=dumb HOSTNAME=c SHLVL=0 PWD=/ \
    'Y=a b' KEEP=pid1 'A-B=1' '1X=2' "Z=\$(touch $BATS_TEST_TMPDIR/pwned)" > "$E"
  cmd='export KEEP=mine HOME=/home/me TERM=xterm; source "$P"; echo "$PATH|${X:-}|${Y:-}|$HOME|$TERM|$KEEP"'
}

@test "with SSH_CONNECTION the PID 1 environment is exported, PATH included" {
  SSH_CONNECTION="1 2 3 4" AGENTIC_PID1_ENVIRON="$E" run bash -c "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/tool/bin:/usr/bin|from-pid1|a b|/home/me|xterm|mine" ]
}

@test "a value is exported as text, never run" {
  SSH_CONNECTION="1 2 3 4" AGENTIC_PID1_ENVIRON="$E" run bash -c 'source "$P"; printf "%s" "$Z"'
  [ "$output" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "without SSH_CONNECTION nothing is imported" {
  unset SSH_CONNECTION
  AGENTIC_PID1_ENVIRON="$E" run bash -c "$cmd"
  [[ "$output" != *from-pid1* ]]
}

@test "an unreadable environ file is silent and changes nothing" {
  SSH_CONNECTION="1 2 3 4" AGENTIC_PID1_ENVIRON=/nonexistent run bash -c "$cmd 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|/home/me|xterm|mine" && "$output" != *from-pid1* && "$output" != *No\ such* ]]
}

@test "sourcing it twice under set -u is harmless" {
  SSH_CONNECTION="1 2 3 4" AGENTIC_PID1_ENVIRON="$E" run bash -uc 'source "$P"; source "$P"; echo "$X"'
  [ "$status" -eq 0 ]
  [ "$output" = from-pid1 ]
}

@test "a nested shell of the same SSH session keeps its own PATH (imported once per session)" {
  SSH_CONNECTION="1 2 3 4" AGENTIC_PID1_ENVIRON="$E" run bash -c 'source "$P"; export PATH="/editor/bin:$PATH"; bash -c "source \"\$P\"; echo \$PATH"'
  [ "$output" = "/editor/bin:/opt/tool/bin:/usr/bin" ]
}
