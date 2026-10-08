# Hooks

- `on-start.sh`: runs as `dev` in `/work` at every container start, with `.env` loaded.
  A failure warns, unless `hooks.on_start_required: true`.
- `on-build.sh`: runs as `dev` at the end of `agentic build`. It never sees `.env`; use it for
  user-level installs (`npm i -g`, `pipx install`).
