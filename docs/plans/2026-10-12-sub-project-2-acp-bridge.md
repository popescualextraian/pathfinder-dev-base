# Sub-project 2 — ACP bridge for detached tasks: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detached tasks in containers built from our image: one TypeScript ACP bridge per task container drives Claude (through `claude-agent-acp`) or Copilot (`copilot --acp`), serves a small HTTP + WebSocket API, and `bin/agentic` starts, lists, follows, answers, suspends, resumes and stops tasks.

**Architecture:** The bash layer (start steps, hooks, action gate, `agentic-ask`, `bin/agentic`) is ported from the archived tmux attempt and adapted. A new `bridge/` package holds a pure state machine (`task.ts`), file store (`store.ts`), ACP client and update mapping (`agent.ts`, `map.ts`), HTTP/WS API (`api.ts`, `server.ts`), notify, and an orchestrator (`bridge.ts`). Everything is tested without tokens against a scripted fake ACP agent.

**Tech Stack:** bash, jq, bats, shellcheck; TypeScript 5 on Node 22, `@agentclientprotocol/sdk` 1.8.0, `@agentclientprotocol/claude-agent-acp` 0.89.1, `ws` 8, vitest 3, eslint 9 with typescript-eslint 8; Docker.

**Spec:** `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` (read it first; section numbers below refer to it).

## Global Constraints

- No company resources in the repository: no certificates, company names, hosts, URLs or product-specific integrations; examples use `example.com`; no hub is named. `make lint` runs the leak check.
- No secret in an image layer, `~/.claude.json`, `~/.agentic/env`, a log, `state.json`, events, questions, the transcript or notify payloads.
- bash: `set -euo pipefail` (hooks and start steps keep the repository's `set -uo pipefail` where they must not abort), short comments, shellcheck-clean, a bats test for every behaviour, written first.
- TypeScript: `strict` tsc, eslint clean, a vitest test for every behaviour, written first; dependencies pinned exactly (`npm install --save-exact`) with `package-lock.json` committed; nothing fetched with `npx` or at run time.
- Every task ends with `make test` and `make lint` green; a task touching `image/`, `derive/`, `config/` or `schema/` also runs `make smoke` green.
- Commits: conventional prefix (`feat:`, `fix:`, `docs:`, `test:`), no `Co-Authored-By` or other attribution lines; never push (there is no remote).
- Bridge port in the container: `8765`. Published by `bin/agentic` only as `127.0.0.1::8765`.
- Grants and `--allow` values: `push`, `open-pr`, `deploy:<target>` (`deploy:[A-Za-z0-9_.-]+`).
- Defaults: `AGENTIC_IDLE_TIMEOUT=900` (seconds), `AGENTIC_MAX_RUNNING=3`, task id `T-<yyyymmdd>-<4 hex>`, branch `agentic/<ID>-<slug>`.
- The spike logs used as fixtures are in `~/agentic-spike-2026-10-12/out/` (outside the repository, already token-free).

## Review Focus

Spec-implied conditions no task's main tests would exercise, most likely to bite first; each has a test in the named task:

1. An answer arriving while a resumed session is still loading (`starting`) is accepted, queued, and delivered exactly once after the load; a prompt then gets 409 (Task 6).
2. The same question answered twice (a double submit from a script or two terminals) gives 409 `Q2 is already answered` and no second inbox item (Task 6).
3. Prompts and answers with newlines, quotes, `$`, backticks and non-ASCII text reach the agent byte-identical from `agentic send` and the API; a body over 1 MiB gets 400 `body too large` (Tasks 8 and 12).
4. A task whose container stopped between lookup and call, or whose port changed after `docker start`, gives `agentic: task <ID> is not reachable (state: <state>)` instead of a curl error dump (Task 11).
5. A `/task` directory the bridge cannot write (a root-owned volume) stops the bridge at boot with a message naming the directory, before any agent is spawned (Task 9).

---

## File map

| File | Responsibility | Task |
|---|---|---|
| `image/task/lib/harness.sh` | per-harness facts for bash: hook events, payload fields, chooser and shell tools, block format, resume command | 2 |
| `image/task/gate.sh`, `image/task/ask-guard.sh` | PreToolUse guards | 2 |
| `image/task/hook.sh` | the one hook entry point | 3 |
| `image/task/task-prompt.md` | the task paragraph (read by `45-hooks` and the bridge) | 3 |
| `image/start.d/45-hooks.sh` | installs the hooks when `AGENTIC_GATE=1` | 3 |
| `image/entrypoint.sh` | `AGENTIC_GATE` default | 3 |
| `image/start.d/06-task-home.sh` | harness homes on `/task` | 10 |
| `image/bin/agentic-ask` | `POST /ask` | 10 |
| `bridge/src/types.ts` | shared types | 4 |
| `bridge/src/redact.ts` | token masking | 4 |
| `bridge/src/store.ts`, `bridge/src/transcript.ts` | files on `/task` | 5 |
| `bridge/src/task.ts` | the state machine | 6 |
| `bridge/src/map.ts` | ACP update → event mapping | 7 |
| `bridge/src/harness.ts`, `bridge/src/agent.ts` | agent process and ACP connection | 7 |
| `bridge/test/fake-agent.mjs` | scripted ACP agent for tests and smoke | 7 |
| `bridge/src/api.ts`, `bridge/src/server.ts` | routes, auth, HTTP and WS | 8 |
| `bridge/src/notify.ts`, `bridge/src/bridge.ts`, `bridge/src/config.ts`, `bridge/src/main.ts`, `bridge/src/follow.ts` | orchestration, env, CLI entry, follow client | 9 |
| `lib/host/task.sh` | host task helpers | 11, 12 |
| `bin/agentic` | task verbs | 11, 12 |
| `tests/image/smoke.sh` | task smoke | 13 |
| `docs/tasks.md`, `docs/architecture.md`, `docs/overlay.md`, `README.md`, `tests/e2e/acp-e2e.sh` | docs and the manual e2e | 14 |

---

### Task 1: Remove `repos:` from the config (port of 734a679)

**Files:**
- Modify: `README.md`, `bin/agentic`, `config/defaults.yaml`, `docs/configuration.md`, `image/lib/config.sh`, `schema/agentic.schema.json`, `templates/agentic.yaml.tmpl`, `tests/bats/cli-init.bats`, `tests/bats/config.bats`, `tests/bats/steps-base.bats`
- Delete: `image/start.d/15-repos.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: an `agentic.yaml` without `repos`; a config that still has `repos:` is accepted and the key ignored (as 734a679 tests).

- [ ] **Step 1: Read the archived commit**

Run: `git show 734a679`
Read what it removes and which tests it adds (`tests/bats/config.bats` gains the "repos is ignored" case).

- [ ] **Step 2: Cherry-pick it**

Run: `git cherry-pick 734a679`
If it conflicts (files changed on `main` since), resolve by keeping `main`'s content and applying only the commit's removals; then `git add` the files and `git cherry-pick --continue`. Keep the original message.

- [ ] **Step 3: Verify**

Run: `make test && make lint`
Expected: both green; `bats -f repos tests/bats/config.bats` shows the ignored-key test passing.

- [ ] **Step 4: Smoke (config and schema changed)**

Run: `make smoke`
Expected: `smoke OK`.

- [ ] **Step 5: Commit (only if Step 2 needed fixes after the cherry-pick)**

```bash
git add -A README.md bin config docs image schema templates tests
git commit -m "fix: repos removal: adapt to main"
```

---

### Task 2: Harness facts, action gate and ask-guard for both block formats

**Files:**
- Create (restored from the tag, then changed): `image/task/lib/harness.sh`, `image/task/gate.sh`, `image/task/ask-guard.sh`, `tests/bats/task-harness.bats`, `tests/bats/task-gate.bats`, `tests/fixtures/hooks/**`
- Modify: `tests/bats/helpers.bash` (link `task:image/task`), `Makefile` (`SHELL_SOURCES`)

**Interfaces:**
- Consumes: `image/lib/common.sh` (`say`, `claude_dir`, `copilot_dir`).
- Produces (bash, sourced by `hook.sh`, `45-hooks.sh`, `gate.sh`, `ask-guard.sh`):
  - `harness_hook_events HARNESS` → lines `<HarnessEventName> <internal>`; claude: `SessionStart sessionstart`, `UserPromptSubmit userpromptsubmit`, `PreToolUse pretooluse`, `PostToolUse posttooluse`, `Stop stop`, `SessionEnd sessionend`; copilot: `sessionStart sessionstart`, `userPromptSubmitted userpromptsubmit`, `preToolUse pretooluse`, `postToolUse posttooluse`, `agentStop stop`.
  - `copilot_hooks_file`, `copilot_instructions_file` → paths under `$(copilot_dir)`.
  - `payload_session P`, `payload_tool P`, `payload_command P` → field values from either harness's payload.
  - `is_shell_tool NAME`, `is_chooser_tool NAME` → exit status.
  - `harness_block HARNESS REASON` → prints the harness's refusal and returns the exit code the hook must use (`2` claude, `0` copilot).
  - `harness_resume_argv HARNESS SESSION` → `ARGV` array (`claude --dangerously-skip-permissions --resume S` / `copilot --allow-all --resume=S`), used by `takeover`.
  - `gate.sh`: payload on stdin; exit 0 allows; exit 2 blocks with the reason on stderr (unchanged contract; the hook converts it).

- [ ] **Step 1: Restore the archived files**

```bash
git checkout archive/sub-project-2-tmux -- image/task/lib/harness.sh image/task/gate.sh image/task/ask-guard.sh \
  tests/bats/task-harness.bats tests/bats/task-gate.bats tests/fixtures/hooks
```

- [ ] **Step 2: Link `image/task` in the test layout**

In `tests/bats/helpers.bash`, `make_agentic_dir`, add `task:image/task` to the `for pair in` list:

```bash
  for pair in lib:image/lib start.d:image/start.d tools:image/tools bin:image/bin derive:derive \
              config:config schema:schema skills:skills profile.d:image/profile.d task:image/task; do
```

Add to `helpers.bash`:

```bash
# install_cmd_stub NAME [EXIT]: a command that logs "args: ..." and its stdin to $BATS_TEST_TMPDIR/NAME.log.
install_cmd_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n{ echo "args: $*"; [ -t 0 ] || cat; echo; } >> "%s/%s.log"\nexit %s\n' \
    "$BATS_TEST_TMPDIR" "$1" "${2:-0}" > "$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# make_task_dir [ALLOWED...]: a /task stand-in at $AGENTIC_TASK_DIR with a state.json holding allowed_actions.
make_task_dir() {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"
  mkdir -p "$AGENTIC_TASK_DIR"
  jq -n '{version: 1, allowed_actions: $ARGS.positional}' --args "$@" > "$AGENTIC_TASK_DIR/state.json"
}
```

- [ ] **Step 3: Rewrite the gate test setup for the new layout (failing first)**

The archived `task-gate.bats` uses `make_task` and `$TASK_DIR` from the removed bash record. Replace its `setup` and `allow` with:

```bash
setup() {
  make_tmp_home
  make_agentic_dir
  make_task_dir
  G="$AGENTIC_DIR/task/gate.sh"
}

allow() { make_task_dir "$@"; }
```

Add these tests at the end of `task-gate.bats`:

```bash
@test "without a task record the gate reads AGENTIC_ALLOWED_ACTIONS (hub mode)" {
  rm "$AGENTIC_TASK_DIR/state.json"
  blocked "git push"
  AGENTIC_ALLOWED_ACTIONS="push, open-pr" allowed "git push"
}

@test "copilot payloads with toolArgs as an object or a JSON string are gated" {
  run bash "$G" <<<'{"toolName":"bash","toolArgs":{"command":"git push"}}'
  [ "$status" -eq 2 ]
  run bash "$G" <<<'{"toolName":"bash","toolArgs":"{\"command\":\"git push\"}"}'
  [ "$status" -eq 2 ]
}
```

In `tests/bats/task-harness.bats`, delete the tests for functions this plan drops (`harness_argv`, `harness_has_session`, `harness_interrupt_key`, `harness_exit_text`, `stop_summary`, `new_uuid`) and replace the event-list test and add the new ones:

```bash
@test "hook events: claude PascalCase, copilot camelCase as confirmed under --acp" {
  run harness_hook_events claude
  [ "$output" = $'SessionStart sessionstart\nUserPromptSubmit userpromptsubmit\nPreToolUse pretooluse\nPostToolUse posttooluse\nStop stop\nSessionEnd sessionend' ]
  run harness_hook_events copilot
  [ "$output" = $'sessionStart sessionstart\nuserPromptSubmitted userpromptsubmit\npreToolUse pretooluse\npostToolUse posttooluse\nagentStop stop' ]
}

@test "claude refusals go to stderr with exit code 2" {
  run --separate-stderr bash -c 'source "$1"; source "$2"; harness_block claude "no push"; echo "rc=$?"' _ \
    "$AGENTIC_DIR/lib/common.sh" "$AGENTIC_DIR/task/lib/harness.sh"
  [ "$output" = "rc=2" ]
  [ "$stderr" = "no push" ]
}

@test "copilot refusals are a JSON deny decision on stdout with exit code 0" {
  run --separate-stderr bash -c 'source "$1"; source "$2"; harness_block copilot "no \"push\""; echo "rc=$?"' _ \
    "$AGENTIC_DIR/lib/common.sh" "$AGENTIC_DIR/task/lib/harness.sh"
  [ "$(head -1 <<<"$output" | jq -r .permissionDecision)" = deny ]
  [ "$(head -1 <<<"$output" | jq -r .permissionDecisionReason)" = 'no "push"' ]
  [ "$(tail -1 <<<"$output")" = "rc=0" ]
}

@test "takeover resumes the session interactively" {
  harness_resume_argv claude 1234; [ "${ARGV[*]}" = "claude --dangerously-skip-permissions --resume 1234" ]
  harness_resume_argv copilot 1234; [ "${ARGV[*]}" = "copilot --allow-all --resume=1234" ]
}
```

(`task-harness.bats` sources the libraries in its `setup`; keep the archived `setup`, minus `make_task`.)

- [ ] **Step 4: Run the tests to see them fail**

Run: `bats tests/bats/task-harness.bats tests/bats/task-gate.bats`
Expected: FAIL on the event list, the two `harness_block` tests and `harness_resume_argv` (not defined).

- [ ] **Step 5: Change `harness.sh`**

Delete `harness_argv`, `harness_has_session`, `harness_interrupt_key`, `harness_exit_text`, `stop_summary`, `new_uuid`, `payload_message`. Replace `harness_hook_events` and `harness_block`, add `harness_resume_argv`:

```bash
# harness_hook_events HARNESS: "<HarnessEventName> <internal name>" per line (spec §13: confirmed under ACP).
harness_hook_events() {
  case "$1" in
    claude) printf '%s\n' 'SessionStart sessionstart' 'UserPromptSubmit userpromptsubmit' \
              'PreToolUse pretooluse' 'PostToolUse posttooluse' 'Stop stop' 'SessionEnd sessionend' ;;
    copilot) printf '%s\n' 'sessionStart sessionstart' 'userPromptSubmitted userpromptsubmit' \
              'preToolUse pretooluse' 'postToolUse posttooluse' 'agentStop stop' ;;
  esac
}

# harness_block HARNESS REASON: prints the refusal in the harness's format; returns the hook's exit code.
# Copilot drops a reason given with exit 2, so it gets its JSON deny decision on stdout and exit 0.
harness_block() {
  case "$1" in
    copilot) jq -cn --arg r "$2" '{permissionDecision: "deny", permissionDecisionReason: $r}'; return 0 ;;
    *) printf '%s\n' "$2" >&2; return 2 ;;
  esac
}

# harness_resume_argv HARNESS SESSION: the interactive command line that resumes SESSION, in ARGV.
harness_resume_argv() {
  case "$1" in
    claude) ARGV=(claude --dangerously-skip-permissions --resume "$2") ;;
    copilot) ARGV=(copilot --allow-all "--resume=$2") ;;
    *) say "unknown harness $1"; return 1 ;;
  esac
}
```

Update the file's header comment to: `# Per-harness facts for the hooks and the gate. Source after lib/common.sh.`

In `gate.sh` change the state path line to `state="${AGENTIC_TASK_DIR:-/task}/state.json"`.

- [ ] **Step 6: Add the task sources to shellcheck**

In `Makefile`, extend `SHELL_SOURCES`:

```make
SHELL_SOURCES = $(wildcard bin/agentic lib/host/*.sh image/*.sh image/lib/*.sh image/start.d/*.sh \
  image/tools/*.sh image/bin/* image/profile.d/*.sh derive/*.sh tools/*.sh tests/image/*.sh \
  image/task/*.sh image/task/lib/*.sh tests/e2e/*.sh)
```

- [ ] **Step 7: Run tests and lint**

Run: `bats tests/bats/task-harness.bats tests/bats/task-gate.bats && make test && make lint`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add image/task tests/bats/task-harness.bats tests/bats/task-gate.bats tests/bats/helpers.bash tests/fixtures/hooks Makefile
git commit -m "feat: action gate, ask-guard and harness facts, with each harness's block format"
```

(The image does not copy `image/task` yet, so no smoke run is needed until Task 3.)

---

### Task 3: Hooks behind `AGENTIC_GATE`

**Files:**
- Create: `image/task/hook.sh`, `image/task/task-prompt.md`, `image/start.d/45-hooks.sh`, `image/hooks.d/.keep`, `tests/bats/task-hook.bats`, `tests/bats/task-hooks-step.bats`, `tests/bats/entrypoint-gate.bats`
- Modify: `image/entrypoint.sh`, `image/Dockerfile`

**Interfaces:**
- Consumes: Task 2's `harness.sh` and guards.
- Produces:
  - Installed hook command: `bash /opt/agentic/task/hook.sh <claude|copilot> <event>`.
  - `hook.sh` reads env `AGENTIC_BRIDGE_URL`, `AGENTIC_AGENT_TOKEN` (optional) and POSTs `{"rule","command"}` to `$AGENTIC_BRIDGE_URL/gate` on a block.
  - `/opt/agentic/task/task-prompt.md`: the task paragraph, read by the bridge in Task 9.
  - `AGENTIC_GATE` exported by the entrypoint before the start steps.

- [ ] **Step 1: Write the step tests (failing)**

`tests/bats/task-hooks-step.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  S="$REPO_ROOT/image/start.d/45-hooks.sh"
  export AGENTIC_GATE=1
}

@test "with the gate off the step does nothing" {
  AGENTIC_GATE=0 run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json" ]
}

@test "claude gets the managed hooks with the harness named, other settings and hooks stay" {
  mkdir -p "$HOME/.claude"
  echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own.sh"}]}]}}' > "$HOME/.claude/settings.json"
  run bash "$S"
  [ "$status" -eq 0 ]
  f="$HOME/.claude/settings.json"
  [ "$(jq -r .model "$f")" = opus ]
  [ "$(jq -r .skipDangerousModePermissionPrompt "$f")" = true ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" = "bash $AGENTIC_DIR/task/hook.sh claude pretooluse" ]
  [ "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$f")" = "my-own.sh,bash $AGENTIC_DIR/task/hook.sh claude stop" ]
  [ "$(jq -r '.hooks | keys | join(",")' "$f")" = PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit ]
}

@test "running twice installs each hook once" {
  bash "$S"; bash "$S"
  [ "$(jq '[.hooks[][].hooks[]] | length' "$HOME/.claude/settings.json")" -eq 6 ]
}

@test "the step follows CLAUDE_CONFIG_DIR and COPILOT_HOME" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cc" COPILOT_HOME="$BATS_TEST_TMPDIR/cp" bash "$S"
  [ -f "$BATS_TEST_TMPDIR/cc/settings.json" ]
  [ -f "$BATS_TEST_TMPDIR/cp/hooks/agentic.json" ]
}

@test "copilot gets camelCase hooks and the task paragraph as a managed block" {
  mkdir -p "$HOME/.copilot"
  printf 'My own rule.\n' > "$HOME/.copilot/copilot-instructions.md"
  bash "$S"; bash "$S"
  f="$HOME/.copilot/hooks/agentic.json"
  [ "$(jq -r .version "$f")" = 1 ]
  [ "$(jq -r '.hooks.preToolUse[0].bash' "$f")" = "bash $AGENTIC_DIR/task/hook.sh copilot pretooluse" ]
  [ "$(jq -r '.hooks | keys | join(",")' "$f")" = agentStop,postToolUse,preToolUse,sessionStart,userPromptSubmitted ]
  i="$HOME/.copilot/copilot-instructions.md"
  grep -q 'My own rule.' "$i"
  [ "$(grep -c 'agentic-ask' "$i")" -ge 1 ]
  [ "$(grep -c '<!-- agentic:task -->' "$i")" -eq 1 ]
}

@test "check mode reports missing hooks and passes once installed" {
  run bash "$S" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"task hooks are not installed"* ]]
  bash "$S"
  run bash "$S" --check
  [ "$status" -eq 0 ]
}

@test "an unreadable settings.json stops the start: a task must not run unguarded" {
  mkdir -p "$HOME/.claude"; echo '{' > "$HOME/.claude/settings.json"
  run bash "$S"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}
```

`tests/bats/task-hook.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  make_task_dir
  H="$AGENTIC_DIR/task/hook.sh"
  F="$REPO_ROOT/tests/fixtures/hooks"
}

@test "claude: a blocked push exits 2 with the reason on stderr" {
  run --separate-stderr bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"agentic gate: git push is not in allowed_actions"* ]]
}

@test "copilot: a blocked push is a deny decision on stdout with exit 0" {
  run --separate-stderr bash "$H" copilot pretooluse < "$F/copilot/pretooluse-bash.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .permissionDecision <<<"$output")" = deny ]
  [[ "$(jq -r .permissionDecisionReason <<<"$output")" == *"git push is not in allowed_actions"* ]]
}

@test "a grant in state.json lets the push through" {
  make_task_dir push
  run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a chooser is blocked by the ask-guard" {
  run --separate-stderr bash "$H" claude pretooluse < "$F/claude/pretooluse-ask.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Use agentic-ask"* ]]
}

@test "a guard that fails another way blocks: a task must not run unguarded" {
  mkdir -p "$BATS_TEST_TMPDIR/opt2"; cp -rL "$AGENTIC_DIR"/. "$BATS_TEST_TMPDIR/opt2/"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/opt2/task/gate.sh"
  AGENTIC_DIR="$BATS_TEST_TMPDIR/opt2" run --separate-stderr bash "$BATS_TEST_TMPDIR/opt2/task/hook.sh" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"agentic gate failed (rc 7)"* ]]
}

@test "a block is reported to the bridge with the agent token" {
  install_cmd_stub curl
  AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 AGENTIC_AGENT_TOKEN=agent-tok run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  grep -q -- 'http://127.0.0.1:8765/gate' "$BATS_TEST_TMPDIR/curl.log"
  grep -q -- 'Authorization: Bearer agent-tok' "$BATS_TEST_TMPDIR/curl.log"
  grep -q '"rule":"gate"' "$BATS_TEST_TMPDIR/curl.log"
  grep -q '"command":"git push origin HEAD"' "$BATS_TEST_TMPDIR/curl.log"
}

@test "without a bridge nothing is reported and the block still holds" {
  install_cmd_stub curl
  run bash "$H" claude pretooluse < "$F/claude/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "a hooks.d pretooluse script can block, others only run" {
  mkdir -p "$BATS_TEST_TMPDIR/cfg/hooks.d/pretooluse" "$BATS_TEST_TMPDIR/cfg/hooks.d/stop"
  printf '#!/usr/bin/env bash\necho "no deploy wrapper" >&2\nexit 2\n' > "$BATS_TEST_TMPDIR/cfg/hooks.d/pretooluse/10-x.sh"
  printf '#!/usr/bin/env bash\ncat > "%s/stop-ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/cfg/hooks.d/stop/10-y.sh"
  jq -c '.tool_input.command = "ls"' "$F/claude/pretooluse-bash.json" > "$BATS_TEST_TMPDIR/ls.json"
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run --separate-stderr bash "$H" claude pretooluse < "$BATS_TEST_TMPDIR/ls.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no deploy wrapper"* ]]
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run bash "$H" claude stop < "$F/claude/stop.json"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/stop-ran" ]
}

@test "other events never fail, even when an extension fails" {
  mkdir -p "$BATS_TEST_TMPDIR/cfg/hooks.d/stop"
  printf '#!/usr/bin/env bash\nexit 9\n' > "$BATS_TEST_TMPDIR/cfg/hooks.d/stop/10-bad.sh"
  AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/cfg" run bash "$H" claude stop < "$F/claude/stop.json"
  [ "$status" -eq 0 ]
}
```

`tests/bats/entrypoint-gate.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps"
  mkdir -p "$AGENTIC_STEPS_DIR"
  printf '#!/usr/bin/env bash\necho "gate=${AGENTIC_GATE:-unset}" > "%s/gate"\n' "$BATS_TEST_TMPDIR" > "$AGENTIC_STEPS_DIR/01-show.sh"
  install_cmd_stub agentic-bridge
}

gate() { cat "$BATS_TEST_TMPDIR/gate"; }

@test "the gate is on by default for the bridge" {
  bash "$REPO_ROOT/image/entrypoint.sh" agentic-bridge
  [ "$(gate)" = gate=1 ]
}

@test "the gate is on by default in worker mode" {
  mkdir -p "$AGENTIC_DIR/worker.d"; printf 'exit 0\n' > "$AGENTIC_DIR/worker.d/w.sh"
  AGENTIC_WORKER_MODE=w bash "$REPO_ROOT/image/entrypoint.sh"
  [ "$(gate)" = gate=1 ]
}

@test "the gate is off by default for anything else, and settable both ways" {
  bash "$REPO_ROOT/image/entrypoint.sh" true
  [ "$(gate)" = gate=0 ]
  AGENTIC_GATE=1 bash "$REPO_ROOT/image/entrypoint.sh" true
  [ "$(gate)" = gate=1 ]
  AGENTIC_GATE=0 bash "$REPO_ROOT/image/entrypoint.sh" agentic-bridge
  [ "$(gate)" = gate=0 ]
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `bats tests/bats/task-hooks-step.bats tests/bats/task-hook.bats tests/bats/entrypoint-gate.bats`
Expected: FAIL (`45-hooks.sh` and `hook.sh` missing; the entrypoint does not set `AGENTIC_GATE`).

- [ ] **Step 3: Write `image/task/task-prompt.md`**

```markdown
You run unattended in a container; nobody watches this session. When you need a human decision,
run `agentic-ask "<question>" [--option <choice>]... [--recommend <choice>]`, continue with any work
that does not depend on the answer, and end your turn when nothing else can move. Answers arrive
as messages `Answer to Q<n>: ...`. Do not use interactive choosers; they are blocked. Outward
actions (push, pull requests, deploys) that are not allowed for this task are blocked; ask if you
need one.
```

- [ ] **Step 4: Write `image/task/hook.sh`**

```bash
#!/usr/bin/env bash
# hook.sh HARNESS EVENT: the one hook entry point for both harnesses; payload on stdin. On PreToolUse
# the gate, the ask-guard and hooks.d/pretooluse scripts may refuse the call; nothing else fails a turn.
set -uo pipefail
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
source "$AGENTIC_DIR/lib/common.sh"
source "$AGENTIC_DIR/task/lib/harness.sh"

harness="${1:-claude}"; ev="${2:-}"
payload="$(cat 2>/dev/null || true)"

# run_extensions EVENT: hooks.d scripts of the image, then of the project, payload on stdin. On
# pretooluse a script exiting 2 refuses the call: its stderr is printed and 2 returned.
run_extensions() {
  local d s out rc
  for d in "$AGENTIC_DIR/hooks.d/$1" "${AGENTIC_CONFIG_MOUNT:-/agentic-config}/hooks.d/$1"; do
    for s in "$d"/*.sh; do
      [ -f "$s" ] || continue
      out="$(printf '%s' "$payload" | timeout 15 bash "$s" 2>&1 >/dev/null)"
      rc=$?
      if [ "$rc" = 2 ] && [ "$1" = pretooluse ]; then printf '%s\n' "${out:-refused by $(basename "$s")}"; return 2; fi
    done
  done
  return 0
}

# report RULE: tells the bridge about a refusal, best effort.
report() {
  [ -n "${AGENTIC_BRIDGE_URL:-}" ] && [ -n "${AGENTIC_AGENT_TOKEN:-}" ] || return 0
  jq -cn --arg r "$1" --arg c "$(payload_command "$payload")" '{rule: $r, command: $c}' \
    | curl -fsS -m 1 -X POST -H "Authorization: Bearer $AGENTIC_AGENT_TOKEN" -H 'Content-Type: application/json' \
        --data-binary @- "$AGENTIC_BRIDGE_URL/gate" >/dev/null 2>&1 || true
}

# refuse RULE REASON: reports, then refuses the call in the harness's format.
refuse() { report "$1"; harness_block "$harness" "$2"; exit $?; }

if [ "$ev" != pretooluse ]; then run_extensions "$ev" >/dev/null 2>&1; exit 0; fi

for g in gate ask-guard; do
  reason="$(printf '%s' "$payload" | bash "$AGENTIC_DIR/task/$g.sh" 2>&1 >/dev/null)"
  grc=$?
  [ "$grc" -ne 2 ] || refuse "$g" "$reason"
  [ "$grc" -eq 0 ] || refuse gate "agentic gate failed (rc $grc); refusing to run unguarded"
done
reason="$(run_extensions pretooluse)"
[ $? -ne 2 ] || refuse hooks.d "$reason"
exit 0
```

- [ ] **Step 5: Write `image/start.d/45-hooks.sh`**

```bash
#!/usr/bin/env bash
# Installs the hooks for both harnesses when the gate is on (AGENTIC_GATE=1): a managed block in
# Claude's settings.json, Copilot's own hook file, and the task paragraph for Copilot. A task must
# not run unguarded, so an unreadable settings.json is fatal.
set -uo pipefail
[ "${AGENTIC_GATE:-0}" = 1 ] || exit 0
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/task/lib/harness.sh"
check=0; [ "${1:-}" = --check ] && check=1
hook="$AGENTIC_DIR/task/hook.sh"
mark='<!-- agentic:task -->'
rc=0

claude_block() {
  harness_hook_events claude | jq -Rn --arg h "$hook" '[inputs | split(" ")
    | {key: .[0], value: [{hooks: [{type: "command", command: "bash \($h) claude \(.[1])", timeout: 30}]}]}] | from_entries'
}

f="$(claude_dir)/settings.json"
cur='{}'
if [ -s "$f" ]; then cur="$(cat "$f")"; fi
if ! new="$(jq --argjson ours "$(claude_block)" --arg h "$hook" '
      .skipDangerousModePermissionPrompt = true
      | .hooks = ((.hooks // {})
          | map_values(map(select(any(.hooks[]?; (.command // "") | contains($h)) | not)))
          | with_entries(select(.value | length > 0)))
      | .hooks = reduce ($ours | to_entries[]) as $e (.hooks; .[$e.key] = ((.[$e.key] // []) + $e.value))' \
      <<<"$cur" 2>/dev/null)"; then
  say "$f is not valid JSON; task hooks not installed"
  exit 1
fi

copilot_new="$(harness_hook_events copilot | jq -Rn --arg h "$hook" '{version: 1, hooks: ([inputs | split(" ")
  | {key: .[0], value: [{type: "command", bash: "bash \($h) copilot \(.[1])", timeoutSec: 30}]}] | from_entries)}')"
cf="$(copilot_hooks_file)"
inf="$(copilot_instructions_file)"
# The instructions keep the user's text; the task paragraph sits between two markers.
own="$(if [ -f "$inf" ]; then sed "/^$mark\$/,/^$mark\$/d" "$inf"; fi)"
inf_new="$(printf '%s\n%s\n%s\n%s\n' "$own" "$mark" "$(cat "$AGENTIC_DIR/task/task-prompt.md")" "$mark" | sed '/./,$!d')"

if [ "$check" = 1 ]; then
  [ "$(jq -S . <<<"$new")" = "$(jq -S . <<<"$cur")" ] || { say "task hooks are not installed for claude"; rc=2; }
  [ "$(cat "$cf" 2>/dev/null)" = "$copilot_new" ] || { say "task hooks are not installed for copilot"; rc=2; }
  exit "$rc"
fi
write_if_changed "$f" "$new"
write_if_changed "$cf" "$copilot_new"
write_if_changed "$inf" "$inf_new"
exit 0
```

(`write_if_changed` from `image/lib/common.sh` creates parent directories and writes with umask 077.)

- [ ] **Step 6: Set the gate default in `image/entrypoint.sh`**

After the `export AGENTIC_DIR AGENTIC_STATE` line add:

```bash
# The gate is on by default where nobody watches: the task bridge and worker mode (spec D17).
if [ -z "${AGENTIC_GATE:-}" ]; then
  if [ "${1:-}" = agentic-bridge ] || [ -n "${AGENTIC_WORKER_MODE:-}" ]; then AGENTIC_GATE=1; else AGENTIC_GATE=0; fi
fi
export AGENTIC_GATE
```

- [ ] **Step 7: Copy the task layer into the image**

In `image/Dockerfile`, in "The agentic layer" block after `COPY image/bin /opt/agentic/bin`, add:

```dockerfile
COPY image/task /opt/agentic/task
COPY image/hooks.d /opt/agentic/hooks.d
```

Create `image/hooks.d/.keep` (empty).

- [ ] **Step 8: Run the tests**

Run: `bats tests/bats/task-hooks-step.bats tests/bats/task-hook.bats tests/bats/entrypoint-gate.bats && make test && make lint`
Expected: PASS.

- [ ] **Step 9: Smoke**

Add to `tests/image/smoke.sh`, before `step "worker mode ..."`:

```bash
step "with the gate on, git push is refused by the hook"
out="$(docker run --rm -e AGENTIC_GATE=1 "$IMG" bash -lc \
  'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}" | bash /opt/agentic/task/hook.sh claude pretooluse; echo "rc=$?"' 2>&1)"
[[ "$out" == *"git push is not in allowed_actions"* && "$out" == *"rc=2"* ]] || fail "gate in the image: got '$out'"
```

Run: `make smoke`
Expected: `smoke OK`.

- [ ] **Step 10: Commit**

```bash
git add image/task image/start.d/45-hooks.sh image/hooks.d image/entrypoint.sh image/Dockerfile \
  tests/bats/task-hook.bats tests/bats/task-hooks-step.bats tests/bats/entrypoint-gate.bats tests/image/smoke.sh
git commit -m "feat: hooks for both harnesses behind AGENTIC_GATE; refusals reach the agent and the bridge"
```

---

### Task 4: Bridge package, toolchain and redaction

**Files:**
- Create: `bridge/package.json`, `bridge/package-lock.json` (by npm), `bridge/tsconfig.json`, `bridge/tsconfig.build.json`, `bridge/vitest.config.ts`, `bridge/eslint.config.js`, `bridge/src/types.ts`, `bridge/src/redact.ts`, `bridge/test/redact.test.ts`
- Modify: `Makefile`, `.gitignore`, `CLAUDE.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `types.ts`: `AgentName`, `State`, `EventType`, `PermissionOption`, `Question`, `InboxItem`, `TaskRecord`, `TaskEvent` (code below; every later task imports these names).
  - `redact.ts`: `makeRedactor(secrets: string[]): (s: string) => string`; `redactDeep<T>(value: T, redact: (s: string) => string): T`.
  - `make test` / `make lint` run the bridge's vitest and tsc + eslint.

- [ ] **Step 1: Create the package**

`bridge/package.json`:

```json
{
  "name": "agentic-bridge",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "bin": { "agentic-bridge": "dist/main.js" },
  "scripts": {
    "build": "tsc -p tsconfig.build.json",
    "test": "vitest run",
    "lint": "tsc -p tsconfig.json --noEmit && eslint ."
  }
}
```

Run (from `bridge/`, on Node 22):

```bash
npm install --save-exact @agentclientprotocol/sdk@1.8.0 @agentclientprotocol/claude-agent-acp@0.89.1 ws@8
npm install --save-exact --save-dev typescript@5 vitest@3 eslint@9 @eslint/js@9 typescript-eslint@8 @types/node@22 @types/ws@8
```

Expected: `package.json` lists exact versions; `package-lock.json` exists.

`bridge/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "types": ["node"],
    "outDir": "dist",
    "rootDir": "."
  },
  "include": ["src", "test", "vitest.config.ts"]
}
```

`bridge/tsconfig.build.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": { "rootDir": "src", "outDir": "dist" },
  "include": ["src"]
}
```

`bridge/vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["test/**/*.test.ts"], testTimeout: 20000 },
});
```

`bridge/eslint.config.js`:

```js
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/", "node_modules/", "test/fake-agent.mjs"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
);
```

Append to `.gitignore` (create it if missing):

```
bridge/node_modules/
bridge/dist/
```

- [ ] **Step 2: Wire the bridge into make**

In `Makefile`, replace the `test:` and `lint:` rules with:

```make
BRIDGE_DEPS = bridge/node_modules/.package-lock.json

