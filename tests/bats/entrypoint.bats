#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps"
  mkdir -p "$AGENTIC_STEPS_DIR"
  E="$REPO_ROOT/image/entrypoint.sh"
}

step() { printf '#!/usr/bin/env bash\nsource "$AGENTIC_DIR/lib/common.sh"\n%s\n' "$2" > "$AGENTIC_STEPS_DIR/$1.sh"; }

@test "runs steps in numeric order, then the command" {
  step 20-b 'echo b >> "$HOME/order"'
  step 10-a 'echo a >> "$HOME/order"'
  run bash "$E" echo done
  [ "$status" -eq 0 ]
  [ "$output" = done ]
  [ "$(tr -d '\n' < "$HOME/order")" = ab ]
}

@test "a warning step is reported and start continues" {
  step 10-w 'echo "careful"; exit 2'
  step 20-ok 'touch "$HOME/ran"'
  run bash "$E" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"10-w: careful"* ]]
  [ -f "$HOME/ran" ]
}

@test "a fatal step stops the start with its output and a non-zero exit" {
  step 10-bad 'echo "broken config"; exit 1'
  step 20-never 'touch "$HOME/ran"'
  run bash "$E" echo done
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken config"* ]]
  [[ "$output" == *"start step 10-bad failed"* ]]
  [ ! -f "$HOME/ran" ]
}

@test "variables a step exports reach later steps and the command" {
  step 10-set 'env_export GREETING "hello world"'
  step 20-use 'echo "$GREETING" > "$HOME/seen"'
  run bash "$E" bash -c 'echo "$GREETING"'
  [ "$output" = "hello world" ]
  [ "$(cat "$HOME/seen")" = "hello world" ]
}

@test "the env file starts empty on every start (a restarted container does not accumulate)" {
  step 10-set 'env_export X 1'
  bash "$E" true
  bash "$E" true
  [ "$(grep -c '^export X=' "$AGENTIC_STATE/env")" -eq 1 ]
}

@test "steps are quiet unless AGENTIC_DEBUG=1, and everything is in the start log" {
  step 10-chatty 'echo chatter'
  run bash "$E" true
  [ "$output" = "" ]
  grep -q chatter "$AGENTIC_STATE/start.log"
  AGENTIC_DEBUG=1 run bash "$E" true
  [[ "$output" == *chatter* ]]
}

@test "worker mode hands over to the adapter with the arguments" {
  printf '#!/usr/bin/env bash\necho "adapter $* $GREETING"\n' > "$AGENTIC_DIR/worker.d/fake.sh"
  step 10-set 'env_export GREETING hi'
  AGENTIC_WORKER_MODE=fake run bash "$E" one two
  [ "$status" -eq 0 ]
  [ "$output" = "adapter one two hi" ]
}

@test "worker mode without its adapter fails clearly" {
  AGENTIC_WORKER_MODE=nope run bash "$E" true
  [ "$status" -eq 1 ]
  [[ "$output" == *"no worker adapter nope"* ]]
}
