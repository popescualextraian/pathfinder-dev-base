# Sub-project 1 — Base Image and Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `agentic-dev-base`: a generic base image, a per-project derived image rendered from
`.agentic/agentic.yaml`, an idempotent entrypoint that applies run-time config, the host CLI
(`init`, `build`, `login`, `setup`, `shell`, `dev`, `doctor`), the `/agentic-setup` skill, the
overlay contract and worker-mode hook, and the leak check.

**Architecture:** The host CLI (`bin/agentic`, bash) stays thin: it finds the project, assembles
`docker run`/`docker build` arguments and delegates every config decision to scripts that run
inside the image (`/opt/agentic`). Inside, `agentic-config` resolves `agentic.yaml` (base
defaults < overlay defaults < project) to JSON with `yq`, validates it with a small JSON-Schema
subset checker written in `jq`, and the renderer turns it into `Dockerfile.derived`. The
entrypoint runs numbered start steps (`/opt/agentic/start.d/NN-*.sh`), each idempotent and with a
`--check` mode that `agentic doctor` reuses.

**Tech Stack:** bash 5, jq 1.7, yq v4 (mikefarah), Docker (buildx), Ubuntu 24.04, bats-core,
shellcheck, openssl (smoke test only).

**Spec:** `docs/specs/2026-10-07-sub-project-1-base-image-design.md` (umbrella:
`docs/architecture.md`). Read both before starting.

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail` (start steps: `set -uo pipefail`, they
  return explicit codes), short comments, shellcheck-clean.
- A bats test for every behaviour, written before the code. `make test` and `make lint` green
  after every task; tasks touching `image/` also run `make smoke` at the end of the plan (Task 14).
- No company resources anywhere in the repo: no certificates, company names, hosts or URLs.
  Examples use `example.com`. `tools/leak-check.sh` enforces this (Task 1).
- No secret is ever written to an image layer, to `~/.claude.json`, to `~/.agentic/env` or to a
  log. `${VAR}` references stay literal; the harness expands them when it connects.
- Commits: no `Co-Authored-By` or other attribution lines. The repository has no remote; never
  push.
- Host prerequisites for using the CLI: bash, git, Docker. Development prerequisites add bats,
  jq, yq v4, shellcheck.
- Image paths (fixed contract): `/opt/agentic/{lib,start.d,worker.d,tools,derive,bin,config,schema,skills,defaults}`,
  entrypoint `/opt/agentic/entrypoint.sh`, state `~/.agentic/` (`config.json`, `config-dir`,
  `env`, `start.log`), harness homes `/home/dev/.claude` and `/home/dev/.copilot`, code at
  `/work`, other repos at `/workspaces/<name>`, project config at `/agentic-config` (read-only).
- Start-step exit codes: `0` ok, `1` fatal (entrypoint stops, non-zero), `2` warning (logged,
  start continues). Steps export variables only by appending `export K=V` lines to
  `$AGENTIC_STATE/env` via `env_export`.
- Image names: base `agentic-dev-base:local`; derived `agentic-<project>:local`; dev container
  `agentic-<project>-dev`. Labels: `agentic.base.hash`, `agentic.project`, `agentic.config.hash`,
  `agentic.docker_socket`, `agentic.harness`.
- Host data dir `${AGENTIC_DATA:-$HOME/.agentic}`; per-project harness state under
  `$AGENTIC_DATA/projects/<project>/harness/{claude,copilot}`; other repos under
  `${AGENTIC_WORKSPACES:-$HOME/agentic-workspaces}/<project>`.
- Refinements of the spec made while planning (keep them; they are deliberate):
  - Harness state is per project (Claude keys sessions by working directory, and every project
    is `/work`); `agentic login` therefore runs once per project.
  - MCP `${VAR}` references stay literal instead of being expanded at start, so no token reaches
    disk; `40-mcp` warns about unset variables.
  - Copilot plugins install at first start into the persistent `~/.copilot`; Claude plugins are
    baked.
  - Git identity is passed at run time (`GIT_AUTHOR_*` env from host git config, overridden by
    `git.user_name/user_email`), not baked.
  - `gradle` is `false` or a version string. Preset versions are exact (`maven: "3.9.9"`), except
    `java`, `node`, `psql` and `dotnet`, which take a major (or channel) and install its latest GA
    at build time.
  - Cloning other `repos:` is its own step, `15-repos`, because it needs the config, which may
    come from the clone made by `05-workspace`.
  - `docker.socket` is read from the built image's label, so changing it needs `agentic build`.
  - Building the base behind a TLS-intercepting proxy: CA certificates in `~/.agentic/ca/*.crt`
    (or `$AGENTIC_BUILD_CA_DIR`) are passed as the optional build context `agentic-ca` and
    trusted before the first download. They stay in the developer's local image only.

## Review Focus

- **Project path with spaces** (`/home/u/my projects/app`): every mount and build path must work.
  Test in Task 9 (`run_args` quotes paths).
- **`.env` written on Windows** (CRLF line endings, quoted values): Docker's `--env-file` keeps `\r`
  and quotes, which silently breaks tokens. The CLI must refuse with a clear message. Test in
  Task 9.
- **Restarting an existing dev container**: the entrypoint runs again on the same home; nothing
  may duplicate (env file, MCP entries, skills) and hand-added MCP servers must survive. Tests in
  Task 5 (env file reset) and Task 6 (second run is a no-op).
- **Running a command from a subdirectory of the project**: the CLI must find the project root.
  Test in Task 9.
- **Corporate proxy variables** (`HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`): passed to `docker
  build` as build args and to every container. Test in Task 9.

---

## File map

```
agentic-dev-base/
├── Makefile                          Task 1  test, lint, build, smoke, docs
├── CLAUDE.md, README.md, .gitignore  Task 1, Task 13
├── .dockerignore                     Task 8
├── bin/agentic                       Task 9–12  host CLI (sources lib/host/*.sh)
├── lib/host/common.sh                Task 9   project discovery, env checks, run args
├── lib/host/aws.sh                   Task 9   AWS profile filter
├── lib/host/detect.sh                Task 10  repo → detected tools (pure bash)
├── config/defaults.yaml              Task 2   base defaults
├── schema/agentic.schema.json        Task 2   the schema (single source of truth)
├── image/
│   ├── Dockerfile                    Task 8   base image
│   ├── entrypoint.sh                 Task 5   runs start.d, entry modes
│   ├── lib/common.sh                 Task 2   paths, cfg accessors, env_export
│   ├── lib/config.sh                 Task 2   find, resolve, validate
│   ├── lib/schema-check.jq           Task 2   JSON-Schema subset checker
│   ├── lib/gitenv.sh                 Task 5   credential-helper env for a host
│   ├── start.d/05-workspace.sh … 90-project-hook.sh   Tasks 5–7
│   ├── worker.d/.gitkeep             Task 5
│   ├── tools/_lib.sh + 14 presets    Task 3
│   ├── bin/agentic-config            Task 2
│   ├── bin/agentic-trust-java, agentic-trust-nss, agentic-remap-user,
│   │   agentic-install-plugins, agentic-render-toolchains   Task 4
│   ├── bin/dev-shell                 Task 8
│   ├── bin/agentic-doctor            Task 12
│   └── profile.d/agentic.sh          Task 4   use-tool, use-java, use-node
├── derive/render-dockerfile.sh       Task 4
├── skills/agentic-setup/SKILL.md     Task 13
├── templates/dot-agentic/            Task 10  skeleton for `agentic init`
├── tools/leak-check.sh               Task 1
├── tools/gen-config-docs.sh          Task 13
├── docs/configuration.md, docs/overlay.md   Task 13
└── tests/
    ├── bats/helpers.bash             Task 1 (extended in Task 2)
    ├── bats/*.bats                   per task
    ├── fixtures/                     Tasks 4, 14
    ├── image/smoke.sh                Task 14
    └── e2e/README.md                 Task 14
```

All work happens in `/mnt/c/WSAGNENG/agentic-dev-base`.

---
### Task 1: Repository scaffold, test harness and leak check

**Files:**
- Create: `Makefile`, `.gitignore`, `.shellcheckrc`, `CLAUDE.md`, `tests/bats/helpers.bash`, `tools/leak-check.sh`
- Test: `tests/bats/leak-check.bats`

**Interfaces:**
- Produces: `make test` (runs `bats -r tests/bats`), `make lint` (shellcheck + leak check; later
  tasks append to the `lint` recipe), `tests/bats/helpers.bash` with `REPO_ROOT` and
  `make_tmp_home`, `tools/leak-check.sh [ROOT]` (exit 0 clean, 1 on any finding or missing
  denylist).

- [ ] **Step 1: Create the denylist outside the repository**

Ask the human for the company terms (names, domains, hosts) to deny and write them, one per line,
to `~/.config/agentic/leak-denylist.txt`. This file is never committed. If the human is not
available, create it with one line `acme-corp-internal` and tell them to fill it in.

- [ ] **Step 2: Write the test helpers**

`tests/bats/helpers.bash`:

```bash
# Shared helpers for bats tests. Source with: load helpers
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# An isolated HOME under the test's temp dir.
make_tmp_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}
```

- [ ] **Step 3: Write the failing leak-check tests**

`tests/bats/leak-check.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  export AGENTIC_LEAK_DENYLIST="$BATS_TEST_TMPDIR/deny.txt"
  printf '# comment\nacme-corp\n\n' > "$AGENTIC_LEAK_DENYLIST"
  echo 'hello' > "$R/ok.txt"
  LC="$REPO_ROOT/tools/leak-check.sh"
}

@test "clean repository passes" {
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "a denylisted term in a tracked file fails, case-insensitively" {
  echo 'see https://wiki.ACME-Corp.example' > "$R/doc.md"
  git -C "$R" add doc.md
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc.md"* ]]
}

@test "an untracked, not ignored file is checked too" {
  echo 'acme-corp' > "$R/new.txt"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
}

@test "an ignored file is not checked" {
  echo 'secret.txt' > "$R/.gitignore"
  echo 'acme-corp' > "$R/secret.txt"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
}

@test "certificates and keys outside tests/fixtures fail" {
  echo x > "$R/ca.crt"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ca.crt"* ]]
}

@test "certificates under tests/fixtures are allowed" {
  mkdir -p "$R/tests/fixtures"
  echo x > "$R/tests/fixtures/test.pem"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
}

@test "a real .env fails, .env.example passes" {
  echo 'A=1' > "$R/.env.example"
  run bash "$LC" "$R"
  [ "$status" -eq 0 ]
  echo 'A=1' > "$R/.env"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
}

@test "a missing denylist fails with a hint" {
  rm "$AGENTIC_LEAK_DENYLIST"
  run bash "$LC" "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configure your denylist"* ]]
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `bats tests/bats/leak-check.bats`
Expected: FAIL (`tools/leak-check.sh` does not exist).

- [ ] **Step 5: Implement the leak check**

`tools/leak-check.sh`:

```bash
#!/usr/bin/env bash
# Fails when tracked or new files contain a denylisted term, a key or certificate outside
# tests/fixtures/, or a real .env. The denylist lives outside the repository.
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
list="${AGENTIC_LEAK_DENYLIST:-$HOME/.config/agentic/leak-denylist.txt}"
if [ ! -s "$list" ]; then
  echo "leak-check: no denylist at $list; configure your denylist (one term per line)" >&2
  exit 1
fi
cd "$root"
mapfile -t files < <(git ls-files --cached --others --exclude-standard)
fail=0
existing=()
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  existing+=("$f")
  case "$f" in
    tests/fixtures/*) ;;
    *.crt|*.pem|*.key) echo "leak-check: $f: key or certificate outside tests/fixtures/"; fail=1 ;;
  esac
  case "$(basename "$f")" in
    .env.example) ;;
    .env|.env.*) echo "leak-check: $f: real .env file"; fail=1 ;;
  esac
done
terms="$(grep -vE '^[[:space:]]*(#|$)' "$list" || true)"
if [ -n "$terms" ] && [ "${#existing[@]}" -gt 0 ]; then
  hits="$(printf '%s\0' "${existing[@]}" \
    | xargs -0 grep -I -n -i -F -f <(printf '%s\n' "$terms") -- 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/leak-check: /'
    fail=1
  fi
fi
if [ "$fail" -eq 0 ]; then echo "leak-check: clean"; fi
exit "$fail"
```

`chmod +x tools/leak-check.sh`.

- [ ] **Step 6: Write the Makefile, .gitignore and CLAUDE.md**

`Makefile`:

```make
IMAGE ?= agentic-dev-base:local
SHELL_SOURCES = $(wildcard bin/agentic lib/host/*.sh image/*.sh image/lib/*.sh image/start.d/*.sh \
  image/tools/*.sh image/bin/* image/profile.d/*.sh derive/*.sh tools/*.sh tests/image/*.sh)

.PHONY: test lint build smoke

test:
	bats -r tests/bats

lint:
	shellcheck -x $(SHELL_SOURCES)
	tools/leak-check.sh

build:
	bin/agentic build-base

smoke: build
	IMAGE=$(IMAGE) bash tests/image/smoke.sh
```

`.shellcheckrc`:

```
# Image scripts source libraries by their runtime path (/opt/agentic/lib/...), which shellcheck
# cannot follow from the repository.
disable=SC1091
```

`.gitignore`:

```
/tests/tmp/
*.log
.agentic/.env
.agentic/.build/
```

`CLAUDE.md`:

```markdown
# CLAUDE.md — agentic-dev-base

A generic container toolbox for agentic development: base image, per-project derived image from
`.agentic/agentic.yaml`, start steps, host CLI. Design: `docs/architecture.md`; specs in
`docs/specs/`; plans in `docs/plans/`.

## Rules

- No company resources in this repository: no certificates, company names, hosts, URLs or
  product-specific integrations. Examples use `example.com`. `make lint` runs
  `tools/leak-check.sh` against your private denylist (`~/.config/agentic/leak-denylist.txt`).
- Company-specific pieces belong in a downstream overlay image built `FROM` the base
  (`docs/overlay.md`), never here.
- No secret in an image layer, `~/.claude.json`, `~/.agentic/env` or a log.
- bash style: `set -euo pipefail`, short comments, shellcheck-clean, a bats test for every
  behaviour, written first.
- No `Co-Authored-By` or other attribution lines in commits. No remote; do not push.

## Commands

    make test     # bats (needs bats, jq, yq v4)
    make lint     # shellcheck, schema, generated docs, leak check
    make build    # base image agentic-dev-base:local
    make smoke    # build, then tests/image/smoke.sh (Docker, openssl, script)

Every change needs `make test` and `make lint` green; a change under `image/`, `derive/`,
`config/` or `schema/` also needs `make smoke`.
```

- [ ] **Step 7: Run the tests and lint**

Run: `bats tests/bats/leak-check.bats && make lint`
Expected: 8 tests pass; shellcheck silent; `leak-check: clean`.

- [ ] **Step 8: Commit**

```bash
git add Makefile .gitignore .shellcheckrc CLAUDE.md tests/bats/helpers.bash tests/bats/leak-check.bats tools/leak-check.sh
git commit -m "chore: scaffold, test harness and leak check"
```

---

### Task 2: Config defaults, schema, checker and `agentic-config`

**Files:**
- Create: `config/defaults.yaml`, `schema/agentic.schema.json`, `image/lib/common.sh`,
  `image/lib/config.sh`, `image/lib/schema-check.jq`, `image/lib/config-rules.jq`,
  `image/bin/agentic-config`
- Modify: `tests/bats/helpers.bash` (add `make_agentic_dir`), `Makefile` (lint: schema)
- Test: `tests/bats/config.bats`

**Interfaces:**
- Consumes: `REPO_ROOT`, `make_tmp_home` (Task 1).
- Produces:
  - `image/lib/common.sh`: variables `AGENTIC_DIR` (default `/opt/agentic`), `AGENTIC_STATE`
    (default `$HOME/.agentic`), `RESOLVED` (`$AGENTIC_STATE/config.json`), `ENV_FILE`
    (`$AGENTIC_STATE/env`); functions `say TEXT`, `claude_dir`, `claude_json`, `copilot_dir`,
    `cfg JQ_EXPR` (string or empty), `cfg_true JQ_EXPR` (exit 0 when true), `cfg_json JQ_EXPR`
    (compact JSON), `config_dir`, `config_path REL` (`.agentic/x` → `<config dir>/x`),
    `env_export NAME VALUE`, `write_if_changed FILE CONTENT`.
  - `image/lib/config.sh`: `config_find` (prints the directory holding `agentic.yaml`; lookup
    `$AGENTIC_CONFIG_MOUNT` (default `/agentic-config`), then `$AGENTIC_WORK/.agentic` (default
    `/work/.agentic`), then `$AGENTIC_CONFIG_B64`), `config_resolve [DIR]` (compact JSON on
    stdout), `config_validate FILE` (errors on stdout, one per line, exit 1 if any).
  - `image/bin/agentic-config resolve [DIR] | validate [DIR] | get EXPR`.
  - `tests/bats/helpers.bash`: `make_agentic_dir` (assembles an `/opt/agentic` layout from repo
    paths under the test temp dir and exports `AGENTIC_DIR`, `AGENTIC_STATE`).

- [ ] **Step 1: Add the test helper**

Append to `tests/bats/helpers.bash`:

```bash
# An /opt/agentic layout built from the repository, as the image has it. Call after make_tmp_home.
make_agentic_dir() {
  export AGENTIC_DIR="$BATS_TEST_TMPDIR/opt-agentic"
  export AGENTIC_STATE="$HOME/.agentic"
  mkdir -p "$AGENTIC_DIR/defaults" "$AGENTIC_DIR/worker.d"
  local pair src
  for pair in lib:image/lib start.d:image/start.d tools:image/tools bin:image/bin derive:derive \
              config:config schema:schema skills:skills profile.d:image/profile.d; do
    src="$REPO_ROOT/${pair#*:}"
    if [ -e "$src" ]; then ln -s "$src" "$AGENTIC_DIR/${pair%%:*}"; fi
  done
}
```

- [ ] **Step 2: Write the failing tests**

`tests/bats/config.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  P="$BATS_TEST_TMPDIR/project/.agentic"
  mkdir -p "$P"
  AC="$REPO_ROOT/image/bin/agentic-config"
}

write() { printf '%s\n' "$2" > "$1"; }

@test "resolve merges base defaults, overlay defaults and the project, project last" {
  write "$AGENTIC_DIR/defaults/agentic.yaml" $'git:\n  host: git.example.com\nharness:\n  default: copilot'
  write "$P/agentic.yaml" $'version: 1\nproject: demo\nharness:\n  default: claude'
  run "$AC" resolve "$P"
  [ "$status" -eq 0 ]
  [ "$(jq -r .project <<<"$output")" = demo ]
  [ "$(jq -r .git.host <<<"$output")" = git.example.com ]
  [ "$(jq -r .harness.default <<<"$output")" = claude ]
  [ "$(jq -r .mcp.playwright.mode <<<"$output")" = headless ]
}

@test "lists from the project replace the defaults" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ntools:\n  apt: [tree]\n  python: ["3.11"]'
  run "$AC" resolve "$P"
  [ "$(jq -c .tools.python <<<"$output")" = '["3.11"]' ]
  [ "$(jq -c .tools.apt <<<"$output")" = '["tree"]' ]
}

@test "the smallest valid file validates" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "a missing project is reported" {
  write "$P/agentic.yaml" 'version: 1'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".project: is required"* ]]
}

@test "unknown keys and wrong types are reported with their path" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ndocker:\n  socket: "yes"\nfoo: 1'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".docker.socket: expected boolean, got string"* ]]
  [[ "$output" == *".foo: unknown key"* ]]
}

@test "project names are restricted to a safe pattern" {
  write "$P/agentic.yaml" $'version: 1\nproject: "My App"'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".project: does not match"* ]]
}

@test "java accepts false or versions with a default inside them" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ntools:\n  java: {versions: [17, 11], default: 11}'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ntools:\n  java: {versions: [17], default: 8}'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.java.default: 8 is not in versions"* ]]
}

@test "a version preset accepts false or a version string, not true" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ntools:\n  terraform: true'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".tools.terraform: matches none of the allowed forms"* ]]
}

@test "presets unknown to the base pass the schema (an overlay may provide them)" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\ntools:\n  hello: "1.0"'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "a literal secret is rejected, a reference is accepted" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com", headers: {api_token: abc123}}'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"api_token: literal secret"* ]]
  write "$P/agentic.yaml" $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com", headers: {api_token: "${DOCS_TOKEN}"}}'
  run "$AC" validate "$P"
  [ "$status" -eq 0 ]
}

@test "custom MCP servers need a command or url and may not take a built-in name" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: a, type: stdio}\n    - {name: playwright, type: http, url: "https://x.example.com"}'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a: stdio server needs command"* ]]
  [[ "$output" == *"playwright: name is reserved"* ]]
}

@test "atlassian enabled needs at least one URL" {
  write "$P/agentic.yaml" $'version: 1\nproject: demo\nmcp:\n  atlassian: {enabled: true}'
  run "$AC" validate "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *".mcp.atlassian: enabled needs jira_url or confluence_url"* ]]
}

@test "config_find prefers the mount, then /work/.agentic, then AGENTIC_CONFIG_B64" {
  source "$AGENTIC_DIR/lib/common.sh"; source "$AGENTIC_DIR/lib/config.sh"
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK/.agentic"
  export AGENTIC_CONFIG_B64; AGENTIC_CONFIG_B64="$(printf 'version: 1\nproject: fromenv\n' | base64 -w0)"
  [ "$(config_find)" = "$AGENTIC_STATE/env-config" ]
  [ "$(yq .project "$AGENTIC_STATE/env-config/agentic.yaml")" = fromenv ]
  touch "$AGENTIC_WORK/.agentic/agentic.yaml"
  [ "$(config_find)" = "$AGENTIC_WORK/.agentic" ]
  touch "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  [ "$(config_find)" = "$AGENTIC_CONFIG_MOUNT" ]
}

@test "config_path maps .agentic/ paths into the config directory" {
  source "$AGENTIC_DIR/lib/common.sh"
  mkdir -p "$AGENTIC_STATE"; echo /agentic-config > "$AGENTIC_STATE/config-dir"
  [ "$(config_path .agentic/certs)" = /agentic-config/certs ]
  [ "$(config_path /abs/x)" = /abs/x ]
}

@test "get reads the resolved config" {
  mkdir -p "$AGENTIC_STATE"; echo '{"project":"demo","docker":{"socket":false}}' > "$AGENTIC_STATE/config.json"
  run "$AC" get .project
  [ "$output" = demo ]
  run "$AC" get .docker.socket
  [ "$output" = false ]
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/config.bats`
Expected: FAIL (`agentic-config` missing).

- [ ] **Step 4: Write the defaults**

`config/defaults.yaml`:

```yaml
# Base defaults. An overlay's /opt/agentic/defaults/agentic.yaml and the project's
# .agentic/agentic.yaml are merged over this file, in that order; lists are replaced, not merged.
version: 1
base_image: agentic-dev-base:local
repos: []
git:
  host: github.com
  user_name: ""
  user_email: ""
tools:
  java: {versions: [21], default: 21}
  maven: "3.9.9"
  gradle: false
  node: {versions: [22], default: 22}
  python: ["3.12"]
  apt: []
  extra_dockerfile: .agentic/Dockerfile.extra
certs: .agentic/certs
plugins:
  claude: [superpowers@claude-plugins-official]
  copilot: []
  marketplaces: [anthropics/claude-plugins-official]
mcp:
  atlassian: {enabled: false, jira_url: "", confluence_url: ""}
  playwright: {enabled: true, mode: headless}
  graphify: {enabled: true}
  custom: []
skills: .agentic/skills
hooks:
  on_build: .agentic/hooks/on-build.sh
  on_start: .agentic/hooks/on-start.sh
  on_start_required: false
harness:
  default: claude
  claude: {model: ""}
  copilot: {model: ""}
docker:
  socket: false
```

- [ ] **Step 5: Write the schema**

`schema/agentic.schema.json` (descriptions feed `docs/configuration.md` in Task 13):

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "agentic.yaml",
  "description": "Project configuration for agentic-dev-base.",
  "type": "object",
  "required": ["version", "project"],
  "additionalProperties": false,
  "properties": {
    "version": {"description": "Schema version. Always 1.", "enum": [1]},
    "project": {"description": "Project name. Names the image agentic-<project>:local and the workspace directory.", "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,62}$"},
    "base_image": {"description": "Image the derived image is built FROM: the base or an overlay built FROM the base.", "type": "string", "minLength": 1},
    "repos": {
      "description": "Repositories. The first is the primary one, at /work; the others are cloned to /workspaces/<name>.",
      "type": "array",
      "items": {
        "type": "object", "required": ["name"], "additionalProperties": false,
        "properties": {
          "name": {"description": "Directory name.", "type": "string", "pattern": "^[A-Za-z0-9._-]+$"},
          "url": {"description": "Clone URL.", "type": "string"},
          "ref": {"description": "Branch or tag to check out.", "type": "string"}
        }
      }
    },
    "git": {
      "description": "Git settings.", "type": "object", "additionalProperties": false,
      "properties": {
        "host": {"description": "Git host for the credential helper and GH_HOST.", "type": "string"},
        "user_name": {"description": "Commit author name. Empty uses the host's git config.", "type": "string"},
        "user_email": {"description": "Commit author email. Empty uses the host's git config.", "type": "string"}
      }
    },
    "tools": {
      "description": "Build-time tools. Changing them needs agentic build.",
      "type": "object",
      "additionalProperties": {"description": "A preset provided by an overlay: false or a version.", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9A-Za-z][0-9A-Za-z.+_-]*$"}]},
      "properties": {
        "java": {"description": "JDK majors, installed side by side under /opt/java/<v>; 21 is always present. default sets JAVA_HOME.", "anyOf": [{"enum": [false]}, {"type": "object", "required": ["versions", "default"], "additionalProperties": false, "properties": {"versions": {"type": "array", "items": {"type": "integer", "minimum": 8}}, "default": {"type": "integer", "minimum": 8}}}]},
        "node": {"description": "Node majors, side by side under /opt/node/<v>; 22 is always present. default goes first on PATH.", "anyOf": [{"enum": [false]}, {"type": "object", "required": ["versions", "default"], "additionalProperties": false, "properties": {"versions": {"type": "array", "items": {"type": "integer", "minimum": 16}}, "default": {"type": "integer", "minimum": 16}}}]},
        "python": {"description": "Python versions installed with uv.", "type": "array", "items": {"type": "string", "pattern": "^3\\.[0-9]+$"}},
        "maven": {"description": "Maven version (exact, e.g. 3.9.9).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "gradle": {"description": "System Gradle version (exact). The wrapper (./gradlew) is the norm; false installs none.", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"}]},
        "terraform": {"description": "Terraform version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "checkov": {"description": "Checkov version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "tflint": {"description": "TFLint version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "kubectl": {"description": "kubectl version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "helm": {"description": "Helm version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "dotnet": {"description": ".NET SDK channel (e.g. 8.0).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+$"}]},
        "go": {"description": "Go version (exact, e.g. 1.22.5).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"}]},
        "glab": {"description": "GitLab CLI version (exact).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}]},
        "psql": {"description": "PostgreSQL client major (e.g. 16).", "anyOf": [{"enum": [false]}, {"type": "string", "pattern": "^[0-9]+$"}]},
        "apt": {"description": "Plain apt packages, optionally pinned (name=version).", "type": "array", "items": {"type": "string", "pattern": "^[a-z0-9][a-z0-9+.-]*(=[^ ]+)?$"}},
        "extra_dockerfile": {"description": "Dockerfile lines appended to the derived image, run as root, inside .agentic/.", "type": "string"}
      }
    },
    "certs": {"description": "Directory inside .agentic/ whose *.crt files are trusted by the system, Java, Node, Python and Chromium.", "type": "string"},
    "plugins": {
      "description": "Harness plugins. Claude plugins are baked at build time; Copilot plugins install at first start.",
      "type": "object", "additionalProperties": false,
      "properties": {
        "claude": {"description": "Claude plugins as name@marketplace.", "type": "array", "items": {"type": "string", "pattern": "^[^@ ]+@[^@ ]+$"}},
        "copilot": {"description": "Copilot plugins as name@marketplace.", "type": "array", "items": {"type": "string", "pattern": "^[^@ ]+@[^@ ]+$"}},
        "marketplaces": {"description": "Marketplace repositories (owner/repo) added before installing.", "type": "array", "items": {"type": "string"}}
      }
    },
    "mcp": {
      "description": "MCP servers, applied at every start without a rebuild.",
      "type": "object", "additionalProperties": false,
      "properties": {
        "atlassian": {"description": "Jira and Confluence (mcp-atlassian). Tokens: JIRA_PERSONAL_TOKEN, CONFLUENCE_PERSONAL_TOKEN in .env.", "type": "object", "additionalProperties": false, "properties": {"enabled": {"type": "boolean"}, "jira_url": {"type": "string"}, "confluence_url": {"type": "string"}}},
        "playwright": {"description": "Browser automation. headed needs a display; without one Xvfb starts.", "type": "object", "additionalProperties": false, "properties": {"enabled": {"type": "boolean"}, "mode": {"enum": ["headless", "headed"]}}},
        "graphify": {"description": "Code and docs graph server (graphify-out/graph.json in the working directory).", "type": "object", "additionalProperties": false, "properties": {"enabled": {"type": "boolean"}}},
        "custom": {
          "description": "Other MCP servers. ${VAR} references are expanded by the harness from the environment.",
          "type": "array",
          "items": {
            "type": "object", "required": ["name", "type"], "additionalProperties": false,
            "properties": {
              "name": {"type": "string", "pattern": "^[A-Za-z0-9_-]+$"},
              "type": {"enum": ["stdio", "http"]},
              "command": {"type": "string"},
              "args": {"type": "array", "items": {"type": "string"}},
              "env": {"type": "object", "additionalProperties": {"type": "string"}},
              "url": {"type": "string"},
              "headers": {"type": "object", "additionalProperties": {"type": "string"}}
            }
          }
        }
      }
    },
    "skills": {"description": "Directory inside .agentic/ with project skills (<name>/SKILL.md), copied into both harnesses.", "type": "string"},
    "hooks": {
      "description": "Project hooks.", "type": "object", "additionalProperties": false,
      "properties": {
        "on_build": {"description": "Script run as dev at the end of the derived build. Never sees .env.", "type": "string"},
        "on_start": {"description": "Script run as dev at every container start, with the full environment.", "type": "string"},
        "on_start_required": {"description": "When true, a failing on_start stops the container.", "type": "boolean"}
      }
    },
    "harness": {
      "description": "Harness choice and models.", "type": "object", "additionalProperties": false,
      "properties": {
        "default": {"description": "Harness used by agentic setup.", "enum": ["claude", "copilot"]},
        "claude": {"type": "object", "additionalProperties": false, "properties": {"model": {"description": "Model; empty uses the harness default.", "type": "string"}}},
        "copilot": {"type": "object", "additionalProperties": false, "properties": {"model": {"description": "Model; empty uses the harness default.", "type": "string"}}}
      }
    },
    "docker": {
      "description": "Docker access.", "type": "object", "additionalProperties": false,
      "properties": {
        "socket": {"description": "Mount the host Docker socket. It is host root; off by default. Changing it needs agentic build.", "type": "boolean"}
      }
    }
  }
}
```

- [ ] **Step 6: Write the checker modules**

`image/lib/schema-check.jq` — a JSON-Schema subset (type, enum, pattern, minimum, minLength,
required, properties, additionalProperties, items, anyOf):

```jq
# errs(schema; path): every violation of schema by ., as "path: message" strings.
def tname: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
def typeok($t): tname as $n | ($t | if type == "array" then . else [.] end)
  | any(.[]; . == $n or (. == "number" and $n == "integer"));
def tlabel($t): $t | if type == "array" then join(" or ") else . end;
def errs($s; $p):
  . as $v
  | if ($s | has("type")) and ($v | typeok($s.type) | not) then
      ["\($p): expected \(tlabel($s.type)), got \($v | tname)"]
    else
      (if ($s | has("enum")) and (($s.enum | index([$v])) == null)
         then ["\($p): must be one of \($s.enum | map(tojson) | join(", "))"] else [] end)
      + (if ($s | has("pattern")) and ($v | type) == "string" and (($v | test($s.pattern)) | not)
           then ["\($p): does not match \($s.pattern)"] else [] end)
      + (if ($s | has("minLength")) and ($v | type) == "string" and ($v | length) < $s.minLength
           then ["\($p): must not be empty"] else [] end)
      + (if ($s | has("minimum")) and ($v | type) == "number" and $v < $s.minimum
           then ["\($p): must be at least \($s.minimum)"] else [] end)
      + (if ($v | type) == "object" then
           [ ($s.required // [])[] | select(($v | has(.)) | not) | "\($p).\(.): is required" ]
           + [ $v | to_entries[] | .key as $k | .value as $x
               | if (($s.properties // {}) | has($k)) then ($x | errs($s.properties[$k]; "\($p).\($k)"))[]
                 elif $s.additionalProperties == false then "\($p).\($k): unknown key"
                 elif ($s.additionalProperties | type) == "object" then ($x | errs($s.additionalProperties; "\($p).\($k)"))[]
                 else empty end ]
         else [] end)
      + (if ($v | type) == "array" and ($s | has("items")) then
           [ range(0; $v | length) as $i | ($v[$i] | errs($s.items; "\($p)[\($i)]"))[] ]
         else [] end)
      + (if ($s | has("anyOf")) then
           ([ $s.anyOf[] as $alt | ($v | errs($alt; $p)) ]) as $alts
           | if any($alts[]; length == 0) then [] else ["\($p): matches none of the allowed forms"] end
         else [] end)
    end;
```

`image/lib/config-rules.jq` — rules JSON Schema cannot express here:

```jq
# semantic_errs: cross-field rules; run only on a schema-valid config.
def semantic_errs:
  . as $c
  | [ ($c.mcp.custom // [])[] | select(.type == "stdio" and ((.command // "") == ""))
      | ".mcp.custom: \(.name): stdio server needs command" ]
  + [ ($c.mcp.custom // [])[] | select(.type == "http" and ((.url // "") == ""))
      | ".mcp.custom: \(.name): http server needs url" ]
  + [ ($c.mcp.custom // [])[] | select(.name == "atlassian" or .name == "playwright" or .name == "graphify")
      | ".mcp.custom: \(.name): name is reserved for a built-in server" ]
  + [ ($c.mcp.custom // []) | group_by(.name)[] | select(length > 1)
      | ".mcp.custom: \(.[0].name): duplicate name" ]
  + [ ($c.mcp.atlassian // {}) | select(.enabled == true and ((.jira_url // "") == "") and ((.confluence_url // "") == ""))
      | ".mcp.atlassian: enabled needs jira_url or confluence_url" ]
  + [ (["java", 21], ["node", 22]) as [$t, $base]
      | ($c.tools[$t] // false) | select(type == "object") | . as $o
      | select($o.default != $base and (($o.versions | index($o.default)) == null))
      | ".tools.\($t).default: \($o.default) is not in versions" ];

# secret_errs: a literal value under a key that names a token, password or secret.
def secret_errs:
  [ paths(type == "string") as $p
    | select($p[-1] | tostring | ascii_downcase | test("token|password|secret"))
    | getpath($p) as $val
    | select($val != "" and ($val | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$") | not))
    | "." + ($p | map(tostring) | join(".")) + ": literal secret; reference it as ${VAR} and put the value in .agentic/.env" ];
```

- [ ] **Step 7: Write the shell libraries**

`image/lib/common.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for image scripts. Source, do not execute.
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
AGENTIC_STATE="${AGENTIC_STATE:-$HOME/.agentic}"
RESOLVED="$AGENTIC_STATE/config.json"
ENV_FILE="$AGENTIC_STATE/env"
export AGENTIC_DIR AGENTIC_STATE

say() { echo "agentic: $*" >&2; }

claude_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf '%s\n' "$CLAUDE_CONFIG_DIR/.claude.json"
  else printf '%s\n' "$HOME/.claude.json"; fi
}
copilot_dir() { printf '%s\n' "${COPILOT_HOME:-$HOME/.copilot}"; }

# cfg EXPR: a string from the resolved config, empty when missing or null.
cfg() { jq -r "($1) // empty" "$RESOLVED"; }
cfg_true() { jq -e "($1) == true" "$RESOLVED" >/dev/null 2>&1; }
cfg_json() { jq -c "$1" "$RESOLVED"; }

config_dir() { cat "$AGENTIC_STATE/config-dir" 2>/dev/null || true; }

# config_path REL: a config path (".agentic/x") as a path inside the config directory.
config_path() {
  local p="$1" d
  d="$(config_dir)"
  [ -n "$p" ] && [ -n "$d" ] || return 1
  case "$p" in
    .agentic/*) printf '%s\n' "$d/${p#.agentic/}" ;;
    /*) printf '%s\n' "$p" ;;
    *) printf '%s\n' "$d/$p" ;;
  esac
}

# env_export NAME VALUE: exported to the entrypoint's command and to dev-shell.
env_export() {
  mkdir -p "$AGENTIC_STATE"
  printf 'export %s=%q\n' "$1" "$2" >> "$ENV_FILE"
}

# write_if_changed FILE CONTENT: writes only on change, private to the user.
write_if_changed() {
  local f="$1" new="$2"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then return 0; fi
  mkdir -p "$(dirname "$f")"
  (umask 077; printf '%s\n' "$new" > "$f")
}
```

`image/lib/config.sh`:

```bash
#!/usr/bin/env bash
# Config discovery, resolution and validation. Source after common.sh.

# config_find: the directory holding agentic.yaml; nothing when there is none.
config_find() {
  local d
  for d in "${AGENTIC_CONFIG_MOUNT:-/agentic-config}" "${AGENTIC_WORK:-/work}/.agentic"; do
    if [ -f "$d/agentic.yaml" ]; then printf '%s\n' "$d"; return 0; fi
  done
  if [ -n "${AGENTIC_CONFIG_B64:-}" ]; then
    d="$AGENTIC_STATE/env-config"
    mkdir -p "$d"
    printf '%s' "$AGENTIC_CONFIG_B64" | base64 -d > "$d/agentic.yaml" || return 1
    printf '%s\n' "$d"
  fi
}

# config_resolve [DIR]: base defaults < overlay defaults < DIR/agentic.yaml, as compact JSON.
config_resolve() {
  local dir="${1:-}" files=("$AGENTIC_DIR/config/defaults.yaml")
  if [ -f "$AGENTIC_DIR/defaults/agentic.yaml" ]; then files+=("$AGENTIC_DIR/defaults/agentic.yaml"); fi
  if [ -n "$dir" ] && [ -f "$dir/agentic.yaml" ]; then files+=("$dir/agentic.yaml"); fi
  yq eval-all -o=json -I=0 '. as $item ireduce ({}; . * ($item // {}))' "${files[@]}"
}

# config_validate FILE: prints one error per line; exit 1 if there is any.
config_validate() {
  local errs
  errs="$(jq -r -L "$AGENTIC_DIR/lib" --slurpfile s "$AGENTIC_DIR/schema/agentic.schema.json" '
    include "schema-check"; include "config-rules";
    errs($s[0]; "") as $e
    | (if ($e | length) > 0 then $e else semantic_errs end) + secret_errs | .[]' "$1")" || return 1
  if [ -n "$errs" ]; then printf '%s\n' "$errs"; return 1; fi
}
```

- [ ] **Step 8: Write `agentic-config`**

`image/bin/agentic-config`:

```bash
#!/usr/bin/env bash
# Resolve, validate and query agentic.yaml. Usage: agentic-config resolve|validate [DIR] | get EXPR
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AGENTIC_DIR="${AGENTIC_DIR:-$(cd "$here/.." && pwd)}"
# shellcheck source=../lib/common.sh
source "$AGENTIC_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$AGENTIC_DIR/lib/config.sh"

dir_arg() {
  local d="${1:-}"
  if [ -z "$d" ]; then d="$(config_find)"; fi
  if [ -z "$d" ] || [ ! -f "$d/agentic.yaml" ]; then say "no agentic.yaml found"; exit 1; fi
  printf '%s\n' "$d"
}

case "${1:-}" in
  resolve) config_resolve "$(dir_arg "${2:-}")" ;;
  validate)
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    config_resolve "$(dir_arg "${2:-}")" > "$tmp"
    if config_validate "$tmp"; then echo "agentic.yaml is valid"; else exit 1; fi ;;
  get) jq -r "${2:?usage: agentic-config get EXPR}" "$RESOLVED" ;;
  *) echo "usage: agentic-config resolve [DIR] | validate [DIR] | get EXPR" >&2; exit 2 ;;
esac
```

`chmod +x image/bin/agentic-config`.

Note: `make_agentic_dir` symlinks `bin` to `image/bin`; the script finds `AGENTIC_DIR` from the
environment first, so tests and the image both work.

- [ ] **Step 9: Run the tests**

Run: `bats tests/bats/config.bats`
Expected: all 15 tests PASS.

- [ ] **Step 10: Add the schema to lint and run it**

In `Makefile`, add this line to the `lint` recipe, before the leak check:

```make
	jq empty schema/agentic.schema.json
```

Run: `make lint`
Expected: clean.

- [ ] **Step 11: Commit**

```bash
git add config schema image/lib image/bin/agentic-config tests/bats/helpers.bash tests/bats/config.bats Makefile
git commit -m "feat: agentic.yaml defaults, schema and validation"
```

---

### Task 3: Tool presets

**Files:**
- Create: `image/tools/_lib.sh` and one preset per tool: `java.sh`, `maven.sh`, `gradle.sh`,
  `node.sh`, `python.sh`, `terraform.sh`, `checkov.sh`, `tflint.sh`, `kubectl.sh`, `helm.sh`,
  `dotnet.sh`, `go.sh`, `glab.sh`, `psql.sh` (all under `image/tools/`)
- Test: `tests/bats/presets.bats`

**Interfaces:**
- Produces the preset contract every later task relies on:
  - `image/tools/<name>.sh install VERSION`: idempotent; installs into
    `$AGENTIC_OPT/<name>/<VERSION>` (`AGENTIC_OPT` defaults to `/opt`), except `psql` (apt) and
    `python` (uv, into `$AGENTIC_OPT/python`). Runs as root at build time.
  - `image/tools/<name>.sh env VERSION`: prints `KEY=VALUE` lines; `PATH=<dir>` lines mean "put
    this directory first on PATH".
  - `image/tools/<name>.sh check VERSION`: prints the installed version; non-zero when missing.
  - Missing version or unknown subcommand: usage on stderr, exit 2.
  - `java.sh install` calls `agentic-trust-java <jdk dir>` when that command exists (Task 4).

- [ ] **Step 1: Write the failing tests**

`tests/bats/presets.bats`:

```bash
#!/usr/bin/env bats
load helpers

DIR_PRESETS="java:21 maven:3.9.9 gradle:8.10 node:22 terraform:1.9.8 checkov:3.2.0 tflint:0.53.0 kubectl:1.31.0 helm:3.16.1 dotnet:8.0 go:1.22.5 glab:1.46.1"

setup() {
  make_tmp_home
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$AGENTIC_OPT" "$BATS_TEST_TMPDIR/bin"
  # any download attempt fails the test
  printf '#!/bin/sh\necho "unexpected download: $*" >&2\nexit 99\n' > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  T="$REPO_ROOT/image/tools"
}

@test "every preset prints usage and exits 2 without a version or with an unknown command" {
  for f in "$T"/*.sh; do
    [ "$(basename "$f")" = _lib.sh ] && continue
    run bash "$f" install
    [ "$status" -eq 2 ] || { echo "$f: $status"; false; }
    run bash "$f" frobnicate 1.0
    [ "$status" -eq 2 ] || { echo "$f: $status"; false; }
  done
}

@test "env prints only KEY=VALUE lines" {
  for f in "$T"/*.sh; do
    [ "$(basename "$f")" = _lib.sh ] && continue
    run bash "$f" env 1.2.3
    [ "$status" -eq 0 ] || { echo "$f: $status $output"; false; }
    while IFS= read -r line; do
      [ -z "$line" ] || [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=.+$ ]] || { echo "$f: bad line '$line'"; false; }
    done <<<"$output"
  done
}

@test "install is a no-op when the version is already present" {
  for pv in $DIR_PRESETS; do
    p="${pv%%:*}"; v="${pv#*:}"
    mkdir -p "$AGENTIC_OPT/$p/$v/bin"; touch "$AGENTIC_OPT/$p/$v/bin/marker"
    run bash "$T/$p.sh" install "$v"
    [ "$status" -eq 0 ] || { echo "$p: $status $output"; false; }
  done
}

@test "check fails when the version is missing" {
  for pv in $DIR_PRESETS; do
    p="${pv%%:*}"; v="${pv#*:}"
    run bash "$T/$p.sh" check "$v"
    [ "$status" -ne 0 ] || { echo "$p: check passed without an install"; false; }
  done
}

@test "java env points JAVA_HOME and PATH at the major" {
  run bash "$T/java.sh" env 17
  [ "${lines[0]}" = "JAVA_HOME=$AGENTIC_OPT/java/17" ]
  [ "${lines[1]}" = "PATH=$AGENTIC_OPT/java/17/bin" ]
}

@test "java install hands the new JDK to agentic-trust-java when it exists" {
  printf '#!/bin/sh\necho "$1" > "%s/trusted"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/agentic-trust-java"
  chmod +x "$BATS_TEST_TMPDIR/bin/agentic-trust-java"
  mkdir -p "$AGENTIC_OPT/java/17/bin"; touch "$AGENTIC_OPT/java/17/bin/java"
  run bash "$T/java.sh" install 17
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/trusted")" = "$AGENTIC_OPT/java/17" ]
}

@test "python uses uv's install dir and skips an installed version" {
  printf '#!/bin/sh\n[ "$1 $2" = "python find" ] && exit 0\necho "uv $*" >> "%s/uv.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/uv"
  chmod +x "$BATS_TEST_TMPDIR/bin/uv"
  run bash "$T/python.sh" install 3.12
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/uv.log" ]
  run bash "$T/python.sh" env 3.12
  [ "$output" = "UV_PYTHON_INSTALL_DIR=$AGENTIC_OPT/python" ]
}
```

Note: `java.sh install` on a present JDK still calls `agentic-trust-java`, so a cert added later
reaches every JDK; it never downloads again.

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/presets.bats`
Expected: FAIL (no presets yet).

- [ ] **Step 3: Write the shared library**

`image/tools/_lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for tool presets. Source, do not execute.
# Every preset: <name>.sh install VERSION | env VERSION | check VERSION
#   install  idempotent, into $AGENTIC_OPT/<name>/<VERSION>; runs as root at build time
#   env      KEY=VALUE lines; PATH=<dir> lines go first on PATH
#   check    prints the installed version; non-zero when missing
set -euo pipefail
AGENTIC_OPT="${AGENTIC_OPT:-/opt}"

arch_go() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
}
# Temurin and Node name x86_64 "x64"; Temurin names arm64 "aarch64", Node "arm64".
arch_temurin() { case "$(arch_go)" in amd64) echo x64 ;; arm64) echo aarch64 ;; esac; }
arch_node() { case "$(arch_go)" in amd64) echo x64 ;; arm64) echo arm64 ;; esac; }

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# untar URL DEST [STRIP]: unpack a tarball into DEST, dropping STRIP leading path parts.
untar() {
  local url="$1" dest="$2" strip="${3:-1}" tmp
  tmp="$(mktemp -d)"
  fetch "$url" "$tmp/archive"
  mkdir -p "$dest"
  tar -xf "$tmp/archive" -C "$dest" --strip-components="$strip"
  rm -rf "$tmp"
}

# unzip_to URL DEST [STRIP_TOP]: unpack a zip into DEST; with STRIP_TOP=1 its single top folder is dropped.
unzip_to() {
  local url="$1" dest="$2" strip="${3:-0}" tmp
  tmp="$(mktemp -d)"
  fetch "$url" "$tmp/archive.zip"
  mkdir -p "$tmp/x" "$dest"
  unzip -q "$tmp/archive.zip" -d "$tmp/x"
  if [ "$strip" = 1 ]; then cp -a "$tmp"/x/*/. "$dest/"; else cp -a "$tmp/x/." "$dest/"; fi
  rm -rf "$tmp"
}

present() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

# preset_main "$@": dispatch to do_install, do_env, do_check, which each preset defines.
preset_main() {
  local cmd="${1:-}" v="${2:-}"
  if [ -z "$v" ]; then echo "usage: $(basename "$0") install|env|check VERSION" >&2; exit 2; fi
  case "$cmd" in
    install) do_install "$v" ;;
    env) do_env "$v" ;;
    check) do_check "$v" ;;
    *) echo "usage: $(basename "$0") install|env|check VERSION" >&2; exit 2 ;;
  esac
}
```

- [ ] **Step 4: Write the presets**

`image/tools/java.sh`:

```bash
#!/usr/bin/env bash
# Temurin JDK, latest GA of the given major, into $AGENTIC_OPT/java/<major>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/java/$1"; }
do_install() {
  local d; d="$(home "$1")"
  if ! present "$d"; then
    untar "https://api.adoptium.net/v3/binary/latest/$1/ga/linux/$(arch_temurin)/jdk/hotspot/normal/eclipse" "$d"
  fi
  if command -v agentic-trust-java >/dev/null 2>&1; then agentic-trust-java "$d"; fi
}
do_env() { echo "JAVA_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/java" -version 2>&1 | head -1; }
preset_main "$@"
```

`image/tools/maven.sh`:

```bash
#!/usr/bin/env bash
# Apache Maven (exact version) into $AGENTIC_OPT/maven/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/maven/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://archive.apache.org/dist/maven/maven-${1%%.*}/$1/binaries/apache-maven-$1-bin.tar.gz" "$(home "$1")"
}
do_env() { echo "MAVEN_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/mvn" -v 2>/dev/null | head -1; }
preset_main "$@"
```

`image/tools/gradle.sh`:

```bash
#!/usr/bin/env bash
# System Gradle (exact version) into $AGENTIC_OPT/gradle/<version>. Projects usually use ./gradlew.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/gradle/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://services.gradle.org/distributions/gradle-$1-bin.zip" "$(home "$1")" 1
}
do_env() { echo "GRADLE_HOME=$(home "$1")"; echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/gradle" --version 2>/dev/null | grep -m1 '^Gradle'; }
preset_main "$@"
```

`image/tools/node.sh`:

```bash
#!/usr/bin/env bash
# Node.js, latest release of the given major, into $AGENTIC_OPT/node/<major>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/node/$1"; }
do_install() {
  local base="https://nodejs.org/dist/latest-v$1.x" sums file
  present "$(home "$1")" && return 0
  sums="$(mktemp)"
  fetch "$base/SHASUMS256.txt" "$sums"
  file="$(awk -v a="linux-$(arch_node).tar.xz" '$2 ~ a"$" {print $2}' "$sums")"
  rm -f "$sums"
  [ -n "$file" ] || { echo "node.sh: no linux build for major $1" >&2; return 1; }
  untar "$base/$file" "$(home "$1")"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/node" --version; }
preset_main "$@"
```

`image/tools/python.sh`:

```bash
#!/usr/bin/env bash
# Python via uv into $AGENTIC_OPT/python, visible to every user's uv.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
export UV_PYTHON_INSTALL_DIR="$AGENTIC_OPT/python"
do_install() {
  uv python find "$1" >/dev/null 2>&1 && return 0
  uv python install "$1"
  chmod -R a+rX "$UV_PYTHON_INSTALL_DIR"
}
do_env() { echo "UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR"; }
do_check() { uv python find "$1"; }
preset_main "$@"
```

`image/tools/terraform.sh`:

```bash
#!/usr/bin/env bash
# Terraform (exact version) into $AGENTIC_OPT/terraform/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/terraform/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://releases.hashicorp.com/terraform/$1/terraform_$1_linux_$(arch_go).zip" "$(home "$1")/bin"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/terraform" version 2>/dev/null | head -1; }
preset_main "$@"
```

`image/tools/tflint.sh`:

```bash
#!/usr/bin/env bash
# TFLint (exact version) into $AGENTIC_OPT/tflint/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/tflint/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  unzip_to "https://github.com/terraform-linters/tflint/releases/download/v$1/tflint_linux_$(arch_go).zip" "$(home "$1")/bin"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/tflint" --version 2>/dev/null | head -1; }
preset_main "$@"
```

`image/tools/checkov.sh`:

```bash
#!/usr/bin/env bash
# Checkov (exact version) as a uv tool into $AGENTIC_OPT/checkov/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/checkov/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  UV_TOOL_DIR="$(home "$1")/tools" UV_TOOL_BIN_DIR="$(home "$1")/bin" uv tool install "checkov==$1"
  chmod -R a+rX "$(home "$1")"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/checkov" --version 2>/dev/null; }
preset_main "$@"
```

`image/tools/kubectl.sh`:

```bash
#!/usr/bin/env bash
# kubectl (exact version) into $AGENTIC_OPT/kubectl/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/kubectl/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  mkdir -p "$(home "$1")/bin"
  fetch "https://dl.k8s.io/release/v$1/bin/linux/$(arch_go)/kubectl" "$(home "$1")/bin/kubectl"
  chmod 755 "$(home "$1")/bin/kubectl"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/kubectl" version --client 2>/dev/null | head -1; }
preset_main "$@"
```

`image/tools/helm.sh`:

```bash
#!/usr/bin/env bash
# Helm (exact version) into $AGENTIC_OPT/helm/<version>/bin.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/helm/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://get.helm.sh/helm-v$1-linux-$(arch_go).tar.gz" "$(home "$1")/bin" 1
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/helm" version --short 2>/dev/null; }
preset_main "$@"
```

`image/tools/dotnet.sh`:

```bash
#!/usr/bin/env bash
# .NET SDK, latest of the given channel (e.g. 8.0), into $AGENTIC_OPT/dotnet/<channel>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/dotnet/$1"; }
do_install() {
  local s
  present "$(home "$1")" && return 0
  s="$(mktemp)"
  fetch https://dot.net/v1/dotnet-install.sh "$s"
  bash "$s" --channel "$1" --install-dir "$(home "$1")" --no-path
  rm -f "$s"
}
do_env() {
  echo "DOTNET_ROOT=$(home "$1")"
  echo "DOTNET_CLI_TELEMETRY_OPTOUT=1"
  echo "PATH=$(home "$1")"
}
do_check() { "$(home "$1")/dotnet" --version 2>/dev/null; }
preset_main "$@"
```

`image/tools/go.sh`:

```bash
#!/usr/bin/env bash
# Go (exact version) into $AGENTIC_OPT/go/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/go/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://go.dev/dl/go$1.linux-$(arch_go).tar.gz" "$(home "$1")" 1
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/go" version 2>/dev/null; }
preset_main "$@"
```

`image/tools/glab.sh`:

```bash
#!/usr/bin/env bash
# GitLab CLI (exact version) into $AGENTIC_OPT/glab/<version>.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
home() { echo "$AGENTIC_OPT/glab/$1"; }
do_install() {
  present "$(home "$1")" && return 0
  untar "https://gitlab.com/gitlab-org/cli/-/releases/v$1/downloads/glab_$1_linux_$(arch_go).tar.gz" "$(home "$1")" 0
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/glab" --version 2>/dev/null | head -1; }
preset_main "$@"
```

`image/tools/psql.sh`:

```bash
#!/usr/bin/env bash
# PostgreSQL client of the given major from the PGDG apt repository.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
do_install() {
  local codename key=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  dpkg -s "postgresql-client-$1" >/dev/null 2>&1 && return 0
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  install -d "$(dirname "$key")"
  fetch https://www.postgresql.org/media/keys/ACCC4CF8.asc "$key"
  echo "deb [signed-by=$key] https://apt.postgresql.org/pub/repos/apt $codename-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update
  apt-get install -y --no-install-recommends "postgresql-client-$1"
  rm -rf /var/lib/apt/lists/*
}
do_env() { echo "PATH=/usr/lib/postgresql/$1/bin"; }
do_check() { "/usr/lib/postgresql/$1/bin/psql" --version 2>/dev/null; }
preset_main "$@"
```

`chmod +x image/tools/*.sh` (but not `_lib.sh`: `chmod -x image/tools/_lib.sh`).

- [ ] **Step 5: Run the tests**

Run: `bats tests/bats/presets.bats`
Expected: all 7 tests PASS.

- [ ] **Step 6: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/tools tests/bats/presets.bats
git commit -m "feat: tool presets with install, env and check"
```

---

### Task 4: Derived-image renderer and build helpers

**Files:**
- Create: `derive/render-dockerfile.sh`, `image/bin/agentic-trust-java`,
  `image/bin/agentic-trust-nss`, `image/bin/agentic-remap-user`,
  `image/bin/agentic-install-plugins`, `image/bin/agentic-render-toolchains`,
  `image/profile.d/agentic.sh`, `tests/fixtures/render/agentic.yaml`,
  `tests/fixtures/render/Dockerfile.extra`, `tests/fixtures/render/hooks/on-build.sh`,
  `tests/fixtures/render/Dockerfile.expected`
- Test: `tests/bats/render.bats`, `tests/bats/build-helpers.bats`

**Interfaces:**
- Consumes: `config_resolve`, `config_validate`, `cfg`, `cfg_true`, `cfg_json`, `claude_dir` (Task 2);
  the preset contract (Task 3).
- Produces:
  - `derive/render-dockerfile.sh [CONFIG_DIR]` (default `$AGENTIC_CONFIG_MOUNT` or
    `/agentic-config`): the derived Dockerfile on stdout; validation errors on stderr and exit 1.
    The build context is the project's `.agentic/` directory.
  - `agentic-trust-java [JDK_DIR...]`: imports every `$AGENTIC_CA_DIR/*.crt` (default
    `/usr/local/share/ca-certificates/agentic`) into each JDK's `cacerts` (default: every
    `$AGENTIC_OPT/java/*`).
  - `agentic-trust-nss`: the same certificates into `~/.pki/nssdb` (Chromium).
  - `agentic-remap-user UID GID`: gives user and group `dev` these ids and fixes ownership.
  - `agentic-install-plugins JSON` (`{"claude":[...],"marketplaces":[...]}`): installs missing
    Claude plugins; exit 1 if any failed (after trying all).
  - `agentic-render-toolchains`: writes `~/.m2/toolchains.xml` and the
    `org.gradle.java.installations.paths` line of `~/.gradle/gradle.properties` from the JDKs under
    `$AGENTIC_OPT/java`.
  - `/etc/profile.d/agentic.sh` (installed in Task 8): shell functions `use-tool NAME VERSION`,
    `use-java V`, `use-node V`.
  - Image labels on the derived image: `agentic.project`, `agentic.config.hash`,
    `agentic.docker_socket` (`true|false`), `agentic.harness`.

- [ ] **Step 1: Write the render fixture**

`tests/fixtures/render/agentic.yaml`:

```yaml
version: 1
project: demo
tools:
  java: {versions: [17, 11], default: 17}
  terraform: "1.9.8"
  apt: [tree, graphviz]
mcp:
  atlassian: {enabled: true, jira_url: https://jira.example.com}
docker:
  socket: true
```

`tests/fixtures/render/Dockerfile.extra` (deliberately without a trailing newline):

```
RUN echo extra > /etc/agentic-extra
```

Create it with `printf 'RUN echo extra > /etc/agentic-extra' > tests/fixtures/render/Dockerfile.extra`.

`tests/fixtures/render/hooks/on-build.sh`:

```bash
#!/usr/bin/env bash
echo on-build
```

`tests/fixtures/render/Dockerfile.expected`:

```
# Generated by agentic build from .agentic/agentic.yaml. Do not edit.
FROM agentic-dev-base:local
USER root
ARG UID=1000
ARG GID=1000
RUN agentic-remap-user "$UID" "$GID"
COPY certs/ /usr/local/share/ca-certificates/agentic/
RUN update-ca-certificates
RUN apt-get update && apt-get install -y --no-install-recommends tree graphviz && rm -rf /var/lib/apt/lists/*
RUN /opt/agentic/tools/java.sh install 17 && /opt/agentic/tools/java.sh install 11
RUN /opt/agentic/tools/maven.sh install 3.9.9
RUN /opt/agentic/tools/node.sh install 22
RUN /opt/agentic/tools/python.sh install 3.12
RUN /opt/agentic/tools/terraform.sh install 1.9.8
ENV JAVA_HOME=/opt/java/17
ENV MAVEN_HOME=/opt/maven/3.9.9
ENV UV_PYTHON_INSTALL_DIR=/opt/python
ENV PATH=/opt/java/17/bin:/opt/maven/3.9.9/bin:/opt/node/22/bin:/opt/terraform/1.9.8/bin:${PATH}
RUN agentic-trust-java
# .agentic/Dockerfile.extra
RUN echo extra > /etc/agentic-extra
USER dev
RUN agentic-trust-nss && agentic-render-toolchains
ARG AGENTIC_PLUGINS_REFRESH=0
RUN agentic-install-plugins '{"claude":["superpowers@claude-plugins-official"],"marketplaces":["anthropics/claude-plugins-official"]}'
COPY --chown=dev hooks/on-build.sh /tmp/agentic-on-build.sh
RUN bash /tmp/agentic-on-build.sh && rm -f /tmp/agentic-on-build.sh
LABEL agentic.project="demo" agentic.config.hash="HASH" agentic.docker_socket="true" agentic.harness="claude"
WORKDIR /work
```

- [ ] **Step 2: Write the failing renderer tests**

`tests/bats/render.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  unset AGENTIC_OPT
  C="$BATS_TEST_TMPDIR/dot-agentic"
  cp -r "$REPO_ROOT/tests/fixtures/render" "$C"
  rm -f "$C/Dockerfile.expected"
  mkdir -p "$C/certs"; touch "$C/certs/test.crt"
  R="$REPO_ROOT/derive/render-dockerfile.sh"
}

normalise() { sed -E 's/agentic\.config\.hash="[0-9a-f]+"/agentic.config.hash="HASH"/'; }

@test "renders the golden Dockerfile" {
  run bash -c "bash '$R' '$C' | sed -E 's/agentic\\.config\\.hash=\"[0-9a-f]+\"/agentic.config.hash=\"HASH\"/'"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$REPO_ROOT/tests/fixtures/render/Dockerfile.expected"
}

@test "without certs, extra Dockerfile, on-build hook or plugins those parts are left out" {
  rm -rf "$C/certs" "$C/Dockerfile.extra" "$C/hooks"
  printf 'plugins:\n  claude: []\n' >> "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 0 ]
  [[ "$output" != *"update-ca-certificates"* ]]
  [[ "$output" != *"Dockerfile.extra"* ]]
  [[ "$output" != *"on-build"* ]]
  [[ "$output" != *"agentic-install-plugins"* ]]
}

@test "an invalid config fails with the validation errors" {
  printf 'version: 1\nproject: demo\nfoo: 1\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
}

@test "a tool without a preset in the image fails" {
  printf 'version: 1\nproject: demo\ntools:\n  hello: "1.0"\n' > "$C/agentic.yaml"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools.hello: no preset hello in this image"* ]]
}

@test "paths outside .agentic/ are refused" {
  printf 'version: 1\nproject: demo\ncerts: ../certs\n' > "$C/agentic.yaml"
  mkdir -p "$BATS_TEST_TMPDIR/certs"; touch "$BATS_TEST_TMPDIR/certs/x.crt"
  run bash "$R" "$C"
  [ "$status" -eq 1 ]
  [[ "$output" == *"certs: ../certs must be inside .agentic/"* ]]
}

@test "the config hash changes with the config" {
  a="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  sed -i 's/1.9.8/1.9.7/' "$C/agentic.yaml"
  b="$(bash "$R" "$C" | grep -o 'config.hash="[0-9a-f]*"')"
  [ "$a" != "$b" ]
}
```

- [ ] **Step 3: Write the failing helper tests**

`tests/bats/build-helpers.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_OPT="$BATS_TEST_TMPDIR/opt" AGENTIC_CA_DIR="$BATS_TEST_TMPDIR/ca"
  mkdir -p "$AGENTIC_OPT" "$AGENTIC_CA_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG="$BATS_TEST_TMPDIR/calls.log"
  B="$REPO_ROOT/image/bin"
}

# fake_jdk MAJOR VERSION_STRING [jre]: a JDK dir with a release file and a logging keytool.
fake_jdk() {
  local d="$AGENTIC_OPT/java/$1"
  mkdir -p "$d/bin" "$d/lib/security"
  if [ "${3:-}" = jre ]; then rm -rf "$d/lib/security"; mkdir -p "$d/jre/lib/security"; fi
  printf 'JAVA_VERSION="%s"\n' "$2" > "$d/release"
  printf '#!/bin/sh\necho "keytool %s $*" >> "$LOG"\n' "$1" > "$d/bin/keytool"
  chmod +x "$d/bin/keytool"
}

@test "trust-java imports every cert into every JDK, Java 8 included" {
  fake_jdk 17 17.0.12; fake_jdk 8 1.8.0_422 jre
  touch "$AGENTIC_CA_DIR/corp.crt"
  run "$B/agentic-trust-java"
  [ "$status" -eq 0 ]
  grep -q "keytool 17 -importcert -noprompt -keystore $AGENTIC_OPT/java/17/lib/security/cacerts -storepass changeit -alias agentic-corp -file $AGENTIC_CA_DIR/corp.crt" "$LOG"
  grep -q "keytool 8 -importcert .*-keystore $AGENTIC_OPT/java/8/jre/lib/security/cacerts" "$LOG"
}

@test "trust-java does nothing without certs" {
  fake_jdk 17 17.0.12
  run "$B/agentic-trust-java"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

@test "trust-nss adds every cert to the user's NSS database" {
  printf '#!/bin/sh\necho "certutil $*" >> "$LOG"\n' > "$BATS_TEST_TMPDIR/bin/certutil"; chmod +x "$BATS_TEST_TMPDIR/bin/certutil"
  touch "$AGENTIC_CA_DIR/corp.crt"
  run "$B/agentic-trust-nss"
  [ "$status" -eq 0 ]
  grep -q "certutil -d sql:$HOME/.pki/nssdb -A -t C,, -n agentic-corp -i $AGENTIC_CA_DIR/corp.crt" "$LOG"
}

@test "render-toolchains lists every JDK by major, sorted, in Maven and Gradle files" {
  fake_jdk 17 17.0.12; fake_jdk 8 1.8.0_422 jre; fake_jdk 21 21.0.4
  mkdir -p "$HOME/.gradle"; printf 'org.gradle.daemon=false\norg.gradle.java.installations.paths=/old\n' > "$HOME/.gradle/gradle.properties"
  run "$B/agentic-render-toolchains"
  [ "$status" -eq 0 ]
  [ "$(grep -o '<version>[0-9]*</version>' "$HOME/.m2/toolchains.xml" | tr -d '\n')" = "<version>8</version><version>17</version><version>21</version>" ]
  grep -q "<jdkHome>$AGENTIC_OPT/java/8</jdkHome>" "$HOME/.m2/toolchains.xml"
  grep -qx 'org.gradle.daemon=false' "$HOME/.gradle/gradle.properties"
  grep -qx "org.gradle.java.installations.paths=$AGENTIC_OPT/java/8,$AGENTIC_OPT/java/17,$AGENTIC_OPT/java/21" "$HOME/.gradle/gradle.properties"
  [ "$(grep -c installations.paths "$HOME/.gradle/gradle.properties")" -eq 1 ]
}

@test "remap-user changes ids only when they differ" {
  for c in groupmod usermod chown; do
    printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"; chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  printf '#!/bin/sh\ncase "$1" in -u) echo 1000;; -g) echo 1000;; esac\n' > "$BATS_TEST_TMPDIR/bin/id"; chmod +x "$BATS_TEST_TMPDIR/bin/id"
  run "$B/agentic-remap-user" 1000 1000
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
  run "$B/agentic-remap-user" 1001 1002
  [ "$status" -eq 0 ]
  grep -q "groupmod -o -g 1002 dev" "$LOG"
  grep -q "usermod -o -u 1001 -g 1002 dev" "$LOG"
  grep -q "chown -R 1001:1002" "$LOG"
}

@test "install-plugins installs only missing plugins and reports failures after trying all" {
  mkdir -p "$HOME/.claude/plugins"
  echo '{"plugins":{"have@m":[{}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
  printf '#!/bin/sh\necho "claude $*" >> "$LOG"\n[ "$3" = "bad@m" ] && exit 1\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  run "$B/agentic-install-plugins" '{"claude":["have@m","bad@m","new@m"],"marketplaces":["o/m"]}'
  [ "$status" -eq 1 ]
  grep -q "claude plugin marketplace add o/m" "$LOG"
  grep -q "claude plugin install new@m" "$LOG"
  ! grep -q "install have@m" "$LOG"
}

@test "use-java switches JAVA_HOME and PATH in the current shell" {
  fake_jdk 11 11.0.24
  printf '#!/bin/sh\necho "openjdk version 11"\n' > "$AGENTIC_OPT/java/11/bin/java"; chmod +x "$AGENTIC_OPT/java/11/bin/java"
  run bash -c "source '$REPO_ROOT/image/profile.d/agentic.sh'; use-java 11 && echo \"\$JAVA_HOME|\$(command -v java)\""
  [ "$status" -eq 0 ]
  [ "$output" = "$AGENTIC_OPT/java/11|$AGENTIC_OPT/java/11/bin/java" ]
}

@test "use-tool refuses a version that is not installed" {
  run bash -c "source '$REPO_ROOT/image/profile.d/agentic.sh'; use-java 99"
  [ "$status" -eq 1 ]
  [[ "$output" == *"java 99 is not installed"* ]]
}
```

- [ ] **Step 4: Run both test files to see them fail**

Run: `bats tests/bats/render.bats tests/bats/build-helpers.bats`
Expected: FAIL (scripts missing).

- [ ] **Step 5: Write the renderer**

`derive/render-dockerfile.sh`:

```bash
#!/usr/bin/env bash
# Renders the derived Dockerfile from .agentic/agentic.yaml. The build context is .agentic/.
# Usage: render-dockerfile.sh [CONFIG_DIR]
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AGENTIC_DIR="${AGENTIC_DIR:-$(cd "$here/.." && pwd)}"
# shellcheck source=../image/lib/common.sh
source "$AGENTIC_DIR/lib/common.sh"
# shellcheck source=../image/lib/config.sh
source "$AGENTIC_DIR/lib/config.sh"
IMG=/opt/agentic   # paths as they are inside the image, whatever AGENTIC_DIR is here

cdir="${1:-${AGENTIC_CONFIG_MOUNT:-/agentic-config}}"
[ -f "$cdir/agentic.yaml" ] || { say "no agentic.yaml in $cdir"; exit 1; }
RESOLVED="$(mktemp)"
trap 'rm -f "$RESOLVED"' EXIT
config_resolve "$cdir" > "$RESOLVED"
if ! errs="$(config_validate "$RESOLVED")"; then printf '%s\n' "$errs" >&2; exit 1; fi

problems=()
# inside KEY: sets REL to the configured path relative to .agentic/ (the build context);
# records a problem when the path points outside it. Call directly, not in $(...).
inside() {
  local p; p="$(cfg "$1")"
  case "$p" in
    .agentic/*) REL="${p#.agentic/}"; return 0 ;;
    *) problems+=("${1#.}: $p must be inside .agentic/"); return 1 ;;
  esac
}

installs=() envs=() paths=()
while IFS= read -r tool; do
  case "$tool" in apt|extra_dockerfile) continue ;; esac
  val="$(cfg_json ".tools[\"$tool\"]")"
  case "$val" in false|null) continue ;; esac
  if [ ! -f "$AGENTIC_DIR/tools/$tool.sh" ]; then
    problems+=("tools.$tool: no preset $tool in this image"); continue
  fi
  case "$(jq -r type <<<"$val")" in
    object) mapfile -t versions < <(jq -r '.versions[] | tostring' <<<"$val"); default="$(jq -r .default <<<"$val")" ;;
    array) mapfile -t versions < <(jq -r '.[]' <<<"$val"); default="${versions[0]:-}" ;;
    *) versions=("$(jq -r . <<<"$val")"); default="${versions[0]}" ;;
  esac
  [ "${#versions[@]}" -gt 0 ] || continue
  line=""
  for v in "${versions[@]}"; do
    line+="${line:+ && }$IMG/tools/$tool.sh install $v"
  done
  installs+=("RUN $line")
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    if [ "${kv%%=*}" = PATH ]; then paths+=("${kv#PATH=}"); else envs+=("ENV $kv"); fi
  done < <(bash "$AGENTIC_DIR/tools/$tool.sh" env "$default")
done < <(jq -r '.tools | keys[]' "$RESOLVED")

certs_rel=""; extra=""; onbuild=""; REL=""
if inside .certs && compgen -G "$cdir/$REL/*.crt" >/dev/null; then certs_rel="$REL"; fi
if inside .tools.extra_dockerfile && [ -f "$cdir/$REL" ]; then extra="$REL"; fi
if inside .hooks.on_build && [ -f "$cdir/$REL" ]; then onbuild="$REL"; fi
if [ "${#problems[@]}" -gt 0 ]; then printf '%s\n' "${problems[@]}" >&2; exit 1; fi

hash="$(sha256sum < "$RESOLVED" | cut -c1-16)"
socket=false; if cfg_true .docker.socket; then socket=true; fi
plugins="$(jq -c '{claude: (.plugins.claude // []), marketplaces: (.plugins.marketplaces // [])}' "$RESOLVED")"

echo "# Generated by agentic build from .agentic/agentic.yaml. Do not edit."
echo "FROM $(cfg .base_image)"
echo "USER root"
echo "ARG UID=1000"
echo "ARG GID=1000"
echo 'RUN agentic-remap-user "$UID" "$GID"'
if [ -n "$certs_rel" ]; then
  echo "COPY ${certs_rel%/}/ /usr/local/share/ca-certificates/agentic/"
  echo "RUN update-ca-certificates"
fi
mapfile -t apt < <(jq -r '.tools.apt[]?' "$RESOLVED")
if [ "${#apt[@]}" -gt 0 ]; then
  echo "RUN apt-get update && apt-get install -y --no-install-recommends ${apt[*]} && rm -rf /var/lib/apt/lists/*"
fi
printf '%s\n' "${installs[@]}"
if [ "${#envs[@]}" -gt 0 ]; then printf '%s\n' "${envs[@]}"; fi
if [ "${#paths[@]}" -gt 0 ]; then echo "ENV PATH=$(IFS=:; echo "${paths[*]}"):\${PATH}"; fi
echo "RUN agentic-trust-java"
if [ -n "$extra" ]; then
  echo "# .agentic/$extra"
  sed -e '$a\' "$cdir/$extra"
fi
echo "USER dev"
echo "RUN agentic-trust-nss && agentic-render-toolchains"
if [ "$(jq '.claude | length' <<<"$plugins")" -gt 0 ]; then
  echo "ARG AGENTIC_PLUGINS_REFRESH=0"
  echo "RUN agentic-install-plugins $(jq -Rr @sh <<<"$plugins")"
fi
if [ -n "$onbuild" ]; then
  echo "COPY --chown=dev $onbuild /tmp/agentic-on-build.sh"
  echo "RUN bash /tmp/agentic-on-build.sh && rm -f /tmp/agentic-on-build.sh"
fi
echo "LABEL agentic.project=\"$(cfg .project)\" agentic.config.hash=\"$hash\" agentic.docker_socket=\"$socket\" agentic.harness=\"$(cfg .harness.default)\""
echo "WORKDIR /work"
```

`chmod +x derive/render-dockerfile.sh`.

- [ ] **Step 6: Write the build helpers**

`image/bin/agentic-trust-java`:

```bash
#!/usr/bin/env bash
# Imports the project's CA certificates into each JDK's cacerts. Usage: agentic-trust-java [JDK_DIR...]
set -euo pipefail
ca="${AGENTIC_CA_DIR:-/usr/local/share/ca-certificates/agentic}"
compgen -G "$ca/*.crt" >/dev/null || exit 0
if [ "$#" -eq 0 ]; then set -- "${AGENTIC_OPT:-/opt}"/java/*; fi
for jdk in "$@"; do
  [ -x "$jdk/bin/keytool" ] || continue
  store="$jdk/lib/security/cacerts"
  [ -f "$store" ] || [ -d "$jdk/lib/security" ] || store="$jdk/jre/lib/security/cacerts"
  for crt in "$ca"/*.crt; do
    alias="agentic-$(basename "$crt" .crt)"
    "$jdk/bin/keytool" -delete -noprompt -keystore "$store" -storepass changeit -alias "$alias" >/dev/null 2>&1 || true
    "$jdk/bin/keytool" -importcert -noprompt -keystore "$store" -storepass changeit -alias "$alias" -file "$crt"
  done
done
```

`image/bin/agentic-trust-nss`:

```bash
#!/usr/bin/env bash
# Adds the project's CA certificates to the user's NSS database, which Chromium reads.
set -euo pipefail
ca="${AGENTIC_CA_DIR:-/usr/local/share/ca-certificates/agentic}"
compgen -G "$ca/*.crt" >/dev/null || exit 0
db="$HOME/.pki/nssdb"
if [ ! -f "$db/cert9.db" ]; then
  mkdir -p "$db"
  certutil -d "sql:$db" -N --empty-password
fi
for crt in "$ca"/*.crt; do
  certutil -d "sql:$db" -A -t "C,," -n "agentic-$(basename "$crt" .crt)" -i "$crt"
done
```

`image/bin/agentic-remap-user`:

```bash
#!/usr/bin/env bash
# Gives user and group dev the host's ids, so files in /work keep the right owner. Runs as root.
set -euo pipefail
uid="${1:?usage: agentic-remap-user UID GID}"; gid="${2:?usage: agentic-remap-user UID GID}"
if [ "$(id -u dev)" = "$uid" ] && [ "$(id -g dev)" = "$gid" ]; then exit 0; fi
groupmod -o -g "$gid" dev
usermod -o -u "$uid" -g "$gid" dev
chown -R "$uid:$gid" /home/dev /opt/agentic/claude-plugins /work /workspaces
```

`image/bin/agentic-install-plugins`:

```bash
#!/usr/bin/env bash
# Installs missing Claude plugins at build time. Usage: agentic-install-plugins JSON
# JSON: {"claude":["name@marketplace",...],"marketplaces":["owner/repo",...]}
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AGENTIC_DIR="${AGENTIC_DIR:-$(cd "$here/.." && pwd)}"
# shellcheck source=../lib/common.sh
source "$AGENTIC_DIR/lib/common.sh"
json="${1:?usage: agentic-install-plugins JSON}"
installed="$(claude_dir)/plugins/installed_plugins.json"
timeout_s="${AGENTIC_NET_TIMEOUT:-300}"
failed=0
while IFS= read -r m; do
  timeout "$timeout_s" claude plugin marketplace add "$m" </dev/null >/dev/null 2>&1 || true
done < <(jq -r '.marketplaces[]?' <<<"$json")
while IFS= read -r p; do
  if jq -e --arg k "$p" '.plugins[$k]' "$installed" >/dev/null 2>&1; then continue; fi
  if ! timeout "$timeout_s" claude plugin install "$p" </dev/null; then
    say "plugin $p failed to install"
    failed=1
  fi
done < <(jq -r '.claude[]?' <<<"$json")
exit "$failed"
```

`image/bin/agentic-render-toolchains`:

```bash
#!/usr/bin/env bash
# Writes Maven toolchains and Gradle's installation paths for every JDK under $AGENTIC_OPT/java.
set -euo pipefail
opt="${AGENTIC_OPT:-/opt}"
entries=()
for d in "$opt"/java/*/; do
  d="${d%/}"
  [ -f "$d/release" ] || continue
  v="$(sed -nE 's/^JAVA_VERSION="([^"]+)".*/\1/p' "$d/release")"
  case "$v" in 1.*) major="$(cut -d. -f2 <<<"$v")" ;; *) major="${v%%.*}" ;; esac
  entries+=("$major $d")
done
mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort -n)

mkdir -p "$HOME/.m2" "$HOME/.gradle"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!-- generated by agentic-render-toolchains -->'
  echo '<toolchains>'
  for e in "${entries[@]}"; do
    [ -n "$e" ] || continue
    printf '  <toolchain>\n    <type>jdk</type>\n    <provides>\n      <version>%s</version>\n      <vendor>temurin</vendor>\n    </provides>\n    <configuration>\n      <jdkHome>%s</jdkHome>\n    </configuration>\n  </toolchain>\n' "${e%% *}" "${e#* }"
  done
  echo '</toolchains>'
} > "$HOME/.m2/toolchains.xml"

props="$HOME/.gradle/gradle.properties"
touch "$props"
list="$(for e in "${entries[@]}"; do [ -n "$e" ] && printf '%s,' "${e#* }"; done)"
grep -v '^org.gradle.java.installations.paths=' "$props" > "$props.tmp" || true
echo "org.gradle.java.installations.paths=${list%,}" >> "$props.tmp"
mv "$props.tmp" "$props"
```

`image/profile.d/agentic.sh`:

```bash
#!/usr/bin/env bash
# Shell helpers for every interactive shell. Sourced from /etc/profile.d and /etc/bash.bashrc.

# use-tool NAME VERSION: put another installed version of a preset first in this shell.
use-tool() {
  local name="${1:-}" v="${2:-}" tools="${AGENTIC_DIR:-/opt/agentic}/tools" line
  if [ -z "$name" ] || [ -z "$v" ]; then echo "usage: use-tool NAME VERSION" >&2; return 2; fi
  if [ ! -f "$tools/$name.sh" ]; then echo "use-tool: unknown tool $name" >&2; return 1; fi
  if ! bash "$tools/$name.sh" check "$v" >/dev/null 2>&1; then
    echo "use-tool: $name $v is not installed (add it to agentic.yaml and run agentic build)" >&2
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "${line%%=*}" = PATH ]; then export PATH="${line#PATH=}:$PATH"; else export "${line?}"; fi
  done < <(bash "$tools/$name.sh" env "$v")
}
use-java() { use-tool java "$@"; }
use-node() { use-tool node "$@"; }
```

`chmod +x image/bin/agentic-*`.

- [ ] **Step 7: Run the tests**

Run: `bats tests/bats/render.bats tests/bats/build-helpers.bats`
Expected: all PASS. If the golden test fails, compare `diff` output line by line against the
Expected file before changing either; the fixture is the contract.

- [ ] **Step 8: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add derive image/bin image/profile.d tests/fixtures/render tests/bats/render.bats tests/bats/build-helpers.bats
git commit -m "feat: derived Dockerfile renderer and build helpers"
```

---

### Task 5: Entrypoint, worker mode and the first start steps

**Files:**
- Create: `image/entrypoint.sh`, `image/lib/gitenv.sh`, `image/start.d/05-workspace.sh`,
  `image/start.d/10-validate.sh`, `image/start.d/15-repos.sh`, `image/start.d/20-onboarding.sh`,
  `image/start.d/30-git.sh`, `image/worker.d/.gitkeep`
- Test: `tests/bats/entrypoint.bats`, `tests/bats/steps-base.bats`

**Interfaces:**
- Consumes: `image/lib/common.sh`, `image/lib/config.sh` (Task 2).
- Produces:
  - `image/entrypoint.sh [CMD...]`: truncates `$AGENTIC_STATE/env`, runs every
    `$AGENTIC_STEPS_DIR/[0-9][0-9]-*.sh` (default `$AGENTIC_DIR/start.d`) in order with stdin
    closed, logs each step to `$AGENTIC_STATE/start.log`, sources the env file after each step;
    then `exec`s `$AGENTIC_DIR/worker.d/$AGENTIC_WORKER_MODE.sh "$@"` when `AGENTIC_WORKER_MODE`
    is set, otherwise `exec "$@"` (default `bash`).
  - `git_cred_env HOST` (`image/lib/gitenv.sh`): prints `export` lines that make git read
    `${GH_TOKEN:-$GIT_TOKEN}` for `https://HOST` at run time. `url_host URL` prints a URL's host.
  - After `10-validate`: `$AGENTIC_STATE/config.json` (resolved config) and
    `$AGENTIC_STATE/config-dir` (the config directory, or empty when there is no config).
  - Overridable paths for tests: `AGENTIC_WORK` (default `/work`), `AGENTIC_WORKSPACES_DIR`
    (default `/workspaces`).
  - Every step accepts `--check` (report only).

- [ ] **Step 1: Write the failing entrypoint tests**

`tests/bats/entrypoint.bats`:

```bash
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
```

- [ ] **Step 2: Write the failing step tests**

`tests/bats/steps-base.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_WORK="$BATS_TEST_TMPDIR/work" AGENTIC_WORKSPACES_DIR="$BATS_TEST_TMPDIR/workspaces"
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount"
  mkdir -p "$AGENTIC_WORK" "$AGENTIC_WORKSPACES_DIR" "$AGENTIC_STATE"
  S="$REPO_ROOT/image/start.d"
  # an origin repository containing .agentic/agentic.yaml
  O="$BATS_TEST_TMPDIR/origin"
  git init -q -b main "$O"
  mkdir -p "$O/.agentic"; printf 'version: 1\nproject: cloned\n' > "$O/.agentic/agentic.yaml"
  git -C "$O" add . && git -C "$O" -c user.name=t -c user.email=t@t commit -q -m init
}

config() { mkdir -p "$AGENTIC_CONFIG_MOUNT"; printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"; }

# --- 05-workspace
@test "05 leaves a non-empty /work alone" {
  touch "$AGENTIC_WORK/file"
  AGENTIC_REPO_URL="file://$O" run bash "$S/05-workspace.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$AGENTIC_WORK/.git" ]
}

@test "05 clones AGENTIC_REPO_URL into an empty /work, at AGENTIC_REPO_REF" {
  git -C "$O" branch feature
  AGENTIC_REPO_URL="file://$O" AGENTIC_REPO_REF=feature run bash "$S/05-workspace.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$AGENTIC_WORK" branch --show-current)" = feature ]
}

@test "05 warns when /work is empty and there is no URL" {
  run bash "$S/05-workspace.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mount a repository or set AGENTIC_REPO_URL"* ]]
}

@test "05 --check reports without cloning" {
  AGENTIC_REPO_URL="file://$O" run bash "$S/05-workspace.sh" --check
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$AGENTIC_WORK")" ]
}

# --- 10-validate
@test "10 resolves the mounted config and records its directory" {
  config $'version: 1\nproject: demo'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = demo ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "$AGENTIC_CONFIG_MOUNT" ]
}

@test "10 fails on an invalid config and keeps the previous resolved config" {
  echo '{"project":"old"}' > "$AGENTIC_STATE/config.json"
  config $'version: 1\nproject: demo\nfoo: 1'
  run bash "$S/10-validate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *".foo: unknown key"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = old ]
}

@test "10 without any config warns and uses the defaults" {
  run bash "$S/10-validate.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agentic.yaml found; using defaults"* ]]
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = default ]
  [ "$(cat "$AGENTIC_STATE/config-dir")" = "" ]
}

@test "10 finds the config inside a cloned /work" {
  git clone -q "$O" "$AGENTIC_WORK/x" && mv "$AGENTIC_WORK/x/.agentic" "$AGENTIC_WORK/.agentic"
  run bash "$S/10-validate.sh"
  [ "$(jq -r .project "$AGENTIC_STATE/config.json")" = cloned ]
}

# --- 15-repos
@test "15 clones other repos into /workspaces and skips existing ones" {
  config "$(printf 'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: lib, url: "file://%s"}' "$O")"
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 0 ]
  [ -d "$AGENTIC_WORKSPACES_DIR/lib/.git" ]
  [ ! -d "$AGENTIC_WORKSPACES_DIR/main" ]
  run bash "$S/15-repos.sh"
  [ "$status" -eq 0 ]
}

@test "15 warns, and continues, when a clone fails" {
  config $'version: 1\nproject: demo\nrepos:\n  - {name: main}\n  - {name: gone, url: "file:///nonexistent/repo"}'
  bash "$S/10-validate.sh"
  run bash "$S/15-repos.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not clone gone"* ]]
}

# --- 20-onboarding
@test "20 seeds Claude onboarding and trusts /work, /workspaces and each clone" {
  mkdir -p "$AGENTIC_WORKSPACES_DIR/lib/.git"
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh"
  [ "$status" -eq 0 ]
  f="$HOME/.claude.json"
  [ "$(jq -r .hasCompletedOnboarding "$f")" = true ]
  for d in "$AGENTIC_WORK" "$AGENTIC_WORKSPACES_DIR" "$AGENTIC_WORKSPACES_DIR/lib"; do
    [ "$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted' "$f")" = true ]
  done
  [ "$(stat -c %a "$f")" = 600 ]
  jq -e --arg d "$AGENTIC_WORK" '.trusted_folders | index($d)' "$HOME/.copilot/config.json"
}

@test "20 keeps existing keys and follows CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cc"; mkdir -p "$CLAUDE_CONFIG_DIR"
  echo '{"theme":"dark"}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  bash "$S/20-onboarding.sh"
  [ "$(jq -r .theme "$CLAUDE_CONFIG_DIR/.claude.json")" = dark ]
  [ "$(jq -r .hasCompletedOnboarding "$CLAUDE_CONFIG_DIR/.claude.json")" = true ]
}

@test "20 --check warns about missing onboarding and changes nothing" {
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/20-onboarding.sh" --check
  [ "$status" -eq 2 ]
  [ ! -f "$HOME/.claude.json" ]
}

# --- 30-git
@test "30 sets the identity from config, else from GIT_AUTHOR_*, and exports it" {
  config $'version: 1\nproject: demo\ngit:\n  user_name: Cfg Name'; bash "$S/10-validate.sh"
  GIT_AUTHOR_EMAIL=env@example.com run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  [ "$(git config --global user.name)" = "Cfg Name" ]
  [ "$(git config --global user.email)" = env@example.com ]
  grep -q '^export GIT_COMMITTER_NAME=Cfg\\ Name$' "$AGENTIC_STATE/env"
}

@test "30 wires the credential helper for git.host without writing the token" {
  config $'version: 1\nproject: demo\ngit:\n  host: git.example.com'; bash "$S/10-validate.sh"
  GH_TOKEN=supersecret run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  run grep -q supersecret "$AGENTIC_STATE/env"
  [ "$status" -ne 0 ]
  grep -q 'credential.https://git.example.com.helper' "$AGENTIC_STATE/env"
  grep -q '^export GH_HOST=git.example.com$' "$AGENTIC_STATE/env"
  out="$(GH_TOKEN=supersecret bash -c "source '$AGENTIC_STATE/env'; printf 'protocol=https\nhost=git.example.com\n\n' | git credential fill")"
  [[ "$out" == *"password=supersecret"* ]]
}

@test "30 without a token sets no helper" {
  config $'version: 1\nproject: demo'; bash "$S/10-validate.sh"
  run bash "$S/30-git.sh"
  [ "$status" -eq 0 ]
  ! grep -q GIT_CONFIG_COUNT "$AGENTIC_STATE/env"
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/entrypoint.bats tests/bats/steps-base.bats`
Expected: FAIL (scripts missing).

- [ ] **Step 4: Write the entrypoint**

`image/entrypoint.sh`:

```bash
#!/usr/bin/env bash
# Applies the project config through the start steps, then runs the command or a worker adapter.
set -euo pipefail
AGENTIC_DIR="${AGENTIC_DIR:-/opt/agentic}"
AGENTIC_STATE="${AGENTIC_STATE:-$HOME/.agentic}"
steps="${AGENTIC_STEPS_DIR:-$AGENTIC_DIR/start.d}"
export AGENTIC_DIR AGENTIC_STATE
mkdir -p "$AGENTIC_STATE"
: > "$AGENTIC_STATE/env"
log="$AGENTIC_STATE/start.log"
echo "== start $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$log"

for s in "$steps"/[0-9][0-9]-*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .sh)"
  out="$(mktemp)"
  set +e
  bash "$s" </dev/null >"$out" 2>&1
  rc=$?
  set -e
  { echo "-- $name rc=$rc"; cat "$out"; } >> "$log"
  if [ "${AGENTIC_DEBUG:-}" = 1 ]; then cat "$out" >&2; fi
  case "$rc" in
    0) ;;
    2) echo "agentic: $name: $(tail -n 1 "$out" | sed 's/^agentic: //')" >&2 ;;
    *) cat "$out" >&2
       echo "agentic: start step $name failed (rc=$rc); see $log" >&2
       rm -f "$out"; exit 1 ;;
  esac
  rm -f "$out"
  # shellcheck disable=SC1091
  source "$AGENTIC_STATE/env"
done

if [ -n "${AGENTIC_WORKER_MODE:-}" ]; then
  adapter="$AGENTIC_DIR/worker.d/$AGENTIC_WORKER_MODE.sh"
  if [ ! -f "$adapter" ]; then
    echo "agentic: no worker adapter $AGENTIC_WORKER_MODE (expected $adapter)" >&2
    exit 1
  fi
  exec bash "$adapter" "$@"
fi
if [ "$#" -eq 0 ]; then set -- bash; fi
exec "$@"
```

`chmod +x image/entrypoint.sh`; `mkdir -p image/worker.d && touch image/worker.d/.gitkeep`.

- [ ] **Step 5: Write the git helper library**

`image/lib/gitenv.sh`:

```bash
#!/usr/bin/env bash
# Git credential wiring. Source after common.sh.

# url_host URL: the host part of an https, ssh or scp-style URL.
url_host() { sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##' <<<"$1"; }

# git_cred_env HOST: export lines that make git send ${GH_TOKEN:-$GIT_TOKEN} to https://HOST.
# The token is read when the helper runs; it is never written anywhere.
git_cred_env() {
  local key="credential.https://$1.helper"
  # shellcheck disable=SC2016 # expanded by git's shell when the helper runs
  local helper='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "${GH_TOKEN:-$GIT_TOKEN}"; }; f'
  printf 'export GIT_CONFIG_COUNT=2\n'
  printf 'export GIT_CONFIG_KEY_0=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_0=\n'
  printf 'export GIT_CONFIG_KEY_1=%q\n' "$key"
  printf 'export GIT_CONFIG_VALUE_1=%q\n' "$helper"
}
```

- [ ] **Step 6: Write steps 05, 10 and 15**

`image/start.d/05-workspace.sh`:

```bash
#!/usr/bin/env bash
# Clones AGENTIC_REPO_URL into an empty /work. A mounted /work is left alone.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
work="${AGENTIC_WORK:-/work}"

if [ -n "$(ls -A "$work" 2>/dev/null)" ]; then exit 0; fi
if [ -z "${AGENTIC_REPO_URL:-}" ]; then
  # A worker may clone on its own; a bare `docker run` may need no code. Warn, never stop.
  say "$work is empty: mount a repository or set AGENTIC_REPO_URL"
  exit 2
fi
if [ "$check" = 1 ]; then say "would clone $AGENTIC_REPO_URL into $work"; exit 0; fi
eval "$(git_cred_env "$(url_host "$AGENTIC_REPO_URL")")"
args=(clone --quiet)
if [ -n "${AGENTIC_REPO_REF:-}" ]; then args+=(--branch "$AGENTIC_REPO_REF"); fi
if ! git "${args[@]}" "$AGENTIC_REPO_URL" "$work"; then
  say "clone of $AGENTIC_REPO_URL failed"
  exit 1
fi
```

`image/start.d/10-validate.sh`:

```bash
#!/usr/bin/env bash
# Finds, resolves and validates agentic.yaml into ~/.agentic/config.json.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/config.sh"
mkdir -p "$AGENTIC_STATE"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
rc=0
dir="$(config_find)"
if [ -z "$dir" ]; then
  say "no agentic.yaml found; using defaults"
  config_resolve | jq -c '.project = "default"' > "$tmp"
  rc=2
else
  config_resolve "$dir" > "$tmp" || { say "could not read $dir/agentic.yaml"; exit 1; }
fi
if ! errs="$(config_validate "$tmp")"; then
  printf '%s\n' "$errs"
  say "agentic.yaml is invalid"
  exit 1
fi
cp "$tmp" "$RESOLVED"
printf '%s\n' "$dir" > "$AGENTIC_STATE/config-dir"
exit "$rc"
```

`image/start.d/15-repos.sh`:

```bash
#!/usr/bin/env bash
# Clones the other repos: entries (all but the first) into /workspaces/<name>.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
ws="${AGENTIC_WORKSPACES_DIR:-/workspaces}"
rc=0
while IFS=$'\t' read -r name url ref; do
  [ -n "$url" ] || continue
  dest="$ws/$name"
  [ -d "$dest/.git" ] && continue
  if [ "$check" = 1 ]; then say "$name is not cloned yet"; rc=2; continue; fi
  args=(clone --quiet)
  if [ -n "$ref" ]; then args+=(--branch "$ref"); fi
  if ! (eval "$(git_cred_env "$(url_host "$url")")"; git "${args[@]}" "$url" "$dest"); then
    say "could not clone $name from $url"
    rc=2
  fi
done < <(jq -r '.repos[1:][]? | [.name, (.url // ""), (.ref // "")] | @tsv' "$RESOLVED")
exit "$rc"
```

- [ ] **Step 7: Write steps 20 and 30**

`image/start.d/20-onboarding.sh`:

```bash
#!/usr/bin/env bash
# Marks harness first-run dialogs as done and trusts /work, /workspaces and every clone in it.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
work="${AGENTIC_WORK:-/work}"; ws="${AGENTIC_WORKSPACES_DIR:-/workspaces}"
trust=("$work")
if [ -d "$ws" ]; then
  trust+=("$ws")
  for d in "$ws"/*/; do [ -e "$d.git" ] && trust+=("${d%/}"); done
fi

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

cf="$(claude_json)"
claude_next="$(read_json "$cf" | jq '
  .hasCompletedOnboarding = true
  | reduce $ARGS.positional[] as $d (.;
      .projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true, hasTrustDialogHooksAccepted: true}))' --args "${trust[@]}")"
pf="$(copilot_dir)/config.json"
copilot_next="$(read_json "$pf" | jq '.trusted_folders = (((.trusted_folders // []) + $ARGS.positional) | unique)' --args "${trust[@]}")"

if [ "$check" = 1 ]; then
  drift=0
  [ "$(read_json "$cf" | jq -S .)" = "$(jq -S . <<<"$claude_next")" ] || { say "Claude onboarding is not seeded"; drift=1; }
  [ "$(read_json "$pf" | jq -S .)" = "$(jq -S . <<<"$copilot_next")" ] || { say "Copilot trust is not seeded"; drift=1; }
  [ "$drift" = 0 ] || exit 2
  exit 0
fi
write_if_changed "$cf" "$claude_next"
chmod 600 "$cf"
write_if_changed "$pf" "$copilot_next"
```

`image/start.d/30-git.sh`:

```bash
#!/usr/bin/env bash
# Git identity, and a credential helper for git.host when GH_TOKEN or GIT_TOKEN is set.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
source "$AGENTIC_DIR/lib/gitenv.sh"
check=0; [ "${1:-}" = --check ] && check=1
name="$(cfg .git.user_name)"; name="${name:-${GIT_AUTHOR_NAME:-}}"
email="$(cfg .git.user_email)"; email="${email:-${GIT_AUTHOR_EMAIL:-}}"
host="$(cfg .git.host)"; host="${host:-github.com}"

if [ "$check" = 1 ]; then
  rc=0
  if [ -n "$name" ] && [ "$(git config --global user.name 2>/dev/null)" != "$name" ]; then say "git user.name is not set"; rc=2; fi
  if [ -z "$name$email" ]; then say "no git identity: set git.user_name/user_email or GIT_AUTHOR_NAME/EMAIL"; rc=2; fi
  exit "$rc"
fi

if [ -n "$name" ]; then
  git config --global user.name "$name"
  env_export GIT_AUTHOR_NAME "$name"; env_export GIT_COMMITTER_NAME "$name"
fi
if [ -n "$email" ]; then
  git config --global user.email "$email"
  env_export GIT_AUTHOR_EMAIL "$email"; env_export GIT_COMMITTER_EMAIL "$email"
fi
if [ "$host" != github.com ]; then env_export GH_HOST "$host"; fi
if [ -n "${GH_TOKEN:-}${GIT_TOKEN:-}" ]; then
  git_cred_env "$host" >> "$ENV_FILE"
  # gh reads GH_ENTERPRISE_TOKEN for enterprise hosts; the reference stays literal.
  # shellcheck disable=SC2016
  if [ "$host" != github.com ]; then printf 'export GH_ENTERPRISE_TOKEN="${GH_TOKEN:-${GIT_TOKEN:-}}"\n' >> "$ENV_FILE"; fi
fi
exit 0
```

`chmod +x image/start.d/*.sh`.

- [ ] **Step 8: Run the tests**

Run: `bats tests/bats/entrypoint.bats tests/bats/steps-base.bats`
Expected: all PASS.

- [ ] **Step 9: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/entrypoint.sh image/lib/gitenv.sh image/start.d image/worker.d tests/bats/entrypoint.bats tests/bats/steps-base.bats
git commit -m "feat: entrypoint with start steps, worker mode, workspace, config, onboarding and git"
```

---

### Task 6: Start step `40-mcp`

**Files:**
- Create: `image/start.d/40-mcp.sh`, `image/lib/mcp.jq`
- Test: `tests/bats/steps-mcp.bats`

**Interfaces:**
- Consumes: `cfg`, `claude_dir`, `claude_json`, `copilot_dir`, `write_if_changed`, the resolved
  config (Tasks 2, 5).
- Produces:
  - Managed MCP servers in `$(claude_json)` under `.mcpServers` and in
    `$(copilot_dir)/mcp-config.json` under `.mcpServers`; the list of managed names in
    `$(claude_dir)/agentic-managed-mcp.json` (a JSON array). Names not in that list are never
    touched.
  - Built-in server definitions (Claude format): `atlassian` → `mcp-atlassian --jira-url U
    --confluence-url U`; `playwright` → `mcp-server-playwright [--headless] --browser chromium
    --no-sandbox --output-dir /tmp/playwright-mcp`; `graphify` →
    `$AGENTIC_GRAPHIFY_PYTHON -m graphify.serve graphify-out/graph.json` (default
    `/opt/agentic/uv-tools/graphifyy/bin/python`). Task 8 installs these commands.
  - Exit 2 (warning) when a `${VAR}` used by a server, or an Atlassian token, is unset.

- [ ] **Step 1: Write the failing tests**

`tests/bats/steps-mcp.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK"
  S="$REPO_ROOT/image/start.d"
  CJ="$HOME/.claude.json"
}

apply() {
  printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  bash "$S/10-validate.sh" >/dev/null
  run bash "$S/40-mcp.sh" "${@:2}"
}

@test "defaults register headless Playwright and Graphify, not Atlassian" {
  apply $'version: 1\nproject: demo'
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.playwright.args | index("--headless")' "$CJ"
  [ "$(jq -r .mcpServers.playwright.command "$CJ")" = mcp-server-playwright ]
  [ "$(jq -r '.mcpServers.graphify.args | join(" ")' "$CJ")" = "-m graphify.serve graphify-out/graph.json" ]
  [ "$(jq -r '.mcpServers.atlassian // "none"' "$CJ")" = none ]
}

@test "atlassian gets the configured URLs as arguments, and warns without a token" {
  apply $'version: 1\nproject: demo\nmcp:\n  atlassian: {enabled: true, jira_url: "https://jira.example.com"}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"JIRA_PERSONAL_TOKEN"* ]]
  [ "$(jq -c .mcpServers.atlassian.args "$CJ")" = '["--jira-url","https://jira.example.com"]' ]
  JIRA_PERSONAL_TOKEN=x apply $'version: 1\nproject: demo\nmcp:\n  atlassian: {enabled: true, jira_url: "https://jira.example.com"}'
  [ "$status" -eq 0 ]
}

@test "headed Playwright drops --headless" {
  apply $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  [ "$(jq '.mcpServers.playwright.args | index("--headless")' "$CJ")" = null ]
}

@test "custom servers keep \${VAR} literal and warn when the variable is unset" {
  apply $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com/mcp", headers: {Authorization: "Bearer ${DOCS_TOKEN}"}}\n    - {name: tool, type: stdio, command: my-mcp, args: [--fast]}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"docs uses \${DOCS_TOKEN}, which is not set"* ]]
  [ "$(jq -r .mcpServers.docs.headers.Authorization "$CJ")" = 'Bearer ${DOCS_TOKEN}' ]
  [ "$(jq -r .mcpServers.tool.command "$CJ")" = my-mcp ]
}

@test "servers added by hand survive; a disabled managed server is removed" {
  echo '{"mcpServers":{"mine":{"type":"stdio","command":"x"}}}' > "$CJ"
  apply $'version: 1\nproject: demo'
  jq -e '.mcpServers.mine' "$CJ"
  apply $'version: 1\nproject: demo\nmcp:\n  graphify: {enabled: false}'
  [ "$(jq -r '.mcpServers.graphify // "gone"' "$CJ")" = gone ]
  jq -e '.mcpServers.mine' "$CJ"
}

@test "a second run with the same config changes nothing" {
  apply $'version: 1\nproject: demo'
  before="$(cat "$CJ" "$HOME/.copilot/mcp-config.json")"
  apply $'version: 1\nproject: demo'
  [ "$status" -eq 0 ]
  [ "$before" = "$(cat "$CJ" "$HOME/.copilot/mcp-config.json")" ]
}

@test "Copilot gets the same servers in its own format" {
  apply $'version: 1\nproject: demo\nmcp:\n  custom:\n    - {name: docs, type: http, url: "https://mcp.example.com/mcp"}'
  f="$HOME/.copilot/mcp-config.json"
  [ "$(jq -r .mcpServers.playwright.type "$f")" = local ]
  [ "$(jq -c .mcpServers.playwright.tools "$f")" = '["*"]' ]
  [ "$(jq -r .mcpServers.docs.type "$f")" = http ]
  [ "$(jq -r .mcpServers.docs.url "$f")" = https://mcp.example.com/mcp ]
}

@test "--check reports drift without writing" {
  printf 'version: 1\nproject: demo\n' > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"
  bash "$S/10-validate.sh" >/dev/null
  run bash "$S/40-mcp.sh" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"MCP servers differ from agentic.yaml"* ]]
  [ ! -f "$CJ" ]
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/steps-mcp.bats`
Expected: FAIL.

- [ ] **Step 3: Write the jq module**

`image/lib/mcp.jq`:

```jq
# desired($graphify): managed MCP servers from the resolved config, in Claude's format.
def desired($graphify):
  (if .mcp.atlassian.enabled then
     {atlassian: {type: "stdio", command: "mcp-atlassian", env: {},
       args: ([if (.mcp.atlassian.jira_url // "") != "" then "--jira-url", .mcp.atlassian.jira_url else empty end]
            + [if (.mcp.atlassian.confluence_url // "") != "" then "--confluence-url", .mcp.atlassian.confluence_url else empty end])}}
   else {} end)
  + (if .mcp.playwright.enabled then
       {playwright: {type: "stdio", command: "mcp-server-playwright", env: {},
         args: ((if .mcp.playwright.mode == "headless" then ["--headless"] else [] end)
                + ["--browser", "chromium", "--no-sandbox", "--output-dir", "/tmp/playwright-mcp"])}}
     else {} end)
  + (if .mcp.graphify.enabled then
       {graphify: {type: "stdio", command: $graphify, env: {},
         args: ["-m", "graphify.serve", "graphify-out/graph.json"]}}
     else {} end)
  + ([ (.mcp.custom // [])[]
       | {(.name): (if .type == "stdio"
                     then {type: "stdio", command, args: (.args // []), env: (.env // {})}
                     else {type: "http", url, headers: (.headers // {})} end)} ] | add // {});

# to_copilot: Claude-format servers in Copilot CLI's mcp-config format.
def to_copilot:
  with_entries(.value |= (if .type == "stdio"
    then {type: "local", command, args, env, tools: ["*"]}
    else {type: "http", url, headers, tools: ["*"]} end));

# merge_managed($managed; $desired): drop previously managed names, then add the desired ones.
def merge_managed($managed; $desired):
  .mcpServers = (((.mcpServers // {}) | with_entries(select(.key as $k | ($managed | index($k)) == null))) + $desired);

# env_refs: names referenced as ${NAME} in any string.
def env_refs: [.. | strings | scan("\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}")[0]] | unique;
```

- [ ] **Step 4: Write the step**

`image/start.d/40-mcp.sh`:

```bash
#!/usr/bin/env bash
# Reconciles the managed MCP servers for Claude and Copilot with agentic.yaml.
# Servers added by hand are left alone. ${VAR} references stay literal; the harness expands them.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
graphify="${AGENTIC_GRAPHIFY_PYTHON:-/opt/agentic/uv-tools/graphifyy/bin/python}"
lib="$AGENTIC_DIR/lib"
rc=0

desired="$(jq -c -L "$lib" --arg g "$graphify" 'include "mcp"; desired($g)' "$RESOLVED")"
mf="$(claude_dir)/agentic-managed-mcp.json"
managed="$(jq -c . "$mf" 2>/dev/null || echo '[]')"
read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }

cf="$(claude_json)"
pf="$(copilot_dir)/mcp-config.json"
claude_next="$(read_json "$cf" | jq -L "$lib" --argjson m "$managed" --argjson d "$desired" 'include "mcp"; merge_managed($m; $d)')"
copilot_next="$(read_json "$pf" | jq -L "$lib" --argjson m "$managed" --argjson d "$desired" 'include "mcp"; merge_managed($m; $d | to_copilot)')"

# Variables the servers need at connect time.
while IFS=$'\t' read -r server var; do
  if [ -z "${!var:-}" ]; then say "MCP server $server uses \${$var}, which is not set (add it to .agentic/.env)"; rc=2; fi
done < <(jq -r -L "$lib" 'include "mcp"; to_entries[] | .key as $k | (.value | env_refs[]) | [$k, .] | @tsv' <<<"$desired")
if jq -e 'has("atlassian")' <<<"$desired" >/dev/null && [ -z "${JIRA_PERSONAL_TOKEN:-}${CONFLUENCE_PERSONAL_TOKEN:-}" ]; then
  say "MCP server atlassian has no token: set JIRA_PERSONAL_TOKEN or CONFLUENCE_PERSONAL_TOKEN in .agentic/.env"
  rc=2
fi

if [ "$check" = 1 ]; then
  if [ "$(read_json "$cf" | jq -S .mcpServers)" != "$(jq -S .mcpServers <<<"$claude_next")" ] \
     || [ "$(read_json "$pf" | jq -S .mcpServers)" != "$(jq -S .mcpServers <<<"$copilot_next")" ]; then
    say "MCP servers differ from agentic.yaml"
    rc=2
  fi
  exit "$rc"
fi

write_if_changed "$cf" "$claude_next"
chmod 600 "$cf"
write_if_changed "$pf" "$copilot_next"
write_if_changed "$mf" "$(jq -c 'keys' <<<"$desired")"
exit "$rc"
```

`chmod +x image/start.d/40-mcp.sh`.

- [ ] **Step 5: Run the tests**

Run: `bats tests/bats/steps-mcp.bats`
Expected: all 8 PASS.

- [ ] **Step 6: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/start.d/40-mcp.sh image/lib/mcp.jq tests/bats/steps-mcp.bats
git commit -m "feat: start step reconciling managed MCP servers for both harnesses"
```

---

### Task 7: Start steps for plugins, skills, Graphify, display and the project hook

**Files:**
- Create: `image/start.d/50-plugins.sh`, `image/start.d/60-skills.sh`,
  `image/start.d/70-graphify.sh`, `image/start.d/80-display.sh`,
  `image/start.d/90-project-hook.sh`
- Test: `tests/bats/steps-rest.bats`

**Interfaces:**
- Consumes: `cfg`, `cfg_true`, `cfg_json`, `config_path`, `claude_dir`, `copilot_dir`,
  `env_export`, `write_if_changed` (Task 2); resolved config and config dir (Task 5).
- Produces:
  - `50-plugins`: `$(claude_dir)/plugins` → symlink to `$AGENTIC_PLUGINS_DIR` (default
    `$AGENTIC_DIR/claude-plugins`, filled at build time in Task 8); `enabledPlugins` set in
    `$(claude_dir)/settings.json` for every configured plugin present in the image; Copilot
    plugins installed if missing.
  - `60-skills`: every `<name>/SKILL.md` folder from `$AGENTIC_DIR/skills/` (base and overlays),
    then from the project's `skills` directory (project wins), copied into
    `$(claude_dir)/skills/` and `$(copilot_dir)/skills/`.
  - `70-graphify`: `graphify install --platform claude|copilot` when Graphify is enabled.
  - `80-display`: for headed Playwright without `DISPLAY`/`WAYLAND_DISPLAY`, starts `Xvfb :99`
    and exports `DISPLAY=:99`.
  - `90-project-hook`: runs the project's `hooks.on_start` script as the current user in `/work`;
    failure is a warning unless `hooks.on_start_required`.

- [ ] **Step 1: Write the failing tests**

`tests/bats/steps-rest.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_CONFIG_MOUNT="$BATS_TEST_TMPDIR/mount" AGENTIC_WORK="$BATS_TEST_TMPDIR/work"
  export AGENTIC_PLUGINS_DIR="$BATS_TEST_TMPDIR/claude-plugins"
  mkdir -p "$AGENTIC_CONFIG_MOUNT" "$AGENTIC_WORK" "$AGENTIC_PLUGINS_DIR" "$BATS_TEST_TMPDIR/bin"
  echo '{"plugins":{"superpowers@claude-plugins-official":[{}]}}' > "$AGENTIC_PLUGINS_DIR/installed_plugins.json"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG="$BATS_TEST_TMPDIR/calls.log"
  S="$REPO_ROOT/image/start.d"
  unset DISPLAY WAYLAND_DISPLAY
}

stub() { printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n%s\n' "$1" "${2:-exit 0}" > "$BATS_TEST_TMPDIR/bin/$1"; chmod +x "$BATS_TEST_TMPDIR/bin/$1"; }
config() { printf '%s\n' "$1" > "$AGENTIC_CONFIG_MOUNT/agentic.yaml"; bash "$S/10-validate.sh" >/dev/null; }

# --- 50-plugins
@test "50 links the baked plugins and enables the configured ones" {
  stub copilot
  config $'version: 1\nproject: demo'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.claude/plugins")" = "$AGENTIC_PLUGINS_DIR" ]
  [ "$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$HOME/.claude/settings.json")" = true ]
}

@test "50 warns about a configured plugin the image does not have" {
  stub copilot
  config $'version: 1\nproject: demo\nplugins:\n  claude: [missing@m]'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"plugin missing@m is not in the image"* ]]
}

@test "50 leaves a real plugins directory alone" {
  stub copilot
  mkdir -p "$HOME/.claude/plugins"
  config $'version: 1\nproject: demo'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  [ -d "$HOME/.claude/plugins" ] && [ ! -L "$HOME/.claude/plugins" ]
}

@test "50 installs missing Copilot plugins and survives a failure" {
  stub copilot 'case "$2" in list) echo "have@m";; install) [ "$3" = "bad@m" ] && exit 1;; esac; exit 0'
  config $'version: 1\nproject: demo\nplugins:\n  copilot: [have@m, new@m, bad@m]'
  run bash "$S/50-plugins.sh"
  [ "$status" -eq 2 ]
  grep -q "copilot plugin install new@m" "$LOG"
  run grep -q "copilot plugin install have@m" "$LOG"
  [ "$status" -ne 0 ]
}

# --- 60-skills
@test "60 copies base and project skills into both harnesses, project wins" {
  config $'version: 1\nproject: demo'
  mkdir -p "$AGENTIC_CONFIG_MOUNT/skills/agentic-setup" "$AGENTIC_CONFIG_MOUNT/skills/mine"
  echo project > "$AGENTIC_CONFIG_MOUNT/skills/agentic-setup/SKILL.md"
  echo mine > "$AGENTIC_CONFIG_MOUNT/skills/mine/SKILL.md"
  run bash "$S/60-skills.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/skills/agentic-setup/SKILL.md")" = project ]
  [ -f "$HOME/.copilot/skills/mine/SKILL.md" ]
}

@test "60 copies a base skill when the project has none" {
  config $'version: 1\nproject: demo'
  run bash "$S/60-skills.sh"
  [ "$status" -eq 0 ]
  diff -q "$REPO_ROOT/skills/agentic-setup/SKILL.md" "$HOME/.claude/skills/agentic-setup/SKILL.md"
}

# --- 70-graphify
@test "70 wires Graphify into both harnesses when enabled" {
  stub graphify
  config $'version: 1\nproject: demo'
  run bash "$S/70-graphify.sh"
  [ "$status" -eq 0 ]
  grep -q "graphify install --platform claude" "$LOG"
  grep -q "graphify install --platform copilot" "$LOG"
}

@test "70 does nothing when Graphify is disabled" {
  stub graphify
  config $'version: 1\nproject: demo\nmcp:\n  graphify: {enabled: false}'
  run bash "$S/70-graphify.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

# --- 80-display
@test "80 starts Xvfb for headed Playwright without a display and exports DISPLAY" {
  stub Xvfb; stub pgrep 'exit 1'
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  run bash "$S/80-display.sh"
  [ "$status" -eq 0 ]
  sleep 0.2
  grep -q "Xvfb :99" "$LOG"
  grep -q '^export DISPLAY=:99$' "$AGENTIC_STATE/env"
}

@test "80 uses an existing display" {
  stub Xvfb
  config $'version: 1\nproject: demo\nmcp:\n  playwright: {enabled: true, mode: headed}'
  DISPLAY=:0 run bash "$S/80-display.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ]
}

@test "80 does nothing in headless mode" {
  stub Xvfb
  config $'version: 1\nproject: demo'
  run bash "$S/80-display.sh"
  [ ! -f "$LOG" ]
}

# --- 90-project-hook
@test "90 runs the on-start hook in /work with the environment" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"
  printf 'pwd > "$HOME/hook-pwd"; echo "$MY_VAR" > "$HOME/hook-var"\n' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 1\nproject: demo'
  MY_VAR=hello run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hook-pwd")" = "$AGENTIC_WORK" ]
  [ "$(cat "$HOME/hook-var")" = hello ]
}

@test "90 failure warns, or stops the start when the hook is required" {
  mkdir -p "$AGENTIC_CONFIG_MOUNT/hooks"; echo 'exit 3' > "$AGENTIC_CONFIG_MOUNT/hooks/on-start.sh"
  config $'version: 1\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 2 ]
  config $'version: 1\nproject: demo\nhooks:\n  on_start_required: true'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 1 ]
}

@test "90 without a hook does nothing" {
  config $'version: 1\nproject: demo'
  run bash "$S/90-project-hook.sh"
  [ "$status" -eq 0 ]
}
```

The `60-skills` tests need `skills/agentic-setup/SKILL.md` to exist. Create a placeholder now
(Task 13 writes the real skill):

```bash
mkdir -p skills/agentic-setup
printf -- '---\nname: agentic-setup\ndescription: Configure agentic-dev-base for this project.\n---\n' > skills/agentic-setup/SKILL.md
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/steps-rest.bats`
Expected: FAIL.

- [ ] **Step 3: Write the steps**

`image/start.d/50-plugins.sh`:

```bash
#!/usr/bin/env bash
# Links the plugins baked into the image, enables the configured Claude plugins and installs
# missing Copilot plugins into the persistent ~/.copilot.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
src="${AGENTIC_PLUGINS_DIR:-$AGENTIC_DIR/claude-plugins}"
cdir="$(claude_dir)"
link="$cdir/plugins"
rc=0

if [ -L "$link" ] || [ ! -e "$link" ]; then
  if [ "$(readlink "$link" 2>/dev/null)" != "$src" ]; then
    if [ "$check" = 1 ]; then say "the image's plugins are not linked into $link"; rc=2
    else mkdir -p "$cdir"; ln -sfn "$src" "$link"; fi
  fi
else
  say "$link is a real directory; not linking the image's plugins"
  rc=2
fi

read_json() { if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cat "$1"; else echo '{}'; fi; }
settings="$cdir/settings.json"
cur="$(read_json "$settings")"; next="$cur"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if jq -e --arg k "$p" '.plugins[$k]' "$src/installed_plugins.json" >/dev/null 2>&1; then
    next="$(jq --arg k "$p" '.enabledPlugins[$k] = true' <<<"$next")"
  else
    say "plugin $p is not in the image; run agentic build"
    rc=2
  fi
done < <(jq -r '.plugins.claude[]?' "$RESOLVED")
if [ "$(jq -S . <<<"$cur")" != "$(jq -S . <<<"$next")" ]; then
  if [ "$check" = 1 ]; then say "configured plugins are not enabled"; rc=2
  else write_if_changed "$settings" "$next"; fi
fi

mapfile -t copilot_plugins < <(jq -r '.plugins.copilot[]?' "$RESOLVED")
if [ "${#copilot_plugins[@]}" -gt 0 ] && command -v copilot >/dev/null 2>&1; then
  t="${AGENTIC_NET_TIMEOUT:-300}"
  list="$(timeout "$t" copilot plugin list </dev/null 2>/dev/null || true)"
  [ "$check" = 1 ] || while IFS= read -r m; do
    timeout "$t" copilot plugin marketplace add "$m" </dev/null >/dev/null 2>&1 || true
  done < <(jq -r '.plugins.marketplaces[]?' "$RESOLVED")
  for p in "${copilot_plugins[@]}"; do
    grep -qF "$p" <<<"$list" && continue
    if [ "$check" = 1 ]; then say "Copilot plugin $p is not installed"; rc=2; continue; fi
    timeout "$t" copilot plugin install "$p" </dev/null >/dev/null 2>&1 || { say "Copilot plugin $p failed to install"; rc=2; }
  done
fi
exit "$rc"
```

`image/start.d/60-skills.sh`:

```bash
#!/usr/bin/env bash
# Copies base, overlay and project skills into both harnesses. Project skills win on a name clash.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
dirs=("$AGENTIC_DIR/skills")
if p="$(config_path "$(cfg .skills)")"; then dirs+=("$p"); fi
targets=("$(claude_dir)/skills" "$(copilot_dir)/skills")
rc=0
declare -A pick=()
for d in "${dirs[@]}"; do
  for s in "$d"/*/; do
    [ -f "$s/SKILL.md" ] && pick["$(basename "$s")"]="${s%/}"
  done
done
for name in "${!pick[@]}"; do
  for t in "${targets[@]}"; do
    if [ "$check" = 1 ]; then
      diff -rq "${pick[$name]}" "$t/$name" >/dev/null 2>&1 || { say "skill $name is not current in $t"; rc=2; }
      continue
    fi
    mkdir -p "$t"
    rm -rf "${t:?}/$name"
    cp -R "${pick[$name]}" "$t/$name"
  done
done
exit "$rc"
```

`image/start.d/70-graphify.sh`:

```bash
#!/usr/bin/env bash
# Wires Graphify's hooks and skill into both harnesses. Building a graph is not done here.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
cfg_true .mcp.graphify.enabled || exit 0
if ! command -v graphify >/dev/null 2>&1; then say "graphify is not installed in this image"; exit 2; fi
[ "$check" = 1 ] && exit 0
rc=0
for p in claude copilot; do
  graphify install --platform "$p" </dev/null >/dev/null 2>&1 || { say "graphify install --platform $p failed"; rc=2; }
done
exit "$rc"
```

`image/start.d/80-display.sh`:

```bash
#!/usr/bin/env bash
# Headed Playwright needs a display: use the one given, or start Xvfb on :99.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
cfg_true .mcp.playwright.enabled || exit 0
[ "$(cfg .mcp.playwright.mode)" = headed ] || exit 0
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then exit 0; fi
if [ "$check" = 1 ]; then say "no display; Xvfb starts on :99 at container start"; exit 0; fi
if ! command -v Xvfb >/dev/null 2>&1; then say "headed Playwright needs a display, and Xvfb is missing"; exit 2; fi
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  nohup Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp >/dev/null 2>&1 &
fi
env_export DISPLAY :99
```

`image/start.d/90-project-hook.sh`:

```bash
#!/usr/bin/env bash
# Runs the project's on-start hook in /work. A failure warns unless the hook is required.
set -uo pipefail
source "${AGENTIC_DIR:-/opt/agentic}/lib/common.sh"
check=0; [ "${1:-}" = --check ] && check=1
f="$(config_path "$(cfg .hooks.on_start)")" || exit 0
[ -f "$f" ] || exit 0
[ "$check" = 1 ] && exit 0
if (cd "${AGENTIC_WORK:-/work}" && bash "$f" </dev/null); then exit 0; fi
say "the on-start hook $f failed"
if cfg_true .hooks.on_start_required; then exit 1; fi
exit 2
```

`chmod +x image/start.d/*.sh`.

- [ ] **Step 4: Run the tests**

Run: `bats tests/bats/steps-rest.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/start.d skills/agentic-setup/SKILL.md tests/bats/steps-rest.bats
git commit -m "feat: start steps for plugins, skills, graphify, display and the project hook"
```

---

### Task 8: Base Dockerfile and dev-shell

**Files:**
- Create: `image/Dockerfile`, `.dockerignore`, `image/bin/dev-shell`
- Test: `tests/bats/dev-shell.bats`, `tests/bats/dockerfile.bats`

**Interfaces:**
- Consumes: everything under `image/`, `derive/`, `config/`, `schema/`, `skills/` (Tasks 2–7).
- Produces:
  - Image `agentic-dev-base:local` (built in Task 9 by `agentic build-base`), user `dev`
    (1000:1000), entrypoint `/opt/agentic/entrypoint.sh`, every `/opt/agentic/bin/*` linked into
    `/usr/local/bin`, harness CLIs (`claude`, `copilot`, `ccusage`, `mcp-server-playwright`)
    as wrappers in `/usr/local/bin` that always run on Node 22, `mcp-atlassian` and `graphify`
    in `/usr/local/bin`, Graphify's Python at `/opt/agentic/uv-tools/graphifyy/bin/python`,
    Claude plugins in `/opt/agentic/claude-plugins`, marker `/etc/agentic/container`.
  - `dev-shell [DIR]`: sources `$AGENTIC_STATE/env`, then
    `exec tmux new-session -A -s main -c DIR` (default `$AGENTIC_WORK` or `/work`).

- [ ] **Step 1: Write the failing tests**

`tests/bats/dev-shell.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  export AGENTIC_STATE="$HOME/.agentic"
  mkdir -p "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "tmux $* GREETING=$GREETING"\n' > "$BATS_TEST_TMPDIR/bin/tmux"
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "dev-shell applies the start environment and attaches the main session in /work" {
  echo 'export GREETING=hi' > "$AGENTIC_STATE/env"
  run bash "$REPO_ROOT/image/bin/dev-shell"
  [ "$status" -eq 0 ]
  [ "$output" = "tmux new-session -A -s main -c /work GREETING=hi" ]
}

@test "dev-shell takes the start directory as an argument and works without an env file" {
  run bash "$REPO_ROOT/image/bin/dev-shell" /workspaces/lib
  [ "$output" = "tmux new-session -A -s main -c /workspaces/lib GREETING=" ]
}
```

`tests/bats/dockerfile.bats` (guards the image path contract; the image itself is proven by the
smoke test in Task 14):

```bash
#!/usr/bin/env bats
load helpers

D="$REPO_ROOT/image/Dockerfile"

@test "the Dockerfile copies every part of the /opt/agentic contract" {
  for pair in "image/lib /opt/agentic/lib" "image/start.d /opt/agentic/start.d" "image/worker.d /opt/agentic/worker.d" \
              "image/tools /opt/agentic/tools" "image/bin /opt/agentic/bin" "derive /opt/agentic/derive" \
              "config /opt/agentic/config" "schema /opt/agentic/schema" "skills /opt/agentic/skills" \
              "image/entrypoint.sh /opt/agentic/entrypoint.sh" "image/profile.d/agentic.sh /etc/profile.d/agentic.sh"; do
    grep -Eq "^COPY( --chmod=[0-9]+)? $pair\$" "$D" || { echo "missing: COPY $pair"; false; }
  done
  grep -q 'ENTRYPOINT \["/opt/agentic/entrypoint.sh"\]' "$D"
}

@test "the base copies no certificate into the image" {
  run grep -Ei '^COPY .*\.(crt|pem)' "$D"
  [ "$status" -ne 0 ]
}

@test ".dockerignore keeps skills, config and schema in the build context" {
  for p in skills config schema image derive; do
    run grep -Eq "^/?$p/?$" "$REPO_ROOT/.dockerignore"
    [ "$status" -ne 0 ] || { echo "$p is ignored"; false; }
  done
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/dev-shell.bats tests/bats/dockerfile.bats`
Expected: FAIL.

- [ ] **Step 3: Write dev-shell**

`image/bin/dev-shell`:

```bash
#!/usr/bin/env bash
# Attach point of the dev container: the start steps' environment, then the tmux session main.
# docker exec skips the entrypoint, so the exports are applied here.
set -euo pipefail
state="${AGENTIC_STATE:-$HOME/.agentic}"
# shellcheck disable=SC1091
if [ -f "$state/env" ]; then source "$state/env"; fi
exec tmux new-session -A -s main -c "${1:-${AGENTIC_WORK:-/work}}"
```

`chmod +x image/bin/dev-shell`.

- [ ] **Step 4: Write the Dockerfile and .dockerignore**

`.dockerignore`:

```
.git
docs/
tests/
README.md
CLAUDE.md
```

`image/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
# agentic-dev-base. Build from the repository root (agentic build-base does this):
#   docker build -f image/Dockerfile -t agentic-dev-base:local .

# Optional build context "agentic-ca": CA certificates for building behind a TLS-intercepting
# proxy. Empty by default; agentic build-base passes ~/.agentic/ca when it exists. The
# certificates come from the developer's machine, never from this repository.
FROM scratch AS agentic-ca

FROM ubuntu:24.04
ARG YQ_VERSION=v4.44.3
ARG NODE_HARNESS=22
ARG JAVA_BASE=21
ARG MAVEN_BASE=3.9.9
ARG PYTHON_BASE=3.12
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    AGENTIC_DIR=/opt/agentic \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    AWS_PAGER="" \
    DISABLE_AUTOUPDATER=1 \
    JAVA_HOME=/opt/java/${JAVA_BASE} \
    MAVEN_HOME=/opt/maven/${MAVEN_BASE} \
    PATH=/usr/local/sbin:/usr/local/bin:/opt/java/${JAVA_BASE}/bin:/opt/maven/${MAVEN_BASE}/bin:/opt/node/${NODE_HARNESS}/bin:/usr/sbin:/usr/bin:/sbin:/bin

# CA certificates first, so every later download works behind a TLS-intercepting proxy
RUN --mount=type=bind,from=agentic-ca,target=/tmp/agentic-ca \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && mkdir -p /usr/local/share/ca-certificates/agentic \
 && (cp /tmp/agentic-ca/*.crt /usr/local/share/ca-certificates/agentic/ 2>/dev/null || true) \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# OS packages
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client bash make build-essential unzip zip tar xz-utils \
      jq ripgrep tmux less procps python3 python3-venv pipx libnss3-tools xvfb lsb-release \
 && rm -rf /var/lib/apt/lists/*

# gh, Docker CLI, Azure CLI from their vendor repositories
RUN install -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin azure-cli \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2, yq, uv
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/aws.zip \
 && unzip -q /tmp/aws.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/aws.zip \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq \
 && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# Base tools through the same presets projects use
COPY image/tools /opt/agentic/tools
RUN /opt/agentic/tools/java.sh install ${JAVA_BASE} \
 && /opt/agentic/tools/maven.sh install ${MAVEN_BASE} \
 && /opt/agentic/tools/node.sh install ${NODE_HARNESS} \
 && /opt/agentic/tools/python.sh install ${PYTHON_BASE}

# Harness CLIs and the Playwright MCP, always run on Node ${NODE_HARNESS} whatever node a project prefers
RUN PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npm install -g --prefix /opt/agentic/npm \
      @anthropic-ai/claude-code @github/copilot ccusage @playwright/mcp \
 && for b in /opt/agentic/npm/bin/*; do \
      n="$(basename "$b")"; \
      printf '#!/bin/sh\nPATH=/opt/node/%s/bin:$PATH exec %s "$@"\n' "${NODE_HARNESS}" "$b" > "/usr/local/bin/$n"; \
      chmod 755 "/usr/local/bin/$n"; \
    done

# Python MCP servers and Graphify, as uv tools shared by every user
RUN UV_TOOL_DIR=/opt/agentic/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python ${PYTHON_BASE} mcp-atlassian \
 && UV_TOOL_DIR=/opt/agentic/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python ${PYTHON_BASE} 'graphifyy[mcp]' \
 && chmod -R a+rX /opt/agentic/uv-tools /opt/python

# Chromium and its system libraries, for Playwright and the Playwright MCP
RUN mkdir -p /ms-playwright \
 && PATH=/opt/node/${NODE_HARNESS}/bin:$PATH npx --yes playwright@latest install --with-deps chromium \
 && mcp-server-playwright install-browser chromium \
 && rm -rf /var/lib/apt/lists/*

# User dev, mount points and the container marker
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && groupadd -g 1000 dev && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
 && mkdir -p /etc/agentic /work /workspaces /agentic-config /opt/agentic/claude-plugins /opt/agentic/defaults \
 && printf 'agentic\n' > /etc/agentic/container \
 && chown -R dev:dev /work /workspaces /opt/agentic/claude-plugins /ms-playwright

# The agentic layer (changes most often, so it comes last)
COPY image/lib /opt/agentic/lib
COPY image/start.d /opt/agentic/start.d
COPY image/worker.d /opt/agentic/worker.d
COPY image/bin /opt/agentic/bin
COPY derive /opt/agentic/derive
COPY config /opt/agentic/config
COPY schema /opt/agentic/schema
COPY skills /opt/agentic/skills
COPY --chmod=755 image/entrypoint.sh /opt/agentic/entrypoint.sh
COPY image/profile.d/agentic.sh /etc/profile.d/agentic.sh
RUN ln -sf /opt/agentic/bin/* /usr/local/bin/ \
 && printf '%s\n' '[ -f /etc/profile.d/agentic.sh ] && . /etc/profile.d/agentic.sh' \
      '[ -f "$HOME/.agentic/env" ] && . "$HOME/.agentic/env"' >> /etc/bash.bashrc \
 && chmod -R a+rX /opt/agentic

# Base plugins, baked so a container needs no network to have them
USER dev
WORKDIR /home/dev
RUN mkdir -p /home/dev/.claude \
 && ln -sfn /opt/agentic/claude-plugins /home/dev/.claude/plugins \
 && agentic-install-plugins "$(yq -o=json -I=0 '{"claude": .plugins.claude, "marketplaces": .plugins.marketplaces}' /opt/agentic/config/defaults.yaml)"

WORKDIR /work
ENTRYPOINT ["/opt/agentic/entrypoint.sh"]
CMD ["bash"]
```

- [ ] **Step 5: Run the tests**

Run: `bats tests/bats/dev-shell.bats tests/bats/dockerfile.bats`
Expected: all PASS.

- [ ] **Step 6: Build the image once by hand**

Run: `docker build -f image/Dockerfile -t agentic-dev-base:local .`
Expected: the build finishes (about 10–15 minutes the first time). Then:
`docker run --rm agentic-dev-base:local bash -lc 'claude --version && copilot --version && java -version 2>&1 | head -1 && mvn -v | head -1 && node --version && graphify --version && mcp-atlassian --version && az version >/dev/null && aws --version && gh --version | head -1'`
Expected: every command prints a version; the entrypoint prints only the `05-workspace` and
`10-validate` warnings (empty `/work`, no config).

If a vendor URL has moved, fix the URL in the Dockerfile or the preset; do not drop the tool.

- [ ] **Step 7: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/Dockerfile .dockerignore image/bin/dev-shell tests/bats/dev-shell.bats tests/bats/dockerfile.bats
git commit -m "feat: base image and dev-shell"
```

---

### Task 9: Host CLI core — project discovery, run arguments, `build-base` and `build`

**Files:**
- Create: `bin/agentic`, `lib/host/common.sh`, `lib/host/aws.sh`
- Test: `tests/bats/cli-core.bats`, `tests/bats/docker-stub.bash`

**Interfaces:**
- Consumes: `derive/render-dockerfile.sh` inside the image (Task 4); image labels (Task 4).
- Produces (all in `lib/host/common.sh` unless noted):
  - `die TEXT`, `say TEXT`; variables `AGENTIC_ROOT` (repo root), `AGENTIC_DATA`
    (`$HOME/.agentic`), `AGENTIC_WORKSPACES` (`$HOME/agentic-workspaces`),
    `BASE_IMAGE=agentic-dev-base:local`.
  - `project_root` (git top level of `$AGENTIC_PROJECT` or `$PWD`), `cfg_dir`, `need_config`,
    `yaml_top FILE KEY`, `project_name`, `project_image`, `base_image_of`, `image_exists IMG`,
    `image_label IMG LABEL`, `dotenv_value FILE KEY`, `check_env_file FILE`.
  - `build_run_args IMAGE`: fills the global array `RUN_ARGS` with mounts, env file, git
    identity, proxy variables, the filtered AWS directory and (per image label) the Docker socket.
  - `proxy_build_args`: fills the global array `PROXY_BUILD_ARGS`.
  - `build_aws_dir SRC DEST PROFILE` (`lib/host/aws.sh`).
  - `bin/agentic` subcommands `build-base [--force]`, `build [--refresh-plugins] [--no-cache]`,
    `help`; `main` runs only when executed, so tests can `source bin/agentic` and call functions.
  - `tests/bats/docker-stub.bash`: `install_docker_stub` for every CLI test.

- [ ] **Step 1: Write the Docker stub for tests**

`tests/bats/docker-stub.bash`:

```bash
# A docker stand-in. Every call is logged to $DOCKER_LOG ("--- <subcommand>" then one argument per line).
# Controls: DOCKER_LABEL (image inspect -f output), DOCKER_IMAGE_EXISTS (1/0),
# DOCKER_RUN_OUT and DOCKER_RUN_RC (docker run), DOCKER_RUNNING (inspect .State.Running output).
install_docker_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
{ echo "--- $1"; printf '%s\n' "$@"; } >> "$DOCKER_LOG"
case "$1" in
  image)
    if [ "$3" = -f ]; then echo "${DOCKER_LABEL:-}"; else [ "${DOCKER_IMAGE_EXISTS:-1}" = 1 ]; fi ;;
  inspect) [ -n "${DOCKER_RUNNING:-}" ] && echo "$DOCKER_RUNNING" || exit 1 ;;
  run) if [ -n "${DOCKER_RUN_OUT:-}" ]; then printf '%s\n' "$DOCKER_RUN_OUT"; fi; exit "${DOCKER_RUN_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
}

# docker_sub SUB [N]: the arguments (subcommand first) of the Nth docker call with subcommand SUB.
docker_sub() {
  awk -v s="$1" -v n="${2:-1}" '/^--- /{ if ($2 == s) k++; on = ($2 == s && k == n); next } on' "$DOCKER_LOG"
}
```

- [ ] **Step 2: Write the failing tests**

`tests/bats/cli-core.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/my project"
  mkdir -p "$PROJ/.agentic" "$PROJ/src/deep"
  git init -q "$PROJ"
  printf 'version: 1\nproject: demo  # the name\n' > "$PROJ/.agentic/agentic.yaml"
  A="$REPO_ROOT/bin/agentic"
  unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
}

in_project() { (cd "$PROJ/${2:-}" && bash -c "source '$A'; $1"); }

@test "help lists the commands" {
  run bash "$A" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"build"* ]]
}

@test "the project root is found from a subdirectory" {
  run in_project 'project_root' src/deep
  [ "$output" = "$PROJ" ]
  run in_project 'project_name' src/deep
  [ "$output" = demo ]
}

@test "without a config the CLI says to run agentic init" {
  rm "$PROJ/.agentic/agentic.yaml"
  run in_project 'need_config'
  [ "$status" -eq 1 ]
  [[ "$output" == *"run agentic init"* ]]
}

@test "a CRLF .env is refused with a fix" {
  printf 'GH_TOKEN=abc\r\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows line endings"* ]]
}

@test "quoted .env values are refused, plain ones accepted" {
  printf 'GH_TOKEN="abc"\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 1 ]
  [[ "$output" == *"quoted values"* ]]
  printf 'GH_TOKEN=abc\n# comment\n' > "$PROJ/.agentic/.env"
  run in_project 'check_env_file .agentic/.env'
  [ "$status" -eq 0 ]
}

@test "run arguments keep paths with spaces intact and mount the standard places" {
  run in_project 'build_run_args agentic-demo:local; printf "%s\n" "${RUN_ARGS[@]}"'
  [ "$status" -eq 0 ]
  grep -qx "$PROJ:/work" <<<"$output"
  grep -qx "$PROJ/.agentic:/agentic-config:ro" <<<"$output"
  grep -qx "$AGENTIC_WORKSPACES/demo:/workspaces" <<<"$output"
  grep -qx "$AGENTIC_DATA/projects/demo/harness/claude:/home/dev/.claude" <<<"$output"
  grep -qx "$AGENTIC_DATA/projects/demo/harness/copilot:/home/dev/.copilot" <<<"$output"
  [ -d "$AGENTIC_DATA/projects/demo/harness/claude" ]
}

@test "the env file, git identity and proxy variables are passed" {
  printf 'A=1\n' > "$PROJ/.agentic/.env"
  git -C "$PROJ" config user.name "Dev Person"
  export HTTPS_PROXY=http://proxy.example.com:8080
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  grep -qx -- "--env-file" <<<"$output"
  grep -qx "GIT_AUTHOR_NAME=Dev Person" <<<"$output"
  grep -qx "HTTPS_PROXY" <<<"$output"
}

@test "the Docker socket is mounted only when the image label says so" {
  DOCKER_LABEL=false run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  run grep -q docker.sock <<<"$output"
  [ "$status" -ne 0 ]
}

@test "build-base skips a current base and builds an outdated one" {
  h="$(bash -c "source '$A'; base_hash")"
  DOCKER_LABEL="$h" run bash "$A" build-base
  [ "$status" -eq 0 ]
  [[ "$output" == *"base image is current"* ]]
  run grep -q -- "--- build" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  DOCKER_LABEL=old run bash "$A" build-base
  [ "$status" -eq 0 ]
  grep -qx "agentic.base.hash=$h" "$DOCKER_LOG"
  grep -qx "$REPO_ROOT/image/Dockerfile" "$DOCKER_LOG"
}

@test "build-base passes the developer's CA directory as a build context when it has certificates" {
  mkdir -p "$AGENTIC_DATA/ca"; touch "$AGENTIC_DATA/ca/corp.crt"
  DOCKER_LABEL=old run bash "$A" build-base
  [ "$status" -eq 0 ]
  grep -qx -- "--build-context" "$DOCKER_LOG"
  grep -qx "agentic-ca=$AGENTIC_DATA/ca" "$DOCKER_LOG"
}

@test "build renders the Dockerfile in the base image, then builds the project image" {
  DOCKER_LABEL=current DOCKER_RUN_OUT='FROM agentic-dev-base:local' run in_project 'main build'
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agentic/.build/Dockerfile.derived")" = 'FROM agentic-dev-base:local' ]
  grep -qx -- "--entrypoint" "$DOCKER_LOG"
  grep -qx "/opt/agentic/derive/render-dockerfile.sh" "$DOCKER_LOG"
  grep -qx "UID=$(id -u)" "$DOCKER_LOG"
  grep -qx "agentic-demo:local" "$DOCKER_LOG"
  [[ "$output" == *"built agentic-demo:local"* ]]
}

@test "build --refresh-plugins busts the plugin layer" {
  DOCKER_LABEL=current run in_project 'main build --refresh-plugins'
  grep -q '^AGENTIC_PLUGINS_REFRESH=' "$DOCKER_LOG"
}

@test "build passes proxy variables as build arguments" {
  export HTTPS_PROXY=http://proxy.example.com:8080
  DOCKER_LABEL=current run in_project 'main build'
  grep -qx "HTTPS_PROXY" "$DOCKER_LOG"
}

@test "build stops when the config does not render" {
  DOCKER_LABEL=current DOCKER_RUN_RC=1 run in_project 'main build'
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic.yaml has errors"* ]]
}

@test "build refuses a missing overlay base image" {
  printf 'version: 1\nproject: demo\nbase_image: my-overlay:1\n' > "$PROJ/.agentic/agentic.yaml"
  DOCKER_LABEL=current DOCKER_IMAGE_EXISTS=0 run in_project 'main build'
  [ "$status" -eq 1 ]
  [[ "$output" == *"base image my-overlay:1 not found"* ]]
}

# --- AWS profile filter (ported)
write_aws() {
  mkdir -p "$HOME/.aws/sso/cache"
  printf '[profile dev]\nsso_session = s1\nregion = eu-central-1\n\n[profile other]\nregion = eu-west-1\n\n[sso-session s1]\nsso_start_url = https://example.awsapps.com/start\n' > "$HOME/.aws/config"
  printf '[default]\naws_access_key_id = AKIADEFAULT\n\n[dev]\naws_access_key_id = AKIADEV\n' > "$HOME/.aws/credentials"
  echo '{}' > "$HOME/.aws/sso/cache/token.json"
}

@test "build_aws_dir keeps only the profile, its sso-session, its credentials and the SSO cache" {
  write_aws
  run bash -c "source '$A'; build_aws_dir '$HOME/.aws' '$BATS_TEST_TMPDIR/out' dev"
  [ "$status" -eq 0 ]
  grep -q '\[profile dev\]' "$BATS_TEST_TMPDIR/out/config"
  grep -q '\[sso-session s1\]' "$BATS_TEST_TMPDIR/out/config"
  run grep -q 'profile other' "$BATS_TEST_TMPDIR/out/config"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/out/credentials")" = "$(printf '[dev]\naws_access_key_id = AKIADEV')" ]
  [ -f "$BATS_TEST_TMPDIR/out/sso/cache/token.json" ]
}

@test "run arguments mount the filtered AWS dir when .env names a profile" {
  write_aws
  printf 'AWS_PROFILE=dev\n' > "$PROJ/.agentic/.env"
  run in_project 'build_run_args img; printf "%s\n" "${RUN_ARGS[@]}"'
  grep -qx "$AGENTIC_DATA/projects/demo/aws:/home/dev/.aws" <<<"$output"
  run grep -qx "$HOME/.aws:/home/dev/.aws" <<<"$output"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/cli-core.bats`
Expected: FAIL.

- [ ] **Step 4: Write the host libraries**

`lib/host/common.sh`:

```bash
#!/usr/bin/env bash
# Host-side helpers for bin/agentic. Source, do not execute.
AGENTIC_DATA="${AGENTIC_DATA:-$HOME/.agentic}"
AGENTIC_WORKSPACES="${AGENTIC_WORKSPACES:-$HOME/agentic-workspaces}"
BASE_IMAGE=agentic-dev-base:local
PROXY_VARS=(HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

die() { echo "agentic: $*" >&2; exit 1; }
say() { echo "agentic: $*" >&2; }

# project_root: the git top level of $AGENTIC_PROJECT (default: the current directory).
project_root() {
  local d="${AGENTIC_PROJECT:-$PWD}"
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
}
cfg_dir() { printf '%s\n' "$(project_root)/.agentic"; }
need_config() {
  [ -f "$(cfg_dir)/agentic.yaml" ] || die "no .agentic/agentic.yaml in $(project_root); run agentic init"
}

# yaml_top FILE KEY: a top-level scalar, without quotes or a trailing comment.
yaml_top() {
  awk -v key="$2" 'index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v); gsub(/^\047|\047$/, "", v)
      print v; exit }' "$1"
}
project_name() {
  local p; p="$(yaml_top "$(cfg_dir)/agentic.yaml" project)"
  [ -n "$p" ] || die "agentic.yaml has no project name"
  printf '%s\n' "$p"
}
project_image() { printf 'agentic-%s:local\n' "$(project_name)"; }
base_image_of() { local b; b="$(yaml_top "$(cfg_dir)/agentic.yaml" base_image)"; printf '%s\n' "${b:-$BASE_IMAGE}"; }
image_exists() { docker image inspect "$1" >/dev/null 2>&1; }
image_label() { docker image inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true; }

dotenv_value() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- || true; }

# check_env_file FILE: refuse what docker --env-file would silently mangle.
check_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -q $'\r' "$f"; then die "$f has Windows line endings (CRLF); fix it with: sed -i 's/\r\$//' '$f'"; fi
  if grep -Eq "^[A-Za-z_][A-Za-z0-9_]*=([\"'].*[\"'])[[:space:]]*\$" "$f"; then
    die "$f has quoted values; docker keeps the quotes as part of the value. Remove them."
  fi
}

proxy_build_args() {
  PROXY_BUILD_ARGS=()
  local v
  for v in "${PROXY_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then PROXY_BUILD_ARGS+=(--build-arg "$v"); fi
  done
}

# build_run_args IMAGE: docker run arguments for this project, in the global array RUN_ARGS.
build_run_args() {
  local img="$1" root cfg p data ws v name email profile sock
  root="$(project_root)"; cfg="$root/.agentic"; p="$(project_name)"
  data="$AGENTIC_DATA/projects/$p"; ws="$AGENTIC_WORKSPACES/$p"
  mkdir -p "$data/harness/claude" "$data/harness/copilot" "$ws"
  RUN_ARGS=(--label "agentic.project=$p"
    -v "$root:/work" -v "$ws:/workspaces" -v "$cfg:/agentic-config:ro"
    -v "$data/harness/claude:/home/dev/.claude" -v "$data/harness/copilot:/home/dev/.copilot")
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
    RUN_ARGS+=(-v "$data/aws:/home/dev/.aws")
  fi
  sock=/var/run/docker.sock
  if [ "$(image_label "$img" agentic.docker_socket)" = true ] && [ -S "$sock" ]; then
    RUN_ARGS+=(-v "$sock:$sock" --group-add "$(stat -c %g "$sock")")
  fi
}
```

`lib/host/aws.sh`:

```bash
#!/usr/bin/env bash
# A per-project ~/.aws holding one profile. Source, do not execute.

# ini_section FILE SECTION: the section verbatim, header included; nothing if absent.
ini_section() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    /^[[:space:]]*\[/ {
      h = $0
      sub(/^[[:space:]]*\[/, "", h); sub(/\].*$/, "", h)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", h); gsub(/[[:space:]]+/, " ", h)
      inside = (h == want)
    }
    inside { print }' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# build_aws_dir SRC DEST PROFILE: DEST gets the profile, its sso-session, its credentials and the
# SSO cache. Rebuilt on every start, so the cache is fresh. Never fails: AWS is optional.
build_aws_dir() {
  local src="$1" dest="$2" profile="$3" want section sso creds
  rm -rf "$dest"
  mkdir -p "$dest"
  : > "$dest/config"
  if [ "$profile" = default ]; then want="default"; else want="profile $profile"; fi
  section="$(ini_section "$src/config" "$want")"
  if [ -z "$section" ]; then
    echo "agentic: AWS profile '$profile' not found in $src/config" >&2
  else
    printf '%s\n' "$section" > "$dest/config"
    sso="$(sed -nE 's/^[[:space:]]*sso_session[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$section" | head -1)"
    if [ -n "$sso" ]; then { echo; ini_section "$src/config" "sso-session $sso"; } >> "$dest/config"; fi
  fi
  creds="$(ini_section "$src/credentials" "$profile")"
  if [ -n "$creds" ]; then
    printf '%s\n' "$creds" > "$dest/credentials"
    chmod 600 "$dest/credentials"
  fi
  if [ -d "$src/sso/cache" ]; then
    mkdir -p "$dest/sso"
    cp -r "$src/sso/cache" "$dest/sso/cache"
  fi
  return 0
}
```

The `sed` at the end of `ini_section` trims trailing blank lines, so the credentials file equals
the section exactly (the test compares it).

- [ ] **Step 5: Write `bin/agentic`**

`bin/agentic`:

```bash
#!/usr/bin/env bash
# Host CLI for agentic-dev-base. Run `agentic help`.
set -euo pipefail
AGENTIC_ROOT="${AGENTIC_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
# shellcheck source=../lib/host/common.sh
source "$AGENTIC_ROOT/lib/host/common.sh"
# shellcheck source=../lib/host/aws.sh
source "$AGENTIC_ROOT/lib/host/aws.sh"

usage() {
  cat <<'EOF'
agentic <command> [options]          run inside a project repository
  init [--force]                     write .agentic/ for this repository, with detected tools
  build [--refresh-plugins] [--no-cache]
                                     build the base if needed, then agentic-<project>:local
  login [claude|copilot]             log a harness in for this project (once)
  setup                              refine .agentic/ with the /agentic-setup skill
  shell [CMD...]                     throwaway container (removed on exit)
  dev [stop|recreate|status] [--host-profile wsl]
                                     persistent dev container, attached through tmux (detach: Ctrl-b d)
  doctor                             check tools, MCP servers, logins, certificates
  build-base [--force]               build agentic-dev-base:local (make build)
EOF
}

# base_hash: a hash of everything the base image is built from.
base_hash() {
  (cd "$AGENTIC_ROOT" && find image derive config schema skills -type f -print0 | sort -z \
    | xargs -0 sha256sum | sha256sum | cut -c1-16)
}

cmd_build_base() {
  local h; h="$(base_hash)"
  if [ "${1:-}" != --force ] && [ "$(image_label "$BASE_IMAGE" agentic.base.hash)" = "$h" ]; then
    echo "base image is current"; return 0
  fi
  proxy_build_args
  local ca="${AGENTIC_BUILD_CA_DIR:-$AGENTIC_DATA/ca}" ctx=()
  if compgen -G "$ca/*.crt" >/dev/null; then ctx=(--build-context "agentic-ca=$ca"); fi
  docker build -f "$AGENTIC_ROOT/image/Dockerfile" "${PROXY_BUILD_ARGS[@]}" "${ctx[@]}" \
    --label "agentic.base.hash=$h" -t "$BASE_IMAGE" "$AGENTIC_ROOT"
}

cmd_build() {
  local refresh=0 nocache=() cfg base img
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh-plugins) refresh=1 ;;
      --no-cache) nocache=(--no-cache) ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  need_config
  cmd_build_base
  cfg="$(cfg_dir)"; base="$(base_image_of)"; img="$(project_image)"
  image_exists "$base" || die "base image $base not found; build or pull it first"
  check_env_file "$cfg/.env"
  mkdir -p "$cfg/.build"
  if ! docker run --rm --entrypoint /opt/agentic/derive/render-dockerfile.sh \
       -v "$cfg:/agentic-config:ro" "$base" > "$cfg/.build/Dockerfile.derived"; then
    die "agentic.yaml has errors (see above)"
  fi
  local args=(-f "$cfg/.build/Dockerfile.derived" --build-arg "UID=$(id -u)" --build-arg "GID=$(id -g)" -t "$img")
  if [ "$refresh" = 1 ]; then args+=(--build-arg "AGENTIC_PLUGINS_REFRESH=$(date +%s)"); fi
  proxy_build_args
  docker build "${nocache[@]}" "${PROXY_BUILD_ARGS[@]}" "${args[@]}" "$cfg"
  echo "built $img"
}

main() {
  local cmd="${1:-help}"
  if [ "$#" -gt 0 ]; then shift; fi
  case "$cmd" in
    build) cmd_build "$@" ;;
    build-base) cmd_build_base "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
```

`chmod +x bin/agentic`.

- [ ] **Step 6: Run the tests**

Run: `bats tests/bats/cli-core.bats`
Expected: all PASS.

- [ ] **Step 7: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add bin/agentic lib/host tests/bats/cli-core.bats tests/bats/docker-stub.bash
git commit -m "feat: host CLI core with build-base and build"
```

---

### Task 10: `agentic init` and tool detection

**Files:**
- Create: `lib/host/detect.sh`, `templates/agentic.yaml.tmpl`,
  `templates/dot-agentic/.env.example`, `templates/dot-agentic/.gitignore`,
  `templates/dot-agentic/certs/.gitkeep`, `templates/dot-agentic/skills/.gitkeep`,
  `templates/dot-agentic/hooks/README.md`
- Modify: `bin/agentic` (source `detect.sh`, add `cmd_init`, add `init` to `main`)
- Test: `tests/bats/detect.bats`, `tests/bats/cli-init.bats`

**Interfaces:**
- Consumes: `project_root`, `die` (Task 9); `url_host` logic (re-implemented on the host, see below).
- Produces:
  - `detect_tools ROOT` (`lib/host/detect.sh`): prints, in this order and only when found,
    `java=V[,V...]`, `maven=V`, `gradle=V|false`, `node=V`, `python=V`, `terraform=V`, `go=V`,
    `dotnet=V`, `helm=V`, then any number of `note=TEXT` lines.
  - `render_tools DETECTION`: the `tools:` YAML block for `agentic.yaml`.
  - `slugify TEXT`: a valid project name.
  - `agentic init [--force]`: writes `.agentic/` (skeleton plus rendered `agentic.yaml` plus
    `detect-report.md`), never overwrites an existing `agentic.yaml` without `--force`, and
    never overwrites other existing files in `.agentic/`.

- [ ] **Step 1: Write the failing detection tests**

`tests/bats/detect.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R"
  source "$REPO_ROOT/lib/host/detect.sh"
}

@test "an empty repository detects nothing" {
  run detect_tools "$R"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Maven modules on Java 8 and 17, with the Maven wrapper's version" {
  mkdir -p "$R/old" "$R/new" "$R/.mvn/wrapper"
  printf '<project><properties><maven.compiler.source>1.8</maven.compiler.source></properties></project>\n' > "$R/old/pom.xml"
  printf '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>\n' > "$R/new/pom.xml"
  printf 'distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.8.8/apache-maven-3.8.8-bin.zip\n' > "$R/.mvn/wrapper/maven-wrapper.properties"
  run detect_tools "$R"
  grep -qx 'java=17,8' <<<"$output"
  grep -qx 'maven=3.8.8' <<<"$output"
}

@test "Gradle with a wrapper and a Java toolchain" {
  printf 'java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }\n' > "$R/build.gradle.kts"
  touch "$R/gradlew"
  run detect_tools "$R"
  grep -qx 'java=21' <<<"$output"
  grep -qx 'gradle=false' <<<"$output"
  grep -q '^note=.*Gradle wrapper' <<<"$output"
}

@test "Gradle sourceCompatibility in its several spellings" {
  printf 'sourceCompatibility = JavaVersion.VERSION_1_8\n' > "$R/build.gradle"
  run detect_tools "$R"
  grep -qx 'java=8' <<<"$output"
  printf "sourceCompatibility = '11'\n" > "$R/build.gradle"
  run detect_tools "$R"
  grep -qx 'java=11' <<<"$output"
}

@test "Node from .nvmrc, falling back to package.json engines" {
  printf '{"engines": {"node": ">=18.0.0"}}\n' > "$R/package.json"
  run detect_tools "$R"
  grep -qx 'node=18' <<<"$output"
  echo v20.11.0 > "$R/.nvmrc"
  run detect_tools "$R"
  grep -qx 'node=20' <<<"$output"
}

@test "Python from .python-version or requires-python" {
  printf '[project]\nrequires-python = ">=3.11"\n' > "$R/pyproject.toml"
  run detect_tools "$R"
  grep -qx 'python=3.11' <<<"$output"
}

@test "Terraform: an exact required_version is used, a range gets the default and a note" {
  mkdir -p "$R/infra"
  printf 'terraform {\n  required_version = "1.5.7"\n}\n' > "$R/infra/main.tf"
  run detect_tools "$R"
  grep -qx 'terraform=1.5.7' <<<"$output"
  printf 'terraform {\n  required_version = ">= 1.5"\n}\n' > "$R/infra/main.tf"
  run detect_tools "$R"
  grep -qx 'terraform=1.9.8' <<<"$output"
  grep -q '^note=.*terraform' <<<"$output"
}

@test ".tool-versions wins for the tools it names" {
  printf 'java temurin-11.0.24+8\nnodejs 18.20.4\nterraform 1.6.6\n' > "$R/.tool-versions"
  printf 'terraform {\n  required_version = "1.5.7"\n}\n' > "$R/main.tf"
  run detect_tools "$R"
  grep -qx 'java=11' <<<"$output"
  grep -qx 'node=18' <<<"$output"
  grep -qx 'terraform=1.6.6' <<<"$output"
}

@test "Go, .NET and Helm" {
  printf 'module x\n\ngo 1.22\n' > "$R/go.mod"
  printf '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>\n' > "$R/app.csproj"
  mkdir -p "$R/chart"; printf 'apiVersion: v2\nname: x\n' > "$R/chart/Chart.yaml"
  run detect_tools "$R"
  grep -qx 'go=1.22.0' <<<"$output"
  grep -qx 'dotnet=8.0' <<<"$output"
  grep -qx 'helm=3.16.1' <<<"$output"
}

@test "a compose file suggests the Docker socket" {
  printf 'services: {}\n' > "$R/docker-compose.yml"
  run detect_tools "$R"
  grep -q '^note=.*docker.socket' <<<"$output"
}

@test "node_modules and .git are never searched" {
  mkdir -p "$R/node_modules/x"; printf '<project><properties><java.version>11</java.version></properties></project>\n' > "$R/node_modules/x/pom.xml"
  run detect_tools "$R"
  [ -z "$output" ]
}

@test "render_tools turns a detection into the tools block, highest Java as default" {
  run render_tools $'java=17,8\nmaven=3.8.8\nterraform=1.5.7\nnote=hello'
  [ "${lines[0]}" = "tools:" ]
  grep -qx '  java: {versions: \[17, 8\], default: 17}' <<<"$output"
  grep -qx '  maven: "3.8.8"' <<<"$output"
  grep -qx '  terraform: "1.5.7"' <<<"$output"
}

@test "render_tools with nothing detected keeps the defaults" {
  run render_tools ''
  [ "$output" = "tools: {}   # nothing detected; the base defaults apply (Java 21, Maven, Node 22, Python 3.12)" ]
}
```

- [ ] **Step 2: Write the failing init tests**

`tests/bats/cli-init.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  PROJ="$BATS_TEST_TMPDIR/Orders Service"
  mkdir -p "$PROJ"
  git init -q "$PROJ"
  git -C "$PROJ" remote add origin git@git.example.com:team/orders-service.git
  printf '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>\n' > "$PROJ/pom.xml"
  A="$REPO_ROOT/bin/agentic"
}

@test "init writes a valid agentic.yaml with the detected tools and the repo" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 0 ]
  y="$PROJ/.agentic/agentic.yaml"
  [ "$(yq .project "$y")" = orders-service ]
  [ "$(yq '.repos[0].url' "$y")" = git@git.example.com:team/orders-service.git ]
  [ "$(yq .git.host "$y")" = git.example.com ]
  [ "$(yq -o=json -I=0 .tools.java "$y")" = '{"versions":[17],"default":17}' ]
  make_agentic_dir
  run "$REPO_ROOT/image/bin/agentic-config" validate "$PROJ/.agentic"
  [ "$status" -eq 0 ]
}

@test "init writes the skeleton, the report and next steps" {
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ -f "$PROJ/.agentic/.env.example" ]
  grep -qx '.env' "$PROJ/.agentic/.gitignore"
  [ -d "$PROJ/.agentic/certs" ]
  grep -q 'pom.xml' "$PROJ/.agentic/detect-report.md"
  [[ "$output" == *"agentic build"* ]]
}

@test "init refuses to overwrite agentic.yaml without --force, and keeps other files" {
  bash -c "cd '$PROJ' && bash '$A' init" >/dev/null
  echo 'GH_TOKEN=keep' > "$PROJ/.agentic/.env.example"
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"use --force"* ]]
  run bash -c "cd '$PROJ' && bash '$A' init --force"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agentic/.env.example")" = 'GH_TOKEN=keep' ]
}

@test "init without a remote uses the folder name and github.com" {
  git -C "$PROJ" remote remove origin
  run bash -c "cd '$PROJ' && bash '$A' init"
  [ "$(yq .git.host "$PROJ/.agentic/agentic.yaml")" = github.com ]
  [ "$(yq '.repos[0].name' "$PROJ/.agentic/agentic.yaml")" = orders-service ]
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `bats tests/bats/detect.bats tests/bats/cli-init.bats`
Expected: FAIL.

- [ ] **Step 4: Write the detection library**

`lib/host/detect.sh`:

```bash
#!/usr/bin/env bash
# Detects a repository's tools from its build files. Pure bash, grep, sed and find, because it
# runs on the host before any image exists. Source, do not execute.
DEFAULT_TERRAFORM=1.9.8
DEFAULT_GRADLE=8.10
DEFAULT_HELM=3.16.1
DEFAULT_MAVEN=3.9.9

# _files ROOT NAME: files called NAME, skipping vendored and generated trees.
_files() {
  find "$1" -maxdepth 5 \( -name .git -o -name node_modules -o -name .terraform -o -name target \
    -o -name build -o -name dist -o -name .agentic -o -name .venv \) -prune -o -type f -name "$2" -print 2>/dev/null
}
_major() { case "$1" in 1.*) cut -d. -f2 <<<"$1" ;; *) echo "${1%%[.+_-]*}" ;; esac; }
# _tv ROOT TOOL: the version .tool-versions gives TOOL, without a vendor prefix.
_tv() { [ -f "$1/.tool-versions" ] && awk -v t="$2" '$1 == t {print $2; exit}' "$1/.tool-versions" | sed -E 's/^[a-z]+-//' || true; }

detect_tools() {
  local root="$1" f v javas=() notes=() out=()
  # Java
  v="$(_tv "$root" java)"
  if [ -n "$v" ]; then javas+=("$(_major "$v")")
  elif [ -f "$root/.java-version" ]; then javas+=("$(_major "$(tr -d '[:space:]' < "$root/.java-version")")")
  elif [ -f "$root/.sdkmanrc" ] && v="$(sed -nE 's/^java=([0-9.]+).*/\1/p' "$root/.sdkmanrc")" && [ -n "$v" ]; then javas+=("$(_major "$v")")
  else
    while IFS= read -r f; do
      while IFS= read -r v; do javas+=("$(_major "$v")"); done < <(
        sed -nE 's#.*<(maven\.compiler\.(release|source|target)|java\.version|release)>[[:space:]]*([0-9.]+)[[:space:]]*</.*#\3#p' "$f")
    done < <(_files "$root" pom.xml)
    while IFS= read -r f; do
      while IFS= read -r v; do javas+=("$(_major "$v")"); done < <(
        sed -nE 's/.*JavaVersion\.VERSION_(1_)?([0-9]+).*/\2/p; s/.*JavaLanguageVersion\.of\(([0-9]+)\).*/\1/p; s/.*(source|target)Compatibility[^0-9]*(1\.)?([0-9]+).*/\3/p' "$f")
    done < <(_files "$root" 'build.gradle*')
  fi
  if [ "${#javas[@]}" -gt 0 ]; then
    out+=("java=$(printf '%s\n' "${javas[@]}" | awk '$1 >= 8' | sort -rnu | paste -sd, -)")
  fi
  # Maven
  if [ -n "$(_files "$root" pom.xml)" ]; then
    v="$(sed -nE 's#.*apache-maven/([0-9]+\.[0-9]+\.[0-9]+)/.*#\1#p' "$root/.mvn/wrapper/maven-wrapper.properties" 2>/dev/null)"
    out+=("maven=${v:-$DEFAULT_MAVEN}")
  fi
  # Gradle
  if [ -n "$(_files "$root" 'build.gradle*')" ] || [ -f "$root/settings.gradle" ] || [ -f "$root/settings.gradle.kts" ]; then
    if [ -f "$root/gradlew" ]; then out+=("gradle=false"); notes+=("uses the Gradle wrapper (./gradlew); no system Gradle installed")
    else out+=("gradle=$DEFAULT_GRADLE"); notes+=("no Gradle wrapper; installs Gradle $DEFAULT_GRADLE, adjust tools.gradle"); fi
  fi
  # Node
  v="$(_tv "$root" nodejs)"
  [ -n "$v" ] || { [ -f "$root/.nvmrc" ] && v="$(tr -d '[:space:]v' < "$root/.nvmrc")"; }
  [ -n "$v" ] || { [ -f "$root/.node-version" ] && v="$(tr -d '[:space:]v' < "$root/.node-version")"; }
  [ -n "$v" ] || { [ -f "$root/package.json" ] && v="$(sed -nE 's/.*"node"[[:space:]]*:[[:space:]]*"[^0-9]*([0-9]+).*/\1/p' "$root/package.json" | head -1)"; }
  if [ -n "$v" ] && [[ "$v" =~ ^[0-9] ]]; then out+=("node=$(_major "$v")"); fi
  # Python
  v="$(_tv "$root" python)"
  [ -n "$v" ] || { [ -f "$root/.python-version" ] && v="$(tr -d '[:space:]' < "$root/.python-version")"; }
  [ -n "$v" ] || { [ -f "$root/pyproject.toml" ] && v="$(sed -nE 's/^requires-python[^0-9]*([0-9]+\.[0-9]+).*/\1/p' "$root/pyproject.toml" | head -1)"; }
  if [ -n "$v" ]; then out+=("python=$(cut -d. -f1-2 <<<"$v")")
  elif [ -f "$root/pyproject.toml" ] || [ -f "$root/requirements.txt" ]; then out+=("python=3.12"); fi
  # Terraform
  if [ -n "$(_files "$root" '*.tf')" ]; then
    v="$(_tv "$root" terraform)"
    [ -n "$v" ] || { [ -f "$root/.terraform-version" ] && v="$(tr -d '[:space:]' < "$root/.terraform-version")"; }
    [ -n "$v" ] || v="$(_files "$root" '*.tf' | xargs -r sed -nE 's/^[[:space:]]*required_version[[:space:]]*=[[:space:]]*"=?[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' | head -1)"
    if [ -z "$v" ]; then v="$DEFAULT_TERRAFORM"; notes+=("no exact terraform version found; using $DEFAULT_TERRAFORM, adjust tools.terraform"); fi
    out+=("terraform=$v")
  fi
  # Go, .NET, Helm
  if [ -f "$root/go.mod" ]; then
    v="$(sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' "$root/go.mod" | head -1)"
    if [ -n "$v" ]; then [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && v="$v.0"; out+=("go=$v"); fi
  fi
  v="$(_files "$root" '*.csproj' | xargs -r sed -nE 's#.*<TargetFramework>net([0-9]+\.[0-9]+)</TargetFramework>.*#\1#p' | sort -rn | head -1)"
  if [ -n "$v" ]; then out+=("dotnet=$v"); fi
  if [ -n "$(_files "$root" Chart.yaml)" ]; then out+=("helm=$DEFAULT_HELM"); notes+=("Helm charts found; installs Helm $DEFAULT_HELM"); fi
  # Hints for the setup skill
  if [ -n "$(_files "$root" 'docker-compose*.yml')$(_files "$root" 'compose*.yaml')" ]; then
    notes+=("a compose file exists; tests that start containers need docker.socket: true")
  fi
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
  [ "${#notes[@]}" -eq 0 ] || printf 'note=%s\n' "${notes[@]}"
}

# render_tools DETECTION: the tools: block for agentic.yaml.
render_tools() {
  local line k v lines=() javas
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      note) ;;
      java) javas="${v//,/, }"; lines+=("  java: {versions: [$javas], default: ${v%%,*}}") ;;
      node) lines+=("  node: {versions: [$v], default: $v}") ;;
      python) lines+=("  python: [\"$v\"]") ;;
      gradle) if [ "$v" = false ]; then lines+=("  gradle: false"); else lines+=("  gradle: \"$v\""); fi ;;
      *) lines+=("  $k: \"$v\"") ;;
    esac
  done <<<"$1"
  if [ "${#lines[@]}" -eq 0 ]; then
    echo "tools: {}   # nothing detected; the base defaults apply (Java 21, Maven, Node 22, Python 3.12)"
  else
    echo "tools:"; printf '%s\n' "${lines[@]}"
  fi
}

# slugify TEXT: a valid project name.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63
}
```

Note on `render_tools` with nothing detected: `tools: {}` merged over the defaults leaves the
defaults intact (`{} * defaults` keeps every default key).

- [ ] **Step 5: Write the templates**

`templates/agentic.yaml.tmpl`:

```yaml
# agentic-dev-base project configuration (docs/configuration.md in agentic-dev-base).
# Secrets never go here: put them in .agentic/.env (git-ignored) and reference them as ${VAR}.
version: 1
project: @PROJECT@

