# Running remotely

The same image runs on your laptop, on a VM and on a managed container service (AWS ECS, Azure
Container Apps and similar). This page is the contract a launcher has to meet. Platform launchers
and hub adapters are not part of this repository; an [overlay](overlay.md) holds them.

## The container contract

- **Image.** `agentic build` makes `agentic-<project>:local`. Push it with plain Docker:
  `docker tag agentic-<project>:local registry.example.com/team/<project>:1` and
  `docker push registry.example.com/team/<project>:1`. Everything the `setup:` build lines
  installed is in the image, so a fresh container needs no network to have it.
- **Environment.** What `.agentic/.env` holds locally, the platform injects from its secret store
  (AWS Secrets Manager, Azure Key Vault). `AGENTIC_REPO_URL` (and `AGENTIC_REPO_REF`) clone the
  project into an empty `/work`; `AGENTIC_CONFIG_B64` passes an `agentic.yaml` when the repository
  has none.
- **State.** The container keeps state only in these paths:

  | Path | Holds |
  |---|---|
  | `/work` | the project checkout |
  | `/workspaces` | other clones (`add workspace` lines) |
  | `/home/dev/.claude`, `/home/dev/.copilot` | logins, sessions, history, harness memory |
  | `/task` | a detached task's record (`AGENTIC_TASK_DIR`; `agentic run` uses `/tasks/<id>`) |

  Whatever is not on a mount or volume is gone after a recreate. One volume with a subpath per
  path is enough (Docker `volume-subpath`, an EFS access point, an Azure Files share).
- **Command.** `sleep infinity` for a dev box you attach to (`docker exec -it ... dev-shell`),
  `agentic-bridge` for a detached task, or a worker adapter with `AGENTIC_WORKER_MODE=<name>`.

## Which state a remote container needs

- **A remote dev box** you attach to over days needs the volume: without it a redeploy loses the
  checkout, the logins and the sessions.
- **A remote task or scheduled job** (clone, work, push, report) needs no volume. Its results
  leave through git and the task record.

## Mounts and the files they bring in

`mount` lines name paths on your machine, so they do not apply remotely; `agentic doctor` lists
them as skipped. Their remote equivalents are native too:

- **AWS:** the container's IAM role (task role on ECS) gives the AWS CLI and SDKs credentials
  without `~/.aws`.
- **Git:** `GIT_AUTHOR_*`, `GIT_COMMITTER_*` and `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n` in the
  environment replace `~/.gitconfig` (see `.env.example`).
- **Caches:** `volume` lines become volumes on the platform.

## A VM with Docker

The simplest remote: put this repository and your project on the VM, and use the CLI there over
SSH. `agentic dev`, `agentic run` and the bind mounts behave exactly as on a laptop, and the
container keeps running while you are disconnected.

Pointing your laptop's CLI at the VM's Docker (`DOCKER_HOST=ssh://vm`) does not work: the bind
mounts would name paths of your laptop that do not exist on the VM.

## One user per container

A container belongs to one user. Logins, tokens, sessions and harness memory are personal: a
shared container would act as one person (commits, pushes, gate decisions) and leak history
between people. Two developers on one project get two containers, two harness homes and two
`.env` files; they share through git: the repository, `.agentic/` and the wiki. Several users on
one remote host (naming, volumes per user, who may attach to which container) is planned.
