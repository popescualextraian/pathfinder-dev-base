# Backlog

Items we chose not to do yet. Each names where it was decided.

## Tasks and bridge

- **Several tasks in one container** – `run --in ID` on a container that already runs a task, with
  the bridge managing several sessions. For now a container runs one task at a time.
  (source: `docs/specs/2026-10-14-run-thin-relay-design.md` §11)
- **Tasks in the dev container** – `run --in dev` runs a task in the dev container. It needs the dev
  container created with the bridge port and the `/tasks` and `/events` mounts, and the question of
  security flags settled: tasks use `--cap-drop ALL` and `no-new-privileges`, dev has neither
  because of sudo. (source: `docs/specs/2026-10-14-run-thin-relay-design.md` §11)
- **Worktree by default** – `run --worktree` is opt-in; it may become the default.
  (source: `docs/specs/2026-10-14-run-thin-relay-design.md` §11)
- **Session API** – `POST /sessions` with the task definition as its body, replacing the
  task-definition env vars once a container runs several tasks at once; and a JSON schema for that
  definition that every launcher can validate against. Until then env is the bridge's contract.
  (source: `docs/specs/2026-10-15-schedule-design.md` S11, §12)
- **Several conversations per task** – more than one agent session in a task, and a `switch`
  between them. (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §17)
- **Outbound mode** – with `AGENTIC_RELAY_URL` the bridge dials a relay over WSS instead of
  listening. It is designed and the routes are transport-neutral, but the relay is not built.
  (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §12, §17)
- **Prompt queueing** – a prompt sent while one is outstanding is refused, not queued.
  (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §17)
- **Queue at the running cap** – at `AGENTIC_MAX_RUNNING`, `run` and starting a task refuse; there
  is no queue that starts them later. (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §12)
- **More events** – thoughts, usage, available commands, config options, session titles and the
  history replayed by `session/load` are not emitted. (source:
  `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §17, `docs/tasks.md` Events)
- **Takeover hand-back** – after `takeover` the task cannot be handed back to the bridge.
  (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §15, §17)
- **Automatic resume** – a task that crashed shows `interrupted` and waits for `resume`, so nothing
  spends tokens unobserved. (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md`
  D10, §17)
- **Resume after a removed container** – a task whose container was removed cannot be resumed by
  the CLI; its files are kept and `clean` still works. (source: `docs/tasks.md` States)
- **Desktop toasts and `agentic watch`** – notify covers the project events log and a webhook
  only. (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §10, §17)
- **Web UI and database** – the task state stays in files; there is no UI. (source:
  `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §17)
- **One data root** – task files live in `~/agentic-workspaces/<p>/tasks/<id>/` (mounted at
  `/tasks`) and the host's private task files in `~/.agentic/projects/<p>/tasks/<id>/` (never
  mounted). The split that matters is mounted versus never mounted, not the top folder:
  `~/.agentic/projects/<p>/harness` is already mounted. Since the host no longer clones,
  `~/agentic-workspaces` holds only `tasks/` and `events/`. Move both under
  `~/.agentic/projects/<p>/` as `tasks/<id>/` (mounted) and `private/<id>/` (never mounted), drop
  `AGENTIC_WORKSPACES`, and decide how existing tasks move or age out. (source: discussion
  2026-10-15)
- **Blocking questions through the harness's own ask tool** – an addition to `agentic-ask`, not a
  replacement. The bridge advertises ACP form elicitation, so `claude-agent-acp` forwards Claude's
  `AskUserQuestion` (several questions, options, multi-select) as an elicitation; each question
  becomes a normal question (Q1, Q2…) and `answer` resolves the elicitation. `ask-guard` stops
  blocking `AskUserQuestion`. Open points: a timeout that ends the wait with "no answer yet, use
  agentic-ask" so a turn is not held for hours; what happens to an open elicitation on a restart
  or suspend; whether `copilot --acp` forwards `ask_user`. `agentic-ask` stays for non-blocking
  questions and for Copilot. (source: discussion 2026-10-15)

## Setup and configuration

- **`agentic secret set NAME`** – prompts without echo and writes `.env`. Docker file secrets
  (`/run/secrets`) with it. (source: `docs/specs/2026-10-14-revamp-design.md` §14)
- **Marketplace browsing** – `copilot plugin marketplace browse` exists; Claude would need a
  reader. (source: `docs/specs/2026-10-14-revamp-design.md` §14)
- **`tools:` and `docker.socket` as setup commands** – both stay config fields that need
  `agentic build`. (source: `docs/specs/2026-10-14-revamp-design.md` §14)
- **Other harnesses behind `--target`** – only Claude and Copilot for now. (source:
  `docs/specs/2026-10-14-revamp-design.md` §14)

## Images

- **`agentic build --push` and registry publishing** – the base image is built locally; pushing to
  a registry comes later. (source: `docs/specs/2026-10-14-revamp-design.md` §14,
  `docs/architecture.md` Decisions)

## Remote

- **Schedules shared by a team** – `schedules:` in `agentic.yaml`, which needs one runner for the
  team instead of one crontab per developer; local scheduling is per user
  (`docs/scheduled-runs.md`). (source: `docs/specs/2026-10-14-revamp-design.md` §14, R11,
  `docs/specs/2026-10-15-schedule-design.md` §12)
- **Scheduling extras** – catch-up of firings missed while the host was off, systemd timers and
  launchd as triggers, result retention, chained or conditional schedules. (source:
  `docs/specs/2026-10-15-schedule-design.md` §12)
- **Several users on one remote host** – per-user containers and volumes, naming, and who may
  attach to whose container. R13 fixes only the principle: one container per user. (source:
  `docs/specs/2026-10-14-revamp-design.md` §14, `docs/remote.md` One user per container)

## Wiki

- **Lessons-learned skill** – a separate skill that writes lessons from a task into the component's
  "Pitfalls" section. (source: `docs/specs/2026-10-12-wiki-skill-design.md` W9, §11)
- **Diagrams** – diagrams and an architecture view bound to the components. (source:
  `docs/specs/2026-10-12-wiki-skill-design.md` §11)
- **Periodic `update`** – scheduling `/wiki update`; the runtime calls the same mode later.
  (source: `docs/specs/2026-10-12-wiki-skill-design.md` §11)
- **`agentic-wiki check` in a project's CI** – running the check outside the container. (source:
  `docs/specs/2026-10-12-wiki-skill-design.md` §11)
- **Migrating an existing wiki** – a project wiki that has its own tooling. (source:
  `docs/specs/2026-10-12-wiki-skill-design.md` §11)
- **Full CLAUDE.md mirror for Copilot** – today only the index block reaches
  `copilot-instructions.md`; a full mirror helps Copilot surfaces that do not read CLAUDE.md.
  (source: `docs/specs/2026-10-12-wiki-skill-design.md` §12)

## Outside this repository

These are decided as not part of the base; an overlay, a project or a hub provides them.

- **Hub adapters** – any hub-specific worker adapter lives in an overlay. (source:
  `docs/specs/2026-10-07-sub-project-1-base-image-design.md` §11,
  `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` §17)
- **Workflows** – pipelines, reviews, reports and `/design` belong to overlays and projects.
  (source: `docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md` D11)
- **Central server, scheduler, remote orchestrator** – not built here; a hub provides them.
  (source: `docs/specs/2026-10-07-sub-project-1-base-image-design.md` §11, `docs/architecture.md` Sub-projects)
- **Migrating existing toolboxes** – moving a project-specific toolbox onto the base. (source:
  `docs/specs/2026-10-07-sub-project-1-base-image-design.md` §11)
