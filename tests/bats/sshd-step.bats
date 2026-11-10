#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  S="$REPO_ROOT/image/start.d/70-sshd.sh"
  mkdir -p "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/keys"; : > "$AGENTIC_STATE/env"
  export AGENTIC_SSH_KEYS="$BATS_TEST_TMPDIR/keys/authorized_keys" AGENTIC_SSH_HOST_DIR="$HOME/.sshd"
  export AGENTIC_SSHD="$BATS_TEST_TMPDIR/bin/sshd" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # stubs: ssh-keygen makes the -f file and its .pub (mode from the umask); sshd logs its args
  cat > "$BATS_TEST_TMPDIR/bin/ssh-keygen" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/keygen.log"
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
: > "$f"; : > "$f.pub"
S
  cat > "$BATS_TEST_TMPDIR/bin/sshd" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/sshd.log"
exit "${SSHD_RC:-0}"
S
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
}
allow_key() { echo "ssh-ed25519 AAAA k" > "$AGENTIC_SSH_KEYS"; }

@test "without allowed keys the step does nothing" {
  run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/sshd_config" ] && [ ! -e "$BATS_TEST_TMPDIR/sshd.log" ]
}

@test "an empty keys file counts as no keys" {
  : > "$AGENTIC_SSH_KEYS"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/sshd_config" ]
}

@test "the host key is made once, private, and reused on the next start" {
  allow_key
  run bash "$S"; [ "$status" -eq 0 ]
  run bash "$S"; [ "$status" -eq 0 ]
  [ "$(grep -c -- '-t ed25519' "$BATS_TEST_TMPDIR/keygen.log")" -eq 1 ]
  [ "$(stat -c %a "$AGENTIC_SSH_HOST_DIR/host_ed25519")" = 600 ]
}

@test "the config has every line of the spec" {
  allow_key
  run bash "$S"
  for l in "Port 2222" "HostKey $AGENTIC_SSH_HOST_DIR/host_ed25519" "PidFile $AGENTIC_STATE/sshd.pid" \
    "AuthorizedKeysFile $AGENTIC_SSH_KEYS" "AllowUsers $(id -un)" "PasswordAuthentication no" \
    "KbdInteractiveAuthentication no" "UsePAM no" "StrictModes no" "AllowAgentForwarding no" \
    "AllowTcpForwarding local" "X11Forwarding no" "PermitUserEnvironment no" "PrintMotd no"; do
    grep -qxF "$l" "$AGENTIC_STATE/sshd_config"
  done
}

@test "sshd starts with that config and its log in the start state" {
  allow_key
  run bash "$S"
  grep -qxF -- "-f $AGENTIC_STATE/sshd_config -E $AGENTIC_STATE/sshd.log" "$BATS_TEST_TMPDIR/sshd.log"
}

@test "a failing sshd is a warning (rc 2), not a failed start" {
  allow_key
  SSHD_RC=1 run bash "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sshd did not start"* ]]
}

@test "--check writes and starts nothing" {
  allow_key
  run bash "$S" --check
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/sshd_config" ] && [ ! -e "$BATS_TEST_TMPDIR/sshd.log" ]
}
