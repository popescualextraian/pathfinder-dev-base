# agentic-dev-base — architecture

A reusable container toolbox for agentic software development. A developer takes the base,
configures it for a project, and works with an AI coding agent: first attached (dev mode), then
detached (autonomous mode). The same image can also serve as the task container of an external
task hub, which then provides the UI, scheduling and remote runners.

This document is the umbrella design. Each sub-project has its own spec in `docs/specs/`.

## Goals

- **Adoption path.** A developer runs it locally in dev mode for a few sprints. Once they trust
  the results, they switch to autonomous mode: they write the spec, the agent implements, tests,
  opens a PR and reports. For a UI, team boards, schedules or remote runs, they connect an
  external task hub that starts this image as its task container.
- **The container is the product.** This repository builds the place where the work happens:
  tools, project tool layer, agent extras, guardrails, a local CLI flow. It does not build a
  platform (server, UI, scheduler, orchestrator); those come from a hub.
- **Generic.** No project, company or customer is built in. Everything project-specific comes
  from the project's `.agentic/` folder, a developer's `.env`, or a downstream overlay image.
- **One image, any host.** The same image runs on a laptop, a VM or a managed container
  service. Nothing may depend on the host beyond Docker and what the launcher passes in.

## Principles

- **Two human gates.** The human approves the spec (Gate 1) and reviews the final report
  (Gate 2). In between, the run goes on alone; the only stops are blocking requests.
- **The agent has everything it needs to prove its work.** If a task needs a tool to build,
  deploy or test, the tool belongs in the image (base or project layer).
- **The container is the sandbox.** Harnesses run with permissions bypassed. Outward-facing
  actions pass a shell-enforced action gate, in every mode, including when a hub drives the
  container.
- **Rules that must hold are enforced in shell, not prompts.**
- **Both harnesses.** Claude Code and Copilot CLI get the same tooling and the same flow.
- **Deterministic first.** A script decides where a script can; the LLM is used only for
  judgement.
- **Minimal.** State lives in files and container labels. No database and no central server: one small bridge per task container.
- **Publishable.** No company resources in this repository: no certificates, company names,
  hosts, URLs or product-specific integrations. Enforced by `tools/leak-check.sh` in
  `make lint`. Company-specific pieces live in a downstream overlay.

## Sub-projects

| # | Sub-project | Delivers | Unlocks |
|---|---|---|---|
| 1 | Base image and config | Base image, `agentic.yaml` with `setup:` lines, derived project image, tool presets, recommended setup lines, `/agentic-setup` skill, `agentic init/build/login/setup/shell/dev/doctor/add/remove/list`, downstream layer contract, worker-mode hook | Dev mode; overlays; hub task containers |
| 2 | Runtime and CLI | Detached tasks: one ACP bridge per task container (HTTP + WebSocket API), worktrees, questions with grants, the action gate behind AGENTIC_GATE, notify, `run/status/follow/send/answer/cancel/stop/resume/takeover/clean` | Autonomous mode, local and hub-less |
| 3 | Hub integration (in the overlay) | A worker-mode adapter that lets an external task hub start and drive this image; the gate active under the hub; blocking requests surfaced as the hub's needs-you signal | UI, team board, scheduling and remote runs, all provided by the hub |

Not built here: a central server, a UI, a scheduler or a remote orchestrator; a hub provides them. Each task container has a small bridge with a light API (`docs/tasks.md`), which a hub may use or replace with its own driver. For a hub-less setup, two documented recipes cover the simple cases:

- **Scheduled jobs:** a host `cron` entry that calls `agentic run` with a brief.
- **Remote:** the same CLI on a VM with Docker, or the image on a managed container service,
  started from env alone (sub-project 1 guarantees this).

## Layers

```
 project repo/.agentic/   →  agentic-<project>:local     (derived image: tools, setup lines, assets)
                               FROM
 overlay (internal)       →  agentic-dev-<org>:<tag>     (optional: org presets, defaults, hub adapter)
                               FROM
 this repository          →  agentic-dev-base:<tag>      (base image, CLI, runtime, schema)
```

