#!/usr/bin/env bash
# Host-side helpers for detached tasks (spec §15). Source after lib/host/common.sh. TASK_PROJECT
# overrides the project (status --all walks every project).
TASK_PORT=8765
TASK_ACTIVE="starting running waiting idle"

task_project() { printf '%s\n' "${TASK_PROJECT:-$(project_name)}"; }
task_ws() { printf '%s/%s\n' "$AGENTIC_WORKSPACES" "$(task_project)"; }
task_dir() { printf '%s/tasks/%s\n' "$(task_ws)" "$1"; }
# The host's own files of a task (tokens, mounts, repos, the interrupted marker) live outside the
# workspace, which task and dev containers can write: task_hdir is never mounted.
task_hdir() { printf '%s/projects/%s/tasks/%s\n' "$AGENTIC_DATA" "$(task_project)" "$1"; }
task_file() { printf '%s/%s\n' "$(task_hdir "$1")" "$2"; }
# task_migrate ID: moves the host files of a task made before they left the workspace
# (tasks/<ID>.<name>) into task_hdir, once; a symlink or anything but a regular file stays behind.
task_migrate() {
  local f old
  [ ! -L "$(task_ws)/tasks" ] || return 0
  for f in env mounts repos interrupted; do
    old="$(task_ws)/tasks/$1.$f"
    if [ -f "$old" ] && [ ! -L "$old" ] && [ ! -e "$(task_file "$1" "$f")" ]; then
      (umask 077; mkdir -p "$(task_hdir "$1")")
      mv -- "$old" "$(task_file "$1" "$f")"
    fi
  done
}
# task_readable ID NAME: NAME in the task directory, which the agent writes, is a regular file and
# no symlink, under no symlinked directory: the host never prints a host file or blocks on a FIFO.
task_readable() {
  local d; d="$(task_dir "$1")"
  [ ! -L "$(task_ws)/tasks" ] && [ ! -L "$d" ] && [ -f "$d/$2" ] && [ ! -L "$d/$2" ]
}
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
# Task clones: a task container writes into their .git, so no host git process opens one once it
# exists. Host git only touches a private bare mirror per clone (mirror_dir, never mounted into a
# container); every operation on a clone runs in a throwaway container (cgit).
mirror_dir() { printf '%s/projects/%s/mirrors/%s.git\n' "$AGENTIC_DATA" "$(task_project)" "$1"; }
# user_cfg KEY: KEY from the user's global, else the system git config.
user_cfg() { git config --includes --global --get "$1" 2>/dev/null || git config --includes --system --get "$1" 2>/dev/null || true; }
# ugit ARG...: host git (mirrors, a brand-new clone) with the user's own settings for what could run
# a command: the ssh command and askpass from the user's config, the credential helpers reset and
# replayed from the system and global config, a git:// proxy only from the user, ext:: off, no
# hooks, no fsmonitor, no automatic gc or maintenance.
ugit() {
  local ssh scope e args=()
  ssh="$(user_cfg core.sshCommand)"
  args=(-c "core.sshCommand=${ssh:-ssh}" -c "core.askPass=$(user_cfg core.askPass)" -c core.attributesFile=/dev/null
    -c protocol.ext.allow=never -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0
    -c maintenance.auto=false -c credential.helper=)
  for scope in system global; do
    if [ "$scope" = system ] && [ -n "${GIT_CONFIG_NOSYSTEM:-}" ]; then continue; fi
    while IFS= read -r -d '' e; do
      if [[ "$e" == *$'\n'* ]]; then args+=(-c "${e%%$'\n'*}=${e#*$'\n'}"); else args+=(-c "$e="); fi
    done < <(git config --includes "--$scope" -z --get-regexp '^credential\..*helper$' 2>/dev/null || true)
  done
  (
    # the first core.gitProxy read wins, so -c could not override one; the variable beats all
    if [ -z "${GIT_PROXY_COMMAND+x}" ] && [ -z "$(user_cfg core.gitProxy)" ]; then export GIT_PROXY_COMMAND=; fi
    git "${args[@]}" "$@"
  )
}
# mgit NAME ARG...: ugit on the private mirror of repos/NAME.
mgit() { local m; m="$(mirror_dir "$1")"; shift; GIT_DIR="$m" GIT_COMMON_DIR="$m" ugit "$@"; }
# clone_ok CLONE: the clone's .git, config, info/ and hooks/ are no symlinks (a mount source would
# follow one); creates info/ and hooks/ so they can be mounted.
clone_ok() {
  local g="$1/.git" d
  [ -d "$g" ] && [ ! -L "$1" ] && [ ! -L "$g" ] && [ -f "$g/config" ] && [ ! -L "$g/config" ] || return 1
  for d in info hooks; do
    [ ! -L "$g/$d" ] || return 1
    mkdir -p "$g/$d"
  done
}
# cgit_err ARG...: cgit with its output on stderr, without control characters (filters the agent
# planted can write there).
cgit_err() {
  local out rc=0
  out="$(cgit "$@" 2>&1)" || rc=$?
  if [ -n "$out" ]; then printf '%s\n' "$out" | plain >&2; fi
  return "$rc"
}
# cgit IMAGE CLONE GIT_DIR [DOCKER-ARG...] -- GIT-ARG...: git in a throwaway container of IMAGE: no
# network, the invoking user, no capabilities, a read-only root, GIT_DIR pinned (GIT_COMMON_DIR is
# the clone's .git), the clone's .git with its config, info/ and hooks/ read-only, and only the
# extra mounts a call names. --entrypoint git stays right before the image (the test stub relies on it).
cgit() {
  local img="$1" g="$2/.git" dir="$3" extra=(); shift 3
  while [ "$1" != -- ]; do extra+=("$1"); shift; done
  shift
  docker run --rm --network none --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
    --read-only --tmpfs /tmp -e HOME=/tmp -e "GIT_DIR=$dir" -e "GIT_COMMON_DIR=$g" \
    -v "$g:$g" -v "$g/config:$g/config:ro" -v "$g/info:$g/info:ro" -v "$g/hooks:$g/hooks:ro" "${extra[@]}" \
    --entrypoint git "$img" -c gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}
