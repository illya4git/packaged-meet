import { COMPONENTS as ADAPTERS } from "@packaged-meet/adapters";
import { COMPONENTS as DB } from "@packaged-meet/db";
import { PACKAGE_NAME as SHARED } from "@packaged-meet/shared";

export const PACKAGE_NAME = "@packaged-meet/controller";

/** Workspace packages this app depends on, including itself. */
export const COMPONENTS: readonly string[] = [
  ...new Set([SHARED, ...DB, ...ADAPTERS, PACKAGE_NAME]),
];
