/**
 * Keeps this Mac's spark profile a copy of the relay's library. The library's providers and MCP
 * servers replace the profile's and its prompts land in ~/.spark/cloud-prompts. An edit spark makes
 * here, such as `spark provider set`, `/provider` or `spark mcp add`, goes to the relay, which checks
 * it and sends every Mac the new library; one the relay refuses is undone.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { applySnapshot, fingerprint, type LibrarySnapshot, readMcp } from "./library";
import { isObject, type Profile, writeAtomic } from "./providers";

const POLL_MS = 1000;

export type LibraryOp =
  | { op: "providerPut"; name: string; provider: unknown; model?: string; env?: Record<string, string> }
  | { op: "providerDelete"; name: string }
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
};

export class Mirror {
  private written: Record<string, string> | null = null;
  /** each MCP server's fingerprint as last written; null until this Mac's own were sent once */
  private writtenMcp: Record<string, string> | null = null;
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

  /** the relay sent the library */
  async receive(snap: LibrarySnapshot) {
    this.latest = snap;
    if (this.busy) return;
    if (this.written === null || this.writtenMcp === null) {
      this.busy = true;
      try {
        if (this.written === null) await this.adopt(snap);
        if (this.writtenMcp === null) await this.adoptMcp(snap);
      } finally {
        this.busy = false;
      }
    }
    this.apply(this.latest!);
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

  private apply(snap: LibrarySnapshot) {
    try {
      this.written = applySnapshot(this.o.home, snap);
      this.writtenMcp = Object.fromEntries(Object.entries(readMcp(this.o.home) ?? {}).map(([k, v]) => [k, fingerprint(v)]));
      this.mtime = this.stamp();
      this.mcpMtime = this.stamp(this.mcpFile);
      writeAtomic(this.o.stateFile, { providers: this.written, mcp: this.writtenMcp });
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

  private local(): Record<string, unknown> {
    if (!existsSync(this.settingsFile)) return {};
    try {
      const s = JSON.parse(readFileSync(this.settingsFile, "utf8"));
      return isObject(s) && isObject(s.providers) ? s.providers : {};
    } catch {
      return {};
    }
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
    if (!ops.length) return;
    this.busy = true;
    try {
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
    } finally {
      this.busy = false;
    }
    // the relay sends the new library before it answers, so this is it: what it took stays, and
    // what it refused is undone here
    this.apply(this.latest);
  }
}
