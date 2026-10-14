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
  printf 'version: 2\nproject: demo\nlayout: single\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  T="$AGENTIC_WORKSPACES/demo/tasks"
  H="$AGENTIC_DATA/projects/demo/tasks"
  : > "$BATS_TEST_TMPDIR/docker.known"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# record ID STATE: a task directory with a state.json, as the bridge leaves it.
record() {
  mkdir -p "$T/$1"
  mkdir -p "$H/$1"
  jq -n --arg id "$1" --arg s "$2" '{version:1, task:$id, project:"demo", agent:"claude", state:$s, reason:"",
    session:"s1", branch:("agentic/" + $id), created:"2026-10-12T10:00:00Z", updated:"t", seq:1,
    allowed_actions:[], summary:"", stopped_by_user:false}' > "$T/$1/state.json"
  printf 'AGENTIC_TASK_TOKEN=tok-task-0123456789\nAGENTIC_AGENT_TOKEN=tok-agent-0123456789\n' > "$H/$1/env"
  printf 'agentic-demo-task-%s\n1\n%s\n' "$1" "$1" > "$H/$1/container"
  printf 'AGENTIC_WORK=/work\n' >> "$H/$1/env"
  echo "$T/$1/.ready" > "$BATS_TEST_TMPDIR/docker.ready"
  echo "agentic-demo-task-$1" >> "$BATS_TEST_TMPDIR/docker.known"
}

@test "run creates a task container with the checkout at /work, starts the bridge in it and prints the id" {
  run --separate-stderr ag run --id T-1 --allow push --allow open-pr "Fix the login bug"
  [ "$status" -eq 0 ]
  [ "$output" = T-1 ]
  [ "$stderr" = "follow: agentic follow T-1" ]
  [ "$(cat "$T/T-1/prompt.md")" = "Fix the login bug" ]
  [ "$(stat -c %a "$H/T-1/env")" = 600 ]
  grep -Eq '^AGENTIC_TASK_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  grep -Eq '^AGENTIC_AGENT_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  for l in AGENTIC_TASK_ID=T-1 AGENTIC_TASK_DIR=/tasks/T-1 AGENTIC_PROJECT=demo AGENTIC_AGENT=claude AGENTIC_WORK=/work \
           AGENTIC_ALLOWED_ACTIONS=push,open-pr AGENTIC_WORKTREE=0 AGENTIC_AUTO_CLEAN=0 AGENTIC_CONTAINER=agentic-demo-task-T-1 \
           AGENTIC_CREATED_CONTAINER=1; do grep -qx "$l" "$H/T-1/env"; done
  [ "$(cat "$H/T-1/container")" = "$(printf 'agentic-demo-task-T-1\n1\nT-1')" ]
  call="$(docker_run_with agentic-task-hold)"
  for l in -d --init agentic-demo-task-T-1 agentic.kind=task agentic.task=T-1 agentic.project=demo 127.0.0.1::8765 ALL \
           no-new-privileges "$PROJ:/work" "$T:/tasks" "$AGENTIC_WORKSPACES/demo/events:/events" AGENTIC_TASK_DIR=/tasks/T-1; do
    grep -qx -- "$l" <<<"$call"
  done
  [ "$(tail -n 1 <<<"$call")" = agentic-task-hold ]
  run ! grep -q '/home/dev/.claude' <<<"$call"
  ex="$(docker_call_with exec agentic-task-start)"
  for l in -d --env-file "$H/T-1/env" agentic-demo-task-T-1; do grep -qx -- "$l" <<<"$ex"; done
  [ "$(tail -n 1 <<<"$ex")" = agentic-task-start ]
  run grep -q "$(grep TASK_TOKEN "$H/T-1/env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "run calls no git on the host but the identity lookup" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/hostgit.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  run ag run --id T-G --worktree "x"
  [ "$status" -eq 0 ]
  if [ -e "$BATS_TEST_TMPDIR/hostgit.log" ]; then ! grep -vE 'config user\.(name|email)$' "$BATS_TEST_TMPDIR/hostgit.log"; fi
}

