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
