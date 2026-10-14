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
  [ -d "$PROJ/.agentic/files" ]
  [ -d "$PROJ/.agentic/agents" ]
  [ ! -e "$PROJ/.agentic/certs" ]
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

@test "init says that an earlier project of the same name leaves its logins and sessions to be reused" {
  mkdir -p "$HOME/.agentic/projects/orders-service/harness/claude"
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.agentic/projects/orders-service"* ]]
  [[ "$output" == *"logins, sessions and history"*"reused"* ]]
}

@test "init of a new project name says nothing about earlier data" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  [[ "$output" != *"reused"* ]]
}

# held_mkdir: a mkdir that fails like Windows does for a deleted folder a process still holds open.
held_mkdir() {
  printf '#!/usr/bin/env bash\nfor a; do case "$a" in */.agentic) echo "mkdir: cannot create directory %s: File exists" "$a" >&2; exit 1 ;; esac; done\nexec %q "$@"\n' \
    "'\$a'" "$(command -v mkdir)" > "$BATS_TEST_TMPDIR/bin/mkdir"
  chmod +x "$BATS_TEST_TMPDIR/bin/mkdir"
}

@test "init names the running container that still holds a deleted .agentic and how to free it" {
  held_mkdir
  export DOCKER_PS="c1 c2"
  export DOCKER_MOUNTS="$(printf '/agentic-other-dev\t/elsewhere/.agentic\n/agentic-orders-service-dev\t%s/.agentic\n' "$PROJ")"
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist but its name is still held open"* ]]
  [[ "$output" == *"docker rm -f agentic-orders-service-dev"* ]]
  [[ "$output" != *"agentic-other-dev"* ]]
}

@test "init without a holding container still explains a held .agentic" {
  held_mkdir
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist but its name is still held open"* ]]
  [[ "$output" != *"docker rm"* ]]
}

@test "init --env-example explains a held .agentic too" {
  held_mkdir
  export DOCKER_PS="c1"
  export DOCKER_MOUNTS="$(printf '/agentic-orders-service-dev\t%s/.agentic\n' "$PROJ")"
  run bash -c "cd '$PROJ' && bash '$A' init --env-example"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker rm -f agentic-orders-service-dev"* ]]
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

ini() { (cd "$PROJ" && bash "$A" init "$@"); }

@test "init writes version 2 with the recommended lines" {
  run ini
  [ "$status" -eq 0 ]
  grep -q '^version: 2$' "$PROJ/.agentic/agentic.yaml"
  grep -qF -- '  - add plugin superpowers@claude-plugins-official --target claude' "$PROJ/.agentic/agentic.yaml"
  grep -qF -- '  - add mcp playwright -- mcp-server-playwright --headless' "$PROJ/.agentic/agentic.yaml"
  if grep -q '^git:' "$PROJ/.agentic/agentic.yaml"; then return 1; fi
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
  [ "$status" -eq 0 ]
}

@test "init --bare writes an empty setup list" {
  ini --bare
  grep -q '^setup: \[\]$' "$PROJ/.agentic/agentic.yaml"
}

@test "init --base takes the image's recommended lines and writes base_image" {
  export DOCKER_RUN_OUT=$'# team defaults\nadd plugin team@corp-market'
  ini --base team-x:1
  grep -q '^base_image: team-x:1$' "$PROJ/.agentic/agentic.yaml"
  grep -qF -- '  - add plugin team@corp-market' "$PROJ/.agentic/agentic.yaml"
  if grep -q superpowers "$PROJ/.agentic/agentic.yaml"; then return 1; fi
}

@test "the .env example documents the variables that replaced config fields" {
  ini
  for v in GIT_COMMITTER_NAME GH_HOST ANTHROPIC_MODEL COPILOT_MODEL AWS_PROFILE; do grep -q "$v" "$PROJ/.agentic/.env.example"; done
  if grep -q JIRA_PERSONAL_TOKEN "$PROJ/.agentic/.env.example"; then return 1; fi
}

@test "init keeps a recommended line with ': ' and ' #' as one literal YAML string" {
  export DOCKER_RUN_OUT=$'add mcp docs --env \'NOTE=a: b #c\' -- run it\nadd plugin team@corp-market'
  ini --base team-x:1
  [ "$(yq -r '.setup[0]' "$PROJ/.agentic/agentic.yaml")" = "add mcp docs --env 'NOTE=a: b #c' -- run it" ]
  [ "$(yq -r '.setup[1]' "$PROJ/.agentic/agentic.yaml")" = "add plugin team@corp-market" ]
  grep -qF -- '  - add plugin team@corp-market' "$PROJ/.agentic/agentic.yaml"
}

@test "init explains targets, harness and the built-in mounts in agentic.yaml, and it stays valid" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  y="$PROJ/.agentic/agentic.yaml"
  grep -B3 '^targets:' "$y" | grep -q 'where setup lines install'
  grep -B3 '^harness:' "$y" | grep -q 'which agent runs'
  grep -B8 '^setup:' "$y" | grep -q '/work'
  grep -B8 '^setup:' "$y" | grep -q '/agentic-config'
  grep -B8 '^setup:' "$y" | grep -q 'agentic list'
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
  [ "$status" -eq 0 ]
}
