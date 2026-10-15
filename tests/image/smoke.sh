#!/usr/bin/env bash
# End-to-end check of agentic-dev-base: an overlay, a derived project image, the container start,
# CA trust, worker mode, a start without mounts, and doctor. Needs Docker, openssl and script(1).
# The checks are single-quoted on purpose: they expand inside the container. The task part touches
# only containers labelled agentic.project=smoke-project, and raises AGENTIC_MAX_RUNNING by the
# tasks already running on this host, so the developer's own tasks neither count nor get removed.
# shellcheck disable=SC2016
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$root/bin/agentic"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AGENTIC_DATA="$tmp/data" AGENTIC_WORKSPACES="$tmp/ws"
IMG=agentic-smoke-project:local
step() { echo "== $*"; }
fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }

step "overlay image"
docker build -q -t agentic-smoke-overlay:local "$root/tests/fixtures/smoke-overlay" >/dev/null

step "project repository, throwaway CA and server certificate (never committed)"
proj="$tmp/smoke-project"
cp -r "$root/tests/fixtures/smoke-project" "$proj"
cp -r "$root/tests/fixtures/wiki/good" "$proj/wiki-demo"
mv "$proj/wiki-demo/CLAUDE.fixture.md" "$proj/wiki-demo/CLAUDE.md"
mv "$proj/wiki-demo/dot-claude" "$proj/wiki-demo/.claude"
mv "$proj/wiki-demo/dot-github" "$proj/wiki-demo/.github"
git -C "$proj" init -q
git -C "$proj" add -A
git -C "$proj" -c user.name=smoke -c user.email=smoke@example.com commit -qm init
mkdir -p "$proj/.smoke-tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=agentic smoke CA" \
  -keyout "$tmp/ca.key" -out "$proj/.agentic/files/smoke-ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$proj/.smoke-tls/server.key" -out "$tmp/server.csr" 2>/dev/null
openssl x509 -req -in "$tmp/server.csr" -CA "$proj/.agentic/files/smoke-ca.crt" -CAkey "$tmp/ca.key" \
  -CAcreateserial -days 1 -out "$proj/.smoke-tls/server.crt" \
  -extfile <(printf 'subjectAltName=DNS:localhost') 2>/dev/null

step "agentic build"
(cd "$proj" && "$A" build) >/dev/null

in_box() { (cd "$proj" && "$A" shell bash -lc "$1" </dev/null); }
check() {
  local out
  echo "-- $1"
  out="$(in_box "$2" 2>&1)" || { echo "$out" >&2; fail "$1"; }
}

check "base tools" 'git --version && gh --version && jq --version && yq --version && tmux -V && rg --version \
  && aws --version && az version >/dev/null && docker --version && uv --version && claude --version \
  && copilot --version && ccusage --version \
  && command -v mcp-server-playwright && test -f /etc/agentic/container && [ "$(id -un)" = dev ]'
check "files keep the host owner" "[ \"\$(id -u)\" = $(id -u) ] && touch /work/.owner-check"
[ "$(stat -c %u "$proj/.owner-check")" = "$(id -u)" ] || fail "a file written in /work has the wrong owner"
check "JDKs 8, 17, 21 with 17 as default" 'test -x /opt/java/8/bin/java && test -x /opt/java/21/bin/java \
  && java -version 2>&1 | grep -q "\"17"'
check "Maven and Gradle toolchains list every JDK" '[ "$(grep -c "<version>" ~/.m2/toolchains.xml)" = 3 ] \
  && grep -q "/opt/java/8" ~/.gradle/gradle.properties'
check "use-java switches the shell" 'use-java 8 && java -version 2>&1 | grep -q "\"1.8"'
check "terraform, apt package, Dockerfile.extra, overlay preset" 'terraform version | grep -q 1.5.7 \
  && command -v tree && test -f /etc/agentic-extra && [ "$(hello)" = "hello 1.0" ]'
check "overlay step, overlay defaults and all skills" 'test -f ~/.overlay-step-ran \
  && [ "$(jq -r .hooks.on_start_required ~/.agentic/config.json)" = true ] \
  && test -f ~/.claude/skills/agentic-setup/SKILL.md && test -f ~/.claude/skills/overlay-skill/SKILL.md \
  && test -f ~/.claude/skills/smoke-skill/SKILL.md && test -f ~/.copilot/skills/smoke-skill/SKILL.md'
