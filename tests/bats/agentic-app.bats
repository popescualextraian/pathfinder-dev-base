#!/usr/bin/env bats
# agentic-app: apps of the resolved config in tmux windows app-<name>, on a tmux server of the test's
# own (AGENTIC_TMUX), with a curl stand-in for the bridge and an ss stand-in for idle_stop.
load helpers

setup() {
  command -v tmux >/dev/null || { echo "tmux is required for these tests" >&2; return 1; }
  make_tmp_home
  export AGENTIC_STATE="$HOME/.agentic" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  export AGENTIC_TMUX="tmux -L aga-$$-$BATS_TEST_NUMBER" AGENTIC_WINDOW_SHELL="bash -c" AGENTIC_APP_STOP_WAIT=2
  export AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 AGENTIC_AGENT_TOKEN=agent-token AGENTIC_TASK_TOKEN=task-token
  export AGENTIC_IDLE_POLL=0.3
  mkdir -p "$AGENTIC_STATE" "$AGENTIC_WORK/frontend" "$AGENTIC_WORK/.agentic" "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "$AGENTIC_WORK/.agentic" > "$AGENTIC_STATE/config-dir"
  echo 'export GREETING=hi' > "$AGENTIC_STATE/env"
  # the bridge: each call logs its arguments, the header file's mode and content, and the body
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
{ echo "--- curl"; for a in "$@"; do echo "arg: $a"
    case "$a" in @/*) echo "mode: $(stat -c %a "${a#@}")"; sed 's/^/header: /' "${a#@}" ;; esac; done
  echo "body: $(cat)"; } >> "$CURL_LOG"
exit "${CURL_RC:-0}"
EOF
  # ss: logs its arguments; prints $BATS_TEST_TMPDIR/ss.out when it exists (a connection)
  cat > "$BATS_TEST_TMPDIR/bin/ss" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$BATS_TEST_TMPDIR/ss.log"
if [ -f "$BATS_TEST_TMPDIR/ss.out" ]; then cat "$BATS_TEST_TMPDIR/ss.out"; fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/ss"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  jq -n '{project: "demo", apps: {
      web: {run: "echo web-$GREETING-$MODE-$(basename $PWD); sleep 30", ports: [5173], dir: "frontend", env: {MODE: "dev"}},
      bad: {run: "echo boom >&2; exit 3"},
      stubborn: {run: "trap \"\" INT; sleep 30"} }}' > "$AGENTIC_STATE/config.json"
  X="$REPO_ROOT/image/bin/agentic-app"
}

teardown() {
  $AGENTIC_TMUX kill-server 2>/dev/null || true
  # the idle loop this test's starts launched, found by its pid file
  if [ -f "$AGENTIC_STATE/apps/idle-loop.pid" ]; then kill "$(cat "$AGENTIC_STATE/apps/idle-loop.pid")" 2>/dev/null || true; fi
}

# conf FILTER: config.json changed by a jq filter.
conf() { jq "$1" "$AGENTIC_STATE/config.json" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$AGENTIC_STATE/config.json"; }
pane() { sleep "${2:-0.7}"; $AGENTIC_TMUX capture-pane -p -t "apps:=app-$1"; }
windows() { $AGENTIC_TMUX list-windows -t apps -F '#{window_name}' 2>/dev/null || true; }
posts() { grep '^body: ' "$CURL_LOG" 2>/dev/null | sed 's/^body: //' || true; }
actions() { posts | jq -r --arg n "$1" 'select(.name == $n) | .action' | tr '\n' ' '; }
field() { jq -c --arg n "$1" ".[] | select(.name == \$n) | $2" <<<"$output"; }
# no_ctl TEXT: no C0 control but tab and newline, no DEL, no UTF-8 C1 control (a failing call fails the test)
no_ctl() {
  if printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]'; then return 1; fi
  if printf '%s' "$1" | LC_ALL=C grep -qE $'\xc2[\x80-\x9f]'; then return 1; fi
  return 0
}

@test "start opens window app-NAME in the checkout's dir with the start env and the app's env, and posts started" {
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [ "$(windows | grep -cx app-web)" -eq 1 ]
  [[ "$(pane web)" == *"web-hi-dev-frontend"* ]]
  [ "$(posts | jq -c 'select(.action == "started")')" = '{"name":"web","action":"started","exit_code":null}' ]
  grep -qx "arg: $AGENTIC_BRIDGE_URL/app" "$CURL_LOG"
  grep -qx 'header: Authorization: Bearer agent-token' "$CURL_LOG"
  grep -qx 'mode: 600' "$CURL_LOG"
  # the token reaches curl only through the header file
  ! grep -q '^arg: .*agent-token' "$CURL_LOG"
}

@test "agentic-app uses the tmux server agentic-apps by default" {
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$BATS_TEST_TMPDIR/tmux.log" > "$BATS_TEST_TMPDIR/bin/tmux"
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  unset AGENTIC_TMUX
  run bash "$X" start web
  [ -s "$BATS_TEST_TMPDIR/tmux.log" ]
  ! grep -v '^-L agentic-apps ' "$BATS_TEST_TMPDIR/tmux.log"
}

@test "start of a running app is a no-op: one window, one started" {
  bash "$X" start web
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [[ "$output" == *"app web is already running"* ]]
  [ "$(windows | grep -cx app-web)" -eq 1 ]
  [ "$(actions web)" = "started " ]
}

@test "two quick starts of the same app open one window" {
  conf '.apps.web.prepare = "sleep 1"'
  bash "$X" start web & a=$!
  bash "$X" start web & b=$!
  wait "$a"; wait "$b"
  [ "$(windows | grep -cx app-web)" -eq 1 ]
  [ "$(actions web)" = "started " ]
}

@test "an unknown name exits 1 with unknown app; a name with specials is refused before tmux" {
  run bash "$X" start nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown app nope"* ]]
  for n in 'web;x' 'a#b' 'a b' 'Web' ''; do
    run bash "$X" start "$n"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad app name"* ]]
  done
  run bash "$X" logs nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown app nope"* ]]
  [ -z "$(windows)" ]
}

@test "the apps come from the resolved config, never from the checkout's agentic.yaml" {
  printf 'apps:\n  web:\n    run: echo from-the-file; sleep 30\n' > "$AGENTIC_WORK/.agentic/agentic.yaml"
  bash "$X" start web
  out="$(pane web)"
  [[ "$out" == *web-hi-dev-frontend* ]]
  [[ "$out" != *from-the-file* ]]
}

@test "prepare runs once, in dir with env, before the first start" {
  conf '.apps.web.prepare = "echo prep-$MODE-$(basename $PWD) >> \"$HOME/prep.log\""'
  bash "$X" start web
  [ "$(cat "$HOME/prep.log")" = prep-dev-frontend ]
  [ -e "$AGENTIC_STATE/apps/web.prepared" ]
  bash "$X" restart web
  bash "$X" stop web
  bash "$X" start web
  [ "$(wc -l < "$HOME/prep.log")" -eq 1 ]
  [[ "$(pane web)" == *web-hi-dev-frontend* ]]
}

@test "a failing prepare: no window, its last 20 lines printed, state failed, event failed" {
  conf '.apps.web.prepare = "for i in $(seq 1 30); do echo prep-line-$i; done; exit 5"'
  run bash "$X" start web
  [ "$status" -eq 1 ]
  [[ "$output" == *"prepare of web failed (exit 5)"* ]]
  [[ "$output" == *prep-line-11* && "$output" == *prep-line-30* ]]
  [[ "$output" != *prep-line-10$'\n'* ]]
  [ -z "$(windows | grep -x app-web || true)" ]
  [ "$(posts | jq -c 'select(.action == "failed")')" = '{"name":"web","action":"failed","exit_code":5}' ]
  run bash "$X" list --json
  [ "$(field web '[.state, .exit_code]')" = '["failed",5]' ]
  [ "$(field web '.since | type')" = '"number"' ]
  # logs of a failed app show the prepare's output
  run bash "$X" logs web --lines 3
  [ "$status" -eq 0 ]
  [[ "$output" == *prep-line-30* && "$output" != *prep-line-27* ]]
  # it is not marked prepared: the next start prepares again
  [ ! -e "$AGENTIC_STATE/apps/web.prepared" ]
}

@test "a prepare that hangs is ended by the timeout and the state is failed" {
  conf '.apps.web.prepare = "echo waiting; sleep 30"'
  SECONDS=0
  AGENTIC_PREPARE_TIMEOUT=1 run bash "$X" start web
  [ "$status" -eq 1 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" == *"timed out after 1 s"* ]]
  [[ "$output" == *waiting* ]]
  run bash "$X" list --json
  [ "$(field web '[.state, .exit_code]')" = '["failed",124]' ]
}

@test "list shows preparing while prepare runs" {
  conf '.apps.web.prepare = "sleep 2"'
  bash "$X" start web & p=$!
  sleep 0.7
  run bash "$X" list --json
  [ "$(field web '.state')" = '"preparing"' ]
  wait "$p"
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
}

@test "env_files are copied from .agentic before prepare, only when missing; a missing source warns" {
  printf 'A=1\n' > "$AGENTIC_WORK/.agentic/web.env"
  printf 'B=2\n' > "$AGENTIC_WORK/.agentic/keep.env"
  printf 'old\n' > "$AGENTIC_WORK/frontend/keep.env"
  conf '.apps.web.env_files = [{from: "web.env", to: "frontend/conf/.env.local"}, {from: "keep.env", to: "frontend/keep.env"}, {from: "gone.env", to: "gone.env"}]
        | .apps.web.prepare = "cat conf/.env.local > \"$HOME/seen\""'
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/seen")" = A=1 ]
  [ "$(cat "$AGENTIC_WORK/frontend/keep.env")" = old ]
  [ ! -e "$AGENTIC_WORK/gone.env" ]
  [[ "$output" == *"env_files: gone.env is no file in .agentic/; skipped"* ]]
}

@test "env_files with .. or an absolute path are refused even past validation" {
  conf '.apps.web.env_files = [{from: "../x", to: "a"}, {from: "a", to: "/etc/x"}]'
  run bash "$X" start web
  [[ "$output" == *"env_files: ../x -> a is not a relative path without ..; skipped"* ]]
  [[ "$output" == *"env_files: a -> /etc/x is not a relative path without ..; skipped"* ]]
}

@test "stop interrupts, removes the window, runs teardown in dir with env, posts stopped and no exited" {
  conf '.apps.web.teardown = "echo down-$MODE-$(basename $PWD) >> \"$HOME/down.log\""'
  bash "$X" start web; sleep 0.5
  run bash "$X" stop web
  [ "$status" -eq 0 ]
  sleep 0.5
  [ "$(cat "$HOME/down.log")" = down-dev-frontend ]
  [ "$(actions web)" = "started stopped " ]
  [ -z "$(windows | grep -x app-web || true)" ]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"stopped"' ]
  # stop of a stopped app does nothing, teardown included
  run bash "$X" stop web
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HOME/down.log")" -eq 1 ]
}

@test "a failing teardown fails the stop with its last lines; the app is stopped" {
  conf '.apps.web.teardown = "echo bye >&2; exit 4"'
  bash "$X" start web; sleep 0.3
  run bash "$X" stop web
  [ "$status" -eq 1 ]
  [[ "$output" == *"teardown of web failed (exit 4)"* && "$output" == *bye* ]]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"stopped"' ]
}

@test "an app that ignores C-c is killed after the wait" {
  bash "$X" start stubborn; sleep 0.5
  SECONDS=0
  run bash "$X" stop stubborn
  [ "$status" -eq 0 ]
  [ "$SECONDS" -ge 2 ]
  run bash "$X" list --json
  [ "$(field stubborn '.state')" = '"stopped"' ]
}

@test "restart is stop, with its teardown, then start" {
  conf '.apps.web.teardown = "echo down >> \"$HOME/down.log\""'
  bash "$X" start web; sleep 0.3
  run bash "$X" restart web
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HOME/down.log")" -eq 1 ]
  [ "$(actions web)" = "started stopped started " ]
  [[ "$(pane web)" == *web-hi-dev-frontend* ]]
}

@test "an app that exits keeps its window and output, and posts exited with its code" {
  bash "$X" start bad
  sleep 1
  run bash "$X" list --json
  [ "$(field bad '[.state, .exit_code]')" = '["exited",3]' ]
  run bash "$X" logs bad
  [[ "$output" == *boom* ]]
  [ "$(posts | jq -c 'select(.action == "exited")')" = '{"name":"bad","action":"exited","exit_code":3}' ]
  # a start replaces the finished window
  run bash "$X" start bad
  [ "$status" -eq 0 ]
  [ "$(windows | grep -cx app-bad)" -eq 1 ]
}

@test "list gives name, state, ports, url and since for every app" {
  conf '.apps.web.url = "/app/"'
  bash "$X" start web
  run bash "$X" list --json
  [ "$status" -eq 0 ]
  [ "$(field web '[.state, .ports, .url, (.since | type)]')" = '["running",[5173],"/app/","number"]' ]
  [ "$(field bad '[.state, .ports, .url, .since]')" = '["stopped",[],"/",null]' ]
  [ "$(jq -c '.[0] | keys' <<<"$output")" = '["exit_code","name","ports","since","state","url"]' ]
  run bash "$X" list
  [[ "$output" == *"web"*"running"*"5173"* ]]
}

@test "list with no apps is []" {
  echo '{"project": "demo"}' > "$AGENTIC_STATE/config.json"
  run bash "$X" list --json
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "logs returns the last N lines without control characters; N is 1 to 2000" {
  conf '.apps.loud = {run: "for i in $(seq 1 50); do echo line-$i; done; printf \"\\033[31mred\\033[0m bell\\a cr\\r\\n\"; sleep 30"}'
  bash "$X" start loud; sleep 0.8
  run bash "$X" logs loud --lines 5
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "$output" == *line-49* && "$output" == *"red bell cr"* && "$output" != *line-45* ]]
  no_ctl "$output"
  run bash "$X" logs loud --lines 2001
  [ "$status" -eq 1 ]
  run bash "$X" logs loud --lines x
  [ "$status" -eq 1 ]
  run bash "$X" logs loud --lines 2000
  [ "$status" -eq 0 ]
  [[ "$output" == *line-1$'\n'* ]]
  run bash "$X" logs web
  [ "$status" -eq 1 ]
  [[ "$output" == *"app web is not running"* ]]
}

@test "without a bridge nothing is posted; a failing post does not fail the command" {
  unset AGENTIC_BRIDGE_URL
  run bash "$X" start web
  [ "$status" -eq 0 ]
  bash "$X" start bad; sleep 1
  bash "$X" stop web
  [ ! -e "$CURL_LOG" ]
  export AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 CURL_RC=7
  run bash "$X" start web
  [ "$status" -eq 0 ]
}

@test "the app gets no bridge token; the wrapper that holds the agent token is private" {
  conf '.apps.tok = {run: "echo tok=${AGENTIC_AGENT_TOKEN:-none}/${AGENTIC_TASK_TOKEN:-none}; sleep 5", prepare: "echo p=${AGENTIC_AGENT_TOKEN:-none} > \"$HOME/p\""}'
  bash "$X" start tok
  [[ "$(pane tok)" == *"tok=none/none"* ]]
  [ "$(cat "$HOME/p")" = p=none ]
  [ "$(stat -c %a "$AGENTIC_STATE/apps/tok.sh")" = 600 ]
  ! grep -q task-token "$AGENTIC_STATE/apps/tok.sh"
}

@test "an exit is posted when the tmux server was started without the bridge env" {
  env -u AGENTIC_AGENT_TOKEN -u AGENTIC_BRIDGE_URL $AGENTIC_TMUX new-session -d -s apps -n home
  bash "$X" start bad
  sleep 1
  [ "$(posts | jq -c 'select(.action == "exited")')" = '{"name":"bad","action":"exited","exit_code":3}' ]
}

@test "a hash in the dir and the state path is not expanded by tmux; values pass literally" {
  mkdir -p "$AGENTIC_WORK/a#b"
  conf '.apps.hash = {run: "echo \"dir=$(basename \"$PWD\") v=$V\"; echo lit#1 ; sleep 5", dir: "a#b", env: {V: "$(touch pwned) `touch pwned2` ${HOME} #x;y"}}'
  mkdir -p "$BATS_TEST_TMPDIR/st#x"; cp "$AGENTIC_STATE"/{config.json,env,config-dir} "$BATS_TEST_TMPDIR/st#x/"
  export AGENTIC_STATE="$BATS_TEST_TMPDIR/st#x"
  run bash "$X" start hash
  [ "$status" -eq 0 ]
  out="$(pane hash)"
  [[ "$out" == *'dir=a#b v=$(touch pwned) `touch pwned2` ${HOME} #x;y'* ]]
  [[ "$out" == *'lit#1'* ]]
  [ ! -e "$AGENTIC_WORK/a#b/pwned" ] && [ ! -e "$AGENTIC_WORK/a#b/pwned2" ]
}

@test "a missing dir fails the start with the path" {
  conf '.apps.web.dir = "nowhere"'
  run bash "$X" start web
  [ "$status" -eq 1 ]
  [[ "$output" == *"dir nowhere does not exist in the checkout"* ]]
}

@test "idle_stop stops an app whose ports saw no connection for the set time, and posts stopped" {
  conf '.apps.web.idle_stop = "2s"'
  bash "$X" start web
  sleep 1
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
  for _ in $(seq 1 30); do [ "$(actions web)" = "started stopped " ] && break; sleep 0.2; done
  [ "$(actions web)" = "started stopped " ]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"stopped"' ]
  grep -q 'sport = :5173' "$BATS_TEST_TMPDIR/ss.log"
}

@test "idle_stop keeps an app with connections running, and stops it once they end" {
  conf '.apps.web.idle_stop = "2s"'
  echo '0 0 127.0.0.1:5173 127.0.0.1:40000' > "$BATS_TEST_TMPDIR/ss.out"
  bash "$X" start web
  sleep 3.5
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
  rm "$BATS_TEST_TMPDIR/ss.out"
  for _ in $(seq 1 30); do [ "$(actions web)" = "started stopped " ] && break; sleep 0.2; done
  [ "$(actions web)" = "started stopped " ]
}

@test "idle_stop without ss reads the connections from /proc/net/tcp" {
  export AGENTIC_SS=no-such-ss AGENTIC_PROC_NET="$BATS_TEST_TMPDIR/net"
  mkdir -p "$AGENTIC_PROC_NET"
  # 5173 is 0x1435; st 01 is an established connection
  printf '  sl  local_address rem_address   st\n   0: 0100007F:1435 0100007F:9C40 01 0\n' > "$AGENTIC_PROC_NET/tcp"
  conf '.apps.web.idle_stop = "2s"'
  bash "$X" start web
  sleep 3.5
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
  printf '  sl  local_address rem_address   st\n   0: 0100007F:1435 00000000:0000 0A 0\n' > "$AGENTIC_PROC_NET/tcp"
  for _ in $(seq 1 30); do [ "$(actions web)" = "started stopped " ] && break; sleep 0.2; done
  [ "$(actions web)" = "started stopped " ]
}

@test "idle_stop 0 or unset never stops the app" {
  conf '.apps.web.idle_stop = "0"'
  bash "$X" start web
  sleep 1.5
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
  [ ! -e "$BATS_TEST_TMPDIR/ss.log" ]
}

@test "no arguments print the usage and fail; help prints it" {
  run bash "$X"
  [ "$status" -eq 1 ]
  [[ "$output" == *usage* ]]
  run bash "$X" help
  [ "$status" -eq 0 ]
  [[ "$output" == *usage* ]]
}

# --- fix round 1

@test "an agentic-app killed mid-prepare: the next start refuses while that prepare lives, then prepares again" {
  conf '.apps.web.prepare = "echo p >> \"$HOME/prep.log\"; sleep 2"'
  bash "$X" start web & p=$!
  sleep 0.7
  kill "$p"; wait "$p" || true
  read -r pid st < "$AGENTIC_STATE/apps/web.preparing"
  [ "$pid" != "$p" ]
  kill -0 "$pid"
  # the marker keeps the prepare's start time from /proc/PID/stat (field 22)
  [ "$st" = "$(sed 's/.*) //' "/proc/$pid/stat" | cut -d' ' -f20)" ]
  run bash "$X" start web
  [ "$status" -eq 1 ]
  [[ "$output" == *"app web is preparing"* ]]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"preparing"' ]
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HOME/prep.log")" -eq 2 ]
}

@test "a stale preparing marker with a dead pid is cleared by the next start" {
  conf '.apps.web.prepare = "true"'
  sh -c 'exit 0' & dp=$!; wait "$dp"
  mkdir -p "$AGENTIC_STATE/apps"; echo "$dp" > "$AGENTIC_STATE/apps/web.preparing"
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/apps/web.preparing" ]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
}

@test "a preparing marker whose pid lives but started at another time (a container restart) is stale" {
  conf '.apps.web.prepare = "true"'
  sleep 30 & lp=$!
  mkdir -p "$AGENTIC_STATE/apps"
  for marker in "$lp 1" "$lp"; do
    echo "$marker" > "$AGENTIC_STATE/apps/web.preparing"
    run bash "$X" list --json
    [ "$(field web '.state')" = '"stopped"' ]
    [ ! -e "$AGENTIC_STATE/apps/web.preparing" ]
  done
  echo "$lp 1" > "$AGENTIC_STATE/apps/web.preparing"
  run bash "$X" start web
  kill "$lp"
  [ "$status" -eq 0 ]
  run bash "$X" list --json
  [ "$(field web '.state')" = '"running"' ]
}

@test "the start step 07-apps clears the preparing markers a container restart left" {
  mkdir -p "$AGENTIC_STATE/apps"
  echo "1 1" > "$AGENTIC_STATE/apps/web.preparing"; echo "2 2" > "$AGENTIC_STATE/apps/api.preparing"
  : > "$AGENTIC_STATE/apps/web.prepared"
  run bash "$REPO_ROOT/image/start.d/07-apps.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_STATE/apps/web.preparing" ] && [ ! -e "$AGENTIC_STATE/apps/api.preparing" ]
  [ -e "$AGENTIC_STATE/apps/web.prepared" ]
  rm -rf "$AGENTIC_STATE/apps"
  run bash "$REPO_ROOT/image/start.d/07-apps.sh"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/image/start.d/07-apps.sh" --check
  [ "$status" -eq 0 ]
}

@test "stop of an app that is preparing is refused" {
  conf '.apps.web.prepare = "sleep 2"'
  bash "$X" start web & p=$!
  sleep 0.7
  run bash "$X" stop web
  [ "$status" -eq 1 ]
  [[ "$output" == *"app web is preparing"* ]]
  wait "$p"
}

@test "the printed last lines of a failed prepare and teardown carry no control characters" {
  conf '.apps.web.prepare = "printf \"bad\\033[31mred\\a c1\\xc2\\x9bx\\n\"; exit 2"'
  run bash "$X" start web
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad[31mred c1x"* ]]
  no_ctl "$output"
  run bash "$X" logs web
  [[ "$output" == *"bad[31mred c1x"* ]]
  no_ctl "$output"
  conf '.apps.web.prepare = null | .apps.web.teardown = "printf \"down\\033x\\a\\n\"; exit 3"'
  bash "$X" start web
  run bash "$X" stop web
  [ "$status" -eq 1 ]
  [[ "$output" == *downx* ]]
  no_ctl "$output"
}

@test "logs caps each line at 4000 bytes" {
  conf '.apps.wide = {run: "head -c 5000 /dev/zero | tr \"\\\\0\" a; echo; sleep 30"}'
  bash "$X" start wide; sleep 0.8
  run bash "$X" logs wide
  [ "$status" -eq 0 ]
  [[ "$output" == *aaaa* ]]
  [ "$(printf '%s\n' "$output" | awk '{ if (length($0) > m) m = length($0) } END { print m }')" -le 4000 ]
}

@test "env_files through a symlink out of .agentic/ or out of the checkout are skipped" {
  mkdir -p "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/outside2"
  printf 'S=secret\n' > "$BATS_TEST_TMPDIR/outside/secret.env"
  printf 'A=1\n' > "$AGENTIC_WORK/.agentic/ok.env"
  ln -s "$BATS_TEST_TMPDIR/outside" "$AGENTIC_WORK/.agentic/out"
  ln -s "$BATS_TEST_TMPDIR/outside2" "$AGENTIC_WORK/linkdir"
  conf '.apps.web.env_files = [{from: "out/secret.env", to: "s.env"}, {from: "ok.env", to: "linkdir/x.env"}]'
  run bash "$X" start web
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTIC_WORK/s.env" ]
  [ ! -e "$BATS_TEST_TMPDIR/outside2/x.env" ]
  [[ "$output" == *"env_files: out/secret.env -> s.env leaves .agentic/ or the checkout; skipped"* ]]
  [[ "$output" == *"env_files: ok.env -> linkdir/x.env leaves .agentic/ or the checkout; skipped"* ]]
}

@test "a dir with .. or an absolute dir is refused even past validation" {
  for d in ../up /tmp a/../../b; do
    conf ".apps.web.dir = \"$d\""
    run bash "$X" start web
    [ "$status" -eq 1 ]
    [[ "$output" == *"dir $d must be a relative path inside the checkout"* ]]
  done
  [ -z "$(windows | grep -x app-web || true)" ]
}

@test "two concurrent stops run the teardown once" {
  conf '.apps.web.teardown = "echo down >> \"$HOME/down.log\"; sleep 1"'
  bash "$X" start web; sleep 0.3
  bash "$X" stop web & a=$!
  bash "$X" stop web & b=$!
  wait "$a"; wait "$b"
  [ "$(wc -l < "$HOME/down.log")" -eq 1 ]
  [ "$(actions web)" = "started stopped " ]
}

@test "an app name in the config that fails the name rule is skipped by list" {
  conf '.apps["bad;name x"] = {run: "true"}'
  run bash "$X" list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = bad,stubborn,web ]
}
