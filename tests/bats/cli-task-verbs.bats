#!/usr/bin/env bats
load helpers
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
# record ID STATE: a task directory with a state.json, tokens and mounts, as run and the bridge leave them.
record() {
  mkdir -p "$T/$1"
  jq -n --arg id "$1" --arg s "$2" '{version:1, task:$id, project:"demo", agent:"claude", state:$s, reason:"",
    session:"s1", branch:("agentic/" + $id), created:"2026-10-12T10:00:00Z", updated:"t", seq:1,
    allowed_actions:[], summary:"", stopped_by_user:false}' > "$T/$1/state.json"
  printf 'AGENTIC_TASK_TOKEN=tok-task-0123456789\nAGENTIC_AGENT_TOKEN=tok-agent-0123456789\n' > "$T/$1.env"
  printf -- '-v\n%s\n' "$T/$1:/task" > "$T/$1.mounts"
}
posted() { grep '^arg: http://127.0.0.1:49153/' "$CURL_LOG" | sed 's#^arg: http://127.0.0.1:49153##' | tr '\n' ' '; }

# Review Focus 3
@test "send passes the text byte-identical and prints the new state" {
  record T-1 idle
  text=$'line one\nline "two" with $HOME, `ticks` and ünïcødé ✓'
  CURL_BODY='{"state":"running","reason":""}' run ag send T-1 "$text"
  [ "$status" -eq 0 ]
  [ "$output" = "T-1: running" ]
  [ "$(curl_body 1 | jq -r .text)" = "$text" ]
  run grep -q tok-task-0123456789 <(grep '^arg: ' "$CURL_LOG")
  [ "$status" -ne 0 ]
}

@test "send to a suspended task starts its container first; a stopped task refuses" {
  record T-2 suspended
  DOCKER_STATUS=exited run ag send T-2 "go on"
  [ "$status" -eq 0 ]
  grep -qx -- '--- start' "$DOCKER_LOG"
  [[ "$(posted)" == *"/status /prompt"* ]]
  record T-3 stopped; rm -f "$BATS_TEST_TMPDIR/docker.status"
  DOCKER_STATUS=exited run ag send T-3 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-3 is stopped"* ]]
}

@test "the bridge's refusal is shown with its message" {
  record T-4 running
  CURL_CODE=409 CURL_BODY='{"error":{"code":"conflict","message":"a turn is in progress; cancel first"}}' run ag send T-4 "x"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic: a turn is in progress; cancel first (HTTP 409)" ]
}

@test "answer sends the question id, the text and the grants" {
  record T-5 waiting
  ag answer T-5 Q2 "yes, push" --allow push --allow deploy:dev
  [ "$(curl_body 1 | jq -c .)" = '{"text":"yes, push","grant":["push","deploy:dev"],"question":"Q2"}' ]
  ag answer T-5 "no"
  [ "$(curl_body 2 | jq -c .)" = '{"text":"no","grant":[]}' ]
  run ag answer T-5
  [ "$status" -eq 1 ]; [[ "$output" == *usage* ]]
}

@test "cancel needs a running task" {
  record T-6 idle
  ag cancel T-6
  [[ "$(posted)" == *"/cancel"* ]]
  DOCKER_STATUS=exited run ag cancel T-6
  [ "$status" -eq 1 ]; [[ "$output" == *"not running"* ]]
}

@test "stop asks the bridge, then waits for the container; without an answer it stops the container" {
  record T-7 idle
  ag stop T-7
  [[ "$(posted)" == *"/stop"* ]]
  grep -qx -- '--- wait' "$DOCKER_LOG"
  : > "$DOCKER_LOG"
  CURL_RC=7 run ag stop T-7
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not answer"* ]]
  grep -qx -- '--- stop' "$DOCKER_LOG"
}

@test "resume is for interrupted or failed tasks and sends the resume prompt" {
  record T-8 idle
  run ag resume T-8
  [ "$status" -eq 1 ]; [[ "$output" == *"resume is for interrupted or failed tasks"* ]]
  record T-9 running
  DOCKER_STATUS=exited run ag resume T-9
  [ "$status" -eq 0 ]
  grep -qx -- '--- start' "$DOCKER_LOG"
  [ "$(curl_body 2 | jq -r .text)" = "You were interrupted. Check git status and continue." ]
}

@test "logs prints the transcript or the bridge log" {
  record T-10 idle
  printf '> hello\n' > "$T/T-10/transcript.md"
  printf 'listening\n' > "$T/T-10/bridge.log"
  [ "$(ag logs T-10)" = "> hello" ]
  [ "$(ag logs T-10 --bridge)" = listening ]
}

@test "follow runs the follow client in the container; a task that is not running points to logs" {
  record T-11 idle
  ag follow T-11 --since 3
  call="$(docker_sub exec)"
  [ "$(tail -n 5 <<<"$call" | tr '\n' ' ')" = "agentic-demo-task-T-11 agentic-bridge follow --since 3 " ]
  DOCKER_STATUS=exited run ag follow T-11
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic logs T-11"* ]]
}

@test "shell opens a login shell in the running container" {
  record T-12 idle
  ag shell T-12
  [ "$(docker_sub exec | tail -n 3 | tr '\n' ' ')" = "agentic-demo-task-T-12 bash -l " ]
}

