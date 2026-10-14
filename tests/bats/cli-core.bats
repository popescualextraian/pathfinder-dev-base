#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/my project"
  mkdir -p "$PROJ/.agentic" "$PROJ/src/deep"
  git init -q "$PROJ"
  printf 'version: 2\nproject: demo  # the name\n' > "$PROJ/.agentic/agentic.yaml"
  A="$REPO_ROOT/bin/agentic"
  unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
}

in_project() { (cd "$PROJ/${2:-}" && bash -c "source '$A'; $1"); }

@test "help lists the commands" {
  run bash "$A" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"build"* ]]
}

@test "the project root is found from a subdirectory" {
  run in_project 'project_root' src/deep
  [ "$output" = "$PROJ" ]
  run in_project 'project_name' src/deep
  [ "$output" = demo ]
}

@test "without a config the CLI says to run agentic init" {
  rm "$PROJ/.agentic/agentic.yaml"
  run in_project 'need_config'
  [ "$status" -eq 1 ]
  [[ "$output" == *"run agentic init"* ]]
}

@test "a CRLF .env is refused with a fix" {
  printf 'GH_TOKEN=abc\r\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows line endings"* ]]
}

@test "quoted .env values are refused, plain ones accepted" {
  printf 'GH_TOKEN="abc"\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 1 ]
  [[ "$output" == *"quoted values"* ]]
  printf 'GH_TOKEN=abc\n# comment\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 0 ]
}

@test "run arguments keep paths with spaces intact and mount the standard places" {
  run in_project 'build_run_args agentic-demo:local; printf "%s\n" "${RUN_ARGS[@]}"'
  [ "$status" -eq 0 ]
  grep -qx "$PROJ:/work" <<<"$output"
  grep -qx "$PROJ/.agentic:/agentic-config:ro" <<<"$output"
  grep -qx "$AGENTIC_WORKSPACES/demo/repos:/workspaces/repos" <<<"$output"
  [ -d "$AGENTIC_WORKSPACES/demo/repos" ]
  # only the clones: never the workspace root, its tasks/ or events/
  [ "$(grep -Ec "^$AGENTIC_WORKSPACES/demo(/tasks|/events)?:" <<<"$output")" -eq 0 ]
  grep -qx "$AGENTIC_DATA/projects/demo/harness/claude:/home/dev/.claude" <<<"$output"
  grep -qx "$AGENTIC_DATA/projects/demo/harness/copilot:/home/dev/.copilot" <<<"$output"
  [ -d "$AGENTIC_DATA/projects/demo/harness/claude" ]
}

@test "the dev mount of the clones is canonical when the workspace root is a symlink" {
  mkdir -p "$BATS_TEST_TMPDIR/real-ws"; ln -s "$BATS_TEST_TMPDIR/real-ws" "$BATS_TEST_TMPDIR/ws-link"
  export AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws-link"
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  grep -qx "$BATS_TEST_TMPDIR/real-ws/demo/repos:/workspaces/repos" <<<"$output"
}

@test "the env file, git identity and proxy variables are passed" {
  printf 'A=1\n' > "$PROJ/.agentic/.env"
  git -C "$PROJ" config user.name "Dev Person"
  export HTTPS_PROXY=http://proxy.example.com:8080
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  grep -qx -- "--env-file" <<<"$output"
  grep -qx "GIT_AUTHOR_NAME=Dev Person" <<<"$output"
  grep -qx "HTTPS_PROXY" <<<"$output"
}

@test "a git identity in .env wins: the host's is passed only for what .env leaves unset" {
  printf 'GIT_AUTHOR_NAME=Env Person\n' > "$PROJ/.agentic/.env"
  git -C "$PROJ" config user.name "Dev Person"
  git -C "$PROJ" config user.email dev@example.com
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  run grep -x "GIT_AUTHOR_NAME=Dev Person" <<<"$output"
  [ "$status" -eq 1 ]
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  grep -qx "GIT_AUTHOR_EMAIL=dev@example.com" <<<"$output"
}

@test "the Docker socket is mounted only when the image label says so" {
  SOCK="$BATS_TEST_TMPDIR/docker.sock"
  python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1])' "$SOCK"
  export AGENTIC_DOCKER_SOCK="$SOCK"
  DOCKER_LABEL=true run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  [ "$status" -eq 0 ]
  grep -qx "$SOCK:/var/run/docker.sock" <<<"$output"
  grep -qx -- "--group-add" <<<"$output"
  grep -qx "$(stat -c %g "$SOCK")" <<<"$output"
  DOCKER_LABEL=false run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  [ "$status" -eq 0 ]
  run grep -q "docker.sock" <<<"$output"
  [ "$status" -ne 0 ]
  run grep -qx -- "--group-add" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "build-base skips a current base and builds an outdated one" {
  h="$(bash -c "source '$A'; base_hash")"
  DOCKER_LABEL="$h" run bash "$A" build-base
  [ "$status" -eq 0 ]
  [[ "$output" == *"base image is current"* ]]
  run grep -q -- "--- build" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  DOCKER_LABEL=old run bash "$A" build-base
  [ "$status" -eq 0 ]
  grep -qx "agentic.base.hash=$h" "$DOCKER_LOG"
  grep -qx "$REPO_ROOT/image/Dockerfile" "$DOCKER_LOG"
}

