#!/usr/bin/env bash
# Host-side helpers for detached tasks (spec §15). Source after lib/host/common.sh. TASK_PROJECT
# overrides the project (status --all walks every project).
TASK_PORT=8765
TASK_ACTIVE="starting running waiting idle"

task_project() { printf '%s\n' "${TASK_PROJECT:-$(project_name)}"; }
task_ws() { printf '%s/%s\n' "$AGENTIC_WORKSPACES" "$(task_project)"; }
task_dir() { printf '%s/tasks/%s\n' "$(task_ws)" "$1"; }
task_file() { printf '%s/tasks/%s.%s\n' "$(task_ws)" "$1" "$2"; }
task_container() { printf 'agentic-%s-task-%s\n' "$(task_project)" "$1"; }
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
# Task clones: the task container writes into their .git, so host git never runs a command the
# clone configures. Their config, info/ and hooks/ are mounted read-only (task_mounts); the commands
# that read what the agent can still change (checkout filters, status) run in a throwaway container.
# hgit CLONE ARG...: host git on the clone's own git directory, pinned so a planted commondir file
# is ignored, without hooks and fsmonitor. For commands that run nothing the clone configures.
hgit() {
  local g="$1/.git"; shift
  GIT_DIR="$g" GIT_COMMON_DIR="$g" git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}
# user_cfg KEY: KEY from the user's global, else the system git config; never from a clone.
user_cfg() { git config --includes --global --get "$1" 2>/dev/null || git config --includes --system --get "$1" 2>/dev/null || true; }
# hfetch CLONE ARG...: hgit for fetch, which runs on the host with the user's credentials. The ssh
# command and askpass come from the user's config, the credential helpers are reset and replayed
# from the system and global config, ext:: is off and a git:// proxy only comes from the user.
hfetch() {
  local clone="$1" ssh scope e args=(); shift
  ssh="$(user_cfg core.sshCommand)"
  args=(-c "core.sshCommand=${ssh:-ssh}" -c "core.askPass=$(user_cfg core.askPass)" -c core.attributesFile=/dev/null
    -c protocol.ext.allow=never -c credential.helper=)
  for scope in system global; do
    if [ "$scope" = system ] && [ -n "${GIT_CONFIG_NOSYSTEM:-}" ]; then continue; fi
    while IFS= read -r -d '' e; do
      if [[ "$e" == *$'\n'* ]]; then args+=(-c "${e%%$'\n'*}=${e#*$'\n'}"); else args+=(-c "$e="); fi
    done < <(git config --includes "--$scope" -z --get-regexp '^credential\..*helper$' 2>/dev/null || true)
  done
  (
    # the first core.gitProxy read wins, so a clone's would beat -c; the variable beats both
    if [ -z "${GIT_PROXY_COMMAND+x}" ] && [ -z "$(user_cfg core.gitProxy)" ]; then export GIT_PROXY_COMMAND=; fi
    hgit "$clone" "${args[@]}" "$@"
  )
}
# cgit IMAGE CLONE ARG...: git in a throwaway container of IMAGE: no network, the invoking user and
# only the clone, at its own path. --entrypoint git stays right before the image (the test stub
# relies on it).
cgit() {
  local img="$1" clone="$2"; shift 2
  docker run --rm --network none --user "$(id -u):$(id -g)" -v "$clone:$clone" --entrypoint git "$img" \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}
valid_task_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
need_task() {
  valid_task_id "${1:-}" || die "usage: a task id ([A-Za-z0-9._-]+)"
  [ -f "$(task_dir "$1")/state.json" ] || die "no task $1 in $(task_project)"
}

# container_status ID: the docker state, missing when there is no such container, unknown when
# docker itself failed (daemon down, no permission).
container_status() {
  local out
  if out="$(docker inspect -f '{{.State.Status}}' "$(task_container "$1")" 2>&1)"; then printf '%s\n' "$out"
  elif [[ "$out" == *"No such object"* || "$out" == *"No such container"* ]]; then echo missing
  else echo unknown; fi
}
task_port() { docker port "$(task_container "$1")" "$TASK_PORT/tcp" 2>/dev/null | head -n 1 | sed 's/.*://'; }
record_get() { jq -r "$2 // empty" "$(task_dir "$1")/state.json" 2>/dev/null || true; }

# task_state ID: the record's state; active while no container runs means interrupted (spec §6).
task_state() {
  local st cs; st="$(record_get "$1" .state)"; st="${st:-unknown}"
  if [[ " $TASK_ACTIVE " == *" $st "* ]]; then
    cs="$(container_status "$1")"
    case "$cs" in running) ;; unknown) st=unknown ;; *) st=interrupted ;; esac
  fi
  printf '%s\n' "$st"
}

