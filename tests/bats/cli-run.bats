#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q "$PROJ"
  printf 'version: 2\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  A="$REPO_ROOT/bin/agentic"
  export AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"   # tests that want WSLg create it
}

fake_wslg() {
  export AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/wslg"; mkdir -p "$AGENTIC_WSLG_DIR"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$AGENTIC_WSLG_DIR/wayland-0"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }

@test "shell runs the project image with the command and no TTY when not on a terminal" {
  run ag shell echo hi
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  [ "$(sed -n 1p <<<"$call")" = run ]
  grep -qx -- '--rm' <<<"$call"
  grep -qx -- '-i' <<<"$call"
  run grep -qx -- '-it' <<<"$call"
  [ "$status" -ne 0 ]
  [ "$(tail -n 3 <<<"$call" | tr '\n' ' ')" = "agentic-demo:local echo hi " ]
}

@test "shell falls back to the base image before the first build" {
  DOCKER_IMAGE_EXISTS=0 run ag shell true
  [[ "$output" == *"agentic-demo:local not built yet"* ]]
  grep -qx 'agentic-dev-base:local' "$DOCKER_LOG"
}

@test "login starts the chosen harness interactively" {
  run ag login copilot
  [ "$status" -eq 0 ]
  grep -qx -- '-it' "$DOCKER_LOG"
  [ "$(tail -n 1 "$DOCKER_LOG")" = copilot ]
  [[ "$output" == *"/login"* ]]
}

@test "login git runs agentic-git in a throwaway container with the options, without a TTY off a terminal" {
  run ag login git https://github.com/example/api.git --name "Jane Doe"
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  grep -qx -- '--rm' <<<"$call"
  grep -qx -- '-i' <<<"$call"
  grep -qx "$PROJ:/work" <<<"$call"
  [ "$(tail -n 6 <<<"$call" | tr '\n' '|')" = "agentic-demo:local|agentic-git|login|https://github.com/example/api.git|--name|Jane Doe|" ]
}

@test "login git passes the tool's failure on" {
  DOCKER_RUN_RC=1 run ag login git
  [ "$status" -eq 1 ]
}

@test "login refuses an unknown harness" {
  run ag login gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: agentic login"* ]]
}

@test "setup without any authentication explains the options and exits 1" {
  run ag setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic login claude"* ]]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
  [[ "$output" == *"CLAUDE_CODE_USE_BEDROCK"* ]]
  run grep -q -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "setup with an API key runs the skill in Claude" {
  printf 'ANTHROPIC_API_KEY=k\n' > "$PROJ/.agentic/.env"
  run ag setup
  [ "$status" -eq 0 ]
  [ "$(tail -n 2 "$DOCKER_LOG" | tr '\n' ' ')" = "claude /agentic-setup " ]
  grep -qx 'AGENTIC_SETUP=1' "$DOCKER_LOG"
}

@test "setup with a Claude login on disk counts as authenticated" {
  mkdir -p "$AGENTIC_DATA/projects/demo/harness/claude"
  echo '{"x":1}' > "$AGENTIC_DATA/projects/demo/harness/claude/.credentials.json"
  run ag setup
  [ "$status" -eq 0 ]
}

@test "setup uses Copilot when the image says so" {
  printf 'COPILOT_GITHUB_TOKEN=t\n' > "$PROJ/.agentic/.env"
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 0 ]
  [ "$(tail -n 3 "$DOCKER_LOG" | tr '\n' ' ')" = "copilot -i /agentic-setup " ]
}

@test "dev creates the container when there is none, then attaches" {
  run ag dev
  [ "$status" -eq 0 ]
  run1="$(docker_sub run)"
  grep -qx -- '-d' <<<"$run1"
  grep -qx 'agentic-demo-dev' <<<"$run1"
  grep -qx 'unless-stopped' <<<"$run1"
  grep -qx 'agentic.kind=dev' <<<"$run1"
  [ "$(tail -n 2 <<<"$run1" | tr '\n' ' ')" = "sleep infinity " ]
  [ "$(docker_sub exec | tr '\n' ' ')" = "exec -it agentic-demo-dev dev-shell " ]
}

@test "dev publishes every app port on the same loopback port" {
  DOCKER_APPS="$(printf '%s' '{"web":{"ports":[3000],"url":"/","autostart":false},"api":{"ports":[8080,9000],"url":"/","autostart":false}}' | base64 -w0)" run ag dev
  [ "$status" -eq 0 ]
  run1="$(docker_sub run)"
  for p in 127.0.0.1:3000:3000 127.0.0.1:8080:8080 127.0.0.1:9000:9000; do grep -qx -- "$p" <<<"$run1"; done
}

@test "dev publishes nothing without apps, and names the ports when the start fails" {
  run ag dev
  run ! grep -q -- '127.0.0.1:' <<<"$(docker_sub run)"
  DOCKER_RUN_RC=1 DOCKER_APPS="$(printf '%s' '{"web":{"ports":[3000],"url":"/","autostart":false}}' | base64 -w0)" run ag dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"3000"* ]]
}

