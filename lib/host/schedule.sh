#!/usr/bin/env bash
# Host-side helpers for scheduled runs (spec 2026-10-15-schedule-design). Source after task.sh.
# A definition lives in $AGENTIC_DATA (never mounted); results in the workspace's results/ (not mounted).

valid_sched_name() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }
sched_root() { printf '%s/projects/%s/schedules\n' "$AGENTIC_DATA" "$(task_project)"; }
sched_dir() { printf '%s/%s\n' "$(sched_root)" "$1"; }
sched_results() { printf '%s/results/%s\n' "$(task_ws)" "$1"; }
sched_get() { dotenv_value "$(sched_dir "$1")/schedule" "$2"; }

# sched_write NAME: KEY=VALUE lines from stdin become the definition, written atomically, mode 600.
sched_write() {
  local d; d="$(sched_dir "$1")"
  (umask 077; mkdir -p "$d"; cat > "$d/schedule.tmp")
  mv -f -- "$d/schedule.tmp" "$d/schedule"
}

# valid_cron EXPR: five cron fields of numbers, *, lists, ranges, steps and month or day names.
# No % (cron makes it a newline) and no @ shortcuts.
valid_cron() {
  local f fields names='(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|sun|mon|tue|wed|thu|fri|sat)'
  [[ "$1" != *$'\n'* ]] || return 1
  read -ra fields <<<"$1"
  [ "${#fields[@]}" -eq 5 ] || return 1
  for f in "${fields[@]}"; do [[ "${f,,}" =~ ^([0-9*,/-]|$names)+$ ]] || return 1; done
}

# at_cron "YYYY-MM-DD HH:MM": the cron fields of a one-off local time in the next 365 days.
at_cron() {
  local s now
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || return 1
  s="$(date -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  [ "$s" -gt "$now" ] && [ "$s" -le $((now + 365 * 86400)) ] || return 1
  date -d "$1" '+%-M %-H %-d %-m *'
}