$(BRIDGE_DEPS): bridge/package-lock.json
	cd bridge && npm ci

test: $(BRIDGE_DEPS)
	bats -r tests/bats
	cd bridge && npm test

lint: $(BRIDGE_DEPS)
	shellcheck -x $(SHELL_SOURCES)
	jq empty schema/agentic.schema.json
	tools/gen-config-docs.sh --check
	tools/leak-check.sh
	cd bridge && npm run lint
```

- [ ] **Step 3: Write `bridge/src/types.ts`**

```ts
// Shared types of the bridge (spec §5.2, §8.3).
export type AgentName = "claude" | "copilot";
export type State =
  | "starting" | "running" | "waiting" | "idle" | "suspended" | "stopped" | "failed" | "interrupted";
export type EventType = "state" | "message" | "tool" | "plan" | "question" | "answer" | "gate" | "error";

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: string;
}

export interface Question {
  id: string;
  source: "permission" | "ask";
  text: string;
  options: string[];
  recommendation: string | null;
  asked: string;
  status: "open" | "answered";
  answer?: string;
  grant?: string[];
  answered?: string;
  permission?: { options: PermissionOption[] };
}

export interface InboxItem {
  kind: "prompt" | "answer";
  text: string;
  question?: string;
}

export interface TaskRecord {
  version: 1;
  task: string;
  project: string;
  agent: AgentName;
  model: string | null;
  state: State;
  reason: string;
  session: string | null;
  branch: string | null;
  created: string;
  updated: string;
  seq: number;
  allowed_actions: string[];
  inbox: InboxItem[];
  summary: string;
  stopped_by_user: boolean;
}

export interface TaskEvent {
  seq: number;
  ts: string;
  task: string;
  session: string | null;
  agent: AgentName;
  type: EventType;
  data: Record<string, unknown>;
}
```

- [ ] **Step 4: Write the redaction test (failing)**

`bridge/test/redact.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { makeRedactor, redactDeep } from "../src/redact.js";

describe("redact", () => {
  const r = makeRedactor(["task-token-0123456789", "short"]);

  it("masks known token patterns", () => {
    expect(r("key sk-ant-oat01-AbCdEf0123456789xyz end")).toBe("key [redacted] end");
    expect(r("gho_0123456789abcdefABCDEF and ghp_0123456789abcdefABCDEF")).toBe("[redacted] and [redacted]");
    expect(r("github_pat_11ABCDEFG0123456789_abcdefghijklmnop")).toBe("[redacted]");
    expect(r("Authorization: Bearer abc.def-ghi_jkl")).toBe("Authorization: Bearer [redacted]");
    expect(r("AKIAABCDEFGHIJKLMNOP")).toBe("[redacted]");
  });

  it("masks the task's own tokens but ignores secrets shorter than 8 characters", () => {
    expect(r("x task-token-0123456789 y")).toBe("x [redacted] y");
    expect(r("a short word")).toBe("a short word");
  });

  it("leaves ordinary text alone", () => {
    expect(r("git push origin HEAD; sk-ant is a prefix")).toBe("git push origin HEAD; sk-ant is a prefix");
  });

  it("walks objects and arrays", () => {
    const v = redactDeep({ a: ["sk-ant-api03-0123456789abcdef"], b: { c: 1, d: "ok" } }, r);
    expect(v).toEqual({ a: ["[redacted]"], b: { c: 1, d: "ok" } });
  });
});
```

- [ ] **Step 5: Run it to see it fail**

Run: `cd bridge && npx vitest run test/redact.test.ts`
Expected: FAIL (cannot resolve `../src/redact.js`). (`npx` here runs the locally installed vitest; nothing is fetched.)

- [ ] **Step 6: Write `bridge/src/redact.ts`**

```ts
// Token masking for everything the bridge writes or sends (spec §11).
const PATTERNS: Array<[RegExp, string]> = [
  [/sk-ant-[A-Za-z0-9_-]{8,}/g, "[redacted]"],
  [/\bgh[opsu]_[A-Za-z0-9]{16,}/g, "[redacted]"],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "[redacted]"],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/g, "Bearer [redacted]"],
  [/\bAKIA[0-9A-Z]{16}\b/g, "[redacted]"],
];

export function makeRedactor(secrets: string[]): (s: string) => string {
  const own = secrets.filter((s) => s.length >= 8);
  return (s: string) => {
    let out = s;
    for (const t of own) out = out.split(t).join("[redacted]");
    for (const [re, rep] of PATTERNS) out = out.replace(re, rep);
    return out;
  };
}

export function redactDeep<T>(value: T, redact: (s: string) => string): T {
  if (typeof value === "string") return redact(value) as T;
  if (Array.isArray(value)) return value.map((v) => redactDeep(v, redact)) as T;
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, redactDeep(v, redact)]),
    ) as T;
  }
  return value;
}
```

- [ ] **Step 7: Run tests and lint**

Run: `make test && make lint`
Expected: PASS (bats unchanged; vitest 4 tests; tsc and eslint clean).

- [ ] **Step 8: Add the TypeScript rules to `CLAUDE.md`**

After the bash style rule in `## Rules`, add:

```markdown
- TypeScript (`bridge/`): strict tsc, eslint clean, a vitest test for every behaviour, written
  first; dependencies pinned exactly with the lockfile committed; nothing fetched with `npx` or at
  run time.
```

In `## Commands`, change the `make test` line to `make test     # bats and the bridge's vitest (needs bats, jq, yq v4, Node 22)` and the `make lint` line to `make lint     # shellcheck, schema, generated docs, leak check, tsc and eslint`.

- [ ] **Step 9: Commit**

```bash
git add bridge .gitignore Makefile CLAUDE.md
git commit -m "feat: bridge package with its toolchain, shared types and token redaction"
```

---

### Task 5: Task files: record, events, questions, transcript

**Files:**
- Create: `bridge/src/store.ts`, `bridge/src/transcript.ts`, `bridge/test/store.test.ts`, `bridge/test/transcript.test.ts`

**Interfaces:**
- Consumes: `types.ts`.
- Produces:
  - `class StoreError extends Error`.
  - `class Store(dir: string, redact?: (s: string) => string)` with `checkWritable(): void` (throws `StoreError` naming the directory), `hasRecord(): boolean`, `readRecord(): TaskRecord` (throws `StoreError` naming the file), `writeRecord(r: TaskRecord): void` (sets `r.seq` to the last event seq, atomic, redacted), `appendEvent(e: Omit<TaskEvent, "seq">): TaskEvent` (assigns the next seq, returns the redacted event as written), `readEvents(since: number, limit?: number): TaskEvent[]`, `appendQuestion(q: Question): void`, `readQuestions(): Question[]` (last line per id wins), `appendTranscript(md: string): void`, `readPrompt(): string | null`.
  - `renderEvent(e: TaskEvent): string | null` in `transcript.ts`.

- [ ] **Step 1: Write the store tests (failing)**

`bridge/test/store.test.ts`:

```ts
import { mkdtempSync, writeFileSync, readFileSync, appendFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { Store, StoreError } from "../src/store.js";
import { makeRedactor } from "../src/redact.js";
import type { TaskRecord, Question } from "../src/types.js";

export function record(over: Partial<TaskRecord> = {}): TaskRecord {
  return {
    version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "starting", reason: "",
    session: null, branch: null, created: "t0", updated: "t0", seq: 0, allowed_actions: [], inbox: [],
    summary: "", stopped_by_user: false, ...over,
  };
}
const ev = (type: "state" | "message" = "state") =>
  ({ ts: "t", task: "T-1", session: null, agent: "claude" as const, type, data: { state: "running" } });

describe("Store", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "store-")); });

  it("has no record until one is written; written records read back with the last seq", () => {
    const s = new Store(dir);
    expect(s.hasRecord()).toBe(false);
    s.appendEvent(ev()); s.appendEvent(ev());
    const r = record();
    s.writeRecord(r);
    expect(s.hasRecord()).toBe(true);
    expect(s.readRecord().seq).toBe(2);
    expect(readFileSync(join(dir, "state.json"), "utf8").endsWith("\n")).toBe(true);
  });

  it("numbers events from 1 and continues after a restart", () => {
    const a = new Store(dir);
    expect(a.appendEvent(ev()).seq).toBe(1);
    expect(a.appendEvent(ev()).seq).toBe(2);
    const b = new Store(dir);
    expect(b.appendEvent(ev()).seq).toBe(3);
    expect(b.readEvents(1).map((e) => e.seq)).toEqual([2, 3]);
    expect(b.readEvents(0, 1).map((e) => e.seq)).toEqual([1]);
  });

  it("skips a torn or corrupt line in events and questions", () => {
    const s = new Store(dir);
    s.appendEvent(ev());
    appendFileSync(join(dir, "events.jsonl"), '{"seq":2,"ts":\n');
    const t = new Store(dir);
    expect(t.readEvents(0).map((e) => e.seq)).toEqual([1]);
    expect(t.appendEvent(ev()).seq).toBe(2);
  });

  it("refuses a corrupt state.json with the file name and never resets it", () => {
    writeFileSync(join(dir, "state.json"), "{");
    const s = new Store(dir);
    expect(() => s.readRecord()).toThrow(StoreError);
    expect(() => s.readRecord()).toThrow(join(dir, "state.json"));
    expect(readFileSync(join(dir, "state.json"), "utf8")).toBe("{");
  });

  it("keeps the last line per question id", () => {
    const s = new Store(dir);
    const q: Question = { id: "Q1", source: "ask", text: "Which DB?", options: [], recommendation: null, asked: "t", status: "open" };
    s.appendQuestion(q);
    s.appendQuestion({ ...q, status: "answered", answer: "postgres" });
    s.appendQuestion({ ...q, id: "Q2" });
    expect(s.readQuestions().map((x) => [x.id, x.status])).toEqual([["Q1", "answered"], ["Q2", "open"]]);
  });

  it("redacts what it writes", () => {
    const s = new Store(dir, makeRedactor(["task-token-0123456789"]));
    const e = s.appendEvent({ ...ev("message"), data: { text: "use task-token-0123456789" } });
    expect(e.data.text).toBe("use [redacted]");
    s.writeRecord(record({ inbox: [{ kind: "prompt", text: "sk-ant-api03-0123456789abcdef" }] }));
    expect(readFileSync(join(dir, "state.json"), "utf8")).not.toContain("sk-ant-api03");
    s.appendTranscript("token task-token-0123456789\n");
    expect(readFileSync(join(dir, "transcript.md"), "utf8")).toBe("token [redacted]\n");
  });

  it("reads the first prompt when there is one", () => {
    const s = new Store(dir);
    expect(s.readPrompt()).toBeNull();
    writeFileSync(join(dir, "prompt.md"), "Fix the login bug\n");
    expect(s.readPrompt()).toBe("Fix the login bug\n");
  });

  it("names the directory when it cannot write there", () => {
    chmodSync(dir, 0o500);
    const s = new Store(dir);
    expect(() => s.checkWritable()).toThrow(dir);
    chmodSync(dir, 0o700);
  });
});
```

(When tests run as root the last case cannot fail; it is skipped by `it.skipIf(process.getuid?.() === 0)` — use that instead of `it` for this one case.)

- [ ] **Step 2: Write the transcript tests (failing)**

`bridge/test/transcript.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { renderEvent } from "../src/transcript.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent =>
  ({ seq: 1, ts: "t", task: "T-1", session: null, agent: "claude", type, data });

describe("renderEvent", () => {
  it("quotes user text and prints the final agent message only", () => {
    expect(renderEvent(e("message", { role: "user", text: "Fix it\nplease", final: true }))).toBe("\n> Fix it\n> please\n");
    expect(renderEvent(e("message", { role: "agent", text: "Done.", final: true }))).toBe("\nDone.\n");
    expect(renderEvent(e("message", { role: "agent", text: "Do", final: false }))).toBeNull();
  });

  it("prints finished tool calls with the last 10 lines of output", () => {
    const tail = Array.from({ length: 15 }, (_, i) => `line ${i + 1}`).join("\n");
    const out = renderEvent(e("tool", { id: "t", title: "npm test", kind: "execute", status: "failed", output_tail: tail }));
    expect(out).toBe("\n▸ npm test — failed\n```\n" + Array.from({ length: 10 }, (_, i) => `line ${i + 6}`).join("\n") + "\n```\n");
    expect(renderEvent(e("tool", { id: "t", title: "ls", kind: "execute", status: "done", output_tail: "" }))).toBe("\n▸ ls — done\n");
    expect(renderEvent(e("tool", { id: "t", title: "ls", kind: "execute", status: "running", output_tail: null }))).toBeNull();
  });

  it("calls out questions, answers, gate refusals, states and errors", () => {
    expect(renderEvent(e("question", { id: "Q1", source: "ask", text: "Which DB?", options: ["pg", "sqlite"], recommendation: "pg" })))
      .toBe("\n**Question Q1** (ask): Which DB? Options: pg, sqlite. Recommended: pg.\n");
    expect(renderEvent(e("answer", { question: "Q1", text: "pg", grant: ["push"] }))).toBe("\n**Answer to Q1**: pg (allowed: push)\n");
    expect(renderEvent(e("gate", { rule: "gate", command: "git push" }))).toBe("\n**Gate** refused `git push` (gate)\n");
    expect(renderEvent(e("state", { state: "waiting", reason: "question Q1" }))).toBe("\n_— waiting: question Q1 —_\n");
    expect(renderEvent(e("error", { message: "boom" }))).toBe("\n**Error**: boom\n");
    expect(renderEvent(e("plan", { entries: [] }))).toBeNull();
  });
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd bridge && npx vitest run test/store.test.ts test/transcript.test.ts`
Expected: FAIL (modules missing).

- [ ] **Step 4: Write `bridge/src/store.ts`**

```ts
// The task's files on /task (spec §5): one writer, atomic state.json, append-only JSONL with seq.
import {
  accessSync, appendFileSync, closeSync, constants, existsSync, fsyncSync, openSync, readFileSync,
  renameSync, writeSync,
} from "node:fs";
import { join } from "node:path";
import type { Question, TaskEvent, TaskRecord } from "./types.js";

export class StoreError extends Error {}

export class Store {
  private seq: number;

  constructor(readonly dir: string, private readonly redact: (s: string) => string = (s) => s) {
    this.seq = this.readJsonl<TaskEvent>("events.jsonl").reduce((m, e) => Math.max(m, e.seq ?? 0), 0);
  }

  path(name: string): string {
    return join(this.dir, name);
  }

  checkWritable(): void {
    try {
      accessSync(this.dir, constants.W_OK);
    } catch {
      throw new StoreError(`${this.dir} is not writable by uid ${process.getuid?.() ?? "?"}; fix the owner of the task volume`);
    }
  }

  hasRecord(): boolean {
    return existsSync(this.path("state.json"));
  }

  readRecord(): TaskRecord {
    const p = this.path("state.json");
    try {
      return JSON.parse(readFileSync(p, "utf8")) as TaskRecord;
    } catch {
      throw new StoreError(`${p} is not valid JSON; fix or remove it by hand (it is never reset)`);
    }
  }

  writeRecord(r: TaskRecord): void {
    r.seq = this.seq;
    const p = this.path("state.json");
    const tmp = `${p}.tmp`;
    const fd = openSync(tmp, "w", 0o644);
    try {
      writeSync(fd, this.redact(JSON.stringify(r, null, 1)) + "\n");
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, p);
  }

  appendEvent(e: Omit<TaskEvent, "seq">): TaskEvent {
    const line = this.redact(JSON.stringify({ seq: this.seq + 1, ...e }));
    appendFileSync(this.path("events.jsonl"), line + "\n");
    this.seq += 1;
    return JSON.parse(line) as TaskEvent;
  }

  readEvents(since: number, limit = 1000): TaskEvent[] {
    return this.readJsonl<TaskEvent>("events.jsonl").filter((e) => e.seq > since).slice(0, limit);
  }

  appendQuestion(q: Question): void {
    appendFileSync(this.path("questions.jsonl"), this.redact(JSON.stringify(q)) + "\n");
  }

  readQuestions(): Question[] {
    const byId = new Map<string, Question>();
    for (const q of this.readJsonl<Question>("questions.jsonl")) byId.set(q.id, q);
    return [...byId.values()];
  }

  appendTranscript(md: string): void {
    appendFileSync(this.path("transcript.md"), this.redact(md));
  }

  readPrompt(): string | null {
    const p = this.path("prompt.md");
    return existsSync(p) ? readFileSync(p, "utf8") : null;
  }

  private readJsonl<T>(name: string): T[] {
    const p = this.path(name);
    if (!existsSync(p)) return [];
    const out: T[] = [];
    for (const line of readFileSync(p, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line) as T);
      } catch {
        // a torn or corrupt line is skipped (spec §5.2)
      }
    }
    return out;
  }
}
```

- [ ] **Step 5: Write `bridge/src/transcript.ts`**

```ts
// Readable rendering of events for transcript.md (spec §5.3).
import type { TaskEvent } from "./types.js";

const str = (v: unknown): string => (typeof v === "string" ? v : "");

export function renderEvent(e: TaskEvent): string | null {
  const d = e.data;
  switch (e.type) {
    case "message":
      if (d.role === "user") return "\n" + str(d.text).split("\n").map((l) => `> ${l}`).join("\n") + "\n";
      return d.final === true ? `\n${str(d.text)}\n` : null;
    case "tool": {
      if (d.status !== "done" && d.status !== "failed") return null;
      const head = `\n▸ ${str(d.title)} — ${d.status}\n`;
      const tail = str(d.output_tail).split("\n").filter((l, i, a) => l !== "" || i < a.length - 1).slice(-10).join("\n");
      return tail ? `${head}\`\`\`\n${tail}\n\`\`\`\n` : head;
    }
    case "question": {
      const opts = Array.isArray(d.options) && d.options.length ? ` Options: ${d.options.join(", ")}.` : "";
      const rec = d.recommendation ? ` Recommended: ${str(d.recommendation)}.` : "";
      return `\n**Question ${str(d.id)}** (${str(d.source)}): ${str(d.text)}${opts}${rec}\n`;
    }
    case "answer": {
      const g = Array.isArray(d.grant) && d.grant.length ? ` (allowed: ${d.grant.join(", ")})` : "";
      return `\n**Answer to ${str(d.question)}**: ${str(d.text)}${g}\n`;
    }
    case "gate":
      return `\n**Gate** refused \`${str(d.command)}\` (${str(d.rule)})\n`;
    case "state":
      return `\n_— ${str(d.state)}${d.reason ? `: ${str(d.reason)}` : ""} —_\n`;
    case "error":
      return `\n**Error**: ${str(d.message)}\n`;
    default:
      return null;
  }
}
```

- [ ] **Step 6: Run tests and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add bridge/src/store.ts bridge/src/transcript.ts bridge/test/store.test.ts bridge/test/transcript.test.ts
git commit -m "feat: bridge store: atomic record, events with seq, questions, redacted transcript"
```

---

### Task 6: The task state machine

**Files:**
- Create: `bridge/src/task.ts`, `bridge/test/task.test.ts`

**Interfaces:**
- Consumes: `types.ts`.
- Produces (`task.ts`), used by `bridge.ts` (Task 9):

```ts
export type Effect =
  | { kind: "spawn"; mode: "new" | "load" }
  | { kind: "prompt"; text: string }
  | { kind: "cancel" }
  | { kind: "permission"; question: string; optionId: string | null }
  | { kind: "kill" }
  | { kind: "exit"; code: number }
  | { kind: "emit"; type: EventType; data: Record<string, unknown> }
  | { kind: "question"; question: Question }
  | { kind: "timer"; on: boolean }
  | { kind: "notify"; question: Question | null };

export type Input =
  | { kind: "boot"; fresh: boolean }
  | { kind: "userPrompt"; text: string }
  | { kind: "answer"; question?: string; text: string; grant: string[] }
  | { kind: "cancel" }
  | { kind: "stop" }
  | { kind: "ask"; text: string; options: string[]; recommend: string | null }
  | { kind: "permissionRequest"; title: string; command: string; options: PermissionOption[] }
  | { kind: "agentReady"; session: string }
  | { kind: "turnEnd"; stopReason: string; summary: string }
  | { kind: "agentExit"; error: string }
  | { kind: "idleTimeout" }
  | { kind: "gate"; rule: string; command: string };

export type Outcome =
  | { ok: true; effects: Effect[]; value?: { id: string } }
  | { ok: false; code: "conflict" | "not_found" | "bad_request"; message: string };

export class TaskMachine {
  constructor(record: TaskRecord, questions: Question[], now: () => string);
  record: TaskRecord; questions: Question[];
  promptOutstanding: boolean; agentLive: boolean;
  openQuestions(): Question[];
  apply(input: Input): Outcome;
}
export const GRANT_RE: RegExp;
```

