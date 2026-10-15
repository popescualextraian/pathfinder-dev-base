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