@test "dev attaches to a running container without starting anything" {
  DOCKER_RUNNING=true run ag dev
  [ "$status" -eq 0 ]
  run grep -qx -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  grep -qx 'dev-shell' "$DOCKER_LOG"
}

@test "dev starts a stopped container" {
  DOCKER_RUNNING=false DOCKER_NETWORKS="bridge agentic-demo " run ag dev
  grep -qx -- '--- start' "$DOCKER_LOG"
  run grep -qx "connect" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dev connects a running container created before the project network to it" {
  DOCKER_RUNNING=true DOCKER_NETWORKS="bridge " run ag dev
  [ "$status" -eq 0 ]
  [ "$(docker_sub network 2 | tr '\n' ' ')" = "network connect agentic-demo agentic-demo-dev " ]
}

@test "dev connects a container created before the project network to it" {
  DOCKER_RUNNING=false DOCKER_NETWORKS="bridge " run ag dev
  [ "$status" -eq 0 ]
  [ "$(docker_sub network 2 | tr '\n' ' ')" = "network connect agentic-demo agentic-demo-dev " ]
}

@test "dev stop and recreate" {
  run ag dev stop
  [ "$(docker_sub stop | tr '\n' ' ')" = "stop agentic-demo-dev " ]
  : > "$DOCKER_LOG"
  run ag dev recreate
  [ "$(docker_sub rm | tr '\n' ' ')" = "rm -f agentic-demo-dev " ]
  grep -qx 'sleep' "$DOCKER_LOG"
}

@test "dev --host-profile wsl adds the WSLg display and clipboard" {
  run ag dev --host-profile wsl
  grep -qx 'DISPLAY=:0' "$DOCKER_LOG"
  grep -qx 'WAYLAND_DISPLAY=/run/wslg/wayland-0' "$DOCKER_LOG"
  grep -qx '/tmp:/tmp' "$DOCKER_LOG"
}

@test "on WSLg, shell, setup, login and dev get the display, the Wayland clipboard and the shared /tmp" {
  fake_wslg
  printf 'ANTHROPIC_API_KEY=k\n' > "$PROJ/.agentic/.env"
  for cmd in "shell true" setup "login claude" dev; do
    : > "$DOCKER_LOG"
    run ag $cmd
    call="$(docker_sub run)"
    grep -qx 'WAYLAND_DISPLAY=/run/wslg/wayland-0' <<<"$call" || { echo "$cmd: no Wayland"; false; }
    grep -qx "$AGENTIC_WSLG_DIR:/run/wslg" <<<"$call" || { echo "$cmd: no socket mount"; false; }
    grep -qx '/tmp:/tmp' <<<"$call" || { echo "$cmd: no shared /tmp"; false; }
    grep -qx 'DISPLAY=:0' <<<"$call" || { echo "$cmd: no display"; false; }
  done
}

@test "without WSLg nothing host-specific is added" {
  run ag shell true
  run grep -q WAYLAND_DISPLAY "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "AGENTIC_HOST_PROFILE=none keeps WSLg out" {
  fake_wslg
  AGENTIC_HOST_PROFILE=none run ag shell true
  run grep -q WAYLAND_DISPLAY "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "dev refuses to start before the first build" {
  DOCKER_IMAGE_EXISTS=0 run ag dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"run agentic build"* ]]
}

@test "dev status reports a missing container" {
  run ag dev status
  [ "$output" = "agentic-demo-dev: not created" ]
}

@test "a placeholder such as TBD is not a token" {
  printf 'COPILOT_GITHUB_TOKEN=TBD\nGH_TOKEN=changeme\n' > "$PROJ/.agentic/.env"
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic login copilot"* ]]
}

@test "the auth help explains the subscription token and the API key" {
  run ag setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude setup-token"* ]]
  [[ "$output" == *"CLAUDE_CODE_OAUTH_TOKEN"* ]]
  [[ "$output" == *"sk-ant-api"* ]]
}

@test "setup with Copilot and no login prints the auth help without a stray shell error" {
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic login copilot"* ]]
  [[ "$output" != *"No such file"* ]]
}

@test "the login check reads no symlinked login and never blocks on a FIFO" {
  hd="$AGENTIC_DATA/projects/demo/harness"; mkdir -p "$hd/claude" "$hd/copilot"
  echo '{"x":1}' > "$BATS_TEST_TMPDIR/creds"; ln -s "$BATS_TEST_TMPDIR/creds" "$hd/claude/.credentials.json"
  run ag setup
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic login claude"* ]]
  echo '{"logged_in_users":[{"login":"a"}]}' > "$BATS_TEST_TMPDIR/cp"; ln -s "$BATS_TEST_TMPDIR/cp" "$hd/copilot/config.json"
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic login copilot"* ]]
  rm "$hd/copilot/config.json"; mkfifo "$hd/copilot/config.json"
  DOCKER_LABEL=copilot run timeout 20 bash -c "cd '$PROJ' && bash '$A' setup </dev/null"
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic login copilot"* ]]
  # a regular login file still counts
  rm "$hd/copilot/config.json"; cp "$BATS_TEST_TMPDIR/cp" "$hd/copilot/config.json"
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 0 ]
}