Rules (spec §6): `boot` fresh → `starting` + `spawn new` (the first prompt is already the record's inbox); `boot` with a record in starting/running/waiting/idle → `interrupted`; `boot` in stopped → `exit 0`; otherwise nothing. Inbox items are delivered as one prompt (joined with a blank line) whenever no prompt is outstanding; if no agent is live, `spawn` (`load` when the record has a session) and state `starting` with reason `resuming session`. `permissionRequest` puts the task in `waiting`. A state change emits a `state` event, switches the idle timer (on in waiting/idle) and notifies in waiting/idle/failed/stopped.

- [ ] **Step 1: Write the tests (failing)**

`bridge/test/task.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { TaskMachine, type Effect, type Outcome } from "../src/task.js";
import type { TaskRecord, Question } from "../src/types.js";

const rec = (over: Partial<TaskRecord> = {}): TaskRecord => ({
  version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "starting", reason: "",
  session: null, branch: null, created: "t0", updated: "t0", seq: 0, allowed_actions: [],
  inbox: [{ kind: "prompt", text: "Fix the login bug" }], summary: "", stopped_by_user: false, ...over,
});
const m = (over: Partial<TaskRecord> = {}, qs: Question[] = []) => new TaskMachine(rec(over), qs, () => "now");
const fx = (o: Outcome): Effect[] => { if (!o.ok) throw new Error(o.message); return o.effects; };
const kinds = (o: Outcome) => fx(o).map((e) => e.kind === "emit" ? `emit:${e.type}` : e.kind);
const states = (o: Outcome) => fx(o).flatMap((e) => (e.kind === "emit" && e.type === "state" ? [e.data.state] : []));

// running: a fresh task whose first prompt is outstanding
function running() {
  const t = m();
  t.apply({ kind: "boot", fresh: true });
  t.apply({ kind: "agentReady", session: "s1" });
  return t;
}

describe("start", () => {
  it("a fresh task spawns a new session, then sends the first prompt", () => {
    const t = m();
    const a = t.apply({ kind: "boot", fresh: true });
    expect(states(a)).toEqual(["starting"]);
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "new" });
    const b = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(b)).toContainEqual({ kind: "prompt", text: "Fix the login bug" });
    expect(t.record.state).toBe("running");
    expect(t.record.session).toBe("s1");
    expect(t.record.inbox).toEqual([]);
  });

  it("a record left running, waiting, idle or starting is interrupted; nothing is spawned", () => {
    for (const s of ["running", "waiting", "idle", "starting"] as const) {
      const t = m({ state: s, inbox: [] });
      const o = t.apply({ kind: "boot", fresh: false });
      expect(states(o)).toEqual(["interrupted"]);
      expect(kinds(o)).not.toContain("spawn");
    }
  });

  it("a suspended task boots lazily; a stopped one exits", () => {
    expect(fx(m({ state: "suspended", inbox: [] }).apply({ kind: "boot", fresh: false }))).toEqual([]);
    expect(fx(m({ state: "stopped", inbox: [] }).apply({ kind: "boot", fresh: false }))).toEqual([{ kind: "exit", code: 0 }]);
  });
});

describe("turns", () => {
  it("a turn without an open question ends idle, with the summary, timer on, notified", () => {
    const t = running();
    const o = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "Done." });
    expect(states(o)).toEqual(["idle"]);
    expect(t.record.summary).toBe("Done.");
    expect(fx(o)).toContainEqual({ kind: "timer", on: true });
    expect(fx(o)).toContainEqual({ kind: "notify", question: null });
  });

  it("a turn with an open question ends waiting", () => {
    const t = running();
    t.apply({ kind: "ask", text: "Which DB?", options: ["pg"], recommend: "pg" });
    const o = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(t.record.state).toBe("waiting");
    expect(t.record.reason).toBe("question Q1");
    expect(fx(o).find((e) => e.kind === "notify")).toMatchObject({ question: { id: "Q1" } });
  });

  it("a summary is cut to 300 characters", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "x".repeat(400) });
    expect(t.record.summary).toHaveLength(300);
  });
});

describe("prompts", () => {
  it("are refused while a turn is in progress", () => {
    const o = running().apply({ kind: "userPrompt", text: "more" });
    expect(o).toMatchObject({ ok: false, code: "conflict" });
    expect(o.ok || o.message).toContain("cancel first");
  });

  it("are refused when empty or when stopped", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(t.apply({ kind: "userPrompt", text: "  " })).toMatchObject({ ok: false, code: "bad_request" });
    t.apply({ kind: "stop" });
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("in idle go straight to the live agent", () => {
    const t = running();
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "userPrompt", text: "Also add a test" });
    expect(fx(o)).toContainEqual({ kind: "prompt", text: "Also add a test" });
    expect(t.record.state).toBe("running");
  });

  it("in suspended load the session first, then deliver", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    const o = t.apply({ kind: "userPrompt", text: "go on" });
    expect(fx(o)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.state).toBe("starting");
    const r = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(r)).toContainEqual({ kind: "prompt", text: "go on" });
  });
});

describe("questions and answers", () => {
  it("ask records an open question and returns its id", () => {
    const t = running();
    const o = t.apply({ kind: "ask", text: "Which DB?", options: ["pg", "sqlite"], recommend: "pg" });
    expect(o).toMatchObject({ ok: true, value: { id: "Q1" } });
    expect(fx(o).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", status: "open", source: "ask" } });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q1"]);
  });

  it("an answer while the agent works is queued and delivered after the turn", () => {
    const t = running();
    t.apply({ kind: "ask", text: "Push?", options: [], recommend: null });
    const a = t.apply({ kind: "answer", text: "yes", grant: ["push"] });
    expect(kinds(a)).not.toContain("prompt");
    expect(t.record.allowed_actions).toEqual(["push"]);
    const e = t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    expect(fx(e)).toContainEqual({ kind: "prompt", text: "Answer to Q1: yes\nAllowed for this task: push." });
    expect(t.record.state).toBe("running");
  });

  it("an answer in waiting is delivered at once; grants are not duplicated", () => {
    const t = running();
    t.record.allowed_actions = ["push"];
    t.apply({ kind: "ask", text: "Which DB?", options: [], recommend: null });
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "answer", question: "Q1", text: "pg", grant: ["push", "open-pr"] });
    expect(fx(o)).toContainEqual({ kind: "prompt", text: "Answer to Q1: pg\nAllowed for this task: push, open-pr." });
    expect(t.record.allowed_actions).toEqual(["push", "open-pr"]);
    expect(fx(o).find((e) => e.kind === "emit" && e.type === "answer")).toMatchObject({ data: { question: "Q1", text: "pg", grant: ["push", "open-pr"] } });
  });

  it("without an id the oldest open question is answered", () => {
    const t = running();
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    t.apply({ kind: "ask", text: "b", options: [], recommend: null });
    t.apply({ kind: "answer", text: "x", grant: [] });
    expect(t.openQuestions().map((q) => q.id)).toEqual(["Q2"]);
  });

  it("refuses unknown ids, nothing open, bad grants and empty text", () => {
    const t = running();
    expect(t.apply({ kind: "answer", text: "x", grant: [] })).toMatchObject({ ok: false, code: "conflict" });
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    expect(t.apply({ kind: "answer", question: "Q9", text: "x", grant: [] })).toMatchObject({ ok: false, code: "not_found" });
    expect(t.apply({ kind: "answer", text: "x", grant: ["merge"] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.apply({ kind: "answer", text: "x", grant: ["deploy:"] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.apply({ kind: "answer", text: " ", grant: [] })).toMatchObject({ ok: false, code: "bad_request" });
    expect(t.openQuestions()).toHaveLength(1);
  });

  // Review Focus 2
  it("a second answer to the same question is a conflict and adds nothing to the inbox", () => {
    const t = running();
    t.apply({ kind: "ask", text: "a", options: [], recommend: null });
    t.apply({ kind: "answer", question: "Q1", text: "x", grant: [] });
    const o = t.apply({ kind: "answer", question: "Q1", text: "x", grant: [] });
    expect(o).toMatchObject({ ok: false, code: "conflict", message: "Q1 is already answered" });
    expect(t.record.inbox).toHaveLength(1);
  });

  // Review Focus 1
  it("an answer during a resume load is queued and delivered once; a prompt then conflicts", () => {
    const t = m({ state: "suspended", session: "s1", inbox: [] }, [
      { id: "Q1", source: "ask", text: "a", options: [], recommendation: null, asked: "t", status: "open" },
    ]);
    t.apply({ kind: "boot", fresh: false });
    const a = t.apply({ kind: "answer", text: "yes", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.state).toBe("starting");
    expect(t.apply({ kind: "userPrompt", text: "x" })).toMatchObject({ ok: false, code: "conflict" });
    const r = t.apply({ kind: "agentReady", session: "s1" });
    expect(fx(r).filter((e) => e.kind === "prompt")).toEqual([{ kind: "prompt", text: "Answer to Q1: yes" }]);
    expect(t.record.inbox).toEqual([]);
  });
});

describe("permission requests", () => {
  const opts = [
    { optionId: "allow-once", name: "Yes", kind: "allow_once" },
    { optionId: "allow-with-updates", name: "Yes, and allow", kind: "allow_always" },
    { optionId: "reject", name: "No", kind: "reject_once" },
  ];

  it("become a waiting question; an answer goes back through ACP, not the inbox", () => {
    const t = running();
    const p = t.apply({ kind: "permissionRequest", title: "echo x", command: "echo x", options: opts });
    expect(t.record.state).toBe("waiting");
    expect(fx(p).find((e) => e.kind === "question")).toMatchObject({ question: { id: "Q1", source: "permission", options: ["Yes", "Yes, and allow", "No"] } });
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "permission", question: "Q1", optionId: "allow-once" });
    expect(t.record.inbox).toEqual([]);
    expect(t.record.state).toBe("running");
  });

  it("accept option names and kinds, case-insensitive; refuse anything else", () => {
    for (const [text, id] of [["No", "reject"], ["reject", "reject"], ["ALLOW ALWAYS", "allow-with-updates"], ["yes", "allow-once"]] as const) {
      const t = running();
      t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
      expect(fx(t.apply({ kind: "answer", text, grant: [] }))).toContainEqual({ kind: "permission", question: "Q1", optionId: id });
    }
    const t = running();
    t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
    expect(t.apply({ kind: "answer", text: "maybe", grant: [] })).toMatchObject({ ok: false, code: "bad_request" });
  });

  it("are cancelled at suspension; a later answer arrives as text after the load", () => {
    const t = running();
    t.apply({ kind: "permissionRequest", title: "x", command: "x", options: opts });
    const s = t.apply({ kind: "idleTimeout" });
    expect(fx(s)).toContainEqual({ kind: "permission", question: "Q1", optionId: null });
    expect(t.record.state).toBe("suspended");
    const a = t.apply({ kind: "answer", text: "allow", grant: [] });
    expect(fx(a)).toContainEqual({ kind: "spawn", mode: "load" });
    expect(t.record.inbox).toEqual([{ kind: "answer", question: "Q1", text: "Answer to Q1: allow" }]);
  });
});

describe("cancel, stop, suspension, failure", () => {
  it("cancel only while a turn is in progress", () => {
    const t = running();
    expect(fx(t.apply({ kind: "cancel" }))).toEqual([{ kind: "cancel" }]);
    t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" });
    expect(t.record.state).toBe("idle");
    expect(t.apply({ kind: "cancel" })).toMatchObject({ ok: false, code: "conflict" });
  });

  it("stop cancels a running turn, ends the agent and exits 0; a late turn end is ignored", () => {
    const t = running();
    const o = t.apply({ kind: "stop" });
    expect(kinds(o)).toEqual(expect.arrayContaining(["cancel", "kill", "exit", "notify"]));
    expect(t.record.state).toBe("stopped");
    expect(t.record.stopped_by_user).toBe(true);
    expect(fx(t.apply({ kind: "turnEnd", stopReason: "cancelled", summary: "" }))).toEqual([]);
    expect(t.record.state).toBe("stopped");
  });

  it("the idle timeout suspends waiting and idle tasks only", () => {
    const t = running();
    expect(fx(t.apply({ kind: "idleTimeout" }))).toEqual([]);
    t.apply({ kind: "turnEnd", stopReason: "end_turn", summary: "" });
    const o = t.apply({ kind: "idleTimeout" });
    expect(kinds(o)).toEqual(expect.arrayContaining(["kill", "exit"]));
    expect(fx(o)).toContainEqual({ kind: "exit", code: 0 });
    expect(t.record.state).toBe("suspended");
    expect(t.agentLive).toBe(false);
  });

  it("an unexpected agent exit fails the task and exits 1; expected ones are ignored", () => {
    const t = running();
    const o = t.apply({ kind: "agentExit", error: "agent exited with code 3" });
    expect(t.record.state).toBe("failed");
    expect(t.record.reason).toBe("agent exited with code 3");
    expect(fx(o)).toContainEqual({ kind: "exit", code: 1 });
    const s = running(); s.apply({ kind: "stop" });
    expect(fx(s.apply({ kind: "agentExit", error: "x" }))).toEqual([]);
  });

  it("a failed task accepts a prompt and resumes its session", () => {
    const t = m({ state: "failed", session: "s1", inbox: [] });
    t.apply({ kind: "boot", fresh: false });
    expect(fx(t.apply({ kind: "userPrompt", text: "retry" }))).toContainEqual({ kind: "spawn", mode: "load" });
  });

  it("gate reports become gate events", () => {
    expect(fx(running().apply({ kind: "gate", rule: "gate", command: "git push" })))
      .toEqual([{ kind: "emit", type: "gate", data: { rule: "gate", command: "git push" } }]);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd bridge && npx vitest run test/task.test.ts`
Expected: FAIL (module missing).

- [ ] **Step 3: Write `bridge/src/task.ts`**

```ts
// The task state machine (spec §6). Pure: inputs in, effects out; bridge.ts performs the effects.
import type { EventType, PermissionOption, Question, State, TaskRecord } from "./types.js";

export type Effect =
  | { kind: "spawn"; mode: "new" | "load" }
  | { kind: "prompt"; text: string }
  | { kind: "cancel" }
  | { kind: "permission"; question: string; optionId: string | null }
  | { kind: "kill" }
  | { kind: "exit"; code: number }
  | { kind: "emit"; type: EventType; data: Record<string, unknown> }
  | { kind: "question"; question: Question }
  | { kind: "timer"; on: boolean }
  | { kind: "notify"; question: Question | null };

export type Input =
  | { kind: "boot"; fresh: boolean }
  | { kind: "userPrompt"; text: string }
  | { kind: "answer"; question?: string; text: string; grant: string[] }
  | { kind: "cancel" }
  | { kind: "stop" }
  | { kind: "ask"; text: string; options: string[]; recommend: string | null }
  | { kind: "permissionRequest"; title: string; command: string; options: PermissionOption[] }
  | { kind: "agentReady"; session: string }
  | { kind: "turnEnd"; stopReason: string; summary: string }
  | { kind: "agentExit"; error: string }
  | { kind: "idleTimeout" }
  | { kind: "gate"; rule: string; command: string };

export type Outcome =
  | { ok: true; effects: Effect[]; value?: { id: string } }
  | { ok: false; code: "conflict" | "not_found" | "bad_request"; message: string };

export const GRANT_RE = /^(push|open-pr|deploy:[A-Za-z0-9_.-]+)$/;
const PROMPTABLE: State[] = ["idle", "waiting", "suspended", "interrupted", "failed"];
const NOTIFY: State[] = ["waiting", "idle", "failed", "stopped"];
const UNCLEAN: State[] = ["starting", "running", "waiting", "idle"];

const fail = (code: "conflict" | "not_found" | "bad_request", message: string): Outcome => ({ ok: false, code, message });

export class TaskMachine {
  promptOutstanding = false;
  agentLive = false;
  private spawning = false;
  private readonly pending = new Set<string>(); // permission questions the live agent waits on

  constructor(public record: TaskRecord, public questions: Question[], private readonly now: () => string) {}

  openQuestions(): Question[] {
    return this.questions.filter((q) => q.status === "open");
  }

  apply(input: Input): Outcome {
    const fx: Effect[] = [];
    switch (input.kind) {
      case "boot":
        if (input.fresh) {
          this.setState("starting", "first prompt", fx);
          this.spawning = true;
          fx.push({ kind: "spawn", mode: "new" });
        } else if (UNCLEAN.includes(this.record.state)) {
          this.setState("interrupted", "the bridge ended without stop or suspension", fx);
        } else if (this.record.state === "stopped") {
          fx.push({ kind: "exit", code: 0 });
        }
        return { ok: true, effects: fx };

      case "userPrompt": {
        if (!input.text.trim()) return fail("bad_request", "empty prompt");
        if (this.promptOutstanding || this.spawning) return fail("conflict", "a turn is in progress; cancel first");
        if (!PROMPTABLE.includes(this.record.state)) return fail("conflict", `task is ${this.record.state}`);
        this.record.inbox.push({ kind: "prompt", text: input.text });
        this.deliver(fx);
        return { ok: true, effects: fx };
      }

      case "answer":
        return this.answer(input, fx);

      case "cancel":
        if (!this.promptOutstanding) return fail("conflict", "no turn in progress");
        fx.push({ kind: "cancel" });
        return { ok: true, effects: fx };

      case "stop":
        if (this.record.state === "stopped") return { ok: true, effects: fx };
        if (this.promptOutstanding) fx.push({ kind: "cancel" });
        for (const id of this.pending) fx.push({ kind: "permission", question: id, optionId: null });
        this.pending.clear();
        if (this.agentLive || this.spawning) fx.push({ kind: "kill" });
        this.agentLive = this.spawning = this.promptOutstanding = false;
        this.record.stopped_by_user = true;
        this.setState("stopped", "stopped by user", fx);
        fx.push({ kind: "exit", code: 0 });
        return { ok: true, effects: fx };

      case "ask": {
        if (!input.text.trim()) return fail("bad_request", "empty question");
        if (this.record.state === "stopped") return fail("conflict", "task is stopped");
        const q = this.addQuestion("ask", input.text, input.options, input.recommend, fx);
        if (!this.promptOutstanding && this.record.state === "idle") this.setState("waiting", `question ${q.id}`, fx);
        return { ok: true, effects: fx, value: { id: q.id } };
      }

      case "permissionRequest": {
        const q = this.addQuestion("permission", `Allow: ${input.command || input.title}?`,
          input.options.map((o) => o.name), null, fx, { options: input.options });
        this.pending.add(q.id);
        this.setState("waiting", `question ${q.id}`, fx);
        return { ok: true, effects: fx };
      }

      case "agentReady":
        this.agentLive = true;
        this.spawning = false;
        this.record.session = input.session;
        this.deliver(fx);
        if (!this.promptOutstanding) this.settle("", fx);
        return { ok: true, effects: fx };

      case "turnEnd":
        if (!this.promptOutstanding) return { ok: true, effects: fx };
        this.promptOutstanding = false;
        this.pending.clear();
        if (input.summary) this.record.summary = input.summary.slice(0, 300);
        this.deliver(fx);
        if (!this.promptOutstanding) this.settle(input.stopReason === "cancelled" ? "cancelled" : "", fx);
        return { ok: true, effects: fx };

      case "agentExit":
        if (["stopped", "suspended"].includes(this.record.state)) return { ok: true, effects: fx };
        this.agentLive = this.spawning = this.promptOutstanding = false;
        this.pending.clear();
        this.setState("failed", input.error, fx);
        fx.push({ kind: "exit", code: 1 });
        return { ok: true, effects: fx };

      case "idleTimeout":
        if (this.record.state !== "waiting" && this.record.state !== "idle") return { ok: true, effects: fx };
        for (const id of this.pending) fx.push({ kind: "permission", question: id, optionId: null });
        this.pending.clear();
        if (this.agentLive) fx.push({ kind: "kill" });
        this.agentLive = this.promptOutstanding = false;
        this.setState("suspended", "idle timeout", fx);
        fx.push({ kind: "exit", code: 0 });
        return { ok: true, effects: fx };

      case "gate":
        fx.push({ kind: "emit", type: "gate", data: { rule: input.rule, command: input.command } });
        return { ok: true, effects: fx };
    }
  }

  private answer(input: { question?: string; text: string; grant: string[] }, fx: Effect[]): Outcome {
    if (!input.text.trim()) return fail("bad_request", "empty answer");
    const bad = input.grant.find((g) => !GRANT_RE.test(g));
    if (bad !== undefined) return fail("bad_request", `unknown grant ${bad} (push, open-pr, deploy:<target>)`);
    if (this.record.state === "stopped") return fail("conflict", "task is stopped");
    let q: Question | undefined;
    if (input.question) {
      q = this.questions.find((x) => x.id === input.question);
      if (!q) return fail("not_found", `no question ${input.question}`);
      if (q.status !== "open") return fail("conflict", `${q.id} is already answered`);
    } else {
      q = this.openQuestions()[0];
      if (!q) return fail("conflict", "no open question");
    }
    const live = q.source === "permission" && this.pending.has(q.id);
    let optionId: string | null = null;
    if (live) {
      optionId = matchOption(q.permission?.options ?? [], input.text);
      if (!optionId) return fail("bad_request", `answer one of: ${q.options.join(", ")}`);
    }
    q.status = "answered";
    q.answer = input.text;
    q.grant = input.grant;
    q.answered = this.now();
    for (const g of input.grant) if (!this.record.allowed_actions.includes(g)) this.record.allowed_actions.push(g);
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "answer", data: { question: q.id, text: input.text, grant: input.grant } });
    if (live) {
      this.pending.delete(q.id);
      fx.push({ kind: "permission", question: q.id, optionId });
      if (this.record.state === "waiting" && this.pending.size === 0) this.setState("running", "", fx);
    } else {
      const allowed = input.grant.length ? `\nAllowed for this task: ${input.grant.join(", ")}.` : "";
      this.record.inbox.push({ kind: "answer", question: q.id, text: `Answer to ${q.id}: ${input.text}${allowed}` });
      this.deliver(fx);
    }
    return { ok: true, effects: fx };
  }

  // deliver: the inbox as one prompt when nothing is outstanding; spawns the agent if needed.
  private deliver(fx: Effect[]): void {
    if (this.promptOutstanding || this.record.inbox.length === 0) return;
    if (!this.agentLive) {
      if (this.spawning) return;
      this.spawning = true;
      this.setState("starting", "resuming session", fx);
      fx.push({ kind: "spawn", mode: this.record.session ? "load" : "new" });
      return;
    }
    const text = this.record.inbox.map((i) => i.text).join("\n\n");
    this.record.inbox = [];
    this.promptOutstanding = true;
    this.setState("running", "", fx);
    fx.push({ kind: "prompt", text });
  }

  // settle: waiting with an open question, else idle.
  private settle(reason: string, fx: Effect[]): void {
    const open = this.openQuestions()[0];
    if (open) this.setState("waiting", `question ${open.id}`, fx);
    else this.setState("idle", reason, fx);
  }

  private addQuestion(source: Question["source"], text: string, options: string[], recommend: string | null,
    fx: Effect[], permission?: Question["permission"]): Question {
    const q: Question = {
      id: `Q${this.questions.length + 1}`, source, text, options, recommendation: recommend, asked: this.now(),
      status: "open", ...(permission ? { permission } : {}),
    };
    this.questions.push(q);
    fx.push({ kind: "question", question: { ...q } });
    fx.push({ kind: "emit", type: "question", data: { id: q.id, source, text, options, recommendation: recommend } });
    return q;
  }

  private setState(state: State, reason: string, fx: Effect[]): void {
    const changed = this.record.state !== state || this.record.reason !== reason;
    this.record.state = state;
    this.record.reason = reason;
    this.record.updated = this.now();
    if (!changed) return;
    fx.push({ kind: "emit", type: "state", data: { state, reason } });
    fx.push({ kind: "timer", on: state === "waiting" || state === "idle" });
    if (NOTIFY.includes(state)) fx.push({ kind: "notify", question: this.openQuestions()[0] ?? null });
  }
}

// matchOption: a permission answer by option name or kind ("allow once"), with allow/yes and reject/deny/no.
export function matchOption(options: { optionId: string; name: string; kind: string }[], text: string): string | null {
  const t = text.trim().toLowerCase();
  const alias: Record<string, string> = { allow: "allow_once", yes: "allow_once", reject: "reject_once", deny: "reject_once", no: "reject_once" };
  const byName = options.find((o) => o.name.toLowerCase() === t);
  if (byName) return byName.optionId;
  const kind = alias[t] ?? t.replace(/\s+/g, "_");
  return options.find((o) => o.kind === kind)?.optionId ?? null;
}
```

- [ ] **Step 4: Run tests and lint**

Run: `make test && make lint`
Expected: PASS. If a test fails, fix the machine, not the test, unless the test contradicts spec §6.

- [ ] **Step 5: Commit**

```bash
git add bridge/src/task.ts bridge/test/task.test.ts
git commit -m "feat: task state machine: turns, inbox, questions and grants, permissions, suspension"
```

---

### Task 7: ACP update mapping, the agent process and the fake agent

**Files:**
- Create: `bridge/src/map.ts`, `bridge/src/harness.ts`, `bridge/src/agent.ts`, `bridge/test/fake-agent.mjs`, `bridge/test/fixtures/claude-updates.jsonl`, `bridge/test/fixtures/copilot-updates.jsonl`, `bridge/test/map.test.ts`, `bridge/test/agent.test.ts`

**Interfaces:**
- Consumes: `types.ts`; `@agentclientprotocol/sdk` (`client`, `methods`, `ndJsonStream`, `PROTOCOL_VERSION`).
- Produces:
  - `map.ts`: `interface Update { sessionUpdate: string; [k: string]: unknown }`; `interface Mapped { type: "message" | "tool" | "plan"; data: Record<string, unknown> }`; `class UpdateMapper { handle(u: Update): Mapped[]; flushPartial(): Mapped[]; finishTurn(): { events: Mapped[]; summary: string } }`; `outputTail(u: Update): string`.
  - `harness.ts`: `interface SessionCalls { setMode(sessionId: string, modeId: string): Promise<void>; setConfigOption(sessionId: string, configId: string, value: string): Promise<void> }`; `interface HarnessSpec { name: AgentName; command: string[]; env: Record<string, string>; sessionMeta(paragraph: string): Record<string, unknown> | undefined; afterSession(calls: SessionCalls, sessionId: string, model: string | null): Promise<void> }`; `harnessFor(name: AgentName, opts: { model: string | null; acpCmd: string[] | null }): HarnessSpec`; `CLAUDE_ACP_ENTRY: string`.
  - `agent.ts`: `interface PermissionAsk { title: string; command: string; options: PermissionOption[] }`; `interface AgentHooks { onUpdate(u: Update): void; onPermission(req: PermissionAsk): Promise<string | null>; onExit(error: string): void; onStderr?(chunk: string): void }`; `interface AgentLike { start(): Promise<void>; newSession(): Promise<string>; loadSession(id: string): Promise<void>; prompt(text: string): Promise<string>; cancel(): void; kill(): Promise<void> }`; `class AgentProcess implements AgentLike` with `constructor(spec: HarnessSpec, opts: { cwd: string; env: NodeJS.ProcessEnv; paragraph: string; model: string | null }, hooks: AgentHooks)`. `onExit` fires only for an exit the bridge did not ask for. Updates arriving during `loadSession` (the replay) are dropped.
  - `fake-agent.mjs`: a scripted ACP agent (prompt keywords below), used by Tasks 9 and 13.

- [ ] **Step 1: Extract the fixtures from the spike logs**

```bash
mkdir -p bridge/test/fixtures
for pair in claude-a:claude copilot-g:copilot; do
  run="${pair%%:*}"; name="${pair##*:}"
  grep ' << ' ~/agentic-spike-2026-10-12/out/$run/acp.log | cut -d' ' -f3- \
    | jq -c 'select(.method == "session/update") | .params.update | del(._meta)
             | select(.sessionUpdate | IN("agent_message_chunk", "user_message_chunk", "tool_call", "tool_call_update", "plan"))' \
    | sed -E 's#/tmp/claude-1000/[^" ]*#/tmp/redacted#g' > "bridge/test/fixtures/$name-updates.jsonl"
done
wc -l bridge/test/fixtures/*.jsonl
```

Expected: two non-empty files. Run `tools/leak-check.sh` now; it must print `leak-check: clean`.

- [ ] **Step 2: Write the mapping tests (failing)**

`bridge/test/map.test.ts`:

```ts
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { UpdateMapper, outputTail, type Mapped, type Update } from "../src/map.js";

const chunk = (text: string): Update => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const fixture = (name: string): Update[] =>
  readFileSync(new URL(`./fixtures/${name}-updates.jsonl`, import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));

describe("UpdateMapper", () => {
  it("buffers message chunks until a flush, then emits one final message per turn", () => {
    const m = new UpdateMapper();
    expect(m.handle(chunk("Hel"))).toEqual([]);
    expect(m.handle(chunk("lo"))).toEqual([]);
    expect(m.flushPartial()).toEqual([{ type: "message", data: { role: "agent", text: "Hello", final: false } }]);
    expect(m.flushPartial()).toEqual([]);
    m.handle(chunk(" there"));
    const { events, summary } = m.finishTurn();
    expect(events).toEqual([
      { type: "message", data: { role: "agent", text: " there", final: false } },
      { type: "message", data: { role: "agent", text: "Hello there", final: true } },
    ]);
    expect(summary).toBe("Hello there");
  });

  it("flushes text before a tool event; the summary is the text after the last tool call", () => {
    const m = new UpdateMapper();
    m.handle(chunk("Let me look."));
    const out = m.handle({ sessionUpdate: "tool_call", toolCallId: "t1", title: "ls", kind: "execute", status: "pending" });
    expect(out.map((e) => e.type)).toEqual(["message", "tool"]);
    m.handle(chunk("Found it."));
    expect(m.finishTurn().summary).toBe("Found it.");
  });

  it("emits tool events on status changes only, with the latest title and an output tail when finished", () => {
    const m = new UpdateMapper();
    const a = m.handle({ sessionUpdate: "tool_call", toolCallId: "t1", title: "Terminal", kind: "execute", status: "pending" });
    expect(a).toEqual([{ type: "tool", data: { id: "t1", title: "Terminal", kind: "execute", status: "pending", output_tail: null } }]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", title: "npm test" })).toEqual([]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "in_progress" })[0]?.data.status).toBe("running");
    const done = m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed",
      content: [{ type: "content", content: { type: "text", text: "```console\nok\n```" } }] });
    expect(done).toEqual([{ type: "tool", data: { id: "t1", title: "npm test", kind: "execute", status: "done", output_tail: "ok" } }]);
    expect(m.handle({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" })).toEqual([]);
  });

  it("maps plans and ignores everything else", () => {
    const m = new UpdateMapper();
    expect(m.handle({ sessionUpdate: "plan", entries: [{ content: "a", status: "pending" }] }))
      .toEqual([{ type: "plan", data: { entries: [{ content: "a", status: "pending" }] } }]);
    for (const s of ["agent_thought_chunk", "usage_update", "available_commands_update", "user_message_chunk", "session_info_update"]) {
      expect(m.handle({ sessionUpdate: s, content: { type: "text", text: "x" } })).toEqual([]);
    }
  });

  it("claude fixture: the gate refusal of git push is a failed tool with the reason", () => {
    const m = new UpdateMapper();
    const out: Mapped[] = fixture("claude").flatMap((u) => m.handle(u));
    const failed = out.filter((e) => e.type === "tool" && e.data.status === "failed");
    expect(failed).toHaveLength(1);
    expect(failed[0]?.data.title).toBe("git push origin HEAD");
    expect(String(failed[0]?.data.output_tail)).toContain("agentic gate: git push is not in allowed_actions");
    expect(String(m.finishTurn().events.at(-1)?.data.text)).toContain("PELICAN");
  });

  it("copilot fixture: the deny decision is a failed tool with the reason", () => {
    const m = new UpdateMapper();
    const out = fixture("copilot").flatMap((u) => m.handle(u));
    const failed = out.filter((e) => e.type === "tool" && e.data.status === "failed");
    expect(failed).toHaveLength(1);
    expect(String(failed[0]?.data.output_tail)).toContain("agentic gate: git push is not in allowed_actions");
  });
});

describe("outputTail", () => {
  it("keeps the last 20 lines and at most 2 KB, without code fences", () => {
    const text = "```\n" + Array.from({ length: 30 }, (_, i) => `l${i + 1}`).join("\n") + "\n```";
    const t = outputTail({ sessionUpdate: "tool_call_update", content: [{ type: "content", content: { type: "text", text } }] });
    expect(t.split("\n")).toEqual(Array.from({ length: 20 }, (_, i) => `l${i + 11}`));
    const long = outputTail({ sessionUpdate: "tool_call_update", rawOutput: "x".repeat(5000) });
    expect(long).toHaveLength(2048);
  });

  it("falls back to rawOutput as a string, its content, or its message", () => {
    expect(outputTail({ sessionUpdate: "u", rawOutput: "plain" })).toBe("plain");
    expect(outputTail({ sessionUpdate: "u", rawOutput: { content: "c" } })).toBe("c");
    expect(outputTail({ sessionUpdate: "u", rawOutput: { message: "m", code: "denied" } })).toBe("m");
    expect(outputTail({ sessionUpdate: "u" })).toBe("");
  });
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd bridge && npx vitest run test/map.test.ts`
Expected: FAIL (module missing).

- [ ] **Step 4: Write `bridge/src/map.ts`**

```ts
// ACP session updates → bridge events (spec §8.3). Thoughts, usage, commands, config, titles and
// user chunks are dropped; message chunks are buffered and flushed by the caller.
export interface Update {
  sessionUpdate: string;
  [k: string]: unknown;
}
export interface Mapped {
  type: "message" | "tool" | "plan";
  data: Record<string, unknown>;
}
type ToolStatus = "pending" | "running" | "done" | "failed";

const STATUS: Record<string, ToolStatus> = { pending: "pending", in_progress: "running", completed: "done", failed: "failed" };
const str = (v: unknown): string => (typeof v === "string" ? v : "");

export class UpdateMapper {
  private partial = "";
  private turn = "";
  private segment = "";
  private readonly tools = new Map<string, { title: string; kind: string; status: ToolStatus }>();

  handle(u: Update): Mapped[] {
    switch (u.sessionUpdate) {
      case "agent_message_chunk": {
        const c = u.content as { type?: string; text?: unknown } | undefined;
        const t = c?.type === "text" ? str(c.text) : "";
        this.partial += t;
        this.turn += t;
        this.segment += t;
        return [];
      }
      case "tool_call": {
        const out = this.flushPartial();
        this.segment = "";
        const id = str(u.toolCallId);
        const e = { title: str(u.title), kind: str(u.kind) || "other", status: STATUS[str(u.status)] ?? "pending" };
        this.tools.set(id, e);
        out.push(this.toolEvent(id, e, u));
        return out;
      }
      case "tool_call_update": {
        const id = str(u.toolCallId);
        const e = this.tools.get(id) ?? { title: "", kind: "other", status: "pending" as ToolStatus };
        this.tools.set(id, e);
        if (str(u.title)) e.title = str(u.title);
        if (str(u.kind)) e.kind = str(u.kind);
        const s = STATUS[str(u.status)];
        if (!s || s === e.status) return [];
        const out = this.flushPartial();
        e.status = s;
        out.push(this.toolEvent(id, e, u));
        return out;
      }
      case "plan":
        return [{ type: "plan", data: { entries: Array.isArray(u.entries) ? u.entries : [] } }];
      default:
        return [];
    }
  }

  flushPartial(): Mapped[] {
    if (!this.partial) return [];
    const text = this.partial;
    this.partial = "";
    return [{ type: "message", data: { role: "agent", text, final: false } }];
  }

  finishTurn(): { events: Mapped[]; summary: string } {
    const events = this.flushPartial();
    if (this.turn) events.push({ type: "message", data: { role: "agent", text: this.turn, final: true } });
    const summary = this.segment.trim();
    this.turn = "";
    this.segment = "";
    this.tools.clear();
    return { events, summary };
  }

  private toolEvent(id: string, e: { title: string; kind: string; status: ToolStatus }, u: Update): Mapped {
    const finished = e.status === "done" || e.status === "failed";
    return { type: "tool", data: { id, title: e.title, kind: e.kind, status: e.status, output_tail: finished ? outputTail(u) : null } };
  }
}

// outputTail: the tool's text output, fences removed, last 20 lines, 2 KB at most.
export function outputTail(u: Update): string {
  const content = Array.isArray(u.content) ? (u.content as Array<{ type?: string; content?: { type?: string; text?: unknown } }>) : [];
  let text = content.filter((c) => c.type === "content" && c.content?.type === "text").map((c) => str(c.content?.text)).join("\n");
  if (!text) {
    const raw = u.rawOutput as unknown;
    if (typeof raw === "string") text = raw;
    else if (raw && typeof raw === "object") text = str((raw as Record<string, unknown>).content) || str((raw as Record<string, unknown>).message);
  }
  const lines = text.split("\n").filter((l) => !/^```/.test(l));
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines.slice(-20).join("\n").slice(-2048);
}
```

- [ ] **Step 5: Run the mapping tests**

Run: `cd bridge && npx vitest run test/map.test.ts`
Expected: PASS. If a fixture assertion fails, inspect the fixture with `jq -c 'select(.status == "failed")' bridge/test/fixtures/<name>-updates.jsonl` and fix the mapper (the spike showed the reasons in `content` and `rawOutput`).

- [ ] **Step 6: Write the fake agent**

`bridge/test/fake-agent.mjs`:

```js
#!/usr/bin/env node
// Scripted ACP agent for the bridge's tests and the smoke test; not a product. Prompts drive it:
//   ASK:<text>        asks the human (POST /ask, or the real agentic-ask with FAKE_ASK=cli), replies "asked <id>"
//   SHELL:<command>   runs the task hook as a harness would (FAKE_HOOK, default /opt/agentic/task/hook.sh) and the
//                     command when allowed; a later "Answer to ..." prompt retries a refused command
//   PERMISSION:<cmd>  asks the client for permission, replies "permission: <optionId|cancelled>"
//   SLEEP:<ms>        a tool call that runs until done or cancelled
//   META              replies with the session's _meta and mode as JSON
//   HISTORY           replies "history: <number of earlier messages>"
//   CRASH             exits with code 3
//   anything else     replies "echo: <prompt>"
// Sessions live in $FAKE_AGENT_STATE (default /tmp/fake-agent), so session/load works across processes.
import { createInterface } from "node:readline";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";

