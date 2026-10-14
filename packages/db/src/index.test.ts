import { describe, expect, it } from "vitest";
import { COMPONENTS } from "./index.js";

describe("@packaged-meet/db", () => {
  it("links against shared", () => {
    expect(COMPONENTS).toEqual(["@packaged-meet/shared", "@packaged-meet/db"]);
  });
});
