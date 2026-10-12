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
      git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1 || safe_rm "$ws/repos" "$wt"
      git -C "$clone" worktree prune >/dev/null 2>&1 || true
      git -C "$clone" branch -D "$branch" >/dev/null 2>&1 || true
    done < "$(task_file "$id" repos)"
  fi
  safe_rm "$ws/tasks" "$(task_dir "$id")"
  for f in env mounts repos interrupted; do safe_rm "$ws/tasks" "$(task_file "$id" "$f")"; done
}

# project_clone: the project's own repository under repos/, cloned from origin (credentials
# stripped) or from the checkout itself; prints its name.
project_clone() {
  local root name clone url
  root="$(project_root)"; name="$(basename "$root")"; clone="$(task_ws)/repos/$name"
  if [ ! -d "$clone/.git" ]; then
    url="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#' || true)"
    mkdir -p "$(task_ws)/repos"
    git clone -q "${url:-$root}" "$clone" >&2 || return 1
    printf '.worktrees/\n' >> "$clone/.git/info/exclude"
  fi
  printf '%s\n' "$name"
}

# add_worktree NAME ID BRANCH BASE: a worktree of repos/NAME on BRANCH from BASE (default origin/HEAD).
add_worktree() {
  local clone base="$4"; clone="$(task_ws)/repos/$1"
  [ -d "$clone/.git" ] || { say "no clone $clone; clone the repository there first"; return 1; }
  git -C "$clone" fetch -q origin >/dev/null 2>&1 || true
  [ -n "$base" ] || base="$(git -C "$clone" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
  git -C "$clone" worktree add -q -b "$3" "$clone/.worktrees/$2" "$base" >&2 || return 1
  printf '%s\t%s\t%s\n' "$clone" "$clone/.worktrees/$2" "$3" >> "$(task_file "$2" repos)"
}

# task_mounts ID REPO...: the -v arguments of a task, one per line, into the mounts file.
task_mounts() {
  local id="$1" ws first="$2" r name clone; shift; ws="$(task_ws)"
  {
    printf -- '-v\n%s\n' "$ws/repos/$first/.worktrees/$id:/work"
    for r in "$@"; do
      [ "$r" = "$first" ] || printf -- '-v\n%s\n' "$ws/repos/$r/.worktrees/$id:/workspaces/$r"
      printf -- '-v\n%s\n' "$ws/repos/$r/.git:$ws/repos/$r/.git"
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

# open_questions ID: the number of open questions in questions.jsonl (the last line per id wins).
open_questions() {
  local f; f="$(task_dir "$1")/questions.jsonl"
  [ -f "$f" ] || { echo 0; return; }
  jq -s 'group_by(.id) | map(last) | map(select(.status == "open")) | length' "$f" 2>/dev/null || echo 0
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

# task_status_json ID: the live status when the bridge answers, else the record with the derived state.
task_status_json() {
  local st
  if [ "$(container_status "$1")" = running ] && bridge_req "$1" GET /status && [ "$BRIDGE_CODE" = 200 ]; then
    printf '%s\n' "$BRIDGE_BODY"; return
  fi
  st="$(task_state "$1")"
  [ "$st" != interrupted ] || note_interrupted "$1"
  jq -c --arg s "$st" --argjson n "$(open_questions "$1")" 'del(.inbox) | .state = $s | .open_questions = $n' "$(task_dir "$1")/state.json"
}
