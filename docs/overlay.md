# Building an overlay

An overlay is an image built `FROM agentic-dev-base` that adds an organisation's pieces:
presets, default config, recommended setup lines, skills, start steps, worker adapters. It lives in its own repository
and never patches base files. Projects use it with `base_image:` in `agentic.yaml`.

## Contract

| Path in the image | Purpose |
|---|---|
| `/opt/agentic/start.d/NN-*.sh` | Extra start steps, run in number order with the base steps. Exit 0 ok, 1 fatal, 2 warning; support `--check`; export variables with `env_export` from `/opt/agentic/lib/common.sh`. |
| `/opt/agentic/tools/<name>.sh` | Extra tool presets: `install VERSION`, `env VERSION`, `check VERSION`. Projects use them as `tools.<name>: "<version>"`. |
| `/opt/agentic/skills/<name>/` | Extra skills, copied into both harnesses at start. |
| `/opt/agentic/defaults/agentic.yaml` | Organisation defaults, merged under each project's `agentic.yaml` (the project wins; lists are replaced). It cannot hold `setup:`. |
| `/opt/agentic/defaults/recommended` | Recommended setup lines, one per line (`docs/setup.md`), replacing the base's. `agentic init --base IMAGE` writes them into a project's `setup:`, where the project can see and delete them. |
| `/usr/local/share/ca-certificates/*.crt` | Organisation CA certificates; any `*.crt` under this folder is trusted by the system, Java, Node, Python and Chromium after `update-ca-certificates`, `agentic-trust-java` and `agentic-trust-nss`. |
| `/opt/agentic/worker.d/<name>.sh` | Worker-mode adapters, started with `AGENTIC_WORKER_MODE=<name>`. |

The base guarantees for an adapter: bash, curl, tar, git and Node are present; the entrypoint
needs no mount and no TTY; start steps never wait for input; `CLAUDE_CONFIG_DIR` and
`COPILOT_HOME` relocate the harness homes and the start steps follow them.

## Task hooks and the gate

- Hook scripts: `/opt/agentic/hooks.d/<event>/*.sh` (image, for an overlay) and
  `/agentic-config/hooks.d/<event>/*.sh` (project). Events: `sessionstart`, `userpromptsubmit`,
  `pretooluse`, `posttooluse`, `stop`, `sessionend`. The payload arrives on stdin; on `pretooluse`
  exit 2 refuses the tool call (stderr carries the reason).
- `AGENTIC_GATE` turns the hooks and the action gate on; the default is on for `agentic-bridge`
  and for worker mode, off otherwise.
- `AGENTIC_ALLOWED_ACTIONS` (comma-separated `push`, `open-pr`, `deploy:<target>`) sets the
  allowed actions for a worker that has no task record.
- `AGENTIC_NOTIFY_WEBHOOK` receives the bridge's notifications on `waiting`, `idle`, `failed`
  and `stopped`.
- A worker adapter may run `agentic-bridge` or drive the agent itself; the hooks and the gate
  apply either way. The API and the files are described in `docs/tasks.md`.

## Example

```dockerfile
FROM agentic-dev-base:local
COPY defaults/agentic.yaml /opt/agentic/defaults/agentic.yaml
COPY recommended /opt/agentic/defaults/recommended
COPY --chmod=755 tools/ /opt/agentic/tools/
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