const STATE = process.env.FAKE_AGENT_STATE || "/tmp/fake-agent";
mkdirSync(STATE, { recursive: true });
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
const waiting = new Map();
let nextId = 1;
const request = (method, params) => new Promise((resolve) => { const id = nextId++; waiting.set(id, resolve); send({ id, method, params }); });
const update = (sessionId, u) => send({ method: "session/update", params: { sessionId, update: u } });
const say = (sid, text) => update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const file = (sid) => join(STATE, `${sid}.json`);
const load = (sid) => JSON.parse(readFileSync(file(sid), "utf8"));
const save = (sid, s) => writeFileSync(file(sid), JSON.stringify(s));
const cancelled = new Set();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function hook(command) {
  const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
  const r = spawnSync("bash", [process.env.FAKE_HOOK || "/opt/agentic/task/hook.sh", "claude", "pretooluse"], { input: payload, encoding: "utf8" });
  return r.status === 2 ? (r.stderr || "refused").trim() : null;
}

function shell(sid, s, command, n) {
  const id = `sh-${n}`;
  update(sid, { sessionUpdate: "tool_call", toolCallId: id, title: command, kind: "execute", status: "pending" });
  const refused = hook(command);
  if (refused) {
    update(sid, { sessionUpdate: "tool_call_update", toolCallId: id, status: "failed", content: [{ type: "content", content: { type: "text", text: refused } }] });
    s.lastRefused = command;
    return `refused: ${refused}`;
  }
  const r = spawnSync("bash", ["-c", command], { encoding: "utf8", cwd: process.cwd() });
  update(sid, { sessionUpdate: "tool_call_update", toolCallId: id, status: r.status === 0 ? "completed" : "failed",
    content: [{ type: "content", content: { type: "text", text: (r.stdout || "") + (r.stderr || "") } }] });
  s.lastRefused = null;
  return `ran: ${command} (exit ${r.status})`;
}

async function ask(text) {
  if (process.env.FAKE_ASK === "cli") {
    const r = spawnSync("agentic-ask", [text], { encoding: "utf8" });
    return (r.stdout.match(/Recorded (Q\d+)/) || [])[1] || `failed: ${r.stderr.trim()}`;
  }
  const res = await fetch(`${process.env.AGENTIC_BRIDGE_URL}/ask`, {
    method: "POST",
    headers: { authorization: `Bearer ${process.env.AGENTIC_AGENT_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  return (await res.json()).id;
}

async function prompt(sid, text) {
  const s = load(sid);
  const before = s.history.length;
  s.history.push({ role: "user", text });
  cancelled.delete(sid);
  let reply = `echo: ${text}`;
  let stopReason = "end_turn";
  if (text.startsWith("ASK:")) reply = `asked ${await ask(text.slice(4))}`;
  else if (text.startsWith("SHELL:")) reply = shell(sid, s, text.slice(6), before);
  else if (text.startsWith("Answer to") && s.lastRefused) reply = shell(sid, s, s.lastRefused, before);
  else if (text.startsWith("PERMISSION:")) {
    const cmd = text.slice(11);
    const r = await request("session/request_permission", {
      sessionId: sid,
      toolCall: { toolCallId: `perm-${before}`, title: cmd, kind: "execute", status: "pending", rawInput: { command: cmd } },
      options: [
        { optionId: "allow-once", name: "Yes", kind: "allow_once" },
        { optionId: "allow-always", name: "Always", kind: "allow_always" },
        { optionId: "reject", name: "No", kind: "reject_once" },
      ],
    });
    reply = `permission: ${r.outcome.outcome === "selected" ? r.outcome.optionId : "cancelled"}`;
  } else if (text.startsWith("SLEEP:")) {
    update(sid, { sessionUpdate: "tool_call", toolCallId: `sleep-${before}`, title: "sleep", kind: "execute", status: "in_progress" });
    const end = Date.now() + Number(text.slice(6));
    while (Date.now() < end && !cancelled.has(sid)) await sleep(50);
    if (cancelled.has(sid)) { stopReason = "cancelled"; reply = ""; }
    else reply = "slept";
  } else if (text === "META") reply = JSON.stringify({ meta: s.meta, mode: s.mode });
  else if (text === "HISTORY") reply = `history: ${before}`;
  else if (text === "CRASH") process.exit(3);
  if (reply) { say(sid, reply); s.history.push({ role: "agent", text: reply }); }
  save(sid, s);
  return { stopReason };
}

async function handle(rpc) {
  if (rpc.id !== undefined && !rpc.method) { waiting.get(rpc.id)?.(rpc.result); waiting.delete(rpc.id); return; }
  const p = rpc.params || {};
  const reply = (result) => send({ id: rpc.id, result });
  switch (rpc.method) {
    case "initialize": return reply({ protocolVersion: 1, agentCapabilities: { loadSession: true }, authMethods: [] });
    case "session/new": {
      const sid = randomUUID();
      save(sid, { history: [], meta: p._meta ?? null, mode: "default", lastRefused: null });
      return reply({ sessionId: sid });
    }
    case "session/load": {
      if (!existsSync(file(p.sessionId))) return send({ id: rpc.id, error: { code: -32002, message: `session ${p.sessionId} not found` } });
      const s = load(p.sessionId);
      if (p._meta) { s.meta = p._meta; save(p.sessionId, s); }
      for (const h of s.history) update(p.sessionId, { sessionUpdate: h.role === "user" ? "user_message_chunk" : "agent_message_chunk", content: { type: "text", text: h.text } });
      return reply({});
    }
    case "session/set_mode": { const s = load(p.sessionId); s.mode = p.modeId; save(p.sessionId, s); return reply({}); }
    case "session/set_config_option": return reply({ configOptions: [] });
    case "session/prompt": return reply(await prompt(p.sessionId, p.prompt.map((b) => b.text ?? "").join("")));
    case "session/cancel": cancelled.add(p.sessionId); return;
    default: if (rpc.id !== undefined) send({ id: rpc.id, error: { code: -32601, message: `${rpc.method} not supported` } });
  }
}

createInterface({ input: process.stdin }).on("line", (line) => { if (line.trim()) void handle(JSON.parse(line)); });
```

- [ ] **Step 7: Write the agent tests (failing)**

`bridge/test/agent.test.ts`:

```ts
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess, type AgentHooks } from "../src/agent.js";
import { harnessFor } from "../src/harness.js";
import type { Update } from "../src/map.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const agents: AgentProcess[] = [];
afterEach(async () => { await Promise.all(agents.splice(0).map((a) => a.kill())); });

function make(state: string, hooks: Partial<AgentHooks> = {}) {
  const updates: Update[] = [];
  const exits: string[] = [];
  const a = new AgentProcess(harnessFor("claude", { model: null, acpCmd: ["node", FAKE] }),
    { cwd: state, env: { ...process.env, FAKE_AGENT_STATE: state }, paragraph: "Use agentic-ask.", model: null },
    { onUpdate: (u) => updates.push(u), onPermission: async () => null, onExit: (e) => exits.push(e), ...hooks });
  agents.push(a);
  return { a, updates, exits };
}
const texts = (us: Update[]) => us.filter((u) => u.sessionUpdate === "agent_message_chunk").map((u) => (u.content as { text: string }).text);

describe("AgentProcess", () => {
  it("opens a session with bypass and the paragraph, and runs turns", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a, updates } = make(dir);
    await a.start();
    await a.newSession();
    expect(await a.prompt("hello")).toBe("end_turn");
    expect(texts(updates)).toEqual(["echo: hello"]);
    await a.prompt("META");
    const meta = JSON.parse(texts(updates)[1] ?? "{}");
    expect(meta.mode).toBe("bypassPermissions");
    expect(meta.meta.systemPrompt.append).toBe("Use agentic-ask.");
  });

  it("cancels a running turn", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start(); await a.newSession();
    const p = a.prompt("SLEEP:10000");
    setTimeout(() => a.cancel(), 200);
    expect(await p).toBe("cancelled");
  });

  it("passes permission requests to the hook and returns its choice", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const asked: unknown[] = [];
    const { a, updates } = make(dir, { onPermission: async (r) => { asked.push(r); return "reject"; } });
    await a.start(); await a.newSession();
    await a.prompt("PERMISSION:echo x");
    expect(asked).toEqual([{ title: "echo x", command: "echo x", options: [
      { optionId: "allow-once", name: "Yes", kind: "allow_once" },
      { optionId: "allow-always", name: "Always", kind: "allow_always" },
      { optionId: "reject", name: "No", kind: "reject_once" },
    ] }]);
    expect(texts(updates)).toEqual(["permission: reject"]);
  });

  it("loads a session in a new process and drops the replayed history", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const first = make(dir);
    await first.a.start();
    const sid = await first.a.newSession();
    await first.a.prompt("one");
    await first.a.kill();
    const second = make(dir);
    await second.a.start();
    await second.a.loadSession(sid);
    expect(second.updates).toEqual([]);
    await second.a.prompt("HISTORY");
    expect(texts(second.updates)).toEqual(["history: 2"]);
  });

  it("rejects a load of an unknown session", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const { a } = make(dir);
    await a.start();
    await expect(a.loadSession("nope")).rejects.toThrow();
  });

  it("reports an unexpected exit, but not a kill", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-"));
    const crash = make(dir);
    await crash.a.start(); await crash.a.newSession();
    await expect(crash.a.prompt("CRASH")).rejects.toThrow();
    await new Promise((r) => setTimeout(r, 200));
    expect(crash.exits).toEqual(["agent exited with code 3"]);
    const quiet = make(dir);
    await quiet.a.start();
    await quiet.a.kill();
    expect(quiet.exits).toEqual([]);
  });
});
```

- [ ] **Step 8: Run them to see them fail**

Run: `cd bridge && npx vitest run test/agent.test.ts`
Expected: FAIL (modules missing).

- [ ] **Step 9: Write `bridge/src/harness.ts`**

```ts
// Claude and Copilot facts for the bridge (spec §7.1).
import { fileURLToPath } from "node:url";
import type { AgentName } from "./types.js";

export interface SessionCalls {
  setMode(sessionId: string, modeId: string): Promise<void>;
  setConfigOption(sessionId: string, configId: string, value: string): Promise<void>;
}

export interface HarnessSpec {
  name: AgentName;
  command: string[];
  env: Record<string, string>;
  sessionMeta(paragraph: string): Record<string, unknown> | undefined;
  afterSession(calls: SessionCalls, sessionId: string, model: string | null): Promise<void>;
}

// The adapter ships in the bridge's own node_modules (src/ and dist/ sit next to it).
export const CLAUDE_ACP_ENTRY = fileURLToPath(
  new URL("../node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js", import.meta.url),
);

export function harnessFor(name: AgentName, opts: { model: string | null; acpCmd: string[] | null }): HarnessSpec {
  if (name === "claude") {
    return {
      name,
      command: opts.acpCmd ?? ["node", CLAUDE_ACP_ENTRY],
      // One Claude version per image: the adapter runs the image's claude, not its bundled binary.
      env: { CLAUDE_CODE_EXECUTABLE: process.env.CLAUDE_CODE_EXECUTABLE ?? "/usr/local/bin/claude" },
      sessionMeta: (paragraph) => (paragraph ? { systemPrompt: { append: paragraph } } : undefined),
      afterSession: async (calls, sessionId, model) => {
        await calls.setMode(sessionId, "bypassPermissions");
        if (model) await calls.setConfigOption(sessionId, "model", model);
      },
    };
  }
  return {
    name,
    command: opts.acpCmd ?? ["copilot", "--acp", "--allow-all", ...(opts.model ? ["--model", opts.model] : [])],
    env: { COPILOT_AUTO_UPDATE: "false" },
    // Copilot reads the task paragraph from copilot-instructions.md (45-hooks writes it).
    sessionMeta: () => undefined,
    afterSession: async () => {},
  };
}
```

- [ ] **Step 10: Write `bridge/src/agent.ts`**

```ts
// One agent process and its ACP connection (spec §7). Replayed history during session/load is dropped.
import { spawn, type ChildProcess } from "node:child_process";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { HarnessSpec } from "./harness.js";
import type { Update } from "./map.js";
import type { PermissionOption } from "./types.js";

export interface PermissionAsk {
  title: string;
  command: string;
  options: PermissionOption[];
}

export interface AgentHooks {
  onUpdate(u: Update): void;
  onPermission(req: PermissionAsk): Promise<string | null>;
  onExit(error: string): void;
  onStderr?(chunk: string): void;
}

export interface AgentLike {
  start(): Promise<void>;
  newSession(): Promise<string>;
  loadSession(id: string): Promise<void>;
  prompt(text: string): Promise<string>;
  cancel(): void;
  kill(): Promise<void>;
}

export class AgentProcess implements AgentLike {
  private child: ChildProcess | null = null;
  private conn: acp.ClientConnection | null = null;
  private sessionId: string | null = null;
  private loading = false;
  private killing = false;
  private exited: Promise<void> = Promise.resolve();

  constructor(
    private readonly spec: HarnessSpec,
    private readonly opts: { cwd: string; env: NodeJS.ProcessEnv; paragraph: string; model: string | null },
    private readonly hooks: AgentHooks,
  ) {}

  async start(): Promise<void> {
    const [cmd, ...args] = this.spec.command;
    if (!cmd) throw new Error("empty agent command");
    const child = spawn(cmd, args, { cwd: this.opts.cwd, env: { ...this.opts.env, ...this.spec.env }, stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.exited = new Promise((resolve) => {
      child.on("exit", (code, signal) => {
        if (!this.killing) this.hooks.onExit(`agent exited with code ${code ?? signal}`);
        resolve();
      });
      child.on("error", (err) => {
        if (!this.killing) this.hooks.onExit(`agent could not start: ${err.message}`);
        resolve();
      });
    });
    child.stderr?.on("data", (d: Buffer) => this.hooks.onStderr?.(d.toString()));
    const stream = acp.ndJsonStream(
      Writable.toWeb(child.stdin!) as WritableStream<Uint8Array>,
      Readable.toWeb(child.stdout!) as ReadableStream<Uint8Array>,
    );
    this.conn = acp
      .client({ name: "agentic-bridge" })
      .onNotification(acp.methods.client.session.update, (ctx) => {
        if (!this.loading) this.hooks.onUpdate(ctx.params.update as unknown as Update);
      })
      .onRequest(acp.methods.client.session.requestPermission, async (ctx) => {
        const p = ctx.params;
        const raw = p.toolCall.rawInput as { command?: unknown } | undefined;
        const optionId = await this.hooks.onPermission({
          title: p.toolCall.title ?? "",
          command: typeof raw?.command === "string" ? raw.command : "",
          options: p.options.map((o) => ({ optionId: o.optionId, name: o.name, kind: o.kind })),
        });
        return { outcome: optionId ? { outcome: "selected" as const, optionId } : { outcome: "cancelled" as const } };
      })
      .connect(stream);
    await this.conn.agent.request(acp.methods.agent.initialize, {
      protocolVersion: acp.PROTOCOL_VERSION,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    });
  }

  async newSession(): Promise<string> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    const r = await this.agent().request(acp.methods.agent.session.new, {
      cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
    });
    this.sessionId = r.sessionId;
    await this.spec.afterSession(this.calls(), r.sessionId, this.opts.model);
    return r.sessionId;
  }

  async loadSession(id: string): Promise<void> {
    const meta = this.spec.sessionMeta(this.opts.paragraph);
    this.loading = true;
    try {
      await this.agent().request(acp.methods.agent.session.load, {
        sessionId: id, cwd: this.opts.cwd, mcpServers: [], ...(meta ? { _meta: meta } : {}),
      });
    } finally {
      this.loading = false;
    }
    this.sessionId = id;
    await this.spec.afterSession(this.calls(), id, this.opts.model);
  }

  async prompt(text: string): Promise<string> {
    const r = await this.agent().request(acp.methods.agent.session.prompt, {
      sessionId: this.session(), prompt: [{ type: "text", text }],
    });
    return r.stopReason;
  }

  cancel(): void {
    if (this.conn && this.sessionId) void this.conn.agent.notify(acp.methods.agent.session.cancel, { sessionId: this.sessionId });
  }

  async kill(): Promise<void> {
    if (!this.child) return;
    this.killing = true;
    this.conn?.close();
    this.child.kill("SIGTERM");
    const timer = setTimeout(() => this.child?.kill("SIGKILL"), 5000);
    await this.exited;
    clearTimeout(timer);
  }

  private agent(): acp.ClientContext {
    if (!this.conn) throw new Error("agent not started");
    return this.conn.agent;
  }

  private session(): string {
    if (!this.sessionId) throw new Error("no session");
    return this.sessionId;
  }

  private calls() {
    return {
      setMode: async (sessionId: string, modeId: string) => {
        await this.agent().request(acp.methods.agent.session.setMode, { sessionId, modeId });
      },
      setConfigOption: async (sessionId: string, configId: string, value: string) => {
        await this.agent().request(acp.methods.agent.session.setConfigOption, { sessionId, configId, value });
      },
    };
  }
}
```

If tsc rejects a request's parameter or result type (the SDK's generated types are strict), keep the call and adjust the object to the type tsc names; do not cast to `any`.

- [ ] **Step 11: Run tests and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add bridge/src/map.ts bridge/src/harness.ts bridge/src/agent.ts bridge/test/fake-agent.mjs bridge/test/fixtures bridge/test/map.test.ts bridge/test/agent.test.ts
git commit -m "feat: ACP client for both agents: update mapping, permissions, cancel, load without replay"
```

---

### Task 8: API routes, access checks, HTTP and WebSocket server

**Files:**
- Create: `bridge/src/api.ts`, `bridge/src/server.ts`, `bridge/test/api.test.ts`, `bridge/test/server.test.ts`

**Interfaces:**
- Consumes: `task.ts` (`Input`, `Outcome`), `types.ts`.
- Produces:
  - `api.ts`:
    ```ts
    export interface ApiTarget {
      ready(): boolean;
      status(): Record<string, unknown>;
      command(input: Input): Outcome;
      events(since: number, limit: number): TaskEvent[];
    }
    export interface Tokens { task: string; agent: string }
    export interface AccessOptions { hosts: string[]; origins: string[] }
    export interface ApiRequest { method: string; path: string; query: URLSearchParams; headers: Record<string, string | undefined>; body: string }
    export interface ApiResponse { status: number; json?: unknown; ndjson?: unknown[] }
    export const MAX_BODY = 1048576;
    export function checkAccess(headers: Record<string, string | undefined>, tokens: Tokens, opts: AccessOptions): { scope: "task" | "agent" } | ApiResponse;
    export function handle(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): ApiResponse;
    ```
  - `server.ts`: `startServer(o: { port: number; host: string; tokens: Tokens; access: AccessOptions; target: ApiTarget; subscribe(fn: (e: TaskEvent) => void): () => void }): Promise<{ port: number; close(): Promise<void> }>`.

Spec clarification: the `Host` check accepts the loopback names on **any port** (`127.0.0.1`, `localhost`, `[::1]`) plus `AGENTIC_BRIDGE_HOSTS` entries (compared without the port). The bridge cannot know the host port Docker chose, and DNS-rebinding protection only needs the name to be loopback.

- [ ] **Step 1: Write the route tests (failing)**

`bridge/test/api.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { handle, checkAccess, type ApiTarget, type ApiRequest } from "../src/api.js";
import type { Input, Outcome } from "../src/task.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const access = { hosts: ["bridge.internal"], origins: [] as string[] };
function target(outcome: Outcome = { ok: true, effects: [] }) {
  const seen: Input[] = [];
  const t: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(i); return outcome; },
    events: (since, limit) => Array.from({ length: 5 }, (_, k) => ({ seq: k + 1 })).filter((e) => e.seq > since).slice(0, limit) as never,
  };
  return { t, seen };
}
const req = (method: string, path: string, body?: unknown, h: Record<string, string> = {}, query = ""): ApiRequest => ({
  method, path, query: new URLSearchParams(query), body: body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body),
  headers: { host: "127.0.0.1:49153", authorization: `Bearer ${tokens.task}`, ...h },
});

describe("checkAccess", () => {
  it("accepts loopback hosts on any port and listed hosts", () => {
    for (const host of ["127.0.0.1:49153", "localhost:8765", "[::1]:1", "bridge.internal:8765"]) {
      expect(checkAccess({ host, authorization: `Bearer ${tokens.task}` }, tokens, access)).toEqual({ scope: "task" });
    }
  });
  it("refuses other hosts and unlisted origins with 403", () => {
    expect(checkAccess({ host: "evil.example.com", authorization: `Bearer ${tokens.task}` }, tokens, access)).toMatchObject({ status: 403 });
    expect(checkAccess({ host: "127.0.0.1:1", origin: "http://evil.example.com", authorization: `Bearer ${tokens.task}` }, tokens, access)).toMatchObject({ status: 403 });
  });
  it("needs a known bearer token; the agent token has the agent scope", () => {
    expect(checkAccess({ host: "localhost" }, tokens, access)).toMatchObject({ status: 401, json: { error: { code: "unauthorized", message: "unauthorized" } } });
    expect(checkAccess({ host: "localhost", authorization: "Bearer wrong" }, tokens, access)).toMatchObject({ status: 401 });
    expect(checkAccess({ host: "localhost", authorization: `Bearer ${tokens.agent}` }, tokens, access)).toEqual({ scope: "agent" });
  });
});

