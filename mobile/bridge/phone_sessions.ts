import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

/**
 * The Mac sessions this phone started, kept so the sidebar can show them after the bridge restarts.
 * The file is replaced with an atomic rename, so a crash leaves the old list or the new one.
 */
export class PhoneSessions {
  private ids: Set<string> | null = null;

  constructor(private file: string) {}

  all(): Set<string> {
    if (this.ids) return this.ids;
    let ids: string[] = [];
    try {
      const parsed = JSON.parse(readFileSync(this.file, "utf8"));
      if (Array.isArray(parsed?.sessions)) ids = parsed.sessions.filter((s: unknown) => typeof s === "string");
    } catch {
      // no file yet, or one we can't read: start empty rather than hide the sidebar
    }
    this.ids = new Set(ids);
    return this.ids;
  }

  add(id: string) {
    const ids = this.all();
    if (ids.has(id)) return;
    ids.add(id);
    this.save();
  }

  remove(id: string) {
    if (this.all().delete(id)) this.save();
  }

  /** forgets sessions spark no longer lists; `known` must be every saved session, not one page */
  prune(known: Set<string>) {
    const ids = this.all();
    let changed = false;
    for (const id of ids) {
      if (!known.has(id)) {
        ids.delete(id);
        changed = true;
      }
    }
    if (changed) this.save();
  }

  private save() {
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ sessions: [...this.all()] }, null, 2), { mode: 0o600 });
    renameSync(tmp, this.file);
  }
}
