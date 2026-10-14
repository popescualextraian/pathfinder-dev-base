# Setting up the container

How to extend the container for a project. The container is a Docker image with the agentic tools
preinstalled; everything a project adds comes through three extension points, and none of them
needs code in this repository:

| Extension point | Use it for | Example |
|---|---|---|
| `.agentic/.env` | secrets, and any setting a tool reads from its own environment variables | `GH_TOKEN=...`, `GIT_AUTHOR_NAME=...`, `ANTHROPIC_MODEL=...` |
| `setup:` lines in `.agentic/agentic.yaml` | plugins, marketplaces, MCP servers, skills and agents, files, mounts, volumes, extra repositories | `add plugin review-kit@agent-plugins` |
| plain Docker | everything else: system packages, other tools, an organisation image | `.agentic/Dockerfile.extra`, an [overlay](overlay.md) |

`.env` reaches every process in the container (`docker --env-file`), so git, gh, the AWS CLI, npm
and the harnesses pick their variables up without any configuration. `.agentic/.env.example`
lists the common ones.

## Setup lines

A setup line is an `agentic` command without the `agentic` prefix. You type it in the shell, and
the same text lands in `setup:`:

```
$ agentic add plugin review-kit@agent-plugins
```

```yaml
setup:
  - add plugin review-kit@agent-plugins
```

The shell command validates the line, writes it, runs `agentic build`, and offers to recreate a
running dev container. Editing `setup:` by hand works too; run `agentic build` afterwards. The file
is the truth: it is checked in, so the whole team gets the same container, and it is replayed in
order on every build.

### Commands

| Command | Phase | --target | What it does |
|---|---|---|---|
| `add marketplace SOURCE` | build | yes | adds a plugin marketplace: `owner/repo`, a git URL, or a path inside the image |
| `add plugin NAME@MARKETPLACE` | build | yes | installs a plugin; a harness's default marketplace (`claude-plugins-official`) is added first when it is missing |
| `add mcp NAME [--env KEY]... [--env KEY=VALUE]... -- COMMAND [ARGS...]` | build | yes | adds a stdio MCP server; `--env KEY` is written as `${KEY}` and filled from `.env` when the server starts |
| `add mcp NAME --transport http\|sse URL` | build | yes | adds a remote MCP server; it takes no `--env` |
| `add skill PATH` | build | yes | copies a skill folder into `.agentic/skills/` |
| `add agent PATH` | build | yes | copies an agent file into `.agentic/agents/` |
| `add command PATH` | build | yes | copies a slash command into `.agentic/commands/` (Claude only) |
| `copy SRC DEST` | build | no | copies a file or folder into the image at `DEST`; an outside `SRC` is first copied into `.agentic/files/` |
| `add workspace URL\|PATH [--name N] [--ref R]` | start | no | a URL is cloned once into `/workspaces/repos/<name>`; a path is bind-mounted there (local only) |
| `mount SRC DEST [--readonly]` | run | no | bind-mounts a host path; `~` is your home, a relative path is relative to the project root |
| `volume NAME DEST` | run | no | a Docker named volume, `agentic-<project>-NAME` |

Examples, shell form:

```bash
agentic add plugin superpowers@claude-plugins-official --target claude
agentic add marketplace obra/superpowers-marketplace --target copilot
agentic add plugin superpowers@superpowers-marketplace --target copilot
agentic add mcp jira --env JIRA_PERSONAL_TOKEN --env JIRA_URL=https://jira.example.com -- mcp-atlassian
agentic add mcp docs --transport http https://mcp.example.com/mcp
agentic add skill ~/my-skills/review
agentic add agent ./agents/db-expert.md --target claude
agentic copy ~/.m2/settings.xml /home/dev/.m2/settings.xml
agentic copy ./corp-root.crt /usr/local/share/ca-certificates/corp-root.crt
agentic add workspace https://github.com/example/api.git
agentic mount ~/.gitconfig /home/dev/.gitconfig --readonly
agentic volume m2 /home/dev/.m2
```

Rules the commands enforce:

- A line is stored literally: quotes group words, nothing is expanded (`~` stays `~`).
- The same command with the same key and targets is never added twice; adding it again with
  other arguments replaces the line in place.
- A literal `--env` value under a name containing TOKEN, PASSWORD or SECRET is refused: write
  `--env NAME` and put the value in `.env`.
- A `copy` of a file that looks like a secret (`.env`, `id_*`, `*.pem`, `*.key`, `credentials`)
  is done, with a warning: the file ends up in the image, readable by anyone who has the image,
  and stays in pushed layers after the line is removed.
- An MCP server needs its program in the image. The Playwright server is preinstalled; install
  others in `Dockerfile.extra` (for example `RUN uv tool install mcp-atlassian`).
- A certificate copied under `/usr/local/share/ca-certificates/` is copied before the tools are
  installed and is trusted by the system, Java, Node, Python and Chromium.

### Shell-only commands

