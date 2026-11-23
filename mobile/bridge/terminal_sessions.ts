import { randomUUID } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync } from "node:fs";
import { readFile, lstat, rename, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { fingerprint } from "./library";
import type { Item } from "./protocol";

export type TerminalView = { owner: string; committed: number; turn: number; running: boolean; items: Item[]; revision: string };
const LEASE_MS = 6_000;
const MAX_VIEW = 6 * 1024 * 1024;

export class TerminalSessions {
  private pending = new Set<string>();
  private dir: string;

  constructor(home: string) {
    this.dir = join(home, "terminal-live");
    mkdirSync(this.dir, { mode: 0o700, recursive: true });
    if (!lstatSync(this.dir).isDirectory()) throw new Error("The terminal mailbox must be a private directory.");
    chmodSync(this.dir, 0o700);
  }

  private file(id: string, kind: string) {
    if (typeof id !== "string" || !/^[\w-]{1,128}$/.test(id)) throw new Error("Invalid session ID.");
    return join(this.dir, `${id}.${kind}`);
  }

  async view(id: string): Promise<TerminalView | undefined> {
    const file = this.file(id, "view");
    try {
      const s = await lstat(file);
      if (!s.isFile() || Date.now() - s.mtimeMs > LEASE_MS || s.size > MAX_VIEW) return;
      const view = JSON.parse(await readFile(file, "utf8"));
      if (!/^[a-f0-9]{32}$/.test(view?.owner) || !Number.isSafeInteger(view.committed) || !Array.isArray(view.items)) return;
      return { ...view, revision: fingerprint(view) };
    } catch {
      return;
    }
  }

  async control(id: string, owner: string, op: "prompt" | "cancel", text?: string) {
    if (this.pending.has(id)) throw new Error("A request is already going to the Mac.");
    this.pending.add(id);
    const ticket = randomUUID();
    const tmp = this.file(id, `${ticket}.tmp`);
    const request = this.file(id, "request");
    try {
      const view = await this.view(id);
      if (!view || view.owner !== owner) throw new Error("The Mac chat changed. Open it again before sending.");
      if (op === "prompt" && (typeof text !== "string" || !text.trim() || Buffer.byteLength(text) > 16 * 1024)) {
        throw new Error("Send a message between 1 byte and 16 KB.");
      }
      const expires = Date.now() + 4_000;
      await writeFile(tmp, JSON.stringify({ owner, ticket, expires, op, text }), { mode: 0o600, flag: "wx" });
      await rename(tmp, request);
      const ack = this.file(id, "ack");
      while (Date.now() < expires) {
        const result = await readFile(ack, "utf8").then(JSON.parse).catch(() => null);
        if (result?.ticket === ticket) {
          if (result.error_message) throw new Error(result.error_message);
          return;
        }
        await Bun.sleep(100);
      }
      throw new Error("The Mac didn't confirm the request. Check the chat before trying again.");
    } finally {
      this.pending.delete(id);
      await rm(tmp, { force: true }).catch(() => undefined);
    }
  }
}
