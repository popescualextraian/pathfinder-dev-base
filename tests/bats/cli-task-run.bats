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
  call="$(docker_run_with agentic-bridge)"
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
  call="$(docker_run_with agentic-bridge)"
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

@test "host git ignores hooks and fsmonitor planted in a task clone" {
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  mkdir -p "$AGENTIC_WORKSPACES/demo/repos"
  git clone -q "$PROJ" "$clone"; printf '.worktrees/\n' >> "$clone/.git/info/exclude"
  for h in post-checkout reference-transaction pre-auto-gc; do
    printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$BATS_TEST_TMPDIR" > "$clone/.git/hooks/$h"; chmod +x "$clone/.git/hooks/$h"
  done
  printf '#!/bin/sh\ntouch "%s/fsmonitor-ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/fsmon"; chmod +x "$BATS_TEST_TMPDIR/fsmon"
  git -C "$clone" config core.fsmonitor "$BATS_TEST_TMPDIR/fsmon"
  run ag run --id T-27 "x"
  [ "$status" -eq 0 ]
  record T-27 idle
  DOCKER_STATUS=exited run ag clean T-27
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/hook-ran" ]
  [ ! -e "$BATS_TEST_TMPDIR/fsmonitor-ran" ]
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
  # docker run leaves a bridge log in the task directory, as a bridge that fails at start does
  cat > "$BATS_TEST_TMPDIR/bin2/docker" <<EOF2
#!/usr/bin/env bash
if [ "\$1" = run ]; then printf 'boot\nagent failed to start: not logged in\e[31m\n' > "$T/T-30/bridge.log"; fi
exec "$BATS_TEST_TMPDIR/bin/docker" "\$@"
EOF2
  chmod +x "$BATS_TEST_TMPDIR/bin2/docker"
  PATH="$BATS_TEST_TMPDIR/bin2:$PATH" DOCKER_STATUS=exited run ag run --id T-30 "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent failed to start: not logged in"* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$output"
  [ "$status" -ne 0 ]
  [ ! -e "$T/T-30" ]
}

# plant NAME [cat]: a command $BATS_TEST_TMPDIR/NAME that appends "NAME host" (or "NAME container" inside
# the docker stub's git container) to $BATS_TEST_TMPDIR/ran, then copies stdin (a filter) or fails.
plant() {
  local rest='exit 1'; [ "${2:-}" != cat ] || rest='exec cat'
  printf '#!/bin/sh\nw=host; [ -z "$DOCKER_STUB_CONTAINER" ] || w=container\necho "%s $w" >> "%s/ran"\n%s\n' \
    "$1" "$BATS_TEST_TMPDIR" "$rest" > "$BATS_TEST_TMPDIR/$1"
  chmod +x "$BATS_TEST_TMPDIR/$1"
}
lib() { (cd "$PROJ" && source "$REPO_ROOT/lib/host/common.sh" && source "$REPO_ROOT/lib/host/task.sh" && "$@"); }

@test "run mounts each changed clone's git config, info and hooks read-only over its writable .git" {
  ws="$AGENTIC_WORKSPACES/demo"
  git clone -q "$PROJ" "$ws/repos/lib"; rm -rf "$ws/repos/lib/.git/hooks" "$ws/repos/lib/.git/info"
  ag run --id T-40 --repo lib --repo proj "x" 2>/dev/null
  [ -d "$ws/repos/lib/.git/hooks" ] && [ -d "$ws/repos/lib/.git/info" ]
  call="$(docker_run_with agentic-bridge)"
  for r in lib proj; do
    g="$ws/repos/$r/.git"
    rw="$(grep -nx "$g:$g" <<<"$call" | cut -d: -f1)"
    for f in config info hooks; do
      n="$(grep -nx "$g/$f:$g/$f:ro" <<<"$call" | cut -d: -f1)"
      [ -n "$n" ] && [ "$n" -gt "$rw" ]
    done
  done
}

@test "a second task on a clone checks out in a throwaway container: no network, the user, only the clone" {
  ag run --id T-41 "x" 2>/dev/null
  run docker_run_with --entrypoint
  [ -z "$output" ]   # a clone made by this run has nothing a task wrote: host git
  : > "$DOCKER_LOG"
  ag run --id T-42 "y" 2>/dev/null
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  [ "$(git -C "$clone/.worktrees/T-42" rev-parse --abbrev-ref HEAD)" = agentic/T-42-y ]
  call="$(docker_run_with --entrypoint)"
  [ "$(sed -n '2,11p' <<<"$call" | tr '\n' ' ')" = "--rm --network none --user $(id -u):$(id -g) -v $clone:$clone --entrypoint git agentic-demo:local " ]
  grep -qx 'worktree' <<<"$call"
  [ "$(grep -c -- '^-v$' <<<"$call")" -eq 1 ]
}