# duration_secs D: 90m, 2h or plain seconds, from 60 to 86400.
duration_secs() {
  local n
  case "$1" in
    *h) n="${1%h}"; [[ "$n" =~ ^[0-9]+$ ]] || return 1; n=$((10#$n * 3600)) ;;
    *m) n="${1%m}"; [[ "$n" =~ ^[0-9]+$ ]] || return 1; n=$((10#$n * 60)) ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] || return 1; n=$((10#$1)) ;;
  esac
  [ "$n" -ge 60 ] && [ "$n" -le 86400 ] || return 1
  printf '%s\n' "$n"
}

cron_marker() { printf '# agentic:%s:%s' "$(task_project)" "$1"; }
# cron_safe VALUE: may go into a single-quoted crontab field (no quote, no %, no newline).
cron_safe() { [[ "$1" != *[\'%$'\n']* ]]; }
cron_running() { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }

# crontab_lines: the user's crontab, empty when there is none.
crontab_lines() { crontab -l 2>/dev/null || true; }
# sched_has_line NAME: the crontab has the line of schedule NAME (the marker ends the line).
sched_has_line() {
  local m; m=" $(cron_marker "$1")"
  crontab_lines | awk -v m="$m" 'substr($0, length($0) - length(m) + 1) == m { f = 1 } END { exit !f }'
}
# crontab_set NAME [LINE]: the crontab without the line of NAME, plus LINE when given. Other lines
# are kept as they are.
crontab_set() {
  local m; m=" $(cron_marker "$1")"
  command -v crontab >/dev/null || die "crontab is not installed; scheduled runs need cron"
  # read the table fully before writing it back
  local cur err keep
  # only stdout is the table; only "no crontab for" (in the C locale) means an empty one, and any
  # other read failure must not become a write
  err="$(mktemp)"
  if ! cur="$(LC_ALL=C crontab -l 2>"$err")"; then
    grep -q "no crontab for" "$err" || { rm -f -- "$err"; die "could not read the crontab"; }
    cur=""
  fi
  rm -f -- "$err"
  keep="$(printf '%s\n' "$cur" | awk -v m="$m" 'substr($0, length($0) - length(m) + 1) != m')"
  { if [ -n "$keep" ]; then printf '%s\n' "$keep"; fi
    if [ -n "${2:-}" ]; then printf '%s\n' "$2"; fi
  } | crontab - || die "could not write the crontab"
}

# cron_line NAME FIELDS: the crontab line that fires schedule NAME, with the paths and the Docker
# and agentic locations captured now. No token or project setting goes in.
cron_line() {
  local name="$1" cfields="$2" root bin v envs=()
  root="$(project_root)"; bin="$AGENTIC_ROOT/bin/agentic"
  for v in "$root" "$bin" "$PATH"; do cron_safe "$v" || die "a path for the crontab line has a quote, % or a newline: $(printf '%s' "$v" | plain)"; done
  envs=("PATH='$PATH'")
  for v in DOCKER_HOST DOCKER_CONTEXT AGENTIC_DATA AGENTIC_WORKSPACES; do
    if [ -n "${!v:-}" ]; then
      cron_safe "${!v}" || die "$v has a quote, % or a newline; the crontab line cannot hold it"
      envs+=("$v='${!v}'")
    fi
  done
  printf "%s cd '%s' && /usr/bin/env %s '%s' schedule fire %s >/dev/null 2>&1 %s\n" \
    "$cfields" "$root" "${envs[*]}" "$bin" "$name" "$(cron_marker "$name")"
}

sched_add() {
  local name="${1:-}" cron="" at="" prompt="" pfile="" agent="" model="" target="" worktree=1 keep=0 kof=0 timeout=2h
  local allow=() a cfields secs line d v err
  valid_sched_name "$name" || die "usage: agentic schedule add NAME (--cron \"M H DOM MON DOW\" | --at \"YYYY-MM-DD HH:MM\") [options] \"prompt\"; NAME is [a-z0-9-], at most 40"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --cron) optval "$@"; cron="$2"; shift 2 ;;
      --at) optval "$@"; at="$2"; shift 2 ;;
      --prompt-file) optval "$@"; pfile="$2"; shift 2 ;;
      --agent) optval "$@"; agent="$2"; shift 2 ;;
      --model) optval "$@"; model="$2"; shift 2 ;;
      --target) optval "$@"; target="$2"; shift 2 ;;
      --allow) optval "$@"; allow+=("$2"); shift 2 ;;
      --timeout) optval "$@"; timeout="$2"; shift 2 ;;
      --no-worktree) worktree=0; shift ;;
      --keep) keep=1; shift ;;
      --keep-on-failure) kof=1; shift ;;
      -*) die "unknown option $1 (agentic help)" ;;
      *) [ -z "$prompt" ] || die "one prompt; quote it"; prompt="$1"; shift ;;
    esac
  done
  d="$(sched_dir "$name")"
  [ ! -e "$d" ] || die "schedule $name exists; agentic schedule remove $name first"
  if { [ -n "$cron" ] && [ -n "$at" ]; } || [ -z "$cron$at" ]; then die "give either --cron or --at"; fi
  if [ -n "$cron" ]; then
    valid_cron "$cron" || die "--cron needs five cron fields (minute hour day month weekday), for example \"0 2 * * 1-5\""
    cfields="$cron"
  else
    cfields="$(at_cron "$at")" || die "--at needs a future local time within a year, as \"YYYY-MM-DD HH:MM\""
  fi
  secs="$(duration_secs "$timeout")" || die "--timeout must be 90m, 2h or seconds, from 1 minute to 24 hours"
  if [ -n "$pfile" ]; then
    [ -z "$prompt" ] || die "give either a prompt or --prompt-file"
    [ -f "$pfile" ] || die "no file $pfile"
    prompt="$(cat "$pfile")"
  fi
  [ -n "$prompt" ] || die "schedule add needs a prompt: \"...\" or --prompt-file F"
  case "$agent" in ""|claude|copilot) ;; *) die "--agent must be claude or copilot" ;; esac
  for a in ${allow[@]+"${allow[@]}"}; do valid_grant "$a" || die "unknown --allow $a (push, open-pr, deploy:<target>)"; done
  for v in "$model" "$target"; do [[ "$v" != *[[:cntrl:]]* ]] || die "--model and --target must be one line"; done
  if [ -n "$target" ]; then task_work "$target" >/dev/null || exit 1; fi
  line="$(cron_line "$name" "$cfields")"
  printf 'kind=%s\nwhen=%s\nallow=%s\nagent=%s\nmodel=%s\ntarget=%s\nworktree=%s\nkeep=%s\nkeep_on_failure=%s\ntimeout=%s\ncreated=%s\n' \
    "$([ -n "$cron" ] && echo cron || echo at)" "${cron:-$at}" "$(IFS=,; echo "${allow[*]+"${allow[*]}"}")" "$agent" "$model" \
    "$target" "$worktree" "$keep" "$kof" "$secs" "$(date -Iseconds)" | sched_write "$name"
  (umask 077; printf '%s\n' "$prompt" > "$d/prompt.md")
  if ! err="$(crontab_set "$name" "$line" 2>&1)"; then
    safe_rm "$(sched_root)" "$d"; die "could not write the crontab; nothing was added (${err#*: })"
  fi
  cron_running || say "warning: no cron daemon runs; $name fires only once cron runs (agentic doctor)"
  echo "$name: ${cron:+cron $cron}${at:+at $at}"
}

