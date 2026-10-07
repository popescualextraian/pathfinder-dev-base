# Sub-project 1 — base image and config

Status: approved design, 2026-10-07. Umbrella: `docs/architecture.md`.

## 1. Outcome

A developer clones `agentic-dev-base`, runs `agentic init` in their project, builds a project
image, logs in once, optionally refines the config with the `/agentic-setup` skill, and works in
a persistent dev container with every tool, MCP server, plugin and skill the project needs.

Success criteria:

- `init → build → login → dev` works on a fresh machine with Docker and nothing else.
- A project that needs Java 8 and 17, Terraform 1.5 and an unknown vendor CLI can be configured
  without changing the base.
- The same derived image starts with no mounts at all, from env only.
- An overlay image can add a start step, a tool preset, a skill and a worker-mode adapter
  without changing any base file.
- `make test`, `make lint` (including the leak check) and `make smoke` pass.

## 2. Repository layout

```
agentic-dev-base/
├── bin/agentic                     host CLI (bash)
├── image/
│   ├── Dockerfile                  base image → agentic-dev-base:local
│   ├── entrypoint.sh               runs start.d steps, then exec "$@"
│   ├── start.d/NN-*.sh             one script per start step (§6.2)
│   ├── worker.d/                   empty in the base; overlays add worker-mode adapters (§6.4)
│   ├── install-extras.sh           base MCP registrations and plugins
│   ├── seed-onboarding.sh          harness onboarding and trust
│   └── tools/<name>.sh             one installer per tool preset (§4.3)
├── derive/
│   ├── render-dockerfile.sh        agentic.yaml → Dockerfile.derived
│   ├── render-toolchains.sh        toolchains.xml, gradle.properties
│   └── detect.sh                   repo → detected tools (used by init)
├── skills/agentic-setup/SKILL.md   setup skill, baked into the image
├── templates/dot-agentic/          skeleton written by `agentic init`
├── schema/agentic.schema.json      validates agentic.yaml
├── tests/{bats,image,e2e,fixtures}/
├── tools/leak-check.sh
├── docs/
├── Makefile                        test, lint, build, smoke
├── CLAUDE.md, README.md
```

## 3. Commands (sub-project 1)

| Command | Does |
|---|---|
| `agentic init` | Writes `.agentic/` from the skeleton into the current repo and runs `detect.sh` to pre-fill `agentic.yaml`. No LLM, no token. Offers `agentic setup` at the end. |
| `agentic build [--refresh-plugins]` | Validates `agentic.yaml`. Builds `agentic-dev-base:local` if missing or outdated (the hash of `image/` is kept as an image label). Renders `Dockerfile.derived` and builds `agentic-<project>:local`. Bakes the host UID and GID into the user `dev`. |
| `agentic login [claude\|copilot]` | Interactive login in a throwaway container; state persists in `~/.agentic/harness/<harness>`. |
| `agentic setup` | Starts the derived image (or the base, if not built yet) interactively and runs the default harness with `/agentic-setup`. Without a login it prints the auth options and exits non-zero. |
| `agentic shell` | Throwaway container (`docker run --rm -it`) with the standard mounts. |
| `agentic dev [stop\|recreate\|status]` | Persistent workbench `agentic-<project>-dev` (`sleep infinity`, `--restart unless-stopped`); attaches tmux session `main` in `/work` through `dev-shell`. `status` shows the image and whether it is older than the latest build. `--host-profile wsl` adds WSLg conveniences (display, clipboard, shared `/tmp`). |
| `agentic doctor` | Runs every start step in check mode plus live probes: tool versions, MCP reachability, harness auth, certificate trust, Docker socket. Exits non-zero on errors; missing auth is a warning. |

The colleague's path: `init → build → login → (setup) → dev`.

## 4. Image

### 4.1 Base image contents

- **OS:** Ubuntu 24.04; bash, git, ssh, curl, wget, jq, yq, ripgrep, tmux, make,
  build-essential, unzip, ca-certificates, xvfb.