@test "commands planted in a clone never run on the host: checkout, fetch and clean" {
  ag run --id T-43 "x" 2>/dev/null
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  plant upload; plant smudge cat; plant clean cat; plant askpass
  git -C "$clone" config remote.origin.uploadpack "$BATS_TEST_TMPDIR/upload"
  git -C "$clone" config filter.x.smudge "$BATS_TEST_TMPDIR/smudge"
  git -C "$clone" config filter.x.clean "$BATS_TEST_TMPDIR/clean"
  git -C "$clone" config core.askPass "$BATS_TEST_TMPDIR/askpass"
  echo '* filter=x' > "$clone/.git/info/attributes"
  run ag run --id T-44 "y"
  [ "$status" -eq 0 ]
  grep -qx 'smudge container' "$BATS_TEST_TMPDIR/ran"   # the planted filter is live, and ran in the container
  record T-44 idle
  # a new mtime, same content: status runs the clean filter to compare
  touch -d "@$(( $(date +%s) + 7 ))" "$clone/.worktrees/T-44/.agentic/agentic.yaml"
  DOCKER_STATUS=exited run ag clean T-44
  [ "$status" -eq 0 ]
  grep -qx 'clean container' "$BATS_TEST_TMPDIR/ran"
  run grep host "$BATS_TEST_TMPDIR/ran"
  [ "$status" -ne 0 ]
}

@test "clean checks the worktrees in a throwaway container of the task's image" {
  ag run --id T-45 "x" 2>/dev/null
  record T-45 idle
  : > "$DOCKER_LOG"
  DOCKER_STATUS=exited DOCKER_RUNNING=agentic-other:local run ag clean T-45
  [ "$status" -eq 0 ]
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  call="$(docker_run_with status)"
  [ "$(sed -n '2,11p' <<<"$call" | tr '\n' ' ')" = "--rm --network none --user $(id -u):$(id -g) -v $clone:$clone --entrypoint git agentic-other:local " ]
  grep -qx "$clone/.worktrees/T-45" <<<"$call"
  docker_run_with log | grep -qx -- '--not'
}

@test "host fetch keeps the user's credential helpers and ignores the clone's command settings" {
  unset GIT_ASKPASS SSH_ASKPASS GIT_PROXY_COMMAND GIT_SSH_COMMAND GIT_SSH
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  mkdir -p "$AGENTIC_WORKSPACES/demo/repos"; git clone -q "$PROJ" "$clone"
  plant local-helper; plant global-helper; plant url-helper; plant askpass; plant ssh; plant proxy
  git -C "$clone" config credential.helper "!$BATS_TEST_TMPDIR/local-helper"
  git -C "$clone" config core.askPass "$BATS_TEST_TMPDIR/askpass"
  git -C "$clone" config core.sshCommand "$BATS_TEST_TMPDIR/ssh"
  git -C "$clone" config core.gitProxy "$BATS_TEST_TMPDIR/proxy"
  git config --global credential.helper "!$BATS_TEST_TMPDIR/global-helper"
  git config --global credential.https://example.com.helper "!$BATS_TEST_TMPDIR/url-helper"
  printf 'protocol=https\nhost=example.com\n\n' | GIT_TERMINAL_PROMPT=0 lib hfetch "$clone" credential fill >/dev/null 2>&1 || true
  grep -qx 'global-helper host' "$BATS_TEST_TMPDIR/ran"
  grep -qx 'url-helper host' "$BATS_TEST_TMPDIR/ran"
  GIT_TERMINAL_PROMPT=0 timeout 60 bash -c "$(declare -f lib); lib hfetch '$clone' ls-remote ssh://git@example.invalid/x" >/dev/null 2>&1 || true
  GIT_TERMINAL_PROMPT=0 timeout 60 bash -c "$(declare -f lib); lib hfetch '$clone' ls-remote git://example.invalid/x" >/dev/null 2>&1 || true
  run grep -E '^(local-helper|askpass|ssh|proxy) ' "$BATS_TEST_TMPDIR/ran"
  [ "$status" -ne 0 ]
}

@test "host git reads the clone's own git directory, not one a planted commondir file names" {
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  mkdir -p "$AGENTIC_WORKSPACES/demo/repos"; git clone -q "$PROJ" "$clone"
  cp -r "$clone/.git" "$BATS_TEST_TMPDIR/decoy"
  git config -f "$BATS_TEST_TMPDIR/decoy/config" remote.origin.url https://example.com/decoy.git
  echo "$BATS_TEST_TMPDIR/decoy" > "$clone/.git/commondir"
  [ "$(git -C "$clone" config remote.origin.url)" = https://example.com/decoy.git ]   # the vector is live
  [ "$(lib hgit "$clone" config remote.origin.url)" = "$PROJ" ]
  [ "$(lib hfetch "$clone" config remote.origin.url)" = "$PROJ" ]
}

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
