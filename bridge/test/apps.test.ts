import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Apps, autostartNames, cleanText, spawnRunner, type RunResult } from "../src/apps.js";

const web = { name: "web", state: "stopped", ports: [3000], url: "/", since: null, exit_code: null };
const ok = (out: string): RunResult => ({ code: 0, out, err: "", timedOut: false });
const fail = (err: string, code = 1): RunResult => ({ code, out: "", err, timedOut: false });

// fake: a runner answering list from LIST and every other call from REPLY; it records each call.
function fake(reply: (args: string[]) => RunResult = () => ok(""), list: () => RunResult = () => ok(JSON.stringify([web]))) {
  const calls: Array<{ args: string[]; timeout: number; work: string }> = [];
  const apps = new Apps(async (args, timeout, work) => { calls.push({ args, timeout, work }); return args[0] === "list" ? list() : reply(args); });
  return { apps, calls };
}

describe("Apps", () => {
  it("list runs agentic-app list --json in the checkout with the short timeout", async () => {
    const { apps, calls } = fake();
    expect(await apps.list("/work/t")).toEqual({ ok: true, value: [web] });
    expect(calls).toEqual([{ args: ["list", "--json"], timeout: 10_000, work: "/work/t" }]);
  });

  it("list answers 502 for output that is no JSON list, or a failed run", async () => {
    for (const r of [ok("not json"), ok('{"web":1}'), ok("[1]"), fail("boom")]) {
      expect(await fake(undefined, () => r).apps.list("/w")).toMatchObject({ ok: false, status: 502 });
    }
  });

  it("an unknown name is refused with 404 before anything is spawned for it", async () => {
    const { apps, calls } = fake();
    expect(await apps.act("/w", "api", "start")).toMatchObject({ ok: false, status: 404, code: "not_found" });
    expect(calls.map((c) => c.args)).toEqual([["list", "--json"]]);
  });

  it("start and restart run with the long timeout that covers prepare; stop with the short one; the app comes back", async () => {
    const running = { ...web, state: "running", since: 1 };
    let after = false;
    const { apps, calls } = fake(() => { after = true; return ok(""); }, () => ok(JSON.stringify([after ? running : web])));
    expect(await apps.act("/w", "web", "start")).toEqual({ ok: true, value: running });
    await apps.act("/w", "web", "restart");
    await apps.act("/w", "web", "stop");
    expect(calls.filter((c) => c.args[0] !== "list")).toEqual([
      { args: ["start", "web"], timeout: 660_000, work: "/w" },
      { args: ["restart", "web"], timeout: 660_000, work: "/w" },
      { args: ["stop", "web"], timeout: 10_000, work: "/w" },
    ]);
  });

  it("maps agentic-app's refusals: preparing 409, unknown app 404, a timeout 504, anything else 502 with its last lines", async () => {
    const act = (r: RunResult) => fake(() => r).apps.act("/w", "web", "start");
    expect(await act(fail("agentic-app: app web is preparing; start it again when that ends\n"))).toMatchObject({ status: 409, code: "conflict" });
    expect(await act(fail("agentic-app: unknown app web\n"))).toMatchObject({ status: 404, code: "not_found" });
    expect(await act({ code: null, out: "", err: "", timedOut: true })).toMatchObject({ status: 504, code: "app_timeout" });
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i}`).join("\n");
    const r = await act(fail(`agentic-app: prepare of web failed (exit 2); its last lines:\n${lines}\n\u001b[31mred\u0007`));
    expect(r).toMatchObject({ ok: false, status: 502, code: "app_failed" });
    const message = r.ok ? "" : r.message;
    expect(message).toContain("line 29");
    expect(message).not.toContain("line 5\n");
    // eslint-disable-next-line no-control-regex
    expect(message).not.toMatch(/[\u0000-\u0008\u000b-\u001f\u007f]/);
  });

  it("logs asks for the lines, returns them clean, and maps a stopped app to 409", async () => {
    const { apps, calls } = fake(() => ok("one\n\u001b[1mtwo\u001b[0m\tx\nthree\n"));
    expect(await apps.logs("/w", "web", 200)).toEqual({ ok: true, value: ["one", "[1mtwo[0m\tx", "three"] });
    expect(calls.at(-1)).toEqual({ args: ["logs", "web", "--lines", "200"], timeout: 10_000, work: "/w" });
    expect(await fake(() => fail("agentic-app: app web is not running\n")).apps.logs("/w", "web", 5)).toMatchObject({ status: 409 });
    expect(await fake().apps.logs("/w", "api", 5)).toMatchObject({ status: 404 });
  });
});

describe("cleanText", () => {
  it("removes C0 controls but tab and newline, DEL and C1 controls", () => {
    expect(cleanText("a\u0000b\u001b[0m\tc\nd\u007fe\u0085f\u009b")).toBe("ab[0m\tc\ndef");
  });
});

describe("autostartNames", () => {
  it("names the apps with autostart true and a valid name, in order", () => {
    const conf = { apps: { web: { autostart: true }, db: { autostart: false }, api: { autostart: true }, "Bad;x": { autostart: true }, x: {} } };
    expect(autostartNames(JSON.stringify(conf))).toEqual(["web", "api"]);
  });
  it("is empty for no apps or a config that is no JSON object", () => {
    for (const s of ["{}", "", "nope", "[]", '{"apps":[1]}', "null"]) expect(autostartNames(s)).toEqual([]);
  });
});

describe("spawnRunner", () => {
  const script = (body: string) => {
    const dir = mkdtempSync(join(tmpdir(), "apps-"));
    const p = join(dir, "agentic-app");
    writeFileSync(p, `#!/usr/bin/env node\n${body}\n`);
    chmodSync(p, 0o755);
    return { p };
  };

  it.skipIf(process.platform === "win32")("passes arguments literally, never through a shell, with AGENTIC_WORK set", async () => {
    const { p } = script(`process.stdout.write(JSON.stringify({ argv: process.argv.slice(2), work: process.env.AGENTIC_WORK, keep: process.env.KEEP })); process.stderr.write("e"); process.exit(3);`);
    const run = spawnRunner(p, { ...process.env, KEEP: "1" });
    const r = await run(["start", "a; touch /tmp/pwned #$(id)"], 5000, "/work/x y");
    expect(r).toMatchObject({ code: 3, err: "e", timedOut: false });
    expect(JSON.parse(r.out)).toEqual({ argv: ["start", "a; touch /tmp/pwned #$(id)"], work: "/work/x y", keep: "1" });
  });

  it.skipIf(process.platform === "win32")("ends a run past its timeout and says so", async () => {
    const { p } = script("setTimeout(() => {}, 10000);");
    const r = await spawnRunner(p, process.env)([], 200, "/w");
    expect(r.timedOut).toBe(true);
  });

  it("a missing program is a failed run, not a throw", async () => {
    const r = await spawnRunner(join(tmpdir(), "no-such-agentic-app"), process.env)(["list"], 1000, "/w");
    expect(r.code).not.toBe(0);
    expect(r.timedOut).toBe(false);
  });
});
