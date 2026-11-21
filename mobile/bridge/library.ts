/**
 * The one set of providers and prompts the whole relay shares. The relay keeps it; every cloud
 * profile and every Mac gets a copy of it, and an edit anywhere goes here first.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { chooseModel, isObject, type Json, Profile, writeAtomic } from "./providers";
import type { PromptSummary, ProviderSummary } from "./protocol";

/** a prompt is a file named after it, so its name can't hold a path or start with a dot */
const PROMPT_NAME = /^(?![.\s])[^/\\\0\r\n:]{1,80}(?<!\s)$/;
const MAX_PROMPT_BYTES = 256 * 1024;
/** the folder in a spark profile that holds the library's prompts; spark lists it with the user's own */
export const PROMPT_DIR = "cloud-prompts";

/** what a profile copies: every provider whole, with keys, and every prompt */
export type LibrarySnapshot = {
  providers: Record<string, Json>;
  /** the model each provider starts on when a profile hasn't chosen one */
  models: Record<string, string>;
  provider?: string;
  /** header values the providers read; the cloud's spark gets them as variables */
  env: Record<string, string>;
  prompts: Record<string, string>;
};

type PromptRecord = { text: string; updatedAt: string };

export class Library {
  readonly profile: Profile;
  private listeners = new Set<() => void>();

  constructor(private o: { dir: string; spark: string }) {
    mkdirSync(o.dir, { recursive: true, mode: 0o700 });
    this.profile = new Profile({ home: o.dir, spark: o.spark, role: "cloud" });
  }

  private get promptsFile() {
    return join(this.o.dir, "prompts.json");
  }

  /** `f` runs after every change */
  onChange(f: () => void): () => void {
    this.listeners.add(f);
    return () => this.listeners.delete(f);
  }

  private changed() {
    for (const f of this.listeners) {
      try {
        f();
      } catch (e) {
        console.error("library listener failed:", e);
      }
    }
  }

  // MARK: Providers

  providers(): ProviderSummary[] {
    return this.profile.list();
  }

  async putProvider(input: { name: string; provider: unknown; model?: unknown; env?: unknown; previous?: unknown }): Promise<ProviderSummary[]> {
    const list = await this.profile.put(input);
    this.changed();
    return list;
  }

  async deleteProvider(name: unknown): Promise<ProviderSummary[]> {
    const list = await this.profile.delete(name);
    this.changed();
    return list;
  }

  // MARK: Prompts

  private readPrompts(): Record<string, PromptRecord> {
    try {
      const parsed = JSON.parse(readFileSync(this.promptsFile, "utf8"));
      if (!isObject(parsed)) return {};
      return Object.fromEntries(Object.entries(parsed).filter(([k, v]) => PROMPT_NAME.test(k) && isObject(v) && typeof v.text === "string")) as Record<string, PromptRecord>;
    } catch {
      return {};
    }
  }

  prompts(): PromptSummary[] {
    return Object.entries(this.readPrompts())
      .map(([name, p]) => ({ name, text: p.text, updatedAt: p.updatedAt ?? "" }))
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }));
  }

  /** adds or replaces a prompt; `previous` renames one */
  putPrompt(input: { name: unknown; text: unknown; previous?: unknown }): PromptSummary[] {
    const name = typeof input.name === "string" ? input.name.trim() : "";
    if (!PROMPT_NAME.test(name)) throw new Error("A prompt's name is 1 to 80 characters, without / \\ or : and not starting with a dot.");
    if (typeof input.text !== "string") throw new Error("That prompt has no text.");
    if (Buffer.byteLength(input.text) > MAX_PROMPT_BYTES) throw new Error("That prompt is longer than 256 KB.");
    const all = this.readPrompts();
    const previous = typeof input.previous === "string" && input.previous !== name ? input.previous : undefined;
    if (previous) {
      if (!all[previous]) throw new Error(`There's no prompt named ${previous}.`);
      if (all[name]) throw new Error(`There's already a prompt named ${name}.`);
      delete all[previous];
    }
    all[name] = { text: input.text, updatedAt: new Date().toISOString() };
    writeAtomic(this.promptsFile, all);
    this.changed();
    return this.prompts();
  }

  deletePrompt(name: unknown): PromptSummary[] {
    const all = this.readPrompts();
    if (typeof name !== "string" || !all[name]) throw new Error("That prompt is already gone.");
    delete all[name];
    writeAtomic(this.promptsFile, all);
    this.changed();
    return this.prompts();
  }

  // MARK: Copies

  snapshot(): LibrarySnapshot {
    const s = readJson(join(this.o.dir, "settings.json"));
    const providers = isObject(s.providers) ? (s.providers as Record<string, Json>) : {};
    const models = isObject(s.models) ? Object.fromEntries(Object.entries(s.models).filter(([k, v]) => typeof v === "string" && k in providers)) : {};
    const prompts = Object.fromEntries(Object.entries(this.readPrompts()).map(([k, v]) => [k, v.text]));
    return { providers, models: models as Record<string, string>, provider: typeof s.provider === "string" ? s.provider : undefined, env: this.profile.env(), prompts };
  }

  /**
   * The first time the relay runs with a library, it starts from the providers the cloud profiles
   * already have, newest file first, so nothing a phone set up is lost.
   */
  adopt(homes: string[]) {
    const file = join(this.o.dir, "settings.json");
    if (existsSync(file)) return;
    const found = homes
      .filter((h) => existsSync(join(h, "settings.json")))
      .sort((a, b) => statSync(join(b, "settings.json")).mtimeMs - statSync(join(a, "settings.json")).mtimeMs);
    const out: Json = { providers: {}, models: {} };
    const env: Record<string, string> = {};
    for (const home of found) {
      const s = readJson(join(home, "settings.json"));
      if (!isObject(s.providers)) continue;
      for (const [name, p] of Object.entries(s.providers)) {
        if (!isObject(p) || out.providers[name]) continue;
        out.providers[name] = p;
        if (isObject(s.models) && typeof s.models[name] === "string") out.models[name] = s.models[name];
      }
      if (out.provider === undefined && typeof s.provider === "string" && isObject(s.providers[s.provider])) out.provider = s.provider;
      const e = readJson(join(home, "cloud-env.json"));
      for (const [k, v] of Object.entries(e)) if (typeof v === "string" && !(k in env)) env[k] = v;
    }
    if (!Object.keys(out.providers).length) return;
    chooseModel(out);
    writeAtomic(file, out);
    writeAtomic(join(this.o.dir, "cloud-env.json"), env);
  }
}

