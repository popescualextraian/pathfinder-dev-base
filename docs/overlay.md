# Building an overlay

An overlay is an image built `FROM agentic-dev-base` that adds an organisation's pieces:
presets, default config, skills, start steps, worker adapters. It lives in its own repository
and never patches base files. Projects use it with `base_image:` in `agentic.yaml`.

## Contract

| Path in the image | Purpose |
|---|---|
| `/opt/agentic/start.d/NN-*.sh` | Extra start steps, run in number order with the base steps. Exit 0 ok, 1 fatal, 2 warning; support `--check`; export variables with `env_export` from `/opt/agentic/lib/common.sh`. |
| `/opt/agentic/tools/<name>.sh` | Extra tool presets: `install VERSION`, `env VERSION`, `check VERSION`. Projects use them as `tools.<name>: "<version>"`. |
| `/opt/agentic/skills/<name>/` | Extra skills, copied into both harnesses at start. |
| `/opt/agentic/defaults/agentic.yaml` | Organisation defaults, merged under each project's `agentic.yaml` (the project wins; lists are replaced). |
| `/opt/agentic/worker.d/<name>.sh` | Worker-mode adapters, started with `AGENTIC_WORKER_MODE=<name>`. |

The base guarantees for an adapter: bash, curl, tar, git and Node are present; the entrypoint
needs no mount and no TTY; start steps never wait for input; `CLAUDE_CONFIG_DIR` and
`COPILOT_HOME` relocate the harness homes and the start steps follow them.

## Example

```dockerfile
FROM agentic-dev-base:local
COPY defaults/agentic.yaml /opt/agentic/defaults/agentic.yaml
COPY tools/ /opt/agentic/tools/
COPY skills/ /opt/agentic/skills/
COPY --chmod=755 start.d/ /opt/agentic/start.d/
COPY --chmod=755 worker.d/ /opt/agentic/worker.d/
```

A worker adapter receives the configured container and the container's arguments:

```bash
#!/usr/bin/env bash
# /opt/agentic/worker.d/example.sh — started instead of the CLI command.
set -euo pipefail
exec my-worker --config "$HOME/.agentic/config.json" "$@"
```