describe("handle", () => {
  it("POST /prompt passes the text byte-identical and returns 202 with the status", () => {
    const { t, seen } = target();
    const text = 'line one\nline "two" with $HOME, `ticks` and ünïcødé ✓';
    expect(handle(req("POST", "/prompt", { text }), t, tokens, access)).toEqual({ status: 202, json: { state: "idle" } });
    expect(seen).toEqual([{ kind: "userPrompt", text }]);
  });

  it("maps outcomes to status codes with one error body", () => {
    for (const [code, status] of [["conflict", 409], ["not_found", 404], ["bad_request", 400]] as const) {
      const { t } = target({ ok: false, code, message: "m" });
      expect(handle(req("POST", "/prompt", { text: "x" }), t, tokens, access)).toEqual({ status, json: { error: { code, message: "m" } } });
    }
  });

  it("validates bodies", () => {
    const { t } = target();
    expect(handle(req("POST", "/prompt", "{"), t, tokens, access)).toMatchObject({ status: 400, json: { error: { message: "body is not JSON" } } });
    expect(handle(req("POST", "/prompt", { text: 3 }), t, tokens, access)).toMatchObject({ status: 400 });
    expect(handle(req("POST", "/answer", { text: "x", grant: "push" }), t, tokens, access)).toMatchObject({ status: 400 });
    expect(handle(req("POST", "/prompt", "x".repeat(1048577)), t, tokens, access)).toMatchObject({ status: 400, json: { error: { message: "body too large" } } });
  });

  it("routes answer, cancel and stop", () => {
    const { t, seen } = target();
    handle(req("POST", "/answer", { question: "Q2", text: "yes", grant: ["push"] }), t, tokens, access);
    handle(req("POST", "/answer", { text: "no" }), t, tokens, access);
    handle(req("POST", "/cancel"), t, tokens, access);
    handle(req("POST", "/stop"), t, tokens, access);
    expect(seen).toEqual([
      { kind: "answer", question: "Q2", text: "yes", grant: ["push"] },
      { kind: "answer", text: "no", grant: [] },
      { kind: "cancel" },
      { kind: "stop" },
    ]);
  });

  it("GET /events returns NDJSON after the cursor, with a limit", () => {
    const { t } = target();
    expect(handle(req("GET", "/events", undefined, {}, "since=2&limit=2"), t, tokens, access)).toEqual({ status: 200, ndjson: [{ seq: 3 }, { seq: 4 }] });
    expect(handle(req("GET", "/events", undefined, {}, "since=x"), t, tokens, access)).toMatchObject({ status: 400 });
  });

  it("the agent token may only ask and report gate refusals", () => {
    const { t, seen } = target({ ok: true, effects: [], value: { id: "Q1" } });
    const agent = { authorization: `Bearer ${tokens.agent}` };
    expect(handle(req("POST", "/ask", { text: "Which DB?", options: ["pg"], recommend: "pg" }, agent), t, tokens, access)).toEqual({ status: 201, json: { id: "Q1" } });
    expect(handle(req("POST", "/gate", { rule: "gate", command: "git push" }, agent), t, tokens, access)).toEqual({ status: 204 });
    expect(handle(req("POST", "/answer", { text: "yes" }, agent), t, tokens, access)).toMatchObject({ status: 403 });
    expect(handle(req("GET", "/status", undefined, agent), t, tokens, access)).toMatchObject({ status: 403 });
    expect(seen).toEqual([
      { kind: "ask", text: "Which DB?", options: ["pg"], recommend: "pg" },
      { kind: "gate", rule: "gate", command: "git push" },
    ]);
  });

  it("answers 503 until ready and 404 for unknown routes", () => {
    const { t } = target();
    expect(handle(req("GET", "/nope"), t, tokens, access)).toMatchObject({ status: 404 });
    expect(handle(req("GET", "/status"), { ...t, ready: () => false }, tokens, access)).toMatchObject({ status: 503, json: { error: { code: "starting" } } });
  });
});
```

`bridge/test/server.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { startServer } from "../src/server.js";
import type { ApiTarget } from "../src/api.js";
import type { TaskEvent } from "../src/types.js";

const tokens = { task: "task-token-0123456789", agent: "agent-token-0123456789" };
const ev = (seq: number): TaskEvent => ({ seq, ts: "t", task: "T-1", session: null, agent: "claude", type: "state", data: { state: "idle" } });
let close: (() => Promise<void>) | null = null;
afterEach(async () => { await close?.(); close = null; });

async function serve(stored: TaskEvent[], seen: string[] = []) {
  const listeners = new Set<(e: TaskEvent) => void>();
  const target: ApiTarget = {
    ready: () => true,
    status: () => ({ state: "idle" }),
    command: (i) => { seen.push(JSON.stringify(i)); return { ok: true, effects: [] }; },
    events: (since, limit) => stored.filter((e) => e.seq > since).slice(0, limit),
  };
  const s = await startServer({ port: 0, host: "127.0.0.1", tokens, access: { hosts: [], origins: [] }, target,
    subscribe: (fn) => { listeners.add(fn); return () => listeners.delete(fn); } });
  close = s.close;
  return { port: s.port, push: (e: TaskEvent) => { stored.push(e); listeners.forEach((f) => f(e)); } };
}

describe("server", () => {
  it("serves JSON with the token and refuses without it", async () => {
    const { port } = await serve([]);
    const ok = await fetch(`http://127.0.0.1:${port}/status`, { headers: { authorization: `Bearer ${tokens.task}` } });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ state: "idle" });
    expect((await fetch(`http://127.0.0.1:${port}/status`)).status).toBe(401);
  });

  it("refuses a body over 1 MiB with 400 body too large", async () => {
    const { port } = await serve([]);
    const r = await fetch(`http://127.0.0.1:${port}/prompt`, { method: "POST", body: JSON.stringify({ text: "x".repeat(1048600) }),
      headers: { authorization: `Bearer ${tokens.task}`, "content-type": "application/json" } });
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: { code: "bad_request", message: "body too large" } });
  });

  it("streams the backlog after the cursor, then live events, over WebSocket", async () => {
    const { port, push } = await serve([ev(1), ev(2), ev(3)]);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events?since=1`, { headers: { authorization: `Bearer ${tokens.task}` } });
    const got: number[] = [];
    await new Promise<void>((resolve) => {
      ws.on("message", (m) => {
        got.push(JSON.parse(m.toString()).seq);
        if (got.length === 2) push(ev(4));
        if (got.length === 3) resolve();
      });
    });
    ws.close();
    expect(got).toEqual([2, 3, 4]);
  });

  it("refuses a WebSocket without the task token", async () => {
    const { port } = await serve([]);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/events`, { headers: { authorization: `Bearer ${tokens.agent}` } });
    const status = await new Promise<number>((resolve) => ws.on("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0)));
    expect(status).toBe(403);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd bridge && npx vitest run test/api.test.ts test/server.test.ts`
Expected: FAIL (modules missing).

- [ ] **Step 3: Write `bridge/src/api.ts`**

```ts
// Routes of API version 1 as plain functions (spec §8.2): transport-neutral, so an outbound mode
// could serve them over another connection.
import { timingSafeEqual } from "node:crypto";
import type { Input, Outcome } from "./task.js";
import type { TaskEvent } from "./types.js";

export interface ApiTarget {
  ready(): boolean;
  status(): Record<string, unknown>;
  command(input: Input): Outcome;
  events(since: number, limit: number): TaskEvent[];
}
export interface Tokens { task: string; agent: string }
export interface AccessOptions { hosts: string[]; origins: string[] }
export interface ApiRequest {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: Record<string, string | undefined>;
  body: string;
}
export interface ApiResponse { status: number; json?: unknown; ndjson?: unknown[] }

export const MAX_BODY = 1048576;
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);
const STATUS = { conflict: 409, not_found: 404, bad_request: 400 } as const;

const err = (status: number, code: string, message: string): ApiResponse => ({ status, json: { error: { code, message } } });
const hostname = (h: string): string => (h.startsWith("[") ? h.slice(0, h.indexOf("]") + 1) : h.split(":")[0] ?? "");

function same(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function checkAccess(headers: Record<string, string | undefined>, tokens: Tokens, opts: AccessOptions): { scope: "task" | "agent" } | ApiResponse {
  const host = hostname(headers.host ?? "");
  if (!LOOPBACK.has(host) && !opts.hosts.map(hostname).includes(host)) return err(403, "forbidden", "host not allowed");
  if (headers.origin !== undefined && !opts.origins.includes(headers.origin)) return err(403, "forbidden", "origin not allowed");
  const m = /^Bearer (.+)$/.exec(headers.authorization ?? "");
  if (m?.[1] && same(m[1], tokens.task)) return { scope: "task" };
  if (m?.[1] && same(m[1], tokens.agent)) return { scope: "agent" };
  return err(401, "unauthorized", "unauthorized");
}

const isStr = (v: unknown): v is string => typeof v === "string";
const isStrArray = (v: unknown): v is string[] => Array.isArray(v) && v.every(isStr);

function outcome(o: Outcome, ok: () => ApiResponse): ApiResponse {
  return o.ok ? ok() : err(STATUS[o.code], o.code, o.message);
}

export function handle(req: ApiRequest, target: ApiTarget, tokens: Tokens, opts: AccessOptions): ApiResponse {
  const access = checkAccess(req.headers, tokens, opts);
  if ("status" in access) return access;
  const route = `${req.method} ${req.path}`;
  if (access.scope === "agent" && route !== "POST /ask" && route !== "POST /gate") return err(403, "forbidden", "this token may only ask");
  if (!target.ready()) return err(503, "starting", "the bridge is starting");
  if (req.body.length > MAX_BODY) return err(400, "bad_request", "body too large");
  let body: Record<string, unknown> = {};
  if (req.method === "POST" && req.body.trim()) {
    try {
      const parsed: unknown = JSON.parse(req.body);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return err(400, "bad_request", "body must be a JSON object");
      body = parsed as Record<string, unknown>;
    } catch {
      return err(400, "bad_request", "body is not JSON");
    }
  }
  const status = () => ({ status: 202, json: target.status() });
  switch (route) {
    case "GET /status":
      return { status: 200, json: target.status() };
    case "GET /events": {
      const since = Number(req.query.get("since") ?? "0");
      const limit = Number(req.query.get("limit") ?? "1000");
      if (!Number.isInteger(since) || since < 0 || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
        return err(400, "bad_request", "since must be an integer >= 0 and limit 1..1000");
      }
      return { status: 200, ndjson: target.events(since, limit) };
    }
    case "POST /prompt":
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      return outcome(target.command({ kind: "userPrompt", text: body.text }), status);
    case "POST /answer": {
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      if (body.question !== undefined && !isStr(body.question)) return err(400, "bad_request", "question must be a string");
      if (body.grant !== undefined && !isStrArray(body.grant)) return err(400, "bad_request", "grant must be a list of strings");
      const input: Input = { kind: "answer", text: body.text, grant: body.grant ?? [], ...(body.question ? { question: body.question } : {}) };
      return outcome(target.command(input), status);
    }
    case "POST /cancel":
      return outcome(target.command({ kind: "cancel" }), status);
    case "POST /stop":
      return outcome(target.command({ kind: "stop" }), status);
    case "POST /ask": {
      if (!isStr(body.text)) return err(400, "bad_request", "text must be a string");
      if (body.options !== undefined && !isStrArray(body.options)) return err(400, "bad_request", "options must be a list of strings");
      if (body.recommend !== undefined && body.recommend !== null && !isStr(body.recommend)) return err(400, "bad_request", "recommend must be a string");
      const o = target.command({ kind: "ask", text: body.text, options: body.options ?? [], recommend: body.recommend ?? null });
      return outcome(o, () => ({ status: 201, json: o.ok ? o.value : undefined }));
    }
    case "POST /gate":
      target.command({ kind: "gate", rule: isStr(body.rule) ? body.rule : "", command: isStr(body.command) ? body.command : "" });
      return { status: 204 };
    default:
      return err(404, "not_found", "no such route");
  }
}
```

- [ ] **Step 4: Write `bridge/src/server.ts`**

```ts
// HTTP and WebSocket transport for the API (spec §8.1). Request headers and bodies are never logged.
import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { checkAccess, handle, MAX_BODY, type AccessOptions, type ApiResponse, type ApiTarget, type Tokens } from "./api.js";
import type { TaskEvent } from "./types.js";

export interface ServerOptions {
  port: number;
  host: string;
  tokens: Tokens;
  access: AccessOptions;
  target: ApiTarget;
  subscribe(fn: (e: TaskEvent) => void): () => void;
}

const headersOf = (req: IncomingMessage): Record<string, string | undefined> =>
  Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, Array.isArray(v) ? v.join(",") : v]));

export function startServer(o: ServerOptions): Promise<{ port: number; close(): Promise<void> }> {
  const server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) tooLarge = true;
      else chunks.push(c);
    });
    req.on("end", () => {
      const url = new URL(req.url ?? "/", "http://bridge");
      const r: ApiResponse = tooLarge
        ? { status: 400, json: { error: { code: "bad_request", message: "body too large" } } }
        : handle({ method: req.method ?? "GET", path: url.pathname, query: url.searchParams, headers: headersOf(req),
            body: Buffer.concat(chunks).toString("utf8") }, o.target, o.tokens, o.access);
      if (r.ndjson) {
        res.writeHead(r.status, { "content-type": "application/x-ndjson" });
        res.end(r.ndjson.map((e) => JSON.stringify(e) + "\n").join(""));
      } else if (r.json !== undefined) {
        res.writeHead(r.status, { "content-type": "application/json" });
        res.end(JSON.stringify(r.json));
      } else {
        res.writeHead(r.status);
        res.end();
      }
    });
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://bridge");
    const access = checkAccess(headersOf(req), o.tokens, o.access);
    const refuse = (status: number) => { socket.write(`HTTP/1.1 ${status} Refused\r\nConnection: close\r\n\r\n`); socket.destroy(); };
    if ("status" in access) return refuse(access.status);
    if (access.scope !== "task") return refuse(403);
    if (url.pathname !== "/events") return refuse(404);
    const since = Number(url.searchParams.get("since") ?? "0");
    wss.handleUpgrade(req, socket, head, (ws) => follow(ws, Number.isInteger(since) && since >= 0 ? since : 0));
  });

  // follow: the backlog after SINCE, then live events; events arriving during the backlog are queued.
  function follow(ws: WebSocket, since: number): void {
    let last = since;
    let live = false;
    const queue: TaskEvent[] = [];
    const sendEvent = (e: TaskEvent) => { if (e.seq > last) { ws.send(JSON.stringify(e)); last = e.seq; } };
    const unsubscribe = o.subscribe((e) => (live ? sendEvent(e) : queue.push(e)));
    for (const e of o.target.events(since, Number.MAX_SAFE_INTEGER)) sendEvent(e);
    live = true;
    queue.splice(0).forEach(sendEvent);
    const ping = setInterval(() => ws.ping(), 30000);
    ws.on("close", () => { clearInterval(ping); unsubscribe(); });
  }

  return new Promise((resolve) => {
    server.listen(o.port, o.host, () => {
      resolve({
        port: (server.address() as AddressInfo).port,
        close: () => new Promise<void>((done) => { wss.clients.forEach((c) => c.terminate()); server.close(() => done()); }),
      });
    });
  });
}
```

- [ ] **Step 5: Run tests and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bridge/src/api.ts bridge/src/server.ts bridge/test/api.test.ts bridge/test/server.test.ts
git commit -m "feat: bridge API v1: routes, tokens and scopes, Host and Origin checks, WebSocket events"
```

---

### Task 9: Notify, config, the orchestrator, the entry point and the follow client

**Files:**
- Create: `bridge/src/notify.ts`, `bridge/src/config.ts`, `bridge/src/bridge.ts`, `bridge/src/main.ts`, `bridge/src/follow.ts`, `bridge/test/notify.test.ts`, `bridge/test/config.test.ts`, `bridge/test/bridge.test.ts`, `bridge/test/follow.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 4–8.
- Produces:
  - `config.ts`: `class ConfigError extends Error`; `interface Config { taskDir: string; task: string; project: string; agent: AgentName; model: string | null; branch: string | null; prompt: string | null; idleTimeoutMs: number; port: number; tokens: Tokens; hosts: string[]; origins: string[]; webhook: string | null; eventsDir: string; acpCmd: string[] | null; work: string; allowed: string[]; paragraphFile: string }`; `loadConfig(env: NodeJS.ProcessEnv): Config`; `agentEnvironment(env: NodeJS.ProcessEnv, cfg: Config): NodeJS.ProcessEnv`.
  - `notify.ts`: `interface NotifyOptions { eventsLog: string | null; webhook: string | null; project: string; log(line: string): void; fetch?: typeof fetch; retryDelayMs?: number }`; `class Notifier { logState(rec: TaskRecord): void; webhook(rec: TaskRecord, q: Question | null): Promise<void> }`; `notifyPayload(rec: TaskRecord, q: Question | null, ts: string): Record<string, unknown>`.
  - `bridge.ts`: `class BridgeError extends Error`; `interface BridgeDeps { store: Store; config: Config; notifier: Notifier; paragraph: string; agentFactory(hooks: AgentHooks): AgentLike; exit(code: number): void; now(): string; log(line: string): void }`; `class Bridge implements ApiTarget { boot(): void; subscribe(fn): () => void; shutdownAgent(): Promise<void> }`.
  - `follow.ts`: `formatEvent(e: TaskEvent): string`; `follow(opts: { url: string; token: string; since: number; raw: boolean; forever: boolean; out: (s: string) => void }): Promise<number>` (resolves with the exit code).
  - `main.ts`: `agentic-bridge` (serve) and `agentic-bridge follow [--since N] [--raw] [--forever]`.

Environment read by `loadConfig` (all optional unless marked): `AGENTIC_TASK_TOKEN`, `AGENTIC_AGENT_TOKEN` (required, 16+ characters), `AGENTIC_TASK_DIR` (`/task`), `AGENTIC_TASK_ID` (`task`), `AGENTIC_PROJECT` (`project`), `AGENTIC_AGENT` (`claude`; `claude` or `copilot`), `AGENTIC_MODEL`, `AGENTIC_BRANCH`, `AGENTIC_PROMPT`, `AGENTIC_IDLE_TIMEOUT` (seconds, `900`), `AGENTIC_BRIDGE_PORT` (`8765`), `AGENTIC_BRIDGE_HOSTS`, `AGENTIC_BRIDGE_ORIGINS` (comma-separated), `AGENTIC_NOTIFY_WEBHOOK`, `AGENTIC_EVENTS_DIR` (`/events`), `AGENTIC_ACP_CMD` (JSON array), `AGENTIC_WORK` (`/work`), `AGENTIC_ALLOWED_ACTIONS` (comma-separated, the initial grants), `AGENTIC_DIR` (`/opt/agentic`; the paragraph is `$AGENTIC_DIR/task/task-prompt.md`).

- [ ] **Step 1: Write the config and notify tests (failing)**

`bridge/test/config.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { agentEnvironment, loadConfig } from "../src/config.js";

const base = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789" };

describe("loadConfig", () => {
  it("has defaults for everything but the tokens", () => {
    const c = loadConfig(base);
    expect(c).toMatchObject({ taskDir: "/task", agent: "claude", port: 8765, idleTimeoutMs: 900000, eventsDir: "/events",
      work: "/work", acpCmd: null, allowed: [], hosts: [], origins: [], webhook: null, paragraphFile: "/opt/agentic/task/task-prompt.md" });
  });

  it("refuses missing or short tokens, an unknown agent and a bad ACP command", () => {
    expect(() => loadConfig({})).toThrow("AGENTIC_TASK_TOKEN");
    expect(() => loadConfig({ ...base, AGENTIC_AGENT_TOKEN: "short" })).toThrow("AGENTIC_AGENT_TOKEN");
    expect(() => loadConfig({ ...base, AGENTIC_AGENT: "gpt" })).toThrow("AGENTIC_AGENT");
    expect(() => loadConfig({ ...base, AGENTIC_ACP_CMD: "node x" })).toThrow("AGENTIC_ACP_CMD");
    expect(() => loadConfig({ ...base, AGENTIC_IDLE_TIMEOUT: "soon" })).toThrow("AGENTIC_IDLE_TIMEOUT");
  });

  it("parses lists and the ACP command", () => {
    const c = loadConfig({ ...base, AGENTIC_ALLOWED_ACTIONS: "push, open-pr", AGENTIC_BRIDGE_HOSTS: "a:1,b", AGENTIC_ACP_CMD: '["node","/f.mjs"]', AGENTIC_IDLE_TIMEOUT: "3" });
    expect(c.allowed).toEqual(["push", "open-pr"]);
    expect(c.hosts).toEqual(["a:1", "b"]);
    expect(c.acpCmd).toEqual(["node", "/f.mjs"]);
    expect(c.idleTimeoutMs).toBe(3000);
  });
});

describe("agentEnvironment", () => {
  it("gives the agent the bridge URL and its own token, never the task token", () => {
    const env = agentEnvironment({ ...base, PATH: "/bin" }, loadConfig(base));
    expect(env.AGENTIC_TASK_TOKEN).toBeUndefined();
    expect(env.AGENTIC_AGENT_TOKEN).toBe("agent-token-0123456789");
    expect(env.AGENTIC_BRIDGE_URL).toBe("http://127.0.0.1:8765");
    expect(env.AGENTIC_TASK_DIR).toBe("/task");
    expect(env.PATH).toBe("/bin");
  });
});
```

`bridge/test/notify.test.ts`:

```ts
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Notifier, notifyPayload } from "../src/notify.js";
import type { Question, TaskRecord } from "../src/types.js";

const rec = { version: 1, task: "T-1", project: "demo", agent: "claude", model: null, state: "waiting", reason: "question Q1",
  session: "s", branch: "b", created: "t", updated: "t", seq: 3, allowed_actions: [], inbox: [], summary: "Need a DB", stopped_by_user: false } as TaskRecord;
const q: Question = { id: "Q1", source: "ask", text: "Which DB?", options: ["pg"], recommendation: "pg", asked: "t", status: "open" };

