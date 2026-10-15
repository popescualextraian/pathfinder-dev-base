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
  printf 'version: 2\nproject: demo\nlayout: single\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  S="$AGENTIC_DATA/projects/demo/schedules"
  R="$AGENTIC_WORKSPACES/demo/results"
  T="$AGENTIC_WORKSPACES/demo/tasks"
  H="$AGENTIC_DATA/projects/demo/tasks"
  : > "$BATS_TEST_TMPDIR/docker.known"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# lib FUNC ARGS...: one helper of bin/agentic, in the project.
lib() { (cd "$PROJ" && source "$A" && "$@"); }

@test "schedule names, cron fields, one-off times and durations are validated" {
  lib valid_sched_name nightly-deps
  run ! lib valid_sched_name Nightly
  run ! lib valid_sched_name -x
  run ! lib valid_sched_name "$(printf 'a%.0s' $(seq 41))"
  lib valid_cron "0 2 * * 1-5"
  lib valid_cron "*/15 8-18 * jan,feb mon-fri"
  run ! lib valid_cron "0 2 * *"
  run ! lib valid_cron "0 2 * * 1 6"
  run ! lib valid_cron "@reboot"
  run ! lib valid_cron "0 2 * * 1%x"
  when="$(date -d '+1 day' '+%Y-%m-%d 22:30')"
  run lib at_cron "$when"
  [ "$output" = "30 22 $(date -d "$when" +%-d) $(date -d "$when" +%-m) *" ]
  run ! lib at_cron "$(date -d '-1 day' '+%Y-%m-%d %H:%M')"
  run ! lib at_cron "$(date -d '+400 days' '+%Y-%m-%d %H:%M')"
  run ! lib at_cron "tomorrow"
  [ "$(lib duration_secs 2h)" = 7200 ]
  [ "$(lib duration_secs 90m)" = 5400 ]
  [ "$(lib duration_secs 600)" = 600 ]
  run ! lib duration_secs 30
  run ! lib duration_secs 25h
  run ! lib duration_secs 2d
}

@test "a definition is written atomically, private, and read back by key" {
  printf 'kind=cron\nwhen=0 2 * * 1-5\nallow=push,open-pr\n' | lib sched_write nightly
  [ "$(stat -c %a "$S/nightly")" = 700 ]
  [ "$(stat -c %a "$S/nightly/schedule")" = 600 ]
  [ "$(lib sched_get nightly when)" = "0 2 * * 1-5" ]
  [ "$(lib sched_get nightly allow)" = "push,open-pr" ]
  [ ! -e "$S/nightly/schedule.tmp" ]
}
