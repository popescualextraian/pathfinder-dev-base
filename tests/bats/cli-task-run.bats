#!/usr/bin/env bats
load helpers
bats_require_minimum_version 1.5.0
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  install_curl_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q -b main "$PROJ"
  printf 'version: 1\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  T="$AGENTIC_WORKSPACES/demo/tasks"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# record ID STATE: a task directory with a state.json, as the bridge leaves it.
record() {
  mkdir -p "$T/$1"
  jq -n --arg id "$1" --arg s "$2" '{version:1, task:$id, project:"demo", agent:"claude", state:$s, reason:"",
    session:"s1", branch:("agentic/" + $id), created:"2026-10-12T10:00:00Z", updated:"t", seq:1,
    allowed_actions:[], summary:"", stopped_by_user:false}' > "$T/$1/state.json"
  printf 'AGENTIC_TASK_TOKEN=tok-task-0123456789\nAGENTIC_AGENT_TOKEN=tok-agent-0123456789\n' > "$T/$1.env"
}

@test "run creates the worktree, the task directory and tokens, starts the bridge and prints the id" {
  run --separate-stderr ag run --id T-1 --allow push --allow open-pr "Fix the login bug"
  [ "$status" -eq 0 ]
  [ "$output" = T-1 ]
  [ "$stderr" = "follow: agentic follow T-1" ]
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-1"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = agentic/T-1-fix-the-login-bug ]
  [ "$(cat "$T/T-1/prompt.md")" = "Fix the login bug" ]
  [ "$(stat -c %a "$T/T-1.env")" = 600 ]
  grep -Eq '^AGENTIC_TASK_TOKEN=[0-9a-f]{64}$' "$T/T-1.env"
  grep -Eq '^AGENTIC_AGENT_TOKEN=[0-9a-f]{64}$' "$T/T-1.env"
  call="$(docker_sub run)"
  grep -qx -- '-d' <<<"$call"
  grep -qx 'agentic-demo-task-T-1' <<<"$call"
  for l in agentic.kind=task agentic.task=T-1 agentic.project=demo agentic.agent=claude agentic.branch=agentic/T-1-fix-the-login-bug; do grep -qx "$l" <<<"$call"; done
  grep -qx '127.0.0.1::8765' <<<"$call"
  grep -qx "$wt:/work" <<<"$call"
  grep -qx "$T/T-1:/task" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/events:/events" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/repos/proj/.git:$AGENTIC_WORKSPACES/demo/repos/proj/.git" <<<"$call"
  grep -qx "$T/T-1.env" <<<"$call"
  grep -qx 'AGENTIC_ALLOWED_ACTIONS=push,open-pr' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-bridge ]
  run grep -q "$(grep TASK_TOKEN "$T/T-1.env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "run --repo gives each named repository a worktree and mounts the other clones read-only" {
  git clone -q "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/lib"
  git clone -q "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/docs"
  ag run --id T-R --repo lib --repo proj "x" 2>/dev/null
  ws="$AGENTIC_WORKSPACES/demo"
  call="$(docker_sub run)"
  grep -qx "$ws/repos/lib/.worktrees/T-R:/work" <<<"$call"
  grep -qx "$ws/repos/proj/.worktrees/T-R:/workspaces/proj" <<<"$call"
  grep -qx "$ws/repos/docs:/workspaces/docs:ro" <<<"$call"
  [ "$(git -C "$ws/repos/lib/.worktrees/T-R" rev-parse --abbrev-ref HEAD)" = agentic/T-R-x ]
}

@test "run --json prints the task, container, port and branch" {
  run --separate-stderr ag run --id T-2 --branch feature/x --json "x"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"task":"T-2","container":"agentic-demo-task-T-2","port":"49153","branch":"feature/x"}' ]
}

@test "run seeds the task's harness homes from the project login, private to the user" {
  mkdir -p "$AGENTIC_DATA/projects/demo/harness/claude" "$AGENTIC_DATA/projects/demo/harness/copilot"
  echo '{}' > "$AGENTIC_DATA/projects/demo/harness/claude/.credentials.json"
  echo '{}' > "$AGENTIC_DATA/projects/demo/harness/copilot/config.json"
  ag run --id T-3 "x"
  [ "$(stat -c %a "$T/T-3/home/claude/.credentials.json")" = 600 ]
  [ "$(stat -c %a "$T/T-3/home/copilot/config.json")" = 600 ]
}

