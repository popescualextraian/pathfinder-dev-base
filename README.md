# agentic-dev-base

A container for agentic development. One base image with the tools agents need (git, Claude
Code, Copilot CLI, AWS and Azure CLI, gh, Java 21 and Maven, Node 22, Python 3.12, Docker CLI,
Playwright with Chromium) and the `/agentic-setup` and `/wiki` skills. Each project extends it in
the standard ways: `.env` for secrets and settings, one-line `setup:` commands for plugins,
marketplaces, MCP servers, skills, files and mounts, and plain Dockerfile lines for anything else.
The project owns its technologies; this repository owns the agentic part.

Built for my own daily use first, and shared so anyone can use it: no company-specific pieces,
MIT licensed.

## Direction

The project is heading towards **pathfinder-dev-base**: a generic, company-neutral toolbox for
running coding agents in containers. It provides a base image, configuration skills, built-in
core skills, agent scheduling, ACP support, automatic task execution and more. ACP and
automatic task execution are planned, not yet available; scheduling is described below.

Why it is built this way: seventeen pillars, such as "one container with every tool" and "steer
the agent, don't write code". See the [philosophy](docs/philosophy.md).

## Prerequisites

bash, git and Docker. Clone this repository once and put `bin/agentic` on your PATH.

Behind a TLS-intercepting proxy, put your CA certificate into `~/.agentic/ca/` before the first
build (the base image needs it to download anything), and copy it into the project image so
Java, Node, Python and Chromium trust it too:
`agentic copy ~/.agentic/ca/corp.crt /usr/local/share/ca-certificates/corp.crt`. The files in
`~/.agentic/ca/` must be named `*.crt` and hold PEM content; others are ignored.
`AGENTIC_BUILD_CA_DIR` points the build at another directory.

## Usage

1. **Install.** Clone this repository, put `bin/agentic` on your PATH. Optionally run
   `make test lint smoke` to check that everything is green.
2. **Init.** `cd` into your project, `agentic init` → `.agentic/` with the detected tools and the
   recommended setup lines (Superpowers, the Playwright MCP server; `--bare` for none);
   `.agentic/detect-report.md` names the build files it read. Review the `setup:` lines, then
   commit `.agentic/`.
3. **Build.** `agentic build` → the base image (first time ~15 min), then
   `agentic-<project>:local`.
4. **Log in** once per project, with either harness and in either mode:
   - `agentic login claude` → `/login` in the browser flow, `/exit`; later containers need no
     login. Or put `ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN`) in `.agentic/.env`.
   - `agentic login copilot` → device code, `/exit`. Or put `COPILOT_GITHUB_TOKEN` in
     `.agentic/.env`.
5. **Setup.** `agentic setup` → the `/agentic-setup` skill reviews your repository and proposes
   the setup lines.
