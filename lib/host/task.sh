#!/usr/bin/env bash
# Host-side helpers for detached tasks (spec §15). Source after lib/host/common.sh. TASK_PROJECT
# overrides the project (status --all walks every project).
TASK_PORT=8765
TASK_ACTIVE="starting running waiting idle"

task_project() { printf '%s\n' "${TASK_PROJECT:-$(project_name)}"; }
# The workspace root is canonical (no symlink).
task_ws() { printf '%s/%s\n' "$(realpath -m -- "$AGENTIC_WORKSPACES")" "$(task_project)"; }
task_dir() { printf '%s/tasks/%s\n' "$(task_ws)" "$1"; }
# The host's own files of a task (tokens and the bridge's settings, the container, the interrupted
# marker) live outside the workspace, which task and dev containers can write: task_hdir is never mounted.
# shellcheck disable=SC2034 # read by cmd_run in bin/agentic
TASK_HOST_FILES=(env container interrupted)
task_hdir() { printf '%s/projects/%s/tasks/%s\n' "$AGENTIC_DATA" "$(task_project)" "$1"; }
task_file() { printf '%s/%s\n' "$(task_hdir "$1")" "$2"; }
# host_file ID NAME: the host file NAME of a task, when it is a regular file and no symlink.
host_file() { local f; f="$(task_file "$1" "$2")"; [ -f "$f" ] && [ ! -L "$f" ] && printf '%s\n' "$f"; }
# read_agent_file FILE: FILE's content, opened without following a symlink and without blocking
# (a FIFO gives nothing).
read_agent_file() { dd if="$1" iflag=nofollow,nonblock status=none 2>/dev/null; }
# task_readable ID NAME: NAME in the task directory, which the agent writes, is a regular file and
# no symlink, under no symlinked directory: the host never prints a host file or blocks on a FIFO.
task_readable() {
  local d; d="$(task_dir "$1")"
  [ ! -L "$(task_ws)/tasks" ] && [ ! -L "$d" ] && [ -f "$d/$2" ] && [ ! -L "$d/$2" ]
}
# task_read ID NAME: the content of NAME in the task directory, when task_readable, read with
# read_agent_file; 1 otherwise.
task_read() { task_readable "$1" "$2" && read_agent_file "$(task_dir "$1")/$2"; }
# task_container ID: the container the task runs in (line 1 of its host file container), else the
# one run creates for it. Never taken from the record, which the agent can write.
task_container() {
  local f n
  if f="$(host_file "$1" container)"; then
    n="$(sed -n 1p "$f")"
    if [[ "$n" =~ ^agentic-[a-z0-9-]+-task-[A-Za-z0-9._-]+$ ]]; then printf '%s\n' "$n"; return 0; fi
  fi
  printf 'agentic-%s-task-%s\n' "$(task_project)" "$1"
}
# task_created ID: the task created its container (line 2 is 1); task_creator ID: the task that did (line 3).
task_created() { local f; f="$(host_file "$1" container)" && [ "$(sed -n 2p "$f")" = 1 ]; }
task_creator() { local f c; f="$(host_file "$1" container)" && c="$(sed -n 3p "$f")" && valid_task_id "$c" && printf '%s\n' "$c"; }

# bridge_running CONTAINER: a task bridge (not a follow client) runs in CONTAINER.
bridge_running() { docker exec "$1" pgrep -f 'bridge/dist/main\.js$' >/dev/null 2>&1; }
# wait_bridge_gone CONTAINER SECONDS: until no bridge runs in CONTAINER.
wait_bridge_gone() {
  local end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do bridge_running "$1" || return 0; sleep 0.5; done
  return 1
}

