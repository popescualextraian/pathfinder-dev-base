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
  # crontab stand-in: the table lives in $BATS_TEST_TMPDIR/crontab; CRONTAB_FAIL=1 fails a write
  cat > "$BATS_TEST_TMPDIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
f="$BATS_TEST_TMPDIR/crontab"
case "$1" in
  -l) [ -z "${CRONTAB_READ_FAIL:-}" ] || { echo "crontab: cannot open spool" >&2; exit 1; }
      [ -f "$f" ] || { echo "no crontab for user" >&2; exit 1; }; cat "$f" ;;
  -) [ -z "${CRONTAB_FAIL:-}" ] || exit 1; cat > "$f" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/crontab"
  CT="$BATS_TEST_TMPDIR/crontab"
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
  run ! lib valid_cron $'0 2 * * 1\n* * * * *'
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

@test "add writes the definition, the prompt and one marked crontab line; other lines stay" {
  printf '# mine\n5 4 * * * /usr/bin/true\n' > "$CT"
  run ag schedule add nightly --cron "0 2 * * 1-5" --allow open-pr --timeout 90m "Update the dependencies"
  [ "$status" -eq 0 ]
  [ "$(cat "$S/nightly/prompt.md")" = "Update the dependencies" ]
  for l in kind=cron "when=0 2 * * 1-5" allow=open-pr worktree=1 keep=0 keep_on_failure=0 timeout=5400; do grep -qxF -- "$l" "$S/nightly/schedule"; done
  [ "$(sed -n 1,2p "$CT")" = "$(printf '# mine\n5 4 * * * /usr/bin/true')" ]
  line="$(grep -F '# agentic:demo:nightly' "$CT")"
  [[ "$line" == "0 2 * * 1-5 cd '$PROJ' && /usr/bin/env PATH='"* ]]
  [[ "$line" == *" '$REPO_ROOT/bin/agentic' schedule fire nightly >/dev/null 2>&1 # agentic:demo:nightly" ]]
  [ "$(grep -c agentic: "$CT")" = 1 ]
}

@test "add --at writes the fields of that minute; --no-worktree, --keep and --keep-on-failure are stored" {
  when="$(date -d '+2 days' '+%Y-%m-%d 06:05')"
  ag schedule add once --at "$when" --no-worktree --keep --keep-on-failure "x"
  for l in kind=at "when=$when" worktree=0 keep=1 keep_on_failure=1 timeout=7200; do grep -qxF -- "$l" "$S/once/schedule"; done
  grep -q "^5 6 $(date -d "$when" +%-d) $(date -d "$when" +%-m) \* cd " "$CT"
}

@test "add refuses a bad name, an existing name, both or neither of --cron and --at, bad values, and writes nothing" {
  run ag schedule add Bad --cron "0 2 * * *" x; [ "$status" -ne 0 ]
  run ag schedule add a "x"; [ "$status" -ne 0 ]; [[ "$output" == *"either --cron or --at"* ]]
  run ag schedule add a --cron "0 2 * * *" --at "2099-01-01 00:00" x; [ "$status" -ne 0 ]
  run ag schedule add a --cron "0 2 * *" x; [ "$status" -ne 0 ]; [[ "$output" == *"five cron fields"* ]]
  run ag schedule add a --at "$(date -d '-1 day' '+%Y-%m-%d %H:%M')" x; [ "$status" -ne 0 ]
  run ag schedule add a --cron "0 2 * * *" --timeout 30 x; [ "$status" -ne 0 ]
  run ag schedule add a --cron "0 2 * * *" --allow merge x; [ "$status" -ne 0 ]
  run ag schedule add a --cron "0 2 * * *" --agent gpt x; [ "$status" -ne 0 ]
  run ag schedule add a --cron "0 2 * * *"; [ "$status" -ne 0 ]; [[ "$output" == *"prompt"* ]]
  [ ! -e "$S/a" ]; [ ! -e "$CT" ]
  ag schedule add a --cron "0 2 * * *" x
  run ag schedule add a --cron "0 3 * * *" y; [ "$status" -ne 0 ]; [[ "$output" == *"exists"* ]]
}

@test "add refuses a path with a quote or a percent sign, which would break the crontab line" {
  mv "$PROJ" "$BATS_TEST_TMPDIR/pro%j"; PROJ="$BATS_TEST_TMPDIR/pro%j"
  run ag schedule add a --cron "0 2 * * *" x
  [ "$status" -ne 0 ]; [[ "$output" == *"quote, % or a newline"* ]]
  [ ! -e "$S/a" ]
}

@test "a failing crontab write leaves no definition" {
  run env CRONTAB_FAIL=1 bash -c "cd '$PROJ' && bash '$A' schedule add a --cron '0 2 * * *' x"
  [ "$status" -ne 0 ]; [[ "$output" == *"could not write the crontab"* ]]
  [ ! -e "$S/a" ]
}