- **Harnesses:** Claude Code, Copilot CLI, ccusage.
- **Clouds and forges:** AWS CLI v2, Azure CLI, gh.
- **Runtimes:** Node 22 LTS, Python 3.12 with uv, pipx; Temurin 21 at `/opt/java/21`; Maven.
- **Containers:** Docker CLI with buildx and compose plugins.
- **Browser:** Playwright with Chromium.
- **Agent extras:** MCP servers Atlassian (`mcp-atlassian`), Playwright, Graphify; plugin
  Superpowers; Graphify (`Graphify-Labs/graphify`) as the default code index; the
  `/agentic-setup` skill.
- **User:** `dev`, with UID and GID set at derived build.
- No certificates and no company-specific values.

### 4.2 Derived image

`derive/render-dockerfile.sh` turns `agentic.yaml` into `Dockerfile.derived`, in this order:

1. `FROM agentic-dev-base:local`.
2. Certificates from `certs:` into the system store, Java cacerts (every JDK), Node
   (`NODE_EXTRA_CA_CERTS`), Python (`REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`) and Chromium's NSS
   store. First, so every later download trusts the proxy.
3. `tools.apt` packages.
4. Tool presets in a fixed order, each via `image/tools/<name>.sh install <version>`.
5. Generated `toolchains.xml` and `gradle.properties` (§4.4).
6. Project plugins into `/opt/agentic/claude-plugins` (and the Copilot equivalent).
7. `Dockerfile.extra`, appended as-is.
8. `hooks/on-build.sh` as `dev`, if present.
9. UID and GID of `dev`, git identity defaults, labels (base hash, config hash).

Build-time inputs never include `.env`. No secret reaches an image layer.

### 4.3 Tool presets

Each `image/tools/<name>.sh` implements:

- `install <version>`: installs into `/opt/<name>/<version>` from a pinned upstream release.
  Idempotent.
- `env <version>`: prints the `PATH` and `*_HOME` lines for that version.

Initial presets: java (Temurin), maven, gradle, node, python (via uv), terraform, checkov,
tflint, kubectl, helm, dotnet, go, glab, psql. Each preset has a bats test and a schema entry. A
new preset must pass the leak check.

### 4.4 Several versions of one tool

```yaml
tools:
  java: { versions: [8, 11, 17], default: 11 }
```

- Extra versions are installed side by side under `/opt/java/<v>`; 21 is always there.
- `default` sets `JAVA_HOME` and `PATH`.
- `~/.m2/toolchains.xml` lists every JDK, so Maven toolchains pick the right one.
- `~/.gradle/gradle.properties` sets `org.gradle.java.installations.paths`, so Gradle
  toolchains find them.
- `use-java <v>` switches `JAVA_HOME` and `PATH` in the current shell.
- Node follows the same pattern (`use-node <v>`). Python versions are handled by uv.

## 5. `agentic.yaml`

### 5.1 Schema

```yaml
version: 1
project: orders-service             # image agentic-orders-service:local, workspace dir name
base_image: agentic-dev-base:local  # or an overlay image built FROM the base

repos:                              # first = primary, mounted or cloned at /work
  - name: orders-service            # others cloned under /workspaces/<name>
    url: git@git.example.com:team/orders-service.git

git:
  host: git.example.com             # credential helper and GH_HOST
  user_name: ""                     # empty → host git config at build
  user_email: ""

tools:                              # build time
  java:      { versions: [17], default: 17 }
  maven:     "3.9"
  gradle:    false
  node:      { versions: [22], default: 22 }
  python:    ["3.12"]
  terraform: false                  # version string or false
  apt: []
  extra_dockerfile: .agentic/Dockerfile.extra

certs: .agentic/certs               # build time

plugins:                            # build time
  claude:  [superpowers@claude-plugins-official]
  copilot: []
  marketplaces: []

mcp:                                # run time
  atlassian:  { enabled: false, jira_url: "", confluence_url: "" }
  playwright: { enabled: true, mode: headless }    # headless | headed
  graphify:   { enabled: true }
  custom: []                        # claude mcp add-json shape; ${VAR} expanded from env

skills: .agentic/skills             # run time

hooks:
  on_build: .agentic/hooks/on-build.sh
  on_start: .agentic/hooks/on-start.sh
  on_start_required: false

harness:
  default: claude                   # claude | copilot
  claude:  { model: "" }
  copilot: { model: "" }

docker:
  socket: false
```

