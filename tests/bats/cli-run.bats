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

@test "dev attaches to a running container without starting anything" {
  DOCKER_RUNNING=true run ag dev
  [ "$status" -eq 0 ]
  run grep -qx -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  grep -qx 'dev-shell' "$DOCKER_LOG"
}

@test "dev starts a stopped container" {
  DOCKER_RUNNING=false run ag dev
  grep -qx -- '--- start' "$DOCKER_LOG"
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