@test "remove takes only its own line, also when another name starts the same, and keeps the results" {
  ag schedule add nightly --cron "0 2 * * *" x
  ag schedule add nightly-deps --cron "0 3 * * *" y
  mkdir -p "$R/nightly"; echo r > "$R/nightly/20261016-0200-T-1.md"
  run ag schedule remove nightly
  [ "$status" -eq 0 ]
  run ! grep -q '# agentic:demo:nightly$' "$CT"
  grep -q '# agentic:demo:nightly-deps$' "$CT"
  [ ! -e "$S/nightly" ]; [ -e "$S/nightly-deps" ]; [ -e "$R/nightly/20261016-0200-T-1.md" ]
  run ag schedule remove nightly; [ "$status" -ne 0 ]; [[ "$output" == *"no schedule nightly"* ]]
}

@test "list shows each schedule, its last result and whether cron has it; --json too" {
  ag schedule add nightly --cron "0 2 * * 1-5" --allow open-pr x
  mkdir -p "$R/nightly"; printf '# nightly\n\n| | |\n|---|---|\n| State | stopped (scheduled-done) |\n' > "$R/nightly/20261016-0200-T-1.md"
  run ag schedule list
  [ "$status" -eq 0 ]
  [[ "$output" == *nightly*"0 2 * * 1-5"*"stopped (scheduled-done)"* ]]
  run ag schedule list --json
  [ "$(jq -r '.[0] | [.name, .kind, .when, .cron, .last.state] | @tsv' <<<"$output")" = "$(printf 'nightly\tcron\t0 2 * * 1-5\ttrue\tstopped (scheduled-done)')" ]
  : > "$CT"
  run ag schedule list --json
  [ "$(jq -r '.[0].cron' <<<"$output")" = false ]
}

@test "an unreadable crontab fails add and remove and is never replaced" {
  ag schedule add keep --cron "0 2 * * *" x
  printf '# mine\n' >> "$CT"; cp "$CT" "$BATS_TEST_TMPDIR/before"
  run env CRONTAB_READ_FAIL=1 bash -c "cd '$PROJ' && bash '$A' schedule add a --cron '0 2 * * *' x"
  [ "$status" -ne 0 ]; [[ "$output" == *"could not read the crontab"* ]]
  cmp "$CT" "$BATS_TEST_TMPDIR/before"; [ ! -e "$S/a" ]
  run env CRONTAB_READ_FAIL=1 bash -c "cd '$PROJ' && bash '$A' schedule remove keep"
  [ "$status" -ne 0 ]
  cmp "$CT" "$BATS_TEST_TMPDIR/before"; [ -e "$S/keep/schedule" ]
}

# ended STATE REASON [RESULT]: a fake bridge run: the start hook writes the record (and result.md) the bridge would leave.
ended() {
  export DOCKER_START_HOOK="$BATS_TEST_TMPDIR/ended.sh" DOCKER_BRIDGE_RC=1
  cat > "$DOCKER_START_HOOK" <<HOOK
d="\$(ls -d "$T"/T-* | head -n 1)"
jq -n --arg s "$1" --arg r "$2" '{version:1, state:\$s, reason:\$r, branch:"agentic/x", allowed_actions:["open-pr"], cleaned:false}' > "\$d/state.json"
printf '%s' "${3:-}" > "\$d/result.md"
HOOK
}
results() { find "$R/$1" -type f -name '*.md' | sort; }

@test "run fires now: scheduled defaults, the result with the summary, and everything removed" {
  ag schedule add nightly --cron "0 2 * * *" --allow open-pr --timeout 90m "Update"
  ended stopped scheduled-done "Did the update. PR opened."
  run ag schedule run nightly
  [ "$status" -eq 0 ]
  f="$(results nightly)"
  [ -n "$f" ]
  grep -qx '| State | stopped (scheduled-done) |' "$f"
  grep -qx '| Allowed | open-pr |' "$f"
  grep -qx '| Kept | no |' "$f"
  grep -qx 'Did the update. PR opened.' "$f"
  [ -z "$(ls -A "$T")" ]; [ -z "$(ls -A "$H")" ]
  [ ! -e "$S/nightly/lock" ]
  docker_sub stop | grep -q agentic-demo-task-
}

@test "the task env of a firing has the scheduled settings, worktree and auto-clean" {
  ag schedule add nightly --cron "0 2 * * *" --timeout 90m --keep "Update"
  ended stopped scheduled-done "ok"
  ag schedule run nightly
  e="$(ls "$H"/*/env)"
  for l in AGENTIC_SCHEDULED=1 AGENTIC_RUN_TIMEOUT=5400 AGENTIC_WORKTREE=1 AGENTIC_AUTO_CLEAN=1; do grep -qx "$l" "$e"; done
}