repos:
  - name: @REPO_NAME@
    url: "@REPO_URL@"

git:
  host: @GIT_HOST@

@TOOLS@

mcp:
  atlassian:
    enabled: false
    jira_url: ""          # e.g. https://jira.example.com
    confluence_url: ""    # e.g. https://confluence.example.com
  playwright: {enabled: true, mode: headless}   # headed needs a display
  graphify: {enabled: true}

harness:
  default: claude

docker:
  socket: false   # true mounts the host Docker socket (host root); needs agentic build
```

`templates/dot-agentic/.env.example`:

```
# Copy to .agentic/.env (git-ignored) and fill in what you use. No quotes, no spaces around =.
# Git host token (credential helper, gh/glab)
GH_TOKEN=
# Claude: leave empty after `agentic login claude`, or use an API key, or Bedrock
ANTHROPIC_API_KEY=
CLAUDE_CODE_USE_BEDROCK=
# Copilot: leave empty after `agentic login copilot`, or a token
COPILOT_GITHUB_TOKEN=
# AWS profile from ~/.aws to pass into the container
AWS_PROFILE=
# Atlassian MCP
JIRA_PERSONAL_TOKEN=
CONFLUENCE_PERSONAL_TOKEN=
```

`templates/dot-agentic/.gitignore`:

```
.env
.build/
detect-report.md
```

`templates/dot-agentic/hooks/README.md`:

```markdown
# Hooks