@test "run refuses bad input before creating anything" {
  run ag run --allow merge "x";       [ "$status" -eq 1 ]; [[ "$output" == *"unknown --allow merge"* ]]
  run ag run --agent gpt "x";         [ "$status" -eq 1 ]; [[ "$output" == *"--agent must be claude or copilot"* ]]
  run ag run;                         [ "$status" -eq 1 ]; [[ "$output" == *"needs a prompt"* ]]
  run ag run --id 'a/b' "x";          [ "$status" -eq 1 ]; [[ "$output" == *"task id"* ]]
  echo p > "$BATS_TEST_TMPDIR/p.md"
  run ag run --prompt-file "$BATS_TEST_TMPDIR/p.md" "x"; [ "$status" -eq 1 ]; [[ "$output" == *"either"* ]]
  [ ! -d "$T" ] || [ -z "$(ls -A "$T")" ]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
}

@test "run refuses at the cap of running tasks" {
  DOCKER_PS="a b c" run ag run "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"3 tasks are running (AGENTIC_MAX_RUNNING=3)"* ]]
  AGENTIC_MAX_RUNNING=4 DOCKER_PS="a b c" run ag run --id T-4 "x"
  [ "$status" -eq 0 ]
}

@test "a failed start rolls back the container, worktree, branch and files" {
  DOCKER_RUN_RC=1 run ag run --id T-5 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-5" ] && [ ! -e "$T/T-5.env" ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-5" ]
  run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-5-x
  [ "$status" -ne 0 ]
}

@test "--keep-on-failure keeps what was created" {
  DOCKER_RUN_RC=1 run ag run --id T-6 --keep-on-failure "x"
  [ "$status" -eq 1 ]
  [ -d "$T/T-6" ]
}

@test "status lists tasks: live state from a running bridge, interrupted when the container is gone" {
  record T-7 idle
  CURL_BODY='{"task":"T-7","agent":"claude","created":"2026-10-12T10:00:00Z","branch":"agentic/T-7","state":"waiting","reason":"question Q1","questions":[{"id":"Q1"}]}' run ag status
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p <<<"$output")" == TASK*STATE*AGENT*QUESTIONS*AGE*BRANCH ]]
  [[ "$(sed -n 2p <<<"$output")" =~ ^T-7\ +waiting\ +claude\ +1\ +[0-9]+[mhd]\ +agentic/T-7$ ]]
  record T-8 running
  DOCKER_STATUS="" run ag status T-8 --json
  [ "$(jq -r .state <<<"$output")" = interrupted ]
}

@test "status records an interrupted task in the project events log once" {
  record T-9 running
  DOCKER_STATUS="" ag status >/dev/null
  DOCKER_STATUS="" ag status >/dev/null
  [ "$(grep -c '"state":"interrupted"' "$AGENTIC_WORKSPACES/demo/events/events.jsonl")" -eq 1 ]
}

@test "a bridge that does not answer gives a clear message, not a curl error" {
  record T-10 idle
  CURL_RC=7 run ag status T-10
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle"* ]]
  CURL_RC=7 run bash -c "cd '$PROJ' && source '$REPO_ROOT/lib/host/common.sh' && source '$REPO_ROOT/lib/host/task.sh' && bridge_call T-10 GET /status"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic: task T-10 is not reachable (state: idle)" ]
}

@test "the bridge token goes to curl in a header file, never through a proxy, and the agent token never reaches docker" {
  record T-11 idle
  ag status T-11 >/dev/null
  grep -qx 'arg: --noproxy' "$CURL_LOG"
  grep -qx 'arg: \*' "$CURL_LOG"
  grep -q '^header: Authorization: Bearer tok-task-0123456789$' "$CURL_LOG"
  run grep -q '^arg: .*tok-task' "$CURL_LOG"
  [ "$status" -ne 0 ]
  ag run --id T-12 "x" 2>/dev/null
  run grep -q "$(grep AGENT_TOKEN "$T/T-12.env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "a bad .env fails before anything is created, and a retry with the same id works" {
  printf 'A="quoted"\n' > "$PROJ/.agentic/.env"
  run ag run --id T-13 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-13" ] && [ ! -e "$T/T-13.env" ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-13" ]
  if [ -d "$AGENTIC_WORKSPACES/demo/repos/proj" ]; then
    run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-13-x
    [ "$status" -ne 0 ]
  fi
  rm "$PROJ/.agentic/.env"
  run ag run --id T-13 "x"
  [ "$status" -eq 0 ]
}