new_task_id() { printf 'T-%s-%s\n' "$(date -u +%Y%m%d)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }
new_token() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
# task_slug TEXT: a branch-safe slug of the first non-blank line, "task" when nothing is left.
# Plain bash for the line, so a large prompt never meets SIGPIPE under pipefail.
task_slug() {
  local line="" l slug
  while IFS= read -r l; do
    if [[ "$l" =~ [^[:space:]] ]]; then line="${l:0:200}"; break; fi
  done <<<"$1"
  slug="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-40 | sed -E 's/-+$//')"
  printf '%s\n' "${slug:-task}"
}
valid_task_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
# valid_grant ACTION: an action a task may be allowed (run --allow, answer --allow).
valid_grant() { [[ "$1" =~ ^(push|open-pr|deploy:[A-Za-z0-9_.-]+)$ ]]; }
need_task() {
  valid_task_id "${1:-}" || die "usage: a task id ([A-Za-z0-9._-]+)"
  task_readable "$1" state.json || die "no task $1 in $(task_project)"
}

# container_status ID: the docker state, missing when there is no such container, unknown when
# docker itself failed (daemon down, no permission).
container_status() {
  local out
  if out="$(docker inspect -f '{{.State.Status}}' "$(task_container "$1")" 2>&1)"; then printf '%s\n' "$out"
  elif [[ "${out,,}" == *"no such object"* || "${out,,}" == *"no such container"* ]]; then echo missing
  else echo unknown; fi
}
task_port() { docker port "$(task_container "$1")" "$TASK_PORT/tcp" 2>/dev/null | head -n 1 | sed 's/.*://'; }
record_get() { { task_read "$1" state.json || true; } | jq -r "$2 // empty" 2>/dev/null || true; }

# task_state ID: the record's state; active while no container runs means interrupted (spec §6).
task_state() {
  local st cs; st="$(record_get "$1" .state)"; st="${st:-unknown}"
  if [[ " $TASK_ACTIVE " == *" $st "* ]]; then
    cs="$(container_status "$1")"
    case "$cs" in running) bridge_running "$(task_container "$1")" || st=interrupted ;; unknown) st=unknown ;; *) st=interrupted ;; esac
  fi
  printf '%s\n' "$st"
}

# bridge_req ID METHOD PATH [BODY]: one API request; BRIDGE_CODE and BRIDGE_BODY. 1 when unreachable.
# The token goes in a header file, never on a command line.
bridge_req() {
  local id="$1" method="$2" path="$3" body="${4:-}" port hdr out envf rc=0
  envf="$(host_file "$id" env)" || return 1
  port="$(task_port "$id")"
  [ -n "$port" ] || return 1
  hdr="$(mktemp)"
  (umask 077; printf 'Authorization: Bearer %s\n' "$(dotenv_value "$envf" AGENTIC_TASK_TOKEN)" > "$hdr")
  out="$(printf '%s' "$body" | curl -sS --noproxy '*' -m 30 -X "$method" -H "@$hdr" -H 'Content-Type: application/json' \
    --data-binary @- -w '\n%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null)" || rc=1
  rm -f "$hdr"
  [ "$rc" = 0 ] || return 1
  BRIDGE_CODE="${out##*$'\n'}"; BRIDGE_BODY="${out%$'\n'*}"
}
bridge_call() { bridge_req "$@" || die "task $1 is not reachable (state: $(task_state "$1"))"; }
# bridge_post ID PATH [BODY]: a POST the task must answer; prints its new state, or dies.
bridge_post() { bridge_call "$1" POST "$2" "${3:-}"; bridge_result "$1"; }

# wait_bridge ID SECONDS: until the bridge answers with a state other than starting. Gives up early
# when the container stops, or when no bridge process runs once a short grace has passed (a bridge
# that fails at boot leaves the container running). One attempt is always made.
wait_bridge() {
  local id="$1" start=$SECONDS end=$((SECONDS + $2))
  while :; do
    [ "$(container_status "$id")" = running ] || return 1
    if bridge_req "$id" GET /status && [ "$BRIDGE_CODE" = 200 ] && [ "$(jq -r .state <<<"$BRIDGE_BODY")" != starting ]; then return 0; fi
    if [ "$((SECONDS - start))" -ge 2 ] && ! bridge_running "$(task_container "$id")"; then return 1; fi
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 0.5
  done
}

# bridge_tails ID: the tails of the bridge's log and its own output, to stderr (before a rollback
# removes the task directory).
bridge_tails() {
  local v dir; dir="$(task_dir "$1")"
  for v in bridge.log bridge.out; do
    if task_readable "$1" "$v" && [ -s "$dir/$v" ]; then { echo "$v:"; task_read "$1" "$v" | tail -n 20 | plain; } >&2; fi
  done
}

check_cap() {
  local n=0 c max="${AGENTIC_MAX_RUNNING:-3}"
  while IFS= read -r c; do
    if [ -n "$c" ] && bridge_running "$c"; then n=$((n + 1)); fi
  done < <(docker ps --format '{{.Names}}' --filter label=agentic.kind=task --filter status=running)
  [ "$n" -lt "$max" ] || die "$n tasks are running (AGENTIC_MAX_RUNNING=$max); stop one or wait"
}