# bridge_req ID METHOD PATH [BODY]: one API request; BRIDGE_CODE and BRIDGE_BODY. 1 when unreachable.
# The token goes in a header file, never on a command line.
bridge_req() {
  local id="$1" method="$2" path="$3" body="${4:-}" port hdr out rc=0
  port="$(task_port "$id")"
  [ -n "$port" ] || return 1
  hdr="$(mktemp)"
  (umask 077; printf 'Authorization: Bearer %s\n' "$(dotenv_value "$(task_file "$id" env)" AGENTIC_TASK_TOKEN)" > "$hdr")
  out="$(printf '%s' "$body" | curl -sS --noproxy '*' -m 30 -X "$method" -H "@$hdr" -H 'Content-Type: application/json' \
    --data-binary @- -w '\n%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null)" || rc=1
  rm -f "$hdr"
  [ "$rc" = 0 ] || return 1
  BRIDGE_CODE="${out##*$'\n'}"; BRIDGE_BODY="${out%$'\n'*}"
}
bridge_call() { bridge_req "$@" || die "task $1 is not reachable (state: $(task_state "$1"))"; }

# wait_bridge ID SECONDS: until the bridge answers with a state other than starting.
wait_bridge() {
  local id="$1" end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do
    [ "$(container_status "$id")" = running ] || return 1
    if bridge_req "$id" GET /status && [ "$BRIDGE_CODE" = 200 ] && [ "$(jq -r .state <<<"$BRIDGE_BODY")" != starting ]; then return 0; fi
    sleep 0.5
  done
  return 1
}

check_cap() {
  local n max="${AGENTIC_MAX_RUNNING:-3}"
  n="$(docker ps -q --filter label=agentic.kind=task --filter status=running | grep -c . || true)"
  [ "$n" -lt "$max" ] || die "$n tasks are running (AGENTIC_MAX_RUNNING=$max); stop one or wait"
}

# safe_rm ROOT PATH: rm -rf PATH only when it is absolute, free of .. and strictly inside ROOT.
safe_rm() {
  local root="$1" path="$2"
  [ -n "$root" ] && [ -n "$path" ] || return 0
  [[ "$path" == /* && "$path" != *"/../"* && "$path" != */.. && "$path" == "$root"/?* ]] || return 0
  rm -rf -- "$path"
}

# rollback_task ID: removes the container, worktrees, branches and files of a task. The repos file
# holds one tab-separated clone, worktree and branch per line.
rollback_task() {
  local id="$1" clone wt branch ws f
  valid_task_id "$id" || return 0
  ws="$(task_ws)"
  docker rm -f "$(task_container "$id")" >/dev/null 2>&1 || true
  if [ -f "$(task_file "$id" repos)" ]; then
    while IFS=$'\t' read -r clone wt branch; do
      [[ "$clone" == "$ws/repos/"?* && "$wt" == "$ws/repos/"?* ]] || continue
      hgit "$clone" -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1 || safe_rm "$ws/repos" "$wt"
      hgit "$clone" -C "$clone" worktree prune >/dev/null 2>&1 || true
      hgit "$clone" -C "$clone" branch -D "$branch" >/dev/null 2>&1 || true
    done < "$(task_file "$id" repos)"
  fi
  safe_rm "$ws/tasks" "$(task_dir "$id")"
  for f in env mounts repos interrupted; do safe_rm "$ws/tasks" "$(task_file "$id" "$f")"; done
}

# project_clone: the project's own repository under repos/, cloned from origin (credentials
# stripped) or from the checkout itself. Sets CLONE_NAME, and CLONE_NEW=1 when cloned just now.
# shellcheck disable=SC2034  # both are read by bin/agentic
project_clone() {
  local root clone url
  root="$(project_root)"; CLONE_NAME="$(basename "$root")"; CLONE_NEW=0; clone="$(task_ws)/repos/$CLONE_NAME"
  if [ ! -d "$clone/.git" ]; then
    url="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#' || true)"
    mkdir -p "$(task_ws)/repos"
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false clone -q "${url:-$root}" "$clone" >&2 || return 1
    printf '.worktrees/\n' >> "$clone/.git/info/exclude"
    CLONE_NEW=1
  fi
}

