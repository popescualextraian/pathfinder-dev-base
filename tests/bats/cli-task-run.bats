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
  printf 'version: 2\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  T="$AGENTIC_WORKSPACES/demo/tasks"
  H="$AGENTIC_DATA/projects/demo/tasks"
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
}

@test "run creates the worktree, the task directory and tokens, starts the bridge and prints the id" {
  run --separate-stderr ag run --id T-1 --allow push --allow open-pr "Fix the login bug"
  [ "$status" -eq 0 ]
  [ "$output" = T-1 ]
  [ "$stderr" = "follow: agentic follow T-1" ]
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-1"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = agentic/T-1-fix-the-login-bug ]
  [ "$(cat "$T/T-1/prompt.md")" = "Fix the login bug" ]
  [ "$(stat -c %a "$H/T-1/env")" = 600 ]
  grep -Eq '^AGENTIC_TASK_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  grep -Eq '^AGENTIC_AGENT_TOKEN=[0-9a-f]{64}$' "$H/T-1/env"
  call="$(docker_run_with agentic-bridge)"
  grep -qx -- '-d' <<<"$call"
  grep -qx 'agentic-demo-task-T-1' <<<"$call"
  for l in agentic.kind=task agentic.task=T-1 agentic.project=demo agentic.agent=claude agentic.branch=agentic/T-1-fix-the-login-bug; do grep -qx "$l" <<<"$call"; done
  grep -qx '127.0.0.1::8765' <<<"$call"
  grep -qx "$wt:/work" <<<"$call"
  grep -qx "$T/T-1:/task" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/events:/events" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/repos/proj/.git:$AGENTIC_WORKSPACES/demo/repos/proj/.git" <<<"$call"
  grep -qx "$H/T-1/env" <<<"$call"
  grep -qx 'AGENTIC_ALLOWED_ACTIONS=push,open-pr' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-bridge ]
  run grep -q "$(grep TASK_TOKEN "$H/T-1/env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "run --repo gives each named repository a worktree and mounts the other clones read-only" {
  fake_ssh
  remote_clone "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/lib"
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
  [ ! -e "$T/T-5" ] && [ ! -e "$H/T-5/env" ]
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
  mkdir -p "$H/T-14/mounts"
  run ag run --id T-14 "x"
  [ "$status" -ne 0 ]
  [ ! -e "$T/T-14" ] && [ ! -e "$H/T-14" ]
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
  printf 'x\t%s\tb\n' "$BATS_TEST_TMPDIR/keep" > "$H/T-17/repos"
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
# fake_ssh: the user's core.sshCommand runs the remote command here, so ssh://example.invalid/<path>
# reaches the local repository <path>.
fake_ssh() {
  printf '#!/bin/sh\nfor a; do c="$a"; done\nexec sh -c "$c"\n' > "$BATS_TEST_TMPDIR/fake-ssh"
  chmod +x "$BATS_TEST_TMPDIR/fake-ssh"
  git config --global core.sshCommand "$BATS_TEST_TMPDIR/fake-ssh"
  git config --global ssh.variant simple
}
# remote_clone SRC DEST: a clone of SRC whose origin is SRC over the fake ssh.
remote_clone() { git clone -q "$1" "$2"; git -C "$2" remote set-url origin "ssh://example.invalid$1"; }

@test "run mounts each changed clone's git config, info and hooks read-only over its writable .git" {
  ws="$AGENTIC_WORKSPACES/demo"
  fake_ssh; remote_clone "$PROJ" "$ws/repos/lib"; rm -rf "$ws/repos/lib/.git/hooks" "$ws/repos/lib/.git/info"
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

# cg_head CALL: the docker run options of a throwaway git container call, up to the image, on one line.
cg_head() { sed -n '2,/^--entrypoint$/p' <<<"$1" | tr '\n' ' '; }
# cg_base CLONE GITDIR: the options every throwaway git container has, before its own mounts.
cg_base() {
  local g="$1/.git"
  printf '%s ' --rm --network none --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
    --read-only --tmpfs /tmp -e HOME=/tmp -e "GIT_DIR=$2" -e "GIT_COMMON_DIR=$g" \
    -v "$g:$g" -v "$g/config:$g/config:ro" -v "$g/info:$g/info:ro" -v "$g/hooks:$g/hooks:ro"
}
MIRRORS_REL=projects/demo/mirrors

@test "every operation on a task clone runs in a hardened throwaway container with only what it needs" {
  ag run --id T-41 "x" 2>/dev/null
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"; g="$clone/.git"; m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"; wt="$clone/.worktrees/T-41"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = agentic/T-41-x ]
  call="$(docker_run_with fetch)"
  [ "$(cg_head "$call")" = "$(cg_base "$clone" "$g")-v $m:$m:ro --entrypoint " ]
  [ "$(sed -n '/^--entrypoint$/,$p' <<<"$call" | sed -n '4,11p' | tr '\n' ' ')" = "-c gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null -c core.fsmonitor=false " ]
  grep -qx -- '--no-write-fetch-head' <<<"$call"
  call="$(docker_run_with worktree)"
  [ "$(cg_head "$call")" = "$(cg_base "$clone" "$g")-v $wt:$wt --entrypoint " ]
  grep -qx -- '--no-track' <<<"$call"
  record T-41 idle
  : > "$DOCKER_LOG"
  DOCKER_STATUS=exited run ag clean T-41
  [ "$status" -eq 0 ]
  [ "$(cg_head "$(docker_run_with status)")" = "$(cg_base "$clone" "$g/worktrees/T-41")-v $wt:$wt -e GIT_WORK_TREE=$wt --entrypoint " ]
  [ "$(cg_head "$(docker_run_with remove)")" = "$(cg_base "$clone" "$g")-v $wt:$wt --entrypoint " ]
  [ "$(cg_head "$(docker_run_with prune)")" = "$(cg_base "$clone" "$g")-v $clone/.worktrees:$clone/.worktrees:ro --entrypoint " ]
  [ "$(cg_head "$(docker_run_with -D)")" = "$(cg_base "$clone" "$g")--entrypoint " ]
  [ ! -e "$wt" ]
  run git -C "$clone" rev-parse --verify -q agentic/T-41-x
  [ "$status" -ne 0 ]
}

@test "host git never opens a task clone once it exists: a second run, clean and rollback" {
  ag run --id T-42 "x" 2>/dev/null
  install_git_log
  ag run --id T-43 "y" 2>/dev/null
  record T-43 idle
  DOCKER_STATUS=exited ag clean T-43 >/dev/null
  DOCKER_STATUS=exited DOCKER_RUN_RC=1 run ag run --id T-44 "z"
  [ "$status" -eq 1 ]
  [ -s "$BATS_TEST_TMPDIR/hostgit.log" ]   # the mirror fetches ran through it
  run grep -F "$AGENTIC_WORKSPACES/demo/repos" "$BATS_TEST_TMPDIR/hostgit.log"
  [ "$status" -ne 0 ]
}

@test "the mirror is private: made from the project's remote, never mounted into a task, deaf to the clone's config" {
  ag run --id T-45 "x" 2>/dev/null
  m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"
  [ "$(git --git-dir="$m" rev-parse --is-bare-repository)" = true ]
  run grep -F mirrors "$H/T-45/mounts"
  [ "$status" -ne 0 ]
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  git -C "$clone" config remote.origin.url https://example.invalid/x.git
  git -C "$clone" config http.proxy http://127.0.0.1:9
  git -C "$clone" config "url.https://example.invalid/.insteadOf" "$PROJ"
  git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m second
  ag run --id T-46 "y" 2>/dev/null
  [ "$(git -C "$clone/.worktrees/T-46" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
  [ "$(git --git-dir="$m" config remote.origin.url)" = "$PROJ" ]
}

@test "a --repo clone's origin is recorded in its mirror on first use; the clone's config is not read again" {
  ws="$AGENTIC_WORKSPACES/demo"
  fake_ssh; remote_clone "$PROJ" "$ws/repos/lib"
  ag run --id T-47 --repo lib "x" 2>/dev/null
  m="$AGENTIC_DATA/$MIRRORS_REL/lib.git"
  [ "$(git --git-dir="$m" config remote.origin.url)" = "ssh://example.invalid$PROJ" ]
  git -C "$ws/repos/lib" config remote.origin.url https://example.invalid/x.git
  git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m second
  ag run --id T-48 --repo lib "y" 2>/dev/null
  [ "$(git -C "$ws/repos/lib/.worktrees/T-48" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
}

@test "commands planted in a clone never run on the host: checkout, fetch and clean" {
  ag run --id T-49 "x" 2>/dev/null
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  plant upload; plant smudge cat; plant clean cat; plant askpass
  git -C "$clone" config remote.origin.uploadpack "$BATS_TEST_TMPDIR/upload"
  git -C "$clone" config filter.x.smudge "$BATS_TEST_TMPDIR/smudge"
  git -C "$clone" config filter.x.clean "$BATS_TEST_TMPDIR/clean"
  git -C "$clone" config core.askPass "$BATS_TEST_TMPDIR/askpass"
  echo '* filter=x' > "$clone/.git/info/attributes"
  run ag run --id T-50 "y"
  [ "$status" -eq 0 ]
  grep -qx 'smudge container' "$BATS_TEST_TMPDIR/ran"   # the planted filter is live, and ran in the container
  record T-50 idle
  # a new mtime, same content: status runs the clean filter to compare
  touch -d "@$(( $(date +%s) + 7 ))" "$clone/.worktrees/T-50/.agentic/agentic.yaml"
  DOCKER_STATUS=exited run ag clean T-50
  [ "$status" -eq 0 ]
  grep -qx 'clean container' "$BATS_TEST_TMPDIR/ran"
  run grep -E 'host|upload' "$BATS_TEST_TMPDIR/ran"
  [ "$status" -ne 0 ]
}

@test "FETCH_HEAD and packed-refs symlinks planted in a clone never change a host file" {
  ag run --id T-51 "x" 2>/dev/null
  g="$AGENTIC_WORKSPACES/demo/repos/proj/.git"
  echo keep > "$BATS_TEST_TMPDIR/victim1"; cp "$g/packed-refs" "$BATS_TEST_TMPDIR/victim2"; cp "$BATS_TEST_TMPDIR/victim2" "$BATS_TEST_TMPDIR/victim2.orig"
  rm -f "$g/FETCH_HEAD"; ln -s "$BATS_TEST_TMPDIR/victim1" "$g/FETCH_HEAD"
  ln -sf "$BATS_TEST_TMPDIR/victim2" "$g/packed-refs"
  ag run --id T-52 "y" 2>/dev/null
  record T-52 idle
  DOCKER_STATUS=exited ag clean T-52 >/dev/null
  DOCKER_STATUS=exited ag clean T-51 --force >/dev/null 2>&1 || true
  [ "$(cat "$BATS_TEST_TMPDIR/victim1")" = keep ]
  cmp "$BATS_TEST_TMPDIR/victim2" "$BATS_TEST_TMPDIR/victim2.orig"
}

@test "clean refuses a worktree whose .git does not name one of the clone's worktrees" {
  ag run --id T-53 "x" 2>/dev/null
  record T-53 idle
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-53"
  echo "gitdir: $BATS_TEST_TMPDIR/elsewhere" > "$wt/.git"
  DOCKER_STATUS=exited run ag clean T-53
  [ "$status" -eq 1 ]; [[ "$output" == *"cannot check"* ]]
  rm "$wt/.git"; ln -s "$BATS_TEST_TMPDIR/elsewhere" "$wt/.git"
  DOCKER_STATUS=exited run ag clean T-53
  [ "$status" -eq 1 ]; [[ "$output" == *"cannot check"* ]]
}

@test "the host's own git (mirror fetch) keeps the user's credential helpers, not other command settings" {
  unset GIT_ASKPASS SSH_ASKPASS GIT_PROXY_COMMAND GIT_SSH_COMMAND GIT_SSH
  plant global-helper; plant url-helper
  git config --global credential.helper "!$BATS_TEST_TMPDIR/global-helper"
  git config --global credential.https://example.com.helper "!$BATS_TEST_TMPDIR/url-helper"
  printf 'protocol=https\nhost=example.com\n\n' | GIT_TERMINAL_PROMPT=0 lib ugit credential fill >/dev/null 2>&1 || true
  grep -qx 'global-helper host' "$BATS_TEST_TMPDIR/ran"
  grep -qx 'url-helper host' "$BATS_TEST_TMPDIR/ran"
  [ "$(lib ugit config gc.auto)" = 0 ]
  [ "$(lib ugit config maintenance.auto)" = false ]
  [ "$(lib ugit config protocol.ext.allow)" = never ]
  [ "$(lib ugit config core.sshCommand)" = ssh ]
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

@test "the host's task files (tokens, mounts, repos) live outside the workspace a dev container mounts" {
  ag run --id T-60 "x" 2>/dev/null
  [ "$(stat -c %a "$H/T-60/env")" = 600 ] && [ -f "$H/T-60/mounts" ] && [ -f "$H/T-60/repos" ]
  run ls "$T"
  [ "$output" = T-60 ]
  call="$(docker_run_with agentic-bridge)"
  grep -qx "$H/T-60/env" <<<"$call"
  run grep -F "$AGENTIC_DATA" "$H/T-60/mounts"
  [ "$status" -ne 0 ]
}

@test "a task from before the move: its files are taken from the workspace once" {
  ag run --id T-61 "x" 2>/dev/null
  record T-61 idle
  for f in env mounts repos; do mv "$H/T-61/$f" "$T/T-61.$f"; done
  rmdir "$H/T-61"
  DOCKER_STATUS=exited run ag clean T-61
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-61" ]
  [ ! -e "$T/T-61.repos" ] && [ ! -e "$H/T-61" ]
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

@test "git errors from a clone reach the terminal without control characters" {
  ag run --id T-64 "x" 2>/dev/null
  clone="$AGENTIC_WORKSPACES/demo/repos/proj"
  printf '#!/bin/sh\nprintf "bad\\033[2Jfilter\\n" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/loud"; chmod +x "$BATS_TEST_TMPDIR/loud"
  git -C "$clone" config filter.x.smudge "$BATS_TEST_TMPDIR/loud"; git -C "$clone" config filter.x.required true
  echo '* filter=x' > "$clone/.git/info/attributes"
  run ag run --id T-65 "y"
  [[ "$output" == *"badfilter"* || "$output" == *"bad[2Jfilter"* ]]
  run grep -qP '[\x00-\x08\x0b-\x1f\x7f]' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "run refuses a bind source that goes through a symlink, and drops every capability of the task" {
  mkdir -p "$AGENTIC_WORKSPACES/demo" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$AGENTIC_WORKSPACES/demo/events"
  run ag run --id T-80 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"symlink"* ]]
  [ -z "$(docker_run_with agentic-bridge)" ]
  [ ! -e "$T/T-80" ] && [ ! -e "$H/T-80" ]
  rm "$AGENTIC_WORKSPACES/demo/events"
  ag run --id T-81 "x" 2>/dev/null
  call="$(docker_run_with agentic-bridge)"
  grep -A1 -x -- '--cap-drop' <<<"$call" | grep -qx ALL
  grep -A1 -x -- '--security-opt' <<<"$call" | grep -qx no-new-privileges
}

@test "rollback and clean take no clone or worktree path with .. or a symlink in it" {
  mkdir -p "$BATS_TEST_TMPDIR/keep" "$BATS_TEST_TMPDIR/keep2"; touch "$BATS_TEST_TMPDIR/keep/f" "$BATS_TEST_TMPDIR/keep2/f"
  mkdir -p "$AGENTIC_WORKSPACES/demo/repos"
  ln -s "$BATS_TEST_TMPDIR" "$AGENTIC_WORKSPACES/demo/repos/link"
  record T-82 idle
  r="$AGENTIC_WORKSPACES/demo/repos"
  # both name the real repository $PROJ (with a .git) from inside repos/
  printf '%s\t%s\tb\n' "$r/x/../../../../proj" "$r/x/../../../../keep2" "$r/link/proj" "$r/link/keep2" > "$H/T-82/repos"
  lib rollback_task T-82
  [ -f "$BATS_TEST_TMPDIR/keep/f" ] && [ -f "$BATS_TEST_TMPDIR/keep2/f" ]
  run grep -E -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  [ -d "$PROJ/.git" ]
  record T-83 idle
  mkdir -p "$PROJ/.worktrees/T-83"
  printf '%s\t%s\tb\n' "$r/link/proj" "$r/link/proj/.worktrees/T-83" > "$H/T-83/repos"
  DOCKER_STATUS=exited run ag clean T-83
  [ "$status" -eq 1 ]; [[ "$output" == *"cannot check"* ]]
  run grep -E -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
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
  # an old-layout file that turns out not to be a regular file after the move is refused
  record T-86 idle
  rm -rf "$H/T-86"; ln -s "$BATS_TEST_TMPDIR/victim" "$T/T-86.env"
  run ag send T-86 "x"
  [ "$status" -ne 0 ]
  [ ! -e "$H/T-86/env" ]
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

@test "an origin URL that is a git option never runs on the host: project, --repo and the mirror fetch" {
  X="$BATS_TEST_TMPDIR/pwned"; bad="--upload-pack=touch $X;git-upload-pack"
  # first use: the checkout's origin is refused, nothing is mirrored
  git -C "$PROJ" config remote.origin.url "$bad"
  run ag run --id T-90 "x"
  [ "$status" -ne 0 ]; [[ "$output" == *"starts with -"* ]]
  [ ! -e "$X" ]; [ ! -e "$AGENTIC_DATA/$MIRRORS_REL/proj.git" ]
  # after the mirror is made, the checkout's origin is no longer read
  git -C "$PROJ" config --unset remote.origin.url
  ag run --id T-91 "x" 2>/dev/null
  git -C "$PROJ" config remote.origin.url "$bad"
  run ag run --id T-92 "y"
  [ "$status" -eq 0 ]; [ ! -e "$X" ]
  # a --repo clone's origin on first use
  git clone -q "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/lib"
  git -C "$AGENTIC_WORKSPACES/demo/repos/lib" config remote.origin.url "$bad"
  run ag run --id T-93 --repo lib "z"
  [ "$status" -ne 0 ]; [[ "$output" == *"starts with -"* ]]; [ ! -e "$X" ]
  # the mirror fetch and clone take the URL as an operand, never as an option
  lib sync_mirror proj "$bad" 2>/dev/null || true
  lib sync_mirror other "$bad" 2>/dev/null || true
  [ ! -e "$X" ]
}

@test "the project's URL is pinned in its mirror when first made; deleting the mirror takes the origin again" {
  ag run --id T-94 "x" 2>/dev/null
  m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"
  [ "$(git --git-dir="$m" config remote.origin.url)" = "$PROJ" ]
  OTHER="$BATS_TEST_TMPDIR/other"; git init -q -b main "$OTHER"
  git -C "$OTHER" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m other
  fake_ssh; git -C "$PROJ" remote add origin "ssh://example.invalid$OTHER"
  git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m second
  git -C "$PROJ" update-ref refs/remotes/origin/main "$(git -C "$PROJ" rev-parse HEAD)"
  ag run --id T-95 "y" 2>/dev/null
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees"
  [ "$(git -C "$wt/T-95" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
  [ "$(git --git-dir="$m" config remote.origin.url)" = "$PROJ" ]
  rm -rf "$m"
  ag run --id T-96 "z" 2>/dev/null
  [ "$(git --git-dir="$m" config remote.origin.url)" = "ssh://example.invalid$OTHER" ]
  [ "$(git -C "$wt/T-96" rev-parse HEAD)" = "$(git -C "$OTHER" rev-parse HEAD)" ]
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

@test "wt_gitdir reads the worktree's .git file without following a symlink or blocking" {
  clone="$BATS_TEST_TMPDIR/c"; wt="$clone/.worktrees/T-1"; mkdir -p "$wt"
  echo "gitdir: $clone/.git/worktrees/T-1" > "$wt/.git"
  [ "$(lib wt_gitdir "$clone" "$wt")" = "$clone/.git/worktrees/T-1" ]
  mv "$wt/.git" "$BATS_TEST_TMPDIR/g"; ln -s "$BATS_TEST_TMPDIR/g" "$wt/.git"
  run lib wt_gitdir "$clone" "$wt"; [ "$status" -ne 0 ]
  rm "$wt/.git"; mkfifo "$wt/.git"
  run timeout 10 bash -c "cd '$PROJ' && source '$REPO_ROOT/lib/host/common.sh' && source '$REPO_ROOT/lib/host/task.sh' && wt_gitdir '$clone' '$wt'"
  [ "$status" -ne 0 ]; [ "$status" -ne 124 ]
}

@test "a pinned origin must be https, ssh, git or scp-style: a local path, file:// and a transport helper are refused" {
  fake_ssh
  OTHER="$BATS_TEST_TMPDIR/other"; git init -q -b main "$OTHER"
  git -C "$OTHER" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m other
  m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"; n=0
  for bad in /other/host/repo "$OTHER" file:///x "file://$OTHER" foo::bar "ext::sh -c touch% $BATS_TEST_TMPDIR/pwned"; do
    n=$((n + 1))
    git -C "$PROJ" config remote.origin.url "$bad"
    run ag run --id "T-A$n" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an https://, ssh://, git:// or scp-style [user@]host:path URL; refused"* ]]
    [ ! -e "$m" ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  # a --repo clone's origin on first use
  git -C "$PROJ" config --unset remote.origin.url
  remote_clone "$OTHER" "$AGENTIC_WORKSPACES/demo/repos/lib"
  git -C "$AGENTIC_WORKSPACES/demo/repos/lib" remote set-url origin "file://$OTHER"
  run ag run --id T-A9 --repo lib "x"
  [ "$status" -ne 0 ]; [[ "$output" == *"scp-style [user@]host:path URL; refused"* ]]
  [ ! -e "$AGENTIC_DATA/$MIRRORS_REL/lib.git" ]
}

@test "an https origin is accepted and pinned" {
  fake_ssh
  git -C "$PROJ" remote add origin "https://example.invalid$PROJ"
  git -C "$PROJ" update-ref refs/remotes/origin/main "$(git -C "$PROJ" rev-parse HEAD)"
  [ "$(lib project_url)" = "https://example.invalid$PROJ" ]
  # the user's own rewrite to the fake ssh, so the mirror can be made here
  git config --global url.ssh://example.invalid/.insteadOf https://example.invalid/
  run ag run --id T-B1 "x"
  [ "$status" -eq 0 ]
  m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"
  [ "$(git --git-dir="$m" rev-parse --is-bare-repository)" = true ]
  [ "$(git -C "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-B1" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
  for u in "ssh://git@example.invalid/x.git" "git://example.invalid/x.git" "git@example.invalid:x/y.git" "example.invalid:x.git"; do
    lib remote_url_ok "$u"
  done
}

@test "host git talks to a remote only over https, ssh and git; file only for the project root and the mirror" {
  [ "$(lib ugit config protocol.allow)" = never ]
  for p in https ssh git; do [ "$(lib ugit config "protocol.$p.allow")" = always ]; done
  run lib ugit config protocol.file.allow
  [ "$status" -ne 0 ]
  # the project root (no origin) is the fallback: mirrored and cloned over file
  ag run --id T-C1 "x" 2>/dev/null
  m="$AGENTIC_DATA/$MIRRORS_REL/proj.git"
  [ "$(git --git-dir="$m" config remote.origin.url)" = "$PROJ" ]
  # a mirror that recorded another local path fetches nothing from it
  OTHER="$BATS_TEST_TMPDIR/other"; git init -q -b main "$OTHER"
  git -C "$OTHER" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m other
  git --git-dir="$m" config remote.origin.url "$OTHER"
  ag run --id T-C2 "y" 2>/dev/null || true
  run git --git-dir="$m" cat-file -e "$(git -C "$OTHER" rev-parse HEAD)"
  [ "$status" -ne 0 ]
}

@test "host git in the checkout runs without fsmonitor or hooks" {
  install_git_log
  git -C "$PROJ" config user.name t
  ag run --id T-D1 "x" 2>/dev/null
  log="$BATS_TEST_TMPDIR/hostgit.log"
  for c in "rev-parse --show-toplevel" "remote get-url origin" "config user.name"; do
    grep -qF -- "args: -c core.fsmonitor=false -c core.hooksPath=/dev/null -C $PROJ $c" "$log"
  done
  run grep -E -- "args: -C " "$log"
  [ "$status" -ne 0 ]
}
