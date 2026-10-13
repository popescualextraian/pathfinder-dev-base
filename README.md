# agentic-dev-base

A container toolbox for agentic development. One base image with the tools agents need (git,
Claude Code, Copilot CLI, AWS and Azure CLI, gh, Java 21 and Maven, Node 22, Python 3.12, Docker
CLI, Playwright with Chromium) and recommended extras (Atlassian, Playwright and Graphify MCP
servers, the Superpowers plugin, the `/agentic-setup` and `/wiki` skills). Each project adds its
own layer from `.agentic/agentic.yaml`.

Built for my own daily use first, and shared so anyone can use it: no company-specific pieces,
MIT licensed.

## Direction

The project is heading towards **pathfinder-dev-base**: a generic, company-neutral toolbox for
running coding agents in containers. It provides a base image, configuration skills, built-in
core skills, agent scheduling, ACP support, automatic task execution and more. Agent
scheduling, ACP and automatic task execution are planned, not yet available.

Why it is built this way: seventeen pillars, such as "one container with every tool" and "steer
the agent, don't write code". See the [philosophy](docs/philosophy.md).

## Prerequisites

bash, git and Docker. Clone this repository once and put `bin/agentic` on your PATH.

Behind a TLS-intercepting proxy, put your CA certificate into `~/.agentic/ca/` before the first
build (the base image needs it to download anything), and into the project's `.agentic/certs/`
so Java, Node, Python and Chromium trust it too. The files in `~/.agentic/ca/` must be named
`*.crt` and hold PEM content; others are ignored. `AGENTIC_BUILD_CA_DIR` points the build at
another directory.

## Usage

1. **Install.** Clone this repository, put `bin/agentic` on your PATH. Optionally run
   `make test lint smoke` to check that everything is green.
2. **Init.** `cd` into your project, `agentic init` → `.agentic/` with the detected tools;
   `.agentic/detect-report.md` names the build files it read. Commit `.agentic/`.
3. **Build.** `agentic build` → the base image (first time ~15 min), then
   `agentic-<project>:local`.
4. **Log in** once per project, with either harness and in either mode:
   - `agentic login claude` → `/login` in the browser flow, `/exit`; later containers need no
     login. Or put `ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN`) in `.agentic/.env`.
   - `agentic login copilot` → device code, `/exit`. Or put `COPILOT_GITHUB_TOKEN` in
     `.agentic/.env`.
5. **Refine (optional).** `agentic setup` → the `/agentic-setup` skill reviews and improves
   `.agentic/` for your project.
6. **Work.**
   - `agentic dev` → a persistent container with a tmux session in `/work`; run `claude` or
     `copilot`. Detach with `Ctrl-b d`; `agentic dev` again re-attaches. `agentic dev stop`,
     `recreate` and `status` manage it.
   - `agentic shell [CMD...]` → a throwaway container, removed on exit.
   More in [Dev mode](#dev-mode).
7. **Check.** `agentic doctor` → start steps, tools, logins, MCP servers and certificates, each
   with `ok` or what is wrong (for example `ok claude`).

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

`agentic dev status` reports when the image was rebuilt, and `agentic dev recreate` starts a
fresh container from it. Parallel agents that change code each need their own git worktree. Full
guide: [`docs/dev-mode.md`](docs/dev-mode.md).

## Project wiki

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

Repositories (`AGENTIC_REPO_URL`, `repos:`) clone over https with `GIT_TOKEN` or `GH_TOKEN` from
`.agentic/.env`. Never put a token in the URL itself (`https://user:token@...`): URLs end up in
configs and logs. `git@host:` and `ssh://git@host/` URLs are rewritten to https, because no SSH
keys are mounted.

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