allow_ssh() { mkdir -p "$AGENTIC_DATA/projects/demo/ssh/keys"; echo "ssh-ed25519 AAAA k" > "$AGENTIC_DATA/projects/demo/ssh/keys/authorized_keys"; }

@test "dev without allowed keys adds no ssh mount and no ssh port" {
  run ag dev
  [ "$status" -eq 0 ]
  run1="$(docker_sub run)"
  [[ "$run1" != *"/etc/agentic/ssh"* && "$run1" != *":2222"* ]]
}

@test "dev with allowed keys mounts the keys read-only, the host key dir, and publishes 2222 on loopback" {
  allow_ssh
  run ag dev
  [ "$status" -eq 0 ]
  run1="$(docker_sub run)"
  grep -qxF "$AGENTIC_DATA/projects/demo/ssh/keys:/etc/agentic/ssh:ro" <<<"$run1"
  grep -qxF "$AGENTIC_DATA/projects/demo/ssh/host:/home/dev/.sshd" <<<"$run1"
  grep -qx "127.0.0.1:2222:2222" <<<"$run1"
  [ -d "$AGENTIC_DATA/projects/demo/ssh/host" ]
}

@test "AGENTIC_SSH_PORT in .agentic/.env picks the host port; a bad one is refused" {
  allow_ssh
  echo AGENTIC_SSH_PORT=2233 > "$PROJ/.agentic/.env"
  run ag dev
  grep -qx "127.0.0.1:2233:2222" <<<"$(docker_sub run)"
  : > "$DOCKER_LOG"
  echo AGENTIC_SSH_PORT=99999 > "$PROJ/.agentic/.env"
  run ag dev
  [ "$status" -ne 0 ]
  [[ "$output" == *AGENTIC_SSH_PORT* ]]
}

@test "a failed start with ssh on names the ssh port and AGENTIC_SSH_PORT" {
  allow_ssh
  DOCKER_RUN_RC=1 run ag dev
  [ "$status" -eq 1 ]
  [[ "$output" == *2222* && "$output" == *AGENTIC_SSH_PORT* ]]
}

@test "shell gets no ssh mount even with allowed keys" {
  allow_ssh
  run ag shell true
  [[ "$(docker_sub run)" != *"/etc/agentic/ssh"* ]]
}

@test "dev ssh adds a public key once, CR stripped, with modes 700/600, and prints the block" {
  printf 'ssh-ed25519 AAAAC3 me@laptop\r\n\r\n' > "$BATS_TEST_TMPDIR/k.pub"
  run ag dev ssh "$BATS_TEST_TMPDIR/k.pub"
  [ "$status" -eq 0 ]
  run ag dev ssh "$BATS_TEST_TMPDIR/k.pub"
  [ "$status" -eq 0 ]
  f="$AGENTIC_DATA/projects/demo/ssh/keys/authorized_keys"
  [ "$(cat "$f")" = "ssh-ed25519 AAAAC3 me@laptop" ]
  [ "$(stat -c %a "$f")" = 600 ] && [ "$(stat -c %a "${f%/*}")" = 700 ]
  [[ "$output" == *"Host agentic-demo"* && "$output" == *"Port 2222"* && "$output" == *"User dev"* ]]
}

@test "dev ssh takes every public key type and refuses a private key and a file that is not a key" {
  printf 'ssh-rsa AAAAB a\necdsa-sha2-nistp256 AAAAE b\nsk-ssh-ed25519@openssh.com AAAAG c\n' > "$BATS_TEST_TMPDIR/many.pub"
  run ag dev ssh "$BATS_TEST_TMPDIR/many.pub"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AGENTIC_DATA/projects/demo/ssh/keys/authorized_keys")" -eq 3 ]
  rm -rf "$AGENTIC_DATA/projects/demo/ssh"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n' > "$BATS_TEST_TMPDIR/k"
  run ag dev ssh "$BATS_TEST_TMPDIR/k"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pass the .pub file"* ]]
  printf 'ssh-ed25519 AAAA ok\nhello\n' > "$BATS_TEST_TMPDIR/x"
  run ag dev ssh "$BATS_TEST_TMPDIR/x"
  [ "$status" -ne 0 ]
  [ ! -e "$AGENTIC_DATA/projects/demo/ssh/keys/authorized_keys" ]
  run ag dev ssh "$BATS_TEST_TMPDIR/missing.pub"
  [ "$status" -ne 0 ]
}

@test "dev ssh says to recreate when the running container does not publish the port" {
  allow_ssh
  DOCKER_RUNNING=true run ag dev ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"run agentic dev recreate"* ]]
  DOCKER_RUNNING=true DOCKER_PORT=2222 run ag dev ssh
  [[ "$output" != *"recreate"* ]]
}

@test "dev status shows the ssh address when the port is published" {
  DOCKER_RUNNING=true DOCKER_PORT=2222 run ag dev status
  [[ "$output" == *"ssh=127.0.0.1:2222"* ]]
  DOCKER_RUNNING=true run ag dev status
  [[ "$output" != *"ssh="* ]]
}