### 5.2 Rules

- Every field has a default. The smallest valid file is `version: 1` plus `project`.
- Secrets live only in `.agentic/.env` (git-ignored) and are referenced as `${VAR}`. The
  schema rejects a literal value under any key matching `*token*`, `*password*`, `*secret*`.
- `agentic build`, `agentic doctor` and start step `10-validate` validate against
  `schema/agentic.schema.json`.
- Atlassian tokens come from `JIRA_PERSONAL_TOKEN` and `CONFLUENCE_PERSONAL_TOKEN` in `.env`.
- Later sub-projects add top-level keys (`gate`, `branches`, `notify`, `jobs`); `version`
  allows the schema to change.

### 5.3 Extension ladder

| Need | Mechanism | Rebuild |
|---|---|---|
| System package | `tools.apt` | yes |
| Known tool, other version | preset version | yes |
| Unknown tool | `.agentic/Dockerfile.extra` (root, `COPY` from `.agentic/`) | yes |
| User-level install | `hooks/on-build.sh` (as `dev`, at build) | yes |
| Something at every start | `hooks/on-start.sh` (as `dev`, sees `.env`) | no |
| MCP server | `mcp.custom` | no |
| Plugin | `plugins` | yes |
| Project skill | `.agentic/skills/<name>/SKILL.md` | no |
| Project rules | the repo's own `CLAUDE.md`, `AGENTS.md`, `.claude/` | no |
| Tool many projects need | new preset in `agentic-dev-base` | yes |

Hooks and `Dockerfile.extra` come from the project repo and are as trusted as the repo.

## 6. Container start

### 6.1 Inputs

| Input | Local and VM | Without mounts |
|---|---|---|
| Code at `/work` | bind mount of the repo | cloned from `AGENTIC_REPO_URL` (and `AGENTIC_REPO_REF`) |
| Other repos | `/workspaces/<name>` mount | cloned from `repos:` |
| Config | `.agentic/` mounted read-only at `/agentic-config` | `/work/.agentic`, else `AGENTIC_CONFIG_B64` |
| Secrets | `--env-file .agentic/.env` | env from a secret store |
| Harness state | `~/.agentic/harness/{claude,copilot}` → `/home/dev/.claude`, `/home/dev/.copilot` | token env vars; an optional volume for history |
| AWS | `~/.aws` filtered to one profile, read-only | IAM role or env credentials |
| Docker socket | only if `docker.socket: true` | not available; `doctor` errors if enabled |

Config lookup order: `/agentic-config`, then `/work/.agentic`, then `AGENTIC_CONFIG_B64`.

### 6.2 Start steps

`entrypoint.sh` runs `/opt/agentic/start.d/NN-*.sh` in order. Every step supports `--check`
(report only, used by `doctor`) and is idempotent.

