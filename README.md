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