- `on-start.sh`: runs as `dev` in `/work` at every container start, with `.env` loaded.
  A failure warns, unless `hooks.on_start_required: true`.
- `on-build.sh`: runs as `dev` at the end of `agentic build`. It never sees `.env`; use it for
  user-level installs (`npm i -g`, `pipx install`).
```

`touch templates/dot-agentic/certs/.gitkeep templates/dot-agentic/skills/.gitkeep`.

- [ ] **Step 6: Add `init` to the CLI**

In `bin/agentic`, after the `aws.sh` source line, add:

```bash
# shellcheck source=../lib/host/detect.sh
source "$AGENTIC_ROOT/lib/host/detect.sh"
```

Add before `main`:

```bash
cmd_init() {
  local force=0 root cfg det name url host line
  [ "${1:-}" = --force ] && force=1
  root="$(project_root)"; cfg="$root/.agentic"
  if [ -f "$cfg/agentic.yaml" ] && [ "$force" = 0 ]; then
    die ".agentic/agentic.yaml already exists; use --force to overwrite it"
  fi
  mkdir -p "$cfg"
  # the skeleton never overwrites a file that is already there
  (cd "$AGENTIC_ROOT/templates/dot-agentic" && find . -type f) | while IFS= read -r line; do
    if [ ! -e "$cfg/$line" ]; then
      mkdir -p "$cfg/$(dirname "$line")"
      cp "$AGENTIC_ROOT/templates/dot-agentic/$line" "$cfg/$line"
    fi
  done
  det="$(detect_tools "$root")"
  name="$(slugify "$(basename "$root")")"
  url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  host="github.com"
  if [ -n "$url" ]; then host="$(sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##' <<<"$url")"; fi
  while IFS= read -r line; do
    case "$line" in
      @TOOLS@) render_tools "$det" ;;
      *) line="${line//@PROJECT@/$name}"; line="${line//@REPO_NAME@/$name}"
         line="${line//@REPO_URL@/$url}"; line="${line//@GIT_HOST@/$host}"
         printf '%s\n' "$line" ;;
    esac
  done < "$AGENTIC_ROOT/templates/agentic.yaml.tmpl" > "$cfg/agentic.yaml"
  {
    echo "# Detection report ($(date -u +%Y-%m-%d))"
    echo
    echo "Build files found:"
    (cd "$root" && find . -maxdepth 5 \( -name .git -o -name node_modules -o -name .agentic \) -prune -o -type f \
      \( -name pom.xml -o -name 'build.gradle*' -o -name package.json -o -name pyproject.toml -o -name '*.tf' \
         -o -name go.mod -o -name '*.csproj' -o -name Chart.yaml -o -name '.tool-versions' -o -name 'docker-compose*.yml' \) -print | sed 's/^/- /' | head -50)
    echo
    echo "Detected:"; grep -v '^note=' <<<"$det" | sed 's/^/- /' || true
    echo
    echo "Notes:"; grep '^note=' <<<"$det" | sed 's/^note=/- /' || true
  } > "$cfg/detect-report.md"
  echo "wrote $cfg/agentic.yaml"
  echo "next: review it, then run: agentic build && agentic login && agentic setup (optional) && agentic dev"
}
```

In `main`, add the case `init) cmd_init "$@" ;;`.

- [ ] **Step 7: Run the tests**

Run: `bats tests/bats/detect.bats tests/bats/cli-init.bats`
Expected: all PASS.

- [ ] **Step 8: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add lib/host/detect.sh templates bin/agentic tests/bats/detect.bats tests/bats/cli-init.bats
git commit -m "feat: agentic init with tool detection"
```

