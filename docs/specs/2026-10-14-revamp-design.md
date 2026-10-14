# Revamp: a container with extension points

Status: draft for review, 2026-10-14. Umbrella: `docs/architecture.md`. Changes sub-project 1
(config, build, start steps); keeps sub-project 2 (tasks, bridge, gate) as it is.

## 1. Outcome

agentic-dev-base is a Docker image with preinstalled components, extended by the user in the
standard Docker way, plus a small set of convenience commands to work with it. We own the agentic
part: the harnesses, dev mode, detached tasks, the setup and support skills, and the build and start
flow. We do not own the technologies a project uses: git hosts, cloud accounts, issue trackers, MCP
servers. For those, the user gets generic extension points, and the code that configured each one
goes away.

The extension points:

- **`.env`** for secrets and every setting a tool reads from its own environment variables (kept as
  today).
- **`setup:`** in `agentic.yaml`: a list of our own commands, in the same grammar the user types in
  the shell. `agentic add plugin X` runs and also appends `add plugin X` to the list; the build
  replays the list.
- **Asset folders** in `.agentic/` (`skills/`, `agents/`, `commands/`, `instructions.md`), copied
  into each harness.
- **`Dockerfile.extra`** and overlays: plain Docker, for everything else.

Success criteria:

- A new technology (a git host, a cloud CLI, an MCP server, a plugin) never needs a schema field, a
  start step or a doctor check. The user writes a `.env` line, a `setup` line or a Dockerfile line.
- Every `setup` command is one line, works in the shell and in the file, and covers Claude and
  Copilot through `--target`.
- The recommended plugins are ordinary `setup` lines that the user can delete.
- What survives a container recreate is exactly the table in section 7, locally and on a remote VM.
- The schema, the start steps and the host CLI get smaller (counted in the PR description).
- `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| R1 | The container is disposable; the image holds what is declared; mounts hold only work, identity and history. | The standard Docker split. Declared things are rebuilt identically; nothing drifts. |
| R2 | `setup:` is a list of our own commands, not a schema of objects. The shell command and the file line are the same text. | One grammar to learn. The file is a readable, replayable record. Harness differences stay inside the commands. |
| R3 | Each command has a fixed phase: build, start or run. | Build is cached and offline at start; start is where state lives; run is where Docker takes mounts and env. |
| R4 | Build-phase commands write into a seed home in the image; a start step merges the seed into the mounted harness home (3-way JSON merge, linked plugin directories). | Baked results work offline and remotely, and the user's own settings in the mounted home survive. |
| R5 | No secret reaches the build. MCP env values are written as `${VAR}` references; the harness expands them at run time. | An image can be pushed and shared; anything in it is readable. |
| R6 | Assets are folders, not `setup` lines. A line exists only to narrow an asset's target. | Installing a skill is a file copy. The file stays short. |
| R7 | `add plugin` adds a harness's default marketplace when it is missing. | A fresh, non-interactive Claude home has only `anthropic-plugin-directory`; `claude-plugins-official` appears only on the first interactive start. The user should not need to know that. |
| R8 | The recommended set is a file of `setup` lines (`/opt/agentic/defaults/recommended`), written into the project by `agentic init`; `--bare` skips it. An overlay may replace the file. | Recommended, not hard-wired: deleting a line drops it. |
| R9 | Removed: `git.*`, `certs`, `plugins.*`, `mcp.*`, `skills`, `hooks.on_build`, `harness.*.model` and their start steps; `lib/host/aws.sh`; `mcp-atlassian` and Graphify in the base image. | Each one is a technology we maintained. The user's equivalent is in section 9. |
| R10 | Kept unchanged: `tools:` presets, `docker.socket`, `hooks.on_start`, `harness.default`, the overlay contract, dev mode, tasks, the bridge and the gate. | Not part of this problem. |
| R11 | Remote in scope: a VM with Docker running the CLI is tested; a managed container service is documented as a contract and tested with scheduling. | A VM needs almost no change; a managed service needs a cloud account but no change to the design. |
| R12 | Editing `agentic.yaml` runs in a throwaway container from the base image (`agentic-setup-edit`); the same script runs inside the container for the setup skill. | The host needs only bash, git and Docker (no yq). One implementation for shell, skill and CLI. |

## 3. `agentic.yaml` version 2

```yaml
# .agentic/agentic.yaml: the project's container, checked in. Secrets go in .agentic/.env only.
version: 2
project: shop-backend
base_image: agentic-dev-base:local
targets: [claude, copilot]            # default --target of every setup command

