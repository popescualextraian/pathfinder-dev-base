# Manual end-to-end runbook

Run on a real machine before tagging a release. Each step lists what you should see.

1. **Fresh clone.** Clone `agentic-dev-base`, put `bin/agentic` on PATH, `make test lint smoke`
   → all green.
2. **Init on a real repository.** `cd` into a real project, `agentic init` → `.agentic/` with
   the detected tools; `detect-report.md` names the build files it read.
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
7. **Headed Playwright on WSLg.** Set `mcp.playwright.mode: headed`, `agentic dev recreate
   --host-profile wsl`, ask Claude to open a page → a visible Chromium window.
8. **Corporate network.** With your CA in `~/.agentic/ca/` and `.agentic/certs/`, the build and
   `agentic doctor` pass behind the proxy.
9. **MCP servers connect.** Enable `mcp.atlassian` and add an `mcp.custom` server whose header
   uses a `${VAR}` reference, with `VAR` in `.agentic/.env`. In `agentic shell claude`,
   `claude mcp list` → `playwright`, `graphify`, `atlassian` and the custom server all
   connected. In `agentic shell copilot`, `/mcp` → the same servers, Atlassian connected with
   its token. Neither `~/.claude.json` nor `~/.copilot/` contains the token's value.
10. **Harness models.** Set `harness.claude.model` and `harness.copilot.model`, restart the
    container → `echo $ANTHROPIC_MODEL` and Claude's `/model` show the Claude model;
    `~/.copilot/config.json` has `"model"` and Copilot's `/model` shows it. `agentic doctor`
    reports no model drift.