---

### Task 11: `shell`, `login`, `setup` and `dev`

**Files:**
- Modify: `bin/agentic` (add `cmd_shell`, `harness_authenticated`, `auth_help`, `cmd_login`,
  `cmd_setup`, `cmd_dev` and helpers; add the cases to `main`)
- Test: `tests/bats/cli-run.bats`

**Interfaces:**
- Consumes: `need_config`, `project_name`, `project_image`, `base_image_of`, `image_exists`,
  `image_label`, `dotenv_value`, `build_run_args`/`RUN_ARGS` (Task 9); `dev-shell` in the image
  (Task 8); the skill name `/agentic-setup` (Task 13).
- Produces:
  - `agentic shell [CMD...]`: `docker run --rm -i[t]` (TTY only when stdin and stdout are
    terminals) on the project image, falling back to the base with a notice.
  - `agentic login [claude|copilot]`: interactive harness in a throwaway container; state lands
    in the project's harness directory.
  - `harness_authenticated claude|copilot`: exit 0 when a login or token exists for the project.
  - `agentic setup`: runs `claude "/agentic-setup"` or `copilot -i "/agentic-setup"` (per the
    image's `agentic.harness` label); without authentication prints the options and exits 1.
  - `agentic dev [attach|stop|recreate|status] [--host-profile wsl]`: container
    `agentic-<project>-dev`, `--restart unless-stopped`, command `sleep infinity`, label
    `agentic.kind=dev`; attach is `docker exec -it <name> dev-shell`.

- [ ] **Step 1: Write the failing tests**

`tests/bats/cli-run.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  install_docker_stub
  export AGENTIC_DATA="$BATS_TEST_TMPDIR/data" AGENTIC_WORKSPACES="$BATS_TEST_TMPDIR/ws"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.agentic"; git init -q "$PROJ"
  printf 'version: 1\nproject: demo\n' > "$PROJ/.agentic/agentic.yaml"
  A="$REPO_ROOT/bin/agentic"
}

ag() { (cd "$PROJ" && bash "$A" "$@" </dev/null); }

@test "shell runs the project image with the command and no TTY when not on a terminal" {
  run ag shell echo hi
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  [ "$(sed -n 1p <<<"$call")" = run ]
  grep -qx -- '--rm' <<<"$call"
  grep -qx -- '-i' <<<"$call"
  run grep -qx -- '-it' <<<"$call"
  [ "$status" -ne 0 ]
  [ "$(tail -n 3 <<<"$call" | tr '\n' ' ')" = "agentic-demo:local echo hi " ]
}

@test "shell falls back to the base image before the first build" {
  DOCKER_IMAGE_EXISTS=0 run ag shell true
  [[ "$output" == *"agentic-demo:local not built yet"* ]]
  grep -qx 'agentic-dev-base:local' "$DOCKER_LOG"
}

@test "login starts the chosen harness interactively" {
  run ag login copilot
  [ "$status" -eq 0 ]
  grep -qx -- '-it' "$DOCKER_LOG"
  [ "$(tail -n 1 "$DOCKER_LOG")" = copilot ]
  [[ "$output" == *"/login"* ]]
}

@test "login refuses an unknown harness" {
  run ag login gemini
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: agentic login"* ]]
}

@test "setup without any authentication explains the options and exits 1" {
  run ag setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"agentic login claude"* ]]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
  [[ "$output" == *"CLAUDE_CODE_USE_BEDROCK"* ]]
  run grep -q -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "setup with an API key runs the skill in Claude" {
  printf 'ANTHROPIC_API_KEY=k\n' > "$PROJ/.agentic/.env"
  run ag setup
  [ "$status" -eq 0 ]
  [ "$(tail -n 2 "$DOCKER_LOG" | tr '\n' ' ')" = "claude /agentic-setup " ]
}

@test "setup with a Claude login on disk counts as authenticated" {
  mkdir -p "$AGENTIC_DATA/projects/demo/harness/claude"
  echo '{"x":1}' > "$AGENTIC_DATA/projects/demo/harness/claude/.credentials.json"
  run ag setup
  [ "$status" -eq 0 ]
}

@test "setup uses Copilot when the image says so" {
  printf 'COPILOT_GITHUB_TOKEN=t\n' > "$PROJ/.agentic/.env"
  DOCKER_LABEL=copilot run ag setup
  [ "$status" -eq 0 ]
  [ "$(tail -n 3 "$DOCKER_LOG" | tr '\n' ' ')" = "copilot -i /agentic-setup " ]
}

@test "dev creates the container when there is none, then attaches" {
  run ag dev
  [ "$status" -eq 0 ]
  run1="$(docker_sub run)"
  grep -qx -- '-d' <<<"$run1"
  grep -qx 'agentic-demo-dev' <<<"$run1"
  grep -qx 'unless-stopped' <<<"$run1"
  grep -qx 'agentic.kind=dev' <<<"$run1"
  [ "$(tail -n 2 <<<"$run1" | tr '\n' ' ')" = "sleep infinity " ]
  [ "$(docker_sub exec | tr '\n' ' ')" = "exec -it agentic-demo-dev dev-shell " ]
}

@test "dev attaches to a running container without starting anything" {
  DOCKER_RUNNING=true run ag dev
  [ "$status" -eq 0 ]
  run grep -qx -- '--- run' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  grep -qx 'dev-shell' "$DOCKER_LOG"
}

@test "dev starts a stopped container" {
  DOCKER_RUNNING=false run ag dev
  grep -qx -- '--- start' "$DOCKER_LOG"
}

@test "dev stop and recreate" {
  run ag dev stop
  [ "$(docker_sub stop | tr '\n' ' ')" = "stop agentic-demo-dev " ]
  : > "$DOCKER_LOG"
  run ag dev recreate
  [ "$(docker_sub rm | tr '\n' ' ')" = "rm -f agentic-demo-dev " ]
  grep -qx 'sleep' "$DOCKER_LOG"
}

@test "dev --host-profile wsl adds the WSLg display and clipboard" {
  run ag dev --host-profile wsl
  grep -qx 'DISPLAY=:0' "$DOCKER_LOG"
  grep -qx 'WAYLAND_DISPLAY=/run/wslg/wayland-0' "$DOCKER_LOG"
  grep -qx '/tmp:/tmp' "$DOCKER_LOG"
}

@test "dev refuses to start before the first build" {
  DOCKER_IMAGE_EXISTS=0 run ag dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"run agentic build"* ]]
}

@test "dev status reports a missing container" {
  run ag dev status
  [ "$output" = "agentic-demo-dev: not created" ]
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/cli-run.bats`
Expected: FAIL.

- [ ] **Step 3: Implement the commands**

Add to `bin/agentic`, before `main`:

```bash
# run_image: the project image, or the base with a notice before the first build.
run_image() {
  local img; img="$(project_image)"
  if image_exists "$img"; then printf '%s\n' "$img"; return 0; fi
  say "$img not built yet; using $(base_image_of) (run agentic build)"
  base_image_of
}

cmd_shell() {
  need_config
  local img tty=(-i)
  img="$(run_image)"
  if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
  build_run_args "$img"
  docker run --rm "${tty[@]}" "${RUN_ARGS[@]}" "$img" "$@"
}

# harness_authenticated claude|copilot: a login on disk or a token in .env.
harness_authenticated() {
  local h="$1" data env
  data="$AGENTIC_DATA/projects/$(project_name)/harness/$h"; env="$(cfg_dir)/.env"
  case "$h" in
    claude)
      [ -s "$data/.credentials.json" ] \
        || [ -n "$(dotenv_value "$env" ANTHROPIC_API_KEY)$(dotenv_value "$env" CLAUDE_CODE_OAUTH_TOKEN)$(dotenv_value "$env" CLAUDE_CODE_USE_BEDROCK)" ] ;;
    copilot)
      [ -n "$(dotenv_value "$env" COPILOT_GITHUB_TOKEN)$(dotenv_value "$env" GH_TOKEN)" ] \
        || tr -d '[:space:]' < "$data/config.json" 2>/dev/null | grep -q '"logged_in_users":\[{' ;;
    *) return 1 ;;
  esac
}

auth_help() {
  cat >&2 <<EOF
agentic: $1 is not authenticated for $(project_name). Pick one:
  Claude   subscription   agentic login claude      (then /login inside, then /exit)
           API key        ANTHROPIC_API_KEY=... in .agentic/.env
           Bedrock        CLAUDE_CODE_USE_BEDROCK=1 and AWS_PROFILE=... in .agentic/.env
  Copilot  device login   agentic login copilot     (then /login inside, then /exit)
           token          COPILOT_GITHUB_TOKEN=... (or GH_TOKEN) in .agentic/.env, GH_HOST for Enterprise
EOF
}

cmd_login() {
  need_config
  local h="${1:-claude}" img
  case "$h" in claude|copilot) ;; *) die "usage: agentic login [claude|copilot]" ;; esac
  img="$(run_image)"
  if harness_authenticated "$h"; then say "$h already has a login or token for $(project_name); starting it anyway"; fi
  echo "Starting $h. Run /login, follow the instructions, then /exit. The login is kept for this project."
  build_run_args "$img"
  docker run --rm -it "${RUN_ARGS[@]}" "$img" "$h"
}

cmd_setup() {
  need_config
  local img h
  img="$(run_image)"
  h="$(image_label "$img" agentic.harness)"
  case "$h" in claude|copilot) ;; *) h=claude ;; esac
  if ! harness_authenticated "$h"; then auth_help "$h"; exit 1; fi
  build_run_args "$img"
  if [ "$h" = copilot ]; then set -- copilot -i "/agentic-setup"; else set -- claude "/agentic-setup"; fi
  docker run --rm -it "${RUN_ARGS[@]}" "$img" "$@"
}

WSL_ARGS=(-e DISPLAY=:0 -e WAYLAND_DISPLAY=/run/wslg/wayland-0 -e TMUX_TMPDIR=/home/dev
  -v /mnt/wslg/runtime-dir:/run/wslg -v /tmp:/tmp)

dev_start() {
  local name="$1" img="$2" wsl="$3" extra=()
  image_exists "$img" || die "$img is not built; run agentic build"
  build_run_args "$img"
  if [ "$wsl" = 1 ]; then extra=("${WSL_ARGS[@]}"); fi
  docker run -d --name "$name" --restart unless-stopped --label agentic.kind=dev \
    "${RUN_ARGS[@]}" "${extra[@]}" "$img" sleep infinity >/dev/null
}

dev_status() {
  local name="$1" img="$2" running cur latest
  if ! running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
    echo "$name: not created"; return 0
  fi
  cur="$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)"
  latest="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)"
  echo "$name: running=$running image=$img"
  if [ -n "$latest" ] && [ "$cur" != "$latest" ]; then echo "outdated: $img was rebuilt; run agentic dev recreate"; fi
}

cmd_dev() {
  need_config
  local action=attach wsl=0 name img
  while [ $# -gt 0 ]; do
    case "$1" in
      attach|stop|recreate|status) action="$1" ;;
      --host-profile) [ "${2:-}" = wsl ] || die "only --host-profile wsl is supported"; wsl=1; shift ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  name="agentic-$(project_name)-dev"; img="$(project_image)"
  case "$action" in
    stop) docker stop "$name" >/dev/null; echo "stopped $name" ;;
    status) dev_status "$name" "$img" ;;
    recreate)
      docker rm -f "$name" >/dev/null 2>&1 || true
      dev_start "$name" "$img" "$wsl"
      docker exec -it "$name" dev-shell ;;
    attach)
      case "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" in
        true) ;;
        false) docker start "$name" >/dev/null ;;
        *) dev_start "$name" "$img" "$wsl" ;;
      esac
      docker exec -it "$name" dev-shell ;;
  esac
}
```

In `main`, add:

```bash
    shell) cmd_shell "$@" ;;
    login) cmd_login "$@" ;;
    setup) cmd_setup "$@" ;;
    dev) cmd_dev "$@" ;;
```

Note: the stub's `docker stop` prints nothing, so the test reads `stopped` from our own echo.

- [ ] **Step 4: Run the tests**

Run: `bats tests/bats/cli-run.bats tests/bats/cli-core.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add bin/agentic tests/bats/cli-run.bats
git commit -m "feat: agentic shell, login, setup and dev"
```

---

### Task 12: `agentic doctor`

**Files:**
- Create: `image/bin/agentic-doctor`
- Modify: `bin/agentic` (add `cmd_doctor` and the `doctor` case)
- Test: `tests/bats/doctor.bats`

**Interfaces:**
- Consumes: start steps with `--check` (Tasks 5–7), presets' `check` (Task 3), `cfg`,
  `cfg_true`, `claude_dir`, `claude_json`, `copilot_dir` (Task 2), `run_image`,
  `build_run_args`, `image_label` (Tasks 9, 11).
- Produces:
  - `agentic-doctor` (in the image): sections *start steps*, *tools*, *logins*, *mcp servers*,
    *certificates*, *docker*, *image*; lines `  ok    …`, `  warn  …`, `  error …`; a summary
    `doctor: N errors, M warnings`; exit 1 when there is any error. Honours
    `AGENTIC_STEPS_DIR` and `AGENTIC_IMAGE_CONFIG_HASH`.
  - `agentic doctor` (host): runs `agentic-doctor` through the entrypoint (so the real start is
    exercised first) with `AGENTIC_IMAGE_CONFIG_HASH` set from the image label; exits with its
    status.

- [ ] **Step 1: Write the failing tests**

`tests/bats/doctor.bats`:

```bash
#!/usr/bin/env bats
load helpers
load docker-stub

setup() {
  make_tmp_home
  make_agentic_dir
  export AGENTIC_STEPS_DIR="$BATS_TEST_TMPDIR/steps" AGENTIC_OPT="$BATS_TEST_TMPDIR/opt"
  mkdir -p "$AGENTIC_STEPS_DIR" "$AGENTIC_STATE" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  for c in claude copilot gh aws az; do
    printf '#!/bin/sh\necho "%s 1.0"\n' "$c" > "$BATS_TEST_TMPDIR/bin/$c"; chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  printf '#!/bin/sh\nexit "${CURL_RC:-0}"\n' > "$BATS_TEST_TMPDIR/bin/curl"; chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  # a JDK 21 that answers `java -version`
  mkdir -p "$AGENTIC_OPT/java/21/bin"
  printf '#!/bin/sh\necho "openjdk version 21" >&2\n' > "$AGENTIC_OPT/java/21/bin/java"; chmod +x "$AGENTIC_OPT/java/21/bin/java"
  resolved '{"project":"demo","git":{"host":"github.com"},"tools":{"java":{"versions":[21],"default":21},"apt":[]},"mcp":{"atlassian":{"enabled":false},"playwright":{"enabled":false},"graphify":{"enabled":false},"custom":[]},"docker":{"socket":false}}'
  echo '{}' > "$HOME/.claude.json"
  export ANTHROPIC_API_KEY=k COPILOT_GITHUB_TOKEN=t
  D="$REPO_ROOT/image/bin/agentic-doctor"
}

resolved() { printf '%s\n' "$1" > "$AGENTIC_STATE/config.json"; }
step() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$AGENTIC_STEPS_DIR/$1.sh"; }

@test "a healthy container passes" {
  step 10-ok 'exit 0'
  run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    10-ok"* ]]
  [[ "$output" == *"ok    java 21"* ]]
  [[ "$output" == *"doctor: 0 errors, 0 warnings"* ]]
}

@test "a failing start step is an error, a warning step a warning" {
  step 10-bad 'echo "agentic: config broken"; exit 1'
  step 20-meh 'echo "agentic: not ideal"; exit 2'
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error 10-bad: config broken"* ]]
  [[ "$output" == *"warn  20-meh: not ideal"* ]]
}

@test "a configured tool that is not installed is an error" {
  resolved '{"project":"demo","tools":{"terraform":"1.9.8","apt":[]},"mcp":{"custom":[]},"docker":{"socket":false}}'
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error terraform 1.9.8 is not installed"* ]]
}

@test "a missing login is only a warning" {
  unset ANTHROPIC_API_KEY COPILOT_GITHUB_TOKEN
  run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  claude: not authenticated"* ]]
  [[ "$output" == *"warn  copilot: not authenticated"* ]]
}

@test "an HTTP MCP server with an untrusted certificate is an error with the fix" {
  echo '{"mcpServers":{"docs":{"type":"http","url":"https://mcp.example.com/mcp"}}}' > "$HOME/.claude.json"
  CURL_RC=60 run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error mcp docs: TLS certificate not trusted"* ]]
  [[ "$output" == *".agentic/certs"* ]]
}

@test "an unreachable HTTP MCP server is a warning" {
  echo '{"mcpServers":{"docs":{"type":"http","url":"https://mcp.example.com/mcp"}}}' > "$HOME/.claude.json"
  CURL_RC=6 run bash "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  mcp docs unreachable"* ]]
}

@test "a stdio MCP server whose command is missing is an error" {
  echo '{"mcpServers":{"tool":{"type":"stdio","command":"does-not-exist"}}}' > "$HOME/.claude.json"
  run bash "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error mcp tool: command does-not-exist not found"* ]]
}

@test "a config that changed since the build is reported" {
  AGENTIC_IMAGE_CONFIG_HASH=0000000000000000 run bash "$D"
  [[ "$output" == *"warn  agentic.yaml changed since the last agentic build"* ]]
}

@test "the host command runs agentic-doctor through the entrypoint with the image's config hash" {
  install_docker_stub
  P="$BATS_TEST_TMPDIR/proj"; mkdir -p "$P/.agentic"; git init -q "$P"
  printf 'version: 1\nproject: demo\n' > "$P/.agentic/agentic.yaml"
  DOCKER_LABEL=abc123 run bash -c "cd '$P' && bash '$REPO_ROOT/bin/agentic' doctor"
  [ "$status" -eq 0 ]
  call="$(docker_sub run)"
  grep -qx 'AGENTIC_IMAGE_CONFIG_HASH=abc123' <<<"$call"
  [ "$(tail -n 1 <<<"$call")" = agentic-doctor ]
  run grep -qx -- '--entrypoint' <<<"$call"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/doctor.bats`
Expected: FAIL.

- [ ] **Step 3: Write `agentic-doctor`**

`image/bin/agentic-doctor`:

```bash
#!/usr/bin/env bash
# Checks a configured container: the start steps in check mode, then live probes.
# Exit 1 when there is any error; warnings alone pass.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AGENTIC_DIR="${AGENTIC_DIR:-$(cd "$here/.." && pwd)}"
# shellcheck source=../lib/common.sh
source "$AGENTIC_DIR/lib/common.sh"
errors=0; warnings=0
ok() { echo "  ok    $*"; }
warn() { echo "  warn  $*"; warnings=$((warnings + 1)); }
err() { echo "  error $*"; errors=$((errors + 1)); }
last_line() { tail -n 1 <<<"$1" | sed 's/^agentic: //'; }

# probe_url LABEL URL: TLS failures are errors (a CA is missing), other failures warnings.
probe_url() {
  local rc
  curl -sS -o /dev/null --max-time 10 "$2" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ok "$1 reachable" ;;
    35|51|58|59|60|77|83) err "$1: TLS certificate not trusted ($2); add the CA to .agentic/certs and run agentic build" ;;
    *) warn "$1 unreachable ($2, curl exit $rc)" ;;
  esac
}

echo "start steps"
for s in "${AGENTIC_STEPS_DIR:-$AGENTIC_DIR/start.d}"/[0-9][0-9]-*.sh; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .sh)"
  out="$(bash "$s" --check </dev/null 2>&1)"; rc=$?
  case "$rc" in
    0) ok "$name" ;;
    2) warn "$name: $(last_line "$out")" ;;
    *) err "$name: $(last_line "$out")" ;;
  esac
done

echo "tools"
while IFS=$'\t' read -r tool version; do
  if v="$(bash "$AGENTIC_DIR/tools/$tool.sh" check "$version" 2>&1)"; then ok "$tool $version: $(head -1 <<<"$v")"
  else err "$tool $version is not installed (run agentic build)"; fi
done < <(jq -r '.tools // {} | to_entries[]
  | select(.key != "apt" and .key != "extra_dockerfile" and .value != false and .value != null)
  | .key as $k | (if (.value | type) == "object" then .value.versions[]
                  elif (.value | type) == "array" then .value[] else .value end)
  | [$k, tostring] | @tsv' "$RESOLVED")
for c in claude copilot git gh aws az; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else err "$c is missing from the image"; fi
done

echo "logins"
if [ -s "$(claude_dir)/.credentials.json" ] || [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}${CLAUDE_CODE_USE_BEDROCK:-}" ]; then
  ok "claude"
else warn "claude: not authenticated (agentic login claude, or a key in .agentic/.env)"; fi
if [ -n "${COPILOT_GITHUB_TOKEN:-}${GH_TOKEN:-}" ] \
   || jq -e '(.logged_in_users // []) | length > 0' "$(copilot_dir)/config.json" >/dev/null 2>&1; then
  ok "copilot"
else warn "copilot: not authenticated (agentic login copilot, or COPILOT_GITHUB_TOKEN in .agentic/.env)"; fi

echo "mcp servers"
while IFS=$'\t' read -r name type target; do
  case "$type" in
    http) probe_url "mcp $name" "$target" ;;
    *) if command -v "$target" >/dev/null 2>&1; then ok "mcp $name"; else err "mcp $name: command $target not found"; fi ;;
  esac
done < <(jq -r '.mcpServers // {} | to_entries[] | [.key, (.value.type // "stdio"), (.value.url // .value.command)] | @tsv' "$(claude_json)" 2>/dev/null)

echo "certificates"
for key in .mcp.atlassian.jira_url .mcp.atlassian.confluence_url; do
  u="$(cfg "$key")"
  if [ -n "$u" ] && cfg_true .mcp.atlassian.enabled; then probe_url "${key##*.}" "$u"; fi
done
host="$(cfg .git.host)"
if [ -n "$host" ]; then probe_url "git host" "https://$host"; fi

echo "docker"
if cfg_true .docker.socket; then
  if docker version >/dev/null 2>&1; then ok "docker daemon"; else err "docker.socket is true but the daemon is not reachable"; fi
else ok "docker socket not requested"; fi

echo "image"
if [ -n "${AGENTIC_IMAGE_CONFIG_HASH:-}" ]; then
  if [ "$(sha256sum < "$RESOLVED" | cut -c1-16)" = "$AGENTIC_IMAGE_CONFIG_HASH" ]; then ok "built from the current agentic.yaml"
  else warn "agentic.yaml changed since the last agentic build; tools, certs, plugins and docker apply only after agentic build"; fi
fi

echo "doctor: $errors errors, $warnings warnings"
[ "$errors" -eq 0 ]
```

`chmod +x image/bin/agentic-doctor`.

Note for the healthy test: the default fixture has `git.host: github.com`, so the certificate
section probes `https://github.com` through the stubbed `curl` (exit 0).

- [ ] **Step 4: Add the host command**

Add to `bin/agentic` before `main`:

```bash
cmd_doctor() {
  need_config
  local img; img="$(run_image)"
  build_run_args "$img"
  docker run --rm "${RUN_ARGS[@]}" -e "AGENTIC_IMAGE_CONFIG_HASH=$(image_label "$img" agentic.config.hash)" "$img" agentic-doctor
}
```

In `main`, add `doctor) cmd_doctor "$@" ;;`.

- [ ] **Step 5: Run the tests**

Run: `bats tests/bats/doctor.bats`
Expected: all PASS.

- [ ] **Step 6: Lint and commit**

Run: `make lint` — expected clean.

```bash
git add image/bin/agentic-doctor bin/agentic tests/bats/doctor.bats
git commit -m "feat: agentic doctor"
```

---

### Task 13: The `/agentic-setup` skill and the documentation

**Files:**
- Create: `tools/gen-config-docs.sh`, `docs/configuration.md` (generated), `docs/overlay.md`,
  `README.md`
- Modify: `skills/agentic-setup/SKILL.md` (replace the placeholder), `Makefile` (lint: docs check)
- Test: `tests/bats/docs.bats`

**Interfaces:**
- Consumes: the schema and defaults (Task 2), the CLI commands (Tasks 9–12), the overlay
  contract (spec §6.4), `agentic-config validate` (Task 2), `/opt/agentic/schema` (Task 8).
- Produces: `tools/gen-config-docs.sh [--check]`; the skill `agentic-setup` copied into both
  harnesses by `60-skills`.

- [ ] **Step 1: Write the failing tests**

`tests/bats/docs.bats`:

```bash
#!/usr/bin/env bats
load helpers

@test "the configuration reference lists every field with type, default and description" {
  run bash "$REPO_ROOT/tools/gen-config-docs.sh"
  [ "$status" -eq 0 ]
  grep -qF '| `project` | string |' <<<"$output"
  grep -qF '| `tools.maven` | false or string | `"3.9.9"` |' <<<"$output"
  grep -qF '| `mcp.playwright.mode` | "headless" / "headed" | `"headless"` |' <<<"$output"
  grep -qF '| `docker.socket` | boolean | `false` |' <<<"$output"
}

@test "--check fails when docs/configuration.md is stale" {
  cp -r "$REPO_ROOT" "$BATS_TEST_TMPDIR/copy"
  echo stale >> "$BATS_TEST_TMPDIR/copy/docs/configuration.md"
  run bash "$BATS_TEST_TMPDIR/copy/tools/gen-config-docs.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
}

@test "the committed reference is current" {
  run bash "$REPO_ROOT/tools/gen-config-docs.sh" --check
  [ "$status" -eq 0 ]
}

@test "the setup skill has a name, a description and its rules" {
  f="$REPO_ROOT/skills/agentic-setup/SKILL.md"
  [ "$(sed -n 1p "$f")" = --- ]
  grep -qx 'name: agentic-setup' "$f"
  grep -q '^description: ' "$f"
  grep -q 'agentic-config validate' "$f"
  grep -q 'Never read .agentic/.env' "$f"
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/bats/docs.bats`
Expected: FAIL.

- [ ] **Step 3: Write the generator**

`tools/gen-config-docs.sh`:

```bash
#!/usr/bin/env bash
# Generates docs/configuration.md from the schema and the defaults. --check fails when it is stale.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

render() {
  local defaults
  defaults="$(yq -o=json -I=0 . "$root/config/defaults.yaml")"
  echo "# agentic.yaml reference"
  echo
  echo "Generated from \`schema/agentic.schema.json\` and \`config/defaults.yaml\` by"
  echo "\`tools/gen-config-docs.sh\`. Do not edit by hand."
  echo
  echo "| Field | Type | Default | Description |"
  echo "|---|---|---|---|"
  jq -r --argjson d "$defaults" '
    def tdesc:
      if has("type") then (.type | if type == "array" then join(" or ") else . end)
      elif has("enum") then (.enum | map(tojson) | join(" / "))
      elif has("anyOf") then ([.anyOf[] | if has("enum") and .enum == [false] then "false" else tdesc end] | join(" or "))
      else "any" end;
    def rows($p):
      (.properties // {}) | to_entries[] | .key as $k | .value as $v | ($p + [$k]) as $path
      | ("| `" + ($path | join(".")) + "` | " + ($v | tdesc) + " | "
         + (($d | getpath($path)) as $x | if $x == null then "" else "`" + ($x | tojson) + "`" end)
         + " | " + ($v.description // "") + " |"),
        ($v | rows($path));
    rows([])' "$root/schema/agentic.schema.json"
}

if [ "${1:-}" = --check ]; then
  if ! diff -q "$root/docs/configuration.md" <(render) >/dev/null 2>&1; then
    echo "docs/configuration.md is stale; run: tools/gen-config-docs.sh > docs/configuration.md" >&2
    exit 1
  fi
else
  render
fi
```

`chmod +x tools/gen-config-docs.sh`, then generate the reference:
`tools/gen-config-docs.sh > docs/configuration.md`.

Add to the `lint` recipe in `Makefile`, before the leak check:

```make
	tools/gen-config-docs.sh --check
```

- [ ] **Step 4: Write the skill**

`skills/agentic-setup/SKILL.md`:

```markdown
---
name: agentic-setup
description: Use when the user wants to configure, review or extend agentic-dev-base for this repository — the .agentic/ folder, agentic.yaml, which tools, JDKs, MCP servers, plugins or certificates the container needs, or "help me set up this project for agentic work".
---

# Configure agentic-dev-base for this project

You refine `.agentic/agentic.yaml` with the user. `agentic init` already wrote a first version
from a deterministic scan; you add judgement. You work in `/work` (the repository). Reference for
every field: `/opt/agentic/schema/agentic.schema.json` (descriptions included).

## Rules

- Write only inside `/work/.agentic/`. Never touch `CLAUDE.md`, `AGENTS.md` or `.claude/`; if
  project rules would help, show the text and let the user add it.
- Never read .agentic/.env. Secrets go into `.agentic/.env.example` as names only, and into the
  config as `${NAME}` references.
- Never guess company hosts or URLs (Jira, Confluence, git host, MCP servers). Ask.
- Never commit, never run `agentic build` (you are inside the container; the build runs on the
  host).
- Ask one question at a time. Use a multiple-choice question when the options are clear.

## Procedure

1. **Read**: `.agentic/agentic.yaml`, `.agentic/detect-report.md`, build files (`pom.xml`,
   `build.gradle*`, `package.json`, `pyproject.toml`, `*.tf`, `go.mod`, `*.csproj`), CI files
   (`.gitlab-ci.yml`, `.github/workflows/*`), Dockerfiles and compose files, the README, and
   any existing agent instruction files. For an empty repository, skip to step 3 and ask for
   the stack.
2. **Find gaps you can see**, and propose each fix with its reason. Typical ones:
   - a module targets a JDK that `tools.java.versions` lacks;
   - the Maven wrapper pins a different Maven than `tools.maven`;
   - tests use a compose file or Testcontainers while `docker.socket` is false (explain that
     the socket is host root before suggesting it);
   - Jira keys appear in commit messages or branch names but `mcp.atlassian` is disabled;
   - Terraform has no exact version.
3. **Ask for what you cannot see**: tools used day to day that are not in the repository, deploy
   targets and their CLIs, the Atlassian URLs, extra MCP servers, the preferred harness,
   headless or headed browser, corporate CA certificates (they go into `.agentic/certs/*.crt`).
4. **Handle specific needs with the lowest rung that works**:

   | Need | Use |
   |---|---|
   | system package | `tools.apt` |
   | known tool, other version | the preset's version |
   | unknown tool | `.agentic/Dockerfile.extra` (root, `COPY` from `.agentic/`) |
   | user-level install | `.agentic/hooks/on-build.sh` |
   | something at every start | `.agentic/hooks/on-start.sh` (sees `.env`) |
   | MCP server | `mcp.custom` |
   | plugin | `plugins` |
   | project skill | `.agentic/skills/<name>/SKILL.md` |

5. **Write and validate**: edit the files, then run `agentic-config validate /work/.agentic` and
   fix every error it prints before you continue.
6. **Hand over**: summarise what changed; say whether a rebuild is needed (tools, certs,
   plugins, `Dockerfile.extra`, `on-build.sh`, `docker.socket` need one; MCP servers, skills
   and `on-start.sh` do not); list the variables to put into `.agentic/.env`; and tell the user
   to run, on the host, `agentic build` (if needed) and `agentic doctor`.
```

- [ ] **Step 5: Write the overlay guide and the README**

`docs/overlay.md`:

````markdown
# Building an overlay

An overlay is an image built `FROM agentic-dev-base` that adds an organisation's pieces:
presets, default config, skills, start steps, worker adapters. It lives in its own repository
and never patches base files. Projects use it with `base_image:` in `agentic.yaml`.

## Contract

| Path in the image | Purpose |
|---|---|
| `/opt/agentic/start.d/NN-*.sh` | Extra start steps, run in number order with the base steps. Exit 0 ok, 1 fatal, 2 warning; support `--check`; export variables with `env_export` from `/opt/agentic/lib/common.sh`. |
| `/opt/agentic/tools/<name>.sh` | Extra tool presets: `install VERSION`, `env VERSION`, `check VERSION`. Projects use them as `tools.<name>: "<version>"`. |
| `/opt/agentic/skills/<name>/` | Extra skills, copied into both harnesses at start. |
| `/opt/agentic/defaults/agentic.yaml` | Organisation defaults, merged under each project's `agentic.yaml` (the project wins; lists are replaced). |
| `/opt/agentic/worker.d/<name>.sh` | Worker-mode adapters, started with `AGENTIC_WORKER_MODE=<name>`. |

The base guarantees for an adapter: bash, curl, tar, git and Node are present; the entrypoint
needs no mount and no TTY; start steps never wait for input; `CLAUDE_CONFIG_DIR` and
`COPILOT_HOME` relocate the harness homes and the start steps follow them.

## Example

```dockerfile
FROM agentic-dev-base:local
COPY defaults/agentic.yaml /opt/agentic/defaults/agentic.yaml
COPY tools/ /opt/agentic/tools/
COPY skills/ /opt/agentic/skills/
COPY --chmod=755 start.d/ /opt/agentic/start.d/
COPY --chmod=755 worker.d/ /opt/agentic/worker.d/
```

A worker adapter receives the configured container and the container's arguments:

```bash
#!/usr/bin/env bash
# /opt/agentic/worker.d/example.sh — started instead of the CLI command.
set -euo pipefail
exec my-worker --config "$HOME/.agentic/config.json" "$@"
```
````

`README.md`:

```markdown
# agentic-dev-base

A container toolbox for agentic development. One base image with the tools agents need (git,
Claude Code, Copilot CLI, AWS and Azure CLI, gh, Java 21 and Maven, Node 22, Python 3.12, Docker
CLI, Playwright with Chromium) and recommended extras (Atlassian, Playwright and Graphify MCP
servers, the Superpowers plugin, the `/agentic-setup` skill). Each project adds its own layer
from `.agentic/agentic.yaml`.

## Prerequisites

bash, git and Docker. Clone this repository once and put `bin/agentic` on your PATH.

Behind a TLS-intercepting proxy, put your CA certificate into `~/.agentic/ca/` before the first
build (the base image needs it to download anything), and into the project's `.agentic/certs/`
so Java, Node, Python and Chromium trust it too.

## Quick start

    cd your-project
    agentic init          # writes .agentic/ with detected tools; commit it
    agentic build         # base image (first time ~15 min), then agentic-<project>:local
    agentic login         # once per project (or put a key or token in .agentic/.env)
    agentic setup         # optional: refine .agentic/ with the /agentic-setup skill
    agentic dev           # persistent container, tmux session in /work; run claude or copilot
    agentic doctor        # when something looks wrong

## Extending

| Need | Where |
|---|---|
| system package | `tools.apt` |
| another tool version | the preset (`tools.java: {versions: [8, 17], default: 17}`) |
| any other tool | `.agentic/Dockerfile.extra` |
| user-level install | `.agentic/hooks/on-build.sh` |
| something at every start | `.agentic/hooks/on-start.sh` |
| MCP server | `mcp.custom` |
| plugin | `plugins` |
| project skill | `.agentic/skills/<name>/SKILL.md` |
| organisation-wide pieces | an overlay image, see `docs/overlay.md` |

Every field: `docs/configuration.md`. Design: `docs/architecture.md`.
```

- [ ] **Step 6: Run the tests and lint**

Run: `bats tests/bats/docs.bats && make lint`
Expected: all PASS; lint clean (the docs check passes because you generated the file in Step 3).

- [ ] **Step 7: Commit**

```bash
git add tools/gen-config-docs.sh docs/configuration.md docs/overlay.md README.md skills/agentic-setup/SKILL.md Makefile tests/bats/docs.bats
git commit -m "docs: setup skill, configuration reference, overlay guide and README"
```

---

### Task 14: Smoke test and manual runbook

**Files:**
- Create: `tests/image/smoke.sh`, `tests/fixtures/smoke-overlay/Dockerfile`,
  `tests/fixtures/smoke-overlay/start.d/45-overlay.sh`,
  `tests/fixtures/smoke-overlay/tools/hello.sh`,
  `tests/fixtures/smoke-overlay/skills/overlay-skill/SKILL.md`,
  `tests/fixtures/smoke-overlay/worker.d/fake.sh`,
  `tests/fixtures/smoke-overlay/defaults/agentic.yaml`,
  `tests/fixtures/smoke-project/README.md`,
  `tests/fixtures/smoke-project/.agentic/agentic.yaml`,
  `tests/fixtures/smoke-project/.agentic/Dockerfile.extra`,
  `tests/fixtures/smoke-project/.agentic/hooks/on-start.sh`,
  `tests/fixtures/smoke-project/.agentic/skills/smoke-skill/SKILL.md`,
  `tests/fixtures/smoke-project/.agentic/certs/.gitkeep`,
  `tests/fixtures/smoke-project/.agentic/.gitignore`,
  `tests/fixtures/smoke-project/Fetch.java`, `tests/e2e/README.md`

**Interfaces:**
- Consumes: everything. `make smoke` builds the base (`agentic build-base`), then runs
  `tests/image/smoke.sh`.
- Produces: proof of every success criterion in spec §1 and the smoke row of spec §8.

- [ ] **Step 1: Write the overlay fixture**

`tests/fixtures/smoke-overlay/Dockerfile`:

```dockerfile
FROM agentic-dev-base:local
USER root
COPY defaults/agentic.yaml /opt/agentic/defaults/agentic.yaml
COPY tools/ /opt/agentic/tools/
COPY skills/ /opt/agentic/skills/
COPY start.d/ /opt/agentic/start.d/
COPY worker.d/ /opt/agentic/worker.d/
RUN chmod 755 /opt/agentic/tools/hello.sh /opt/agentic/start.d/45-overlay.sh /opt/agentic/worker.d/fake.sh
USER dev
```

`tests/fixtures/smoke-overlay/defaults/agentic.yaml`:

```yaml
git:
  host: localhost
```

`tests/fixtures/smoke-overlay/start.d/45-overlay.sh`:

```bash
#!/usr/bin/env bash
# Proves an overlay start step runs between the base steps.
touch "$HOME/.overlay-step-ran"
```

`tests/fixtures/smoke-overlay/tools/hello.sh`:

```bash
#!/usr/bin/env bash
# A preset only the overlay provides.
# shellcheck source=/dev/null
source /opt/agentic/tools/_lib.sh
home() { echo "$AGENTIC_OPT/hello/$1"; }
do_install() {
  mkdir -p "$(home "$1")/bin"
  printf '#!/bin/sh\necho "hello %s"\n' "$1" > "$(home "$1")/bin/hello"
  chmod 755 "$(home "$1")/bin/hello"
}
do_env() { echo "PATH=$(home "$1")/bin"; }
do_check() { "$(home "$1")/bin/hello"; }
preset_main "$@"
```

`tests/fixtures/smoke-overlay/skills/overlay-skill/SKILL.md`:

```markdown
---
name: overlay-skill
description: A skill shipped by the smoke-test overlay.
---
Overlay skill.
```

`tests/fixtures/smoke-overlay/worker.d/fake.sh`:

```bash
#!/usr/bin/env bash
# A worker adapter that reports what it was given.
echo "FAKE-WORKER project=$(jq -r .project "$HOME/.agentic/config.json") args=$*"
```

- [ ] **Step 2: Write the project fixture**

`tests/fixtures/smoke-project/README.md`: `# smoke project`

`tests/fixtures/smoke-project/.agentic/agentic.yaml`:

```yaml
version: 1
project: smoke-project
base_image: agentic-smoke-overlay:local
tools:
  java: {versions: [17, 8], default: 17}
  terraform: "1.5.7"
  hello: "1.0"
  apt: [tree]
mcp:
  atlassian: {enabled: true, jira_url: "https://jira.example.com"}
```

`tests/fixtures/smoke-project/.agentic/Dockerfile.extra`:

```
RUN echo extra > /etc/agentic-extra
```

`tests/fixtures/smoke-project/.agentic/hooks/on-start.sh`:

```bash
#!/usr/bin/env bash
touch "$HOME/.on-start-ran"
```

`tests/fixtures/smoke-project/.agentic/skills/smoke-skill/SKILL.md`:

```markdown
---
name: smoke-skill
description: A project skill from the smoke-test fixture.
---
Project skill.
```

`tests/fixtures/smoke-project/.agentic/.gitignore`:

```
.env
.build/
```

`touch tests/fixtures/smoke-project/.agentic/certs/.gitkeep`.

`tests/fixtures/smoke-project/Fetch.java`:

```java
// Exits 0 when the URL answers 200 over TLS the JDK trusts.
public class Fetch {
  public static void main(String[] args) throws Exception {
    var client = java.net.http.HttpClient.newHttpClient();
    var request = java.net.http.HttpRequest.newBuilder(java.net.URI.create(args[0])).build();
    var response = client.send(request, java.net.http.HttpResponse.BodyHandlers.discarding());
    System.exit(response.statusCode() == 200 ? 0 : 1);
  }
}
```

- [ ] **Step 3: Write the smoke test**

`tests/image/smoke.sh`:

```bash
#!/usr/bin/env bash
# End-to-end check of agentic-dev-base: an overlay, a derived project image, the container start,
# CA trust, worker mode, a start without mounts, and doctor. Needs Docker, openssl and script(1).
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
```

Notes:
- The broken-setup step appends to the `mcp:` block, which is the last block of the fixture's
  `agentic.yaml`; keep `mcp:` last in that fixture.
- `doctor` on the good setup must pass although `jira.example.com` and `https://localhost` are
  unreachable: unreachable is a warning, only a TLS failure is an error. That is why the
  overlay's default `git.host` is `localhost`.

`chmod +x tests/image/smoke.sh`.

- [ ] **Step 4: Write the manual runbook**

`tests/e2e/README.md`:

```markdown
# Manual end-to-end runbook

Run on a real machine before tagging a release. Each step lists what you should see.

1. **Fresh clone.** Clone `agentic-dev-base`, put `bin/agentic` on PATH, `make test lint smoke`
   → all green.
2. **Init on a real repository.** `cd` into a real project, `agentic init` → `.agentic/` with
   the detected tools; `detect-report.md` names the build files it read.
3. **Build.** `agentic build` → base image (first time), then `agentic-<project>:local`.
4. **Logins, both harnesses, both modes.**
   - `agentic login claude` → `/login` in the browser flow, `/exit`; a second `agentic shell
     claude` needs no login.
   - Remove the login, put `ANTHROPIC_API_KEY` in `.agentic/.env`; `agentic doctor` shows
     `ok claude`.
   - `agentic login copilot` → device code, `/exit`; then the token mode with
     `COPILOT_GITHUB_TOKEN`.
5. **Setup dialogue.** `agentic setup` → Claude starts in the skill, asks one question at a time,
   writes only `.agentic/`, runs `agentic-config validate`, ends with next steps.
6. **Dev mode.** `agentic dev` → tmux in `/work`; detach with `Ctrl-b d`; `agentic dev` again →
   same session. `agentic build` then `agentic dev status` → "outdated"; `agentic dev recreate`.
7. **Headed Playwright on WSLg.** Set `mcp.playwright.mode: headed`, `agentic dev recreate
   --host-profile wsl`, ask Claude to open a page → a visible Chromium window.
8. **Corporate network.** With your CA in `~/.agentic/ca/` and `.agentic/certs/`, the build and
   `agentic doctor` pass behind the proxy.
```

- [ ] **Step 5: Run the smoke test**

Run: `make smoke`
Expected: `smoke OK`. A failure prints the step and the container's output; fix the cause in the
owning task's files, rerun `make test lint`, then `make smoke` again.

- [ ] **Step 6: Run the whole suite**

Run: `make test && make lint`
Expected: all green, `leak-check: clean`.

- [ ] **Step 7: Commit**

```bash
git add tests/image tests/fixtures/smoke-overlay tests/fixtures/smoke-project tests/e2e
git commit -m "test: smoke test across overlay, project image, CA trust, worker mode and doctor; manual runbook"
```

---

## Spec coverage

| Spec section | Task |
|---|---|
| §1 success criteria | 14 (smoke proves each) |
| §2 layout | all; file map above |
| §3 commands | 9 (build, build-base), 10 (init), 11 (shell, login, setup, dev), 12 (doctor) |
| §4.1 base contents | 8 |
| §4.2 derived image | 4 (renderer), 9 (build) |
| §4.3 presets | 3 |
| §4.4 several versions | 3, 4 (toolchains, use-java) |
| §5.1–5.2 schema and rules | 2 |
| §5.3 extension ladder | 4 (extra, on-build), 7 (on-start, skills), 6 (custom MCP), 13 (docs, skill) |
| §6.1 inputs, mount-optional | 5 (05-workspace, config lookup), 9 (mounts), 14 (no-mount run) |
| §6.2 start steps | 5, 6, 7 |
| §6.3 harness auth | 11 (login, setup gate), 12 (doctor) |
| §6.4 overlay contract, worker mode | 2 (defaults merge), 5 (worker mode), 7 (skills), 4 (presets in image), 13 (overlay.md), 14 (fixture overlay) |
| §7 setup skill | 13 |
| §8 testing | every task; 14 |
| §9 leak check | 1 |
| §10 documentation | 1 (CLAUDE.md), 13 |