# safe_rm ROOT PATH: rm -rf PATH only when it is absolute, free of .., strictly inside ROOT and no
# component below ROOT is a symlink.
safe_rm() {
  local root="$1" path="$2" p
  [ -n "$root" ] && [ -n "$path" ] || return 0
  [[ "$path" == /* && "$path" != *"/../"* && "$path" != */.. && "$path" == "$root"/?* ]] || return 0
  p="$path"
  while [ "$p" != "$root" ] && [ "$p" != / ]; do
    [ ! -L "$p" ] || return 0
    p="$(dirname "$p")"
  done
  rm -rf -- "$path"
}

# foreign_bridge ID: a bridge runs in the task's container and it answers the task's token with
# something other than 200: another task's bridge, which this task must never stop or kill.
foreign_bridge() { bridge_running "$(task_container "$1")" && bridge_req "$1" GET /status && [ "$BRIDGE_CODE" != 200 ]; }

# rollback_task ID [kill]: removes what the task created: its container (only when it created it)
# and its files. With kill (run's own failure path only) the bridge this run just started in a
# reused container is ended; clean and the sweep never kill a bridge there.
rollback_task() {
  local id="$1" kill="${2:-}" ws c
  valid_task_id "$id" || return 0
  ws="$(task_ws)"; c="$(task_container "$id")"
  if task_created "$id"; then docker rm -f "$c" >/dev/null 2>&1 || true
  elif [ "$kill" = kill ] && host_file "$id" container >/dev/null; then docker exec "$c" pkill -f 'bridge/dist/main\.js$' >/dev/null 2>&1 || true
  fi
  safe_rm "$ws/tasks" "$(task_dir "$id")"
  safe_rm "$AGENTIC_DATA/projects/$(task_project)/tasks" "$(task_hdir "$id")"
}

