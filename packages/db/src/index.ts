import { PACKAGE_NAME as SHARED } from "@packaged-meet/shared";

export const PACKAGE_NAME = "@packaged-meet/db";

/** Workspace packages this package depends on, including itself. */
export const COMPONENTS: readonly string[] = [SHARED, PACKAGE_NAME];