# add_worktree NAME ID BRANCH BASE [IMAGE]: a worktree of repos/NAME on BRANCH from BASE (default
# origin/HEAD). With IMAGE the checkout runs in a throwaway container of it (a clone a task may
# have touched); without, on the host (a clone made just now).
add_worktree() {
  local clone base="$4" img="${5:-}" add; clone="$(task_ws)/repos/$1"
  [ -d "$clone/.git" ] || { say "no clone $clone; clone the repository there first"; return 1; }
  hfetch "$clone" -C "$clone" fetch -q --no-recurse-submodules --upload-pack=git-upload-pack origin >/dev/null 2>&1 || true
  [ -n "$base" ] || base="$(hgit "$clone" -C "$clone" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
  add=(worktree add -q -b "$3" "$clone/.worktrees/$2" "$base")
  if [ -n "$img" ]; then cgit "$img" "$clone" -C "$clone" "${add[@]}" >&2 || return 1
  else hgit "$clone" -C "$clone" "${add[@]}" >&2 || return 1; fi
  printf '%s\t%s\t%s\n' "$clone" "$clone/.worktrees/$2" "$3" >> "$(task_file "$2" repos)"
}

# task_mounts ID REPO...: the -v arguments of a task, one per line, into the mounts file. A changed
# clone's .git is writable (commits, refs, objects), but not its config, info/ (attributes) and
# hooks/, which host git would read.
task_mounts() {
  local id="$1" ws first="$2" r name clone g; shift; ws="$(task_ws)"
  {
    printf -- '-v\n%s\n' "$ws/repos/$first/.worktrees/$id:/work"
    for r in "$@"; do
      [ "$r" = "$first" ] || printf -- '-v\n%s\n' "$ws/repos/$r/.worktrees/$id:/workspaces/$r"
      g="$ws/repos/$r/.git"
      mkdir -p "$g/info" "$g/hooks"
      printf -- '-v\n%s\n' "$g:$g" "$g/config:$g/config:ro" "$g/info:$g/info:ro" "$g/hooks:$g/hooks:ro"
    done
    for clone in "$ws"/repos/*/; do
      name="$(basename "$clone")"
      [[ " $* " == *" $name "* ]] || printf -- '-v\n%s\n' "$ws/repos/$name:/workspaces/$name:ro"
    done
    printf -- '-v\n%s\n-v\n%s\n-v\n%s\n' "$(task_dir "$id"):/task" "$ws/events:/events" "$(cfg_dir):/agentic-config:ro"
  } > "$(task_file "$id" mounts)"
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
  local f out; f="$(task_dir "$1")/questions.jsonl"
  [ -f "$f" ] || { echo '[]'; return; }
  out="$(jq -cs 'map(select(type == "object")) | group_by(.id | tostring) | map(last) | map(select(.status == "open"))
    | sort_by(.id | tostring | ltrimstr("Q") | tonumber? // 0)
    | map({id, source, text, options: (.options | if type == "array" then . else [] end), recommendation, asked})' "$f" 2>/dev/null)" || out='[]'
  printf '%s\n' "${out:-[]}"
}

# note_interrupted ID: appends interrupted to the project events log the first time it is seen.
note_interrupted() {
  local m; m="$(task_file "$1" interrupted)"
  [ -e "$m" ] && return 0
  mkdir -p "$(task_ws)/events"
  jq -cn --arg t "$1" --arg p "$(task_project)" '{ts: (now | todate), task: $t, project: $p, state: "interrupted", reason: "container gone without stop"}' \
    >> "$(task_ws)/events/events.jsonl"
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
  jq -cs --arg s "$st" --argjson q "$(open_questions "$1")" 'select(length == 1 and (.[0] | type) == "object") | .[0]
    | .inbox = (.inbox | if type == "array" then length else 0 end) | .state = $s | .questions = $q' \
    "$(task_dir "$1")/state.json" 2>/dev/null | grep . \
    || jq -cn --arg id "$1" '{task: $id, state: "unknown", inbox: 0, questions: []}'
}

# plain: stdin without control characters (terminal escapes) other than newline and tab.
plain() { tr -d '\000-\010\013-\037\177'; }

# ensure_running ID: starts the container of a task that is not stopped and waits for its bridge.
ensure_running() {
  local id="$1" st
  [ "$(container_status "$id")" = running ] && return 0
  st="$(task_state "$id")"
  [ "$st" != stopped ] || die "task $id is stopped"
  case "$(container_status "$id")" in
    missing) die "task $id has no container (state: $st)" ;;
    unknown) die "docker did not answer for task $id" ;;
  esac
  check_cap
  docker start "$(task_container "$id")" >/dev/null || die "could not start the container of $id"
  wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}" || die "the bridge of $id did not come up; see agentic logs $id --start"
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
