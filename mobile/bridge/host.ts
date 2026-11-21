import { existsSync, readFileSync } from "node:fs";
import { mkdir, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { Acp } from "./acp";
import { type Library, promptFile } from "./library";
import { writeAtomic } from "./providers";
import { macSessions, type Running } from "./mac_sessions";
import type { PhoneSessions } from "./phone_sessions";
import type { Profile } from "./providers";
import type { ConfigOption, Event, Folder, HostInfo, Item, Permission, Request, SessionInfo, Snapshot } from "./protocol";

export type HostOptions = {
  info: HostInfo;
  /** the spark binary */
  spark: string;
  /** where the folder picker starts, and with `confine`, the only place sessions may run */
  root: string;
  confine?: boolean;
  /** read each time spark starts, so a provider the cloud just got reaches the next session */
  env?: () => Record<string, string | undefined>;
  /**
   * The Mac shows only sessions the phone started and sessions open in a spark process now. Without
   * this (the cloud), every session shows: they all came from the phone.
   */
  filter?: { phone: PhoneSessions; running: () => Promise<Running[]> };
  /** the providers in this host's spark profile */
  profile?: Profile;
  /** the cloud only: the shared providers and prompts, which the phone edits through it */
  library?: Library;
  /** the spark profile the library's prompts are copied into, and the file that remembers which prompt each session runs with */
  prompts?: { home: string; sessions: string };
  /** `to` is one device; without it, every device that can see this host */
  send: (event: Event, to?: string) => void;
};

const OUTPUT_TAIL = 6000;
const IDLE_MS = 30 * 60 * 1000;
const OPTIONS_MS = 5 * 60 * 1000;
/** session/list pages are 100; this walks up to 2,000 saved sessions to find the phone's */
const MAX_LIST_PAGES = 20;
/** spark prints these as agent text before the first answer; they're for the terminal, not the chat */
const NOISE = /^(skill discovery warning|\[context\])/;

/** one session with a spark process behind it */
class Live {
  acp: Acp;
  items: Item[] = [];
  index = new Map<string, number>();
  running = false;
  config: ConfigOption[] = [];
  permission: { p: Permission; rpc: number | string } | null = null;
  usage?: { used: number; size: number };
  touched = Date.now();
  loading = true;
  dirty = new Set<string>();
  flushTimer: ReturnType<typeof setTimeout> | null = null;
  lastRole: string | null = null;

  constructor(
    public id: string,
    public cwd: string,
    public title: string,
    public updatedAt: string,
    acp: Acp,
    public origin: SessionInfo["origin"],
  ) {
    this.acp = acp;
  }

  info(): SessionInfo {
    return { id: this.id, title: this.title, cwd: this.cwd, updatedAt: this.updatedAt, live: true, running: this.running, origin: this.origin };
  }

  snapshot(): Snapshot {
    return { ...this.info(), items: this.items, config: this.config, permission: this.permission?.p ?? null, usage: this.usage };
  }
}

export class Host {
  private live = new Map<string, Live>();
  private opening = new Map<string, Promise<Live>>();
  private sweeper: ReturnType<typeof setInterval>;

  constructor(private o: HostOptions) {
    this.sweeper = setInterval(() => this.sweep(), 5 * 60 * 1000);
  }

  stop() {
    clearInterval(this.sweeper);
    for (const l of this.live.values()) l.acp.kill();
    this.live.clear();
  }

  async handle(req: Request, from?: string) {
    try {
      const result = await this.run(req);
      this.o.send({ t: "reply", id: req.id, ok: true, result: result ?? null }, from);
    } catch (e) {
      this.o.send({ t: "reply", id: req.id, ok: false, error: e instanceof Error ? e.message : String(e) }, from);
    }
  }

  private async run(req: Request): Promise<unknown> {
    switch (req.op) {
      case "hello":
        return this.o.info;
      case "sessions":
        return this.sessions();
      case "open":
        return (await this.open(req.s)).snapshot();
      case "new":
        return (await this.create(req.cwd, req.prompt)).snapshot();
      case "prompt":
        return this.prompt(req.s, req.text, req.item);
      case "cancel": {
        const l = this.live.get(req.s);
        if (l) {
          if (l.permission) this.answer(l, l.permission.p.id, null);
          l.acp.notify("session/cancel", { sessionId: l.id });
        }
        return null;
      }
      case "config": {
        const l = await this.open(req.s);
        const r = await l.acp.call("session/set_config_option", { sessionId: l.id, configId: req.option, value: req.value });
        if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
        this.o.send({ t: "config", s: l.id, config: l.config });
        return l.config;
      }
      case "answer": {
        const l = this.live.get(req.s);
        if (l) this.answer(l, req.request, req.option);
        return null;
      }
      case "close": {
        const l = this.live.get(req.s);
        if (l && !l.running) {
          l.acp.kill();
          this.live.delete(l.id);
        }
        return null;
      }
      case "options":
        return this.options();
      case "folders":
        return this.folders(req.path);
      case "search":
        return this.search(req.query, req.path);
      case "sessionRename":
        return this.renameSession(req.s, req.title);
      case "sessionDelete":
        return this.deleteSession(req.s);
      case "providers":
        return this.o.library ? this.o.library.providers() : this.profile().list();
      case "providerExport":
        return this.profile().export(req.name);
      case "providerPut": {
        const list = this.o.library ? await this.o.library.putProvider(req) : await this.profile().put(req);
        this.invalidate();
        return list;
      }
      case "providerDelete": {
        const list = this.o.library ? await this.o.library.deleteProvider(req.name) : await this.profile().delete(req.name);
        this.invalidate();
        return list;
      }
      case "prompts":
        return this.library().prompts();
      case "promptPut":
        return this.library().putPrompt(req);
      case "promptDelete":
        return this.library().deletePrompt(req.name);
      case "mkdir": {
        const parent = await this.allowed(req.path);
        const path = join(parent, folderName(req.name));
        await mkdir(path);
        return path;
      }
      case "folderRename": {
        const from = await this.removable(req.path);
        const to = join(dirname(from), folderName(req.name));
        if (to === from) return to;
        if (existsSync(to)) throw new Error(`There's already a folder named ${basename(to)} there.`);
        await rename(from, to);
        return to;
      }
      case "folderDelete": {
        const path = await this.removable(req.path);
        await rm(path, { recursive: true, force: true });
        return dirname(path);
      }
    }
  }

  /** forgets what a new chat would start with, after its providers changed */
  invalidate() {
    this.defaults = undefined;
  }

  private library(): Library {
    if (!this.o.library) throw new Error("Prompts live in the cloud. Open them there.");
    return this.o.library;
  }

  // MARK: Sessions

  private env(): Record<string, string | undefined> {
    return this.o.env?.() ?? {};
  }

  private profile(): Profile {
    if (!this.o.profile) throw new Error("This host doesn't keep providers.");
    return this.o.profile;
  }

  /** every session spark has saved here, newest first; `complete` is false when the walk stopped early */
  private async saved(pages = MAX_LIST_PAGES): Promise<{ sessions: SessionInfo[]; complete: boolean }> {
    const acp = new Acp(this.o.spark, this.o.root, this.env());
    try {
      await acp.initialize();
      const sessions: SessionInfo[] = [];
      let cursor: string | undefined;
      for (let page = 0; page < pages; page++) {
        const r = await acp.call("session/list", cursor ? { cursor } : {});
        for (const s of r?.sessions ?? []) {
          sessions.push({ id: s.sessionId, title: s.title || "New session", cwd: s.cwd ?? "", updatedAt: s.updatedAt ?? "", live: false, running: false, origin: "phone" });
        }
        cursor = typeof r?.nextCursor === "string" ? r.nextCursor : undefined;
        if (!cursor) return { sessions, complete: true };
      }
      return { sessions, complete: false };
    } finally {
      acp.kill();
    }
  }

  private async sessions(): Promise<SessionInfo[]> {
    const live = [...this.live.values()].map((l) => l.info());
    let out: SessionInfo[];
    if (this.o.filter) {
      const { phone, running } = this.o.filter;
      // a failed live list hides terminal sessions for one refresh; it never hides the phone's
      const [saved, open] = await Promise.all([this.saved(), running().catch(() => [] as Running[])]);
      // spark saves a session at its first prompt, so one the bridge has open may not be listed yet
      if (saved.complete) phone.prune(new Set([...saved.sessions.map((s) => s.id), ...live.map((l) => l.id)]));
      out = macSessions(saved.sessions, phone.all(), open, live);
    } else {
      const saved = (await this.saved(1)).sessions;
      out = saved.map((s) => this.live.get(s.id)?.info() ?? s);
      for (const l of live) if (!out.some((s) => s.id === l.id)) out.unshift(l);
    }
    return out.sort((a, b) => Number(b.running) - Number(a.running) || b.updatedAt.localeCompare(a.updatedAt));
  }

  /**
   * What a new chat would start with (provider, model, effort, ...), before there is one. spark only
   * tells these to a session, so ask an empty one; spark doesn't keep a session nobody wrote in.
   */
  private async options(): Promise<ConfigOption[]> {
    if (this.defaults && Date.now() - this.defaults.at < OPTIONS_MS) return this.defaults.config;
    const acp = new Acp(this.o.spark, this.o.root, this.env());
    try {
      await acp.initialize();
      const r = await acp.call("session/new", { cwd: this.o.root, mcpServers: [] });
      const config: ConfigOption[] = Array.isArray(r?.configOptions) ? r.configOptions : [];
      this.defaults = { at: Date.now(), config };
      return config;
    } finally {
      acp.kill();
    }
  }

  private defaults?: { at: number; config: ConfigOption[] };

  private open(id: string): Promise<Live> {
    const l = this.live.get(id);
    if (l?.acp.alive) {
      l.touched = Date.now();
      return Promise.resolve(l);
    }
    const pending = this.opening.get(id);
    if (pending) return pending;
    const p = this.load(id).finally(() => this.opening.delete(id));
    this.opening.set(id, p);
    return p;
  }

  private async load(id: string): Promise<Live> {
    // any saved session may open, not only the shown ones: a terminal session that just closed stays tappable
    const known = (await this.saved()).sessions.find((s) => s.id === id);
    if (!known) throw new Error("That session is gone.");
    const cwd = existsSync(known.cwd) ? known.cwd : this.o.root;
    const acp = new Acp(this.o.spark, cwd, { ...this.env(), ...this.promptEnv(this.sessionPrompts()[id]) });
    const origin = !this.o.filter || this.o.filter.phone.all().has(id) ? "phone" : "mac";
    const l = new Live(id, cwd, known.title, known.updatedAt, acp, origin);
    this.wire(l);
    try {
      await acp.initialize();
      const r = await acp.call("session/load", { sessionId: id, cwd, mcpServers: [] });
      if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
    } catch (e) {
      acp.kill();
      throw e;
    }
    l.loading = false;
    this.live.set(id, l);
    return l;
  }

  /** what spark runs with for a session that uses library prompt `name` */
  private promptEnv(name?: string): Record<string, string> {
    if (!name) return {};
    const file = this.o.prompts ? promptFile(this.o.prompts.home, name) : null;
    return file ? { SPARK_SYSTEM_PROMPT_FILE: file } : {};
  }

  private sessionPrompts(): Record<string, string> {
    if (!this.o.prompts) return {};
    try {
      const parsed = JSON.parse(readFileSync(this.o.prompts.sessions, "utf8"));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }

  private rememberPrompt(id: string, name?: string) {
    if (!this.o.prompts) return;
    const all = this.sessionPrompts();
    if (name) all[id] = name;
    else if (!(id in all)) return;
    else delete all[id];
    writeAtomic(this.o.prompts.sessions, all);
  }

  private async create(path: string, prompt?: string): Promise<Live> {
    const cwd = await this.allowed(path);
    const env = this.promptEnv(prompt);
    if (prompt && !env.SPARK_SYSTEM_PROMPT_FILE) throw new Error(`The prompt ${prompt} hasn't reached this host yet.`);
    const acp = new Acp(this.o.spark, cwd, { ...this.env(), ...env });
    const l = new Live("", cwd, "New session", new Date().toISOString(), acp, "phone");
    this.wire(l);
    try {
      await acp.initialize();
      const r = await acp.call("session/new", { cwd, mcpServers: [] });
      l.id = r.sessionId;
      if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
      this.o.filter?.phone.add(l.id);
      this.rememberPrompt(l.id, prompt);
    } catch (e) {
      acp.kill();
      throw e;
    }
    l.loading = false;
    this.live.set(l.id, l);
    return l;
  }

  private async renameSession(id: string, raw: string) {
    const title = String(raw ?? "").trim();
    if (!title || title.length > 200 || /[\r\n]/.test(title)) throw new Error("A title is one line of 1 to 200 characters.");
    const l = await this.open(id);
    await l.acp.call("_spark/session/rename", { sessionId: l.id, title });
    l.title = title;
    l.updatedAt = new Date().toISOString();
    this.o.send({ t: "info", s: l.id, title: l.title, updatedAt: l.updatedAt });
    return null;
  }

  private async deleteSession(id: string) {
    const l = this.live.get(id);
    if (l?.running) throw new Error("spark is still working in that session. Stop it first.");
    if (l) {
      this.live.delete(id);
      await l.acp.stop();
    }
    const acp = new Acp(this.o.spark, this.o.root, this.env());
    try {
      await acp.initialize();
      // the bridge's own spark for it has only just exited; its lock can take a moment to go
      for (let attempt = 0; ; attempt++) {
        try {
          await acp.call("session/remove", { sessionId: id });
          break;
        } catch (e) {
          if (attempt >= 4 || !String(e instanceof Error ? e.message : e).includes("another spark")) throw e;
          await Bun.sleep(250);
        }
      }
    } finally {
      acp.kill();
    }
    this.o.filter?.phone.remove(id);
    this.rememberPrompt(id);
    return null;
  }

  /** `item` is the id the phone already shows the message under */
  private async prompt(id: string, text: string, item?: string) {
    const l = await this.open(id);
    if (l.running) throw new Error("spark is still working on the last message.");
    const body = text.trim();
    if (!body) return null;
    l.touched = Date.now();
    const shown = typeof item === "string" && /^[A-Za-z0-9-]{8,64}$/.test(item) && !l.index.has(item) ? item : crypto.randomUUID();
    this.upsert(l, { id: shown, role: "user", text: body });
    this.setRunning(l, true);
    l.acp
      .call("session/prompt", { sessionId: l.id, prompt: [{ type: "text", text: body }] })
      .then((r) => this.setRunning(l, false, r?.stopReason))
      .catch((e) => this.setRunning(l, false, "error", e instanceof Error ? e.message : String(e)));
    return null;
  }

  private setRunning(l: Live, running: boolean, reason?: string, error?: string) {
    l.running = running;
    l.touched = Date.now();
    if (!running) {
      this.flush(l);
      l.lastRole = null;
    }
    this.o.send({ t: "state", s: l.id, running, reason, error });
  }

  private answer(l: Live, request: string, option: string | null) {
    if (!l.permission || l.permission.p.id !== request) return;
    l.acp.respond(l.permission.rpc, { outcome: option ? { outcome: "selected", optionId: option } : { outcome: "cancelled" } });
    l.permission = null;
    this.o.send({ t: "permission", s: l.id, permission: null });
  }

  private sweep() {
    const now = Date.now();
    for (const l of this.live.values()) {
      if (!l.running && !l.permission && now - l.touched > IDLE_MS) {
        l.acp.kill();
        this.live.delete(l.id);
      }
    }
  }

  // MARK: ACP → items

  private wire(l: Live) {
    l.acp.onNotify = (method, params) => {
      if (method === "session/update") this.update(l, params?.update ?? {});
    };
    l.acp.onRequest = (rpc, method, params) => {
      if (method !== "session/request_permission") return l.acp.respond(rpc, null);
      const call = params?.toolCall ?? {};
      const p: Permission = {
        id: crypto.randomUUID(),
        title: call.title || call.name || "Run a tool",
        detail: describe(call.rawInput),
        kind: call.kind,
        options: params?.options ?? [],
      };
      l.permission = { p, rpc };
      this.o.send({ t: "permission", s: l.id, permission: p });
    };
    l.acp.onExit = () => {
      if (this.live.get(l.id) === l) this.live.delete(l.id);
      if (l.running) this.setRunning(l, false, "error", "spark stopped.");
    };
  }

  private update(l: Live, u: any) {
    switch (u.sessionUpdate) {
      case "user_message_chunk":
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        const text = u.content?.type === "text" ? String(u.content.text ?? "") : "";
        if (!text) return;
        const role = u.sessionUpdate === "user_message_chunk" ? "user" : u.sessionUpdate === "agent_thought_chunk" ? "thought" : "assistant";
        if (role === "assistant" && NOISE.test(text)) return;
        // a turn spark started on its own keeps the same id across chunks; without one, chunks join the last item of that role
        const last = l.items[l.items.length - 1];
        const id = u.messageId ? `${role}:${u.messageId}` : last && last.role === role && l.lastRole === role ? last.id : crypto.randomUUID();
        const i = l.index.get(id);
        if (i === undefined) this.upsert(l, { id, role, text });
        else {
          l.items[i].text += text;
          if (!l.loading) this.o.send({ t: "append", s: l.id, id, text });
        }
        l.lastRole = role;
        return;
      }
      case "tool_call": {
        l.lastRole = "tool";
        const id = String(u.toolCallId);
        const prior = l.index.get(id);
        const item: Item = {
          ...(prior === undefined ? {} : l.items[prior]),
          id,
          role: "tool",
          text: "",
          name: u.name,
          title: u.title,
          kind: u.kind,
          status: u.status ?? "pending",
          detail: describe(u.rawInput),
        };
        this.upsert(l, item);
        return;
      }
      case "tool_call_update": {
        const i = l.index.get(String(u.toolCallId));
        if (i === undefined) return;
        const t = l.items[i];
        const text = contentText(u.content);
        const changed = u.status && u.status !== t.status;
        if (u.status) t.status = u.status;
        if (u.title && u.title !== "Running") t.title = u.title;
        if (text) {
          const done = u.status === "completed" || u.status === "failed";
          const out = done ? text : (t.output ?? "") + text;
          t.output = out.length > OUTPUT_TAIL ? out.slice(-OUTPUT_TAIL) : out;
        }
        if (l.loading) return;
        if (changed) this.o.send({ t: "item", s: l.id, item: t });
        else this.later(l, t.id);
        return;
      }
      case "notice": {
        const text = String(u.text ?? u.message ?? u.content?.text ?? "");
        if (text) this.upsert(l, { id: crypto.randomUUID(), role: "notice", text });
        return;
      }
      case "session_info_update":
        if (u.title) l.title = u.title;
        if (u.updatedAt) l.updatedAt = u.updatedAt;
        if (!l.loading) this.o.send({ t: "info", s: l.id, title: l.title, updatedAt: l.updatedAt });
        return;
      case "usage_update":
        if (typeof u.used === "number" && typeof u.size === "number") {
          l.usage = { used: u.used, size: u.size };
          if (!l.loading) this.o.send({ t: "usage", s: l.id, used: u.used, size: u.size });
        }
        return;
      case "config_option_update":
        if (Array.isArray(u.configOptions)) {
          l.config = u.configOptions;
          if (!l.loading) this.o.send({ t: "config", s: l.id, config: l.config });
        }
        return;
    }
  }

  private upsert(l: Live, item: Item) {
    const i = l.index.get(item.id);
    if (i === undefined) {
      l.index.set(item.id, l.items.length);
      l.items.push(item);
    } else {
      l.items[i] = item;
    }
    if (!l.loading) this.o.send({ t: "item", s: l.id, item });
  }

  /** tool output arrives a line at a time; the phone gets it a few times a second */
  private later(l: Live, id: string) {
    l.dirty.add(id);
    l.flushTimer ??= setTimeout(() => this.flush(l), 150);
  }

  private flush(l: Live) {
    if (l.flushTimer) clearTimeout(l.flushTimer);
    l.flushTimer = null;
    for (const id of l.dirty) {
      const i = l.index.get(id);
      if (i !== undefined) this.o.send({ t: "item", s: l.id, item: l.items[i] });
    }
    l.dirty.clear();
  }

  // MARK: Folders

  /** a real, existing folder the phone may use; inside the root when the host is confined */
  private async allowed(path?: string): Promise<string> {
    const wanted = resolve(path && path.length > 0 ? path.replace(/^~(?=$|\/)/, this.o.root) : this.o.root);
    let real: string;
    try {
      real = await realpath(wanted);
    } catch {
      throw new Error("That folder doesn't exist.");
    }
    if (!(await stat(real)).isDirectory()) throw new Error("That isn't a folder.");
    if (this.o.confine) {
      const root = await realpath(this.o.root);
      if (real !== root && !real.startsWith(root + sep)) throw new Error("That folder is outside this host.");
    }
    return real;
  }

  /** a folder the phone may rename or delete: never the host's root, the home folder, or what holds them */
  private async removable(path: string): Promise<string> {
    if (!path) throw new Error("Choose a folder.");
    const real = await this.allowed(path);
    const root = await realpath(this.o.root);
    const home = await realpath(homedir()).catch(() => homedir());
    for (const keep of [root, home]) {
      if (real === keep || keep.startsWith(real + sep)) throw new Error("spark won't change that folder.");
    }
    if (dirname(real) === home && PROTECTED.has(basename(real))) throw new Error("spark won't change that folder.");
    if (real.split(sep).filter(Boolean).length < 2) throw new Error("spark won't change that folder.");
    return real;
  }

  /** folders under `path` whose name contains `query`, nearest first, within a time budget */
  private async search(query: string, path?: string): Promise<Folder[]> {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const start = await this.allowed(path);
    const until = Date.now() + 1500;
    const found: Folder[] = [];
    let level = [start];
    for (let depth = 0; depth < 6 && level.length && found.length < 60 && Date.now() < until; depth++) {
      const next: string[] = [];
      for (const dir of level) {
        if (Date.now() > until || found.length >= 60) break;
        const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
        for (const e of entries) {
          if (!e.isDirectory() || e.name.startsWith(".") || SKIP.has(e.name)) continue;
          const full = join(dir, e.name);
          if (e.name.toLowerCase().includes(q)) found.push({ name: e.name, path: full, git: existsSync(join(full, ".git")) });
          next.push(full);
        }
      }
      level = next;
    }
    // exact and prefix matches first, then shallower paths
    const rank = (f: Folder) => (f.name.toLowerCase() === q ? 0 : f.name.toLowerCase().startsWith(q) ? 1 : 2);
    return found.sort((a, b) => rank(a) - rank(b) || a.path.split(sep).length - b.path.split(sep).length).slice(0, 40);
  }

  private async folders(path?: string): Promise<{ path: string; name: string; parent: string | null; folders: Folder[] }> {
    const dir = await this.allowed(path);
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    const folders: Folder[] = [];
    for (const e of entries) {
      if (folders.length >= 500) break;
      if (e.name.startsWith(".")) continue;
      const full = join(dir, e.name);
      let isDir = e.isDirectory();
      if (e.isSymbolicLink()) isDir = await stat(full).then((s) => s.isDirectory()).catch(() => false);
      if (!isDir) continue;
      folders.push({ name: e.name, path: full, git: existsSync(join(full, ".git")) });
    }
    folders.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }));
    const root = await realpath(this.o.root);
    const top = this.o.confine ? dir === root : dir === sep;
    return { path: dir, name: dir === root ? "Home" : basename(dir), parent: top ? null : dirname(dir), folders };
  }
}