| Shell command | What it does |
|---|---|
| `agentic remove KIND KEY [--target T]` | deletes the matching lines, then builds. Keys: the plugin id, the marketplace source, the MCP name, the copy `DEST`, the asset path, the workspace name, the mount `DEST`, the volume name |
| `agentic list` | prints every line with its phase |
| `--no-build` | on any add or remove: change the file only |
| `--yes` | recreate a running dev container without asking |
| `agentic build --refresh` | rebuild the setup lines without the cache, to pull newer plugins and marketplaces |

Removing a workspace never deletes its clone (it may hold unpushed work), and removing a volume
leaves the Docker volume; both commands say where they are.

## Targets

`targets:` in `agentic.yaml` (default `[claude, copilot]`) is where plugins, marketplaces, MCP
servers and assets go. `--target claude`, `--target copilot` or `--target claude,copilot` narrows
one line. Marketplaces differ between the harnesses, so one plugin often needs one line per
harness.

| Asset in `.agentic/` | Claude | Copilot |
|---|---|---|
| skills/NAME/ | `~/.claude/skills/NAME/` | `~/.copilot/skills/NAME/` |
| agents/NAME.md | `~/.claude/agents/NAME.md` | `~/.copilot/agents/NAME.agent.md` |
| commands/NAME.md | `~/.claude/commands/NAME.md` | not supported (warning) |
| instructions.md | a marked block in `~/.claude/CLAUDE.md` | a marked block in `~/.copilot/copilot-instructions.md` |

The asset folders are the truth: a file in `.agentic/skills/` is installed without any line. A
line such as `add agent agents/db-expert.md --target claude` exists only to narrow its target.
Assets the project drops are removed from the harness homes at the next start; what you put there
by hand stays.

## Phases

| Phase | When | Lines | Needs |
|---|---|---|---|
| build | `agentic build` | plugins, marketplaces, MCP servers, assets, `copy` | `agentic build`, then `agentic dev recreate` |
| start | every container start | workspaces | a restart |
| run | `docker run` | `mount`, `volume`, path workspaces | `agentic build` (they travel as an image label), then `agentic dev recreate` |

Build-phase lines run against a seed home in the image. At start, the container brings the seed
into your harness home: plugin folders are linked, and settings are merged so that what a line
added appears, what a removed line added disappears, and what you changed by hand stays. No secret
reaches the build: `.env` is not in the build context.

## copy, mount or volume?

| | copy | mount | volume |
|---|---|---|---|
| where the data lives | in the image | on your machine | in Docker, outside the image |
| works remotely | yes | no | yes |
| reaches detached tasks | yes | yes | yes |
| typical use | settings files, certificates | `~/.gitconfig`, `~/.aws`, files you edit on the host | build caches (`~/.m2`, `~/.npm`) |

Prefer `copy` for plain files and `.env` for secrets. A mount gives every container of the
project, unattended tasks included, whatever it brings in; mount cloud credentials only when you
accept that.

## What survives a recreate

`agentic dev recreate` (or a remote redeploy) replaces the container; only mounts survive.

| | Survives | Where |
|---|---|---|
| Your checkout and clones (`/work`, `/workspaces`) | yes | mount |
| Harness logins | yes | mount (or a token in `.env`) |
| Sessions, history, harness memory | yes | mount |
| Task records | yes | host only |
| Settings you changed by hand in the harness | yes | mount, kept by the merge |
| Plugins, marketplaces, MCP servers, assets, copied files, tools | rebuilt | image |
| Anything installed by hand, files outside the mounts | no | — |
| Build caches | only with a `volume` line | named volume |

## Recommended lines

`agentic init` writes the recommended lines into `setup:` under a `# recommended` comment:
Superpowers for both harnesses and the Playwright MCP server. Delete a line to drop it; nothing is
hard-wired in the image. `agentic init --bare` writes none. An overlay ships its own
`/opt/agentic/defaults/recommended`; `agentic init --base IMAGE` reads it from that image.

## Fields that became lines or variables

Older configs (version 1) are refused; run `agentic init` again and keep your `.env`.

| Version 1 field | Now |
|---|---|
| git user name and email | `GIT_AUTHOR_*`, `GIT_COMMITTER_*` in `.env`, or `mount ~/.gitconfig /home/dev/.gitconfig --readonly` |
| git host | `GH_HOST` in `.env` |
| certificate folder | `copy files/x.crt /usr/local/share/ca-certificates/x.crt` |
| plugin lists | `add marketplace`, `add plugin` |
| built-in MCP switches (Atlassian, Graphify, Playwright) | `add mcp`, with the program installed in `Dockerfile.extra` when the image lacks it |
| custom MCP servers | `add mcp` |
| skills folder setting | the `.agentic/skills/` folder |
| build hook | `Dockerfile.extra` |
| harness models | `ANTHROPIC_MODEL`, `COPILOT_MODEL` in `.env` |
| AWS profile copy | `AWS_PROFILE` in `.env` and `mount ~/.aws /home/dev/.aws --readonly` |

Every remaining field of `agentic.yaml`: [configuration.md](configuration.md). Running the
container elsewhere: [remote.md](remote.md).
