# Manual end-to-end runbook

Run on a real machine before tagging a release. Each step lists what you should see.

1. **Fresh clone.** Clone `agentic-dev-base`, put `bin/agentic` on PATH, `make test lint smoke`
   → all green.
2. **Init on a real repository.** `cd` into a real project, `agentic init` → `.agentic/` with
   the detected tools and the recommended setup lines; `detect-report.md` names the build files
   it read.
3. **Build.** `agentic build` → base image (first time), then `agentic-<project>:local`.
4. **Logins, both harnesses, both modes.**
   - `agentic login claude` → `/login` in the browser flow, `/exit`; a second `agentic shell
     claude` needs no login.
   - Remove the login, put `ANTHROPIC_API_KEY` in `.agentic/.env`; `agentic doctor` shows
     `ok claude`.
   - `agentic login copilot` → device code, `/exit`; then the token mode with
     `COPILOT_GITHUB_TOKEN`.
5. **Setup dialogue.** `agentic setup` → Claude starts in the skill, asks one question at a time,
   writes only `.agentic/`, runs `agentic-config validate`, ends with next steps.
6. **Dev mode.** `agentic dev` → tmux in `/work`; detach with `Ctrl-b d`; `agentic dev` again →
   same session. `agentic build` then `agentic dev status` → "outdated"; `agentic dev recreate`.
7. **Headed Playwright on WSLg.** `agentic add mcp playwright -- mcp-server-playwright --yes`
   (no `--headless`), `agentic dev --host-profile wsl`, ask Claude to open a page → a visible
   Chromium window.
8. **Corporate network.** With your CA in `~/.agentic/ca/` and
   `agentic copy ~/.agentic/ca/corp.crt /usr/local/share/ca-certificates/corp.crt`, the build and
   `agentic doctor` pass behind the proxy.
9. **MCP servers connect.** `agentic add mcp NAME --env VAR -- COMMAND` for a server that needs a
   token, with `VAR` in `.agentic/.env`. In `agentic shell claude`, `claude mcp list` → the
   server connected. In `agentic shell copilot`, `/mcp` → the same server connected. Neither
   `~/.claude.json` nor `~/.copilot/` contains the token's value.
10. **Harness models.** Set `ANTHROPIC_MODEL` and `COPILOT_MODEL` in `.agentic/.env`, restart
    the container → Claude's and Copilot's `/model` show them.
11. **Setup lines round trip.** `agentic add plugin superpowers@claude-plugins-official --target
    claude --yes` → `/plugin` lists it; `agentic remove plugin superpowers@claude-plugins-official
    --yes` → gone, while an MCP server you added by hand in the container stays.
