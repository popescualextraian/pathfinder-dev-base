#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
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
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# record ID STATE: a task directory with a state.json, tokens and the container file, as run and the bridge leave them.
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
  DOCKER_BRIDGE_RC=1 DOCKER_STATUS=exited run ag send T-2 "go on"
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

@test "resume is for interrupted or failed tasks and sends the resume prompt" {
  record T-8 idle
  run ag resume T-8
  [ "$status" -eq 1 ]; [[ "$output" == *"resume is for interrupted or failed tasks"* ]]
  record T-9 running
  DOCKER_BRIDGE_RC=1 DOCKER_STATUS=exited run ag resume T-9
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

@test "logs --bridge also prints the bridge's own output (bridge.out)" {
  record T-10 idle
  printf 'listening\n' > "$T/T-10/bridge.log"
  printf 'boot failure\e[31m\n' > "$T/T-10/bridge.out"
  run ag logs T-10 --bridge
  [ "$status" -eq 0 ]
  [[ "$output" == *listening* ]]; [[ "$output" == *"bridge.out"* ]]; [[ "$output" == *"boot failure"* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "a bridge that does not come up shows the tails of its log and output" {
  record T-10 idle
  printf 'in the log\n' > "$T/T-10/bridge.log"
  printf 'in the output\n' > "$T/T-10/bridge.out"
  CURL_RC=7 DOCKER_BRIDGE_RC=1 AGENTIC_START_TIMEOUT=1 run ag send T-10 "go"
  [ "$status" -eq 1 ]
  [[ "$output" == *"in the log"* ]]; [[ "$output" == *"in the output"* ]]
  [[ "$output" == *"did not come up"* ]]
}

@test "follow runs the follow client in the container; a task that is not running points to logs" {
  record T-11 idle
  ag follow T-11 --since 3 --status
  call="$(docker_sub exec)"
  [ "$(tail -n 6 <<<"$call" | tr '\n' ' ')" = "agentic-demo-task-T-11 agentic-bridge follow --since 3 --status " ]
  DOCKER_STATUS=exited run ag follow T-11
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic logs T-11"* ]]
}

@test "shell opens a login shell in the running container" {
  record T-12 idle
  ag shell T-12
  [ "$(docker_sub exec | tail -n 3 | tr '\n' ' ')" = "agentic-demo-task-T-12 bash -l " ]
}

@test "resume clears the interrupted marker" {
  record T-15 running
  : > "$H/T-15/interrupted"
  DOCKER_BRIDGE_RC=1 DOCKER_STATUS=exited run ag resume T-15
  [ "$status" -eq 0 ]
  [ ! -e "$H/T-15/interrupted" ]
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
  : > "$H/T-40/interrupted"
  DOCKER_BRIDGE_RC=1 DOCKER_STATUS=exited run ag send T-40 "go on"
  [ "$status" -eq 0 ]
  [ ! -e "$H/T-40/interrupted" ]
  rm -f "$BATS_TEST_TMPDIR/docker.status"
  record T-41 running
  : > "$H/T-41/interrupted"
  DOCKER_BRIDGE_RC=1 DOCKER_STATUS=exited run ag answer T-41 "pg"
  [ "$status" -eq 0 ]
  [ ! -e "$H/T-41/interrupted" ]
}

@test "stop asks the bridge to stop, then stops the container; without an answer it stops the container" {
  record T-1 running
  AGENTIC_STOP_TIMEOUT=1 run ag stop T-1
  [ "$status" -eq 0 ]
  [[ "$(posted)" == *"/stop"* ]]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub stop)"
  : > "$DOCKER_LOG"
  CURL_RC=7 AGENTIC_STOP_TIMEOUT=1 run ag stop T-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not answer"* ]]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub stop)"
}

@test "resume starts the bridge again in the running container when it died" {
  record T-1 running
  DOCKER_BRIDGE_RC=1 run ag resume T-1
  [ "$status" -eq 0 ]
  grep -qx -- "$H/T-1/env" <<<"$(docker_call_with exec agentic-task-start)"
  [ -z "$(docker_sub start)" ]
  [[ "$(posted)" == *"/prompt"* ]]
}

@test "resume of a task whose container stopped starts it, waits for its start, then the bridge" {
  record T-1 running
  DOCKER_STATUS=exited DOCKER_BRIDGE_RC=1 run ag resume T-1
  [ "$status" -eq 0 ]
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub start)"
  [ -n "$(docker_call_with exec agentic-task-start)" ]
}

@test "takeover stops the bridge and resumes the session in the task's container and directory" {
  record T-1 idle
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  AGENTIC_STOP_TIMEOUT=1 run ag takeover T-1
  [ "$status" -eq 0 ]
  [[ "$(posted)" == *"/stop"* ]]
  ex="$(docker_call_with exec claude)"
  for l in -w /work/.worktrees/T-1 -e AGENTIC_TASK_DIR=/tasks/T-1 agentic-demo-task-T-1 --dangerously-skip-permissions --resume s1; do
    grep -qx -- "$l" <<<"$ex"
  done
  [ -z "$(docker_sub run)" ]
}

@test "follow passes the task token through the host env file" {
  record T-11 idle
  ag follow T-11 --since 3
  call="$(docker_call_with exec follow)"
  grep -qx -- --env-file <<<"$call"; grep -qx -- "$H/T-11/env" <<<"$call"
  [ "$(tail -n 5 <<<"$call" | tr '\n' ' ')" = "agentic-demo-task-T-11 agentic-bridge follow --since 3 " ]
}

@test "clean of a task with a worktree removes it in the container, then the container and the files" {
  record T-1 stopped
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  DOCKER_BRIDGE_RC=1 run ag clean T-1
  [ "$status" -eq 0 ]
  wt="$(docker_call_with exec /opt/agentic/task/worktree.sh)"
  for l in agentic-demo-task-T-1 remove /work T-1 agentic/T-1-x; do grep -qx -- "$l" <<<"$wt"; done
  run ! grep -qx -- --force <<<"$wt"
  grep -qx agentic-demo-task-T-1 <<<"$(docker_sub rm)"
  [ ! -e "$T/T-1" ] && [ ! -e "$H/T-1" ]
}

@test "clean refuses unpushed work unless forced" {
  record T-1 stopped
  printf 'AGENTIC_WORKTREE=1\nAGENTIC_BRANCH=agentic/T-1-x\n' >> "$H/T-1/env"
  DOCKER_BRIDGE_RC=1 DOCKER_WT_ERR="agentic-worktree: /work/.worktrees/T-1 has commits on no remote branch (agentic/T-1-x); push them, or clean with --force" \
    run ag clean T-1
  [ "$status" -eq 1 ]; [[ "$output" == *"has commits on no remote branch"* ]]
  [ -d "$T/T-1" ]
  : > "$DOCKER_LOG"
  DOCKER_BRIDGE_RC=1 run ag clean T-1 --force
  [ "$status" -eq 0 ]
  grep -qx -- --force <<<"$(docker_call_with exec /opt/agentic/task/worktree.sh)"
}

@test "clean without a worktree never touches /work; a reused container stays" {
  record T-1 stopped
  printf 'agentic-demo-task-T-0\n0\nT-0\n' > "$H/T-1/container"
  DOCKER_BRIDGE_RC=1 run ag clean T-1
  [ "$status" -eq 0 ]
  [ -z "$(docker_sub rm)" ]
  ! grep -q worktree.sh "$DOCKER_LOG"
}

@test "clean refuses a running task unless forced, and a container another task runs in" {
  record T-1 running
  run ag clean T-1
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-1 is running; run agentic stop T-1 first, or --force"* ]]
  record T-2 stopped
  run ag clean T-2
  [ "$status" -eq 1 ]; [[ "$output" == *"another task runs in the container of T-2; stop it first"* ]]
  [ -d "$T/T-2" ]
}

@test "clean of a task that reused another task's container never kills the bridge running there" {
  record T-1 stopped
  printf 'agentic-demo-task-T-0\n0\nT-0\n' > "$H/T-1/container"
  DOCKER_BRIDGE_RC=0 run ag clean T-1
  [ "$status" -eq 0 ]
  run grep -q pkill "$DOCKER_LOG"; [ "$status" -ne 0 ]
  [ ! -e "$T/T-1" ]
}

@test "takeover and clean --force refuse a container whose bridge is another task's" {
  record T-1 idle
  CURL_GET_CODE=401 CURL_CODE=401 DOCKER_BRIDGE_RC=0 run ag takeover T-1
  [ "$status" -eq 1 ]; [[ "$output" == *"another task runs in the container of T-1; stop it first"* ]]
  CURL_GET_CODE=401 CURL_CODE=401 DOCKER_BRIDGE_RC=0 run ag clean T-1 --force
  [ "$status" -eq 1 ]; [[ "$output" == *"another task runs in the container of T-1; stop it first"* ]]
  run grep -q pkill "$DOCKER_LOG"; [ "$status" -ne 0 ]
  [ -z "$(docker_sub stop)" ]
  [ -d "$T/T-1" ]
}

@test "stop does not stop a container whose bridge is another task's" {
  record T-1 running
  CURL_GET_CODE=401 CURL_CODE=401 run ag stop T-1
  [ "$status" -eq 1 ]
  [ -z "$(docker_sub stop)" ]
}