sched_remove() {
  local name="${1:-}"
  valid_sched_name "$name" || die "usage: agentic schedule remove NAME"
  [ -e "$(sched_dir "$name")" ] || sched_has_line "$name" || die "no schedule $name"
  crontab_set "$name"
  safe_rm "$(sched_root)" "$(sched_dir "$name")"
  echo "$name: removed (results stay in $(sched_results "$name"))"
}

# sched_last NAME: the newest result file's name, empty when none.
sched_last() {
  local d; d="$(sched_results "$1")"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f -name '[0-9]*-[0-9]*-*.md' -printf '%f\n' | sort | tail -n 1
}
# result_state FILE: the State cell of a result file.
result_state() { sed -n 's/^| State | \(.*\) |$/\1/p' "$1" | head -n 1; }

# sched_show NAME [--all]: the newest result, or every result file newest first.
sched_show() {
  local name="${1:-}" dir f
  valid_sched_name "$name" || die "usage: agentic schedule results NAME [--all]"
  dir="$(sched_results "$name")"
  if [ -z "$(sched_last "$name")" ]; then echo "no results for $name yet"; return 0; fi
  if [ "${2:-}" = --all ]; then
    find "$dir" -maxdepth 1 -type f -name '[0-9]*-[0-9]*-*.md' -printf '%f\n' | sort -r | while IFS= read -r f; do
      printf '%s  %s  %s\n' "$f" "$(result_state "$dir/$f" | plain)" "$dir/$f"
    done
  else
    plain < "$dir/$(sched_last "$name")"
  fi
}

