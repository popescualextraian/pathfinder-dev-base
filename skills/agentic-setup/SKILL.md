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
