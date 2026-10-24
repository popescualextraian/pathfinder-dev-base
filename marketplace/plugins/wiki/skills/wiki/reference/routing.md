# Routing knowledge

Every statement goes to exactly one place. Apply the test in order; the first match decides.

| # | The statement is | Goes to | Example |
|---|---|---|---|
| 1 | Said by the code, or printed by a command | Nowhere; a pointer at most | "Routes are defined in routes.py", a list of environment variables, a field list, a version |
| 2 | A repeated procedure | A skill or a template, plus one line in CLAUDE.md | "To cut a release: ..." becomes a skill; "Use templates/story.md for a story" |
| 3 | An instruction for every task, where removing it would cause mistakes | CLAUDE.md | "Run the linter before every push", "Never commit to main" |
| 4 | An instruction for some paths only | A path rule | "Migrations are append-only" for `db/migrations/**` |
| 5 | A description the code does not reveal | A wiki page | "Billing owns the payment provider; nothing else calls it", "We chose polling over webhooks because ..." |

## Where each kind of knowledge lives

| Knowledge | Place |
|---|---|
| Whys, ADRs | `decisions/adr-<n>.md`; local whys in the component's "Why" |
| Contracts | The owning component's "Contracts": that it is fixed, who relies on it, where its schema lives. No field lists. "Never change it without a new version" is a path rule on its folder. |
| Architecture, components, responsibilities | `overview.md` and the component pages; the index map is generated |
| Concepts | `concepts/<id>.md` for cross-cutting ideas; `glossary.md` for terms |
| Business flows | `flows/<id>.md`: trigger, steps naming components, outcome, failure paths |
| Shared code | One line in CLAUDE.md naming the shared module and `docs/wiki/reuse.md`; each function as an `offers` entry of its component |
| Project structure | Only the components' `sources` and the map. No tree, no folder tour. |
| Commands, how to work, git and PR rules | CLAUDE.md |
| Gotchas | Every task: CLAUDE.md. One component: its "Pitfalls". Enforced for an area: a path rule. |
| Lessons from tasks | The affected component's "Pitfalls" |

## Rules versus the wiki

Rules are imperative: "do", "never", "always". The wiki is descriptive: "is", "owns", "because".
When an instruction needs its reason, the rule holds the instruction and a link, and the wiki holds
the reason. The reason never sits in always-on context.

## CLAUDE.md

At most 130 lines, so that it and the index (at most 70) stay under 200 always-loaded lines. Keep a
line only if removing it would cause mistakes on some task. Do not put in it what the code shows,
standard conventions of the language, file-by-file descriptions or long explanations; link a page
instead. `@` imports do not save context: imported files load in full, so import only the index.

## Copilot

Copilot CLI reads the root CLAUDE.md but not `@` imports, and reads `.github/instructions/` instead
of `.claude/rules/`. `agentic-wiki sync` covers both: never write those Copilot files by hand.
