import { defaultServerConditions } from "vite";
import { defineConfig } from "vitest/config";

// Resolve @packaged-meet/* workspace imports to their TypeScript sources so tests
// never depend on a prior `tsc --build`. See the "@packaged-meet/source" export
// condition in each package.json.
const conditions = ["@packaged-meet/source", ...defaultServerConditions];

export default defineConfig({
  resolve: { conditions },
  ssr: { resolve: { conditions } },
  test: {
    include: ["src/**/*.test.ts"],
  },
});