@test "--worktree passes the branch to the bridge; --json names the target and the branch" {
  run --separate-stderr ag run --id T-2 --worktree --json "Fix it"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"task":"T-2","container":"agentic-demo-task-T-2","port":"49153","target":null,"branch":"agentic/T-2-fix-it"}' ]
  grep -qx AGENTIC_WORKTREE=1 "$H/T-2/env"
  grep -qx AGENTIC_BRANCH=agentic/T-2-fix-it "$H/T-2/env"
}

multi() {
  M="$BATS_TEST_TMPDIR/multi"; mkdir -p "$M/.agentic"; git init -q "$M/api"; git init -q "$M/web"
  printf 'version: 2\nproject: demo\nlayout: multi\n' > "$M/.agentic/agentic.yaml"
}
am() { (cd "$M" && bash "$A" "$@" </dev/null); }

@test "a multi-repository project without a target stops with the hint and creates nothing" {
  multi
  run am run "x"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'agentic: the project holds several repositories (api, web) and no target is set.\n  Run with --target NAME, or set the default: agentic target api')" ]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
}

@test "the target is --target, else target:; the agent starts in /work/<target>; the checkout is the project folder" {
  multi
  am run --id T-a --target web "x"
  grep -qx AGENTIC_WORK=/work/web "$H/T-a/env"; grep -qx AGENTIC_TARGET=web "$H/T-a/env"
  printf 'target: api\n' >> "$M/.agentic/agentic.yaml"
  am run --id T-b "x"
  grep -qx AGENTIC_WORK=/work/api "$H/T-b/env"
  grep -qx "$M:/work" <<<"$(docker_run_with agentic-task-hold)"
}

@test "an unknown target, --target on a single repository, a missing layout and a bad --model are refused" {
  multi
  run am run --target nope "x"; [ "$status" -eq 1 ]; [[ "$output" == *"nope is not a repository of the project; choose one of: api web"* ]]
  run ag run --target web "x"; [ "$status" -eq 1 ]; [[ "$output" == *"--target is for a project with several repositories"* ]]
  run ag run --model $'a\nb' "x"; [ "$status" -eq 1 ]; [[ "$output" == *"--model"* ]]
  printf 'version: 2\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  run ag run "x"; [ "$status" -eq 1 ]; [[ "$output" == *"no layout in .agentic/agentic.yaml; re-run agentic init"* ]]
  [ ! -d "$T" ] || [ -z "$(ls -A "$T")" ]
}

@test "run --in starts a new task in the container of an earlier task, one task at a time" {
  record T-1 idle
  run ag run --id T-2 --in T-1 "second"
  [ "$status" -eq 1 ]; [[ "$output" == *"a task runs in the container of T-1"* ]]
  [ ! -e "$T/T-2" ]
  DOCKER_BRIDGE_RC=1 run ag run --id T-2 --in T-1 "second"
  [ "$status" -eq 0 ]
  [ "$(cat "$H/T-2/container")" = "$(printf 'agentic-demo-task-T-1\n0\nT-1')" ]
  run ! grep -q -- '--- run' "$DOCKER_LOG"
  grep -qx AGENTIC_TASK_DIR=/tasks/T-2 "$H/T-2/env"
  grep -qx AGENTIC_CREATED_CONTAINER=0 "$H/T-2/env"
  grep -qx agentic-demo-task-T-1 <<<"$(docker_call_with exec agentic-task-start)"
}

@test "run --in refuses an unknown task and a container that is gone" {
  run ag run --in T-9 "x"; [ "$status" -eq 1 ]; [[ "$output" == *"no task T-9"* ]]
  record T-1 idle
  DOCKER_STATUS="" run ag run --id T-3 --in T-1 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-1 has no container"* ]]
  [ ! -e "$T/T-3" ]
}