describe("notify", () => {
  it("builds the payload with a reply hint", () => {
    expect(notifyPayload(rec, q, "now")).toEqual({ task: "T-1", project: "demo", state: "waiting",
      question: { id: "Q1", text: "Which DB?", options: ["pg"], recommendation: "pg" }, summary: "Need a DB",
      reply: 'agentic answer T-1 Q1 "…"', ts: "now" });
    expect(notifyPayload({ ...rec, state: "idle" }, null, "now")).toMatchObject({ question: null, reply: 'agentic send T-1 "…"' });
  });

  it("appends every state change to the project events log as one line", () => {
    const f = join(mkdtempSync(join(tmpdir(), "n-")), "events.jsonl");
    const n = new Notifier({ eventsLog: f, webhook: null, project: "demo", log: () => {} });
    n.logState(rec); n.logState({ ...rec, state: "idle", reason: "x".repeat(5000) });
    const lines = readFileSync(f, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(lines.map((l) => l.state)).toEqual(["waiting", "idle"]);
    expect(lines[1].reason.length).toBeLessThanOrEqual(500);
  });

  it("posts the webhook, retries once, and logs a failure without throwing", async () => {
    const calls: string[] = [];
    const logs: string[] = [];
    let fail = 2;
    const fetchStub = (async (url: string, init: RequestInit) => {
      calls.push(`${url} ${init.body}`);
      if (fail-- > 0) throw new Error("down");
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    const n = new Notifier({ eventsLog: null, webhook: "https://hooks.example.com/x", project: "demo", log: (m) => logs.push(m), fetch: fetchStub, retryDelayMs: 1 });
    await n.webhook(rec, q);
    expect(calls).toHaveLength(2);
    expect(logs.join()).toContain("webhook failed");
    fail = 0;
    await n.webhook(rec, q);
    expect(calls).toHaveLength(3);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd bridge && npx vitest run test/config.test.ts test/notify.test.ts`
Expected: FAIL (modules missing).

- [ ] **Step 3: Write `bridge/src/config.ts`**

```ts
// The bridge's environment (spec §8.1, §12).
import type { Tokens } from "./api.js";
import type { AgentName } from "./types.js";

export class ConfigError extends Error {}

export interface Config {
  taskDir: string;
  task: string;
  project: string;
  agent: AgentName;
  model: string | null;
  branch: string | null;
  prompt: string | null;
  idleTimeoutMs: number;
  port: number;
  tokens: Tokens;
  hosts: string[];
  origins: string[];
  webhook: string | null;
  eventsDir: string;
  acpCmd: string[] | null;
  work: string;
  allowed: string[];
  paragraphFile: string;
}

const list = (v: string | undefined): string[] => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const opt = (v: string | undefined): string | null => (v && v.trim() ? v : null);

function token(env: NodeJS.ProcessEnv, name: string): string {
  const v = env[name] ?? "";
  if (v.length < 16) throw new ConfigError(`${name} must be set to a random token of 16 or more characters`);
  return v;
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const tokens = { task: token(env, "AGENTIC_TASK_TOKEN"), agent: token(env, "AGENTIC_AGENT_TOKEN") };
  const agent = env.AGENTIC_AGENT ?? "claude";
  if (agent !== "claude" && agent !== "copilot") throw new ConfigError(`AGENTIC_AGENT must be claude or copilot, not ${agent}`);
  const idle = Number(env.AGENTIC_IDLE_TIMEOUT ?? "900");
  if (!Number.isFinite(idle) || idle <= 0) throw new ConfigError("AGENTIC_IDLE_TIMEOUT must be a number of seconds");
  let acpCmd: string[] | null = null;
  if (opt(env.AGENTIC_ACP_CMD)) {
    try {
      const v: unknown = JSON.parse(env.AGENTIC_ACP_CMD ?? "");
      if (!Array.isArray(v) || v.length === 0 || !v.every((x) => typeof x === "string")) throw new Error();
      acpCmd = v as string[];
    } catch {
      throw new ConfigError('AGENTIC_ACP_CMD must be a JSON array of strings, for example ["node","/fake.mjs"]');
    }
  }
  return {
    taskDir: env.AGENTIC_TASK_DIR ?? "/task",
    task: env.AGENTIC_TASK_ID ?? "task",
    project: env.AGENTIC_PROJECT ?? "project",
    agent,
    model: opt(env.AGENTIC_MODEL),
    branch: opt(env.AGENTIC_BRANCH),
    prompt: opt(env.AGENTIC_PROMPT),
    idleTimeoutMs: idle * 1000,
    port: Number(env.AGENTIC_BRIDGE_PORT ?? "8765"),
    tokens,
    hosts: list(env.AGENTIC_BRIDGE_HOSTS),
    origins: list(env.AGENTIC_BRIDGE_ORIGINS),
    webhook: opt(env.AGENTIC_NOTIFY_WEBHOOK),
    eventsDir: env.AGENTIC_EVENTS_DIR ?? "/events",
    acpCmd,
    work: env.AGENTIC_WORK ?? "/work",
    allowed: list(env.AGENTIC_ALLOWED_ACTIONS),
    paragraphFile: `${env.AGENTIC_DIR ?? "/opt/agentic"}/task/task-prompt.md`,
  };
}

// agentEnvironment: what the agent process sees: the ask channel, never the task token.
export function agentEnvironment(env: NodeJS.ProcessEnv, cfg: Config): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = { ...env };
  delete out.AGENTIC_TASK_TOKEN;
  out.AGENTIC_AGENT_TOKEN = cfg.tokens.agent;
  out.AGENTIC_BRIDGE_URL = `http://127.0.0.1:${cfg.port}`;
  out.AGENTIC_TASK_DIR = cfg.taskDir;
  return out;
}
```

- [ ] **Step 4: Write `bridge/src/notify.ts`**

```ts
// Notify, version 1 (spec §10): the project events log and a webhook. Failures never block.
import { appendFileSync } from "node:fs";
import type { Question, TaskRecord } from "./types.js";

export interface NotifyOptions {
  eventsLog: string | null;
  webhook: string | null;
  project: string;
  log(line: string): void;
  fetch?: typeof fetch;
  retryDelayMs?: number;
}

export function notifyPayload(rec: TaskRecord, q: Question | null, ts: string): Record<string, unknown> {
  return {
    task: rec.task,
    project: rec.project,
    state: rec.state,
    question: q ? { id: q.id, text: q.text, options: q.options, recommendation: q.recommendation } : null,
    summary: rec.summary,
    reply: q ? `agentic answer ${rec.task} ${q.id} "…"` : `agentic send ${rec.task} "…"`,
    ts,
  };
}

export class Notifier {
  constructor(private readonly o: NotifyOptions) {}

  logState(rec: TaskRecord): void {
    if (!this.o.eventsLog) return;
    const line = JSON.stringify({ ts: new Date().toISOString(), task: rec.task, project: rec.project, state: rec.state, reason: rec.reason.slice(0, 500) });
    try {
      appendFileSync(this.o.eventsLog, line + "\n");
    } catch (e) {
      this.o.log(`events log failed: ${(e as Error).message}`);
    }
  }

  async webhook(rec: TaskRecord, q: Question | null): Promise<void> {
    if (!this.o.webhook) return;
    const f = this.o.fetch ?? fetch;
    const body = JSON.stringify(notifyPayload(rec, q, new Date().toISOString()));
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await f(this.o.webhook, { method: "POST", body, headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(5000) });
        if (r.ok) return;
        throw new Error(`HTTP ${r.status}`);
      } catch (e) {
        if (attempt === 1) this.o.log(`webhook failed: ${(e as Error).message}`);
        else await new Promise((r) => setTimeout(r, this.o.retryDelayMs ?? 1000));
      }
    }
  }
}
```

- [ ] **Step 5: Run the config and notify tests**

Run: `cd bridge && npx vitest run test/config.test.ts test/notify.test.ts`
Expected: PASS.

- [ ] **Step 6: Write the orchestrator tests (failing)**

`bridge/test/bridge.test.ts` runs the real `Bridge`, `AgentProcess`, `Store` and server against the fake agent:

```ts
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { AgentProcess } from "../src/agent.js";
import { Bridge } from "../src/bridge.js";
import { agentEnvironment, loadConfig, type Config } from "../src/config.js";
import { harnessFor } from "../src/harness.js";
import { Notifier } from "../src/notify.js";
import { makeRedactor } from "../src/redact.js";
import { startServer } from "../src/server.js";
import { Store } from "../src/store.js";
import type { State, TaskEvent } from "../src/types.js";

const FAKE = fileURLToPath(new URL("./fake-agent.mjs", import.meta.url));
const running: Array<{ bridge: Bridge; close(): Promise<void> }> = [];
afterEach(async () => { for (const r of running.splice(0)) { await r.bridge.shutdownAgent(); await r.close(); } });

async function start(dir: string, extra: Record<string, string> = {}) {
  const exits: number[] = [];
  const env = { AGENTIC_TASK_TOKEN: "task-token-0123456789", AGENTIC_AGENT_TOKEN: "agent-token-0123456789",
    AGENTIC_TASK_DIR: dir, AGENTIC_TASK_ID: "T-1", AGENTIC_PROJECT: "demo", AGENTIC_ACP_CMD: JSON.stringify(["node", FAKE]),
    AGENTIC_BRIDGE_PORT: "0", AGENTIC_WORK: dir, AGENTIC_EVENTS_DIR: join(dir, "no-events"), ...extra };
  const cfg: Config = loadConfig(env);
  const store = new Store(dir, makeRedactor([cfg.tokens.task, cfg.tokens.agent]));
  let agentEnv: NodeJS.ProcessEnv = {};
  const bridge = new Bridge({
    store, config: cfg, paragraph: "Use agentic-ask.",
    notifier: new Notifier({ eventsLog: null, webhook: null, project: "demo", log: () => {} }),
    agentFactory: (hooks) => new AgentProcess(harnessFor("claude", { model: null, acpCmd: cfg.acpCmd }),
      { cwd: dir, env: { ...agentEnv, FAKE_AGENT_STATE: join(dir, "fake") }, paragraph: "Use agentic-ask.", model: null }, hooks),
    exit: (code) => exits.push(code), now: () => new Date().toISOString(), log: () => {},
  });
  const server = await startServer({ port: 0, host: "127.0.0.1", tokens: cfg.tokens, access: { hosts: [], origins: [] },
    target: bridge, subscribe: (fn) => bridge.subscribe(fn) });
  agentEnv = agentEnvironment({ ...process.env }, { ...cfg, port: server.port });
  running.push({ bridge, close: server.close });
  bridge.boot();
  return { bridge, exits, store, port: server.port };
}

function waitState(bridge: Bridge, ...states: State[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const check = () => states.includes(bridge.status().state as State);
    if (check()) return resolve();
    const t = setTimeout(() => reject(new Error(`timeout waiting for ${states.join("|")}, state ${String(bridge.status().state)}`)), 10000);
    const off = bridge.subscribe(() => { if (check()) { clearTimeout(t); off(); resolve(); } });
  });
}
const finals = (store: Store) => store.readEvents(0).filter((e: TaskEvent) => e.type === "message" && e.data.role === "agent" && e.data.final).map((e) => e.data.text);
function taskDir(prompt = "Fix the login bug") {
  const dir = mkdtempSync(join(tmpdir(), "bridge-"));
  writeFileSync(join(dir, "prompt.md"), prompt);
  return dir;
}

describe("Bridge", () => {
  it("runs the first prompt to idle and records events, transcript and summary", async () => {
    const dir = taskDir();
    const { bridge, store } = await start(dir);
    await waitState(bridge, "idle");
    expect(store.readEvents(0).filter((e) => e.type === "state").map((e) => e.data.state)).toEqual(["starting", "running", "idle"]);
    expect(finals(store)).toEqual(["echo: Fix the login bug"]);
    expect(bridge.status()).toMatchObject({ state: "idle", summary: "echo: Fix the login bug", inbox: 0, questions: [] });
    expect(readFileSync(join(dir, "transcript.md"), "utf8")).toContain("> Fix the login bug");
  });

  it("asks over HTTP with the agent token, waits, and delivers an answer with a grant", async () => {
    const { bridge, store } = await start(taskDir("ASK:Which DB?"));
    await waitState(bridge, "waiting");
    expect(bridge.status().questions).toMatchObject([{ id: "Q1", text: "Which DB?", source: "ask" }]);
    expect(bridge.command({ kind: "answer", text: "pg", grant: ["push"] })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(finals(store).at(-1)).toBe("echo: Answer to Q1: pg\nAllowed for this task: push.");
    expect(JSON.parse(readFileSync(join(store.dir, "state.json"), "utf8")).allowed_actions).toEqual(["push"]);
  });

  it("cancels a running turn", async () => {
    const { bridge, store } = await start(taskDir("SLEEP:20000"));
    await waitState(bridge, "running");
    await new Promise((r) => setTimeout(r, 300));
    expect(bridge.command({ kind: "cancel" })).toMatchObject({ ok: true });
    await waitState(bridge, "idle");
    expect(bridge.status().reason).toBe("cancelled");
    expect(store.readEvents(0).some((e) => e.type === "tool")).toBe(true);
  });

  it("suspends after the idle timeout, exits 0, and resumes the session in a new bridge without replay", async () => {
    const dir = taskDir();
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    await waitState(a.bridge, "suspended");
    expect(a.exits).toEqual([0]);
    const b = await start(dir);
    expect(b.bridge.status().state).toBe("suspended");
    expect(b.bridge.command({ kind: "userPrompt", text: "HISTORY" })).toMatchObject({ ok: true });
    await waitState(b.bridge, "idle");
    expect(finals(b.store)).toEqual(["echo: Fix the login bug", "history: 2"]);
  });

  it("falls back to a new session seeded with the task history when the session is gone", async () => {
    const dir = taskDir();
    const a = await start(dir, { AGENTIC_IDLE_TIMEOUT: "0.3" });
    await waitState(a.bridge, "suspended");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    writeFileSync(join(dir, "state.json"), JSON.stringify({ ...rec, session: "gone" }));
    const b = await start(dir);
    b.bridge.command({ kind: "userPrompt", text: "go on" });
    await waitState(b.bridge, "idle");
    expect(b.store.readEvents(0).some((e) => e.type === "error" && String(e.data.message).includes("could not be loaded"))).toBe(true);
    expect(String(finals(b.store).at(-1))).toMatch(/^echo: Original task:\nFix the login bug/);
  });

  it("stops: cancels, ends the agent, exits 0", async () => {
    const { bridge, exits } = await start(taskDir("SLEEP:20000"));
    await waitState(bridge, "running");
    bridge.command({ kind: "stop" });
    expect(bridge.status()).toMatchObject({ state: "stopped", stopped_by_user: true });
    expect(exits).toEqual([0]);
  });

  it("fails and exits 1 when the agent crashes", async () => {
    const { bridge, exits } = await start(taskDir("CRASH"));
    await waitState(bridge, "failed");
    expect(exits).toEqual([1]);
  });

  it("a record left running is interrupted at boot and spawns nothing", async () => {
    const dir = taskDir();
    const a = await start(dir);
    await waitState(a.bridge, "idle");
    const rec = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    writeFileSync(join(dir, "state.json"), JSON.stringify({ ...rec, state: "running" }));
    const b = await start(dir);
    expect(b.bridge.status().state).toBe("interrupted");
  });

  // Review Focus 5
  it.skipIf(process.getuid?.() === 0)("refuses to boot in a directory it cannot write, naming it", async () => {
    const dir = taskDir();
    chmodSync(dir, 0o500);
    await expect(start(dir)).rejects.toThrow(dir);
    chmodSync(dir, 0o700);
  });

  it("refuses to boot a fresh task without a prompt", async () => {
    const dir = mkdtempSync(join(tmpdir(), "bridge-"));
    await expect(start(dir)).rejects.toThrow("no prompt");
  });
});
```

`bridge/test/follow.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { formatEvent } from "../src/follow.js";
import type { TaskEvent } from "../src/types.js";

const e = (type: TaskEvent["type"], data: Record<string, unknown>): TaskEvent => ({ seq: 7, ts: "t", task: "T-1", session: null, agent: "claude", type, data });

describe("formatEvent", () => {
  it("prints one readable line per event; partial messages stream without a newline", () => {
    expect(formatEvent(e("state", { state: "waiting", reason: "question Q1" }))).toBe("— waiting (question Q1)\n");
    expect(formatEvent(e("message", { role: "agent", text: "Hel", final: false }))).toBe("Hel");
    expect(formatEvent(e("message", { role: "agent", text: "Hello", final: true }))).toBe("\n");
    expect(formatEvent(e("message", { role: "user", text: "Fix it", final: true }))).toBe("> Fix it\n");
    expect(formatEvent(e("tool", { title: "npm test", status: "failed" }))).toBe("▸ npm test — failed\n");
    expect(formatEvent(e("question", { id: "Q1", text: "Which DB?", options: ["pg"], recommendation: "pg" }))).toBe("? Q1 Which DB? [pg] (recommended: pg)\n");
    expect(formatEvent(e("answer", { question: "Q1", text: "pg", grant: ["push"] }))).toBe("= Q1 pg (allowed: push)\n");
    expect(formatEvent(e("gate", { rule: "gate", command: "git push" }))).toBe("✗ gate refused: git push\n");
    expect(formatEvent(e("error", { message: "boom" }))).toBe("! boom\n");
  });
});
```

- [ ] **Step 7: Run them to see them fail**

Run: `cd bridge && npx vitest run test/bridge.test.ts test/follow.test.ts`
Expected: FAIL (modules missing).

- [ ] **Step 8: Write `bridge/src/bridge.ts`**

```ts
// The orchestrator: feeds inputs to the state machine and performs its effects (spec §6).
import { spawnSync } from "node:child_process";
import type { ApiTarget } from "./api.js";
import type { AgentHooks, AgentLike } from "./agent.js";
import type { Config } from "./config.js";
import { UpdateMapper, type Mapped } from "./map.js";
import type { Notifier } from "./notify.js";
import type { Store } from "./store.js";
import { TaskMachine, type Effect, type Input, type Outcome } from "./task.js";
import { renderEvent } from "./transcript.js";
import type { EventType, TaskEvent, TaskRecord } from "./types.js";

export class BridgeError extends Error {}

export interface BridgeDeps {
  store: Store;
  config: Config;
  notifier: Notifier;
  paragraph: string;
  agentFactory(hooks: AgentHooks): AgentLike;
  exit(code: number): void;
  now(): string;
  log(line: string): void;
}

const message = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export class Bridge implements ApiTarget {
  private machine: TaskMachine | null = null;
  private readonly mapper = new UpdateMapper();
  private agent: AgentLike | null = null;
  private readonly listeners = new Set<(e: TaskEvent) => void>();
  private readonly waiters = new Map<string, (optionId: string | null) => void>();
  private idle: NodeJS.Timeout | null = null;
  private flush: NodeJS.Timeout | null = null;

  constructor(private readonly d: BridgeDeps) {}

  boot(): void {
    const { store, config } = this.d;
    store.checkWritable();
    const fresh = !store.hasRecord();
    let record: TaskRecord;
    if (fresh) {
      const prompt = store.readPrompt() ?? config.prompt;
      if (!prompt) throw new BridgeError(`no prompt: write ${store.path("prompt.md")} or set AGENTIC_PROMPT`);
      const now = this.d.now();
      record = {
        version: 1, task: config.task, project: config.project, agent: config.agent, model: config.model, state: "starting",
        reason: "", session: null, branch: config.branch, created: now, updated: now, seq: 0, allowed_actions: [...config.allowed],
        inbox: [{ kind: "prompt", text: prompt }], summary: "", stopped_by_user: false,
      };
    } else {
      record = store.readRecord();
    }
    this.machine = new TaskMachine(record, fresh ? [] : store.readQuestions(), this.d.now);
    this.flush = setInterval(() => this.emitMapped(this.mapper.flushPartial()), 1000);
    this.run({ kind: "boot", fresh });
  }

  ready(): boolean {
    return this.machine !== null;
  }

  status(): Record<string, unknown> {
    const m = this.m();
    const { inbox, ...rest } = m.record;
    return {
      ...rest,
      inbox: inbox.length,
      questions: m.openQuestions().map((q) => ({ id: q.id, source: q.source, text: q.text, options: q.options, recommendation: q.recommendation, asked: q.asked })),
    };
  }

  command(input: Input): Outcome {
    return this.run(input);
  }

  events(since: number, limit: number): TaskEvent[] {
    return this.d.store.readEvents(since, limit);
  }

  subscribe(fn: (e: TaskEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  // shutdownAgent: ends the agent without a state change (SIGTERM from Docker: the next boot shows interrupted).
  async shutdownAgent(): Promise<void> {
    this.clearTimers();
    const a = this.agent;
    this.agent = null;
    await a?.kill();
  }

  private m(): TaskMachine {
    if (!this.machine) throw new BridgeError("the bridge has not booted");
    return this.machine;
  }

  private run(input: Input): Outcome {
    const m = this.m();
    const out = m.apply(input);
    if (!out.ok) return out;
    // the record first: the gate reads allowed_actions from it before the agent retries
    this.d.store.writeRecord(m.record);
    for (const e of out.effects) this.perform(e);
    this.d.store.writeRecord(m.record);
    return out;
  }

  private perform(e: Effect): void {
    switch (e.kind) {
      case "emit": this.emit(e.type, e.data); break;
      case "question": this.d.store.appendQuestion(e.question); break;
      case "timer": if (e.on) this.armIdle(); else this.disarmIdle(); break;
      case "notify": void this.d.notifier.webhook(this.m().record, e.question); break;
      case "spawn": void this.spawn(e.mode); break;
      case "prompt":
        this.emit("message", { role: "user", text: e.text, final: true });
        void this.prompt(e.text);
        break;
      case "cancel": this.agent?.cancel(); break;
      case "permission": this.waiters.get(e.question)?.(e.optionId); this.waiters.delete(e.question); break;
      case "kill": { const a = this.agent; this.agent = null; void a?.kill(); break; }
      case "exit": this.clearTimers(); this.d.exit(e.code); break;
    }
  }

  private hooks(self: () => AgentLike | null): AgentHooks {
    return {
      onUpdate: (u) => { if (this.agent === self()) this.emitMapped(this.mapper.handle(u)); },
      onPermission: (req) => new Promise((resolve) => {
        const out = this.run({ kind: "permissionRequest", ...req });
        const q = this.m().questions.at(-1);
        if (!out.ok || !q) return resolve(null);
        this.waiters.set(q.id, resolve);
      }),
      onExit: (error) => {
        if (this.agent !== self()) return;
        this.agent = null;
        this.run({ kind: "agentExit", error });
      },
      onStderr: (s) => this.d.log(`agent: ${s.trimEnd()}`),
    };
  }

  private async spawn(mode: "new" | "load"): Promise<void> {
    let agent: AgentLike | null = null;
    agent = this.d.agentFactory(this.hooks(() => agent));
    this.agent = agent;
    const rec = this.m().record;
    try {
      await agent.start();
      let session: string;
      if (mode === "load" && rec.session) {
        try {
          await agent.loadSession(rec.session);
          session = rec.session;
        } catch (err) {
          this.emit("error", { message: `session ${rec.session} could not be loaded (${message(err)}); started a new session with the task history` });
          session = await agent.newSession();
          rec.inbox.unshift({ kind: "prompt", text: this.seed() });
        }
      } else {
        session = await agent.newSession();
      }
      if (this.agent !== agent) return;
      this.run({ kind: "agentReady", session });
    } catch (err) {
      if (this.agent !== agent) return;
      this.agent = null;
      await agent.kill();
      this.run({ kind: "agentExit", error: `agent failed to start: ${message(err)}` });
    }
  }

  private async prompt(text: string): Promise<void> {
    const agent = this.agent;
    if (!agent) return;
    let stopReason = "error";
    try {
      stopReason = await agent.prompt(text);
    } catch (err) {
      if (this.agent !== agent) return;
      this.emit("error", { message: `prompt failed: ${message(err)}` });
    }
    if (this.agent !== agent) return;
    const { events, summary } = this.mapper.finishTurn();
    this.emitMapped(events);
    this.run({ kind: "turnEnd", stopReason, summary });
  }

  // seed: the first prompt of a replacement session (spec §6, Resume).
  private seed(): string {
    const m = this.m();
    const qa = m.questions.map((q) => `${q.id}: ${q.text} → ${q.status === "answered" ? q.answer : "(open)"}`).join("\n") || "(none)";
    const log = spawnSync("git", ["-C", this.d.config.work, "log", "--oneline", "-20"], { encoding: "utf8" }).stdout?.trim() || "(none)";
    return `Original task:\n${this.d.store.readPrompt() ?? this.d.config.prompt ?? ""}\n\nQuestions and answers so far:\n${qa}\n\nRecent commits:\n${log}\n\nThe earlier session could not be restored. Check git status and continue the task.`;
  }

  private emitMapped(list: Mapped[]): void {
    for (const e of list) this.emit(e.type, e.data);
  }

  private emit(type: EventType, data: Record<string, unknown>): void {
    const m = this.m();
    const ev = this.d.store.appendEvent({ ts: this.d.now(), task: m.record.task, session: m.record.session, agent: m.record.agent, type, data });
    const md = renderEvent(ev);
    if (md) this.d.store.appendTranscript(md);
    if (type === "state") this.d.notifier.logState(m.record);
    for (const fn of this.listeners) fn(ev);
  }

  private armIdle(): void {
    this.disarmIdle();
    this.idle = setTimeout(() => this.run({ kind: "idleTimeout" }), this.d.config.idleTimeoutMs);
  }

  private disarmIdle(): void {
    if (this.idle) clearTimeout(this.idle);
    this.idle = null;
  }

  private clearTimers(): void {
    this.disarmIdle();
    if (this.flush) clearInterval(this.flush);
    this.flush = null;
  }
}
```

(`Store` redacts everything it writes, and events reach listeners as the store returns them (redacted), so `emit` needs no redaction of its own.)

- [ ] **Step 9: Write `bridge/src/follow.ts`**

```ts
// agentic-bridge follow: prints the task's events readably from the WebSocket (spec §15, follow).
import WebSocket from "ws";
import type { TaskEvent } from "./types.js";

const s = (v: unknown): string => (typeof v === "string" ? v : "");
const END = new Set(["waiting", "idle", "stopped", "failed", "suspended"]);

export function formatEvent(e: TaskEvent): string {
  const d = e.data;
  switch (e.type) {
    case "state": return `— ${s(d.state)}${d.reason ? ` (${s(d.reason)})` : ""}\n`;
    case "message":
      if (d.role === "user") return s(d.text).split("\n").map((l) => `> ${l}`).join("\n") + "\n";
      return d.final ? "\n" : s(d.text);
    case "tool": return `▸ ${s(d.title)} — ${s(d.status)}\n`;
    case "plan": return `plan: ${Array.isArray(d.entries) ? d.entries.length : 0} entries\n`;
    case "question": {
      const opts = Array.isArray(d.options) && d.options.length ? ` [${d.options.join(", ")}]` : "";
      const rec = d.recommendation ? ` (recommended: ${s(d.recommendation)})` : "";
      return `? ${s(d.id)} ${s(d.text)}${opts}${rec}\n`;
    }
    case "answer": return `= ${s(d.question)} ${s(d.text)}${Array.isArray(d.grant) && d.grant.length ? ` (allowed: ${d.grant.join(", ")})` : ""}\n`;
    case "gate": return `✗ gate refused: ${s(d.command)}\n`;
    case "error": return `! ${s(d.message)}\n`;
    default: return "";
  }
}

export function follow(o: { url: string; token: string; since: number; raw: boolean; forever: boolean; out: (s: string) => void }): Promise<number> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${o.url}/events?since=${o.since}`, { headers: { authorization: `Bearer ${o.token}` } });
    // A state event ends the stream only once the backlog is through: the stored events are sent first.
    let settled: NodeJS.Timeout | null = null;
    ws.on("message", (m) => {
      const e = JSON.parse(m.toString()) as TaskEvent;
      o.out(o.raw ? JSON.stringify(e) + "\n" : formatEvent(e));
      if (settled) clearTimeout(settled);
      if (!o.forever && e.type === "state" && END.has(s(e.data.state))) settled = setTimeout(() => { ws.close(); resolve(0); }, 300);
    });
    ws.on("unexpected-response", (_req, res) => { o.out(`agentic-bridge: follow refused (HTTP ${res.statusCode})\n`); resolve(1); });
    ws.on("error", (err) => { o.out(`agentic-bridge: ${err.message}\n`); resolve(1); });
    ws.on("close", () => resolve(0));
  });
}
```

- [ ] **Step 10: Write `bridge/src/main.ts`**

```ts
#!/usr/bin/env node
// agentic-bridge: the task bridge (no arguments), or `agentic-bridge follow` inside the container.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { AgentProcess } from "./agent.js";
import { Bridge } from "./bridge.js";
import { agentEnvironment, loadConfig } from "./config.js";
import { follow } from "./follow.js";
import { harnessFor } from "./harness.js";
import { Notifier } from "./notify.js";
import { makeRedactor } from "./redact.js";
import { startServer } from "./server.js";
import { Store } from "./store.js";

function die(text: string): never {
  process.stderr.write(`agentic-bridge: ${text}\n`);
  process.exit(1);
}

async function serve(): Promise<void> {
  const cfg = loadConfig(process.env);
  const redact = makeRedactor([cfg.tokens.task, cfg.tokens.agent]);
  const store = new Store(cfg.taskDir, redact);
  const log = (m: string) => { try { appendFileSync(store.path("bridge.log"), redact(`${new Date().toISOString()} ${m}\n`)); } catch { /* best effort */ } };
  const eventsLog = existsSync(cfg.eventsDir) ? join(cfg.eventsDir, "events.jsonl") : null;
  const paragraph = existsSync(cfg.paragraphFile) ? readFileSync(cfg.paragraphFile, "utf8") : "";
  const spec = harnessFor(cfg.agent, { model: cfg.model, acpCmd: cfg.acpCmd });
  const env = agentEnvironment(process.env, cfg);
  let close: (() => Promise<void>) | null = null;
  const bridge = new Bridge({
    store, config: cfg, paragraph, log, now: () => new Date().toISOString(),
    notifier: new Notifier({ eventsLog, webhook: cfg.webhook, project: cfg.project, log }),
    agentFactory: (hooks) => new AgentProcess(spec, { cwd: cfg.work, env, paragraph, model: cfg.model }, hooks),
    exit: (code) => { log(`exit ${code}`); void (close?.() ?? Promise.resolve()).finally(() => process.exit(code)); },
  });
  const server = await startServer({ port: cfg.port, host: "0.0.0.0", tokens: cfg.tokens, access: { hosts: cfg.hosts, origins: cfg.origins },
    target: bridge, subscribe: (fn) => bridge.subscribe(fn) });
  close = server.close;
  try {
    bridge.boot();
  } catch (e) {
    await server.close();
    die((e as Error).message);
  }
  log(`listening on ${server.port}`);
  // Docker stop or a host shutdown: end the agent, keep the state (the next boot shows interrupted, spec D10).
  process.on("SIGTERM", () => { void bridge.shutdownAgent().finally(() => server.close().finally(() => process.exit(143))); });
}

async function followCmd(args: string[]): Promise<void> {
  let since = 0;
  let raw = false;
  let forever = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--since") since = Number(args[++i]);
    else if (a === "--raw") raw = true;
    else if (a === "--forever") forever = true;
    else die(`unknown option ${a}; usage: agentic-bridge follow [--since N] [--raw] [--forever]`);
  }
  if (!Number.isInteger(since) || since < 0) die("--since needs a number >= 0");
  const token = process.env.AGENTIC_TASK_TOKEN ?? die("AGENTIC_TASK_TOKEN is not set (run follow inside the task container)");
  const port = process.env.AGENTIC_BRIDGE_PORT ?? "8765";
  process.exit(await follow({ url: `ws://127.0.0.1:${port}`, token, since, raw, forever, out: (s) => process.stdout.write(s) }));
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "follow") await followCmd(rest);
else if (cmd === undefined) await serve().catch((e: Error) => die(e.message));
else die(`unknown command ${cmd}; usage: agentic-bridge [follow [--since N] [--raw] [--forever]]`);
```

Note the boot order differs from the test helper only in that the server starts first, so `/status` answers 503 until `boot()` has run.

- [ ] **Step 11: Run tests and lint**

Run: `make test && make lint`
Expected: PASS. Then build once to check the production build: `cd bridge && npm run build && node dist/main.js follow --bogus; echo rc=$?` → prints the usage error, `rc=1`.

- [ ] **Step 12: Commit**

```bash
git add bridge/src bridge/test
git commit -m "feat: the bridge: orchestration, suspension and resume, notify, config, entry point and follow"
```

---

### Task 10: The bridge in the image: build, `agentic-ask`, task homes

**Files:**
- Create: `image/bin/agentic-ask`, `image/start.d/06-task-home.sh`, `tests/bats/agentic-ask.bats`, `tests/bats/task-home-step.bats`
- Modify: `image/Dockerfile`, `.dockerignore`, `tests/bats/dockerfile.bats`, `tests/image/smoke.sh`

**Interfaces:**
- Consumes: Task 9's `dist/main.js`; Task 3's `task-prompt.md`.
- Produces: `/usr/local/bin/agentic-bridge`, `/usr/local/bin/agentic-ask` in the image; `/task` owned by `dev` in the image (so a new named volume inherits the owner); `ENV COPILOT_AUTO_UPDATE=false`; with `/task` mounted (or `AGENTIC_TASK_DIR` set), `CLAUDE_CONFIG_DIR=/task/home/claude` and `COPILOT_HOME=/task/home/copilot` for every later start step and the bridge.

- [ ] **Step 1: Write the tests (failing)**

`tests/bats/agentic-ask.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  ASK="$REPO_ROOT/image/bin/agentic-ask"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # curl stand-in: logs the arguments and the body, answers with $ASK_BODY and $ASK_CODE
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl.args"
for a in "$@"; do case "$a" in @*) cat "${a#@}" > "$BATS_TEST_TMPDIR/curl.header" ;; esac; done
cat > "$BATS_TEST_TMPDIR/curl.body"
printf '%s\n%s' "${ASK_BODY:-{\"id\":\"Q3\"}}" "${ASK_CODE:-201}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" AGENTIC_BRIDGE_URL=http://127.0.0.1:8765 AGENTIC_AGENT_TOKEN=agent-token-0123456789
}

@test "asks with options and a recommendation, and tells the agent what to do next" {
  run bash "$ASK" "Which DB?" --option pg --option sqlite --recommend pg
  [ "$status" -eq 0 ]
  [ "$output" = "Recorded Q3. Continue with work that does not depend on it; when nothing else can move, end your turn." ]
  [ "$(jq -c . "$BATS_TEST_TMPDIR/curl.body")" = '{"text":"Which DB?","options":["pg","sqlite"],"recommend":"pg"}' ]
  grep -qx 'http://127.0.0.1:8765/ask' "$BATS_TEST_TMPDIR/curl.args"
  grep -q 'Authorization: Bearer agent-token-0123456789' "$BATS_TEST_TMPDIR/curl.header"
  run grep -q agent-token-0123456789 "$BATS_TEST_TMPDIR/curl.args"
  [ "$status" -ne 0 ]
}

@test "the question text keeps quotes, newlines and dollars" {
  bash "$ASK" $'Use "pg"\nor $DB?'
  [ "$(jq -r .text "$BATS_TEST_TMPDIR/curl.body")" = $'Use "pg"\nor $DB?' ]
  [ "$(jq -c .options "$BATS_TEST_TMPDIR/curl.body")" = '[]' ]
  [ "$(jq -c .recommend "$BATS_TEST_TMPDIR/curl.body")" = null ]
}

@test "outside a task it says so" {
  unset AGENTIC_BRIDGE_URL
  run bash "$ASK" "x"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic-ask: agentic-ask works only inside a task" ]
}

@test "usage errors and refusals are clear" {
  run bash "$ASK"
  [ "$status" -eq 1 ]; [[ "$output" == *usage* ]]
  run bash "$ASK" a b
  [ "$status" -eq 1 ]; [[ "$output" == *"one question at a time"* ]]
  ASK_BODY='{"error":{"code":"conflict","message":"task is stopped"}}' ASK_CODE=409 run bash "$ASK" "x"
  [ "$status" -eq 1 ]; [ "$output" = "agentic-ask: task is stopped" ]
}
```

`tests/bats/task-home-step.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  S="$REPO_ROOT/image/start.d/06-task-home.sh"
  mkdir -p "$AGENTIC_STATE"; : > "$AGENTIC_STATE/env"
}

@test "without a task volume the step does nothing" {
  run bash "$S"
  [ "$status" -eq 0 ]
  [ ! -s "$AGENTIC_STATE/env" ]
}

@test "with a task directory the harness homes move onto it" {
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"; mkdir -p "$AGENTIC_TASK_DIR"
  run bash "$S"
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_TASK_DIR/home/claude" ] && [ -d "$AGENTIC_TASK_DIR/home/copilot" ]
  grep -qx "export CLAUDE_CONFIG_DIR=$AGENTIC_TASK_DIR/home/claude" "$AGENTIC_STATE/env"
  grep -qx "export COPILOT_HOME=$AGENTIC_TASK_DIR/home/copilot" "$AGENTIC_STATE/env"
}

@test "an unwritable task directory stops the start with a clear message" {
  [ "$(id -u)" != 0 ] || skip "root can write anywhere"
  export AGENTIC_TASK_DIR="$BATS_TEST_TMPDIR/task"; mkdir -p "$AGENTIC_TASK_DIR"; chmod 500 "$AGENTIC_TASK_DIR"
  run bash "$S"
  chmod 700 "$AGENTIC_TASK_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not writable"* ]]
}
```

Add to `tests/bats/dockerfile.bats`:

```bash
@test "the image builds the bridge, disables Copilot's self-update and owns /task" {
  f="$REPO_ROOT/image/Dockerfile"
  grep -q 'COPILOT_AUTO_UPDATE=false' "$f"
  grep -q 'npm ci' "$f"
  grep -q '/usr/local/bin/agentic-bridge' "$f"
  grep -q 'chown -R dev:dev /work /workspaces /task' "$f"
  grep -qx 'bridge/node_modules' "$REPO_ROOT/.dockerignore"
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `bats tests/bats/agentic-ask.bats tests/bats/task-home-step.bats tests/bats/dockerfile.bats`
Expected: FAIL.

- [ ] **Step 3: Write `image/bin/agentic-ask`**

```bash
#!/usr/bin/env bash
# agentic-ask "question" [--option X]... [--recommend X]: asks the human through the task bridge.
# The agent token may only ask; the answer arrives later as a message "Answer to Q<n>: ...".
set -euo pipefail
die() { echo "agentic-ask: $*" >&2; exit 1; }
usage='usage: agentic-ask "question" [--option X]... [--recommend X]'
[ -n "${AGENTIC_BRIDGE_URL:-}" ] && [ -n "${AGENTIC_AGENT_TOKEN:-}" ] || die "agentic-ask works only inside a task"

text=""; rec=""; opts=()
while [ $# -gt 0 ]; do
  case "$1" in
    --option) [ $# -ge 2 ] || die "--option needs a value"; opts+=("$2"); shift 2 ;;
    --recommend) [ $# -ge 2 ] || die "--recommend needs a value"; rec="$2"; shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) [ -z "$text" ] || die "one question at a time; quote it"; text="$1"; shift ;;
  esac
done
[ -n "$text" ] || die "$usage"

body="$(jq -cn --arg t "$text" --arg r "$rec" \
  '{text: $t, options: $ARGS.positional, recommend: (if $r == "" then null else $r end)}' --args "${opts[@]}")"
hdr="$(mktemp)"; trap 'rm -f "$hdr"' EXIT
printf 'Authorization: Bearer %s\n' "$AGENTIC_AGENT_TOKEN" > "$hdr"
resp="$(printf '%s' "$body" | curl -sS -m 10 -X POST -H "@$hdr" -H 'Content-Type: application/json' \
  --data-binary @- -w '\n%{http_code}' "$AGENTIC_BRIDGE_URL/ask")" || die "the task bridge is not reachable"
code="${resp##*$'\n'}"; json="${resp%$'\n'*}"
[ "$code" = 201 ] || die "$(jq -r '.error.message // "the bridge refused the question"' <<<"$json" 2>/dev/null || echo "HTTP $code")"
echo "Recorded $(jq -r .id <<<"$json"). Continue with work that does not depend on it; when nothing else can move, end your turn."
```

Make it executable: `chmod +x image/bin/agentic-ask` (the Dockerfile links every `image/bin/*` into `/usr/local/bin`).

- [ ] **Step 4: Write `image/start.d/06-task-home.sh`**

```bash
#!/usr/bin/env bash
# With a task volume (/task mounted, or AGENTIC_TASK_DIR set): the harness homes live on it, so a
# suspended task's sessions survive the container. Runs before every step that writes a home.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
if [ -z "${AGENTIC_TASK_DIR:-}" ] && ! mountpoint -q /task 2>/dev/null; then exit 0; fi
task="${AGENTIC_TASK_DIR:-/task}"
if [ ! -w "$task" ]; then say "$task is not writable by $(id -un); fix the owner of the task volume"; exit 1; fi
[ "${1:-}" = --check ] && exit 0
mkdir -p "$task/home/claude" "$task/home/copilot"
printf 'export CLAUDE_CONFIG_DIR=%s\nexport COPILOT_HOME=%s\n' "$task/home/claude" "$task/home/copilot" >> "$AGENTIC_STATE/env"
```

- [ ] **Step 5: Build the bridge in the image**

In `image/Dockerfile`:

1. Add `COPILOT_AUTO_UPDATE=false \` to the first `ENV` block (after `DISABLE_AUTOUPDATER=1 \`).
2. After the "Harness CLIs" `RUN`, add:

```dockerfile
# The task bridge's dependencies (cached apart from its sources)
COPY bridge/package.json bridge/package-lock.json /opt/agentic/bridge/
RUN cd /opt/agentic/bridge && PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npm ci --no-audit --no-fund
```

3. In the "User dev, mount points" `RUN`, add `/task` to `mkdir -p` and change the `chown` to `chown -R dev:dev /work /workspaces /task /opt/agentic/claude-plugins /ms-playwright`.
4. In "The agentic layer", before `RUN ln -sf /opt/agentic/bin/* /usr/local/bin/`, add:

```dockerfile
COPY bridge/tsconfig.json bridge/tsconfig.build.json /opt/agentic/bridge/
COPY bridge/src /opt/agentic/bridge/src
# Built here, then only production dependencies stay; the adapter's bundled Claude binary is an
# optional dependency and not needed (the bridge points it at the image's claude).
RUN cd /opt/agentic/bridge && PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npm run build \
 && PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npm prune --omit=dev --omit=optional \
 && printf '#!/bin/sh\nPATH=/opt/node/%s/bin:$PATH exec node /opt/agentic/bridge/dist/main.js "$@"\n' "${NODE_HARNESS}" > /usr/local/bin/agentic-bridge \
 && chmod 755 /usr/local/bin/agentic-bridge
```

Append to `.dockerignore`:

```
bridge/node_modules
bridge/dist
```

- [ ] **Step 6: Run tests and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 7: Smoke: the bridge runs a task in the image**

Add to `tests/image/smoke.sh`, after the gate step from Task 3:

```bash
step "the bridge runs a task to idle with the fake agent; homes live on the task volume"
tk="$tmp/task-bridge"; mkdir -p "$tk"; printf 'hello\n' > "$tk/prompt.md"
docker run -d --name agentic-smoke-bridge -p 127.0.0.1::8765 -v "$tk:/task" -v "$root/bridge/test:/fake:ro" \
  -e AGENTIC_TASK_TOKEN=smoke-task-token-0123456789 -e AGENTIC_AGENT_TOKEN=smoke-agent-token-0123456789 \
  -e 'AGENTIC_ACP_CMD=["node","/fake/fake-agent.mjs"]' -e FAKE_AGENT_STATE=/task/home/fake "$IMG" agentic-bridge >/dev/null
trap 'docker rm -f agentic-smoke-bridge >/dev/null 2>&1; rm -rf "$tmp"' EXIT
port="$(docker port agentic-smoke-bridge 8765/tcp | head -n 1 | sed 's/.*://')"
st=""
for _ in $(seq 1 60); do
  st="$(curl -fsS -H 'Authorization: Bearer smoke-task-token-0123456789' "http://127.0.0.1:$port/status" 2>/dev/null | jq -r .state || true)"
  [ "$st" = idle ] && break
  sleep 1
done
[ "$st" = idle ] || { docker logs agentic-smoke-bridge >&2; fail "bridge task: state '$st'"; }
[ "$(jq -r .summary "$tk/state.json")" = "echo: hello" ] || fail "bridge task: summary"
[ -d "$tk/home/claude" ] && [ -d "$tk/home/copilot" ] || fail "bridge task: harness homes not on /task"
docker exec agentic-smoke-bridge bash -lc '[ "$CLAUDE_CONFIG_DIR" = /task/home/claude ] && { [ -L /task/home/claude/plugins ] || [ -d /task/home/claude/plugins ]; }' \
  || fail "bridge task: plugins not linked into the task's Claude home"
docker exec agentic-smoke-bridge bash -lc 'test "$COPILOT_AUTO_UPDATE" = false && agentic-ask x 2>&1 | grep -q "only inside a task"' \
  || fail "bridge task: image env"
docker rm -f agentic-smoke-bridge >/dev/null
```

(`agentic-ask` in a `docker exec` shell has no `AGENTIC_BRIDGE_URL`, so it must refuse: that proves it is on PATH and only works for the agent.)

Run: `make smoke`
Expected: `smoke OK`. If the plugins check fails, `50-plugins` links into `$(claude_dir)`; check that `06-task-home` ran first (`AGENTIC_DEBUG=1`) and fix the order, not the check.

- [ ] **Step 8: Commit**

```bash
git add image/bin/agentic-ask image/start.d/06-task-home.sh image/Dockerfile .dockerignore \
  tests/bats/agentic-ask.bats tests/bats/task-home-step.bats tests/bats/dockerfile.bats tests/image/smoke.sh
git commit -m "feat: the bridge in the image, agentic-ask, harness homes on the task volume"
```

---

### Task 11: Host: create and list tasks (`run`, `status`)

**Files:**
- Create: `lib/host/task.sh`, `tests/bats/cli-task-run.bats`
- Modify: `lib/host/common.sh` (split `build_run_args`), `bin/agentic` (source, usage, dispatch), `tests/bats/docker-stub.bash`, `tests/bats/helpers.bash`

**Interfaces:**
- Consumes: `lib/host/common.sh` (`project_name`, `project_root`, `cfg_dir`, `run_image`, `image_label`, `dotenv_value`, `check_env_file`, `die`, `say`).
- Produces (bash, used by Task 12):
  - `TASK_PORT=8765`; `TASK_PROJECT` (optional override of the project for every helper).
  - `task_ws`, `task_dir ID`, `task_file ID env|mounts|repos|interrupted`, `task_container ID`, `new_task_id`, `new_token`, `task_slug TEXT`, `need_task ID`.
  - `container_status ID` → `running|exited|created|...|missing`; `task_port ID`; `record_get ID FILTER`; `task_state ID` (record state, with `interrupted` derived when the record says active and no container runs).
  - `bridge_req ID METHOD PATH [BODY]` → sets `BRIDGE_CODE`, `BRIDGE_BODY`; returns 1 when unreachable. `bridge_call` the same but dies with `task <ID> is not reachable (state: <state>)`.
  - `wait_bridge ID SECONDS` → 0 once `GET /status` answers 200 with a state other than `starting`; 1 if the container stops or time runs out.
  - `check_cap`; `rollback_task ID`; `shared_run_args IMAGE` (in `common.sh`, appends env file, git identity, proxy, AWS and Docker socket arguments to `RUN_ARGS`).
- Defaults (spec §15): the agent defaults to the image label `agentic.harness` (rendered from `harness.default`); without `--model` the bridge passes no model, and the container's start step `25-harness` already applies `harness.<h>.model` (`ANTHROPIC_MODEL` for Claude, Copilot's config).

- [ ] **Step 1: Extend the stubs**

In `tests/bats/docker-stub.bash`, replace the `inspect)` line and add `port` and `ps` cases:

```bash
  inspect)
    if [[ "$*" == *State.Status* ]]; then [ -n "${DOCKER_STATUS:-}" ] || exit 1; echo "$DOCKER_STATUS"; exit 0; fi
    [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  port) [ -n "${DOCKER_PORT:-}" ] && echo "127.0.0.1:$DOCKER_PORT" ;;
  ps) [ -z "${DOCKER_PS:-}" ] || printf '%s\n' $DOCKER_PS ;;
```

and document the controls in its header comment: `DOCKER_STATUS (inspect .State.Status), DOCKER_PORT (docker port), DOCKER_PS (docker ps ids, space-separated)`.

Add to `tests/bats/helpers.bash`:

```bash
# install_curl_stub: a curl stand-in for bridge calls. Each call appends its arguments, the header
# file's content and the body (stdin) to $CURL_LOG, then prints $CURL_BODY and the HTTP code:
# $CURL_GET_CODE (default 200) for GET, $CURL_CODE (default 202) otherwise. CURL_RC=7 fails the call.
install_curl_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET
{ echo "--- curl"; for a in "$@"; do echo "arg: $a"; case "$a" in @/*|@.*) sed 's/^/header: /' "${a#@}" ;; esac; done
  echo "body: $(cat)"; } >> "$CURL_LOG"
prev=""; for a in "$@"; do [ "$prev" = -X ] && method="$a"; prev="$a"; done
[ -z "${CURL_RC:-}" ] || exit "$CURL_RC"
code="${CURL_CODE:-202}"; [ "$method" = GET ] && code="${CURL_GET_CODE:-200}"
printf '%s\n%s' "${CURL_BODY:-{\"state\":\"idle\",\"reason\":\"\"}}" "$code"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
}
# curl_body N: the body of the Nth curl call.
curl_body() { grep '^body: ' "$CURL_LOG" | sed -n "${1}p" | sed 's/^body: //'; }
```

- [ ] **Step 2: Write the tests (failing)**

`tests/bats/cli-task-run.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  install_curl_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q -b main "$PROJ"
  printf 'version: 1\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  T="$AGENTIC_WORKSPACES/demo/tasks"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# record ID STATE: a task directory with a state.json, as the bridge leaves it.
record() {
  mkdir -p "$T/$1"
  jq -n --arg id "$1" --arg s "$2" '{version:1, task:$id, project:"demo", agent:"claude", state:$s, reason:"",
    session:"s1", branch:("agentic/" + $id), created:"2026-10-12T10:00:00Z", updated:"t", seq:1,
    allowed_actions:[], summary:"", stopped_by_user:false}' > "$T/$1/state.json"
  printf 'AGENTIC_TASK_TOKEN=tok-task-0123456789\nAGENTIC_AGENT_TOKEN=tok-agent-0123456789\n' > "$T/$1.env"
}

@test "run creates the worktree, the task directory and tokens, starts the bridge and prints the id" {
  run --separate-stderr ag run --id T-1 --allow push --allow open-pr "Fix the login bug"
  [ "$status" -eq 0 ]
  [ "$output" = T-1 ]
  [ "$stderr" = "follow: agentic follow T-1" ]
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-1"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = agentic/T-1-fix-the-login-bug ]
  [ "$(cat "$T/T-1/prompt.md")" = "Fix the login bug" ]
  [ "$(stat -c %a "$T/T-1.env")" = 600 ]
  grep -Eq '^AGENTIC_TASK_TOKEN=[0-9a-f]{64}$' "$T/T-1.env"
  grep -Eq '^AGENTIC_AGENT_TOKEN=[0-9a-f]{64}$' "$T/T-1.env"
  call="$(docker_sub run)"
  grep -qx -- '-d' <<<"$call"
  grep -qx 'agentic-demo-task-T-1' <<<"$call"
  for l in agentic.kind=task agentic.task=T-1 agentic.project=demo agentic.agent=claude agentic.branch=agentic/T-1-fix-the-login-bug; do grep -qx "$l" <<<"$call"; done
  grep -qx '127.0.0.1::8765' <<<"$call"
  grep -qx "$wt:/work" <<<"$call"
  grep -qx "$T/T-1:/task" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/events:/events" <<<"$call"
  grep -qx "$AGENTIC_WORKSPACES/demo/repos/proj/.git:$AGENTIC_WORKSPACES/demo/repos/proj/.git" <<<"$call"
  grep -qx "$T/T-1.env" <<<"$call"
  grep -qx 'AGENTIC_ALLOWED_ACTIONS=push,open-pr' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-bridge ]
  run grep -q "$(grep TASK_TOKEN "$T/T-1.env" | cut -d= -f2)" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "run --repo gives each named repository a worktree and mounts the other clones read-only" {
  git clone -q "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/lib"
  git clone -q "$PROJ" "$AGENTIC_WORKSPACES/demo/repos/docs"
  ag run --id T-R --repo lib --repo proj "x" 2>/dev/null
  ws="$AGENTIC_WORKSPACES/demo"
  call="$(docker_sub run)"
  grep -qx "$ws/repos/lib/.worktrees/T-R:/work" <<<"$call"
  grep -qx "$ws/repos/proj/.worktrees/T-R:/workspaces/proj" <<<"$call"
  grep -qx "$ws/repos/docs:/workspaces/docs:ro" <<<"$call"
  [ "$(git -C "$ws/repos/lib/.worktrees/T-R" rev-parse --abbrev-ref HEAD)" = agentic/T-R-x ]
}

@test "run --json prints the task, container, port and branch" {
  run --separate-stderr ag run --id T-2 --branch feature/x --json "x"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"task":"T-2","container":"agentic-demo-task-T-2","port":"49153","branch":"feature/x"}' ]
}

@test "run seeds the task's harness homes from the project login, private to the user" {
  mkdir -p "$AGENTIC_DATA/projects/demo/harness/claude" "$AGENTIC_DATA/projects/demo/harness/copilot"
  echo '{}' > "$AGENTIC_DATA/projects/demo/harness/claude/.credentials.json"
  echo '{}' > "$AGENTIC_DATA/projects/demo/harness/copilot/config.json"
  ag run --id T-3 "x"
  [ "$(stat -c %a "$T/T-3/home/claude/.credentials.json")" = 600 ]
  [ "$(stat -c %a "$T/T-3/home/copilot/config.json")" = 600 ]
}

@test "run refuses bad input before creating anything" {
  run ag run --allow merge "x";       [ "$status" -eq 1 ]; [[ "$output" == *"unknown --allow merge"* ]]
  run ag run --agent gpt "x";         [ "$status" -eq 1 ]; [[ "$output" == *"--agent must be claude or copilot"* ]]
  run ag run;                         [ "$status" -eq 1 ]; [[ "$output" == *"needs a prompt"* ]]
  run ag run --id 'a/b' "x";          [ "$status" -eq 1 ]; [[ "$output" == *"task id"* ]]
  echo p > "$BATS_TEST_TMPDIR/p.md"
  run ag run --prompt-file "$BATS_TEST_TMPDIR/p.md" "x"; [ "$status" -eq 1 ]; [[ "$output" == *"either"* ]]
  [ ! -d "$T" ] || [ -z "$(ls -A "$T")" ]
  [ ! -s "$DOCKER_LOG" ] || ! grep -q -- '--- run' "$DOCKER_LOG"
}

@test "run refuses at the cap of running tasks" {
  DOCKER_PS="a b c" run ag run "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"3 tasks are running (AGENTIC_MAX_RUNNING=3)"* ]]
  AGENTIC_MAX_RUNNING=4 DOCKER_PS="a b c" run ag run --id T-4 "x"
  [ "$status" -eq 0 ]
}

@test "a failed start rolls back the container, worktree, branch and files" {
  DOCKER_RUN_RC=1 run ag run --id T-5 "x"
  [ "$status" -eq 1 ]
  [ ! -e "$T/T-5" ] && [ ! -e "$T/T-5.env" ]
  [ ! -e "$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-5" ]
  run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-5-x
  [ "$status" -ne 0 ]
}

@test "--keep-on-failure keeps what was created" {
  DOCKER_RUN_RC=1 run ag run --id T-6 --keep-on-failure "x"
  [ "$status" -eq 1 ]
  [ -d "$T/T-6" ]
}

@test "status lists tasks: live state from a running bridge, interrupted when the container is gone" {
  record T-7 idle
  CURL_BODY='{"task":"T-7","agent":"claude","created":"2026-10-12T10:00:00Z","branch":"agentic/T-7","state":"waiting","reason":"question Q1","questions":[{"id":"Q1"}]}' run ag status
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p <<<"$output")" == TASK*STATE*AGENT*QUESTIONS*AGE*BRANCH ]]
  [[ "$(sed -n 2p <<<"$output")" =~ ^T-7\ +waiting\ +claude\ +1\ +[0-9]+[mhd]\ +agentic/T-7$ ]]
  record T-8 running
  DOCKER_STATUS="" run ag status T-8 --json
  [ "$(jq -r .state <<<"$output")" = interrupted ]
}

@test "status records an interrupted task in the project events log once" {
  record T-9 running
  DOCKER_STATUS="" ag status >/dev/null
  DOCKER_STATUS="" ag status >/dev/null
  [ "$(grep -c '"state":"interrupted"' "$AGENTIC_WORKSPACES/demo/events/events.jsonl")" -eq 1 ]
}

# Review Focus 4
@test "a bridge that does not answer gives a clear message, not a curl error" {
  record T-10 idle
  CURL_RC=7 run ag status T-10
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle"* ]]
  CURL_RC=7 run bash -c "cd '$PROJ' && source '$REPO_ROOT/lib/host/common.sh' && source '$REPO_ROOT/lib/host/task.sh' && bridge_call T-10 GET /status"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic: task T-10 is not reachable (state: idle)" ]
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `bats tests/bats/cli-task-run.bats`
Expected: FAIL (`agentic run` unknown).

- [ ] **Step 4: Split `build_run_args` in `lib/host/common.sh`**

Replace `build_run_args` with:

```bash
# build_run_args IMAGE: docker run arguments for this project, in the global array RUN_ARGS.
build_run_args() {
  local root cfg p data ws
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"
  data="$AGENTIC_DATA/projects/$p"; ws="$AGENTIC_WORKSPACES/$p"
  mkdir -p "$data/harness/claude" "$data/harness/copilot" "$ws"
  RUN_ARGS=(--label "agentic.project=$p"
    -v "$root:/work" -v "$ws:/workspaces" -v "$cfg:/agentic-config:ro"
    -v "$data/harness/claude:/home/dev/.claude" -v "$data/harness/copilot:/home/dev/.copilot")
  shared_run_args "$1"
}

# shared_run_args IMAGE: appends what every container of the project gets to RUN_ARGS: the .env
# file, git identity, proxy, AWS profile and the opt-in Docker socket.
shared_run_args() {
  local img="$1" root cfg p data v name email profile sock
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"; data="$AGENTIC_DATA/projects/$p"
  check_env_file "$cfg/.env"
  if [ -f "$cfg/.env" ]; then RUN_ARGS+=(--env-file "$cfg/.env"); fi
  name="$(git -C "$root" config user.name || true)"; email="$(git -C "$root" config user.email || true)"
  if [ -n "$name" ]; then RUN_ARGS+=(-e "GIT_AUTHOR_NAME=$name"); fi
  if [ -n "$email" ]; then RUN_ARGS+=(-e "GIT_AUTHOR_EMAIL=$email"); fi
  for v in "${PROXY_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then RUN_ARGS+=(-e "$v"); fi
  done
  profile="$(dotenv_value "$cfg/.env" AWS_PROFILE)"
  if [ -n "$profile" ] && [ -d "$HOME/.aws" ]; then
    build_aws_dir "$HOME/.aws" "$data/aws" "$profile"
    RUN_ARGS+=(-v "$data/aws:/home/dev/.aws:ro")
  fi
  sock="${AGENTIC_DOCKER_SOCK:-/var/run/docker.sock}"
  if [ "$(image_label "$img" agentic.docker_socket)" = true ] && [ -S "$sock" ]; then
    RUN_ARGS+=(-v "$sock:/var/run/docker.sock" --group-add "$(stat -c %g "$sock")")
  fi
}
```

Run: `bats tests/bats/cli-run.bats tests/bats/cli-core.bats` → PASS (no behaviour change).

- [ ] **Step 5: Write `lib/host/task.sh`**

```bash
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
task_slug() { printf '%s' "$1" | head -n 1 | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-40 | sed -E 's/-+$//'; }
valid_task_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
need_task() {
  valid_task_id "${1:-}" || die "usage: a task id ([A-Za-z0-9._-]+)"
  [ -f "$(task_dir "$1")/state.json" ] || die "no task $1 in $(task_project)"
}

container_status() { docker inspect -f '{{.State.Status}}' "$(task_container "$1")" 2>/dev/null || echo missing; }
task_port() { docker port "$(task_container "$1")" "$TASK_PORT/tcp" 2>/dev/null | head -n 1 | sed 's/.*://'; }
record_get() { jq -r "$2 // empty" "$(task_dir "$1")/state.json" 2>/dev/null || true; }

# task_state ID: the record's state; active while no container runs means interrupted (spec §6).
task_state() {
  local st; st="$(record_get "$1" .state)"; st="${st:-unknown}"
  if [[ " $TASK_ACTIVE " == *" $st "* ]] && [ "$(container_status "$1")" != running ]; then st=interrupted; fi
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
  out="$(printf '%s' "$body" | curl -sS -m 30 -X "$method" -H "@$hdr" -H 'Content-Type: application/json' \
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

# rollback_task ID: removes the container, worktrees, branches and files of a task.
rollback_task() {
  local id="$1" clone wt branch
  docker rm -f "$(task_container "$id")" >/dev/null 2>&1 || true
  if [ -f "$(task_file "$id" repos)" ]; then
    while read -r clone wt branch; do
      git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
      git -C "$clone" worktree prune >/dev/null 2>&1 || true
      git -C "$clone" branch -D "$branch" >/dev/null 2>&1 || true
    done < "$(task_file "$id" repos)"
  fi
  rm -rf "$(task_dir "$id")"
  rm -f "$(task_file "$id" env)" "$(task_file "$id" mounts)" "$(task_file "$id" repos)" "$(task_file "$id" interrupted)"
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
  printf '%s %s %s\n' "$clone" "$clone/.worktrees/$2" "$3" >> "$(task_file "$2" repos)"
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
```

- [ ] **Step 6: Add `run` and `status` to `bin/agentic`**

Source the new library after `detect.sh`:

```bash
# shellcheck source=../lib/host/task.sh
source "$AGENTIC_ROOT/lib/host/task.sh"
```

Add the commands:

```bash
optval() { [ -n "${2:-}" ] || die "$1 needs a value"; }

cmd_run() {
  need_config
  local prompt="" pfile="" agent="" model="" base="" branch="" id="" keep=0 json=0 repos=() allow=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) optval "$@"; pfile="$2"; shift 2 ;;
      --agent) optval "$@"; agent="$2"; shift 2 ;;
      --model) optval "$@"; model="$2"; shift 2 ;;
      --repo) optval "$@"; repos+=("$2"); shift 2 ;;
      --base) optval "$@"; base="$2"; shift 2 ;;
      --branch) optval "$@"; branch="$2"; shift 2 ;;
      --allow) optval "$@"; allow+=("$2"); shift 2 ;;
      --id) optval "$@"; id="$2"; shift 2 ;;
      --keep-on-failure) keep=1; shift ;;
      --json) json=1; shift ;;
      -*) die "unknown option $1 (agentic help)" ;;
      *) [ -z "$prompt" ] || die "one prompt; quote it"; prompt="$1"; shift ;;
    esac
  done
  if [ -n "$pfile" ]; then
    [ -z "$prompt" ] || die "give either a prompt or --prompt-file"
    [ -f "$pfile" ] || die "no file $pfile"
    prompt="$(cat "$pfile")"
  fi
  [ -n "$prompt" ] || die 'run needs a prompt: agentic run "..." or --prompt-file F'
  local img; img="$(run_image)"
  [ -n "$agent" ] || agent="$(image_label "$img" agentic.harness)"
  agent="${agent:-claude}"
  case "$agent" in claude|copilot) ;; *) die "--agent must be claude or copilot" ;; esac
  for a in "${allow[@]}"; do [[ "$a" =~ ^(push|open-pr|deploy:[A-Za-z0-9_.-]+)$ ]] || die "unknown --allow $a (push, open-pr, deploy:<target>)"; done
  [ -n "$id" ] || id="$(new_task_id)"
  valid_task_id "$id" || die "the task id must match [A-Za-z0-9._-]+"
  [ ! -e "$(task_dir "$id")" ] || die "task $id exists"
  [ -n "$branch" ] || branch="${AGENTIC_BRANCH_PREFIX:-agentic/}$id-$(task_slug "$prompt")"
  check_cap

  abort() { [ "$keep" = 1 ] || rollback_task "$id"; die "$*"; }
  local p ws dir c own r data port
  p="$(task_project)"; ws="$(task_ws)"; dir="$(task_dir "$id")"; c="$(task_container "$id")"
  mkdir -p "$dir/home/claude" "$dir/home/copilot" "$ws/events"
  own="$(project_clone)" || abort "could not clone the project's repository into $ws/repos"
  [ "${#repos[@]}" -gt 0 ] || repos=("$own")
  for r in "${repos[@]}"; do add_worktree "$r" "$id" "$branch" "$base" || abort "could not create the worktree of $r"; done
  printf '%s\n' "$prompt" > "$dir/prompt.md"
  (umask 077; printf 'AGENTIC_TASK_TOKEN=%s\nAGENTIC_AGENT_TOKEN=%s\n' "$(new_token)" "$(new_token)" > "$(task_file "$id" env)")
  data="$AGENTIC_DATA/projects/$p/harness"
  if [ -f "$data/claude/.credentials.json" ]; then install -m 600 "$data/claude/.credentials.json" "$dir/home/claude/"; fi
  if [ -f "$data/copilot/config.json" ]; then install -m 600 "$data/copilot/config.json" "$dir/home/copilot/"; fi
  task_mounts "$id" "${repos[@]}"

  local mounts=() extra=() v
  mapfile -t mounts < "$(task_file "$id" mounts)"
  read -ra extra <<<"${AGENTIC_TASK_DOCKER_ARGS:-}"
  RUN_ARGS=()
  shared_run_args "$img"
  for v in AGENTIC_IDLE_TIMEOUT AGENTIC_NOTIFY_WEBHOOK AGENTIC_GATE_PROTECTED; do
    if [ -n "${!v:-}" ]; then RUN_ARGS+=(-e "$v"); fi
  done
  docker run -d --name "$c" --label agentic.kind=task --label "agentic.task=$id" --label "agentic.project=$p" \
    --label "agentic.agent=$agent" --label "agentic.branch=$branch" -p "127.0.0.1::$TASK_PORT" \
    "${mounts[@]}" "${RUN_ARGS[@]}" --env-file "$(task_file "$id" env)" \
    -e "AGENTIC_TASK_ID=$id" -e "AGENTIC_PROJECT=$p" -e "AGENTIC_AGENT=$agent" -e "AGENTIC_MODEL=$model" \
    -e "AGENTIC_BRANCH=$branch" -e "AGENTIC_ALLOWED_ACTIONS=$(IFS=,; echo "${allow[*]}")" \
    "${extra[@]}" "$img" agentic-bridge >/dev/null || abort "docker run failed for $id"
  if ! wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}"; then
    docker logs --tail 20 "$c" >&2 2>&1 || true
    abort "the bridge of $id did not come up"
  fi
  port="$(task_port "$id")"
  if [ "$json" = 1 ]; then
    jq -cn --arg t "$id" --arg c "$c" --arg p "$port" --arg b "$branch" '{task: $t, container: $c, port: $p, branch: $b}'
  else
    echo "$id"
  fi
  echo "follow: agentic follow $id" >&2
}

cmd_status() {
  local all=0 json=0 id="" f st rows=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --json) json=1 ;;
      -*) die "unknown option $1" ;;
      *) id="$1" ;;
    esac
    shift
  done
  if [ -n "$id" ]; then
    need_config; need_task "$id"
    st="$(task_status_json "$id")"
    if [ "$json" = 1 ]; then printf '%s\n' "$st"; return; fi
    jq -r --arg id "$id" '"\($id)  \(.state)\(if (.reason // "") != "" then " (" + .reason + ")" else "" end)  \(.agent)  \(.branch // "")",
      (if (.summary // "") != "" then "summary: " + .summary else empty end),
      ((.questions // [])[] | "\(.id) (\(.source)): \(.text)\(if (.options | length) > 0 then " [" + (.options | join(", ")) + "]" else "" end)\(if .recommendation then " recommended: " + .recommendation else "" end)"),
      (if ((.questions // []) | length) > 0 then "reply: agentic answer \($id) \(.questions[0].id) \"…\"" else empty end)' <<<"$st"
    return
  fi
  local files=()
  if [ "$all" = 1 ]; then
    files=("$AGENTIC_WORKSPACES"/*/tasks/*/state.json)
  else
    need_config
    files=("$(task_ws)"/tasks/*/state.json)
  fi
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    id="$(basename "$(dirname "$f")")"
    rows+=("$(TASK_PROJECT="$(jq -r .project "$f")" task_status_json "$id")")
  done
  if [ "$json" = 1 ]; then printf '%s\n' "${rows[@]}" | jq -s .; return; fi
  printf '%-18s %-11s %-8s %-9s %-5s %s\n' TASK STATE AGENT QUESTIONS AGE BRANCH
  for st in "${rows[@]}"; do
    [ -n "$st" ] || continue
    printf '%-18s %-11s %-8s %-9s %-5s %s\n' "$(jq -r .task <<<"$st")" "$(jq -r .state <<<"$st")" "$(jq -r .agent <<<"$st")" \
      "$(jq -r 'if has("questions") then (.questions | length) else (.open_questions // 0) end' <<<"$st")" "$(age "$(jq -r .created <<<"$st")")" "$(jq -r '.branch // ""' <<<"$st")"
  done
}
```

In `main`, add `run) cmd_run "$@" ;;` and `status) cmd_status "$@" ;;`. In `usage`, add:

```
  run "prompt" [--agent A] [--allow push|open-pr|deploy:T]... [--repo R]... [--base REF] [--branch B] [--id ID] [--json]
                                     start a detached task; prints its id
  status [ID] [--all] [--json]       list tasks, or one task with its open questions