check "agentic-wiki and the /wiki skill" 'agentic-wiki -C /work/wiki-demo check \
  && test -f ~/.claude/skills/wiki/SKILL.md && test -f ~/.copilot/skills/wiki/SKILL.md \
  && grep -qx -- "- agentic-wiki" /opt/agentic/inventory.txt'
check "on-start hook ran" 'test -f ~/.on-start-ran'
check "setup lines: plugin for both harnesses, MCP with a reference, narrowed agent, instructions, volume" '
  claude plugin list 2>/dev/null | grep -q hello@smoke-marketplace && copilot plugin list 2>/dev/null | grep -q hello \
  && test -L ~/.claude/plugins \
  && jq -e ".mcpServers.fake.env.SMOKE_TOKEN == \"\${SMOKE_TOKEN}\"" ~/.claude/.claude.json \
  && jq -e ".mcpServers.fake" ~/.copilot/mcp-config.json \
  && test -f ~/.claude/agents/db.md && test ! -e ~/.copilot/agents/db.agent.md \
  && grep -q "smoke instructions" ~/.claude/CLAUDE.md && grep -q "smoke instructions" ~/.copilot/copilot-instructions.md \
  && mountpoint -q /home/dev/.m2'
echo "-- init --base takes the overlay's recommended lines"
(t="$(mktemp -d)" && git init -q "$t" && cd "$t" && "$A" init --base agentic-smoke-overlay:local >/dev/null \
  && grep -qF -- '- add mcp overlay-recommended -- true' .agentic/agentic.yaml && rm -rf "$t") \
  || fail "init --base did not take the overlay's recommended lines"
check "the project CA is trusted by curl, Node, Python and Java, and is in Chromium's store" '
  openssl s_server -accept 8443 -cert /work/.smoke-tls/server.crt -key /work/.smoke-tls/server.key -www -quiet &
  sleep 1
  curl -fsS -o /dev/null https://localhost:8443/ \
  && node -e "fetch(\"https://localhost:8443/\").then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))" \
  && python3 -c "import urllib.request; urllib.request.urlopen(\"https://localhost:8443/\")" \
  && java /work/Fetch.java https://localhost:8443/ \
  && certutil -L -d sql:$HOME/.pki/nssdb | grep -q agentic-smoke-ca'
check "tmux keeps UTF-8 under a terminal" 'tmux new-session -d -s u -x 40 -y 5 "echo ●; sleep 8" && sleep 1 \
  && TERM=xterm-256color timeout 3 script -qec "tmux attach -t u" /tmp/out >/dev/null 2>&1 </dev/null; grep -q ● /tmp/out'

step "with the gate on, git push is refused by the hook"
out="$(docker run --rm -e AGENTIC_GATE=1 "$IMG" bash -lc \
  'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}" | bash /opt/agentic/task/hook.sh claude pretooluse; echo "rc=$?"' 2>&1)"
[[ "$out" == *"git push is not in allowed_actions"* && "$out" == *"rc=2"* ]] || fail "gate in the image: got '$out'"

step "the bridge runs a task to idle with the fake agent; homes live on the task volume"
tk="$tmp/task-bridge"; mkdir -p "$tk"; printf 'hello\n' > "$tk/prompt.md"
docker rm -f agentic-smoke-bridge >/dev/null 2>&1 || true
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
[ -d "$tk/home/claude" ] || fail "bridge task: Claude home not on /task"
[ -d "$tk/home/copilot" ] || fail "bridge task: harness homes not on /task"
# PID 1 is the bridge (the launcher execs node): its own environment must carry the homes
docker exec agentic-smoke-bridge sh -c "tr '\\0' '\\n' < /proc/1/environ" > "$tmp/bridge.env"
grep -qx 'CLAUDE_CONFIG_DIR=/task/home/claude' "$tmp/bridge.env" || fail "bridge task: the bridge has no CLAUDE_CONFIG_DIR"
grep -qx 'COPILOT_HOME=/task/home/copilot' "$tmp/bridge.env" || fail "bridge task: the bridge has no COPILOT_HOME"
[ -L "$tk/home/claude/plugins" ] || fail "bridge task: plugins not linked into the task's Claude home"
docker exec agentic-smoke-bridge bash -lc 'test "$COPILOT_AUTO_UPDATE" = false && agentic-ask x 2>&1 | grep -q "only inside a task"' \
  || fail "bridge task: image env"
