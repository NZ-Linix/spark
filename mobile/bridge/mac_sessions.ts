import { deadline } from "./acp";
import type { SessionInfo } from "./protocol";

const LIVE_MS = 5_000;

/** a session some spark process on this Mac has open now, such as one in a terminal window */
export type Running = { id: string; title: string; cwd: string; updatedAt: string };

/**
 * The sessions a spark process holds the writer lock for, from `spark sessions --live --all --json`.
 * spark only reads to answer it, so asking never makes a session look running.
 */
export async function runningSessions(spark: string, env: Record<string, string | undefined> = {}): Promise<Running[]> {
  const proc = Bun.spawn([spark, "sessions", "--live", "--all", "--json"], {
    env: { ...process.env, ...env, SPARK_SOUND: "0" },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  });
  try {
    const text = await deadline(new Response(proc.stdout).text(), LIVE_MS, "spark took too long to list running sessions.");
    return parseRunning(text);
  } finally {
    proc.kill();
  }
}

export function parseRunning(text: string): Running[] {
  const parsed = JSON.parse(text);
  if (parsed?.kind !== "live_sessions" || !Array.isArray(parsed.sessions)) return [];
  return parsed.sessions
    .filter((s: any) => typeof s?.id === "string")
    .map((s: any) => ({
      id: s.id,
      title: typeof s.title === "string" && s.title ? s.title : "New session",
      cwd: typeof s.workspace_root === "string" ? s.workspace_root : "",
      updatedAt: typeof s.updated_at_ms === "number" ? new Date(s.updated_at_ms).toISOString() : "",
    }));
}

/**
 * What the Mac shows the phone: sessions the phone started, sessions open in a spark process now,
 * and sessions the bridge itself has open. Everything else on the Mac stays off the phone.
 * `live` wins over `saved`, which wins over `running`, because each knows more than the next.
 */
export function macSessions(saved: SessionInfo[], phone: Set<string>, running: Running[], live: SessionInfo[]): SessionInfo[] {
  const out = new Map<string, SessionInfo>();
  const origin = (id: string) => (phone.has(id) ? "phone" : "mac");
  const savedById = new Map(saved.map((s) => [s.id, s]));
  for (const r of running) {
    const s = savedById.get(r.id);
    out.set(r.id, { ...(s ?? { ...r, live: false, running: false }), origin: origin(r.id) });
  }
  for (const s of saved) if (phone.has(s.id)) out.set(s.id, { ...s, origin: "phone" });
  for (const l of live) out.set(l.id, { ...l, origin: origin(l.id) });
  return [...out.values()];
}