sched_list() {
  local json=0 d n last st rows=()
  [ "${1:-}" != --json ] || json=1
  for d in "$(sched_root)"/*/; do
    n="$(basename "$d")"
    { valid_sched_name "$n" && [ -f "$d/schedule" ]; } || continue
    last="$(sched_last "$n")"; st=""
    if [ -n "$last" ]; then st="$(result_state "$(sched_results "$n")/$last" | plain)"; fi
    rows+=("$(jq -cn --arg n "$n" --arg k "$(sched_get "$n" kind)" --arg w "$(sched_get "$n" when)" --arg a "$(sched_get "$n" allow)" \
      --arg keep "$(sched_get "$n" keep)" --arg t "$(sched_get "$n" timeout)" --arg l "$last" --arg s "$st" \
      --argjson c "$(sched_has_line "$n" && echo true || echo false)" \
      '{name: $n, kind: $k, when: $w, allow: $a, keep: ($keep == "1"), timeout: ($t | tonumber? // null), cron: $c,
        last: (if $l == "" then null else {file: $l, state: $s} end)}')")
  done
  if [ "$json" = 1 ]; then printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -cs .; return 0; fi
  [ ${#rows[@]} -gt 0 ] || { echo "no schedules in $(task_project)"; return 0; }
  printf '%-20s %-5s %-22s %-14s %-6s %s\n' NAME KIND WHEN ALLOW CRON LAST
  printf '%s\n' "${rows[@]}" | jq -r '[.name, .kind, .when, (if .allow == "" then "-" else .allow end),
    (if .cron then "yes" else "MISSING" end), (if .last then .last.state else "-" end)] | @tsv' \
    | while IFS=$'\t' read -r a b c e f g; do printf '%-20s %-5s %-22s %-14s %-6s %s\n' "$a" "$b" "$c" "$e" "$f" "$g"; done
}

# sched_lock NAME: one firing per schedule. A lock whose pid is gone is taken over; the task it
# names is reported as interrupted and kept (its work may not be pushed).
sched_lock() {
  local l old t; l="$(sched_dir "$1")/lock"
  if ! mkdir "$l" 2>/dev/null; then
    old="$(cat "$l/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 1; fi
    t="$(cat "$l/task" 2>/dev/null || true)"
    rm -rf -- "$l"; mkdir "$l" || return 1
    if valid_task_id "$t" && task_readable "$t" state.json; then
      sched_result "$1" "$t" "interrupted (the firing ended before its run)" "interrupted firing; agentic clean $t"
    fi
  fi
  echo $$ > "$l/pid"
}
sched_unlock() { rm -rf -- "$(sched_dir "$1")/lock"; }

# sched_wait ID SECONDS: until the run ended: the container stopped, the record says stopped or
# failed, or the bridge check failed twice in a row (one failure may be a Docker hiccup). Past
# SECONDS plus the grace the host stops it (the bridge's own timeout should have ended it) and
# returns 1.
sched_wait() {
  local id="$1" c end miss=0; c="$(task_container "$1")"
  end=$((SECONDS + $2 + ${AGENTIC_SCHEDULE_GRACE:-600}))
  while [ "$(container_status "$id")" = running ]; do
    case "$(record_get "$id" .state)" in stopped|failed) return 0 ;; esac
    if bridge_running "$c"; then miss=0; else miss=$((miss + 1)); [ "$miss" -lt 2 ] || return 0; fi
    if [ "$SECONDS" -ge "$end" ]; then
      say "$id overran its timeout; stopping it"
      bridge_req "$id" POST /stop >/dev/null 2>&1 || true
      wait_bridge_gone "$c" "${AGENTIC_STOP_TIMEOUT:-30}" || docker exec "$c" pkill -f 'bridge/dist/main\.js$' >/dev/null 2>&1 || true
      return 1
    fi
    sleep "${AGENTIC_SCHEDULE_POLL:-5}"
  done
}

# cell TEXT: one Markdown table cell (at most 500 characters, one line, no control characters, | escaped).
cell() { local t="${1:0:500}"; printf '%s' "$t" | plain | tr '\n\t' '  ' | sed 's/|/\\|/g'; }

# sched_read_capped ID NAME: at most 64 KiB of a task file, capped at the read (no SIGPIPE).
sched_read_capped() {
  task_readable "$1" "$2" && dd if="$(task_dir "$1")/$2" iflag=nofollow,nonblock,count_bytes count=65536 status=none 2>/dev/null
}

# sched_result NAME ID STATE KEPT [AT]: the result file of one firing, named and headed with AT
# (epoch seconds of the firing; now when not given). Agent-written files are read with the
# safe-read rules and capped.
sched_result() {
  local name="$1" id="$2" state="$3" kept="$4" at="${5:-$(date +%s)}" dir f branch="" allowed="" open="" body=""
  dir="$(sched_results "$name")"; mkdir -p "$dir"
  f="$dir/$(date -d "@$at" +%Y%m%d-%H%M)-${id:-none}.md"
  if [ -n "$id" ] && task_readable "$id" state.json; then
    branch="$(record_get "$id" .branch)"
    allowed="$(record_get "$id" '(.allowed_actions // []) | join(", ")')"
    open="$(open_questions "$id" | jq -r 'map("\(.id): \(.text)") | join("; ")' 2>/dev/null || true)"
    if [[ "$state" == failed* ]]; then
      body="$(r="$(record_get "$id" .reason)"; printf 'Reason: %s\n\n' "$(printf '%s' "${r:0:500}" | plain)"; if task_readable "$id" bridge.log; then task_read "$id" bridge.log | tail -n 20 | plain; fi)"
    elif task_readable "$id" result.md; then body="$(sched_read_capped "$id" result.md | plain)"
    fi
  fi
  {
    printf '# %s — %s\n\n| | |\n|---|---|\n' "$name" "$(date -d "@$at" '+%Y-%m-%d %H:%M')"
    printf '| Task | %s |\n| State | %s |\n| Branch | %s |\n| Allowed | %s |\n| Open questions | %s |\n| Kept | %s |\n' \
      "$(cell "${id:--}")" "$(cell "$state")" "$(cell "${branch:--}")" "$(cell "${allowed:--}")" "$(cell "${open:-none}")" "$(cell "${kept:-no}")"
    if [ -n "$body" ]; then printf '\n%s\n' "$body"; fi
  } > "$f"
  echo "$name: $state → $f"
}

# sched_fire NAME now|cron: one firing (spec §5). cron: output to fire.log, and a one-off checks its
# year and removes itself. Exits 0 whenever it wrote a result.
sched_fire() {
  local name="${1:-}" mode="$2" d id secs out st reason kept keep c a at timed=0 args=() allow=()
  valid_sched_name "$name" || die "usage: agentic schedule run NAME"
  at="$(date +%s)"   # the firing time names the result
  d="$(sched_dir "$name")"
  if [ ! -f "$d/schedule" ]; then
    [ "$mode" = cron ] || die "no schedule $name"
    crontab_set "$name"; return 0
  fi
  if [ "$mode" = cron ]; then
    if [ -f "$d/fire.log" ]; then tail -n 999 "$d/fire.log" > "$d/fire.log.tmp" && mv -f "$d/fire.log.tmp" "$d/fire.log"; fi
    exec >>"$d/fire.log" 2>&1
    echo "== $(date '+%F %T') fire $name"
    if [ "$(sched_get "$name" kind)" = at ] && [ "$(date +%Y)" != "$(sched_get "$name" when | cut -c1-4)" ]; then return 0; fi
  fi
  if ! sched_lock "$name"; then sched_result "$name" "" "skipped (the previous run still runs)" ""; return 0; fi
  if ! out="$( (check_cap) 2>&1 )"; then
    sched_result "$name" "" "skipped ($(tail -n 1 <<<"$out" | sed 's/^agentic: //'))" ""; sched_end "$name" "$mode"; return 0
  fi
  id="$(new_task_id)"; echo "$id" > "$d/lock/task"
  secs="$(sched_get "$name" timeout)"
  args=(--id "$id" --scheduled "$secs" --prompt-file "$d/prompt.md")
  # --keep keeps everything, the worktree too: no auto-clean
  [ "$(sched_get "$name" keep)" = 1 ] || args+=(--auto-clean)
  [ "$(sched_get "$name" worktree)" != 1 ] || args+=(--worktree)
  for a in agent model target; do if [ -n "$(sched_get "$name" "$a")" ]; then args+=("--$a" "$(sched_get "$name" "$a")"); fi; done
  IFS=, read -ra allow <<<"$(sched_get "$name" allow)"
  for a in ${allow[@]+"${allow[@]}"}; do args+=(--allow "$a"); done
  if ! out="$( (cmd_run "${args[@]}") 2>&1 )"; then
    sched_result "$name" "$id" "refused ($(tail -n 1 <<<"$out" | sed 's/^agentic: //' | plain))" "" "$at"; sched_end "$name" "$mode"; return 0
  fi
  echo "$name: started $id"
  sched_wait "$id" "$secs" || timed=1
  st="$(record_get "$id" .state)"; reason="$(record_get "$id" .reason)"
  case "$st" in stopped|failed) st="$st (${reason:-no reason})" ;; *) st="${st:-unknown} (the run did not end)" ;; esac
  if [ "$timed" = 1 ]; then st="stopped (timeout)"; fi
  keep=""
  if [ "$(sched_get "$name" keep)" = 1 ]; then keep="--keep"
  elif [[ "$st" == failed* ]] && [ "$(sched_get "$name" keep_on_failure)" = 1 ]; then keep="--keep-on-failure"; fi
  kept=""
  c="$(task_container "$id")"
  if task_has_worktree "$id"; then
    if [ "$(container_status "$id")" = running ]; then
      # as clean does, in the container before it stops; a kept run keeps its worktree
      if [ -n "$keep" ]; then worktree_cmd "$id" check >/dev/null 2>&1 || kept="unpushed work"
      else worktree_cmd "$id" remove >/dev/null 2>&1 || kept="unpushed work"; fi
    else
      # the bridge removes the worktree on a clean auto-clean; a folder left in the checkout is unchecked work
      local work wt; work="$(dotenv_value "$(host_file "$id" env)" AGENTIC_WORK 2>/dev/null || true)"
      wt="$(project_root)${work#/work}/.worktrees/$id"
      if [ -e "$wt" ] || [ -L "$wt" ]; then kept="worktree not checked"; fi
    fi
  fi
  if [ "$(container_status "$id")" = running ]; then docker stop "$c" >/dev/null 2>&1 || say "could not stop $c"; fi
  kept="${kept:-$keep}"
  sched_result "$name" "$id" "$st" "${kept:+$kept; agentic clean $id}" "$at"
  if [ -z "$kept" ]; then rollback_task "$id"; fi
  sched_end "$name" "$mode"
}

# sched_end NAME MODE: releases the lock; a fired one-off removes its line and definition.
sched_end() {
  sched_unlock "$1"
  if [ "$2" = cron ] && [ "$(sched_get "$1" kind)" = at ]; then
    crontab_set "$1"
    safe_rm "$(sched_root)" "$(sched_dir "$1")"
  fi
}

# sched_doctor: the host's part of doctor: cron runs, and definitions and crontab lines match.
sched_doctor() {
  local d n names=() lines=() errs=0 p; p="$(task_project)"
  for d in "$(sched_root)"/*/; do n="$(basename "$d")"; if valid_sched_name "$n" && [ -f "$d/schedule" ]; then names+=("$n"); fi; done
  mapfile -t lines < <(crontab_lines | sed -n "s/.* # agentic:$p:\([a-z0-9-]*\)\$/\1/p")
  [ ${#names[@]} -gt 0 ] || [ ${#lines[@]} -gt 0 ] || return 0
  echo "schedules"
  if cron_running; then echo "  ok    cron"
  else echo "  error cron: no cron daemon runs; on WSL set systemd=true in /etc/wsl.conf, or sudo service cron start"; errs=1; fi
  for n in ${names[@]+"${names[@]}"}; do
    if printf '%s\n' ${lines[@]+"${lines[@]}"} | grep -qx -- "$n"; then echo "  ok    schedule $n"
    else echo "  error schedule $n: no crontab line; agentic schedule remove $n, then add it again"; errs=1; fi
  done
  for n in ${lines[@]+"${lines[@]}"}; do
    [ -f "$(sched_dir "$n")/schedule" ] && continue
    echo "  error schedule $n: a crontab line without a definition; agentic schedule remove $n"; errs=1
  done
  return "$errs"
}