docker rm -f agentic-smoke-bridge >/dev/null

step "worker mode hands over to the overlay's adapter"
cfg_b64="$(base64 -w0 < "$proj/.agentic/agentic.yaml")"
out="$(docker run --rm -e AGENTIC_WORKER_MODE=fake -e "AGENTIC_CONFIG_B64=$cfg_b64" "$IMG" one two 2>/dev/null)"
[ "$out" = "FAKE-WORKER project=smoke-project args=one two" ] || fail "worker mode: got '$out'"

step "a start without any project mount clones the repository and finds its config"
git clone -q --bare "$proj" "$tmp/repo.git"
out="$(docker run --rm -v "$tmp/repo.git:/repo.git:ro" -e AGENTIC_REPO_URL=file:///repo.git "$IMG" \
  bash -lc 'test -f /work/.agentic/agentic.yaml && jq -r .project ~/.agentic/config.json && jq -e .mcpServers.fake ~/.claude/.claude.json >/dev/null' 2>/dev/null)"
[ "$out" = smoke-project ] || fail "no-mount start: got '$out'"

step "detached tasks through bin/agentic, with the fake agent"
# the project's origin: a bare repository mounted at the same path, so a granted push lands there
git clone -q --bare "$proj" "$tmp/origin.git"
git -C "$proj" remote add origin "$tmp/origin.git"
export AGENTIC_TASK_DOCKER_ARGS="-v $tmp/origin.git:$tmp/origin.git -v $root/bridge/test:/fake:ro -e AGENTIC_ACP_CMD=[\"node\",\"/fake/fake-agent.mjs\"] -e FAKE_AGENT_STATE=/home/dev/fake -e FAKE_ASK=cli"
ag() { (cd "$proj" && "$A" "$@"); }
tasks="$AGENTIC_WORKSPACES/smoke-project/tasks"
mine=(--filter label=agentic.kind=task --filter label=agentic.project=smoke-project)
others="$(docker ps -q --filter label=agentic.kind=task --filter status=running | grep -c . || true)"
export AGENTIC_MAX_RUNNING="$((others + ${AGENTIC_MAX_RUNNING:-3}))"
# wait_state ID STATE...: until the task is in one of the states.
wait_state() {
  local id="$1" s=""; shift
  for _ in $(seq 1 90); do
    s="$(ag status "$id" --json 2>/dev/null | jq -r .state)" || s=""
    if [[ " $* " == *" $s "* ]]; then return 0; fi
    sleep 1
  done
  echo "state of $id: $s" >&2; ag logs "$id" --bridge >&2 || true; return 1
}

