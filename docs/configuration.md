# agentic.yaml reference

Generated from `schema/agentic.schema.json` and `config/defaults.yaml` by
`tools/gen-config-docs.sh`. Do not edit by hand. Setup lines (`setup:`): [setup.md](setup.md).

| Field | Type | Default | Description |
|---|---|---|---|
| `version` | 2 | `2` | Schema version. Always 2. |
| `project` | string |  | Project name. Names the image agentic-<project>:local and the workspace directory. |
| `layout` | "single" / "multi" |  | What /work is: single (the project root is one git repository) or multi (git repositories in its direct subfolders). Written by agentic init; agentic run needs it. |
| `target` | string |  | multi only: the default repository agentic run starts the agent in, a direct subfolder of the project root. agentic target NAME sets it. |
| `targets` | array | `["claude","copilot"]` | Default --target of every setup line: the harnesses that assets, plugins, marketplaces and MCP servers go to. |
| `base_image` | string | `"agentic-dev-base:local"` | Image the derived image is built FROM: the base or an overlay built FROM the base. |
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
| `hooks` | object | `{"on_start":".agentic/hooks/on-start.sh","on_start_required":false}` | Project hooks. |
| `hooks.on_start` | string | `".agentic/hooks/on-start.sh"` | Script run as dev at every container start, with the full environment. |
| `hooks.on_start_required` | boolean | `false` | When true, a failing on_start stops the container. |
| `harness` | object | `{"default":"claude"}` | Harness choice. |
| `harness.default` | "claude" / "copilot" | `"claude"` | Agent of agentic run without --agent, and of agentic setup. |
| `docker` | object | `{"socket":false}` | Docker access. |
| `docker.socket` | boolean | `false` | Mount the host Docker socket. It is host root; off by default. Changing it needs agentic build. |
| `setup` | array | `[]` | The container's setup as agentic commands without the agentic prefix (docs/setup.md): add marketplace|plugin|mcp|skill|agent|command|workspace, copy, mount, volume. Replayed in order by agentic build and the start. |
