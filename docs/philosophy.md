# Philosophy

What we are building for, and why the toolbox looks the way it does.

The goal: each step brings more autonomy and more speed, while the quality stays the same or
gets better. We get there through seventeen pillars. Each one moves you up a level, and each one
builds on the ones before it.

| # | Pillar | In this repository |
|---|---|---|
| 0 | The developer becomes architect and owner | outside the repo: it is up to you |
| 1 | One container to rule them all | available: the base image |
| 2 | Run it remotely | planned (same image, any host) |
| 3 | Agentic colleagues | planned (scheduled runs) |
| 4 | Spec-driven development | available: Superpowers, Atlassian MCP |
| 5 | Invest in the plan | available: the spec gate |
| 6 | Knowledge in AI format | in progress: the wiki skill |
| 7 | A minimal, agent-maintained wiki | in progress: the wiki skill |
| 8 | The agent tests its own work | available: test tools and Playwright in the image |
| 9 | Steer the agent, don't write code | dev mode now; autonomous mode planned |
| 10 | Guardrails, not supervision | partly available: sandbox, secret handling; action gate planned |
| 11 | Feedback loops | available locally; CI access depends on the project |
| 12 | Review before the human | available: Superpowers code review |
| 13 | Isolated parallel work | planned: tasks and worktrees |
| 14 | Deterministic first | design principle, applied throughout |
| 15 | Context as code | available: `.agentic/`, `CLAUDE.md`, skills |
| 16 | Measure | planned: task records |

## Pillar 0: the developer becomes architect and owner

The developer's job is no longer writing code. A developer has to quickly become an architect
and a business owner: think in components, responsibilities, contracts, design and scale. Once
a component has clear responsibilities and contracts, the AI writes it fast.

This change happens in the developer, not in the repository.

## Pillar 1: one container to rule them all

Pun intended. The agent gets one container with every tool a developer has: Claude Code,
Copilot CLI, git, gh, Java, Node, Python, the AWS and Azure CLIs, Docker, a browser. You cannot
expect the agent to work as well as you do if it does not have the same access. How can it fix
an error if it cannot read the logs?

Each project adds its own tools on top, from `.agentic/agentic.yaml`.

## Pillar 2: run it remotely

You can run the harness on your laptop. Running it on a remote machine means things can run on
a schedule, run long tasks overnight, and keep working while you are away from the laptop.

Most important is the psychological effect: when the agent is not on your screen, you are less
tempted to watch every small step it takes.

## Pillar 3: agentic colleagues

Agents that run on a schedule: they update the documentation, write regular reports, pay down
tech debt. With pillars 1 and 2 in place, adding agentic colleagues is easy.

## Pillar 4: spec-driven development

Plan, build, test. Don't build your own method: adopt an existing one. We suggest
[Superpowers](https://github.com/obra/superpowers), which the image installs.

The agent also needs the sources a developer uses: the issue tracker, the wiki and the other
places where requirements and decisions live (pillar 1 again). Ideally all of that is one
seamless environment; if it is not, connect what you can through MCP servers.

## Pillar 5: invest in the plan

The plan is where your time pays off most.

A good plan:

- defines the architecture
- names the affected components and APIs
- states the reason and the business goal
- sets test criteria and test cases
- says how the agent proves the work

A weak plan:

- describes only the business need
- leaves the agent to guess where the code goes
- says nothing about how to test

## Pillar 6: knowledge in AI format

Agents read Markdown far better than PDFs, slides or screenshots. Keep the knowledge an agent
needs as Markdown files in the repository, next to the code.

## Pillar 7: a minimal, agent-maintained wiki

We focus on development work, not on product management. Even so, some things cannot be read
from the code. Every project needs a minimal wiki, maintained by the agent, with:

- the whys and the ADRs
- strict API contracts
- the architecture and the components
- each component's responsibility
- a map from concepts to code
- the rules to follow

An index matters: it lets the agent find what it needs without reading everything (progressive
disclosure).

## Pillar 8: the agent tests its own work

Probably the most important pillar. The agent must be able to test what it builds. Unit tests are
a must. UI tests with Playwright and API calls are mandatory too. Strong projects add good
regression suites and automation.

## Pillar 9: steer the agent, don't write code

Your job is to steer: set the direction, review, correct. Not to type the code.

Scale up step by step. Start with one task. The next day, continue it and add a second one in
parallel. The limit is your attention, not the agent.

## Pillar 10: guardrails, not supervision

An agent that runs alone, at night or on a schedule, cannot be watched. It needs guardrails
instead. The container is the sandbox. Rules that must hold are enforced in shell, not in
prompts. Outward-facing actions, such as pushing or posting, pass a gate. No secret ends up in
an image or a log. This is what makes pillars 2 and 3 safe.

## Pillar 11: feedback loops

The agent must see the result of what it did: build output, test results, CI, logs, the running
app. Fast, readable feedback beats a smarter model. Every tool from pillar 1 that shows a result
is part of the loop.

## Pillar 12: review before the human

Before you see the work, a second agent reviews it against the plan and the rules. Your review
then starts from a cleaner result, and you spend your time on design, not on typos and missed
cases.

## Pillar 13: isolated parallel work

One task gets one worktree and one branch. Parallel tasks never step on each other, and a task
that goes wrong is thrown away without touching the others. This is what makes pillar 9's
"add a second task" safe.

## Pillar 14: deterministic first

A script decides wherever a script can; the model is used only for judgement. Checks, builds,
formatting and gates are scripts. Runs become cheaper, faster and repeatable, and a rule holds
every time, not most of the time.

## Pillar 15: context as code

`CLAUDE.md`, skills, the wiki and the project's `.agentic/` are versioned with the code and
reviewed like code. The whole team gets the same agent with the same knowledge, and an
improvement made by one developer reaches everyone.

## Pillar 16: measure

Track time, cost and how often a task passes without rework. Then you know whether a change to
the setup, the plan template or a skill really helped, instead of guessing.
