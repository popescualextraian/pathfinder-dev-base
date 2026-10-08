#!/usr/bin/env bash
# End-to-end check of agentic-dev-base: an overlay, a derived project image, the container start,
# CA trust, worker mode, a start without mounts, and doctor. Needs Docker, openssl and script(1).
# The checks are single-quoted on purpose: they expand inside the container.
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
git -C "$proj" init -q
git -C "$proj" add -A
git -C "$proj" -c user.name=smoke -c user.email=smoke@example.com commit -qm init
mkdir -p "$proj/.smoke-tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=agentic smoke CA" \
  -keyout "$tmp/ca.key" -out "$proj/.agentic/certs/smoke-ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$proj/.smoke-tls/server.key" -out "$tmp/server.csr" 2>/dev/null
openssl x509 -req -in "$tmp/server.csr" -CA "$proj/.agentic/certs/smoke-ca.crt" -CAkey "$tmp/ca.key" \
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
  && copilot --version && ccusage --version && mcp-atlassian --version && graphify --version \
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
  && [ "$(jq -r .git.host ~/.agentic/config.json)" = localhost ] \
  && test -f ~/.claude/skills/agentic-setup/SKILL.md && test -f ~/.claude/skills/overlay-skill/SKILL.md \
  && test -f ~/.claude/skills/smoke-skill/SKILL.md && test -f ~/.copilot/skills/smoke-skill/SKILL.md'
check "on-start hook ran" 'test -f ~/.on-start-ran'
check "MCP servers match the config" 'jq -e ".mcpServers.playwright.args | index(\"--headless\")" ~/.claude.json \
  && jq -e ".mcpServers.graphify" ~/.claude.json \
  && jq -e ".mcpServers.atlassian.args | index(\"--jira-url\")" ~/.claude.json \
  && jq -e ".mcpServers.playwright.type == \"local\"" ~/.copilot/mcp-config.json'
check "plugins are baked, linked and enabled" 'test -L ~/.claude/plugins \
  && jq -e ".plugins[\"superpowers@claude-plugins-official\"]" ~/.claude/plugins/installed_plugins.json \
  && jq -e ".enabledPlugins[\"superpowers@claude-plugins-official\"]" ~/.claude/settings.json'
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

step "worker mode hands over to the overlay's adapter"
cfg_b64="$(base64 -w0 < "$proj/.agentic/agentic.yaml")"
out="$(docker run --rm -e AGENTIC_WORKER_MODE=fake -e "AGENTIC_CONFIG_B64=$cfg_b64" "$IMG" one two 2>/dev/null)"
[ "$out" = "FAKE-WORKER project=smoke-project args=one two" ] || fail "worker mode: got '$out'"

step "a start without any project mount clones the repository and finds its config"
git clone -q --bare "$proj" "$tmp/repo.git"
out="$(docker run --rm -v "$tmp/repo.git:/repo.git:ro" -e AGENTIC_REPO_URL=file:///repo.git "$IMG" \
  bash -lc 'test -f /work/.agentic/agentic.yaml && jq -r .project ~/.agentic/config.json && jq -e .mcpServers.playwright ~/.claude.json >/dev/null' 2>/dev/null)"
[ "$out" = smoke-project ] || fail "no-mount start: got '$out'"

step "doctor passes on the good setup"
(cd "$proj" && "$A" doctor) >"$tmp/doctor.out" 2>&1 || { cat "$tmp/doctor.out"; fail "doctor on a good setup"; }

step "doctor fails on a broken setup (no rebuild needed: MCP servers are run-time config)"
printf '  custom:\n    - {name: broken, type: stdio, command: does-not-exist}\n' >> "$proj/.agentic/agentic.yaml"
if (cd "$proj" && "$A" doctor) >"$tmp/doctor.out" 2>&1; then cat "$tmp/doctor.out"; fail "doctor passed a broken setup"; fi
grep -q "mcp broken: command does-not-exist not found" "$tmp/doctor.out" || { cat "$tmp/doctor.out"; fail "doctor did not name the broken server"; }

echo "smoke OK"
