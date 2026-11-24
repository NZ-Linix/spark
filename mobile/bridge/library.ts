/**
 * The one set of providers and prompts the whole relay shares. The relay keeps it; every cloud
 * profile and every Mac gets a copy of it, and an edit anywhere goes here first.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { chooseModel, isObject, type Json, Profile, writeAtomic } from "./providers";
import type { McpSummary, PromptSummary, ProviderSummary } from "./protocol";

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
  mcp?: Record<string, Json>;
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

  // MARK: MCP servers

  private get mcpFile() {
    return join(this.o.dir, "mcp.json");
  }

  private readMcpFile(): Json {
    return readJson(this.mcpFile);
  }

  private writeMcp(servers: Record<string, Json>) {
    writeAtomic(this.mcpFile, { ...this.readMcpFile(), mcpServers: servers });
    this.changed();
  }

  mcp(): McpSummary[] {
    return Object.entries(readMcp(this.o.dir) ?? {})
      .map(([name, server]) => mcpSummary(name, server))
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }));
  }

  /** adds or replaces a server; `previous` renames one, and a null env or header value keeps the saved one */
  putMcp(input: { name: unknown; server: unknown; previous?: unknown }): McpSummary[] {
    const name = typeof input.name === "string" ? input.name.trim() : "";
    if (!MCP_NAME.test(name)) throw new Error("An MCP server's name is 1 to 64 characters, without line breaks or spaces at either end.");
    const all = readMcp(this.o.dir) ?? {};
    const previous = typeof input.previous === "string" && input.previous !== name ? input.previous : undefined;
    if (previous && !all[previous]) throw new Error(`There's no MCP server named ${previous}.`);
    if (previous && all[name]) throw new Error(`There's already an MCP server named ${name}.`);
    const server = checkMcp(input.server, all[previous ?? name]);
    const next: Record<string, Json> = {};
    // a renamed server keeps its place in the file
    for (const [k, v] of Object.entries(all)) {
      if (k === previous) next[name] = server;
      else if (k !== name || !previous) next[k] = v;
    }
    next[name] = server;
    this.writeMcp(next);
    return this.mcp();
  }

  deleteMcp(name: unknown): McpSummary[] {
    const all = readMcp(this.o.dir) ?? {};
    if (typeof name !== "string" || !all[name]) throw new Error("That MCP server is already gone.");
    delete all[name];
    this.writeMcp(all);
    return this.mcp();
  }

  /** off writes "enabled": false, as `spark mcp off` does; on drops it */
  setMcpEnabled(name: unknown, enabled: unknown): McpSummary[] {
    const all = readMcp(this.o.dir) ?? {};
    if (typeof name !== "string" || !all[name]) throw new Error("That MCP server is gone.");
    const server = { ...all[name] };
    if (enabled === false) server.enabled = false;
    else delete server.enabled;
    all[name] = server;
    this.writeMcp(all);
    return this.mcp();
  }

  // MARK: Copies

  snapshot(): LibrarySnapshot {
    const s = readJson(join(this.o.dir, "settings.json"));
    const providers = isObject(s.providers) ? (s.providers as Record<string, Json>) : {};
    const models = isObject(s.models) ? Object.fromEntries(Object.entries(s.models).filter(([k, v]) => typeof v === "string" && k in providers)) : {};
    const prompts = Object.fromEntries(Object.entries(this.readPrompts()).map(([k, v]) => [k, v.text]));
    const mcp = readMcp(this.o.dir);
    return { providers, models: models as Record<string, string>, provider: typeof s.provider === "string" ? s.provider : undefined, env: this.profile.env(), prompts, mcp };
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

export function readMcp(home: string): Record<string, Json> | undefined {
  const servers = readJson(join(home, "mcp.json")).mcpServers;
  return isObject(servers) ? Object.fromEntries(Object.entries(servers).filter(([, v]) => isObject(v))) : undefined;
}

/** spark takes any name a terminal can show */
const MCP_NAME = /^(?!\s)[^\x00-\x1f\x7f-\x9f]{1,64}(?<!\s)$/u;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
/** a value that only names a variable: it holds no secret, so the phone sees it whole */
const REFERENCE = /^\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}$/;

/** the server with each value that may be a secret left out, and its last 4 characters beside it */
function mcpSummary(name: string, server: Json): McpSummary {
  const out: Json = structuredClone(server);
  const hints: Record<string, string> = {};
  for (const field of ["env", "headers"]) {
    if (!isObject(out[field])) continue;
    for (const [k, v] of Object.entries(out[field] as Json)) {
      if (typeof v !== "string" || REFERENCE.test(v)) continue;
      out[field][k] = null;
      hints[`${field}.${k}`] = v.length > 8 ? v.slice(-4) : "";
    }
  }
  return { name, server: out, hints };
}

/**
 * A server as spark reads it: a `url` makes it an HTTP server with `headers`, otherwise it starts
 * `command` with `args` and `env`. Fields spark doesn't read are kept as they are.
 */
function checkMcp(raw: unknown, saved: Json | undefined): Json {
  if (!isObject(raw)) throw new Error("That MCP server has no settings.");
  const server: Json = structuredClone(raw);
  const pairs = (field: string, names: RegExp, what: string) => {
    if (server[field] === undefined) return;
    if (!isObject(server[field])) throw new Error(`An MCP server's ${what} are a list of names and values.`);
    const old = isObject(saved?.[field]) ? saved[field] : {};
    for (const [k, v] of Object.entries(server[field] as Json)) {
      if (!names.test(k)) throw new Error(`${k} isn't a valid ${what.replace(/s$/, "")} name.`);
      if (v === null) {
        if (typeof old[k] !== "string") throw new Error(`Enter a value for ${k}.`);
        server[field][k] = old[k];
      } else if (typeof v !== "string") {
        // spark skips a value that isn't text
        delete server[field][k];
      }
    }
    if (!Object.keys(server[field]).length) delete server[field];
  };
  if (typeof server.url === "string" || server.type === "http") {
    let url: URL;
    try {
      url = new URL(String(server.url ?? "").trim());
    } catch {
      throw new Error("An HTTP MCP server needs a URL, such as https://example.com/mcp.");
    }
    if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("An MCP server's URL starts with https:// or http://.");
    server.type = "http";
    server.url = String(server.url).trim();
    delete server.command;
    delete server.args;
    delete server.env;
    pairs("headers", /^[^\s:\x00-\x1f]+$/, "headers");
  } else {
    if (typeof server.command !== "string" || !server.command.trim()) throw new Error("An MCP server needs a command to run, or a URL.");
    server.command = server.command.trim();
    if (server.args !== undefined && (!Array.isArray(server.args) || server.args.some((a: unknown) => typeof a !== "string"))) throw new Error("An MCP server's arguments are text.");
    if (Array.isArray(server.args) && !server.args.length) delete server.args;
    delete server.type;
    delete server.url;
    delete server.headers;
    pairs("env", ENV_NAME, "variables");
  }
  if (server.enabled !== undefined && typeof server.enabled !== "boolean") throw new Error("enabled is true or false.");
  if (server.enabled === true) delete server.enabled;
  return server;
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
  if (snap.mcp !== undefined) {
    const path = join(home, "mcp.json");
    const current = readJson(path);
    if (fingerprint(current.mcpServers ?? null) !== fingerprint(snap.mcp)) {
      writeAtomic(path, { ...current, mcpServers: snap.mcp });
    }
  }
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