6. **Work.**
   - `agentic dev` → a persistent container with a tmux session in `/work`; run `claude` or
     `copilot`. Detach with `Ctrl-b d`; `agentic dev` again re-attaches. `agentic dev stop`,
     `recreate` and `status` manage it.
   - `agentic shell [CMD...]` → a throwaway container, removed on exit.
   More in [Dev mode](#dev-mode).
7. **Check.** `agentic doctor` → start steps, tools, logins, MCP servers and setup lines, each
   with `ok` or what is wrong (for example `ok claude`).
8. **Extend.** `agentic add plugin ...`, `agentic add mcp ...`, `agentic copy ...`,
   `agentic mount ...`: one line each, see [docs/setup.md](docs/setup.md) and
   [Extending](#extending).

## The `.agentic/` folder

`agentic init` writes it into your project; commit it, except `.env`. Nothing rebuilds by itself:
after a change marked *build*, run `agentic build`, then `agentic dev recreate`.

| Path | Purpose | Takes effect |
|---|---|---|
| `agentic.yaml` | Project config: tools, Docker socket, hooks, and the `setup:` lines ([setup](docs/setup.md), [reference](docs/configuration.md)) | build |
| `.env` (git-ignored), `.env.example` | Secrets and settings tools read natively (`ANTHROPIC_API_KEY`, `GH_TOKEN`, `GIT_AUTHOR_NAME`, …); loaded at start, never in the image | next start |
| `files/` | Sources of `copy` lines (settings files, CA certificates) | build |
| `skills/`, `agents/`, `commands/`, `instructions.md` | Copied into Claude and Copilot (`targets:`) | build |
| `hooks/on-start.sh` | Runs as `dev` in `/work` at every start, with `.env`; a failure only warns unless `hooks.on_start_required` | next start |
| `Dockerfile.extra` (optional) | Extra Dockerfile lines, run as root, appended to the project image; build-time installs go here | build |
| `detect-report.md` | Which build files `init` read to detect your tools; for information only | — |

`agentic doctor` warns when `agentic.yaml` changed since the last build.

## Dev mode

`agentic dev` keeps one container per project running, with a tmux session in `/work`. Run
several agents side by side, one per tmux window, and leave them working while you are away.

| Keys | Action |
|---|---|
| `Ctrl-b c` | new window; type `claude` for another agent |
| `Ctrl-b w` | all windows, each titled with its agent's current task |
| `Ctrl-b 0`…`9`, `n`, `p`, `l` | go to a window, the next, the previous, the last used |
| `Ctrl-b d` | detach; `agentic dev` re-attaches to the same windows |
| `Ctrl-b [` | scroll, `q` to leave |

The running container keeps the image it started from. After `agentic build` (or a change to
`.env` or `on-start.sh`), `agentic dev recreate` removes the container, starts a fresh one from the
current image and attaches; `agentic dev status` tells you when that is due. Files in `/work`,
logins and Claude/Copilot history survive a recreate; running agents, tmux windows and anything
installed by hand inside the container do not. `claude --continue` brings a conversation back.

Parallel agents that change code each need their own git worktree. Full guide:
[`docs/dev-mode.md`](docs/dev-mode.md).

## Detached tasks

`agentic run` starts an unattended task in a container set up like the dev
container, with your checkout at `/work` (`--worktree` adds a worktree of its own); Claude Code or
Copilot works on it through a small bridge, asks you with `agentic-ask` when it needs a decision,
and suspends when idle. Push, pull requests and deploys are refused unless you allow them.
Follow, answer, cancel and stop it from the CLI or a small local API.

```bash
agentic run --worktree --allow open-pr "Fix the failing login test and open a pull request"
agentic follow T-20261012-a3f1
agentic answer T-20261012-a3f1 Q1 "Yes, use the staging config" --allow push
agentic send T-20261012-a3f1 "Also add a test for the logout path"
agentic status
agentic cost
agentic stop T-20261012-a3f1
agentic clean T-20261012-a3f1
```

The CLI only relays: each command goes to the bridge in the task container over HTTP or
WebSocket, and the bridge is the only process that speaks ACP to the agent. Each task's state
lives in `~/agentic-workspaces/<project>/tasks/<id>/`; `agentic status` lists the tasks from there.

```mermaid
%%{init: {"theme": "default", "themeVariables": {"edgeLabelBackground": "#ffffff"}, "flowchart": {"rankSpacing": 110, "nodeSpacing": 50}}}%%
flowchart LR
  subgraph host["Host"]
    cli["<b>agentic&nbsp;CLI</b><br/>run<br/>send<br/>resume<br/>answer<br/>cancel<br/>stop<br/>follow<br/>status"]
    state["<b>Task&nbsp;files</b><br/>~/agentic-workspaces/<br/>&lt;project&gt;/tasks/&lt;id&gt;/<br/>state.json<br/><i>read by agentic status</i>"]
  end
  subgraph task["Task container"]
    bridge["<b>Bridge&nbsp;·&nbsp;HTTP&nbsp;/&nbsp;WS</b><br/>GET&nbsp;/status<br/>GET&nbsp;/events<br/>POST&nbsp;/prompt<br/>POST&nbsp;/answer<br/>POST&nbsp;/cancel<br/>POST&nbsp;/stop<br/>POST&nbsp;/ask<br/>POST&nbsp;/gate"]
    agent["<b>Agent&nbsp;·&nbsp;ACP</b><br/>claude-agent-acp<br/>copilot&nbsp;--acp"]
    tools["<b>Agent's&nbsp;tools</b><br/>gate.sh<br/>agentic-ask"]
  end
  cli -- "HTTP / WS" --> bridge
  state <---|"← bridge writes<br/>(mounted at /tasks)"| bridge
  bridge -- "initialize<br/>session/new | load<br/>session/prompt<br/>session/cancel" --> agent
  agent -- "session/update<br/>request_permission" --> bridge
  agent --> tools
  tools -- "POST /ask<br/>POST /gate" --> bridge
  linkStyle default color:#1d2329
```

Full guide: [`docs/detached-mode.md`](docs/detached-mode.md). States, API, events, files and
environment: [`docs/tasks.md`](docs/tasks.md).

## Sessions

A task can hold several named conversations with its agent: one container, one checkout or
worktree, one branch, and as many sessions as the work needs. The first is `main`; every command
without `--session` uses it. Each session has its own context and, if you want, its own model,
and sessions can run at the same time. On Claude a session can start as a fork of another.
Questions, events, `follow` and the transcript say which session they come from.

```bash
agentic run --worktree "Plan the move of the auth module to the new API; write the plan to PLAN.md"
agentic session add T-20261012-a3f1 impl --model sonnet "Implement PLAN.md step by step"
agentic session add T-20261012-a3f1 review --fork main "Review the diff against the plan"
agentic session list T-20261012-a3f1
agentic follow T-20261012-a3f1 --session impl
agentic send T-20261012-a3f1 --session review "Also check the error handling"
```

This is a mechanism, not a workflow: roles such as plan, implement and review, and any handoff
between sessions, are yours to build with the CLI or the API. Sessions share the task's worktree,
so keep parallel sessions out of each other's files. Details: [`docs/tasks.md`](docs/tasks.md#sessions).

## Scheduled runs

`agentic schedule add` runs a detached task at a set time, once (`--at`) or on a cron schedule
(`--cron`): agentic colleagues that update dependencies at night or write a report every Monday.
Each run gets a fresh container and its own worktree, keeps the `--allow` grants you gave, and is
told that nobody is watching. At the end the agent writes a summary, the container is stopped and,
unless you pass `--keep`, removed with the task. Only the summary stays; unpushed work is never
deleted.

```bash
agentic schedule add nightly-deps --cron "0 2 * * 1-5" --allow open-pr \
  "Update the dependencies, run the tests and open a pull request"
agentic schedule run nightly-deps        # try it now
agentic schedule results nightly-deps    # the summary of the last run
agentic schedule follow nightly-deps     # watch a run in progress
agentic schedule list
agentic schedule remove nightly-deps
```

Locally your crontab fires the run, so the host needs cron and must be on at the time. Remotely
the platform's own scheduler starts the image with `AGENTIC_SCHEDULED=1`; the scheduled behaviour
lives in the bridge, so it is the same in both places. Guide:
[`docs/scheduled-runs.md`](docs/scheduled-runs.md).

## Project wiki (WIP)

> **Work in progress:** the wiki skill is not finished yet; commands and page layout may change.

`/wiki seed` writes what agents cannot read from the code into `docs/wiki/`: components and their
boundaries, decisions, contracts, concepts, flows and the shared code to reuse. It also writes a
lean CLAUDE.md that imports the wiki index, and path rules. `/wiki update` keeps the pages true
after a change. `agentic-wiki check` validates all of it. The skill decides where each statement
belongs: `skills/wiki/reference/routing.md`.

## Philosophy

The aim is more autonomy and speed with the same quality, reached through seventeen pillars:
the developer becomes architect and owner, one container with every tool, remote runs, agentic
colleagues on a schedule, spec-driven development, a strong plan, knowledge in Markdown, an
agent-maintained wiki, agents that test their own work, steering instead of coding, guardrails,
feedback loops, agent review, isolated parallel work, deterministic checks, context as code,
and measurement. See [`docs/philosophy.md`](docs/philosophy.md).

## Private repositories

Workspaces (`agentic add workspace URL`) clone with the git settings below. The repository
(`AGENTIC_REPO_URL`) clones over https with `GIT_TOKEN` or `GH_TOKEN` from
`.agentic/.env`. Never put a token in the URL itself (`https://user:token@...`): URLs end up in
configs and logs. For that clone, `git@host:` and `ssh://git@host/` URLs are rewritten to https,
because no SSH keys are mounted.

After that, git is configured the way git itself is: every variable in `.agentic/.env` reaches
every process in the container, and git reads its identity (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`)
and any setting (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`, `GIT_CONFIG_VALUE_n`) from the
environment. To push over https, give each host a username and a helper that names its token
variable; git expands it when it runs, so the token is stored once:

```
GITLAB_TOKEN=glpat-...
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=credential.https://gitlab.example.com.username
GIT_CONFIG_VALUE_0=oauth2
GIT_CONFIG_KEY_1=credential.https://gitlab.example.com.helper
GIT_CONFIG_VALUE_1=!f() { echo "password=$GITLAB_TOKEN"; }; f
```

The username is `oauth2` for GitLab and `x-access-token` for GitHub. A remote runner sets the
same variables. `.agentic/.env.example` has the template, and `/agentic-setup` writes and checks it.

## Extending

Three ways, all standard:

- **`.env`** for secrets and every setting a tool reads from its environment.
- **Setup lines** for plugins, marketplaces, MCP servers, skills, agents, files, mounts, volumes
  and extra repositories: [docs/setup.md](docs/setup.md).
- **Plain Docker** for everything else: `tools:` presets and `tools.apt` in `agentic.yaml`,
  `.agentic/Dockerfile.extra`, or an organisation-wide [overlay](docs/overlay.md) image.

Cost tracking is a recommended plugin: every session's token cost lands in one ledger per project,
and `agentic cost` sums it ([docs/cost.md](docs/cost.md)).

Running the container on a VM or a managed service: [docs/remote.md](docs/remote.md). Every
field: [docs/configuration.md](docs/configuration.md). Design:
[docs/architecture.md](docs/architecture.md).
