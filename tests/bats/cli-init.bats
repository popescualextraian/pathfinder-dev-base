#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  PROJ="$BATS_TEST_TMPDIR/Orders Service"
  mkdir -p "$PROJ"
  git init -q "$PROJ"
  git -C "$PROJ" remote add origin git@git.example.com:team/orders-service.git
  printf '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>\n' > "$PROJ/pom.xml"
  A="$REPO_ROOT/bin/agentic"
}

@test "init writes a valid agentic.yaml with the detected tools and the repo" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  y="$PROJ/.agentic/agentic.yaml"
  [ "$(yq .project "$y")" = orders-service ]
  [ "$(yq '.repos[0].url' "$y")" = git@git.example.com:team/orders-service.git ]
  [ "$(yq .git.host "$y")" = git.example.com ]
  [ "$(yq -o=json -I=0 .tools.java "$y")" = '{"versions":[17],"default":17}' ]
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
  [ "$status" -eq 0 ]
}

@test "init writes the skeleton, the report and next steps" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ -f "$PROJ/.agentic/.env.example" ]
  grep -qx '.env' "$PROJ/.agentic/.gitignore"
  [ -d "$PROJ/.agentic/certs" ]
  grep -q 'pom.xml' "$PROJ/.agentic/detect-report.md"
  [[ "$output" == *"agentic build"* ]]
}

@test "init refuses to overwrite agentic.yaml without --force, and keeps other files" {
  bash -c "cd '$PROJ' && bash '$A' init" >/dev/null
  echo 'GH_TOKEN=keep' > "$PROJ/.agentic/.env.example"
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"use --force"* ]]
  run bash -c "cd '$PROJ' && bash '$A' init --force"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agentic/.env.example")" = 'GH_TOKEN=keep' ]
}

@test "init without a remote uses the folder name and github.com" {
  git -C "$PROJ" remote remove origin
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$(yq .git.host "$PROJ/.agentic/agentic.yaml")" = github.com ]
  [ "$(yq '.repos[0].name' "$PROJ/.agentic/agentic.yaml")" = orders-service ]
}