| Step | Does |
|---|---|
| `05-workspace` | If `/work` is empty: clone `AGENTIC_REPO_URL`, else fail with a clear message. Clone missing `repos:` into `/workspaces`. |
| `10-validate` | Find the config (§6.1) and validate it. Exit non-zero on error. |
| `20-onboarding` | Seed harness onboarding and trust for `/work` and `/workspaces/*`. |
| `30-git` | `user.name` and `user.email`, credential helper for `git.host` from `GH_TOKEN` or `GIT_TOKEN`, `GH_HOST`, `GIT_COMMITTER_*`. |
| `40-mcp` | Reconcile managed MCP servers for both harnesses: remove disabled ones, add or update enabled ones, expand `${VAR}`. Servers added by hand are left alone. |
| `50-plugins` | Link `~/.claude/plugins` (and Copilot's) to the baked plugins. Warn about configured plugins not in the image. |
| `60-skills` | Copy base skills and `.agentic/skills/*` into both harnesses' skill folders. |
| `70-graphify` | `graphify install` for both harnesses (hooks and skill). No graph build. |
| `80-display` | For `playwright.mode: headed`: use `$DISPLAY` or `$WAYLAND_DISPLAY`, else start Xvfb on `:99`. |
| `90-project-hook` | Run `hooks/on-start.sh` as `dev`. A failure warns, unless `on_start_required`. |

Then the entry mode (§6.4): `exec "$@"` by default. Output: one summary line per step in `~/.agentic-start.log`; `AGENTIC_DEBUG=1`
prints everything.

`docker exec` skips the entrypoint, so `dev-shell` re-applies step `30-git` and the env exports
before attaching tmux.

### 6.3 Harness auth

| Harness | Mode | Source |
|---|---|---|
| Claude | Subscription | `/login` via `agentic login claude`, stored in the harness home |
| Claude | API key | `ANTHROPIC_API_KEY` |
| Claude | Bedrock | `CLAUDE_CODE_USE_BEDROCK=1` plus AWS credentials |
| Copilot | Device login | `/login` via `agentic login copilot` |
| Copilot | Token | `COPILOT_GITHUB_TOKEN` or `GH_TOKEN`, plus `GH_HOST` for Enterprise |

### 6.4 Downstream layer contract and worker mode

An overlay image builds `FROM agentic-dev-base` and extends it only through these paths. The
base reads them; nothing in the base has to change.

| Path | Purpose |
|---|---|
| `/opt/agentic/start.d/NN-*.sh` | Extra start steps, ordered by number with the base steps. Same `--check` contract. |
| `/opt/agentic/tools/<name>.sh` | Extra tool presets, same `install`/`env` contract; `agentic build` and the schema accept any preset present in the image. |
| `/opt/agentic/skills/<name>/` | Extra skills, copied by `60-skills` like the base skills. |
| `/opt/agentic/defaults/agentic.yaml` | Org defaults, merged under the project's `agentic.yaml` (project wins). |
| `/opt/agentic/worker.d/<name>.sh` | Worker-mode adapters. |

**Entry modes.** After the start steps:

- `AGENTIC_WORKER_MODE` unset: `exec "$@"` (CLI mode: shell, dev, task).
- `AGENTIC_WORKER_MODE=<name>`: `exec /opt/agentic/worker.d/<name>.sh "$@"`. A missing adapter
  fails with a clear message. The adapter gets the configured container (tools, certs, MCPs,
  plugins, skills, git, and the gate once sub-project 2 exists) and starts whatever the hub needs.

The base guarantees for any adapter: bash, curl, tar, git and Node are present; the entrypoint
needs no mount and no TTY; start steps never block on input; the harness homes can be relocated
by env (`CLAUDE_CONFIG_DIR`, `COPILOT_HOME`), and the start steps follow them. A hub may launch
the harness with its own MCP configuration; whether it honours the container's MCP servers and
plugins is the adapter's and the hub's concern.

## 7. Setup skill `/agentic-setup`

- **Entry:** `agentic setup` runs the harness interactively in a throwaway container with a TTY
  (`claude "/agentic-setup"` or `copilot -i "/agentic-setup"`); or the user invokes the skill
  inside `agentic dev`. The user talks to it in the terminal as in any session; it asks one
  question at a time and uses multiple-choice menus where options are clear.
- **Reads:** `agentic.yaml`, the `init` detection report, build and CI files, Dockerfiles,
  README, existing agent instruction files.
- **Finds gaps** it can see (a JDK not configured, a compose file for tests while the socket is
  off, Jira keys in commits without Atlassian URLs) and proposes each fix with its reason.
- **Asks** for what it cannot see: tools used day to day, deploy targets, Atlassian URLs. It
  never guesses company hosts. For an empty repo it asks for the stack directly.
- **Handles specific needs** through the extension ladder (§5.3), choosing the lowest rung.
- **Writes** only inside `.agentic/`; secrets only as names in `.env.example`. Validates the
  result. Never touches `CLAUDE.md` or `.claude/`, never commits, never reads `.env`.
- **Ends** with a summary of changes, whether a rebuild is needed, and the next host commands
  (`agentic build`, `agentic doctor`).

## 8. Testing

These tests prove `agentic-dev-base` itself. A developer checks their configured setup with
`agentic doctor`. Testing the project's code is the agent's job in sub-project 2.

| Layer | Covers | Command |
|---|---|---|
| Unit (bats) | each start step in check and apply mode against temporary homes; `render-dockerfile.sh` against golden files; `render-toolchains.sh`; `detect.sh` against fixture repos (maven-8, gradle-17, terraform, node, empty); schema valid and invalid cases, including secret literals; `bin/agentic` argument parsing and the docker commands it builds (docker stubbed) | `make test` |
| Lint | shellcheck over `bin/`, `image/`, `derive/`, `tools/`; schema is valid JSON Schema; leak check | `make lint` |
| Smoke | build base, a fixture overlay (one extra start step, preset, skill and a fake worker adapter) and a derived image from a fixture `.agentic/` (Java 8 and 17, Terraform, an apt package, a `Dockerfile.extra` line, a self-made test CA); inside, under a pseudo-terminal: base tools run, extra JDKs and toolchains and `use-java` work, the test CA is trusted by curl, Java, Node, Python and Chromium, MCPs match the config, plugins linked, skills present, `on-start` ran; the overlay's step, preset and skill are applied; `AGENTIC_WORKER_MODE=fake` hands over to the adapter with the config applied; a run with no mounts (env only, local bare repo) comes up; `doctor` passes on a good setup and fails on a broken one | `make smoke` |
| Manual | `tests/e2e/README.md`: `init` on a real repo, both harnesses and auth modes, the `setup` dialogue, `dev` attach and re-attach, headed Playwright on WSLg | by hand |

Tests are written before the code. Every change needs `make test` and `make lint` green; a
change under `image/` also needs `make smoke`.

## 9. Leak check

- `tools/leak-check.sh` runs `git grep` over tracked and untracked-not-ignored files against a
  denylist of company names, domains, hosts and URLs.
- The denylist lives outside the repository: `~/.config/agentic/leak-denylist.txt` or
  `$AGENTIC_LEAK_DENYLIST`. A missing denylist fails the check.
- It also rejects `*.crt`, `*.pem`, `*.key` outside `tests/fixtures/`, and any `.env` other than
  `.env.example`.
- Part of `make lint`; an optional pre-commit hook runs the same script.

## 10. Documentation

- `README.md`: purpose, quick start, extension ladder.
- `docs/configuration.md`: every `agentic.yaml` field, generated from the schema descriptions.
- `docs/architecture.md`: the umbrella design.
- `docs/overlay.md`: how to build an overlay, with the contract from §6.4.
- `CLAUDE.md`: principles, commands, the no-company-resources rule, for working on this repo.
- No licence file until publication; the licence is decided then.

## 11. Out of scope

- Tasks, worktrees, `run/answer/stop/resume`, action gate, notify, task records, kickoff and
  report templates, `/design`, graph building → sub-project 2.
- Any hub-specific worker adapter → sub-project 3, in the overlay.
- Own API server, UI protocol, scheduler, remote orchestrator: not built (see
  `docs/architecture.md`). Sub-project 1 only guarantees that the image starts without mounts
  (§6.1) and can hand over to a worker adapter (§6.4).
- Migrating any existing project-specific toolbox onto the base.