@test "--no-worktree runs without a worktree" {
  ag schedule add nightly --cron "0 2 * * *" --no-worktree --keep "Update"
  ended stopped scheduled-done "ok"
  ag schedule run nightly
  grep -qx AGENTIC_WORKTREE=0 "$(ls "$H"/*/env)"
}

@test "--keep keeps the stopped container and the task files, and the result says how to clean" {
  ag schedule add nightly --cron "0 2 * * *" --keep "Update"
  ended stopped scheduled-done "ok"
  ag schedule run nightly
  [ -n "$(ls -A "$T")" ]
  grep -Eq '^\| Kept \| --keep; agentic clean T-[0-9]{8}-[0-9a-f]{4} \|$' "$(results nightly)"
  run ! grep -q task <<<"$(docker_sub rm)"
}

@test "a failed run is removed, or kept with --keep-on-failure; its result has the reason" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended failed "agent exited with code 3"
  ag schedule run a
  grep -qx '| State | failed (agent exited with code 3) |' "$(results a)"
  grep -q 'Reason: agent exited with code 3' "$(results a)"
  [ -z "$(ls -A "$T")" ]
  ag schedule add b --cron "0 2 * * *" --keep-on-failure "x"
  ag schedule run b
  grep -q '| Kept | --keep-on-failure; agentic clean ' "$(results b)"
}

@test "unpushed work keeps the run whatever the flags" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  export DOCKER_WT_ERR="agentic-worktree: has commits on no remote branch"
  ag schedule run a
  grep -q '| Kept | unpushed work; agentic clean ' "$(results a)"
  [ -n "$(ls -A "$T")" ]
}

@test "a live lock skips the firing; a stale one is taken over and its task is reported and kept" {
  ag schedule add a --cron "0 2 * * *" "x"
  mkdir "$S/a/lock"; echo $$ > "$S/a/lock/pid"
  run ag schedule run a
  [ "$status" -eq 0 ]
  grep -qx '| State | skipped (the previous run still runs) |' "$(results a)"
  rm -rf "$R/a"
  echo 999999 > "$S/a/lock/pid"; echo T-OLD > "$S/a/lock/task"
  mkdir -p "$T/T-OLD" "$H/T-OLD"; echo '{"state":"running"}' > "$T/T-OLD/state.json"
  ended stopped scheduled-done "ok"
  ag schedule run a
  grep -l interrupted $(results a)
  [ -e "$T/T-OLD/state.json" ]
}

@test "the running cap skips the firing" {
  ag schedule add a --cron "0 2 * * *" "x"
  export DOCKER_PS="c1 c2 c3"
  run ag schedule run a
  [ "$status" -eq 0 ]
  grep -q '| State | skipped (' "$(results a)"
}

@test "a refused run is a result with run's message" {
  ag schedule add a --cron "0 2 * * *" "x"
  export DOCKER_IMAGE_EXISTS=0 DOCKER_RUN_RC=1
  run ag schedule run a
  [ "$status" -eq 0 ]
  grep -q '| State | refused (' "$(results a)"
}

@test "fire logs to fire.log; a one-off removes itself after it fired, and skips another year" {
  when="$(date -d '+1 day' '+%Y-%m-%d %H:%M')"
  ag schedule add once --at "$when" "x"
  sed -i "s/^when=[0-9]\{4\}/when=1999/" "$S/once/schedule"
  ag schedule fire once
  grep -q 'fire once' "$S/once/fire.log"
  [ ! -e "$R/once" ]; grep -q '# agentic:demo:once' "$CT"
  sed -i "s/^when=1999/when=$(date +%Y)/" "$S/once/schedule"
  ended stopped scheduled-done "ok"
  ag schedule fire once
  [ -n "$(results once)" ]
  run ! grep -q '# agentic:demo:once' "$CT"
  [ ! -e "$S/once" ]
}

@test "fire of a removed schedule drops its leftover crontab line" {
  printf '0 2 * * * x # agentic:demo:gone\n' > "$CT"
  run ag schedule fire gone
  [ "$status" -eq 0 ]
  ! grep -q 'agentic:demo:gone' "$CT"
}

@test "a run that overruns its timeout is stopped by the host" {
  ag schedule add a --cron "0 2 * * *" --timeout 60 "x"
  export DOCKER_BRIDGE_RC=0 AGENTIC_SCHEDULE_GRACE=0 AGENTIC_SCHEDULE_POLL=0.1 AGENTIC_STOP_TIMEOUT=0
  export CURL_BODY='{"state":"running"}'   # run's start-up wait sees a live bridge
  sed -i 's/^timeout=60/timeout=0/' "$S/a/schedule"
  run ag schedule run a
  [ "$status" -eq 0 ]
  grep -q '/stop' "$CURL_LOG"
}