/** the home folders macOS makes; the phone can't rename or delete them */
const PROTECTED = new Set(["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]);

function folderName(raw: unknown): string {
  const name = typeof raw === "string" ? raw.trim() : "";
  if (!name || name.length > 255 || /[/\\\0]/.test(name) || name.startsWith(".")) throw new Error("That isn't a folder name.");
  return name;
}

/** folders a search never walks into: big, generated, or not the user's projects */
const SKIP = new Set(["node_modules", "Library", "Applications", "Pictures", "Music", "Movies", "build", "dist", "target", "vendor", "Pods", "DerivedData", "venv", "__pycache__"]);

function describe(input: any): string | undefined {
  if (!input || typeof input !== "object") return undefined;
  const v = input.command ?? input.cmd ?? input.path ?? input.file_path ?? input.filePath ?? input.pattern ?? input.query ?? input.url ?? input.name;
  if (typeof v === "string") return v.length > 400 ? v.slice(0, 400) + "…" : v;
  if (Array.isArray(v)) return v.join(" ");
  return undefined;
}

function contentText(content: any): string {
  if (!Array.isArray(content)) return "";
  let out = "";
  for (const c of content) {
    if (c?.type === "content" && c.content?.type === "text") out += c.content.text ?? "";
    else if (c?.type === "diff") out += `${c.path ?? "file"} changed\n`;
  }
  return out;
}
