# Setup lines

A setup line is an `agentic` command without the `agentic` prefix, kept in `setup:` of
`agentic.yaml`. In the container, change the list only with
`agentic-setup-edit --dir /work/.agentic add 'LINE'` and
`agentic-setup-edit --dir /work/.agentic remove KIND KEY [--target T]`. On the host the user types
the same line with the prefix (`agentic add plugin ...`), which also rebuilds. Full guide:
`docs/setup.md` in agentic-dev-base.

`--target claude|copilot|claude,copilot` is optional where the table says so; without it the line
goes to `targets:` (both harnesses by default).

| Command | Phase | --target | What it does |
|---|---|---|---|
| `add marketplace SOURCE` | build | yes | adds a plugin marketplace (`owner/repo`, a git URL or a path in the image) |
| `add plugin NAME@MARKETPLACE` | build | yes | installs a plugin; a harness's default marketplace is added when missing |
| `add mcp NAME [--env KEY]... [--env KEY=VALUE]... -- COMMAND [ARGS...]` | build | yes | adds a stdio MCP server; `--env KEY` is written as `${KEY}` and filled from `.env` at run time |
| `add mcp NAME --transport http\|sse URL` | build | yes | adds a remote MCP server |
| `add skill PATH` | build | yes | `.agentic/skills/<name>/`; a line only when it narrows the target |
| `add agent PATH` | build | yes | `.agentic/agents/<name>.md`; a line only when it narrows the target |
| `add command PATH` | build | yes | `.agentic/commands/<name>.md` (Claude only); a line only when it narrows the target |
| `copy SRC DEST` | build | no | copies `.agentic/SRC` into the image at `DEST`; never for secrets |
| `add workspace URL\|PATH [--name N] [--ref R]` | start | no | a URL is cloned once into `/workspaces/repos/<name>` (in a workspace folder: `/work/<name>`); a path is a bind mount (local only) |
| `mount SRC DEST [--readonly]` | run | no | bind-mounts a host path (`~` is the host home); local only; tasks receive mounts too |
| `volume NAME DEST` | run | no | a Docker named volume (caches such as `~/.m2`), local and remote |

Examples:

```
add plugin superpowers@claude-plugins-official --target claude
add marketplace obra/superpowers-marketplace --target copilot
add plugin superpowers@superpowers-marketplace --target copilot
add mcp jira --env JIRA_PERSONAL_TOKEN --env JIRA_URL=https://jira.example.com -- mcp-atlassian
add mcp docs --transport http https://mcp.example.com/mcp
add agent agents/db-expert.md --target claude
copy files/settings.xml /home/dev/.m2/settings.xml
copy files/corp-root.crt /usr/local/share/ca-certificates/corp-root.crt
add workspace https://github.com/example/api.git
mount ~/.gitconfig /home/dev/.gitconfig --readonly
volume m2 /home/dev/.m2
```

- A literal `--env` value under a name with TOKEN, PASSWORD or SECRET is refused: write `--env KEY`
  and put the value in `.env` with `agentic-env`.
- A certificate copied under `/usr/local/share/ca-certificates/` is trusted by the system, Java,
  Node, Python and Chromium after `agentic build`.
- An MCP server the image lacks needs its install first, in `.agentic/Dockerfile.extra`
  (for example `RUN uv tool install mcp-atlassian`).