- **Base:** everything generic. Published as-is when the time comes.
- **Overlay:** a separate, private repository per organisation. It builds `FROM` the base and
  adds only through the downstream layer contract (sub-project 1): extra start steps, presets,
  skills, default config, worker-mode adapters. It never patches base files.
- **Project:** `.agentic/` in each project repository; `agentic build` renders the derived image
  `FROM` the base or the overlay (`base_image:` in `agentic.yaml`).

Changes flow one way: generic work goes to the base first; the overlay pulls a newer tag. There is
never a second copy of a base file to keep in sync.

## Components

```
 host / VM                                     container (one per dev session or task)
 ─────────                                     ───────────────────────────────────────
 bin/agentic  ──docker run/exec──────────────▶ entrypoint (start.d steps)
                                                   ├─ CLI mode:    dev (tmux) or task: agentic-bridge (ACP)
 external hub ──starts container with env────▶     └─ worker mode: worker.d/<name>.sh (overlay)
                                                                       │
                                                  hooks → action gate, liveness, notify
                                                                       ▼
                                                  task files: state.json, events.jsonl, transcript.md (2)
```

- **Image (1).** Base image plus a derived image per project, rendered from `agentic.yaml`.
  Build-phase setup lines run against a seed home in the image (`/opt/agentic/seed`); the start
  step `40-seed` links its plugin folders into the mounted harness home and merges its settings
  (3-way: what a removed line added goes, what the user changed stays). Run-phase lines (`mount`,
  `volume`) travel as an image label that the CLI turns into `docker run -v` arguments.
- **State (1).** The container is disposable; state lives only in `/work`, `/workspaces`, the
  harness homes and `/task`, which the launcher mounts (`docs/remote.md`). One container belongs
  to one user.
- **CLI (1, 2).** `bin/agentic` on the host is the only thing a developer installs for hub-less
  use.
- **Entry modes (1).** By default the entrypoint applies config and runs the given command (CLI
  mode). With `AGENTIC_WORKER_MODE=<name>` it applies the same config and then hands over to
  `/opt/agentic/worker.d/<name>.sh`, which an overlay provides. The base ships no worker adapter.
- **Task files (2).** `state.json`, `events.jsonl` and `transcript.md` under the workspace are the source of truth for hub-less runs; only the bridge writes `state.json`.
- **Gate (2).** The PreToolUse hook is installed at user scope for both harnesses, so it applies
  whether the CLI or a hub launches the harness.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Scope | Container toolbox, not a platform | An existing task hub already provides UI, scheduling and remote runs |
| Repository | New repository; private now, publishable later | Generic from day one |
| Company-specific parts | Downstream overlay repository, `FROM` the base | One-way flow, nothing to sync |
| Agent driving | ACP: claude-agent-acp for Claude, copilot --acp for Copilot | Structured events, cancel, permissions and session load without terminal scraping |
| Hub compatibility | Worker-mode hook in the base; the adapter in the overlay | Base stays neutral; any hub can be added |
| Project config | `.agentic/` checked into the project repo; secrets in a git-ignored `.env` | Shared by the team like `.devcontainer/` |
| Project tools | Config file plus a derived image built by `agentic build` | Install once, reproducible |
| Setup help | `/agentic-setup` skill on top of deterministic `agentic init` | LLM only for judgement |
| Base image distribution | Built locally first; registry publishing later | Nothing to host |
| Java | Temurin 21 and Maven in the base; extra JDKs side by side per project, with generated Maven and Gradle toolchains | Old projects need old JDKs |
| Extension | `.env`, `setup:` lines in our own command grammar, plain Docker; no per-technology schema fields or start steps | The project owns its technologies; the shell command and the file line are the same text |
| Setup lines | Baked into a seed home at build, merged into the mounted harness home at start | Reproducible, offline-capable, and the user's own settings survive |
| Recommended plugins | Lines written by `agentic init`, deletable; nothing hard-wired | Recommended, not imposed |
| Users | One container per user | Logins, sessions and memory are personal |
| Mounts | Optional; the image also starts from env alone | Hubs and managed containers have no bind mounts |
| Docker socket | Off by default; opt-in per project | Guardrail: the socket is host root |
| Licence | Decided at publication | Private until then |
