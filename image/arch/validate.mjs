// Validate architect files against the schemas.
// Usage: node validate.mjs [--model MODEL.json] [--schemas DIR] < items.json
// items: [{ kind: model|plan|full|architecture|component, file, data }]
// Prints "<file>: <message>" per problem; exit 0 none, 1 problems, 2 usage.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const die = (msg) => { console.error(msg); process.exit(2); };

let Ajv;
try {
  Ajv = createRequire(import.meta.url)("ajv/dist/2020").default;
} catch {
  die("agentic-arch: run npm ci in image/arch");
}

let modelPath = null;
let schemas = join(here, "..", "..", "skills", "architect", "schema");
const args = process.argv.slice(2);
while (args.length) {
  const a = args.shift();
  if (a === "--model" && args.length) modelPath = args.shift();
  else if (a === "--schemas" && args.length) schemas = args.shift();
  else die("usage: validate.mjs [--model MODEL.json] [--schemas DIR] < items.json");
}

const files = {
  model: "model", plan: "plan-review", full: "full-review",
  architecture: "architecture", component: "component",
};
const ajv = new Ajv({ allErrors: false, strict: true, strictRequired: false });
const validators = {};
const load = (name) => JSON.parse(readFileSync(join(schemas, `${name}.schema.json`), "utf8"));

let items;
try {
  items = JSON.parse(readFileSync(0, "utf8"));
  if (!Array.isArray(items)) throw new Error("not an array");
} catch (e) {
  die(`validate.mjs: stdin must be a JSON array of items (${e.message})`);
}

let known = null;
if (modelPath) {
  try {
    known = new Set(JSON.parse(readFileSync(modelPath, "utf8")).components.map((c) => c.id));
  } catch (e) {
    die(`validate.mjs: cannot read model ${modelPath} (${e.message})`);
  }
}

const problems = [];
for (const { kind, file, data } of items) {
  if (!files[kind]) { problems.push(`${file}: unknown kind ${kind}`); continue; }
  validators[kind] ??= ajv.compile(load(files[kind]));
  const validate = validators[kind];
  if (!validate(data)) {
    const e = validate.errors[0];
    problems.push(`${file}: ${e.instancePath || "/"} ${e.message}${e.params?.allowedValues ? ` (${e.params.allowedValues.join("|")})` : ""}`);
    continue;
  }
  if (!known) continue;
  if (kind === "plan") {
    for (const c of data.changes) {
      if (!known.has(c.component) && !(c.change === "new" && c.proposed)) {
        problems.push(`${file}: component ${c.component} is neither in the model nor new with proposed`);
      }
    }
  } else if (kind === "full") {
    const refs = [...Object.keys(data.components), ...data.findings.map((f) => f.component)];
    for (const id of new Set(refs)) {
      if (!known.has(id)) problems.push(`${file}: component ${id} is not in the model`);
    }
  }
}
for (const p of problems) console.log(p);
process.exit(problems.length ? 1 : 0);
