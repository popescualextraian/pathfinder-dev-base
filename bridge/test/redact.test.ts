import { describe, expect, it } from "vitest";
import { makeRedactor, redactDeep } from "../src/redact.js";

describe("redact", () => {
  const r = makeRedactor(["task-token-0123456789", "short"]);

  it("masks known token patterns", () => {
    expect(r("key sk-ant-oat01-AbCdEf0123456789xyz end")).toBe("key [redacted] end");
    expect(r("gho_0123456789abcdefABCDEF and ghp_0123456789abcdefABCDEF")).toBe("[redacted] and [redacted]");
    expect(r("github_pat_11ABCDEFG0123456789_abcdefghijklmnop")).toBe("[redacted]");
    expect(r("Authorization: Bearer abc.def-ghi_jkl")).toBe("Authorization: Bearer [redacted]");
    expect(r("AKIAABCDEFGHIJKLMNOP")).toBe("[redacted]");
  });

  it("masks the task's own tokens but ignores secrets shorter than 8 characters", () => {
    expect(r("x task-token-0123456789 y")).toBe("x [redacted] y");
    expect(r("a short word")).toBe("a short word");
  });

  it("leaves ordinary text alone", () => {
    expect(r("git push origin HEAD; sk-ant is a prefix")).toBe("git push origin HEAD; sk-ant is a prefix");
  });

  it("walks objects and arrays", () => {
    const v = redactDeep({ a: ["sk-ant-api03-0123456789abcdef"], b: { c: 1, d: "ok" } }, r);
    expect(v).toEqual({ a: ["[redacted]"], b: { c: 1, d: "ok" } });
  });

  it("masks a secret that contains another one completely (longest first)", () => {
    const rr = makeRedactor(["abcdefgh", "abcdefghXYZ12345", "abcdefgh"]);
    expect(rr("x abcdefghXYZ12345 y")).toBe("x [redacted] y");
  });

  it("ignores empty and short secrets", () => {
    const rr = makeRedactor(["", "abc"]);
    expect(rr("abc and more")).toBe("abc and more");
  });

  it("masks a lowercase bearer scheme", () => {
    expect(r("authorization: bearer abc.def-ghi_jkl")).toBe("authorization: Bearer [redacted]");
  });

  it("does not mutate its input", () => {
    const input = { a: ["sk-ant-api03-0123456789abcdef"], b: { d: "ok" } };
    const copy = structuredClone(input);
    redactDeep(input, r);
    expect(input).toEqual(copy);
  });
});
