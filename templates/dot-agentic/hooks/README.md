# Hooks

- `on-start.sh`: runs as `dev` in `/work` at every container start, with `.env` loaded.
  A failure warns, unless `hooks.on_start_required: true`.

Build-time installs (`npm i -g`, `pipx install`, apt packages) go in `../Dockerfile.extra`, plain
Dockerfile lines run at the end of `agentic build`.
