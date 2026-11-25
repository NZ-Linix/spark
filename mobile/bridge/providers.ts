import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Acp, deadline } from "./acp";
import type { ProviderExport, ProviderSummary } from "./protocol";

/** spark's own rule for a connection's name (`InvalidProviderId` in configured_provider.zig) */
const NAME = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
/** spark's own rule for a variable's name (`environment_name` in configured_provider.zig) */
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;
/** variables that change how a process runs rather than what a provider sends; the phone never sets these */
const RESERVED_ENV = /^(PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|PWD|LANG|LC_\w*|LD_\w*|DYLD_\w*|SPARK_\w*|BUN_\w*|NODE_\w*)$/;
const MAX_VALUE_BYTES = 8192;
const MAX_MODEL_BYTES = 256;
const CHECK_MS = 15_000;
const SHELL_MS = 5_000;

export type Json = Record<string, any>;

export type ProfileOptions = {
  /** the SPARK_HOME whose settings.json holds the providers */
  home: string;
  spark: string;
  /** both list, add, change and delete; only "mac" exports, and only "cloud" keeps header values in cloud-env.json */
  role: "mac" | "cloud";
  /** how the Mac finds a variable the bridge wasn't started with (a LaunchAgent gets almost none) */
  lookup?: (name: string) => Promise<string | undefined>;
};

export const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
export const isLocalProvider = (name: string, value?: unknown) => name.startsWith("chatgpt-plan-") || (isObject(value) && value.auth?.type === "chatgpt-plan");

/** the last 4 characters, and only when the key is long enough that they give little away */
function mask(key: unknown): string | undefined {
  if (typeof key !== "string" || !key) return undefined;
  return key.length >= 12 ? `…${key.slice(-4)}` : "…";
}

/** every variable a provider reads: its bearer key and its header values */
function variables(p: Json): string[] {
  const out: string[] = [];
  if (p.auth?.type === "bearer" && typeof p.auth.env === "string") out.push(p.auth.env);
  if (isObject(p.headers)) for (const h of Object.values(p.headers)) if (isObject(h) && typeof h.env === "string") out.push(h.env);
  return out;
}

function headerVariables(p: Json): string[] {
  if (!isObject(p.headers)) return [];
  return Object.values(p.headers).flatMap((h) => (isObject(h) && typeof h.env === "string" ? [h.env] : []));
}

/**
 * One spark profile's providers, read from and written to its settings.json. Each provider is kept
 * whole, as spark wrote it, so a field this file doesn't know about is never lost.
 */
export class Profile {
  private queue: Promise<unknown> = Promise.resolve();
  private accountJob = false;

  constructor(private o: ProfileOptions) {}

  private get settingsFile() {
    return join(this.o.home, "settings.json");
  }

  /** the cloud's values for the variables its providers read, which only the cloud's spark sees */
  private get secretsFile() {
    return join(this.o.home, "cloud-env.json");
  }

