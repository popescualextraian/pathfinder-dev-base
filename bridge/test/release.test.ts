import { describe, expect, it } from "vitest";
import { parseHoldPid } from "../src/release.js";

describe("parseHoldPid", () => {
  it("accepts an integer greater than 1, with surrounding whitespace", () => {
    expect(parseHoldPid("42\n")).toBe(42);
    expect(parseHoldPid(" 2 ")).toBe(2);
  });

  it("refuses what would signal a group or everything, and anything that is not an integer", () => {
    for (const bad of ["", "\n", "0", "1", "-1", "-5", "1.5", "abc", "12 13", "1e3", "0x10"]) expect(parseHoldPid(bad)).toBeNull();
  });
});