tools:                                # unchanged from version 1
  java: {versions: [17, 21], default: 21}
  maven: "3.9.9"
  apt: []
  extra_dockerfile: .agentic/Dockerfile.extra

harness:
  default: claude                     # agent of `agentic run` without --agent

hooks:
  on_start: .agentic/hooks/on-start.sh
  on_start_required: false

docker:
  socket: false

# Replayed in order. Typing `agentic <line>` in the shell runs it and appends it here;
# `agentic remove ...` deletes it.
setup:
  # recommended (agentic init; delete a line to drop it)
  - add plugin superpowers@claude-plugins-official --target claude
  - add marketplace obra/superpowers-marketplace --target copilot
  - add plugin superpowers@superpowers-marketplace --target copilot
  - add mcp playwright -- mcp-server-playwright --headless
  # project
  - add marketplace example-org/agent-plugins
  - add plugin review-kit@agent-plugins
  - add mcp jira --target claude --env JIRA_PERSONAL_TOKEN --env JIRA_URL=https://jira.example.com -- mcp-atlassian
  - copy files/settings.xml /home/dev/.m2/settings.xml
  - copy files/corp-root.crt /usr/local/share/ca-certificates/corp-root.crt
  - add agent agents/db-expert.md --target claude
  - add workspace https://github.com/example/api.git
  - mount ~/.gitconfig /home/dev/.gitconfig --readonly
  - volume m2 /home/dev/.m2
