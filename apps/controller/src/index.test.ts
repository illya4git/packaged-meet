import { describe, expect, it } from "vitest";
import { COMPONENTS } from "./index.js";

describe("@packaged-meet/controller", () => {
  it("links against shared, db and adapters", () => {
    expect(COMPONENTS).toEqual([
      "@packaged-meet/shared",
      "@packaged-meet/db",
      "@packaged-meet/adapters",
      "@packaged-meet/controller",
    ]);
  });
});