@test "a failure after creation (set -e, signal-free) still rolls back" {
  # the mounts file cannot be written when its path is a directory
  mkdir -p "$T/T-14.mounts"
  run ag run --id T-14 "x"
  [ "$status" -ne 0 ]
  [ ! -e "$T/T-14" ] && [ ! -e "$T/T-14.env" ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-14" ]
}

@test "rollback works in a workspace path containing a space" {
  export AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/my ws"
  T="$AGENTIC_WORKSPACES/demo/tasks"
  DOCKER_RUN_RC=1 run ag run --id T-15 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-15" ] && [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-15" ]
  run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-15-x
  [ "$status" -ne 0 ]
  [ -d "$AGENTIC_WORKSPACES/demo/repos/proj/.git" ]
  run ag run --id T-16 "x"
  [ "$status" -eq 0 ]
}

@test "rollback_task never removes a path outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/keep"; touch "$BATS_TEST_TMPDIR/keep/f"
  record T-17 idle
  printf 'x\t%s\tb\n' "$BATS_TEST_TMPDIR/keep" > "$T/T-17.repos"
  run bash -c "cd '$PROJ' && source '$REPO_ROOT/lib/host/common.sh' && source '$REPO_ROOT/lib/host/task.sh' && rollback_task T-17"
  [ -f "$BATS_TEST_TMPDIR/keep/f" ]
  [ ! -e "$T/T-17" ]
}

@test "status --all takes the project from the directory layout, not from state.json" {
  record T-18 running
  jq '.project = "../x"' "$T/T-18/state.json" > "$T/s" && mv "$T/s" "$T/T-18/state.json"
  DOCKER_STATUS="" run ag status --all
  [ "$status" -eq 0 ]
  [[ "$output" =~ T-18\ +interrupted ]]
  [ ! -e "$AGENTIC_WORKSPACES/x" ]
  grep -q '"project":"demo"' "$AGENTIC_WORKSPACES/demo/events/events.jsonl"
}

@test "a docker failure shows unknown and records no interruption" {
  record T-19 running
  DOCKER_DOWN=1 run ag status T-19 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = unknown ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/events/events.jsonl" ]
  [ ! -e "$T/T-19.interrupted" ]
}

@test "a prompt over 64 KB starts a task with a short branch" {
  head -c 100000 /dev/zero | tr '\0' a > "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr ag run --id T-20 --prompt-file "$BATS_TEST_TMPDIR/big.md" --json
  [ "$status" -eq 0 ]
  b="$(jq -r .branch <<<"$output")"
  [ "$b" = "agentic/T-20-$(printf 'a%.0s' $(seq 40))" ]
}

@test "the branch slug skips blank lines and falls back to task" {
  run --separate-stderr ag run --id T-21 --json $'\n  \nHello, World!'
  [ "$(jq -r .branch <<<"$output")" = agentic/T-21-hello-world ]
  run --separate-stderr ag run --id T-22 --json '!!! ???'
  [ "$(jq -r .branch <<<"$output")" = agentic/T-22-task ]
}

@test "status strips control characters from what the agent wrote" {
  record T-23 idle
  CURL_BODY='{"task":"T-23","agent":"claude","created":"2026-10-12T10:00:00Z","branch":"b\u001b[31m","state":"idle","reason":"r\u001b]0;x\u0007","summary":"s\u001b[2J","questions":[{"id":"Q1","source":"agent","text":"t\u001b[1m","options":[]}]}' run ag status T-23
  [ "$status" -eq 0 ]
  out="$output"
  [[ "$out" == *"T-23"* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$out"
  [ "$status" -ne 0 ]
}