# wt_gitdir CLONE WT: the worktree's git directory from its .git file, only when that is a regular
# file naming CLONE/.git/worktrees/<name>.
wt_gitdir() {
  local line d n
  [ -f "$2/.git" ] && [ ! -L "$2/.git" ] || return 1
  line="$(head -c 4096 "$2/.git" | head -n 1)"
  d="${line#gitdir: }"; n="${d#"$1/.git/worktrees/"}"
  [ "$d" != "$line" ] && [ "$n" != "$d" ] && [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$n" != . ] && [ "$n" != .. ] || return 1
  printf '%s\n' "$d"
}
# task_image ID: the image of the task's container, else the project image, else its base.
task_image() {
  docker inspect -f '{{.Config.Image}}' "$(task_container "$1")" 2>/dev/null && return 0
  if image_exists "$(project_image)"; then project_image; else base_image_of; fi
}
valid_task_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
need_task() {
  valid_task_id "${1:-}" || die "usage: a task id ([A-Za-z0-9._-]+)"
  task_readable "$1" state.json || die "no task $1 in $(task_project)"
  task_migrate "$1"
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
record_get() { if task_readable "$1" state.json; then jq -r "$2 // empty" "$(task_dir "$1")/state.json" 2>/dev/null || true; fi; }

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

# rollback_task ID: removes the container, worktrees, branches and files of a task. The repos file
# holds one tab-separated clone, worktree and branch per line.
rollback_task() {
  local id="$1" clone wt branch ws f img g
  valid_task_id "$id" || return 0
  ws="$(task_ws)"
  task_migrate "$id"
  img="$(task_image "$id")"
  docker rm -f "$(task_container "$id")" >/dev/null 2>&1 || true
  if [ -f "$(task_file "$id" repos)" ]; then
    while IFS=$'\t' read -r clone wt branch; do
      [[ "$clone" == "$ws/repos/"?* && "$wt" == "$ws/repos/"?* ]] || continue
      if clone_ok "$clone"; then
        g="$clone/.git"
        # git cannot remove its own mount point: the directory (and what is left) goes after
        if [ -d "$wt" ] && [ ! -L "$wt" ]; then cgit "$img" "$clone" "$g" -v "$wt:$wt" -- worktree remove --force "$wt" >/dev/null 2>&1 || true; fi
        safe_rm "$ws/repos" "$wt"
        if [ -d "$clone/.worktrees" ] && [ ! -L "$clone/.worktrees" ]; then
          cgit "$img" "$clone" "$g" -v "$clone/.worktrees:$clone/.worktrees:ro" -- worktree prune >/dev/null 2>&1 || true
        fi
        cgit "$img" "$clone" "$g" -- branch -D "$branch" >/dev/null 2>&1 || true
      else
        safe_rm "$ws/repos" "$wt"
      fi
    done < "$(task_file "$id" repos)"
  fi
  safe_rm "$ws/tasks" "$(task_dir "$id")"
  for f in env mounts repos interrupted; do safe_rm "$ws/tasks" "$ws/tasks/$id.$f"; done
  safe_rm "$AGENTIC_DATA/projects/$(task_project)/tasks" "$(task_hdir "$id")"
}

# project_url: the project's origin (credentials stripped), else the checkout itself.
project_url() {
  local root url; root="$(project_root)"
  url="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#' || true)"
  printf '%s\n' "${url:-$root}"
}

# repo_url NAME: where the mirror of repos/NAME fetches from: the project's remote for the project's
# own clone; else the URL its mirror recorded; else, on first use, the clone's origin, read before
# any task had write access to the clone (a clone only becomes writable after its mirror exists).
repo_url() {
  local clone m; clone="$(task_ws)/repos/$1"; m="$(mirror_dir "$1")"
  if [ "$1" = "$(basename "$(project_root)")" ]; then project_url; return; fi
  if [ -d "$m" ]; then mgit "$1" config --get remote.origin.url; return; fi
  clone_ok "$clone" || return 1
  git config --file "$clone/.git/config" --get remote.origin.url
}

# sync_mirror NAME URL: makes the private bare mirror of repos/NAME from URL, or fetches into it.
sync_mirror() {
  local m; m="$(mirror_dir "$1")"
  if [ ! -d "$m" ]; then
    mkdir -p "$(dirname "$m")"
    ugit clone -q --bare "$2" "$m" >&2
  else
    mgit "$1" fetch -q --prune --no-recurse-submodules "$2" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >&2 || true
  fi
}

# project_clone: the project's own clone under repos/; prints its name. A missing clone is made by
# the host from the mirror, in a fresh directory no task has seen, with origin set to the remote.
project_clone() {
  local name clone url m
  name="$(basename "$(project_root)")"; clone="$(task_ws)/repos/$name"; m="$(mirror_dir "$name")"
  if [ ! -e "$clone" ]; then
    url="$(project_url)"
    sync_mirror "$name" "$url" || return 1
    mkdir -p "$(task_ws)/repos"
    ugit clone -q --no-hardlinks "$m" "$clone" >&2 || return 1
    ugit -C "$clone" remote set-url origin "$url" || return 1
    printf '.worktrees/\n' >> "$clone/.git/info/exclude"
  fi
  printf '%s\n' "$name"
}

# add_worktree NAME ID BRANCH BASE IMAGE: a worktree of repos/NAME on BRANCH from BASE (default the
# remote's default branch): the mirror fetches, then a throwaway container of IMAGE fetches from it
# into the clone's refs/remotes/origin/ and checks the worktree out.
add_worktree() {
  local clone wt m url base="$4" img="$5" head; clone="$(task_ws)/repos/$1"; wt="$clone/.worktrees/$2"; m="$(mirror_dir "$1")"
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != . && "$1" != .. ]] || { say "bad repository name $1"; return 1; }
  [ -d "$clone/.git" ] || { say "no clone $clone; clone the repository there first"; return 1; }
  clone_ok "$clone" || { say "$clone/.git has a symlink where a directory or file belongs"; return 1; }
  url="$(repo_url "$1")" || url=""
  [ -n "$url" ] || { say "repos/$1 has no origin to fetch from"; return 1; }
  sync_mirror "$1" "$url" || { say "could not mirror $url"; return 1; }
  cgit_err "$img" "$clone" "$clone/.git" -v "$m:$m:ro" -- fetch -q --no-write-fetch-head --no-tags --no-recurse-submodules \
    --upload-pack=git-upload-pack "$m" '+refs/heads/*:refs/remotes/origin/*' || return 1
  if [ -z "$base" ]; then
    head="$(mgit "$1" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    base="${head:+origin/$head}"; base="${base:-HEAD}"
  fi
  [ ! -L "$clone/.worktrees" ] || return 1
  mkdir -p "$wt"
  cgit_err "$img" "$clone" "$clone/.git" -v "$wt:$wt" -- worktree add -q --no-track -b "$3" "$wt" "$base" \
    || { safe_rm "$(task_ws)/repos" "$wt"; return 1; }
  printf '%s\t%s\t%s\n' "$clone" "$wt" "$3" >> "$(task_file "$2" repos)"
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
      printf -- '-v\n%s\n' "$g:$g" "$g/config:$g/config:ro" "$g/info:$g/info:ro" "$g/hooks:$g/hooks:ro"
    done
    for clone in "$ws"/repos/*/; do
      name="$(basename "$clone")"
      [[ " $* " == *" $name "* ]] || printf -- '-v\n%s\n' "$ws/repos/$name:/workspaces/$name:ro"
    done
    printf -- '-v\n%s\n-v\n%s\n-v\n%s\n' "$(task_dir "$id"):/task" "$ws/events:/events" "$(cfg_dir):/agentic-config:ro"
  } > "$(task_file "$id" mounts)"
}

# read_mounts ID: the task's -v arguments into TASK_MOUNTS, only in the forms task_mounts writes
# (a workspace or config source; /work, /task, /events, /agentic-config, /workspaces/<name>, or a
# clone's .git path at its own place); dies on anything else.
read_mounts() {
  local f ws cfg lines=() i v src dst
  f="$(task_file "$1" mounts)"; ws="$(task_ws)"; cfg="$(cfg_dir)"; TASK_MOUNTS=()
  if [ ! -f "$f" ] || [ -L "$f" ]; then die "task $1 has no mounts file"; fi
  mapfile -t lines < "$f"
  [ $(( ${#lines[@]} % 2 )) -eq 0 ] || die "the mounts file of $1 is not one the host wrote"
  for ((i = 0; i < ${#lines[@]}; i += 2)); do
    v="${lines[i+1]}"; v="${v%:ro}"; src="${v%%:*}"; dst="${v#*:}"
    if [ "${lines[i]}" != -v ] || [[ "$dst" == *:* || "$src/" == *"/../"* || "$dst/" == *"/../"* ]] \
      || ! [[ "$src" == "$ws/"?* || "$src" == "$cfg" ]] \
      || ! [[ "$dst" =~ ^/(work|task|events|agentic-config)$ || "$dst" =~ ^/workspaces/[A-Za-z0-9._-]+$ \
              || ( "$dst" == "$ws/repos/"?* && "$dst" == "$src" ) ]]; then
      die "the mounts file of $1 is not one the host wrote"
    fi
    TASK_MOUNTS+=(-v "${lines[i+1]}")
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
  local f out; f="$(task_dir "$1")/questions.jsonl"
  task_readable "$1" questions.jsonl || { echo '[]'; return; }
  out="$(jq -cs 'map(select(type == "object")) | group_by(.id | tostring) | map(last) | map(select(.status == "open"))
    | sort_by(.id | tostring | ltrimstr("Q") | tonumber? // 0)
    | map({id, source, text, options: (.options | if type == "array" then . else [] end), recommendation, asked})' "$f" 2>/dev/null)" || out='[]'
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
  { task_readable "$1" state.json && jq -cs --arg s "$st" --argjson q "$(open_questions "$1")" \
    'select(length == 1 and (.[0] | type) == "object") | .[0]
    | .inbox = (.inbox | if type == "array" then length else 0 end) | .state = $s | .questions = $q' \
    "$(task_dir "$1")/state.json" 2>/dev/null; } | grep . \
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
