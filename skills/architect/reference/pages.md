# The page contract

The schemas in `schema/` (`architecture.schema.json`, `component.schema.json`) are the truth for
front matter; this page says what each key means and what the body holds. `agentic-arch check`
enforces the shape and the limits.

Every page directs: name the choice, pin it, give the rule. Leave out what the code or a command
shows (field lists, routes, class lists, folder listings) and what any textbook says.

## architecture.md

Front matter:

- `style`: a catalog style id (`layered`, `modular-monolith`, `hexagonal`, `microservices`, or a
  project entry).
- `parts`: the separately built or run pieces, in drawing order; one for a simple project. Each has
  `id`, `name`, `layers` (top to bottom, each `{id, name, mayUse[, folders]}`), optional `modules`
  (`{id, name}`; the columns of the picture, feature areas) and optional `mayUse` (other part ids
  it may import; parts normally talk only at run time).
- `boundaries` (optional): sealed folders `{id, folder, uses, entry}`. Code inside may import only
  the layers in `uses`; code outside imports it only through `entry`. Checked, not drawn.
- `principles`: catalog principle ids in priority order.
- `patterns`: catalog pattern ids the project uses.
- `exceptions`: accepted breaks `{id, rule, component, reason[, plan]}`. A finding whose id is here
  is accepted. `plan` names the plan review slug it came from.

Dependency rules come only from parts, `layers[].mayUse` and boundaries. `talks_to` describes run
time calls for the picture and impact; it is not an import allowlist.

Body, each section left out when empty:

- **Style**: one line, plus the choices the style label leaves open.
- **Layers**: one line per layer where the folder layout does not say it.
- **Rules**: the project's own rules, one line each ("the service owns the interfaces it needs").
- **Exceptions**: the human text for each entry in `exceptions`.
- **Where to start**: two or three pointers for a newcomer.

## components/<id>.md

Front matter:

- `id`: `[a-z0-9-]{1,60}`, equal to the file name.
- `name`, and `summary`: one line; it is the component's line in the index.
- `part`: optional when the project has one part. `layer`: a layer id of that part.
- `module`: optional; a component without one spans its layer's row (shared code usually does).
- `parent`: optional, for later nesting; leave it out.
- `sources`: folders or files. The longest match owns a file; no two components claim the same
  entry. Sources may include configuration, migrations and pipelines.
- `talks_to`: `[{to, via}]` with `via` one of `call`, `rest`, `event`, `file`, `other`.
- `patterns`: catalog pattern ids it applies.
- `status`: `draft` when written by seed, `reviewed` once a person has read it.

Body, in this order, each section a few lines:

- **Purpose and boundary**: what it owns and what it must not do.
- **Where changes go**: which file or folder takes which kind of change.
- **Contracts**: what others rely on: the entry point, the events, the shapes that must not change.
- **Invariants**: what must stay true.
- **Why**: the reason it is built this way, when it is not obvious.
- **Pitfalls**: the mistakes someone new would make.

At most about 80 lines, no table longer than 10 rows, no lists of routes or fields.

## flows/<id>.md

Optional; only for a few main business flows. Front matter `title`. The body lists the steps, one
line each, naming the component of each step, with the failure handling where it is not obvious.

## decisions/<n>.md

Optional; only when a decision needs more than a line under **Why**. Minimal MADR: front matter
`title`, `status` (proposed, accepted, superseded), `date`; body Context, Decision, Consequences.

## omitted.yaml

`paths:` with `{path, reason}` entries for paths that deliberately belong to no component (an entry
point that only wires things, generated code, fixtures).
