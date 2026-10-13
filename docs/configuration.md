# agentic.yaml reference

Generated from `schema/agentic.schema.json` and `config/defaults.yaml` by
`tools/gen-config-docs.sh`. Do not edit by hand.

| Field | Type | Default | Description |
|---|---|---|---|
| `version` | 1 | `1` | Schema version. Always 1. |
| `project` | string |  | Project name. Names the image agentic-<project>:local and the workspace directory. |
| `base_image` | string | `"agentic-dev-base:local"` | Image the derived image is built FROM: the base or an overlay built FROM the base. |
| `git` | object | `{"host":"github.com","user_name":"","user_email":""}` | Git settings. |
| `git.host` | string | `"github.com"` | Git host for GH_HOST, and for the credential helper with GH_TOKEN or GIT_TOKEN unless git.hosts lists it. |
| `git.hosts` | object |  | Further git hosts, each with its own token: host -> {kind: github (default) or gitlab, token: "${VAR}" naming a variable in .env}. Each host with a token gets a credential helper; the first gitlab host also gets GITLAB_HOST and GITLAB_TOKEN. |
| `git.user_name` | string | `""` | Commit author name. Empty uses the host's git config. |
| `git.user_email` | string | `""` | Commit author email. Empty uses the host's git config. |
| `tools` | object | `{"java":{"versions":[21],"default":21},"maven":"3.9.9","gradle":false,"node":{"versions":[22],"default":22},"python":["3.12"],"apt":[],"extra_dockerfile":".agentic/Dockerfile.extra"}` | Build-time tools. Changing them needs agentic build. |
| `tools.java` | false or object | `{"versions":[21],"default":21}` | JDK majors, installed side by side under /opt/java/<v>; 21 is always present. default sets JAVA_HOME. |
| `tools.node` | false or object | `{"versions":[22],"default":22}` | Node majors, side by side under /opt/node/<v>; 22 is always present. default goes first on PATH. |
| `tools.python` | array | `["3.12"]` | Python versions installed with uv. |
| `tools.maven` | false or string | `"3.9.9"` | Maven version (exact, e.g. 3.9.9). |
| `tools.gradle` | false or string | `false` | System Gradle version (exact). The wrapper (./gradlew) is the norm; false installs none. |
| `tools.terraform` | false or string |  | Terraform version (exact). |
| `tools.checkov` | false or string |  | Checkov version (exact). |
| `tools.tflint` | false or string |  | TFLint version (exact). |
| `tools.kubectl` | false or string |  | kubectl version (exact). |
| `tools.helm` | false or string |  | Helm version (exact). |
| `tools.dotnet` | false or string |  | .NET SDK channel (e.g. 8.0). |
| `tools.go` | false or string |  | Go version (exact, e.g. 1.22.5). |
| `tools.glab` | false or string |  | GitLab CLI version (exact). |
| `tools.psql` | false or string |  | PostgreSQL client major (e.g. 16). |
| `tools.apt` | array | `[]` | Plain apt packages, optionally pinned (name=version). |
| `tools.extra_dockerfile` | string | `".agentic/Dockerfile.extra"` | Dockerfile lines appended to the derived image, run as root, inside .agentic/. |
| `certs` | string | `".agentic/certs"` | Directory inside .agentic/ whose *.crt files are trusted by the system, Java, Node, Python and Chromium. |
| `plugins` | object | `{"claude":["superpowers@claude-plugins-official"],"copilot":[],"marketplaces":["anthropics/claude-plugins-official"]}` | Harness plugins. Claude plugins are baked at build time; Copilot plugins install at first start. |
| `plugins.claude` | array | `["superpowers@claude-plugins-official"]` | Claude plugins as name@marketplace. |
| `plugins.copilot` | array | `[]` | Copilot plugins as name@marketplace. |
| `plugins.marketplaces` | array | `["anthropics/claude-plugins-official"]` | Marketplace repositories (owner/repo) added before installing. |
| `mcp` | object | `{"atlassian":{"enabled":false,"jira_url":"","confluence_url":""},"playwright":{"enabled":true,"mode":"headless"},"graphify":{"enabled":true},"custom":[]}` | MCP servers, applied at every start without a rebuild. |
| `mcp.atlassian` | object | `{"enabled":false,"jira_url":"","confluence_url":""}` | Jira and Confluence (mcp-atlassian). Tokens: JIRA_PERSONAL_TOKEN, CONFLUENCE_PERSONAL_TOKEN in .env. |
| `mcp.atlassian.enabled` | boolean | `false` |  |
| `mcp.atlassian.jira_url` | string | `""` |  |
| `mcp.atlassian.confluence_url` | string | `""` |  |
| `mcp.playwright` | object | `{"enabled":true,"mode":"headless"}` | Browser automation. headed needs a display; without one Xvfb starts. |
| `mcp.playwright.enabled` | boolean | `true` |  |
| `mcp.playwright.mode` | "headless" / "headed" | `"headless"` |  |
| `mcp.graphify` | object | `{"enabled":true}` | Code and docs graph server (graphify-out/graph.json in the working directory). |
| `mcp.graphify.enabled` | boolean | `true` |  |
| `mcp.custom` | array | `[]` | Other MCP servers. ${VAR} references are expanded by the harness from the environment. |
| `skills` | string | `".agentic/skills"` | Directory inside .agentic/ with project skills (<name>/SKILL.md), copied into both harnesses. |
| `hooks` | object | `{"on_build":".agentic/hooks/on-build.sh","on_start":".agentic/hooks/on-start.sh","on_start_required":false}` | Project hooks. |
| `hooks.on_build` | string | `".agentic/hooks/on-build.sh"` | Script run as dev at the end of the derived build. Never sees .env. |
| `hooks.on_start` | string | `".agentic/hooks/on-start.sh"` | Script run as dev at every container start, with the full environment. |
| `hooks.on_start_required` | boolean | `false` | When true, a failing on_start stops the container. |
| `harness` | object | `{"default":"claude","claude":{"model":""},"copilot":{"model":""}}` | Harness choice and models. |
| `harness.default` | "claude" / "copilot" | `"claude"` | Harness used by agentic setup. |
| `harness.claude` | object | `{"model":""}` |  |
| `harness.claude.model` | string | `""` | Model; empty uses the harness default. |
| `harness.copilot` | object | `{"model":""}` |  |
| `harness.copilot.model` | string | `""` | Model; empty uses the harness default. |
| `docker` | object | `{"socket":false}` | Docker access. |
| `docker.socket` | boolean | `false` | Mount the host Docker socket. It is host root; off by default. Changing it needs agentic build. |