@test "a huge result.md is capped at 64 KiB and the firing still completes" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  echo "head -c 400000 /dev/zero | tr '\\0' x > \"\$d/result.md\"" >> "$DOCKER_START_HOOK"
  run ag schedule run a
  [ "$status" -eq 0 ]
  f="$(results a)"
  [ -n "$f" ]
  [ "$(grep -c '^xxxx' "$f")" -eq 1 ]
  [ "$(wc -c < "$f")" -lt 66000 ]
  [ -z "$(ls -A "$T")" ]; [ ! -e "$S/a/lock" ]
}

@test "a failed run with an empty result.md still reports its reason" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended failed "boom" ""
  ag schedule run a
  grep -q 'Reason: boom' "$(results a)"
}

@test "long agent-written header values are capped at 500 characters" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  echo "jq --arg b \"\$(head -c 3000 /dev/zero | tr '\\0' b)\" '.branch=\$b' \"\$d/state.json\" > \"\$d/s2\" && mv \"\$d/s2\" \"\$d/state.json\"" >> "$DOCKER_START_HOOK"
  ag schedule run a
  [ "$(grep '^| Branch |' "$(results a)" | wc -c)" -lt 600 ]
}

@test "a record that says cleaned does not skip the worktree check" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  echo "jq '.cleaned=true' \"\$d/state.json\" > \"\$d/s2\" && mv \"\$d/s2\" \"\$d/state.json\"" >> "$DOCKER_START_HOOK"
  export DOCKER_WT_ERR="agentic-worktree: has commits on no remote branch"
  ag schedule run a
  grep -q '| Kept | unpushed work; agentic clean ' "$(results a)"
  [ -n "$(ls -A "$T")" ]
}

@test "a worktree run whose container is not running is kept unchecked" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  echo "echo exited > \"$BATS_TEST_TMPDIR/docker.status\"; mkdir -p \"$PROJ/.worktrees/\$(basename \"\$d\")\"" >> "$DOCKER_START_HOOK"
  ag schedule run a
  grep -q '| Kept | worktree not checked; agentic clean ' "$(results a)"
  [ -n "$(ls -A "$T")" ]
}

@test "results prints the newest result; --all lists them newest first" {
  mkdir -p "$R/a"
  printf '# a\n\n| State | failed (x) |\n\nold\n' > "$R/a/20261015-0200-T-1.md"
  printf '# a\n\n| State | stopped (scheduled-done) |\n\nnew\n' > "$R/a/20261016-0200-T-2.md"
  run ag schedule results a
  [ "$status" -eq 0 ]; [[ "$output" == *new* ]]; [[ "$output" != *old* ]]
  run ag schedule results a --all
  [ "$(sed -n 1p <<<"$output")" = "20261016-0200-T-2.md  stopped (scheduled-done)  $R/a/20261016-0200-T-2.md" ]
  [ "$(sed -n 2p <<<"$output")" = "20261015-0200-T-1.md  failed (x)  $R/a/20261015-0200-T-1.md" ]
  run ag schedule results none
  [ "$status" -eq 0 ]; [ "$output" = "no results for none yet" ]
}

@test "doctor says nothing about schedules when there are none" {
  run ag doctor
  [[ "$output" != *schedules* ]]
}

@test "doctor reports a missing cron daemon and a schedule without its crontab line" {
  install_cmd_stub pgrep 1
  mkdir -p "$S/nightly"; echo kind=cron > "$S/nightly/schedule"
  printf '0 3 * * * x # agentic:demo:orphan\n' > "$CT"
  run ag doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"error cron: no cron daemon runs"* ]]
  [[ "$output" == *"error schedule nightly: no crontab line"* ]]
  [[ "$output" == *"error schedule orphan: a crontab line without a definition; agentic schedule remove orphan"* ]]
}

@test "doctor is content with cron running and every line in place" {
  install_cmd_stub pgrep 0
  ag schedule add nightly --cron "0 2 * * *" x
  run ag doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    cron"* ]]; [[ "$output" == *"ok    schedule nightly"* ]]
}

@test "an auto-cleaned run whose container exited is removed" {
  ag schedule add a --cron "0 2 * * *" "x"
  ended stopped scheduled-done "ok"
  echo "echo exited > \"$BATS_TEST_TMPDIR/docker.status\"" >> "$DOCKER_START_HOOK"
  ag schedule run a
  grep -qx '| Kept | no |' "$(results a)"
  [ -z "$(ls -A "$T")" ]
}
