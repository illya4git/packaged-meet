export const PACKAGE_NAME = "@packaged-meet/shared";

/** Exhaustiveness guard for `switch` statements over discriminated unions. */
export function assertNever(value: never): never {
  throw new Error(`Unexpected value: ${JSON.stringify(value)}`);
}
