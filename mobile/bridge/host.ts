import { type ChildProcess, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { lstat, mkdir, open, readdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, extname, join, resolve, sep } from "node:path";
import { Acp } from "./acp";
import { type Library, promptFile, readMcp, fingerprint } from "./library";
import { writeAtomic } from "./providers";
import { macSessions, type Running } from "./mac_sessions";
import { describe, historyItems, readSession } from "./session_view";
import type { PhoneSessions } from "./phone_sessions";
import { type TerminalSessions, type TerminalView } from "./terminal_sessions";
import type { Profile } from "./providers";
import type { ConfigOption, Event, FileContent, FileData, FileEntry, FileListing, Folder, HostInfo, Item, Permission, Request, SessionInfo, Snapshot } from "./protocol";

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
  terminal?: TerminalSessions;
  /** the cloud only: the shared providers and prompts, which the phone edits through it */
  library?: Library;
  /** the spark profile the library's prompts are copied into, and the file that remembers which prompt each session runs with */
  prompts?: { home: string; sessions: string };
  /**
   * Where chats started without a folder get one each, and the file that remembers whose is whose.
   * Defaults to a hidden folder in the root, so a confined host's chats stay inside it.
   */
  scratch?: string;
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
  mcpStamp = "";
  preparing = false;

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
  private attached = new Map<string, { held: Running; committed: number; owner: string; items: Item[]; historyLength: number }>();
  private sweeper: ReturnType<typeof setInterval>;
  /** terminal commands running now, by the phone's id for each */
  private terms = new Map<string, ChildProcess>();

  /** the real path of the folder that holds each folderless chat's own folder */
  private scratch: string;

  constructor(private o: HostOptions) {
    this.sweeper = setInterval(() => this.sweep(), 5 * 60 * 1000);
    const scratch = o.scratch ?? join(o.root, ".spark-chats");
    mkdirSync(scratch, { recursive: true, mode: 0o700 });
    this.scratch = realpathSync(scratch);
  }

  stop() {
    clearInterval(this.sweeper);
    for (const l of this.live.values()) l.acp.kill();
    this.live.clear();
    this.attached.clear();
    for (const p of this.terms.values()) killGroup(p, "SIGKILL");
    this.terms.clear();
  }

  async handle(req: Request, from?: string) {
    try {
      const result = await this.run(req, from);
      this.o.send({ t: "reply", id: req.id, ok: true, result: result ?? null }, from);
    } catch (e) {
      this.o.send({ t: "reply", id: req.id, ok: false, error: e instanceof Error ? e.message : String(e) }, from);
    }
  }

  private async run(req: Request, from?: string): Promise<unknown> {
    switch (req.op) {
      case "hello":
        return this.o.info;
      case "sessions":
        return this.sessions();
      case "open":
        return this.withPrompt(this.marked(await this.show(req.s)));
      case "watchTerminal": {
        const held = this.attached.get(req.s)?.held;
        const view = held && await this.o.terminal?.view(req.s);
        if (view && view.revision === req.revision) return null;
        if (view) return this.withPrompt(this.marked(await this.terminalView(held, view)));
        this.attached.delete(req.s);
        return this.withPrompt(this.marked(await this.show(req.s)));
      }
      case "new":
        return this.view(await this.create(req.cwd, req.prompt, req.mcpDisabled));
      case "mcpServers":
        return this.mcpNames();
      case "sessionMcp": {
        const l = await this.open(req.s);
        if (l.running || l.preparing) throw new Error("Change MCP servers after spark finishes its turn.");
        const disabled = this.cleanMcp(req.disabled);
        this.rememberMcp(l.id, disabled);
        return disabled;
      }
      case "rewind":
        return this.rewind(req.s, req.item, req.keep === true);
      case "sessionPrompt":
        return this.setPrompt(req.s, req.prompt);
      case "prompt":
        if (req.terminalOwner) return this.controlTerminal(req.s, req.terminalOwner, "prompt", req.text);
        return this.prompt(req.s, req.text, req.item);
      case "cancel": {
        if (req.terminalOwner) return this.controlTerminal(req.s, req.terminalOwner, "cancel");
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
        return this.options(req.provider);
      case "folders":
        return this.folders(req.path);
      case "search":
        return this.search(req.query, req.path);
      case "files":
        return this.files(req.path);
      case "file":
        return this.file(req.path);
      case "fileData":
        return this.fileData(req.path, req.offset ?? 0);
      case "fileWrite":
        return this.writeFile(req.path, req.text, req.modified);
      case "fileCreate": {
        const parent = await this.allowed(req.path);
        const path = join(parent, entryName(req.name));
        if (existsSync(path)) throw new Error(`There's already something named ${basename(path)} there.`);
        if (req.dir) await mkdir(path);
        else await writeFile(path, "", { flag: "wx" });
        return path;
      }
      case "entryRename": {
        const from = await this.entry(req.path);
        const to = join(dirname(from), entryName(req.name));
        if (to === from) return to;
        if (existsSync(to)) throw new Error(`There's already something named ${basename(to)} there.`);
        await rename(from, to);
        return to;
      }
      case "entryDelete": {
        const path = await this.entry(req.path);
        await rm(path, { recursive: true, force: true });
        return dirname(path);
      }
      case "run":
        return this.command(req.run, req.cwd, req.command, from);
      case "runStop": {
        const p = this.terms.get(req.run);
        if (p) {
          killGroup(p, "SIGINT");
          setTimeout(() => this.terms.get(req.run) === p && killGroup(p, "SIGKILL"), 2000).unref?.();
        }
        return null;
      }
      case "sessionRename":
        return this.renameSession(req.s, req.title);
      case "sessionDelete":
        return this.deleteSession(req.s);
      case "providers":
        return this.o.library ? this.o.library.providers() : this.profile().list();
      // `chatgptAccount(s)` are what app builds before Claude and Antigravity send.
      case "planAccounts":
      case "chatgptAccounts":
        return (this.o.library ?? this.profile()).accounts(req.op === "planAccounts" ? req.plan : "chatgpt");
      case "planAccount":
      case "chatgptAccount": {
        const plan = req.op === "planAccount" ? req.plan : "chatgpt";
        const result = this.o.library ? await this.o.library.removeAccount(plan, req.action, req.value) : await this.profile().changeAccount(plan, req.action, req.value);
        this.invalidate();
        return result;
      }
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
      case "mcpList":
        return this.library().mcp();
      case "mcpPut":
        return this.library().putMcp(req);
      case "mcpDelete":
        return this.library().deleteMcp(req.name);
      case "mcpEnabled":
        return this.library().setMcpEnabled(req.name, req.enabled);
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
    this.optionsRevision++;
  }

  private library(): Library {
    if (!this.o.library) throw new Error("The library lives in the cloud. Open it there.");
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
    return out.map((s) => this.marked(s)).sort((a, b) => Number(b.running) - Number(a.running) || b.updatedAt.localeCompare(a.updatedAt));
  }

  /** a live session as the phone sees it, with the library prompt it runs with */
  private view(l: Live): Snapshot {
    return this.withPrompt(this.marked(l.snapshot()));
  }

  private withPrompt(s: Snapshot): Snapshot {
    const prompt = this.sessionPrompts()[s.id];
    return { ...s, prompt, mcpDisabled: this.disabledMcp(s.id) };
  }

  /**
   * Takes a chat back to one of its messages. spark forks the session before the turn that
   * message opened (or, with `keep`, before the turn after it), the same spark loads the fork, and
   * the old session is removed, so the chat goes on from there under the fork's id.
   */
  private async rewind(id: string, itemId: string, keep: boolean): Promise<Snapshot> {
    const l = await this.open(id);
    if (l.running) throw new Error("spark is still working. Stop it first.");
    const at = l.index.get(itemId);
    if (at === undefined) throw new Error("That message is gone. Open the chat again.");
    const r = await l.acp.call("_spark/session/turns", { sessionId: l.id });
    const turns: { turn: number; prompt: string }[] = Array.isArray(r?.turns) ? r.turns : [];
    // the chat's messages line up with spark's turns from the newest back; a message sent while
    // spark worked (steering) opened no turn of its own and is passed over
    const opened = new Map<number, { turn: number; prompt: string }>();
    let t = turns.length - 1;
    for (let i = l.items.length - 1; i >= 0 && t >= 0; i--) {
      const item = l.items[i];
      if (item.role !== "user") continue;
      if (item.text.trim() === turns[t].prompt.trim()) opened.set(i, turns[t--]);
    }
    let point: { turn: number; prompt: string } | undefined;
    if (keep) {
      for (let i = at + 1; i < l.items.length && !point; i++) point = opened.get(i);
      // already the last turn: nothing comes after it
      if (!point) return this.view(l);
    } else {
      point = opened.get(at);
      if (!point) throw new Error("spark can go back only to a message that started a turn.");
    }
    const forked = await l.acp.call("_spark/session/fork", { sessionId: l.id, beforeTurn: point.turn });
    const next = String(forked?.sessionId ?? "");
    if (!next) throw new Error("spark couldn't go back to that message.");
    const old = l.id;
    const prompt = this.sessionPrompts()[old];
    l.loading = true;
    l.items = [];
    l.index = new Map();
    l.lastRole = null;
    l.permission = null;
    l.id = next;
    try {
      const disabled = this.disabledMcp(old);
      l.mcpStamp = this.mcpStamp(disabled);
      const loaded = await l.acp.call("session/load", { sessionId: next, cwd: l.cwd, ...this.mcpParams(disabled) });
      this.rememberMcp(next, disabled);
      if (Array.isArray(loaded?.configOptions)) l.config = loaded.configOptions;
    } finally {
      l.loading = false;
    }
    l.updatedAt = new Date().toISOString();
    this.live.delete(old);
    this.live.set(next, l);
    this.o.filter?.phone.add(next);
    this.rememberPrompt(next, prompt);
    // the old session is no longer the loaded one, so the same spark can remove it
    try {
      await l.acp.call("session/remove", { sessionId: old });
      this.o.filter?.phone.remove(old);
      this.rememberPrompt(old);
      this.rememberMcp(old, []);
    } catch (e) {
      console.error(`rewind: kept ${old}: ${e instanceof Error ? e.message : e}`);
    }
    return { ...this.view(l), restored: keep ? undefined : point.prompt };
  }

  /** a new prompt reaches spark as it starts, so the chat's spark starts again with it */
  private async setPrompt(id: string, name: string | null): Promise<Snapshot> {
    const wanted = name || undefined;
    if (wanted && !this.promptEnv(wanted).SPARK_SYSTEM_PROMPT_FILE) throw new Error(`The prompt ${wanted} hasn't reached this host yet.`);
    const l = this.live.get(id);
    if (l?.running) throw new Error("spark is still working. Change the prompt once it stops.");
    if (this.sessionPrompts()[id] !== wanted) {
      this.rememberPrompt(id, wanted);
      if (l) {
        this.live.delete(id);
        await l.acp.stop();
      }
    }
    return this.view(await this.open(id));
  }

  /** a session as the phone sees it: whether it runs in a folder of its own */
  private marked<T extends SessionInfo>(s: T): T {
    return this.ownFolder(s.cwd) ? { ...s, scratch: true } : s;
  }

  /** a folder made for one folderless chat: directly inside the scratch folder */
  private ownFolder(path: string): boolean {
    return dirname(path) === this.scratch;
  }

  /** a new folder for a chat started without one, named for when it started */
  private async newScratch(): Promise<string> {
    const stamp = new Date().toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
    const path = join(this.scratch, `chat-${stamp}-${randomUUID().slice(0, 4)}`);
    await mkdir(path, { recursive: true });
    return path;
  }

  /**
   * What a new chat would start with (provider, model, effort, ...), before there is one. spark only
   * tells these to a session, so ask an empty one; spark doesn't keep a session nobody wrote in.
   */
  private async options(provider?: string): Promise<ConfigOption[]> {
    if (provider !== undefined && (typeof provider !== "string" || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(provider))) throw new Error("Invalid provider.");
    if (!provider && this.defaults && Date.now() - this.defaults.at < OPTIONS_MS) return this.defaults.config;
    const revision = this.optionsRevision;
    const env = provider ? { ...this.env(), SPARK_PROVIDER: provider } : this.env();
    const acp = new Acp(this.o.spark, this.o.root, env);
    try {
      await acp.initialize();
      const r = await acp.call("session/new", { cwd: this.o.root, mcpServers: [] });
      const config: ConfigOption[] = Array.isArray(r?.configOptions) ? r.configOptions : [];
      if (provider && !config.some(o => o.id === "provider" && o.currentValue === provider)) throw new Error("This provider is not available on the host.");
      if (!provider && revision === this.optionsRevision && config.length) this.defaults = { at: Date.now(), config };
      return config;
    } finally {
      acp.kill();
    }
  }

  private defaults?: { at: number; config: ConfigOption[] };
  private optionsRevision = 0;

  /**
   * A session for the phone to show. One another spark process has open, such as spark in a
   * terminal, shows read-only: spark lets one process write a session, and that one is it.
   */
  private async show(id: string): Promise<Snapshot> {
    if (!this.live.get(id)?.acp.alive && !this.opening.has(id)) {
      const held = await this.heldElsewhere(id);
      if (held) {
        const permitted = !this.o.confine || (held.cwd && await this.allowed(held.cwd).catch(() => undefined));
        const view = permitted && await this.o.terminal?.view(id);
        return view ? this.terminalView(held, view) : this.readOnly(id, held);
      }
    }
    try {
      return (await this.open(id)).snapshot();
    } catch (e) {
      // it was taken between the check and the load
      if (e instanceof SessionElsewhere) return this.readOnly(id, await this.heldElsewhere(id));
      throw e;
    }
  }

  /** the session as another spark process here has it open, if one does; never the bridge's own */
  private async heldElsewhere(id: string): Promise<Running | undefined> {
    if (!this.o.filter || this.live.has(id)) return undefined;
    // a failed live list only means the phone tries to open it, and spark says whether it can
    const running = await this.o.filter.running().catch(() => [] as Running[]);
    return running.find((r) => r.id === id);
  }

  private async controlTerminal(id: string, owner: string, op: "prompt" | "cancel", text?: string) {
    const attached = this.attached.get(id);
    if (!this.o.terminal || attached?.owner !== owner) throw new Error("Open the Mac chat again before sending.");
    await this.allowed(attached.held.cwd);
    return this.o.terminal.control(id, owner, op, text);
  }

  private async terminalView(held: Running, view: TerminalView): Promise<Snapshot> {
    const { id, title, cwd, updatedAt } = held;
    let cached = this.attached.get(id);
    if (!cached || cached.owner !== view.owner || cached.committed !== view.committed) {
      const detail = await readSession(this.o.spark, id, this.env()).catch(err => {
        if (view.committed === 0) return {};
        throw err;
      });
      cached = { held, committed: view.committed, owner: view.owner, items: historyItems(detail), historyLength: detail.history_len ?? 0 };
      this.attached.set(id, cached);
    }
    const next = cached.historyLength + 1;
    const items = view.items.map(item => ({ ...item, id: item.id.replace(`h${view.turn}:`, `h${next}:`) }));
    return {
      id, title, cwd, updatedAt, live: true, running: view.running, elsewhere: true,
      origin: this.o.filter?.phone.all().has(id) ? "phone" : "mac",
      terminalOwner: view.owner, terminalRevision: view.revision,
      items: [...cached.items, ...items], config: [], permission: null,
    };
  }

  /** the session's finished turns, read without taking its lock; the phone asks again to keep up */
  private async readOnly(id: string, held?: Running): Promise<Snapshot> {
    const [detail, known] = await Promise.all([
      readSession(this.o.spark, id, this.env()),
      held ? Promise.resolve(undefined) : this.saved().then((r) => r.sessions.find((s) => s.id === id)),
    ]);
    const working = held?.working === true;
    const items = historyItems(detail);
    // spark saves a turn when it ends, so the one it's working on now isn't in the history yet
    if (working) items.push({ id: "elsewhere:working", role: "notice", text: `spark is working on this on ${this.o.info.name}. Its reply shows here when the turn ends.` });
    const updatedAt = typeof detail.updated_at_ms === "number" ? new Date(detail.updated_at_ms).toISOString() : (held?.updatedAt ?? known?.updatedAt ?? "");
    return {
      id,
      title: held?.title ?? known?.title ?? "New session",
      cwd: held?.cwd ?? known?.cwd ?? "",
      updatedAt,
      live: false,
      running: working,
      origin: this.o.filter?.phone.all().has(id) ? "phone" : "mac",
      elsewhere: true,
      items,
      config: [],
      permission: null,
    };
  }

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
      const disabled = this.disabledMcp(id);
      l.mcpStamp = this.mcpStamp(disabled);
      const r = await acp.call("session/load", { sessionId: id, cwd, ...this.mcpParams(disabled) });
      if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
    } catch (e) {
      acp.kill();
      // spark's words for a session another spark process holds the writer lock for
      if (e instanceof Error && e.message === "Session is busy") throw new SessionElsewhere(this.o.info.name);
      throw e;
    }
    l.loading = false;
    this.live.set(id, l);
    return l;
  }

  private mcpNames(): string[] {
    const configs = this.o.prompts ? readMcp(this.o.prompts.home) : undefined;
    return Object.entries(configs ?? {}).filter(([, c]) => c.enabled !== false).map(([name]) => name).sort();
  }

  private mcpPicks(): Record<string, string[]> {
    if (!this.o.prompts) return {};
    try { return JSON.parse(readFileSync(`${this.o.prompts.sessions}.mcp`, "utf8")); }
    catch { return {}; }
  }

  private disabledMcp(id: string): string[] {
    const all = this.mcpPicks();
    return Object.hasOwn(all, id) && Array.isArray(all[id]) ? all[id] : [];
  }

  private cleanMcp(raw: unknown): string[] {
    if (!Array.isArray(raw)) return [];
    return this.mcpNames().filter(name => raw.includes(name));
  }

  private rememberMcp(id: string, disabled: string[]) {
    if (!this.o.prompts) return;
    const all = this.mcpPicks();
    if (disabled.length) all[id] = disabled;
    else if (!Object.hasOwn(all, id)) return;
    else delete all[id];
    writeAtomic(`${this.o.prompts.sessions}.mcp`, all);
  }

  private mcpParams(disabled: string[] = []) {
    return { mcpServers: [], _meta: { spark: { profileMcpServers: true, profileMcpDisabled: disabled } } };
  }

  private mcpStamp(disabled: string[]) {
    return fingerprint([disabled, (this.o.prompts && readMcp(this.o.prompts.home)) ?? null]);
  }

  private async refreshMcp(l: Live) {
    const disabled = this.disabledMcp(l.id);
    const stamp = this.mcpStamp(disabled);
    if (stamp === l.mcpStamp) return;
    const previous = l.config;
    const r = await l.acp.call("session/resume", { sessionId: l.id, ...this.mcpParams(disabled) });
    if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
    for (const id of ["model", "effort", "mode"]) {
      const value = previous.find(o => o.id === id)?.currentValue;
      if (value && l.config.some(o => o.id === id && o.currentValue !== value)) {
        const result = await l.acp.call("session/set_config_option", { sessionId: l.id, configId: id, value });
        if (Array.isArray(result?.configOptions)) l.config = result.configOptions;
      }
    }
    l.mcpStamp = stamp;
    this.o.send({ t: "config", s: l.id, config: l.config });
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

  private async create(path: string | undefined, prompt?: string, mcpDisabled?: string[]): Promise<Live> {
    const env = this.promptEnv(prompt);
    if (prompt && !env.SPARK_SYSTEM_PROMPT_FILE) throw new Error(`The prompt ${prompt} hasn't reached this host yet.`);
    const own = !path;
    const cwd = own ? await this.newScratch() : await this.allowed(path);
    const acp = new Acp(this.o.spark, cwd, { ...this.env(), ...env });
    const l = new Live("", cwd, "New session", new Date().toISOString(), acp, "phone");
    this.wire(l);
    try {
      await acp.initialize();
      const disabled = this.cleanMcp(mcpDisabled);
      l.mcpStamp = this.mcpStamp(disabled);
      const r = await acp.call("session/new", { cwd, ...this.mcpParams(disabled) });
      l.id = r.sessionId;
      if (Array.isArray(r?.configOptions)) l.config = r.configOptions;
      this.o.filter?.phone.add(l.id);
      this.rememberPrompt(l.id, prompt);
      this.rememberMcp(l.id, disabled);
    } catch (e) {
      acp.kill();
      if (own) await rm(cwd, { recursive: true, force: true });
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
    // a chat's own folder goes with it; the bridge has to find where it ran before spark forgets
    const cwd = l?.cwd ?? (await this.saved()).sessions.find((s) => s.id === id)?.cwd;
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
          const why = String(e instanceof Error ? e.message : e);
          // spark keeps a session only once it has a message; one it never saved is already gone
          if (why.includes("session is gone")) break;
          if (attempt >= 4 || !why.includes("another spark")) throw e;
          await Bun.sleep(250);
        }
      }
    } finally {
      acp.kill();
    }
    this.o.filter?.phone.remove(id);
    this.rememberPrompt(id);
    this.rememberMcp(id, []);
    if (cwd && this.ownFolder(cwd)) await rm(cwd, { recursive: true, force: true });
    return null;
  }

  /** `item` is the id the phone already shows the message under */
  private async prompt(id: string, text: string, item?: string) {
    const l = await this.open(id);
    if (l.running || l.preparing) throw new Error("spark is still working on the last message.");
    const body = text.trim();
    if (!body) return null;
    l.preparing = true;
    try { await this.refreshMcp(l); }
    finally { l.preparing = false; }
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
    if (this.o.terminal) for (const id of this.attached.keys()) {
      void this.o.terminal.view(id).then(view => { if (!view) this.attached.delete(id); });
    }
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
        const mcp = u._meta?.spark?.toolCall?.mcp;
        const item: Item = {
          ...(prior === undefined ? {} : l.items[prior]),
          id,
          role: "tool",
          text: "",
          name: mcp?.tool ?? u.name,
          title: mcp?.server ? `${mcp.server} · ${u.title || mcp.tool}` : u.title,
          kind: mcp ? "mcp" : u.kind,
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
        if (t.kind !== "mcp" && u.title && u.title !== "Running") t.title = u.title;
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
    const real = await this.inside(path, "folder");
    if (!(await stat(real)).isDirectory()) throw new Error("That isn't a folder.");
    return real;
  }

  /** a real, existing path; inside the root when the host is confined */
  private async inside(path: string | undefined, what: "folder" | "file"): Promise<string> {
    const wanted = resolve(path && path.length > 0 ? path.replace(/^~(?=$|\/)/, this.o.root) : this.o.root);
    let real: string;
    try {
      real = await realpath(wanted);
    } catch {
      throw new Error(`That ${what} doesn't exist.`);
    }
    if (this.o.confine) {
      const root = await realpath(this.o.root);
      if (real !== root && !real.startsWith(root + sep)) throw new Error(`That ${what} is outside this host.`);
    }
    return real;
  }

  /** everything in a folder, folders first, for the chat's file browser */
  private async files(path: string): Promise<FileListing> {
    const dir = await this.allowed(path);
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    const out: FileEntry[] = [];
    for (const e of entries) {
      if (out.length >= MAX_FILE_ENTRIES) break;
      if (UNLISTED.has(e.name)) continue;
      const full = join(dir, e.name);
      const s = await stat(full).catch(() => null);
      if (!s) continue;
      out.push(s.isDirectory() ? { name: e.name, path: full, dir: true } : { name: e.name, path: full, dir: false, size: s.size });
    }
    out.sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }));
    return { path: dir, name: basename(dir), entries: out };
  }

  /**
   * A file or folder the phone may rename or delete, by its own path: a link is the link, not what
   * it points at. A folder also has to be one `removable` allows.
   */
  private async entry(path: string): Promise<string> {
    if (!path) throw new Error("Choose a file.");
    const wanted = resolve(path.replace(/^~(?=$|\/)/, this.o.root));
    const full = join(await this.allowed(dirname(wanted)), basename(wanted));
    const s = await lstat(full).catch(() => null);
    if (!s) throw new Error("That file doesn't exist.");
    if (s.isDirectory()) return this.removable(full);
    return full;
  }

  /** saves text over a file, unless it changed since the phone read it */
  private async writeFile(path: string, text: string, modified?: number): Promise<{ size: number; modified: number }> {
    if (typeof text !== "string") throw new Error("There's nothing to save.");
    if (text.length > MAX_TEXT_BYTES * 4) throw new Error("That's too much text to save from the phone.");
    const real = await this.inside(path, "file");
    const before = await stat(real);
    if (!before.isFile()) throw new Error("That isn't a file.");
    if (typeof modified === "number" && Math.abs(before.mtimeMs - modified) > 1) {
      throw new Error(`${basename(real)} changed on ${this.o.info.name} since you opened it. Open it again to see the new version.`);
    }
    await writeFile(real, text);
    const after = await stat(real);
    return { size: after.size, modified: after.mtimeMs };
  }

  /**
   * Runs one command in the user's login shell and streams what it prints to the phone that asked.
   * A command that changes folder leaves the next one there: the shell writes where it ended up to
   * a scratch file on the way out.
   */
  private async command(run: string, cwd: string, command: string, to?: string): Promise<{ cwd: string }> {
    if (typeof run !== "string" || !run || this.terms.has(run)) throw new Error("That command id is taken.");
    if (typeof command !== "string" || !command.trim()) throw new Error("Type a command.");
    if (this.terms.size >= MAX_TERMS) throw new Error("Too many commands are running. Stop one first.");
    const dir = await this.allowed(cwd);
    const marker = join(tmpdir(), `spark-term-${randomUUID()}`);
    const script = `${command}\n__spark_status=$?\nprintf '%s' "$PWD" > '${marker}'\nexit $__spark_status`;
    const shell = [process.env.SHELL, "/bin/zsh", "/bin/bash", "/bin/sh"].find((s) => s && existsSync(s))!;
    const p = spawn(shell, ["-l", "-c", script], {
      cwd: dir,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, TERM: "dumb", NO_COLOR: "1", PAGER: "cat", GIT_PAGER: "cat", GIT_TERMINAL_PROMPT: "0" },
    });
    this.terms.set(run, p);

    // output goes out in batches, and stops going out past a limit while the command keeps running
    let pending = "";
    let sent = 0;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const flush = () => {
      timer = null;
      if (!pending) return;
      this.o.send({ t: "term", run, data: pending }, to);
      pending = "";
    };
    const take = (decoder: TextDecoder) => (chunk: Buffer) => {
      if (sent >= MAX_TERM_OUTPUT) return;
      let text = decoder.decode(chunk, { stream: true });
      if (sent + text.length >= MAX_TERM_OUTPUT) text = text.slice(0, MAX_TERM_OUTPUT - sent) + "\n[spark stopped showing output here]\n";
      sent += text.length;
      pending += text;
      timer ??= setTimeout(flush, 50);
    };
    p.stdout!.on("data", take(new TextDecoder()));
    p.stderr!.on("data", take(new TextDecoder()));
    p.on("close", async (code, signal) => {
      if (timer) clearTimeout(timer);
      flush();
      this.terms.delete(run);
      const ended = await readFile(marker, "utf8").catch(() => "");
      await rm(marker, { force: true });
      const next = ended ? await this.allowed(ended).catch(() => dir) : dir;
      this.o.send({ t: "term", run, done: true, code: code ?? (signal ? 130 : 1), cwd: next }, to);
    });
    p.on("error", () => {});
    return { cwd: dir };
  }

  /** a piece of a file's bytes, base64, starting at `offset` */
  private async fileData(path: string, offset: number): Promise<FileData> {
    const real = await this.inside(path, "file");
    const s = await stat(real);
    if (!s.isFile()) throw new Error("That isn't a file.");
    if (s.size > MAX_DOWNLOAD_BYTES) throw new Error("That file is too big to send to the phone.");
    if (!Number.isInteger(offset) || offset < 0 || offset > s.size) throw new Error("That's past the end of the file.");
    const handle = await open(real, "r");
    try {
      const buf = Buffer.alloc(Math.min(DOWNLOAD_PIECE_BYTES, s.size - offset));
      const { bytesRead } = await handle.read(buf, 0, buf.length, offset);
      return { path: real, name: basename(real), size: s.size, offset, data: buf.subarray(0, bytesRead).toString("base64") };
    } finally {
      await handle.close();
    }
  }

  /** one file to show: text up to a limit, an image whole, anything else by name and size */
  private async file(path: string): Promise<FileContent> {
    const real = await this.inside(path, "file");
    const s = await stat(real);
    if (!s.isFile()) throw new Error("That isn't a file.");
    const base = { path: real, name: basename(real), size: s.size, modified: s.mtimeMs };
    if (IMAGE_TYPES.has(extname(real).slice(1).toLowerCase())) {
      if (s.size > MAX_IMAGE_BYTES) return { ...base, kind: "binary" };
      return { ...base, kind: "image", data: (await readFile(real)).toString("base64") };
    }
    const handle = await open(real, "r");
    try {
      const buf = Buffer.alloc(Math.min(s.size, MAX_TEXT_BYTES));
      const { bytesRead } = await handle.read(buf, 0, buf.length, 0);
      const bytes = buf.subarray(0, bytesRead);
      if (bytes.includes(0)) return { ...base, kind: "binary" };
      return { ...base, kind: "text", text: new TextDecoder().decode(bytes), truncated: s.size > bytesRead };
    } finally {
      await handle.close();
    }
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

/** a whole process group: the shell and whatever it started */
function killGroup(p: ChildProcess, signal: NodeJS.Signals) {
  try {
    if (p.pid) process.kill(-p.pid, signal);
  } catch {
    p.kill(signal);
  }
}

/** a name for a new or renamed file or folder: one path part, dot files allowed */
function entryName(raw: unknown): string {
  const name = typeof raw === "string" ? raw.trim() : "";
  if (!name || name === "." || name === ".." || name.length > 255 || /[/\\\0]/.test(name)) throw new Error("That isn't a valid name.");
  return name;
}

const MAX_TERMS = 8;
/** a download goes in pieces that stay under the relay's 8 MB a message once in base64 */
const DOWNLOAD_PIECE_BYTES = 3 * 1024 * 1024;
const MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024;
/** what one command may print to the phone, in characters */
const MAX_TERM_OUTPUT = 2 * 1024 * 1024;

/** what the file browser leaves out: git's own folder and Finder's litter */
const UNLISTED = new Set([".git", ".DS_Store"]);
const MAX_FILE_ENTRIES = 2000;
/** a file's text is cut here; the phone says so */
const MAX_TEXT_BYTES = 512 * 1024;
/** images the phone can draw, sent whole up to this size; the relay takes 8 MB a message */
const IMAGE_TYPES = new Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico"]);
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/** the home folders macOS makes; the phone can't rename or delete them */
const PROTECTED = new Set(["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]);

function folderName(raw: unknown): string {
  const name = typeof raw === "string" ? raw.trim() : "";
  if (!name || name.length > 255 || /[/\\\0]/.test(name) || name.startsWith(".")) throw new Error("That isn't a folder name.");
  return name;
}

/** folders a search never walks into: big, generated, or not the user's projects */
const SKIP = new Set(["node_modules", "Library", "Applications", "Pictures", "Music", "Movies", "build", "dist", "target", "vendor", "Pods", "DerivedData", "venv", "__pycache__"]);

/** a session another spark process on the host has open, which the phone can read but not write */
class SessionElsewhere extends Error {
  constructor(host: string) {
    super(`This chat is open in spark on ${host}. Close it there to write here.`);
  }
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
