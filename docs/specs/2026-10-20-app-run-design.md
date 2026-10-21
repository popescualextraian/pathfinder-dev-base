# Apps in a task: run, see and stop the project's app

Status: designed, 2026-10-20. Umbrella: `docs/architecture.md`. Extends tasks (`docs/tasks.md`) and the bridge
(`docs/specs/2026-10-12-sub-project-2-acp-bridge-design.md`). The launcher side lives in pathfinder-dev-ui
(`docs/superpowers/specs/2026-10-20-app-run-design.md` there). Ported from the agentic-dev-base test version, where it
runs in daily use.

## 1. Outcome

A project declares its apps in `agentic.yaml`. In a task, an app can be started, stopped, restarted and its logs
read; it runs inside the task's container in the task's checkout, so it shows exactly the task's changes. A
launcher learns the app ports from the image and publishes them, so the user opens the app in a browser.

Success criteria:

- `apps:` validates against the schema; `agentic build` writes the label `agentic.apps`.
- `agentic-app start|stop|restart|logs|list` works in a task container and reports each start, stop and exit to
  the bridge as an `app` event.
- The bridge serves `GET /apps`, `POST /apps/:name/start|stop|restart`, `GET /apps/:name/logs` (task token).
- `autostart` apps start with the task; `idle_stop` stops an app nobody used for that long; `teardown` runs on stop.
- No secret reaches a label, a log line or an event; `make test`, `make lint` and `make smoke` pass.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| A-1 | **Apps are config in `agentic.yaml`, baked into the image as the label `agentic.apps`** (JSON). | A launcher must know the ports before it creates the container. |
| A-2 | **Each app runs in its own tmux window** in the task container, in the task's checkout (`dir` relative to it). | Survives the agent's shell; logs are the window's scrollback; tmux is in the image. |
| A-3 | **The bridge controls apps** through new routes that run `agentic-app`; a launcher never runs commands in a container. | Fits "the launcher returns a URL, the bridge client does the rest"; works the same remotely. |
| A-4 | **`app` events in the existing stream** (`{name, action, exit_code}`, API version 1, additive). | Clients see starts, stops and crashes without polling. |
| A-5 | **Free-text values (`run`, `prepare`, `teardown`) are run only by `agentic-app` in the container**, never by the host CLI or a launcher. | The host stays a thin relay. |

## 3. Config

`apps:` is a map of name (`^[a-z][a-z0-9-]{0,30}$`) to:

| Key | Meaning |
|---|---|
| `run` | the command (required) |
| `ports` | container ports the app listens on (list of 1–65535; may be empty) |
| `url` | path to open, default `/` |
| `dir` | directory relative to the checkout, default the checkout |
| `env` | plain values (map); a key matching `TOKEN\|KEY\|SECRET\|PASSWORD` is refused: such values belong in `.env` |
| `env_files` | files copied into the checkout before the first start (`{from, to}`; `from` relative to `.agentic/`) |
| `prepare` | run once before the first start (e.g. `npm ci`) |
| `teardown` | run after stop |
| `autostart` | start when the task starts (bool, default false) |
| `idle_stop` | stop after this long without traffic on its ports (`30m`, `0` never; default `0`) |

The label `agentic.apps` holds `{name: {ports, url, autostart}}` only (no commands, no env).

## 4. In the container

`agentic-app list [--json]`, `start NAME`, `stop NAME`, `restart NAME`, `logs NAME [--lines N]`: refuses an unknown
name; `start` of a running app is a no-op; `prepare` failing stops the start with its last lines; the tmux window is
`app-<name>`; every change posts `{type: "app", data: {name, action: started|stopped|exited|failed, exit_code}}`
to the bridge with the task's own token. `idle_stop` is checked by a small loop the first start launches.

## 5. Bridge routes

| Route | Body | Result |
|---|---|---|
| `GET /apps` | | `[{name, state: running\|preparing\|stopped\|exited\|failed, ports, url, since, exit_code}]`; `since` in unix seconds or null |
| `POST /apps/:name/start` `/stop` `/restart` | | 202 with the app; 404 unknown; 409 when the task is stopped |
| `GET /apps/:name/logs?lines=N` | | `{lines: [...]}` (N ≤ 2000, default 200), control characters removed |

`autostart` apps are started once the task's checkout is ready.

The task does not suspend under a running or preparing app: when the idle timer runs out, the bridge asks
`agentic-app list` and, while an app is `running` or `preparing`, starts the timer again (a failing list suspends as
before). App actions restart the timer; `app` reports do not. `idle_stop` is how an unused app ends.

## 6. Testing

bats: schema and label; `agentic-app` with a stub tmux (start, stop, restart, logs, prepare failure, unknown name,
env_files, teardown, the event post); idle_stop with a short timeout. vitest: the bridge routes (states, 404, 409,
logs cap) and the `app` event. smoke: a task image with a tiny HTTP app; start it, read its logs, stop it.

## 7. Out of scope

Ports for the local launcher; VS Code attach; app preview inside the UI.
