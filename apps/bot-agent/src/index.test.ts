import { describe, expect, it } from "vitest";
import { COMPONENTS } from "./index.js";

describe("@packaged-meet/bot-agent", () => {
  it("links against shared and adapters", () => {
    expect(COMPONENTS).toEqual([
      "@packaged-meet/shared",
      "@packaged-meet/adapters",
      "@packaged-meet/bot-agent",
    ]);
  });
});