# wait_suspended ID: until the task is suspended while its container still runs.
wait_suspended() {
  for _ in $(seq 1 60); do
    if [ "$(ag status "$1" --json 2>/dev/null | jq -r .state)" = suspended ] \
      && [ "$(docker inspect -f '{{.State.Status}}' "agentic-smoke-project-task-$1" 2>/dev/null)" = running ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

trap 'docker ps -aq "${mine[@]}" | xargs -r docker rm -f >/dev/null; docker ps -aq --filter label=agentic.project=multi-project | xargs -r docker rm -f >/dev/null; docker rm -f agentic-smoke-bridge >/dev/null 2>&1; rm -rf "$tmp"' EXIT
id="$(AGENTIC_IDLE_TIMEOUT=6 ag run --worktree --allow open-pr "hello")"
wait_state "$id" idle || fail "task: first turn"
out="$(ag status)"
grep -q "^$id " <<<"$out" || fail "task: not listed"
if [ ! -f "$AGENTIC_DATA/projects/smoke-project/tasks/$id/env" ] || [ -e "$tasks/$id.env" ]; then fail "task: the tokens are not host-private"; fi
[ -d "$proj/.worktrees/$id" ] || fail "task: no worktree in the checkout"

ag send "$id" "SHELL:git push origin HEAD" >/dev/null
wait_state "$id" idle || fail "task: refused push"
grep -q '"type":"gate"' "$tasks/$id/events.jsonl" || fail "task: the gate refusal was not reported to the bridge"
grep -q 'refused: agentic gate: git push is not in allowed_actions' "$tasks/$id/transcript.md" || fail "task: refusal reason"

ag send "$id" "ASK:May I push?" >/dev/null
wait_state "$id" waiting || fail "task: the question did not make the task wait"
ag answer "$id" Q1 "yes" --allow push >/dev/null
wait_state "$id" idle || fail "task: answer"
grep -q 'ran: git push origin HEAD (exit 0)' "$tasks/$id/transcript.md" || fail "task: the push was not retried through the gate after the grant"
git --git-dir="$tmp/origin.git" rev-parse -q --verify "refs/heads/$(jq -r .branch "$tasks/$id/state.json")" >/dev/null \
  || fail "task: the granted push did not reach origin"

ag send "$id" "ASK:Which DB?" >/dev/null
wait_state "$id" waiting || fail "task: the second question did not make the task wait"
wait_suspended "$id" || fail "task: not suspended, container running, after the idle timeout"
out="$(ag status "$id")"
grep -q '^Q2 (ask): Which DB?' <<<"$out" || fail "task: status of a suspended task does not list its open question"
grep -qF "reply: agentic answer $id Q2" <<<"$out" || fail "task: status of a suspended task has no reply hint"
if ag answer "$id" Q9 "x" >/dev/null 2>&1; then fail "task: an answer to an unknown question was accepted"; fi
[ "$(ag status "$id" --json | jq -r .state)" = suspended ] || fail "task: a refused answer changed the state"
ag answer "$id" Q2 "pg" >/dev/null
wait_state "$id" idle || fail "task: answer after suspension"
ag send "$id" HISTORY >/dev/null
wait_state "$id" idle || fail "task: resume after suspension"
grep -Eq 'history: [1-9]' "$tasks/$id/transcript.md" || fail "task: the session was not loaded"
ag stop "$id" >/dev/null
[ "$(ag status "$id" --json | jq -r .state)" = stopped ] || fail "task: stop"

id2="$(AGENTIC_IDLE_TIMEOUT=300 ag run "second")"
wait_state "$id2" idle || fail "task 2: first turn"
out="$(ag follow "$id2" </dev/null)" || fail "task 2: follow failed"
grep -q 'echo: second' <<<"$out" || fail "task 2: follow"
docker kill "agentic-smoke-project-task-$id2" >/dev/null
[ "$(ag status "$id2" --json | jq -r .state)" = interrupted ] || fail "task 2: not interrupted after docker kill"
ag resume "$id2" >/dev/null
wait_state "$id2" idle || fail "task 2: resume"
grep -q 'echo: You were interrupted' "$tasks/$id2/transcript.md" || fail "task 2: resume prompt"

ag stop "$id2" >/dev/null
id3="$(ag run --in "$id2" "third")"
wait_state "$id3" idle || fail "task 3: --in"
[ "$(sed -n 1p "$AGENTIC_DATA/projects/smoke-project/tasks/$id3/container")" = "agentic-smoke-project-task-$id2" ] || fail "task 3: not in task 2's container"
ag stop "$id3" >/dev/null

id4="$(ag run --auto-clean "fourth")"
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' "agentic-smoke-project-task-$id4" 2>/dev/null)" = exited ] && break; sleep 1; done
ag status >/dev/null
[ ! -e "$tasks/$id4" ] || fail "task 4: auto-clean left the record"
[ -z "$(docker ps -aq --filter "name=agentic-smoke-project-task-$id4")" ] || fail "task 4: auto-clean left the container"

step "a scheduled run: summary, result, nothing left"
mkdir -p "$tmp/bin"; printf '#!/bin/sh\n[ "$1" = -l ] && cat "%s/crontab" 2>/dev/null; [ "$1" = - ] && cat > "%s/crontab"; exit 0\n' "$tmp" "$tmp" > "$tmp/bin/crontab"
chmod +x "$tmp/bin/crontab"
PATH="$tmp/bin:$PATH" ag schedule add smoke-nightly --cron "0 2 * * *" --timeout 5m "fifth" >/dev/null
PATH="$tmp/bin:$PATH" ag schedule run smoke-nightly >/dev/null || fail "schedule run failed"
res="$(PATH="$tmp/bin:$PATH" ag schedule results smoke-nightly)"
grep -q '| State | stopped (scheduled-done) |' <<<"$res" || fail "scheduled run: wrong state: $res"
grep -q 'echo: The run ends now' <<<"$res" || fail "scheduled run: no summary: $res"
sid="$(sed -n 's/^| Task | \(T-[^ ]*\) |$/\1/p' <<<"$res")"
[ -n "$sid" ] || fail "scheduled run: no task id in the result"
[ -z "$(docker ps -aq --filter "name=agentic-smoke-project-task-$sid")" ] || fail "scheduled run: the container of $sid is left"
[ ! -e "$tasks/$sid" ] || fail "scheduled run: the task files of $sid are left"
PATH="$tmp/bin:$PATH" ag schedule remove smoke-nightly >/dev/null

ag clean "$id" --force >/dev/null
ag clean "$id2" >/dev/null || fail "task 2: clean of an unchanged task"
ag clean "$id3" >/dev/null || fail "task 3: clean"
[ ! -e "$proj/.worktrees/$id" ] || fail "task: clean left the worktree"
[ -z "$(docker ps -aq "${mine[@]}")" ] || fail "task: clean left a container"

step "a project with several repositories: run starts in the target"
mp="$tmp/multi-project"; mkdir -p "$mp"
for r in api web; do
  git init -q "$mp/$r"
  git -C "$mp/$r" -c user.name=s -c user.email=s@example.com commit -q --allow-empty -m init
done
(cd "$mp" && "$A" init --bare >/dev/null)
(cd "$mp" && "$A" target api >/dev/null)
idm="$(cd "$mp" && "$A" run "hello")"
mtasks="$AGENTIC_WORKSPACES/multi-project/tasks"
s=""
for _ in $(seq 1 90); do
  s="$(cd "$mp" && "$A" status "$idm" --json 2>/dev/null | jq -r .state)" || s=""
  [ "$s" = idle ] && break
  sleep 1
done
[ "$s" = idle ] || { (cd "$mp" && "$A" logs "$idm" --bridge) >&2 || true; fail "multi: first turn, state '$s'"; }
[ "$(jq -r .work "$mtasks/$idm/state.json")" = /work/api ] || fail "multi: the task does not work in the target"
(cd "$mp" && "$A" stop "$idm" >/dev/null && "$A" clean "$idm" >/dev/null) || fail "multi: clean"
unset AGENTIC_TASK_DOCKER_ARGS

step "doctor passes on the good setup"
(cd "$proj" && "$A" doctor) >"$tmp/doctor.out" 2>&1 || { cat "$tmp/doctor.out"; fail "doctor on a good setup"; }

step "removing a line removes what it set up; an MCP server added by hand stays"
in_box 'claude mcp add -s user mine -- true >/dev/null' || fail "could not add an MCP server by hand"
(cd "$proj" && "$A" remove mcp fake --no-build >/dev/null && "$A" build >/dev/null) || fail "remove and rebuild"
check "fake gone, mine kept" '! jq -e ".mcpServers.fake" ~/.claude/.claude.json && jq -e ".mcpServers.mine" ~/.claude/.claude.json \
  && ! jq -e ".mcpServers.fake" ~/.copilot/mcp-config.json'

step "doctor fails on a broken setup (an MCP server added by hand whose command is missing)"
in_box 'claude mcp add -s user broken -- does-not-exist >/dev/null' || fail "could not add the broken server"
if (cd "$proj" && "$A" doctor) >"$tmp/doctor.out" 2>&1; then cat "$tmp/doctor.out"; fail "doctor passed a broken setup"; fi
grep -q "mcp broken: command does-not-exist not found" "$tmp/doctor.out" || { cat "$tmp/doctor.out"; fail "doctor did not name the broken server"; }

docker volume rm agentic-smoke-project-m2 >/dev/null 2>&1 || true
echo "smoke OK"