function readJson(file: string): Json {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8"));
    return isObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/** a stable fingerprint of a provider, to tell an edit from a copy */
export function fingerprint(p: unknown): string {
  return createHash("sha256").update(stable(p)).digest("hex");
}

function stable(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stable).join(",")}]`;
  if (isObject(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stable(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

/**
 * Copies the library into a spark profile: its providers replace the profile's, the profile keeps
 * the provider and models it chose while they still exist, and the prompts land in PROMPT_DIR,
 * which the profile's prompts.json lists. Returns each provider's fingerprint as written.
 */
export function applySnapshot(home: string, snap: LibrarySnapshot): Record<string, string> {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const file = join(home, "settings.json");
  const s = readJson(file);
  s.providers = structuredClone(snap.providers);
  const models: Json = isObject(s.models) ? s.models : {};
  for (const name of Object.keys(models)) {
    const p = snap.providers[name];
    const meta = isObject(p) && isObject(p.model_metadata) ? p.model_metadata : null;
    if (!p || typeof models[name] !== "string" || (meta && Object.keys(meta).length && !(models[name] in meta))) delete models[name];
  }
  for (const [name, m] of Object.entries(snap.models)) if (!(name in models) && name in snap.providers) models[name] = m;
  s.models = models;
  if (typeof s.provider !== "string" || !snap.providers[s.provider]) {
    const next = snap.provider && snap.providers[snap.provider] ? snap.provider : Object.keys(snap.providers).sort()[0];
    if (next) s.provider = next;
    else delete s.provider;
  }
  chooseModel(s);
  writeAtomic(file, s);
  writePrompts(home, snap.prompts);
  return Object.fromEntries(Object.entries(snap.providers).map(([k, p]) => [k, fingerprint(p)]));
}

function writePrompts(home: string, prompts: Record<string, string>) {
  const dir = join(home, PROMPT_DIR);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const wanted = new Set<string>();
  for (const [name, text] of Object.entries(prompts)) {
    if (!PROMPT_NAME.test(name)) continue;
    const path = join(dir, `${name}.md`);
    wanted.add(`${name}.md`);
    if (existsSync(path) && readFileSync(path, "utf8") === text) continue;
    writeFileSync(`${path}.tmp`, text, { mode: 0o600 });
    renameSync(`${path}.tmp`, path);
  }
  for (const f of readdirSync(dir)) if (!wanted.has(f)) rmSync(join(dir, f), { force: true });
  // spark lists every folder in prompts.json; the library's goes beside the user's own
  const listFile = join(home, "prompts.json");
  const list = readJson(listFile);
  const dirs = Array.isArray(list.dirs) ? list.dirs.filter((d: unknown) => typeof d === "string") : [];
  if (!dirs.includes(dir)) {
    list.dirs = [...dirs, dir];
    writeAtomic(listFile, list);
  }
}

/** the library prompt file `name` in a profile, when it has arrived there */
export function promptFile(home: string, name: string): string | null {
  if (!PROMPT_NAME.test(name)) return null;
  const path = join(home, PROMPT_DIR, `${name}.md`);
  return existsSync(path) ? path : null;
}