@test "a container whose start never finishes fails the run and is rolled back" {
  DOCKER_NO_READY=1 AGENTIC_START_TIMEOUT=1 run ag run --id T-7 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"the container of T-7 did not finish its start"* ]]
  [ ! -e "$T/T-7" ] && [ ! -e "$H/T-7" ]
  grep -qx agentic-demo-task-T-7 <<<"$(docker_sub rm)"
}

@test "a failed bridge in a reused container rolls the task back and keeps the container" {
  record T-1 idle
  CURL_RC=7 DOCKER_BRIDGE_RC=1 AGENTIC_START_TIMEOUT=1 run ag run --id T-2 --in T-1 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-2" ] && [ ! -e "$H/T-2" ]
  [ -z "$(docker_sub rm)" ]
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

@test "a failed start rolls back the container and files" {
  DOCKER_RUN_RC=1 run ag run --id T-5 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-5" ] && [ ! -e "$H/T-5" ]
  grep -qx agentic-demo-task-T-5 <<<"$(docker_sub rm)"
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
  [ "$(grep -c '"state":"interrupted"' "$AGENTIC_DATA/projects/demo/events.jsonl")" -eq 1 ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/events/events.jsonl" ]
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
  run grep -q "$(grep AGENT_TOKEN "$H/T-12/env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "a bad .env fails before anything is created, and a retry with the same id works" {
  printf 'A="quoted"\n' > "$PROJ/.agentic/.env"
  run ag run --id T-13 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-13" ] && [ ! -e "$H/T-13/env" ]
  rm "$PROJ/.agentic/.env"
  run ag run --id T-13 "x"
  [ "$status" -eq 0 ]
}

@test "a failure after creation (set -e, signal-free) still rolls back" {
  # the container file cannot be written when its path is a directory
  mkdir -p "$H/T-14/container"
  run ag run --id T-14 "x"
  [ "$status" -ne 0 ]
  [ ! -e "$T/T-14" ] && [ ! -e "$H/T-14" ]
}

@test "rollback works in a workspace path containing a space" {
  export AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/my ws"
  T="$AGENTIC_WORKSPACES/demo/tasks"
  DOCKER_RUN_RC=1 run ag run --id T-15 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-15" ] && [ ! -e "$H/T-15" ]
  run ag run --id T-16 "x"
  [ "$status" -eq 0 ]
}

@test "rollback_task never removes a path outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/keep"; touch "$BATS_TEST_TMPDIR/keep/f"
  record T-17 idle
  printf 'x\t%s\tb\n' "$BATS_TEST_TMPDIR/keep" > "$H/T-17/repos"
  ln -s "$BATS_TEST_TMPDIR/keep" "$T/T-17/link"
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
  grep -q '"project":"demo"' "$AGENTIC_DATA/projects/demo/events.jsonl"
}

@test "a docker failure shows unknown and records no interruption" {
  record T-19 running
  DOCKER_DOWN=1 run ag status T-19 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = unknown ]
  [ ! -e "$AGENTIC_DATA/projects/demo/events.jsonl" ]
  [ ! -e "$H/T-19/interrupted" ]
}

@test "a prompt over 64 KB starts a task with a short branch" {
  head -c 100000 /dev/zero | tr '\0' a > "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr ag run --id T-20 --worktree --prompt-file "$BATS_TEST_TMPDIR/big.md" --json
  [ "$status" -eq 0 ]
  b="$(sed -n 's/^AGENTIC_BRANCH=//p' "$H/T-20/env")"
  [ "$b" = "agentic/T-20-$(printf 'a%.0s' $(seq 40))" ]
}

@test "the branch slug skips blank lines and falls back to task" {
  run --separate-stderr ag run --id T-21 --worktree --json $'\n  \nHello, World!'
  [ "$(jq -r .branch <<<"$output")" = agentic/T-21-hello-world ]
  run --separate-stderr ag run --id T-22 --worktree --json '!!! ???'
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

@test "status of a task whose container is gone shows its open questions and the reply hint from the task files" {
  record T-24 suspended
  {
    jq -cn '{id:"Q1", source:"ask", text:"Which DB?\u001b[2J", options:["pg","sqlite"], recommendation:"pg", asked:"t1", status:"open"}'
    jq -cn '{id:"Q2", source:"ask", text:"Old?", options:[], recommendation:null, asked:"t2", status:"open"}'
    jq -cn '{id:"Q2", source:"ask", text:"Old?", options:[], recommendation:null, asked:"t2", status:"answered", answer:"yes"}'
  } > "$T/T-24/questions.jsonl"
  DOCKER_STATUS=exited run ag status T-24
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p <<<"$output")" == "T-24  suspended  claude  agentic/T-24" ]]
  [[ "$output" == *"Q1 (ask): Which DB? [2J [pg, sqlite] recommended: pg"* ]]
  [[ "$output" != *"Q2"* ]]
  [[ "$output" == *'reply: agentic answer T-24 Q1 "…"'* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$output"
  [ "$status" -ne 0 ]
  DOCKER_STATUS=exited run ag status
  [[ "$(sed -n 2p <<<"$output")" =~ ^T-24\ +suspended\ +claude\ +1\  ]]
}

@test "status --json has one shape, with the bridge live or not" {
  record T-25 suspended
  printf '%s\n' '{"id":"Q1","source":"ask","text":"Which DB?","options":[],"recommendation":null,"asked":"t1","status":"open"}' > "$T/T-25/questions.jsonl"
  DOCKER_STATUS=exited run ag status T-25 --json
  [ "$status" -eq 0 ]
  off="$output"
  [ "$(jq -c '.questions' <<<"$off")" = '[{"id":"Q1","source":"ask","text":"Which DB?","options":[],"recommendation":null,"asked":"t1"}]' ]
  [ "$(jq -r '.inbox | type' <<<"$off")" = number ]
  [ "$(jq -r 'has("open_questions")' <<<"$off")" = false ]
  # the live shape: the bridge's status() (the record without the inbox texts, plus questions)
  live="$(jq -c '.inbox = 0 | .questions = []' "$T/T-25/state.json")"
  CURL_BODY="$live" run ag status T-25 --json
  [ "$(jq -c 'keys' <<<"$output")" = "$(jq -c 'keys' <<<"$off")" ]
  # no questions file: an empty list
  record T-26 failed
  DOCKER_STATUS=exited run ag status T-26 --json
  [ "$(jq -c .questions <<<"$output")" = '[]' ]
}

@test "run warns when the project .env turns the gate off for every task" {
  printf 'AGENTIC_GATE=0\n' > "$PROJ/.agentic/.env"
  run --separate-stderr ag run --id T-28 "x"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning: .agentic/.env sets AGENTIC_GATE=0: the gate is off for every task"* ]]
  printf 'AGENTIC_GATE=1\n' > "$PROJ/.agentic/.env"
  run --separate-stderr ag run --id T-29 "x"
  [[ "$stderr" != *warning* ]]
}

@test "a run that fails early shows the bridge's reason before the rollback deletes it" {
  mkdir -p "$BATS_TEST_TMPDIR/bin2"
  # docker exec leaves a bridge log in the task directory, as a bridge that fails at start does
  cat > "$BATS_TEST_TMPDIR/bin2/docker" <<EOF2
#!/usr/bin/env bash
if [ "\$1" = exec ]; then printf 'boot\nagent failed to start: not logged in\e[31m\n' > "$T/T-30/bridge.log"; fi
exec "$BATS_TEST_TMPDIR/bin/docker" "\$@"
EOF2
  chmod +x "$BATS_TEST_TMPDIR/bin2/docker"
  PATH="$BATS_TEST_TMPDIR/bin2:$PATH" CURL_RC=7 AGENTIC_START_TIMEOUT=1 run ag run --id T-30 "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent failed to start: not logged in"* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$output"
  [ "$status" -ne 0 ]
  [ ! -e "$T/T-30" ]
}

lib() { (cd "$PROJ" && source "$REPO_ROOT/lib/host/common.sh" && source "$REPO_ROOT/lib/host/task.sh" && "$@"); }

@test "a malformed state.json or questions file never breaks status" {
  record T-46 idle; echo 'not json' > "$T/T-46/state.json"
  record T-47 idle; printf '[1]\n{"state":"idle"}\n' > "$T/T-47/state.json"
  record T-48 suspended
  printf '%s\n' '{"id":"Q1","source":"ask","text":"Which?","options":"pg","status":"open"}' 5 '"x"' > "$T/T-48/questions.jsonl"
  export DOCKER_STATUS=exited
  run ag status
  [ "$status" -eq 0 ]
  [[ "$output" =~ T-46\ +unknown ]] && [[ "$output" =~ T-47\ +unknown ]] && [[ "$output" =~ T-48\ +suspended\ +claude\ +1\  ]]
  run ag status --all --json
  [ "$status" -eq 0 ]; [ "$(jq length <<<"$output")" -eq 3 ]
  run ag status T-48
  [ "$status" -eq 0 ]; [[ "$output" == *"Q1 (ask): Which?"* ]]
  run ag status T-46
  [ "$status" -eq 0 ]; [[ "$output" == "T-46  unknown"* ]]
  # a live answer that is not a status object falls back to the task files
  DOCKER_STATUS=running CURL_BODY='{"state":"idle"} {"state":"idle"}' run ag status T-48 --json
  [ "$status" -eq 0 ]; [ "$(jq -r .state <<<"$output")" = suspended ]
  DOCKER_STATUS=running CURL_BODY='{"state":"waiting","questions":"x"}' run ag status
  [ "$status" -eq 0 ]
  DOCKER_STATUS=running CURL_BODY='{"task":"T-48","state":"waiting","questions":[{"id":"Q1","options":"pg"},7]}' run ag status T-48
  [ "$status" -eq 0 ]; [[ "$output" == *"Q1 ("* ]]
}

@test "the host's task files (tokens, container) live outside the workspace a dev container mounts" {
  ag run --id T-60 "x" 2>/dev/null
  [ "$(stat -c %a "$H/T-60/env")" = 600 ] && [ -f "$H/T-60/container" ]
  run ls "$T"
  [ "$output" = T-60 ]
  [ ! -e "$T/T-60/env" ] && [ ! -e "$T/T-60/container" ]
  grep -qx "$H/T-60/env" <<<"$(docker_call_with exec agentic-task-start)"
}

@test "the interrupted line is never written through a planted symlink or into a FIFO" {
  record T-62 running
  mkdir -p "$AGENTIC_WORKSPACES/demo/events"
  echo keep > "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$AGENTIC_WORKSPACES/demo/events/events.jsonl"
  DOCKER_STATUS="" run ag status T-62 --json
  [ "$status" -eq 0 ]; [ "$(jq -r .state <<<"$output")" = interrupted ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
  grep -q '"task":"T-62"' "$AGENTIC_DATA/projects/demo/events.jsonl"
  rm "$AGENTIC_WORKSPACES/demo/events/events.jsonl" "$H/T-62/interrupted"
  mkfifo "$AGENTIC_WORKSPACES/demo/events/events.jsonl"
  DOCKER_STATUS="" run timeout 20 bash -c "cd '$PROJ' && bash '$A' status T-62 --json </dev/null"
  [ "$status" -eq 0 ]
  rm "$AGENTIC_WORKSPACES/demo/events/events.jsonl" "$H/T-62/interrupted"
  rmdir "$AGENTIC_WORKSPACES/demo/events"; ln -s "$BATS_TEST_TMPDIR" "$AGENTIC_WORKSPACES/demo/events"
  DOCKER_STATUS="" run ag status T-62 --json
  [ "$status" -eq 0 ]; [ ! -e "$BATS_TEST_TMPDIR/events.jsonl" ]
}

@test "safe_rm refuses a path with a symlink below the root" {
  mkdir -p "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/outside/x"; touch "$BATS_TEST_TMPDIR/outside/x/f"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/root/link"
  lib safe_rm "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root/link/x"
  [ -f "$BATS_TEST_TMPDIR/outside/x/f" ]
  mkdir -p "$BATS_TEST_TMPDIR/root/real/x"
  lib safe_rm "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root/real/x"
  [ ! -e "$BATS_TEST_TMPDIR/root/real/x" ]
}

@test "the host reads no task file that is a symlink or not a regular file" {
  echo 'host secret' > "$BATS_TEST_TMPDIR/secret"
  record T-63 suspended
  ln -s "$BATS_TEST_TMPDIR/secret" "$T/T-63/transcript.md"
  mkfifo "$T/T-63/bridge.log"
  printf '%s\n' '{"id":"Q1","source":"ask","text":"Which?","options":[],"status":"open"}' > "$BATS_TEST_TMPDIR/q.jsonl"
  ln -s "$BATS_TEST_TMPDIR/q.jsonl" "$T/T-63/questions.jsonl"
  export DOCKER_STATUS=exited
  run ag logs T-63
  [ "$status" -eq 0 ]; [[ "$output" != *"host secret"* ]]
  run timeout 20 bash -c "cd '$PROJ' && bash '$A' logs T-63 --bridge </dev/null"
  [ "$status" -eq 0 ]
  run ag status T-63
  [ "$status" -eq 0 ]; [[ "$output" != *"Which?"* ]]
  cp "$T/T-63/state.json" "$BATS_TEST_TMPDIR/state.json"; rm "$T/T-63/state.json"
  ln -s "$BATS_TEST_TMPDIR/state.json" "$T/T-63/state.json"
  run ag status T-63
  [ "$status" -eq 1 ]
  run ag status
  [ "$status" -eq 0 ]; [[ "$output" != *T-63* ]]
}

@test "a task container drops every capability" {
  ag run --id T-81 "x" 2>/dev/null
  call="$(docker_run_with agentic-task-hold)"
  grep -A1 -x -- '--cap-drop' <<<"$call" | grep -qx ALL
  grep -A1 -x -- '--security-opt' <<<"$call" | grep -qx no-new-privileges
}

@test "the host never follows a symlink in its own task files" {
  echo 'AGENTIC_TASK_TOKEN=stolen-0123456789abcdef' > "$BATS_TEST_TMPDIR/victim"
  record T-84 idle
  rm "$H/T-84/env"; ln -s "$BATS_TEST_TMPDIR/victim" "$H/T-84/env"
  run ag send T-84 "x"
  [ "$status" -ne 0 ]
  run grep -rq stolen "$CURL_LOG" "$BATS_TEST_TMPDIR"/tmp* 2>/dev/null
  [ "$status" -ne 0 ]
  # run over a stale host directory: a planted env symlink is replaced, never written through
  mkdir -p "$H/T-85"; ln -s "$BATS_TEST_TMPDIR/victim" "$H/T-85/env"
  ag run --id T-85 "x" 2>/dev/null
  grep -q stolen "$BATS_TEST_TMPDIR/victim"
  [ ! -L "$H/T-85/env" ]
}

@test "agent-written files are opened without following a symlink and without blocking" {
  echo secret > "$BATS_TEST_TMPDIR/secret"; ln -s "$BATS_TEST_TMPDIR/secret" "$BATS_TEST_TMPDIR/link"
  run lib read_agent_file "$BATS_TEST_TMPDIR/link"
  [ "$status" -ne 0 ]; [[ "$output" != *secret* ]]
  mkfifo "$BATS_TEST_TMPDIR/fifo"
  run timeout 10 bash -c "cd '$PROJ' && source '$REPO_ROOT/lib/host/common.sh' && source '$REPO_ROOT/lib/host/task.sh' && read_agent_file '$BATS_TEST_TMPDIR/fifo'"
  [ "$status" -ne 124 ]
  printf 'a\nb\n' > "$BATS_TEST_TMPDIR/plain"
  [ "$(lib read_agent_file "$BATS_TEST_TMPDIR/plain")" = $'a\nb' ]
}

@test "run copies a harness login only from a regular file: never through a symlink, never blocking on a FIFO" {
  hd="$AGENTIC_DATA/projects/demo/harness"; mkdir -p "$hd/claude" "$hd/copilot"
  echo hostsecret > "$BATS_TEST_TMPDIR/secret"
  ln -s "$BATS_TEST_TMPDIR/secret" "$hd/claude/.credentials.json"
  mkfifo "$hd/copilot/config.json"
  run timeout 60 bash -c "cd '$PROJ' && bash '$A' run --id T-97 x </dev/null"
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-97/home/claude/.credentials.json" ]
  [ ! -e "$T/T-97/home/copilot/config.json" ]
  run grep -rq hostsecret "$T/T-97"
  [ "$status" -ne 0 ]
}

@test "host git in the checkout runs without fsmonitor or hooks" {
  install_git_log
  git -C "$PROJ" config user.name t
  ag run --id T-D1 "x" 2>/dev/null
  log="$BATS_TEST_TMPDIR/hostgit.log"
  grep -qF -- "args: -c core.fsmonitor=false -c core.hooksPath=/dev/null -C $PROJ config user.name" "$log"
  run grep -E -- "args: -C " "$log"
  [ "$status" -ne 0 ]
}

@test "a task container gets the project's volume lines" {
  DOCKER_LABEL="$(printf 'volume\tm2\t/home/dev/.m2\t\tvolume m2 /home/dev/.m2\n' | base64 -w0)"
  export DOCKER_LABEL
  run ag run --id T-9 --agent claude "Do it"
  [ "$status" -eq 0 ]
  call="$(docker_run_with agentic-task-hold)"
  grep -qx 'agentic-demo-m2:/home/dev/.m2' <<<"$call"
}

@test "a project name that is not [a-z0-9-] is refused: the agent can write agentic.yaml" {
  printf 'version: 2\nproject: ../x\nlayout: single\n' > "$PROJ/.agentic/agentic.yaml"
  run ag run --id T-P1 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic.yaml has a project name that is not [a-z0-9-]"* ]]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
  [ ! -e "$AGENTIC_WORKSPACES/x" ] && [ ! -e "$AGENTIC_WORKSPACES/../x" ]
}

@test "a bind source that is or goes through a symlink is refused before any docker run" {
  mkdir -p "$AGENTIC_WORKSPACES/demo" "$BATS_TEST_TMPDIR/elsewhere"
  for d in tasks events; do
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$AGENTIC_WORKSPACES/demo/$d"
    run ag run --id T-P2 "x"
    [ "$status" -eq 1 ]; [[ "$output" == *"symlink"* ]]
    [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
    rm "$AGENTIC_WORKSPACES/demo/$d"
  done
  rmdir "$AGENTIC_WORKSPACES/demo/repos"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$AGENTIC_WORKSPACES/demo/repos"
  run ag run --id T-P2 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"symlink"* ]]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
}

@test "the task directory is made exclusively: a planted symlink is refused and never written through" {
  mkdir -p "$T" "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$T/T-X1"
  run ag run --id T-X1 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-X1 exists"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/victim")" ]
  [ -L "$T/T-X1" ]
  ! grep -q -- '--- run' "$DOCKER_LOG" 2>/dev/null
}

@test "prompt and credential copies never follow a planted symlink" {
  hd="$AGENTIC_DATA/projects/demo/harness"; mkdir -p "$hd/claude"; echo '{}' > "$hd/claude/.credentials.json"
  echo keep > "$BATS_TEST_TMPDIR/victim"
  # a sibling agent plants the links as soon as the host has made the directory (here: when od makes the first token)
  printf '#!/bin/sh\nmkdir -p "%s/T-X2/home/claude"\nln -sf "%s" "%s/T-X2/prompt.md"\nln -sf "%s" "%s/T-X2/home/claude/.credentials.json"\nexec /usr/bin/od "$@"\n' \
    "$T" "$BATS_TEST_TMPDIR/victim" "$T" "$BATS_TEST_TMPDIR/victim" "$T" > "$BATS_TEST_TMPDIR/bin/od"
  chmod +x "$BATS_TEST_TMPDIR/bin/od"
  run ag run --id T-X2 "x"
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
}

@test "a container that already has the task's name is refused and never removed" {
  echo agentic-demo-task-T-Y1 >> "$BATS_TEST_TMPDIR/docker.known"
  run ag run --id T-Y1 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"a container agentic-demo-task-T-Y1 already exists; remove it or pick another --id"* ]]
  run ! grep -q -- '--- rm' "$DOCKER_LOG"
  ! grep -q -- '--- run' "$DOCKER_LOG"
  [ ! -e "$T/T-Y1" ] && [ ! -e "$H/T-Y1" ]
}