```

Rules:

- `version: 1` files are refused with a pointer to `agentic init --migrate` (section 10).
- `targets` lists `claude`, `copilot` or both; the default is both.
- The overlay's `/opt/agentic/defaults/agentic.yaml` is merged under the project's as today (lists
  are replaced). It must not contain `setup:`; an overlay contributes lines through its
  `recommended` file instead, so every line is visible in, and removable from, the project's file.
- `.agentic/` layout after `agentic init`:

```
.agentic/
├── agentic.yaml
├── .env, .env.example
├── Dockerfile.extra        # optional
├── files/                  # sources of `copy` lines
├── skills/<name>/SKILL.md  # assets, Claude's layout
├── agents/<name>.md
├── commands/<name>.md
├── instructions.md
└── hooks/on-start.sh
```

## 4. The `setup` grammar

A line is an `agentic` command without the `agentic` prefix. Arguments follow shell quoting. Every
command accepts `--target claude|copilot|claude,copilot` where it is marked; without it the
command uses `targets`.

| Command | Phase | Target | Does |
|---|---|---|---|
| `add marketplace SOURCE` | build | yes | `claude plugin marketplace add SOURCE` / `copilot plugin marketplace add SOURCE` |
| `add plugin NAME@MARKETPLACE` | build | yes | adds the harness's default marketplace if missing (R7), then `claude plugin install -s user` / `copilot plugin install` |
| `add mcp NAME [--env KEY]... [--env KEY=VALUE]... [--transport http\|sse URL \| -- CMD ARGS...]` | build | yes | `claude mcp add -s user` / `copilot mcp add`. `--env KEY` writes `KEY=${KEY}`; `KEY=VALUE` writes a literal (not for secrets) |
| `copy SRC DEST` | build | no | `COPY --chown=dev SRC DEST`; `SRC` is relative to `.agentic/`; `DEST` absolute |
| `add skill\|agent\|command PATH` | build | yes | copies `PATH` into the asset folder; writes a line only when `--target` narrows `targets` |
| `add workspace URL\|PATH [--name N] [--ref R]` | start | no | URL: cloned at start into `/workspaces/repos/<name>` if missing. PATH: bind mount there (local only) |
| `mount SRC DEST [--readonly]` | run | no | `-v SRC:DEST[:ro]`; `~` is the host home, a relative `SRC` is relative to the project root; local only |
| `volume NAME DEST` | run | no | `-v agentic-<project>-NAME:DEST`, a Docker named volume |

Shell-only commands (never written to the file):

- `agentic remove <kind> <key>` deletes the matching line. Keys: plugin id, marketplace source, mcp
  name, copy `DEST`, asset path, workspace name, mount `DEST`, volume name. Removing a workspace
  leaves its clone and prints where it is. Removing a volume leaves the Docker volume
  (`docker volume rm` deletes it).
- `agentic list` prints the `setup` lines with their phase.
- Every adding or removing command then runs `agentic build`, unless `--no-build` is given. If a dev
  container of the project is running, it asks before `agentic dev recreate`, because a recreate
  ends the tmux sessions; `--yes` answers yes.

Behaviour of the commands:

- **Idempotent.** A line that is already in the file is not added twice. Applying a line twice
  leaves the same result.
- **Validated before writing.** An unknown command, a missing `SRC`, a non-absolute `DEST`, an
  unknown target or a `copy` of a file that looks like a secret (`.env`, `id_*`, `*.pem`, `*.key`,
  `credentials`) is refused, and the file is not changed. `--force` allows the secret-looking
  `copy` after the user confirms the file holds no secret.
- **`copy` makes the source local.** `agentic copy ~/x/settings.xml /home/dev/.m2/settings.xml`
  copies the file (or folder) to `.agentic/files/settings.xml` and records
  `copy files/settings.xml /home/dev/.m2/settings.xml`. A name clash in `files/` is refused.
- **Certificates.** When any `copy` has a `DEST` under `/usr/local/share/ca-certificates/`, the
  build runs `update-ca-certificates`, `agentic-trust-java` and `agentic-trust-nss` once after the
  last `copy`. This replaces `certs:`.
- **Commands for Copilot.** Copilot CLI documents no user-level slash commands. Unless the plan's
  first check finds an equivalent, `add command` with the `copilot` target, explicit or from
  `targets`, warns and installs for Claude only.

## 5. Build flow

`agentic build` renders `Dockerfile.derived` (as today, from a throwaway container) in this order:

```
FROM <base_image>
user remap, tools presets, apt, Dockerfile.extra                  (unchanged)
COPY .agentic/{skills,agents,commands,instructions.md} → /opt/agentic/project/
for each build-phase setup line, in order:
   copy SRC DEST                → COPY --chown=dev SRC DEST
   add marketplace|plugin|mcp   → RUN agentic-apply '<line>'      (as dev, one RUN per line)