@test "build-base passes the developer's CA directory as a build context when it has certificates" {
  mkdir -p "$AGENTIC_DATA/ca"; touch "$AGENTIC_DATA/ca/corp.crt"
  DOCKER_LABEL=old run bash "$A" build-base
  [ "$status" -eq 0 ]
  grep -qx -- "--build-context" "$DOCKER_LOG"
  grep -qx "agentic-ca=$AGENTIC_DATA/ca" "$DOCKER_LOG"
}

@test "build keeps .env and .build/ out of the build context" {
  DOCKER_LABEL=current DOCKER_RUN_OUT='FROM agentic-dev-base:local' run in_project 'main build'
  [ "$status" -eq 0 ]
  ign="$PROJ/.agentic/.build/Dockerfile.derived.dockerignore"
  [ -f "$ign" ]
  grep -qx '.env' "$ign"
  grep -qx '.env.*' "$ign"
  grep -qx '!.env.example' "$ign"
  grep -qx '.build/' "$ign"
}

@test "build renders the Dockerfile in the base image, then builds the project image" {
  DOCKER_LABEL=current DOCKER_RUN_OUT='FROM agentic-dev-base:local' run in_project 'main build'
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agentic/.build/Dockerfile.derived")" = 'FROM agentic-dev-base:local' ]
  grep -qx -- "--entrypoint" "$DOCKER_LOG"
  grep -qx "/opt/agentic/derive/render-dockerfile.sh" "$DOCKER_LOG"
  grep -qx "UID=$(id -u)" "$DOCKER_LOG"
  grep -qx "agentic-demo:local" "$DOCKER_LOG"
  [[ "$output" == *"built agentic-demo:local"* ]]
}

@test "build --refresh-plugins busts the plugin layer" {
  DOCKER_LABEL=current run in_project 'main build --refresh-plugins'
  grep -q '^AGENTIC_PLUGINS_REFRESH=' "$DOCKER_LOG"
}

@test "build passes proxy variables as build arguments" {
  export HTTPS_PROXY=http://proxy.example.com:8080
  h="$(bash -c "source '$A'; base_hash")"
  DOCKER_LABEL="$h" run in_project 'main build'
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '^--- build' "$DOCKER_LOG")" -eq 1 ]
  docker_sub build 1 | grep -qx "agentic-demo:local"
  docker_sub build 1 | grep -qx "HTTPS_PROXY"
}

@test "build stops when the config does not render" {
  DOCKER_LABEL=current DOCKER_RUN_RC=1 run in_project 'main build'
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic.yaml has errors"* ]]
}

@test "build refuses a missing overlay base image" {
  printf 'version: 2\nproject: demo\nbase_image: my-overlay:1\n' > "$PROJ/.agentic/agentic.yaml"
  DOCKER_LABEL=current DOCKER_IMAGE_EXISTS=0 run in_project 'main build'
  [ "$status" -eq 1 ]
  [[ "$output" == *"base image my-overlay:1 not found"* ]]
}

# --- AWS profile filter (ported)
write_aws() {
  mkdir -p "$HOME/.aws/sso/cache"
  printf '[profile dev]\nsso_session = s1\nregion = eu-central-1\n\n[profile other]\nregion = eu-west-1\n\n[sso-session s1]\nsso_start_url = https://example.awsapps.com/start\n' > "$HOME/.aws/config"
  printf '[default]\naws_access_key_id = AKIADEFAULT\n\n[dev]\naws_access_key_id = AKIADEV\n' > "$HOME/.aws/credentials"
  echo '{}' > "$HOME/.aws/sso/cache/token.json"
}


label() { printf '%s' "$1" | base64 -w0; }

@test "mount, volume and path workspace lines become -v arguments" {
  mkdir -p "$HOME/.aws" "$BATS_TEST_TMPDIR/lib"
  DOCKER_LABEL="$(label $'mount\t~/.aws\t/home/dev/.aws\tro\tmount ~/.aws /home/dev/.aws --readonly\nvolume\tm2\t/home/dev/.m2\t\tvolume m2 /home/dev/.m2\nbind\t../lib\t/workspaces/repos/lib\t\tadd workspace ../lib\n')"
  export DOCKER_LABEL
  run in_project 'RUN_ARGS=(); setup_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  [ "$status" -eq 0 ]
  grep -qx -- "$HOME/.aws:/home/dev/.aws:ro" <<<"$output"
  grep -qx -- "agentic-demo-m2:/home/dev/.m2" <<<"$output"
  grep -qx -- "$BATS_TEST_TMPDIR/lib:/workspaces/repos/lib" <<<"$output"
}

@test "a missing mount source refuses the start and names the line" {
  DOCKER_LABEL="$(label $'mount\t~/.nope\t/x\t\tmount ~/.nope /x\n')"
  export DOCKER_LABEL
  run in_project 'RUN_ARGS=(); setup_run_args img'
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup line 'mount ~/.nope /x': $HOME/.nope does not exist on this host"* ]]
}

@test "an image without the run label adds nothing" {
  export DOCKER_LABEL=""
  run in_project 'RUN_ARGS=(); setup_run_args img; echo "${#RUN_ARGS[@]}"'
  [ "$output" = 0 ]
}