  list(): ProviderSummary[] {
    const s = this.read();
    const providers = isObject(s.providers) ? s.providers : {};
    return Object.entries(providers)
      .filter(([name, p]) => isObject(p) && !isLocalProvider(name, p))
      .map(([name, p]) => summarize(name, p as Json, s))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  accounts(): ProviderSummary[] {
    if (this.o.role !== "mac") throw new Error("ChatGPT plans are available only on your paired Mac.");
    const s = this.read();
    const providers = isObject(s.providers) ? s.providers : {};
    return Object.entries(providers).flatMap(([name, p]) => isObject(p) && p.auth?.type === "chatgpt-plan" ? [summarize(name, p, s)] : []);
  }

  async changeAccount(action: unknown, value: unknown): Promise<{ accounts: ProviderSummary[]; warning?: string }> {
    if (this.o.role !== "mac") throw new Error("ChatGPT plans are available only on your paired Mac.");
    if (this.accountJob) throw new Error("A ChatGPT account change is already in progress on this Mac.");
    if (action !== "connect" && action !== "reconnect" && action !== "remove") throw new Error("Unknown account action.");
    if (typeof value !== "string" || (action === "connect" ? Buffer.byteLength(value) > 48 || /[\u0000-\u001f\u007f]/.test(value) : !/^chatgpt-plan-[0-9a-f]{32}$/.test(value))) throw new Error("Invalid ChatGPT account label or ID.");
    this.accountJob = true;
    try {
      const child = Bun.spawn([this.o.spark, "provider", "chatgpt-account", action, value], {
        env: { ...process.env, SPARK_HOME: this.o.home }, stdin: "ignore", stdout: "ignore", stderr: "pipe",
        timeout: 330_000,
      });
      const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
      const detail = stderr.trim().replace(/^spark provider: /, "");
      if (code !== 0) throw new Error(detail || "Could not update the ChatGPT account on this Mac.");
      return { accounts: this.accounts(), warning: detail || undefined };
    } finally {
      this.accountJob = false;
    }
  }

  /** the variables the cloud's spark runs with */
  env(): Record<string, string> {
    if (this.o.role !== "cloud") return {};
    try {
      const parsed = JSON.parse(readFileSync(this.secretsFile, "utf8"));
      if (!isObject(parsed)) return {};
      return Object.fromEntries(Object.entries(parsed).filter(([k, v]) => typeof v === "string" && ENV_NAME.test(k) && !RESERVED_ENV.test(k))) as Record<string, string>;
    } catch {
      // none saved yet
      return {};
    }
  }

  /**
   * A provider ready for another machine: whole, with its bearer key and header values read from
   * this Mac's environment, because the cloud doesn't have it.
   */
  async export(name: string): Promise<ProviderExport> {
    if (this.o.role !== "mac") throw new Error("Only a Mac can copy its providers.");
    const s = this.read();
    const found = isObject(s.providers) ? s.providers[name] : undefined;
    if (!isObject(found)) throw new Error(`There's no provider named ${name} on this Mac.`);
    if (isLocalProvider(name, found)) throw new Error("Subscription accounts stay on this Mac.");
    const provider: Json = structuredClone(found);
    const env: Record<string, string> = {};
    const missing: string[] = [];
    let keyFrom: string | undefined;
    if (provider.auth?.type === "bearer") {
      keyFrom = String(provider.auth.env ?? "");
      const key = await this.resolve(keyFrom);
      if (key) provider.auth = { type: "key", key };
      else missing.push(keyFrom);
    }
    for (const v of headerVariables(provider)) {
      const value = await this.resolve(v);
      if (value) env[v] = value;
      else missing.push(v);
    }
    if (missing.length) {
      throw new Error(`${missing.join(", ")} ${missing.length > 1 ? "aren't" : "isn't"} set on this Mac, so ${name} wouldn't work in the cloud.`);
    }
    const model = isObject(s.models) && typeof s.models[name] === "string" ? s.models[name] : undefined;
    return { name, provider, model, env, keyFrom };
  }

  private async resolve(name: string): Promise<string | undefined> {
    if (!ENV_NAME.test(name)) return undefined;
    const v = process.env[name] ?? (await this.o.lookup?.(name));
    const trimmed = v?.trim();
    return trimmed ? trimmed : undefined;
  }

  /**
   * Adds or replaces a provider. spark checks the whole new settings file first, so a provider spark
   * would refuse never replaces a working one. A key left out keeps the saved key. `previous` renames
   * a provider: the old name goes, and the saved model and chosen provider follow it.
   */
  put(input: { name: string; provider: unknown; model?: unknown; env?: unknown; previous?: unknown }): Promise<ProviderSummary[]> {
    const { name, provider, model, env, previous } = input;
    if (this.o.role !== "cloud" && env !== undefined && env !== null && isObject(env) && Object.keys(env).length) return Promise.reject(new Error("The Mac reads header values from its own environment."));
    if (previous !== undefined && previous !== null && (typeof previous !== "string" || !NAME.test(previous))) return Promise.reject(new Error("That old name isn't valid."));
    if (typeof name !== "string" || !NAME.test(name)) return Promise.reject(new Error("A provider's name starts with a letter and uses letters, digits, _ and -."));
    if (!isObject(provider)) return Promise.reject(new Error("That provider isn't an object."));
    if (isLocalProvider(name, provider) || (typeof previous === "string" && isLocalProvider(previous))) return Promise.reject(new Error("Subscription accounts aren't part of the provider library."));
    if (model !== undefined && model !== null && (typeof model !== "string" || model.length > MAX_MODEL_BYTES)) return Promise.reject(new Error("That model name isn't valid."));
    let values: Record<string, string>;
    try {
      values = checkEnv(env);
    } catch (e) {
      return Promise.reject(e);
    }
    return this.serial(async () => {
      const s = this.read();
      s.providers = isObject(s.providers) ? s.providers : {};
      const next: Json = structuredClone(provider);
      const renamed = typeof previous === "string" && previous !== name ? previous : undefined;
      if (renamed && isObject(s.providers[name])) throw new Error(`There's already a provider named ${name}.`);
      const old = s.providers[renamed ?? name];
      if (renamed) {
        delete s.providers[renamed];
        if (isObject(s.models) && typeof s.models[renamed] === "string") {
          s.models[name] = s.models[renamed];
          delete s.models[renamed];
        }
        if (s.provider === renamed) s.provider = name;
      }
      if (isObject(next.auth) && next.auth.type === "key" && !next.auth.key && isObject(old) && old.auth?.type === "key") next.auth.key = old.auth.key;
      s.providers[name] = next;
      if (isObject(s.models) && typeof s.models[name] === "string" && !(isObject(next.model_metadata) && s.models[name] in next.model_metadata)) delete s.models[name];
      if (typeof model === "string" && model) {
        s.models = isObject(s.models) ? s.models : {};
        s.models[name] = model;
      }
      // a profile with no provider chosen starts its chats on the first one it gets
      if (typeof s.provider !== "string" || !isObject(s.providers[s.provider])) s.provider = name;
      chooseModel(s);
      await this.save(s, { ...this.env(), ...values });
      return this.list();
    });
  }

  delete(name: unknown): Promise<ProviderSummary[]> {
    return this.serial(async () => {
      const s = this.read();
      if (typeof name !== "string" || !isObject(s.providers) || !isObject(s.providers[name])) throw new Error("That provider is already gone.");
      if (isLocalProvider(name, s.providers[name])) throw new Error("Disconnect this account on your Mac instead.");
      delete s.providers[name];
      if (isObject(s.models)) delete s.models[name];
      if (s.provider === name) {
        const first = Object.keys(s.providers).sort()[0];
        if (first) s.provider = first;
        else delete s.provider;
      }
      chooseModel(s);
      await this.save(s, this.env());
      return this.list();
    });
  }

  private serial<T>(f: () => Promise<T>): Promise<T> {
    const p = this.queue.then(f, f);
    this.queue = p.catch(() => {});
    return p;
  }

  private read(): Json {
    if (!existsSync(this.settingsFile)) return {};
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(this.settingsFile, "utf8"));
    } catch {
      throw new Error("The settings file there isn't valid JSON, so spark left it alone.");
    }
    if (!isObject(parsed)) throw new Error("The settings file there isn't a JSON object, so spark left it alone.");
    return parsed;
  }

  /** checks `settings` with spark, then replaces both files; values no provider reads are dropped */
  private async save(settings: Json, values: Record<string, string>) {
    const used = new Set(Object.values(isObject(settings.providers) ? settings.providers : {}).flatMap((p) => (isObject(p) ? variables(p) : [])));
    const secrets = Object.fromEntries(Object.entries(values).filter(([k]) => used.has(k)));
    // The Mac's spark reads these from the person's shell, which the check can't see, so it stands
    // in a value: the check is of the settings, not of whether a variable is set right now.
    const checked = this.o.role === "mac" ? Object.fromEntries([...used].filter((k) => ENV_NAME.test(k) && !RESERVED_ENV.test(k)).map((k) => [k, "set-on-the-mac"])) : secrets;
    await this.check(settings, checked);
    writeAtomic(this.settingsFile, settings);
    if (this.o.role === "cloud") writeAtomic(this.secretsFile, secrets);
  }

  /** spark loads the settings at `initialize` and refuses ones it can't use; its reason goes to the phone */
  private async check(settings: Json, secrets: Record<string, string>) {
    const dir = mkdtempSync(join(this.o.home, ".check-"));
    try {
      writeFileSync(join(dir, "settings.json"), JSON.stringify(settings), { mode: 0o600 });
      const acp = new Acp(this.o.spark, dir, { ...secrets, SPARK_HOME: dir });
      try {
        await deadline(acp.initialize(), CHECK_MS, "spark took too long to check the provider.");
      } catch (e) {
        const why = (e instanceof Error ? e.message : String(e)).replace(/^\$SPARK_HOME\/settings\.json: /, "");
        throw new Error(`spark refused it: ${why}`);
      } finally {
        acp.kill();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
}

function summarize(name: string, p: Json, s: Json): ProviderSummary {
  const auth = p.auth?.type === "key" || p.auth?.type === "bearer" ? p.auth.type : "none";
  const shown: Json = structuredClone(p);
  if (isObject(shown.auth) && shown.auth.type === "key") shown.auth = { type: "key" };
  return {
    name,
    displayName: typeof p.display_name === "string" && p.display_name ? p.display_name : undefined,
    protocol: typeof p.protocol === "string" ? p.protocol : "",
    baseUrl: typeof p.base_url === "string" ? p.base_url : "",
    auth,
    keyHint: auth === "key" ? mask(p.auth.key) : undefined,
    keyEnv: auth === "bearer" && typeof p.auth.env === "string" ? p.auth.env : undefined,
    headerEnv: headerVariables(p),
    models: isObject(p.model_metadata) ? Object.keys(p.model_metadata) : [],
    model: isObject(s.models) && typeof s.models[name] === "string" ? s.models[name] : undefined,
    active: s.provider === name,
    provider: shown,
  };
}

/** spark won't start on a chosen provider with no saved model, so it gets its first listed one */
export function chooseModel(s: Json) {
  const p = typeof s.provider === "string" && isObject(s.providers) ? s.providers[s.provider] : undefined;
  if (!isObject(p) || (isObject(s.models) && typeof s.models[s.provider] === "string")) return;
  const first = isObject(p.model_metadata) ? Object.keys(p.model_metadata)[0] : undefined;
  if (!first) return;
  s.models = isObject(s.models) ? s.models : {};
  s.models[s.provider] = first;
}

function checkEnv(env: unknown): Record<string, string> {
  if (env === undefined || env === null) return {};
  if (!isObject(env)) throw new Error("Those variables aren't an object.");
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) {
    if (!ENV_NAME.test(k) || RESERVED_ENV.test(k)) throw new Error(`The cloud can't set ${k}.`);
    if (typeof v !== "string" || !v || v.length > MAX_VALUE_BYTES || /[\0\r\n]/.test(v)) throw new Error(`The value for ${k} isn't valid.`);
    out[k] = v;
  }
  return out;
}

/** replaces `file` with an atomic rename, readable only by its owner */
export function writeAtomic(file: string, value: unknown) {
  const tmp = `${file}.${process.pid}.tmp`;
  rmSync(tmp, { force: true });
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, file);
}

/**
 * A variable from the person's login shell. The bridge runs as a LaunchAgent with almost no
 * environment, so a key exported in ~/.zshrc is only found this way. The name is passed as an
 * argument, never spliced into the command.
 */
export async function loginShellVariable(name: string): Promise<string | undefined> {
  if (!ENV_NAME.test(name)) return undefined;
  const shell = process.env.SHELL || "/bin/zsh";
  const proc = Bun.spawn([shell, "-ilc", 'printf "\\n__SPARK__%s__SPARK__\\n" "$(printenv "$1")"', "spark-bridge", name], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  });
  const timer = setTimeout(() => proc.kill(), SHELL_MS);
  try {
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return out.match(/__SPARK__([\s\S]*?)__SPARK__/)?.[1] || undefined;
  } finally {
    clearTimeout(timer);
  }
}
