# Revamp: measured harness facts

Measured on 2026-10-14 in `agentic-dev-base:local` (Claude Code 2.1.296, Copilot CLI 1.0.95), for
Task 1 of `docs/plans/2026-10-14-revamp.md`. Later tasks rely on these facts.

## Seed footprint

A fresh home (`CLAUDE_CONFIG_DIR`, `COPILOT_HOME`) after one no-op command (`mcp list`):

- Claude `.claude.json` holds `firstStartTime`, `firstStartVersion`, `machineID`, `userID`,
  `migrationVersion`, `seenNotifications` and three migration flags. Two no-op runs change none of
  them. Copilot writes no JSON file for a no-op.

What the setup commands add:

| Command | Claude | Copilot |
|---|---|---|
| `plugin marketplace add` | `plugins/known_marketplaces.json`, `plugins/marketplaces/`, `settings.json` `.extraKnownMarketplaces` | `settings.json` `.extraKnownMarketplaces`, `.cache/copilot/marketplaces/` |
| `plugin install` | `plugins/cache/`, `plugins/installed_plugins.json`, `settings.json` `.enabledPlugins` | `installed-plugins/<marketplace>/<plugin>/`, `config.json` `.installedPlugins`, `settings.json` `.enabledPlugins` |
| `mcp add` | `.claude.json` `.mcpServers` | `mcp-config.json` `.mcpServers` |

- Plugin paths are absolute: Claude's `installPath` and Copilot's `cache_path` point into the seed
  home, which exists in the image.
- **Copilot's `config.json` is JSONC**: it starts with `//` comment lines ("User settings belong in
  settings.json. This file is managed automatically."). It also holds the user's login
  (`logged_in_users`). Reading it with plain `jq` fails; any code that falls back to `{}` and writes
  it back loses the login. `20-onboarding` did exactly that; Task 8 fixes it with a shared reader.
- Locks, logs and backups (`*.lock`, `.mcp-writer.*`, `logs/`, `backups/`, `.last_inuse_sweep`) are
  never merged.

## Linked plugins load

With `~/.claude/plugins` linked to the seed's `plugins/`, the seed's `settings.json` keys in the home,
`~/.copilot/installed-plugins` linked to the seed and the seed's `installedPlugins` and `settings.json`
keys in the home, `claude plugin list` shows Superpowers enabled and `copilot plugin list` shows it
installed. Copilot's marketplace cache (`.cache/copilot/marketplaces`) is not needed to load an
installed plugin and is not linked.

## Copilot asset layout

- Personal skills: `~/.copilot/skills/<name>/SKILL.md` (also `~/.agents/skills/`), confirmed with
  `copilot skill list`.
- Custom agents: `~/.copilot/agents/<name>.agent.md` is the documented location; loading needs a
  login, so it is checked live in Task 18 with the other live checks.
- Instructions: `copilot-instructions.md` in the Copilot home (already used by the gate).
- User-level slash commands: none documented (`copilot help commands` lists only built-ins). `add
  command` stays Claude-only, with a warning.

## Local marketplaces

A directory with `.claude-plugin/marketplace.json` (`{"name", "owner", "plugins": [{"name",
"source": "./plugins/<name>"}]}`) and `plugins/<name>/.claude-plugin/plugin.json` plus
`skills/<name>/SKILL.md` is accepted by both `claude plugin marketplace add PATH` and
`copilot plugin marketplace add PATH`. Claude copies the plugin into its cache; Copilot loads it live
from the path ("nothing was copied"), so the path must stay in the image: the smoke copies the
marketplace into the image with a `copy` line and adds it from there.
