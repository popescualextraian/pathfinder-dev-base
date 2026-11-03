# Task stacks: each task gets its own copy of the project's services

Status: designed, 2026-10-30. Umbrella: `docs/architecture.md`. Extends tasks (`docs/tasks.md`), dev mode
(`docs/dev-mode.md`) and the project network ("Services" in `docs/setup.md`). The launcher side lives in
pathfinder-dev-ui; section 8 is the contract it implements.

## 1. Outcome

A project lists compose files in `agentic.yaml`. Every task gets its own copy of the services in them
(database, cache, broker, mocks): its own containers, volumes and network, started with the task and removed
with it. The agent reaches them by service name (`db:5432`). The dev container gets one long-lived copy.
No container of the stack, and no agent container, gets the Docker socket.

Success criteria:

- `stack:` validates against the schema; `agentic build` writes the resolved, uninterpolated stack as the
  label `agentic.stack`, and refuses a stack that breaks the rules (section 5).
- `agentic run` starts the task's stack before the agent container and joins the container to its network;
  `stop`, `resume`, `clean`, `--auto-clean` and scheduled runs stop, start and remove it with the container.
- Two tasks of one project run side by side with separate databases.
- `agentic dev` starts the dev copy and joins the dev container to it.
- A project without `stack:` behaves exactly as today.
- `make test`, `make lint` and `make smoke` pass; smoke runs a task whose stack has a small service.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| S-1 | **The stack is plain compose files, listed in `stack:` in `agentic.yaml`.** No services syntax of our own. | Any project's needs fit; teams already have compose files; nothing to learn. |
| S-2 | **The stack is baked into the image at build** as the label `agentic.stack`: the listed files as written, `[{file, content}]` in base64, after the build checked the rules on compose's merged model (`docker compose config --format json --env-file /dev/null`). | Compose's uninterpolated export misparses short volume syntax, so the files themselves travel and compose resolves them at run. | Also: agents can edit the checkout, so the stack must not be read from it at run time; a change takes effect only after the user's `agentic build`. A launcher reads it from the image, like `agentic.apps`. No value from `.env` reaches the label. |
| S-3 | **One stack per container**, compose project `<project>-<creator task id>` (lowercased). `--in` tasks share the stack of the container they run in. | The stack follows the container's life, which `run`, `stop` and `clean` already manage. |
| S-4 | **The agent container is not in the stack.** It is created as today and then connected to the stack's network `<stack project>_default`. | Agentic keeps owning the agent container (mounts, labels, tokens, caps, bridge port); the stack stays any compose file. |
| S-5 | **Rules, not an image list** (section 5): what a service may do is checked, not which image it runs. Checked at build and again at run, after interpolation. | Generic for every project, and it closes the way to the host that a compose file opens. |
| S-6 | **Interpolation at run from `.agentic/.env`** (`--env-file`), the way compose reads it natively. | Passwords of local services live where the other settings live. |
| S-7 | **The host runs `docker compose`** from the label, written to a host-private file per stack. | Starting containers is the host CLI's job (thin relay); the file is never one the agent can write. |

## 3. Config

```yaml
# agentic.yaml
stack:
  - .agentic/compose.stack.yaml   # inside .agentic/, the build context (like tools.extra_dockerfile)
  - .agentic/compose.mocks.yaml
```

The files are merged in order, as `docker compose -f a -f b` merges them. A path outside `.agentic/`, a
missing file or a stack that breaks the rules fails the build, naming the file.

## 4. Lifecycle

`S` is the stack project (`shop-t-17`), `F` the frozen file `$AGENTIC_DATA/projects/<p>/tasks/<creator>/stack.json`.

