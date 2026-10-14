import { describe, expect, it } from "vitest";
import { assertNever, PACKAGE_NAME } from "./index.js";

describe("@packaged-meet/shared", () => {
  it("exports its package name", () => {
    expect(PACKAGE_NAME).toBe("@packaged-meet/shared");
  });

  it("assertNever throws on unexpected values", () => {
    expect(() => assertNever("oops" as never)).toThrow('Unexpected value: "oops"');
  });
});