```

(`TASK_PROJECT=… task_status_json` sets the project for that one call, so `--all` finds each project's containers and files.)

- [ ] **Step 7: Run tests and lint**

Run: `bats tests/bats/cli-task-run.bats && make test && make lint`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/host/task.sh lib/host/common.sh bin/agentic tests/bats/cli-task-run.bats tests/bats/docker-stub.bash tests/bats/helpers.bash
git commit -m "feat: agentic run and status: worktrees, task directory, tokens, bridge container, listing"
```

---

### Task 12: Host: follow, send, answer, cancel, stop, resume, logs, shell, takeover, clean

**Files:**
- Create: `tests/bats/cli-task-verbs.bats`
- Modify: `lib/host/task.sh`, `bin/agentic`, `tests/bats/docker-stub.bash`

**Interfaces:**
- Consumes: Task 11's helpers.
- Produces: `ensure_running ID` (starts a task's container unless it is stopped, honouring the cap, and waits for the bridge); `bridge_result ID` (prints `ID: state (reason)` for a 2xx answer, else dies with the bridge's message and the HTTP code); the verbs of spec §15.

- [ ] **Step 1: Let the docker stub remember `docker start`**

In `tests/bats/docker-stub.bash`, make the `State.Status` branch read a state file first and add a `start)` case:

```bash
  inspect)
    if [[ "$*" == *State.Status* ]]; then
      if [ -f "$BATS_TEST_TMPDIR/docker.status" ]; then cat "$BATS_TEST_TMPDIR/docker.status"; exit 0; fi
      [ -n "${DOCKER_STATUS:-}" ] || exit 1; echo "$DOCKER_STATUS"; exit 0
    fi
    [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  start) echo running > "$BATS_TEST_TMPDIR/docker.status" ;;
```

- [ ] **Step 2: Write the tests (failing)**

`tests/bats/cli-task-verbs.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  install_curl_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q -b main "$PROJ"
  printf 'version: 1\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@example.com commit -qm init
  A="$REPO_ROOT/bin/agentic"
  export DOCKER_STATUS=running DOCKER_PORT=49153 AGENTIC_WSLG_DIR="$BATS_TEST_TMPDIR/no-wslg"
  T="$AGENTIC_WORKSPACES/demo/tasks"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }
# record ID STATE: a task directory with a state.json, tokens and mounts, as run and the bridge leave them.
record() {
  mkdir -p "$T/$1"
  jq -n --arg id "$1" --arg s "$2" '{version:1, task:$id, project:"demo", agent:"claude", state:$s, reason:"",
    session:"s1", branch:("agentic/" + $id), created:"2026-10-12T10:00:00Z", updated:"t", seq:1,
    allowed_actions:[], summary:"", stopped_by_user:false}' > "$T/$1/state.json"
  printf 'AGENTIC_TASK_TOKEN=tok-task-0123456789\nAGENTIC_AGENT_TOKEN=tok-agent-0123456789\n' > "$T/$1.env"
  printf -- '-v\n%s\n' "$T/$1:/task" > "$T/$1.mounts"
}
posted() { grep '^arg: http://127.0.0.1:49153/' "$CURL_LOG" | sed 's#^arg: http://127.0.0.1:49153##' | tr '\n' ' '; }

# Review Focus 3
@test "send passes the text byte-identical and prints the new state" {
  record T-1 idle
  text=$'line one\nline "two" with $HOME, `ticks` and ünïcødé ✓'
  CURL_BODY='{"state":"running","reason":""}' run ag send T-1 "$text"
  [ "$status" -eq 0 ]
  [ "$output" = "T-1: running" ]
  [ "$(curl_body 1 | jq -r .text)" = "$text" ]
  run grep -q tok-task-0123456789 <(grep '^arg: ' "$CURL_LOG")
  [ "$status" -ne 0 ]
}

@test "send to a suspended task starts its container first; a stopped task refuses" {
  record T-2 suspended
  DOCKER_STATUS=exited run ag send T-2 "go on"
  [ "$status" -eq 0 ]
  grep -qx -- '--- start' "$DOCKER_LOG"
  [[ "$(posted)" == *"/status /prompt"* ]]
  record T-3 stopped
  DOCKER_STATUS=exited run ag send T-3 "x"
  [ "$status" -eq 1 ]; [[ "$output" == *"task T-3 is stopped"* ]]
}

@test "the bridge's refusal is shown with its message" {
  record T-4 running
  CURL_CODE=409 CURL_BODY='{"error":{"code":"conflict","message":"a turn is in progress; cancel first"}}' run ag send T-4 "x"
  [ "$status" -eq 1 ]
  [ "$output" = "agentic: a turn is in progress; cancel first (HTTP 409)" ]
}

@test "answer sends the question id, the text and the grants" {
  record T-5 waiting
  ag answer T-5 Q2 "yes, push" --allow push --allow deploy:dev
  [ "$(curl_body 1 | jq -c .)" = '{"text":"yes, push","grant":["push","deploy:dev"],"question":"Q2"}' ]
  ag answer T-5 "no"
  [ "$(curl_body 2 | jq -c .)" = '{"text":"no","grant":[]}' ]
  run ag answer T-5
  [ "$status" -eq 1 ]; [[ "$output" == *usage* ]]
}

@test "cancel needs a running task" {
  record T-6 idle
  ag cancel T-6
  [[ "$(posted)" == *"/cancel"* ]]
  DOCKER_STATUS=exited run ag cancel T-6
  [ "$status" -eq 1 ]; [[ "$output" == *"not running"* ]]
}

@test "stop asks the bridge, then waits for the container; without an answer it stops the container" {
  record T-7 idle
  ag stop T-7
  [[ "$(posted)" == *"/stop"* ]]
  grep -qx -- '--- wait' "$DOCKER_LOG"
  : > "$DOCKER_LOG"
  CURL_RC=7 run ag stop T-7
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not answer"* ]]
  grep -qx -- '--- stop' "$DOCKER_LOG"
}

@test "resume is for interrupted or failed tasks and sends the resume prompt" {
  record T-8 idle
  run ag resume T-8
  [ "$status" -eq 1 ]; [[ "$output" == *"resume is for interrupted or failed tasks"* ]]
  record T-9 running
  DOCKER_STATUS=exited run ag resume T-9
  [ "$status" -eq 0 ]
  grep -qx -- '--- start' "$DOCKER_LOG"
  [ "$(curl_body 2 | jq -r .text)" = "You were interrupted. Check git status and continue." ]
}

@test "logs prints the transcript or the bridge log" {
  record T-10 idle
  printf '> hello\n' > "$T/T-10/transcript.md"
  printf 'listening\n' > "$T/T-10/bridge.log"
  [ "$(ag logs T-10)" = "> hello" ]
  [ "$(ag logs T-10 --bridge)" = listening ]
}

@test "follow runs the follow client in the container; a task that is not running points to logs" {
  record T-11 idle
  ag follow T-11 --since 3
  call="$(docker_sub exec)"
  [ "$(tail -n 5 <<<"$call" | tr '\n' ' ')" = "agentic-demo-task-T-11 agentic-bridge follow --since 3 " ]
  DOCKER_STATUS=exited run ag follow T-11
  [ "$status" -eq 1 ]; [[ "$output" == *"agentic logs T-11"* ]]
}

@test "shell opens a login shell in the running container" {
  record T-12 idle
  ag shell T-12
  [ "$(docker_sub exec | tail -n 3 | tr '\n' ' ')" = "agentic-demo-task-T-12 bash -l " ]
}

@test "takeover stops the task and resumes its session interactively, gate on" {
  record T-13 idle
  ag takeover T-13
  [[ "$(posted)" == *"/stop"* ]]
  call="$(docker_sub run)"
  grep -qx -- '--rm' <<<"$call"
  grep -qx 'AGENTIC_GATE=1' <<<"$call"
  grep -qx "$T/T-13:/task" <<<"$call"
  [ "$(tail -n 4 <<<"$call" | tr '\n' ' ')" = "claude --dangerously-skip-permissions --resume s1 " ]
}

@test "clean refuses unpushed commits unless forced, then removes everything but remote branches" {
  ag run --id T-14 "x" >/dev/null 2>&1
  wt="$AGENTIC_WORKSPACES/demo/repos/proj/.worktrees/T-14"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m work
  run ag clean T-14
  [ "$status" -eq 1 ]; [[ "$output" == *"commits on no remote branch"* ]]
  run ag clean T-14 --force
  [ "$status" -eq 0 ]
  [ ! -e "$wt" ] && [ ! -e "$T/T-14" ] && [ ! -e "$T/T-14.env" ]
  run git -C "$AGENTIC_WORKSPACES/demo/repos/proj" rev-parse --verify -q agentic/T-14-x
  [ "$status" -ne 0 ]
  grep -qx -- '--- rm' "$DOCKER_LOG"
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `bats tests/bats/cli-task-verbs.bats`
Expected: FAIL (verbs unknown).

- [ ] **Step 4: Add the helpers to `lib/host/task.sh`**

```bash
# ensure_running ID: starts the container of a task that is not stopped and waits for its bridge.
ensure_running() {
  local id="$1" st
  [ "$(container_status "$id")" = running ] && return 0
  st="$(task_state "$id")"
  [ "$st" != stopped ] || die "task $id is stopped"
  [ "$(container_status "$id")" != missing ] || die "task $id has no container (state: $st)"
  check_cap
  docker start "$(task_container "$id")" >/dev/null || die "could not start the container of $id"
  wait_bridge "$id" "${AGENTIC_START_TIMEOUT:-120}" || die "the bridge of $id did not come up; see agentic logs $id --start"
}

# bridge_result ID: the new state after a 2xx answer; otherwise the bridge's message.
bridge_result() {
  case "$BRIDGE_CODE" in
    2*) jq -r --arg id "$1" '"\($id): \(.state)\(if (.reason // "") != "" then " (" + .reason + ")" else "" end)"' <<<"$BRIDGE_BODY" ;;
    *) die "$(jq -r '.error.message // "request failed"' <<<"$BRIDGE_BODY" 2>/dev/null || echo "request failed") (HTTP $BRIDGE_CODE)" ;;
  esac
}

# need_running ID: dies unless the task's container runs.
need_running() { [ "$(container_status "$1")" = running ] || die "task $1 is not running (state: $(task_state "$1"))"; }
```

- [ ] **Step 5: Add the verbs to `bin/agentic`**

```bash
cmd_send() {
  need_config
  [ $# -eq 2 ] || die 'usage: agentic send ID "text"'
  need_task "$1"; ensure_running "$1"
  bridge_call "$1" POST /prompt "$(jq -cn --arg t "$2" '{text: $t}')"
  bridge_result "$1"
}

cmd_answer() {
  need_config
  local id="" q="" text="" pos=() grants=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow) optval "$@"; grants+=("$2"); shift 2 ;;
      -*) die "unknown option $1" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  case "${#pos[@]}" in
    2) id="${pos[0]}"; text="${pos[1]}" ;;
    3) id="${pos[0]}"; q="${pos[1]}"; text="${pos[2]}" ;;
    *) die 'usage: agentic answer ID [QID] "text" [--allow A]...' ;;
  esac
  need_task "$id"; ensure_running "$id"
  bridge_call "$id" POST /answer "$(jq -cn --arg q "$q" --arg t "$text" \
    '{text: $t, grant: $ARGS.positional} + (if $q == "" then {} else {question: $q} end)' --args "${grants[@]}")"
  bridge_result "$id"
}

cmd_cancel() {
  need_config; need_task "${1:-}"; need_running "$1"
  bridge_call "$1" POST /cancel
  bridge_result "$1"
}

cmd_stop() {
  need_config; need_task "${1:-}"
  local id="$1" c; c="$(task_container "$1")"
  if [ "$(task_state "$id")" = stopped ]; then echo "$id: stopped"; return 0; fi
  ensure_running "$id"
  if bridge_req "$id" POST /stop && [[ "$BRIDGE_CODE" == 2* ]]; then
    timeout 30 docker wait "$c" >/dev/null 2>&1 || docker stop "$c" >/dev/null
  else
    say "the bridge of $id did not answer; stopping its container (the task will show interrupted)"
    docker stop "$c" >/dev/null
  fi
  echo "$id: $(task_state "$id")"
}

cmd_resume() {
  need_config; need_task "${1:-}"
  local id="$1" st; st="$(task_state "$1")"
  case "$st" in
    interrupted|failed) ;;
    *) die "task $id is $st; resume is for interrupted or failed tasks (agentic send continues the others)" ;;
  esac
  ensure_running "$id"
  bridge_call "$id" POST /prompt "$(jq -cn '{text: "You were interrupted. Check git status and continue."}')"
  bridge_result "$id"
}

cmd_logs() {
  need_config
  local id="" what=transcript a
  for a in "$@"; do
    case "$a" in
      --transcript) what=transcript ;; --bridge) what=bridge ;; --start) what=start ;;
      -*) die "unknown option $a" ;;
      *) id="$a" ;;
    esac
  done
  need_task "$id"
  case "$what" in
    transcript) cat "$(task_dir "$id")/transcript.md" 2>/dev/null || echo "(no transcript yet)" ;;
    bridge) cat "$(task_dir "$id")/bridge.log" 2>/dev/null || echo "(no bridge log yet)" ;;
    start) docker logs "$(task_container "$id")" 2>&1 ;;
  esac
}

cmd_follow() {
  need_config
  local id="${1:-}"; [ -n "$id" ] || die "usage: agentic follow ID [--since N] [--raw] [--forever]"
  shift; need_task "$id"
  [ "$(container_status "$id")" = running ] || die "task $id is $(task_state "$id"); agentic logs $id shows its transcript"
  local tty=(-i); if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
  docker exec "${tty[@]}" "$(task_container "$id")" agentic-bridge follow "$@"
}

cmd_task_shell() {
  need_config; need_task "${1:-}"; need_running "$1"
  docker exec -it "$(task_container "$1")" bash -l
}

cmd_takeover() {
  need_config; need_task "${1:-}"
  local id="$1" agent session img c mounts=() argv=()
  agent="$(record_get "$id" .agent)"; session="$(record_get "$id" .session)"; c="$(task_container "$id")"
  [ -n "$session" ] || die "task $id has no session yet"
  case "$agent" in
    claude) argv=(claude --dangerously-skip-permissions --resume "$session") ;;
    copilot) argv=(copilot --allow-all "--resume=$session") ;;
    *) die "task $id has an unknown agent '$agent'" ;;
  esac
  if [ "$(task_state "$id")" != stopped ]; then
    ensure_running "$id"
    bridge_req "$id" POST /stop || true
    timeout 30 docker wait "$c" >/dev/null 2>&1 || docker stop "$c" >/dev/null 2>&1 || true
  fi
  img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || run_image)"
  mapfile -t mounts < "$(task_file "$id" mounts)"
  RUN_ARGS=(); shared_run_args "$img"
  echo "Taking over $id with $agent; the task stays stopped afterwards." >&2
  docker run --rm -it "${mounts[@]}" "${RUN_ARGS[@]}" -e AGENTIC_GATE=1 "$img" "${argv[@]}"
}

cmd_clean() {
  need_config
  local id="" force=0 a clone wt branch
  for a in "$@"; do case "$a" in --force) force=1 ;; *) id="$a" ;; esac; done
  need_task "$id"
  if [ "$force" = 0 ] && [ -f "$(task_file "$id" repos)" ]; then
    while read -r clone wt branch; do
      [ -d "$wt" ] || continue
      if [ -n "$(git -C "$wt" log --oneline HEAD --not --remotes 2>/dev/null | head -n 1)" ]; then
        die "$wt has commits on no remote branch ($branch); push them, or run agentic clean $id --force"
      fi
    done < "$(task_file "$id" repos)"
  fi
  rollback_task "$id"
  echo "$id: removed (remote branches stay)"
}
```

`shell` already exists (a throwaway container). Dispatch `agentic shell ID` to `cmd_task_shell` when its only argument names a task: in `main`, change the `shell)` line to:

```bash
    shell) if [ "$#" -eq 1 ] && valid_task_id "$1" && [ -f "$(task_dir "$1" 2>/dev/null)/state.json" ]; then cmd_task_shell "$1"; else cmd_shell "$@"; fi ;;
```

Add the other verbs to `main`: `send`, `answer`, `cancel`, `stop`, `resume`, `logs`, `follow`, `takeover`, `clean`. Extend `usage`:

```
  follow ID [--since N] [--raw]      stream a running task's events until it waits, idles or ends
  send ID "text"                     a new prompt (starts a suspended task)
  answer ID [QID] "text" [--allow A]...
                                     answer the oldest (or the named) open question; grants unblock the gate
  cancel ID | stop ID | resume ID    end the turn | end the task | continue an interrupted or failed task
  logs ID [--transcript|--bridge|--start]
  shell ID                           a shell in the running task container
  takeover ID                        stop the task and continue its session interactively
  clean ID [--force]                 remove the task's container, worktrees, branch and files
```

- [ ] **Step 6: Run tests and lint**

Run: `bats tests/bats/cli-task-verbs.bats tests/bats/cli-task-run.bats && make test && make lint`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/host/task.sh bin/agentic tests/bats/cli-task-verbs.bats tests/bats/docker-stub.bash
git commit -m "feat: task verbs: follow, send, answer with grants, cancel, stop, resume, logs, shell, takeover, clean"
```

---

### Task 13: Smoke: detached tasks end to end with the fake agent

**Files:**
- Modify: `tests/image/smoke.sh`

**Interfaces:**
- Consumes: everything; `AGENTIC_TASK_DOCKER_ARGS` (Task 11) mounts the fake agent.
- Produces: the smoke checks of spec §14.

- [ ] **Step 1: Add the task flow to `tests/image/smoke.sh`**

Before `step "doctor passes on the good setup"`, add:

```bash
step "detached tasks through bin/agentic, with the fake agent"
export AGENTIC_TASK_DOCKER_ARGS="-v $root/bridge/test:/fake:ro -e AGENTIC_ACP_CMD=[\"node\",\"/fake/fake-agent.mjs\"] -e FAKE_AGENT_STATE=/task/home/fake -e FAKE_ASK=cli"
ag() { (cd "$proj" && "$A" "$@"); }
tasks="$AGENTIC_WORKSPACES/smoke-project/tasks"
wait_state() {
  local id="$1" s=""; shift
  for _ in $(seq 1 90); do
    s="$(ag status "$id" --json 2>/dev/null | jq -r .state)"
    if [[ " $* " == *" $s "* ]]; then return 0; fi
    sleep 1
  done
  echo "state of $id: $s" >&2; ag logs "$id" --bridge >&2 || true; return 1
}

id="$(AGENTIC_IDLE_TIMEOUT=6 ag run --allow open-pr "hello")"
trap 'docker ps -aq --filter label=agentic.kind=task | xargs -r docker rm -f >/dev/null; rm -rf "$tmp"' EXIT
wait_state "$id" idle || fail "task: first turn"
ag status | grep -q "^$id " || fail "task: not listed"

ag send "$id" "SHELL:git push origin HEAD" >/dev/null
wait_state "$id" idle || fail "task: refused push"
grep -q '"type":"gate"' "$tasks/$id/events.jsonl" || fail "task: the gate refusal was not reported to the bridge"
grep -q 'refused: agentic gate: git push is not in allowed_actions' "$tasks/$id/transcript.md" || fail "task: refusal reason"

ag send "$id" "ASK:May I push?" >/dev/null
wait_state "$id" waiting || fail "task: the question did not make the task wait"
ag answer "$id" Q1 "yes" --allow push >/dev/null
wait_state "$id" idle || fail "task: answer"
grep -q 'ran: git push origin HEAD' "$tasks/$id/transcript.md" || fail "task: the push was not retried through the gate after the grant"

for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Status}}' "agentic-smoke-project-task-$id")" = exited ] && break
  sleep 1
done
[ "$(ag status "$id" --json | jq -r .state)" = suspended ] || fail "task: not suspended after the idle timeout"
ag send "$id" HISTORY >/dev/null
wait_state "$id" idle || fail "task: resume after suspension"
grep -Eq 'history: [1-9]' "$tasks/$id/transcript.md" || fail "task: the session was not loaded"
ag stop "$id" >/dev/null
[ "$(ag status "$id" --json | jq -r .state)" = stopped ] || fail "task: stop"

id2="$(AGENTIC_IDLE_TIMEOUT=300 ag run "second")"
wait_state "$id2" idle || fail "task 2: first turn"
ag follow "$id2" </dev/null | grep -q 'echo: second' || fail "task 2: follow"
docker kill "agentic-smoke-project-task-$id2" >/dev/null
[ "$(ag status "$id2" --json | jq -r .state)" = interrupted ] || fail "task 2: not interrupted after docker kill"
ag resume "$id2" >/dev/null
wait_state "$id2" idle || fail "task 2: resume"
grep -q 'echo: You were interrupted' "$tasks/$id2/transcript.md" || fail "task 2: resume prompt"

ag clean "$id" --force >/dev/null
ag clean "$id2" --force >/dev/null
[ -z "$(docker ps -aq --filter label=agentic.kind=task)" ] || fail "task: clean left a container"
unset AGENTIC_TASK_DOCKER_ARGS
```

- [ ] **Step 2: Run the smoke**

Run: `make smoke`
Expected: `smoke OK`. When a step fails, its `bridge.log` is printed; fix the cause in the bridge or the CLI, never by loosening the check.

- [ ] **Step 3: Run tests and lint**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/image/smoke.sh
git commit -m "test: smoke: detached tasks end to end: gate, question with a grant, suspension, resume, interrupt"
```

---

### Task 14: Documentation and the manual end-to-end script

**Files:**
- Create: `docs/tasks.md`, `tests/e2e/acp-e2e.sh`
- Modify: `docs/architecture.md`, `docs/overlay.md`, `README.md`, `docs/configuration.md` (regenerate only if `tools/gen-config-docs.sh --check` fails)

**Interfaces:**
- Consumes: the finished feature.
- Produces: the hub and integration contract (`docs/tasks.md`).

- [ ] **Step 1: Write `docs/tasks.md`**

Sections, in this order, with the content taken from the spec (copy the tables; keep the spec's wording where it is already a contract):

1. `# Detached tasks` — one paragraph: what a task is (one container, one bridge, one agent session), how to start one locally (`agentic run`), and that hubs use the same image, gate and API.
2. `## Quick start` — `agentic run --allow open-pr "…"`, `agentic follow ID`, `agentic answer ID Q1 "…" --allow push`, `agentic status`, `agentic stop ID`, `agentic clean ID`.
3. `## States` — the diagram and rules of spec §6.
4. `## API, version 1` — spec §8.1 (transport, tokens, Host/Origin with the any-port clarification of Task 8, threat model), §8.2 (routes and error body), the status object of §5.2 without `inbox` items.
5. `## Events` — spec §8.3 table and envelope example.
6. `## Files` — spec §5.1 layout, §5.2 record, §5.3 transcript.
7. `## Questions and the gate` — spec §9 (`agentic-ask`, grants, block formats, `hooks.d`).
8. `## Environment` — every variable of Task 9's list, plus `AGENTIC_GATE`, `AGENTIC_GATE_PROTECTED`, `AGENTIC_MAX_RUNNING`, `AGENTIC_START_TIMEOUT`, `AGENTIC_BRANCH_PREFIX`, `AGENTIC_TASK_DOCKER_ARGS` (test hook), `AGENTIC_ACP_CMD` (test hook), one line each with default.
9. `## Cloud` — spec §12, including the outbound-mode design paragraph.
10. `## Spike results` — a pointer to spec §13.

- [ ] **Step 2: Update `docs/architecture.md`**

- Principles: replace `- **Minimal.** State lives in files and container labels. No database, no server.` with `- **Minimal.** State lives in files and container labels. No database and no central server: one small bridge per task container.`
- Sub-projects table, row 2: `| 2 | Runtime and CLI | Detached tasks: one ACP bridge per task container (HTTP + WebSocket API), worktrees, questions with grants, the action gate behind AGENTIC_GATE, notify, \`run/status/follow/send/answer/cancel/stop/resume/takeover/clean\` | Autonomous mode, local and hub-less |`
- Replace `Not built here: an own API server, a UI protocol, ...` with `Not built here: a central server, a UI, a scheduler or a remote orchestrator; a hub provides them. Each task container has a small bridge with a light API (\`docs/tasks.md\`), which a hub may use or replace with its own driver.`
- Components diagram: replace the `CLI mode: harness in tmux (dev / task)` line with `├─ CLI mode:    dev (tmux) or task: agentic-bridge (ACP)` and the record line with `task files: state.json, events.jsonl, transcript.md (2)`.
- Decisions table: add `| Agent driving | ACP: claude-agent-acp for Claude, copilot --acp for Copilot | Structured events, cancel, permissions and session load without terminal scraping |`.

- [ ] **Step 3: Update `docs/overlay.md`**

Add a section `## Task hooks and the gate` listing: `/opt/agentic/hooks.d/<event>/*.sh` (image) and `/agentic-config/hooks.d/<event>/*.sh` (project), events `sessionstart userpromptsubmit pretooluse posttooluse stop sessionend`, payload on stdin, exit 2 on `pretooluse` refuses; `AGENTIC_GATE` (default on for `agentic-bridge` and worker mode); `AGENTIC_ALLOWED_ACTIONS` for workers without a task record; `AGENTIC_NOTIFY_WEBHOOK`; a worker adapter may run `agentic-bridge` or drive the agent itself — the hooks and gate apply either way.

- [ ] **Step 4: Update `README.md`**

Add `## Detached tasks` after the dev-mode section: the quick start of `docs/tasks.md` §2 and a link to `docs/tasks.md`.

- [ ] **Step 5: Write `tests/e2e/acp-e2e.sh`**

```bash
#!/usr/bin/env bash
# Manual end-to-end check with the real agents (spec §14); spends tokens. Needs a built project
# image and the developer's tokens in the project's .agentic/.env.
#   tests/e2e/acp-e2e.sh PROJECT_DIR [claude] [copilot]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$root/bin/agentic"
proj="${1:?usage: acp-e2e.sh PROJECT_DIR [claude] [copilot]}"; shift
agents=("$@"); [ "${#agents[@]}" -gt 0 ] || agents=(claude copilot)
ag() { (cd "$proj" && "$A" "$@"); }
fail() { echo "E2E FAILED: $*" >&2; exit 1; }
wait_state() {
  local id="$1" s=""; shift
  for _ in $(seq 1 300); do
    s="$(ag status "$id" --json | jq -r .state)"
    if [[ " $* " == *" $s "* ]]; then return 0; fi
    sleep 2
  done
  fail "$id stayed $s"
}

for agent in "${agents[@]}"; do
  echo "== $agent"
  id="$(ag run --agent "$agent" "Reply with exactly the word ONE and nothing else.")"
  wait_state "$id" idle
  [ "$(ag status "$id" --json | jq -r .summary)" = ONE ] || fail "$agent: first turn"
  ag send "$id" "Run the shell command 'git push origin HEAD' exactly once. If it is refused, run agentic-ask to ask whether you may push, then end your turn." >/dev/null
  wait_state "$id" waiting
  ag answer "$id" "Yes, you may push now; try again." --allow push >/dev/null
  wait_state "$id" idle
  ag logs "$id" | tail -n 30
  ag stop "$id" >/dev/null
  [ "$(ag status "$id" --json | jq -r .state)" = stopped ] || fail "$agent: stop"
  ag clean "$id" --force >/dev/null
  echo "$agent OK"
done
```

Make it executable. Run it once by hand for both agents (`tests/e2e/acp-e2e.sh <project> claude copilot`) and paste the result into the final report of this plan's execution; it is not part of `make`.

- [ ] **Step 6: Verify**

Run: `make test && make lint && make smoke`
Expected: all green; `tools/gen-config-docs.sh --check` passes (regenerate `docs/configuration.md` with `tools/gen-config-docs.sh` if Task 1 changed the schema docs and it fails).

- [ ] **Step 7: Commit**

```bash
git add docs/tasks.md docs/architecture.md docs/overlay.md README.md docs/configuration.md tests/e2e/acp-e2e.sh
git commit -m "docs: detached tasks: the task contract, architecture, overlay hooks, quick start, manual e2e"
```