| Moment | What the host does |
|---|---|
| `run` (new container) | write the label's files under `F`'s directory and `F` as their merged, interpolated model (`config --format json --env-file .agentic/.env`); check the rules after interpolation; `docker compose -p S -f F --env-file .agentic/.env up -d --wait`; create the agent container as today; `docker network connect S_default <container>`. A failure rolls back the stack too. |
| `run --in ID` | `up -d --wait` on the creator's stack if it is not running. |
| `stop` | after the container stops: `docker compose -p S stop`. |
| `resume`, any verb that starts the container | `up -d --wait` before the container starts. |
| `clean`, auto-clean, the sweep | with the container: `docker compose -p S down -v`, then remove `F`. |
| `agentic dev` | the same with `S = <project>-dev`; the stack stays up across `recreate`, and `down -v` is left to the user (`docker compose -p <project>-dev down -v`). |

The stack's containers carry compose's labels plus `agentic.project` and `agentic.stack=S`, so `status` and
`doctor` can find them. `agentic status ID` and `agentic dev status` list the host ports of the stack's services
(`db 5432 -> 127.0.0.1:49153`), read with `docker compose -p S port` on every call, because a start may change
them; `--json` carries them as `stack_ports`. The agent container stays on `agentic-<project>` as well.

## 5. Rules

A service is refused when it has any of:

- `privileged`, `cap_add`, `devices`, `device_cgroup_rules`, `security_opt` with `unconfined`;
- `network_mode`, `pid`, `ipc`, `uts`, `userns_mode` or `cgroup` other than the default;
- a volume of type `bind` (named volumes and `tmpfs` only), or anything naming `docker.sock`;
- `ports` other than a random loopback port (`127.0.0.1::5432`: host IP `127.0.0.1`, no host port), since
  fixed host ports would clash between tasks and other addresses expose the service beyond the machine;
- `container_name` (names would clash between tasks);
- `build` (images only in version 1), `env_file`, `configs` or `secrets` with `file:`;
- a network or volume declared `external`, a volume with `driver_opts` or a driver other than `local`, a
  network with a driver other than `bridge`; `volumes_from`; `cgroup_parent`;
- a top-level `config` or `secret` read from a `file`.

The same list is the policy a launcher enforces (section 8).

## 6. Changes in this repository

- `schema/agentic.schema.json`: `stack` (array of strings); `docs/configuration.md` regenerated.
- `derive/render-dockerfile.sh`: merge the files with `docker compose config --format json --env-file /dev/null`,
  check the rules (`image/lib/stack-rules.jq`), write the files as the label. **Done** (with the schema).
- `lib/host/stack.sh` (new): `stack_up`, `stack_stop`, `stack_down`, `stack_rules`; `bin/agentic`: the
  calls in section 4.
- `agentic doctor`: `docker compose version` when the image has a stack; lists running stacks.
- `agentic status ID`, `agentic dev status`: the stack's host ports (section 4).
- Setup skill and "Services" in `docs/setup.md`: `stack:` is the way for a database per task; the shared
  network stays for services every container uses.
- Tests first: bats for every row of sections 4 and 5 (docker stub logs the compose calls), the rule checker
  on fixtures, smoke with a one-service stack.

## 7. Not in version 1

`build:` in stack services, fixed host ports, sharing one stack between containers other
than through `--in`, a stack in a remote container service (the launcher runs the services there).

## 8. Launcher contract (pathfinder-dev-ui)

A launcher that starts task containers itself implements the same:

- Read `agentic.stack` from the task image. `ENGINE_COMPOSE_FILE` may override it per deployment.
- `launch`: start the stack as project `<project>-<task id>`, create the agent container as today on its own
  network, connect it to `<stack project>_default`. `start`/`stop` start and stop the stack with the
  container; `remove` runs `down -v`. The UI reaches the bridge on its own network, as today.
- The socket filter allows, for names with the task's stack prefix only: creating and removing a network
  and volumes, pulling images, and creating containers that pass section 5 (checked on the create body:
  `Privileged`, `CapAdd`, `Devices`, `Binds`, `Mounts` of type bind, `NetworkMode`, `PidMode`, `IpcMode`,
  `UsernsMode`, and `PortBindings` with `HostIp` `127.0.0.1` and an empty `HostPort`).
