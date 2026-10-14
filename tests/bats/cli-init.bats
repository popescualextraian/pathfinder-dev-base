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

@test "init writes a valid agentic.yaml with the detected tools" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  y="$PROJ/.agentic/agentic.yaml"
  [ "$(yq .project "$y")" = orders-service ]
  [ "$(yq 'has("repos")' "$y")" = false ]
  [ "$(yq -o=json -I=0 .tools.java "$y")" = '{"versions":[17],"default":17}' ]
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
  [ "$status" -eq 0 ]
}

@test "init writes the skeleton, the report and next steps" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ -f "$PROJ/.agentic/.env.example" ]
  grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=' "$PROJ/.agentic/.env.example"
  grep -q 'claude setup-token' "$PROJ/.agentic/.env.example"
  grep -qx '.env' "$PROJ/.agentic/.gitignore"
  [ -d "$PROJ/.agentic/certs" ]
  grep -q 'pom.xml' "$PROJ/.agentic/detect-report.md"
  [[ "$output" == *"agentic build"* ]]
}

@test "init tolerates an unreadable directory in the repository" {
  mkdir -p "$PROJ/secret/inner"; touch "$PROJ/secret/inner/package.json"
  chmod 000 "$PROJ/secret"
  run bash -c "cd '$PROJ' && bash '$A' init"
  chmod 755 "$PROJ/secret"
  [ "$status" -eq 0 ]
  grep -q 'pom.xml' "$PROJ/.agentic/detect-report.md"
  grep -q '^Notes:' "$PROJ/.agentic/detect-report.md"
  [[ "$output" == *"next:"* ]]
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

@test "init --env-example restores the full template only when it is missing" {
  bash -c "cd '$PROJ' && bash '$A' init" >/dev/null
  rm "$PROJ/.agentic/.env.example"
  run bash -c "cd '$PROJ' && bash '$A' init --env-example"
  [ "$status" -eq 0 ]
  diff -q "$REPO_ROOT/templates/dot-agentic/.env.example" "$PROJ/.agentic/.env.example"
  echo 'MINE=1' >> "$PROJ/.agentic/.env.example"
  run bash -c "cd '$PROJ' && bash '$A' init --env-example"
  [ "$status" -eq 0 ]
  grep -qx 'MINE=1' "$PROJ/.agentic/.env.example"
}

@test "init without a remote uses the folder name" {
  git -C "$PROJ" remote remove origin
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$(yq .project "$PROJ/.agentic/agentic.yaml")" = orders-service ]
}

@test "init survives a repository with hundreds of build files and lists at most 50" {
  mkdir -p "$PROJ/many"
  seq 1 3000 | sed "s#.*#$PROJ/many/f&.tf#" | tr '\n' '\0' | xargs -0 touch
  for i in $(seq 1 200); do mkdir -p "$PROJ/pkg$i"; echo '{}' > "$PROJ/pkg$i/package.json"; done
  mkdir -p "$PROJ/.terraform/modules/m"; echo x > "$PROJ/.terraform/modules/m/main.tf"
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  [[ "$output" == *"next:"* ]]
  [ "$(grep -c '^- \./' "$PROJ/.agentic/detect-report.md")" -le 50 ]
  ! grep -q '\.terraform' "$PROJ/.agentic/detect-report.md"
  grep -q '^Notes:' "$PROJ/.agentic/detect-report.md"
}

@test "init with an https remote that carries credentials writes no credentials" {
  git -C "$PROJ" remote set-url origin 'https://user:tok123@git.example.com/team/x.git?a=1&b=2'
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  y="$PROJ/.agentic/agentic.yaml"
  ! grep -rq tok123 "$PROJ/.agentic"
}

@test "render_tools output of every shape passes agentic-config validate" {
  source "$REPO_ROOT/lib/host/detect.sh"
  make_agentic_dir
  for g in false 8.10; do
    d=$'java=21,17,8\nmaven=3.9.9\ngradle='"$g"$'\nnode=22\npython=3.12\nterraform=1.9.8\ngo=1.22.0\ndotnet=8.0\nhelm=3.16.1'
    mkdir -p "$PROJ/.agentic"
    { printf 'version: 2\nproject: shapes\n'
      render_tools "$d"; } > "$PROJ/.agentic/agentic.yaml"
    run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
    [ "$status" -eq 0 ]
  done
}