# sweep_cleaned: removes the project's auto-cleaned tasks (the bridge marked the record cleaned).
# The record is agent-writable: a task whose created container still runs (or whose state docker
# cannot tell) is kept, and rollback_task takes the container from the host file only.
sweep_cleaned() {
  local f id envf
  for f in "$(task_ws)"/tasks/*/state.json; do
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    id="$(basename "$(dirname "$f")")"
    valid_task_id "$id" || continue
    [ "$(record_get "$id" .cleaned)" = true ] || continue
    # only a task that asked for auto-clean (the host's own env file, not the agent's record)
    envf="$(host_file "$id" env)" || continue
    [ "$(dotenv_value "$envf" AGENTIC_AUTO_CLEAN)" = 1 ] || continue
    if task_created "$id"; then
      case "$(container_status "$id")" in running|unknown) continue ;; esac
    fi
    rollback_task "$id"
  done
}

# age ISO: minutes, hours or days since ISO.
age() {
  local s; s=$(( $(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s) ))
  if [ "$s" -lt 3600 ]; then echo "$((s / 60))m"; elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi
}

# open_questions ID: the open questions in questions.jsonl (the last line per id wins) as a JSON
# array, in the shape of the bridge's status; [] when there is no file or it cannot be read. The
# agent can write the file: lines that are not objects are skipped, options that are not a list are [].
open_questions() {
  local out
  task_readable "$1" questions.jsonl || { echo '[]'; return; }
  out="$(task_read "$1" questions.jsonl | jq -cs 'map(select(type == "object")) | group_by(.id | tostring) | map(last) | map(select(.status == "open"))
    | sort_by(.id | tostring | ltrimstr("Q") | tonumber? // 0)
    | map({id, source, text, options: (.options | if type == "array" then . else [] end), recommendation, asked})' 2>/dev/null)" || out='[]'
  printf '%s\n' "${out:-[]}"
}

# note_interrupted ID: appends interrupted to the host's events log the first time it is seen. Not
# to the shared log under the workspace: tasks write that directory (a planted symlink or device).
note_interrupted() {
  local m; m="$(task_file "$1" interrupted)"
  [ -e "$m" ] && return 0
  (umask 077; mkdir -p "$(task_hdir "$1")")
  jq -cn --arg t "$1" --arg p "$(task_project)" '{ts: (now | todate), task: $t, project: $p, state: "interrupted", reason: "container gone without stop"}' \
    >> "$AGENTIC_DATA/projects/$(task_project)/events.jsonl"
  : > "$m"
}

# task_status_json ID: the live status when the bridge answers with an object, else the same shape
# from the task files: the record with the derived state, the inbox as a count and the open
# questions. A record that is not a JSON object (the agent can write it) gives the id and unknown.
task_status_json() {
  local st
  if [ "$(container_status "$1")" = running ] && bridge_req "$1" GET /status && [ "$BRIDGE_CODE" = 200 ] \
    && jq -cse 'select(length == 1 and (.[0] | type) == "object") | .[0]' <<<"$BRIDGE_BODY" 2>/dev/null; then
    return
  fi
  st="$(task_state "$1")"
  [ "$st" != interrupted ] || note_interrupted "$1"
  { task_read "$1" state.json | jq -cs --arg s "$st" --argjson q "$(open_questions "$1")" \
    'select(length == 1 and (.[0] | type) == "object") | .[0]
    | .inbox = (.inbox | if type == "array" then length else 0 end) | .state = $s | .questions = $q' 2>/dev/null; } | grep . \
    || jq -cn --arg id "$1" '{task: $id, state: "unknown", inbox: 0, questions: []}'
}

# plain: stdin without control characters (terminal escapes) other than newline and tab.
plain() { tr -d '\000-\010\013-\037\177'; }

# wait_ready ID SECONDS: until the container of the task has finished its start (agentic-task-hold
# marks /tasks/<creator>/.ready).
wait_ready() {
  local id="$1" end=$((SECONDS + $2)) creator f
  creator="$(task_creator "$id")" || return 1
  f="$(task_dir "$creator")/.ready"
  while :; do
    [ "$(container_status "$id")" = running ] || return 1
    if [ -f "$f" ] && [ ! -L "$f" ]; then return 0; fi
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 0.5
  done
}

# start_container ID: starts the task's stopped container and waits for its start.
start_container() {
  local creator; creator="$(task_creator "$1")" || die "task $1 has no container record"
  rm -f -- "$(task_dir "$creator")/.ready"
  docker start "$(task_container "$1")" >/dev/null || die "could not start the container of $1"
  wait_ready "$1" "${AGENTIC_START_TIMEOUT:-120}" || die "the container of $1 did not finish its start; see agentic logs $1 --start"
}

# start_bridge ID: the task's bridge in its running container, with the task's host env file.
start_bridge() {
  local envf; envf="$(host_file "$1" env)" || die "the env file of $1 is not a regular file"
  docker exec -d --env-file "$envf" "$(task_container "$1")" agentic-task-start >/dev/null || die "could not start the bridge of $1"
}

# task_has_worktree ID: run gave the task a worktree (its host env file says so).
task_has_worktree() { local envf; envf="$(host_file "$1" env)" && [ "$(dotenv_value "$envf" AGENTIC_WORKTREE)" = 1 ]; }
# worktree_cmd ID check|remove [--force]: the worktree script in the task's container, with the work
# directory and branch from the host env file.
worktree_cmd() {
  local envf; envf="$(host_file "$1" env)" || return 1
  docker exec "$(task_container "$1")" bash /opt/agentic/task/worktree.sh "$2" "$(dotenv_value "$envf" AGENTIC_WORK)" "$1" \
    "$(dotenv_value "$envf" AGENTIC_BRANCH)" ${3:+"$3"}
}

# ensure_running ID: the task's container runs and its bridge answers; starts what is missing (not
# for a stopped task).
ensure_running() {
  local id="$1" st cs c; c="$(task_container "$id")"
  cs="$(container_status "$id")"
  if [ "$cs" = running ] && bridge_running "$c"; then return 0; fi
  st="$(task_state "$id")"
  [ "$st" != stopped ] || die "task $id is stopped"
  case "$cs" in
    missing) die "task $id has no container (state: $st)" ;;
    unknown) die "docker did not answer for task $id" ;;
  esac
  check_cap
  if [ "$cs" != running ]; then start_container "$id"; fi
  ! bridge_running "$c" || die "another task runs in the container of $id"
  start_bridge "$id"
  wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}" || { bridge_tails "$id"; die "the bridge of $id did not come up; see agentic logs $id --bridge"; }
  # revived: a later interruption is logged to the project events log again
  rm -f "$(task_file "$id" interrupted)"
}

# bridge_result ID: the new state after a 2xx answer; otherwise the bridge's message and HTTP code.
bridge_result() {
  local why
  case "$BRIDGE_CODE" in
    2*) jq -er --arg id "$1" '"\($id): \(.state)\(if (.reason // "") != "" then " (" + .reason + ")" else "" end)"' <<<"$BRIDGE_BODY" 2>/dev/null | plain \
          || die "the bridge answered HTTP $BRIDGE_CODE with a body that is not a task state" ;;
    *) why="$(jq -r '.error.message // "request failed"' <<<"$BRIDGE_BODY" 2>/dev/null | plain)" || why=""
       die "${why:-request failed} (HTTP $BRIDGE_CODE)" ;;
  esac
}

# need_running ID: dies unless the task's container runs.
need_running() { [ "$(container_status "$1")" = running ] || die "task $1 is not running (state: $(task_state "$1"))"; }
