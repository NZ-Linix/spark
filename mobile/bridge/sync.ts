/**
 * Keeps this Mac's spark profile a copy of the relay's library. The library's providers and MCP
 * servers replace the profile's and its prompts land in ~/.spark/cloud-prompts. An edit spark makes
 * here, such as `spark provider set`, `/provider` or `spark mcp add`, goes to the relay, which checks
 * it and sends every Mac the new library; one the relay refuses is undone.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { applySnapshot, fingerprint, type LibrarySnapshot, readMcp } from "./library";
import { isLocalProvider, isObject, type Profile, writeAtomic } from "./providers";
import { deleteCredential, readAccounts, readCredential, SHARED_PLANS_FILE, writeCredential, type SharedAccounts } from "./plan_accounts";

const POLL_MS = 1000;

export type LibraryOp =
  | { op: "providerPut"; name: string; provider: unknown; model?: string; env?: Record<string, string> }
  | { op: "providerDelete"; name: string }
  | { op: "accountPut"; name: string; provider: unknown; model?: string; credential?: unknown; updateOnly?: boolean }
  | { op: "accountDelete"; name: string }
  | { op: "mcpPut"; name: string; server: unknown }
  | { op: "mcpDelete"; name: string };

export type MirrorOptions = {
  /** this Mac's SPARK_HOME */
  home: string;
  /** what the mirror remembers between runs: each provider's fingerprint as last written */
  stateFile: string;
  /** a role "mac" profile on `home`, which reads a bearer key from the person's shell */
  profile: Profile;
  /** sends one change to the relay; rejects with the relay's reason */
  send: (op: LibraryOp) => Promise<void>;
  log?: (line: string) => void;
  relay?: { relay: string; token: string };
  onApply?: () => void;
};

