import { constants, closeSync, fstatSync, lstatSync, mkdirSync, openSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { isObject, PLANS, type Json, writeAtomic } from "./providers";

export type SharedAccount = { provider: Json; credential: Json; model?: string };
export type SharedAccounts = Record<string, SharedAccount>;
export const PLAN_STORE_ENV = "SPARK_PLAN_HOME";
export const SHARED_PLANS_FILE = "shared-plan-accounts.json";

export function accountKind(id: string) {
  return Object.values(PLANS).find(plan => new RegExp(`^${plan.auth}-[0-9a-f]{32}$`).test(id));
}

function accountDir(home: string, id: string, create = false) {
  const kind = accountKind(id);
  if (!kind) throw new Error("Invalid subscription account ID.");
  const dir = join(home, kind.auth);
  if (create) mkdirSync(dir, { mode: 0o700, recursive: true });
  const stat = lstatSync(dir, { throwIfNoEntry: false });
  if (!stat) return;
  if (!stat.isDirectory() || (stat.mode & 0o777) !== 0o700) throw new Error("Subscription account folder isn't private.");
  return dir;
}

const token = (v: unknown) => typeof v === "string" && /^[!-~]{1,16384}$/.test(v);

export function validCredential(id: string, v: unknown): v is Json {
  const kind = accountKind(id)?.auth;
  return !!kind && isObject(v) && token(v.access_token) && token(v.refresh_token) &&
    Number.isSafeInteger(v.expires_at_ms) && typeof v.subject === "string" && !!v.subject && typeof v.scope === "string" &&
    (kind !== "chatgpt-plan" || typeof v.client_id === "string" && /^oaiapp_[A-Za-z0-9_-]+$/.test(v.client_id)) &&
    (kind !== "antigravity-plan" || typeof v.project === "string" && !!v.project && typeof v.version === "string" && !!v.version) &&
    Buffer.byteLength(JSON.stringify(v)) <= 64 * 1024;
}

export function readCredential(home: string, id: string): Json | undefined {
  const dir = accountDir(home, id);
  if (!dir) return;
  let fd: number;
  try {
    fd = openSync(join(dir, `${id}.json`), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return;
    throw e;
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o777) !== 0o600 || stat.size > 64 * 1024) throw new Error("Subscription account file isn't private.");
    const value: unknown = JSON.parse(readFileSync(fd, "utf8"));
    if (!validCredential(id, value)) throw new Error("Invalid subscription credentials.");
    return value;
  } finally {
    closeSync(fd);
  }
}

export function writeCredential(home: string, id: string, value: Json) {
  if (!validCredential(id, value)) throw new Error("Invalid subscription credentials.");
  const dir = accountDir(home, id, true)!;
  writeAtomic(join(dir, `${id}.json`), value);
}

export function deleteCredential(home: string, id: string) {
  const dir = accountDir(home, id);
  if (dir) rmSync(join(dir, `${id}.json`), { force: true });
}

export function readAccounts(home: string, settings: Json): SharedAccounts {
  const all: SharedAccounts = {};
  for (const [id, provider] of Object.entries(isObject(settings.providers) ? settings.providers : {})) {
    const kind = accountKind(id);
    if (!kind || !isObject(provider) || provider.auth?.type !== kind.auth) continue;
    try {
      const credential = readCredential(home, id);
      if (!credential) continue;
      const model = isObject(settings.models) && typeof settings.models[id] === "string" ? settings.models[id] : undefined;
      all[id] = { provider, credential, model };
    } catch {
      // An unreadable or unsafe file stays local. Never send its contents or its parse error.
    }
  }
  return all;
}
