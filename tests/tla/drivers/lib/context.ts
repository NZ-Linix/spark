// Run context for the Bun drivers written as `bun test` files: which spark
// checkout and binary they drive, where their output goes, and the E2E helpers
// they borrow from tests/e2e/.
//
//   SPARK_WORKTREE    checkout under test (default: this one)
//   SPARK_BIN         binary under test (default: <checkout>/zig-out/bin/spark)
//   SPARK_TLA_OUT     output root (default: a folder under the system temp dir)
//   SPARK_TLA_REPEAT  how many times a repeatable check runs (default: 1)
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { REPO_ROOT, outDir } from "./tlc";

export const worktree = resolve(process.env.SPARK_WORKTREE ?? REPO_ROOT);
export const binary = process.env.SPARK_BIN ?? join(worktree, "zig-out", "bin", "spark");
export const artifacts = outDir(process.env.SPARK_TLA_CASE ?? "driver");
export const repetitions = Number(process.env.SPARK_TLA_REPEAT ?? "1");

/// The checkout's tests/e2e/tmux-helpers.ts: tmux sessions and fake gateways.
export async function targetHelpers() {
  return await targetModule("tmux-helpers.ts");
}

/// A helper module from the checkout's tests/e2e/, such as shell-sessions.ts.
export async function targetModule(name: string) {
  const path = join(worktree, "tests", "e2e", name);
  if (!existsSync(path)) throw new Error(`missing ${path}`);
  return await import(pathToFileURL(path).href);
}

export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function hashFile(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/// A minimal environment for an spark process under test: no inherited
/// credentials, sound, keychain, upgrade check, or dotenv.
export function testEnvironment(values: Record<string, string>, inherited = process.env): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of ["PATH", "TERM", "COLORTERM", "LANG", "LC_ALL", "TMPDIR"]) {
    if (inherited[key]) result[key] = inherited[key]!;
  }
  return {
    ...result,
    SPARK_SOUND: "0",
    SPARK_DISABLE_KEYCHAIN: "1",
    SPARK_AUTO_UPGRADE: "0",
    SPARK_E2E_DISABLE_DOTENV: "1",
    ...values,
  };
}