export class Mirror {
  private written: Record<string, string> | null = null;
  /** each MCP server's fingerprint as last written; null until this Mac's own were sent once */
  private writtenMcp: Record<string, string> | null = null;
  private writtenAccounts: Record<string, { provider: string; credential: string }> = {};
  private mtime = 0;
  private mcpMtime = 0;
  private latest: LibrarySnapshot | null = null;
  private busy = false;
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private o: MirrorOptions) {
    try {
      const parsed = JSON.parse(readFileSync(o.stateFile, "utf8"));
      if (isObject(parsed) && isObject(parsed.providers)) this.written = parsed.providers as Record<string, string>;
      if (isObject(parsed) && isObject(parsed.mcp)) this.writtenMcp = parsed.mcp as Record<string, string>;
      if (isObject(parsed?.accounts)) this.writtenAccounts = parsed.accounts;
    } catch {
      // never synced: the first library this Mac gets adds the providers only this Mac has
    }
  }

  private get settingsFile() {
    return join(this.o.home, "settings.json");
  }

  private get mcpFile() {
    return join(this.o.home, "mcp.json");
  }

  start() {
    this.timer ??= setInterval(() => void this.poll(), POLL_MS);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  disconnect() {
    this.latest = null;
  }

  /** the relay sent the library */
  async receive(snap: LibrarySnapshot) {
    this.latest = snap;
    if (this.busy) return;
    this.busy = true;
    try {
      if (this.written === null) await this.adopt(snap);
      if (this.writtenMcp === null) await this.adoptMcp(snap);
      const accounts = this.latest && await this.syncAccounts(this.latest.accounts);
      if (this.latest) this.apply(this.latest, accounts ?? undefined);
    } finally {
      this.busy = false;
    }
  }

  private async syncAccounts(shared?: SharedAccounts): Promise<Set<string>> {
    const pending = new Set<string>();
    if (!shared) return pending;
    const settings = this.settings();
    if (!settings) return new Set([...Object.keys(shared), ...Object.keys(this.writtenAccounts)]);
    const local = readAccounts(this.o.home, settings);
    const send = async (op: LibraryOp) => {
      try {
        await this.o.send(op);
      } catch {
        pending.add(op.name);
        this.o.log?.(`Couldn't sync subscription account ${op.name}; will retry.`);
      }
    };
    for (const [name, account] of Object.entries(local)) {
      const before = this.writtenAccounts[name];
      const remote = shared[name];
      if ((!before && remote) || (before && !remote)) continue;
      const credential = before?.credential !== fingerprint(account.credential) ? account.credential : undefined;
      if (credential || before?.provider !== fingerprint(account.provider)) {
        await send({ op: "accountPut", name, provider: account.provider, model: account.model, credential, updateOnly: before !== undefined });
      }
    }
    for (const name of Object.keys(this.writtenAccounts)) {
      // A missing/unsafe credential alone isn't a deletion. Spark removes the settings entry as well.
      if (shared[name] && !Object.hasOwn(settings.providers ?? {}, name)) await send({ op: "accountDelete", name });
    }
    return pending;
  }

  /** the first sync sends the providers only this Mac has; for one both have, the library wins */
  private async adopt(snap: LibrarySnapshot) {
    for (const name of Object.keys(this.local())) {
      if (snap.providers[name]) continue;
      try {
        const e = await this.o.profile.export(name);
        await this.o.send({ op: "providerPut", name, provider: e.provider, model: e.model, env: e.env });
        this.o.log?.(`Sent ${name} to the library.`);
      } catch (err) {
        this.o.log?.(`Couldn't send ${name} to the library: ${err instanceof Error ? err.message : err}`);
      }
    }
  }

  /** the first sync with MCP servers sends the ones only this Mac has; for one both have, the library wins */
  private async adoptMcp(snap: LibrarySnapshot) {
    for (const [name, server] of Object.entries(readMcp(this.o.home) ?? {})) {
      if (snap.mcp?.[name]) continue;
      try {
        // the relay sends the new library before it answers, so `latest` holds the server after this
        await this.o.send({ op: "mcpPut", name, server });
        this.o.log?.(`Sent the MCP server ${name} to the library.`);
      } catch (err) {
        this.o.log?.(`Couldn't send the MCP server ${name} to the library: ${err instanceof Error ? err.message : err}`);
      }
    }
  }

  private apply(snap: LibrarySnapshot, pending = new Set<string>()) {
    try {
      const removed = new Set<string>();
      let nextAccounts = this.writtenAccounts;
      if (snap.accounts) {
        const accounts: SharedAccounts = {};
        const marks: typeof this.writtenAccounts = {};
        for (const [id, account] of Object.entries(snap.accounts)) {
          if (pending.has(id)) continue;
          const credential = fingerprint(account.credential);
          if (fingerprint(readCredential(this.o.home, id) ?? null) !== credential) writeCredential(this.o.home, id, account.credential);
          accounts[id] = account;
          marks[id] = { provider: fingerprint(account.provider), credential };
        }
        for (const id of Object.keys(this.writtenAccounts)) {
          if (pending.has(id)) marks[id] = this.writtenAccounts[id]!;
          else if (!Object.hasOwn(accounts, id)) {
            removed.add(id);
            deleteCredential(this.o.home, id);
          }
        }
        nextAccounts = marks;
        if (this.o.relay) writeAtomic(join(this.o.home, SHARED_PLANS_FILE), { ...this.o.relay, accounts: Object.keys(marks) });
        snap = { ...snap, accounts };
      }
      this.written = applySnapshot(this.o.home, snap, true, removed);
      this.writtenAccounts = nextAccounts;
      this.writtenMcp = Object.fromEntries(Object.entries(readMcp(this.o.home) ?? {}).map(([k, v]) => [k, fingerprint(v)]));
      this.mtime = this.stamp();
      this.mcpMtime = this.stamp(this.mcpFile);
      writeAtomic(this.o.stateFile, { providers: this.written, mcp: this.writtenMcp, accounts: this.writtenAccounts });
      this.o.onApply?.();
    } catch (e) {
      this.o.log?.(`Couldn't copy the library here: ${e instanceof Error ? e.message : e}`);
    }
  }

  private stamp(file = this.settingsFile): number {
    try {
      return statSync(file).mtimeMs;
    } catch {
      return 0;
    }
  }

  private settings() {
    if (!existsSync(this.settingsFile)) return {};
    try {
      const s = JSON.parse(readFileSync(this.settingsFile, "utf8"));
      return isObject(s) ? s : undefined;
    } catch {
      return undefined;
    }
  }

  private local(): Record<string, unknown> {
    const s = this.settings();
    return isObject(s?.providers) ? Object.fromEntries(Object.entries(s.providers).filter(([name, p]) => !isLocalProvider(name, p))) : {};
  }

  /** spark changed settings.json or mcp.json: send each provider or server that differs from what the mirror wrote */
  async poll() {
    if (this.busy || this.written === null || !this.latest) return;
    const ops: LibraryOp[] = [];
    const mtime = this.stamp();
    if (mtime !== this.mtime) {
      this.mtime = mtime;
      const local = this.local();
      const written = this.written;
      for (const [name, p] of Object.entries(local)) {
        if (written[name] !== fingerprint(p)) ops.push({ op: "providerPut", name, provider: p });
      }
      for (const name of Object.keys(written)) if (!(name in local)) ops.push({ op: "providerDelete", name });
    }
    const mcpMtime = this.stamp(this.mcpFile);
    if (this.writtenMcp && mcpMtime !== this.mcpMtime) {
      this.mcpMtime = mcpMtime;
      const local = readMcp(this.o.home) ?? {};
      const written = this.writtenMcp;
      for (const [name, server] of Object.entries(local)) {
        if (written[name] !== fingerprint(server)) ops.push({ op: "mcpPut", name, server });
      }
      for (const name of Object.keys(written)) if (!(name in local)) ops.push({ op: "mcpDelete", name });
    }
    // A reconnect can replace only the credentials, without editing settings.json.
    this.busy = true;
    const before = this.latest;
    try {
      const pending = await this.syncAccounts(before.accounts);
      for (const op of ops) {
        try {
          if (op.op === "providerPut") {
            // a bearer key and header values come from this Mac's shell; the library keeps the values
            const e = await this.o.profile.export(op.name);
            await this.o.send({ op: "providerPut", name: op.name, provider: e.provider, model: e.model, env: e.env });
          } else {
            await this.o.send(op);
          }
          this.o.log?.(`${op.op.endsWith("Put") ? "Saved" : "Deleted"} ${op.op.startsWith("mcp") ? "the MCP server " : ""}${op.name} in the library.`);
        } catch (err) {
          this.o.log?.(`The library refused the change to ${op.name}: ${err instanceof Error ? err.message : err}`);
        }
      }
      // The relay sends the new library before it answers. Keep unacknowledged account edits for retry.
      if (this.latest && (ops.length || this.latest !== before)) this.apply(this.latest, pending);
    } finally {
      this.busy = false;
    }
  }
}