@test "takeover stops the task and resumes its session interactively, gate on" {
  record T-13 idle
  ag takeover T-13
  [[ "$(posted)" == *"/stop"* ]]
  call="$(docker_sub run)"
  grep -qx -- '--rm' <<<"$call"
  grep -qx 'AGENTIC_GATE=1' <<<"$call"
  grep -qx "$T/T-13:/task" <<<"$call"
  [ "$(tail -n 4 <<<"$call" | tr '\n' ' ')" = "claude --dangerously-skip-permissions --resume s1 " ]
}

@test "clean refuses unpushed commits unless forced, then removes everything but remote branches" {
  ag run --id T-14 "x" >/dev/null 2>&1
  record T-14 idle   # the bridge, absent here, writes state.json
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-14"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m work
  export DOCKER_STATUS=exited
  run ag clean T-14
  [ "$status" -eq 1 ]; [[ "$output" == *"commits on no remote branch"* ]]
  run ag clean T-14 --force
  [ "$status" -eq 0 ]
  [ ! -e "$wt" ] && [ ! -e "$T/T-14" ] && [ ! -e "$T/T-14.env" ]
  run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-14-x
  [ "$status" -ne 0 ]
  grep -qx -- '--- rm' "$DOCKER_LOG"
}

@test "resume clears the interrupted marker" {
  record T-15 running
  : > "$T/T-15.interrupted"
  DOCKER_STATUS=exited run ag resume T-15
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-15.interrupted" ]
}

@test "an unknown docker state is not started or resumed" {
  record T-16 running
  DOCKER_DOWN=1 run ag send T-16 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"docker did not answer"* ]]
  DOCKER_DOWN=1 run ag resume T-16
  [ "$status" -eq 1 ]; [[ "$output" == *"is unknown"* ]]
}

@test "the bridge's 401 and reason text are shown without control characters" {
  record T-17 idle
  CURL_CODE=401 CURL_BODY=$'{"error":{"message":"bad \\u001b[31mtoken"}}' run ag send T-17 "x"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic: bad [31mtoken (HTTP 401)" ]
  printf 'a\033[2Jb\n' > "$T/T-17/transcript.md"
  [ "$(ag logs T-17)" = "a[2Jb" ]
}

@test "clean refuses a task id that is not a task" {
  run ag clean ../x
  [ "$status" -eq 1 ]
}

mkclean() {   # a task with a worktree, as run leaves it, container exited
  ag run --id "$1" "x" >/dev/null 2>&1
  record "$1" idle
  export DOCKER_STATUS=exited
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/$1"
}

@test "clean refuses uncommitted changes, a git error and a missing repos file; --force proceeds" {
  mkclean T-20
  echo x > "$wt/new.txt"
  run ag clean T-20
  [ "$status" -eq 1 ]; [[ "$output" == *"uncommitted changes"* ]]
  rm "$wt/new.txt"
  echo "gitdir: /nonexistent" > "$wt/.git"
  run ag clean T-20
  [ "$status" -eq 1 ]; [[ "$output" == *"cannot check"* ]]
  rm "$T/T-20.repos"
  run ag clean T-20
  [ "$status" -eq 1 ]; [[ "$output" == *"no repos file"* ]]
  run ag clean T-20 --force
  [ "$status" -eq 0 ]; [ ! -e "$T/T-20" ]
}

@test "clean of a clean, pushed-nowhere-but-unchanged task succeeds" {
  mkclean T-21
  run ag clean T-21
  [ "$status" -eq 0 ]; [ ! -e "$wt" ]
}

@test "clean refuses a running task unless forced, then stops it first" {
  mkclean T-22
  DOCKER_STATUS=running run ag clean T-22
  [ "$status" -eq 1 ]; [[ "$output" == *"is running; run agentic stop T-22 first"* ]]
  : > "$DOCKER_LOG"
  DOCKER_STATUS=running run ag clean T-22 --force
  [ "$status" -eq 0 ]
  grep -qx -- '--- stop' "$DOCKER_LOG"
}

@test "answer takes -- before text that starts with a dash, and checks grants first" {
  record T-23 waiting
  ag answer T-23 Q1 --allow push -- "-yes please"
  [ "$(curl_body 1 | jq -c .)" = '{"text":"-yes please","grant":["push"],"question":"Q1"}' ]
  : > "$CURL_LOG"
  run ag answer T-23 "ok" --allow "push;rm"
  [ "$status" -eq 1 ]; [[ "$output" == *"bad grant"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "stop shows the bridge's refusal and a failing docker stop" {
  record T-24 idle
  CURL_CODE=409 CURL_BODY='{"error":{"message":"busy"}}' run ag stop T-24
  [ "$status" -eq 1 ]; [ "$output" = "agentic: busy (HTTP 409)" ]
  CURL_RC=7 DOCKER_STOP_FAIL=1 run ag stop T-24
  [ "$status" -eq 1 ]; [[ "$output" == *"could not stop the container"* ]]
}

@test "a 2xx answer that is not JSON gives a readable message" {
  record T-25 idle
  CURL_BODY='<html>proxy</html>' run ag send T-25 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"not a task state"* ]]
}

@test "send and answer reviving an interrupted task clear the interrupted marker" {
  record T-40 running
  : > "$T/T-40.interrupted"
  DOCKER_STATUS=exited run ag send T-40 "go on"
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-40.interrupted" ]
  rm -f "$BATS_TEST_TMPDIR/docker.status"
  record T-41 running
  : > "$T/T-41.interrupted"
  DOCKER_STATUS=exited run ag answer T-41 "pg"
  [ "$status" -eq 0 ]
  [ ! -e "$T/T-41.interrupted" ]
}