@test "an active task in a container that runs without its bridge is interrupted" {
  record T-Z1 running
  [ "$(lib task_state T-Z1)" = running ]
  [ "$(DOCKER_BRIDGE_RC=1 lib task_state T-Z1)" = interrupted ]
}

@test "the cap counts containers with a running bridge, not containers" {
  DOCKER_PS="a b c" DOCKER_BRIDGE_RC=1 run ag run --id T-Z2 "x"
  [ "$status" -eq 0 ]
}

@test "a task in a running container without a bridge gets one by docker exec" {
  record T-Z3 running
  DOCKER_BRIDGE_RC=1 run ag send T-Z3 "go"
  [ "$status" -eq 0 ]
  ex="$(docker_call_with exec agentic-task-start)"
  grep -qx agentic-demo-task-T-Z3 <<<"$ex"
  grep -qx -- "$H/T-Z3/env" <<<"$ex"
  ! grep -qx -- '--- start' "$DOCKER_LOG"
}

@test "status removes auto-cleaned tasks whose container has exited, and keeps the others" {
  record T-1 stopped; jq '.cleaned = true' "$T/T-1/state.json" > "$T/x" && mv "$T/x" "$T/T-1/state.json"
  record T-2 stopped
  DOCKER_STATUS=exited run ag status
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-1" ] && [ ! -e "$H/T-1" ]
  [ -d "$T/T-2" ]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub rm)"
}

@test "a forged cleaned flag never removes a task whose created container still runs" {
  record T-1 idle; jq '.cleaned = true' "$T/T-1/state.json" > "$T/x" && mv "$T/x" "$T/T-1/state.json"
  run ag status
  [ "$status" -eq 0 ]
  [ -d "$T/T-1" ]
  [ -z "$(docker_sub rm)" ]
}

@test "status sweeping a cleaned task that reused another task's container never kills the bridge there" {
  record T-1 stopped; jq '.cleaned = true' "$T/T-1/state.json" > "$T/x" && mv "$T/x" "$T/T-1/state.json"
  printf 'agentic-demo-task-T-0\n0\nT-0\n' > "$H/T-1/container"
  DOCKER_BRIDGE_RC=0 run ag status
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-1" ]
  run grep -q pkill "$DOCKER_LOG"; [ "$status" -ne 0 ]
}
