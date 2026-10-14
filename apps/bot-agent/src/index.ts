import { COMPONENTS as ADAPTERS } from "@packaged-meet/adapters";
import { PACKAGE_NAME as SHARED } from "@packaged-meet/shared";

export const PACKAGE_NAME = "@packaged-meet/bot-agent";

/** Workspace packages this app depends on, including itself. */
export const COMPONENTS: readonly string[] = [...new Set([SHARED, ...ADAPTERS, PACKAGE_NAME])];