certificate refresh, if any copy targeted the CA folder
RUN agentic-inventory
LABEL ... agentic.setup.hash=<hash of the start- and run-phase lines>
```

- `agentic-apply` maps a line to the native commands for each target. It runs with
  `CLAUDE_CONFIG_DIR=/opt/agentic/seed/claude` and `COPILOT_HOME=/opt/agentic/seed/copilot`, so
  every result lands in the seed home. It is the only code that knows the harness CLIs.
- One `RUN` per line keeps Docker's layer cache: appending a line rebuilds from that line on.
- `--refresh` (today's `--refresh-plugins`) busts the cache of the setup layers, to pull newer
  plugin and marketplace versions.
- The build context is `.agentic/` without `.env` (it is in `.dockerignore`, as today).
- A failing line fails the build with the line number and the line.
- The base image no longer bakes plugins. Its own `/opt/agentic/defaults/recommended` holds the
  recommended lines (R8).

## 6. Start flow

Start steps after the revamp (`--check` supported, exit codes as today):

| Step | Does |
|---|---|
| `05-workspace` | Clones `AGENTIC_REPO_URL` into an empty `/work` (unchanged), then every `add workspace URL` line that has no clone yet. Never pulls, resets or deletes. A failed clone warns. |
| `06-task-home` | Unchanged. |
| `10-validate` | Validates version 2; refuses version 1 with the migrate hint. |
| `20-onboarding` | Unchanged. |
| `25-harness` | Only the Claude token fix (an `sk-ant-oat` value under `ANTHROPIC_API_KEY`). Models move to `.env` (`ANTHROPIC_MODEL`, Copilot's `COPILOT_MODEL`). |
| `40-seed` | Merges `/opt/agentic/seed/<harness>` into the harness home (below). |
| `45-hooks` | Unchanged (gate, tasks only). |
| `60-assets` | Copies base skills (`/opt/agentic/skills`), overlay skills and `/opt/agentic/project/*` into each target (below). |
| `90-project-hook` | Unchanged. |

Removed: `30-git`, `40-mcp`, `50-plugins`, `60-skills`, `70-graphify`, `80-display`.

### 6.1 Seed merge (`40-seed`)

For each harness, the seed home is walked once, and each entry is treated by kind:

- **Plugin directories** (Claude `plugins/`; Copilot `installed-plugins/` and its marketplace
  cache) are symlinked from the home into the seed, as Claude's `plugins/` is today. They are
  read-only to the user: a plugin installed by hand inside the container lasts until the next
  recreate, and `agentic doctor` names it with the line to keep it.
- **JSON files** (`.claude.json`, `settings.json`, Copilot's `config.json`, `settings.json`,
  `mcp-config.json`) get a 3-way merge of the previous seed, the new seed and the home. Objects are
  merged key by key, recursively; arrays and scalars are single values. For every path in the
  previous or the new seed:
  - in the new seed: the home gets the new seed's value;
  - only in the previous seed, and the home still has the previous seed's value: removed from the
    home;
  - only in the previous seed, and the user changed it: left alone.

  Paths only the home has are the user's and are never touched. The previous seed is kept as
  `<home>/.agentic-seed/<file>`. An unreadable JSON file in the home is reported and left alone,
  and the step exits 2.
- **Locks, logs and backups** of the harnesses are skipped.
- With no mounted home (a remote job), the step merges into the image's empty home.

### 6.2 Assets (`60-assets`)

| Asset | Claude | Copilot |
|---|---|---|
| `skills/<name>/` | `~/.claude/skills/<name>/` | `~/.copilot/skills/<name>/` |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` | `~/.copilot/agents/<name>.agent.md` |
| `commands/<name>.md` | `~/.claude/commands/<name>.md` | not supported (warning) |
| `instructions.md` | marked block in `~/.claude/CLAUDE.md` | marked block in `~/.copilot/copilot-instructions.md` |

- Precedence on a name clash: project over overlay over base, as today.
- An asset narrowed by an `add skill|agent|command --target` line goes only to that target.
- Assets this step installed and the project no longer has are removed (the step keeps the list of
  what it installed); assets the user put in the home by hand are left alone.
- The Copilot column is the expected layout. The plan's first task verifies it against the Copilot
  CLI in the image (user-level `skills/`, `agents/*.agent.md`, a user instructions file, slash
  commands) and corrects this table before anything is built on it.
- Agent files are copied unchanged. The same check verifies that Copilot loads a Claude-style agent
  file; if it does not, the Copilot target refuses agents with a clear message rather than
  translating.
- The instructions block uses markers, so the user's own text in those files is kept, as the gate
  paragraph does today.

## 7. State, recreate and remote

**Rebuild** makes a new image from the file; a running container does not notice. **Recreate**
replaces the container; only mounts survive.

| | Survives recreate | Where |
|---|---|---|
| Checkout and clones (`/work`, `/workspaces`) | yes | mount |
| Harness logins | yes | mount (or a token in `.env`) |
| Sessions, history, harness memory | yes | mount |
| Task records | yes | host only |
| Settings the user changed by hand in the harness | yes | mount, kept by the 3-way merge |
| Plugins, marketplaces, MCP, assets, copied files, tools | rebuilt | image |
| Anything installed by hand, files outside the mounts | no | — |
| Build caches | only with a `volume` line | named volume |

### 7.1 The container contract

The container keeps state only in `/work`, `/workspaces`, `/home/dev/.claude`, `/home/dev/.copilot`
and, for a task, `/task`. Whoever starts the container decides what survives by mounting those
paths:

- **Local (the CLI):** bind mounts, as today, plus `mount` and `volume` lines.
- **Remote dev box:** one volume on those paths (subpaths of one volume are enough).
- **Remote task or scheduled job:** no volume needed; results leave through git and the task record.

### 7.2 Remote

- **VM with Docker (tested):** the same CLI on the VM, used over SSH, behaves as local. Running the
  laptop's CLI against `DOCKER_HOST=ssh://vm` is not supported: bind mounts would name paths on the
  VM. The docs say so.
- **Managed container service (documented):** push the image built by `agentic build` with plain
  `docker tag` and `docker push`; inject `.env`'s variables from the platform's secret store; attach
  a volume for a dev box; run `sleep infinity`, `agentic-bridge` or a worker adapter. `mount` lines
  do not apply: on AWS the container's role gives the AWS CLI its credentials natively, and git
  settings come from `GIT_CONFIG_*` in the env. `agentic doctor` lists the skipped lines.
- Platform launchers and hub adapters stay in an overlay, never here.

## 8. Host CLI

New: `add`, `copy`, `mount`, `volume`, `remove`, `list` (section 4). Changed:

- `init` writes version 2 with the recommended lines; `--bare` writes none; `--migrate` converts a
  version 1 file (section 10).
- `build` renders the setup lines; `--refresh-plugins` becomes `--refresh`.
- `dev`, `shell`, `login`, `setup`, `doctor` and `run` add the `mount` and `volume` lines to their
  `docker run` arguments, and `add workspace PATH` lines as bind mounts. Task containers get
  `volume` lines but not `mount` lines (the task threat model in `docs/tasks.md` does not let a
  task reach host paths beyond its clones).
- `doctor` adds: seed merged, assets current, workspaces cloned, `${VAR}` references set, skipped
  `mount` lines (remote), plugins installed by hand.
- Removed: the AWS profile extraction (`AWS_PROFILE` in `.env` plus `mount ~/.aws` replaces it). The
  host git identity is still passed when `.env` has none (generic, no config).

## 9. What replaces the removed parts

| Removed | The user writes instead |
|---|---|
| `git.user_name/user_email` | `GIT_AUTHOR_*`, `GIT_COMMITTER_*` in `.env`, or `mount ~/.gitconfig` |
| `git.host` (`GH_HOST`) | `GH_HOST` in `.env` |
| `certs:` | `copy files/x.crt /usr/local/share/ca-certificates/x.crt` |
| `plugins.*` | `add marketplace`, `add plugin` |
| `mcp.atlassian` | `Dockerfile.extra`: `RUN uv tool install mcp-atlassian`; then `add mcp` |
| `mcp.playwright` | `add mcp playwright -- mcp-server-playwright --headless` (in recommended) |
| `mcp.playwright.mode: headed` | `Xvfb` from the on-start hook and `DISPLAY` in `.env` (example in the docs) |
| `mcp.graphify` | `Dockerfile.extra` plus `add mcp`, or a plugin |
| `mcp.custom` | `add mcp` |
| `skills:` path | the `.agentic/skills/` folder |
| `hooks.on_build` | `Dockerfile.extra`, or `setup` lines |
| `harness.*.model` | `ANTHROPIC_MODEL`, `COPILOT_MODEL` in `.env` |
| AWS profile extraction | `AWS_PROFILE` in `.env` and `mount ~/.aws /home/dev/.aws --readonly` |

The base image keeps the harnesses, Playwright with Chromium, the cloud and git CLIs, Docker CLI,
and the tool presets. It drops `mcp-atlassian` and Graphify.

## 10. Migration

`agentic init --migrate` rewrites a version 1 file in place, keeping comments where yq can, and
prints what it could not convert:

- `git.user_*` → `.env` lines through `agentic-env add` (never a value it does not have);
  `git.host` → `GH_HOST`.
- `certs` → each `*.crt` moved to `files/` with a `copy` line.
- `plugins.*`, `mcp.playwright`, `mcp.custom` → `setup` lines.
- `mcp.atlassian`, `mcp.graphify` → printed as manual steps (they need `Dockerfile.extra`).
- `.agentic/skills/` stays where it is.
- `hooks.on_build` → printed: move it into `Dockerfile.extra`.
- `harness.*.model` → `.env` lines.

The converter ships with this revamp and is removed one release later.

## 11. Setup skill

`/agentic-setup` keeps its role (refine `.agentic/` from the workspace, judgement on top of
`agentic init`) and changes its means:

- It proposes `setup` lines and applies them with `agentic-setup-edit` (no build: it runs inside
  the container; it tells the user to run `agentic build` on the host).
- It looks at the workspace for assets to adopt: existing `.claude/skills`, `.claude/agents`,
  `.github/agents`, MCP configs (`.mcp.json`), and offers `add` lines for them.
- It guides `.env` with `agentic-env` (unchanged), including the git and cloud settings that used to
  be schema fields.
- Its reference moves from the schema fields to the grammar in section 4, shipped as
  `skills/agentic-setup/reference/setup-lines.md`.

## 12. Error handling

| Situation | Behaviour |
|---|---|
| Invalid line when typed | refused, file unchanged, the reason printed |
| Invalid line in the file | `10-validate` and the build fail with the line number |
| A build-phase line fails (network, unknown plugin) | the build fails, naming the line |
| A workspace clone fails at start | warning (exit 2); the container starts |
| Seed merge meets unreadable JSON in the home | warning; that file is left alone |
| `${VAR}` of an MCP server is unset | warning at start and in `doctor`, as today |
| `mount` source missing on the host | the CLI refuses to start the container, naming the line |
| Remote start with `mount` lines | skipped, listed by `doctor` |

## 13. Testing

- **bats, written first,** for every behaviour: the line parser and validator, add/remove/list and
  idempotency, `copy` localising and the secret refusal, the Dockerfile rendering per command,
  `agentic-apply` per target (harness CLIs stubbed), the 3-way merge (table-driven, every case of
  6.1), assets per target and their removal, the workspace step, run arguments for `mount` and
  `volume`, the migration of each version 1 field.
- **Smoke** builds a project with: a local fixture marketplace (`tests/fixtures/marketplace`, so no
  network), a plugin from it for both targets, an MCP server with an env reference, a `copy`, a
  certificate, an agent narrowed to Claude, a volume. It checks the result in both harness homes,
  then removes a plugin, rebuilds, recreates and checks it is gone while a hand-added MCP server
  stays.
- **Manual, recorded in the PR:** a remote VM run (`agentic dev` over SSH; recreate keeps the
  clone, the login and a session).

## 14. Delivery

One spec, implemented in stages that each leave `main` green:

1. Grammar, validator and `agentic-setup-edit`; schema version 2; `add`/`remove`/`list` on the file.
2. Build phase: rendering, `agentic-apply`, the seed home, recommended file; base image stops baking
   plugins.
3. Start phase: `40-seed`, `60-assets`, `05-workspace`; old steps removed.
4. Run phase: `mount`, `volume`, workspace paths; AWS extraction and git config removed.
5. Migration, `init --bare/--migrate`, setup skill, docs (`configuration.md` generated from the
   grammar, `architecture.md`, `overlay.md`, a remote page), leak check, smoke.

## 15. Out of scope and backlog

- Scheduling (`schedules:`), tested together with a managed container service.
- `agentic secret set NAME` (prompts without echo, writes `.env`) and Docker file secrets
  (`/run/secrets`).
- Marketplace browsing (`copilot plugin marketplace browse` exists; Claude would need a reader).
- `agentic build --push`.
- Making `tools:` and `docker.socket` setup commands.
- Other harnesses behind `--target`.
