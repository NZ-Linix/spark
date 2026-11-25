/**
 * The relay: pairs phones with Macs, carries their messages both ways, and (when SPARK_CLOUD_ROOT is
 * set) runs cloud sessions itself, so a phone can keep working while its Mac is asleep.
 *
 *   PORT                 port to listen on (8787)
 *   SPARK_RELAY_DATA     where pairings are kept (./data)
 *   SPARK_RELAY_NAME     what the phone calls this relay (spark)
 *   SPARK_CLOUD_ROOT     turns on cloud sessions; each phone gets a folder under it
 *   SPARK_CLOUD_SETTINGS a spark settings.json whose providers start the library when it is new
 *
 * The library ($SPARK_RELAY_DATA/library) holds the one set of providers and prompts every phone,
 * cloud profile and Mac shares. Each cloud profile and each connected Mac gets a copy after every
 * change, and a Mac sends its own edits here.
 *   SPARK_BIN            the spark binary for cloud sessions (spark)
 */
import type { ServerWebSocket } from "bun";
import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync, watchFile } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { Host } from "./host";
import { applySnapshot, fingerprint, Library } from "./library";
import { PLAN_STORE_ENV } from "./plan_accounts";
import type { Event, Request } from "./protocol";
import { writeAtomic } from "./providers";
import { loadTitleService, MANAGED_TITLE_RELAY_FILE } from "./session_titles";

const PORT = Number(process.env.PORT ?? 8787);
const DATA = process.env.SPARK_RELAY_DATA ?? join(import.meta.dir, "data");
const NAME = process.env.SPARK_RELAY_NAME ?? "spark";
const CLOUD = process.env.SPARK_CLOUD_ROOT;
const CLOUD_SETTINGS = process.env.SPARK_CLOUD_SETTINGS;
const SPARK = process.env.SPARK_BIN ?? "spark";
const CODE_MS = 10 * 60 * 1000;
/** the address to listen on; 127.0.0.1 behind a TLS proxy keeps the port itself private */
const HOSTNAME = process.env.HOST ?? "0.0.0.0";
/**
 * Macs need this secret to register, so only spark-bridge builds that carry it can use the relay.
 * Without it, only the first Mac can register. Phones register only with a pairing code from a Mac,
 * unless SPARK_RELAY_OPEN=1 lets any phone in, with its own cloud.
 */
const ENROLL = process.env.SPARK_RELAY_ENROLL ?? "";
const OPEN = process.env.SPARK_RELAY_OPEN === "1";
const titles = OPEN ? undefined : loadTitleService();

type DeviceRecord = { name: string; hash: string; created: string };
type HostRecord = { name: string; hash: string; devices: string[]; created: string };
type State = { devices: Record<string, DeviceRecord>; hosts: Record<string, HostRecord> };

mkdirSync(DATA, { recursive: true });
const file = join(DATA, "relay.json");
const state: State = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { devices: {}, hosts: {} };

function save() {
  writeFileSync(file + ".tmp", JSON.stringify(state, null, 2), { mode: 0o600 });
  renameSync(file + ".tmp", file);
}

const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const id = () => randomBytes(9).toString("base64url");
const secret = () => randomBytes(32).toString("base64url");
const cloudTitleToken = titles ? secret() : undefined;

/** tokens read `<id>.<secret>`; only a hash of the secret is kept */
function check<T extends { hash: string }>(table: Record<string, T>, token: string | null): [string, T] | null {
  if (!token) return null;
  const [key, s] = token.split(".");
  const rec = key ? table[key] : undefined;
  if (!rec || !s) return null;
  const a = Buffer.from(hash(s));
  const b = Buffer.from(rec.hash);
  return a.length === b.length && timingSafeEqual(a, b) ? [key, rec] : null;
}

function bearer(req: globalThis.Request, url: URL): string | null {
  const h = req.headers.get("authorization");
  if (h?.startsWith("Bearer ")) return h.slice(7);
  return url.searchParams.get("token");
}

const codes = new Map<string, { host: string; expires: number }>();

type Socket = ServerWebSocket<{ kind: "device" | "host"; id: string }>;
const deviceSockets = new Map<string, Set<Socket>>();
const hostSockets = new Map<string, Socket>();
const clouds = new Map<string, { host: Host; home: string }>();

const library = new Library({ dir: resolve(DATA, "library"), spark: SPARK, shareAccounts: !OPEN });
{
  const homes = CLOUD && existsSync(CLOUD) ? readdirSync(CLOUD).map((d) => join(CLOUD, d, "spark")) : [];
  if (CLOUD_SETTINGS && existsSync(CLOUD_SETTINGS)) homes.push(dirname(CLOUD_SETTINGS));
  library.adopt(homes);
}

let accountStamp = "";

/** every Mac and cloud profile gets the library as it is now */
function spreadLibrary() {
  const snap = library.snapshot();
  accountStamp = fingerprint(snap.accounts ?? null);
  for (const { host, home } of clouds.values()) {
    try {
      applySnapshot(home, snap);
    } catch (e) {
      console.error(`couldn't copy the library to ${home}:`, e);
    }
    host.invalidate();
  }
  const text = JSON.stringify({ relay: "library", library: snap });
  for (const ws of hostSockets.values()) ws.send(text);
  for (const device of deviceSockets.keys()) toDevice(device, { relay: "library-changed" });
}
library.onChange(spreadLibrary);
// Cloud spark processes can renew a token without going through the bridge.
if (library.planHome) setInterval(() => {
  const snap = library.snapshot();
  const stamp = fingerprint(snap.accounts ?? null);
  if (stamp === accountStamp) return;
  accountStamp = stamp;
  const text = JSON.stringify({ relay: "library", library: snap });
  for (const ws of hostSockets.values()) ws.send(text);
}, 2_000).unref();
watchFile(join(DATA, "library", "mcp.json"), { interval: 2_000, persistent: false }, spreadLibrary);

const MCP_EDITS = new Set(["mcpPut", "mcpDelete", "mcpEnabled"]);

/** a Mac's own provider or MCP server edit, from spark on that Mac */
async function macLibraryOp(op: any): Promise<unknown> {
  switch (op?.op) {
    case "providerPut":
      return library.putProvider(op);
    case "providerDelete":
      return library.deleteProvider(op.name);
    case "accountPut":
      return library.putAccount(op);
    case "accountDelete":
      return library.deleteAccount(op.name);
    case "mcpPut":
      return library.putMcp(op);
    case "mcpDelete":
      return library.deleteMcp(op.name);
    default:
      throw new Error("The relay doesn't know that library change.");
  }
}

function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

function toDevice(device: string, payload: unknown) {
  const text = JSON.stringify(payload);
  for (const ws of deviceSockets.get(device) ?? []) ws.send(text);
}

function hostsFor(device: string) {
  const list: { id: string; name: string; kind: "mac" | "cloud"; online: boolean; sharedAccounts?: boolean }[] = Object.entries(state.hosts)
    .filter(([, h]) => h.devices.includes(device))
    .map(([hid, h]) => ({ id: hid, name: h.name, kind: "mac", online: hostSockets.has(hid) }));
  if (CLOUD) list.push({ id: "cloud", name: "Cloud", kind: "cloud", online: true, sharedAccounts: Boolean(library.planHome) });
  return list;
}

function announce(hostId: string) {
  for (const d of state.hosts[hostId]?.devices ?? []) toDevice(d, { relay: "hosts", hosts: hostsFor(d) });
}

function cloudFor(device: string): Host {
  const known = clouds.get(device);
  if (known) return known.host;
  const base = join(CLOUD!, device);
  const work = join(base, "work");
  const home = join(base, "spark");
  mkdirSync(work, { recursive: true });
  mkdirSync(home, { recursive: true, mode: 0o700 });
  applySnapshot(home, library.snapshot());
  const titleConfig = join(home, MANAGED_TITLE_RELAY_FILE);
  if (cloudTitleToken) writeAtomic(titleConfig, { relay: `http://${HOSTNAME === "::" || HOSTNAME === "::1" ? "[::1]" : "127.0.0.1"}:${PORT}`, token: cloudTitleToken });
  else rmSync(titleConfig, { force: true });
  const h = new Host({
    info: { name: "Cloud", kind: "cloud", home: work, platform: process.platform },
    spark: SPARK,
    root: work,
    confine: true,
    env: () => ({ ...library.profile.env(), SPARK_HOME: home, [PLAN_STORE_ENV]: library.planHome, CREDENTIALS_DIRECTORY: undefined }),
    library,
    prompts: { home, sessions: join(base, "session-prompts.json") },
    send: (event: Event) => toDevice(device, { host: "cloud", msg: event }),
  });
  clouds.set(device, { host: h, home });
  return h;
}

async function body(req: globalThis.Request): Promise<any> {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

const name = (v: unknown, fallback: string) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 60) : fallback);

/** wrong codes allowed before every open code is cancelled, so a code can't be guessed */
const MAX_WRONG_CODES = 10;
let wrongCodes = 0;

/** an unexpired pairing code; joining checks it, pairing uses it up */
function liveCode(v: unknown): boolean {
  const entry = codes.get(String(v ?? "").replace(/\D/g, ""));
  if (entry && entry.expires >= Date.now()) return true;
  if (++wrongCodes >= MAX_WRONG_CODES) {
    codes.clear();
    wrongCodes = 0;
  }
  return false;
}

function enrolled(req: globalThis.Request): boolean {
  if (!ENROLL) return Object.keys(state.hosts).length === 0;
  const given = createHash("sha256").update(req.headers.get("x-spark-enroll") ?? "").digest();
  return timingSafeEqual(given, createHash("sha256").update(ENROLL).digest());
}

Bun.serve<{ kind: "device" | "host"; id: string }, {}>({
  port: PORT,
  hostname: HOSTNAME,
  async fetch(req, server) {
    const url = new URL(req.url);
    const path = url.pathname;

    // a phone without a Mac can only start on the cloud when anyone may join
    if (path === "/api/info") return json({ name: NAME, cloud: Boolean(CLOUD) && OPEN });

    if (path === "/api/devices" && req.method === "POST") {
      const b = await body(req);
      if (!OPEN && !liveCode(b.code)) return json({ error: "That code didn't work. Check it on your Mac, or make a new one." }, 403);
      const key = id();
      const s = secret();
      state.devices[key] = { name: name(b.name, "iPhone"), hash: hash(s), created: new Date().toISOString() };
      save();
      return json({ device: key, token: `${key}.${s}`, hosts: hostsFor(key) });
    }

    if (path === "/api/hosts" && req.method === "POST") {
      if (!enrolled(req)) return json({ error: "This relay doesn't accept new Macs. Build spark-bridge with its SPARK_RELAY_ENROLL." }, 403);
      const b = await body(req);
      const key = id();
      const s = secret();
      state.hosts[key] = { name: name(b.name, "Mac"), hash: hash(s), devices: [], created: new Date().toISOString() };
      save();
      return json({ host: key, token: `${key}.${s}` });
    }

    if (path === "/api/hosts/code" && req.method === "POST") {
      const auth = check(state.hosts, bearer(req, url));
      if (!auth) return json({ error: "Unknown Mac." }, 401);
      for (const [c, v] of codes) if (v.host === auth[0] || v.expires < Date.now()) codes.delete(c);
      let code: string;
      do code = String(randomInt(0, 1_000_000)).padStart(6, "0");
      while (codes.has(code));
      codes.set(code, { host: auth[0], expires: Date.now() + CODE_MS });
      wrongCodes = 0;
      return json({ code, expires: Date.now() + CODE_MS });
    }

    if (path === "/api/pair" && req.method === "POST") {
      const auth = check(state.devices, bearer(req, url));
      if (!auth) return json({ error: "This iPhone isn't known to the relay." }, 401);
      const b = await body(req);
      const code = String(b.code ?? "").replace(/\D/g, "");
      const entry = liveCode(code) ? codes.get(code) : undefined;
      if (!entry) return json({ error: "That code didn't work. Check it on your Mac, or make a new one." }, 404);
      codes.delete(code);
      const h = state.hosts[entry.host];
      if (!h) return json({ error: "That Mac is gone." }, 404);
      if (!h.devices.includes(auth[0])) h.devices.push(auth[0]);
      save();
      hostSockets.get(entry.host)?.send(JSON.stringify({ relay: "paired", device: auth[1].name }));
      announce(entry.host);
      return json({ host: { id: entry.host, name: h.name, kind: "mac", online: hostSockets.has(entry.host) } });
    }

    const unlink = path.match(/^\/api\/hosts\/([\w-]+)$/);
    if (unlink && req.method === "DELETE") {
      const auth = check(state.devices, bearer(req, url));
      if (!auth) return json({ error: "Unknown iPhone." }, 401);
      const h = state.hosts[unlink[1]];
      if (h) {
        h.devices = h.devices.filter((d) => d !== auth[0]);
        save();
      }
      return json({ hosts: hostsFor(auth[0]) });
    }

    if (path === "/api/session-title" && req.method === "POST") {
      if (!titles) return json({ error: "Session titles are unavailable." }, 404);
      const token = req.headers.get("authorization")?.match(/^Bearer ([A-Za-z0-9_.-]{24,256})$/)?.[1];
      if (!token) return json({ error: "Unauthorized." }, 401);
      const host = check(state.hosts, token);
      const principal = host ? `host:${host[0]}` : token === cloudTitleToken ? "cloud" : titles.accepts(token) ? "title-client" : undefined;
      if (!principal) return json({ error: "Unauthorized." }, 403);
      return titles.handle(req, principal);
    }

    const planToken = path.match(/^\/api\/plan-token\/([a-z0-9-]+)$/);
    if (planToken && req.method === "POST" && library.planHome) {
      if (!check(state.hosts, req.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1] ?? null)) return json({ error: "Unknown Mac." }, 403);
      try {
        const access_token = await library.planToken(planToken[1]!);
        return access_token ? json({ access_token }) : json({ error: "Account not found." }, 404);
      } catch {
        return json({ error: "Could not renew the subscription account." }, 502);
      }
    }

    if (path === "/ws/device") {
      const auth = check(state.devices, bearer(req, url));
      if (!auth) return new Response("Unknown iPhone.", { status: 401 });
      return server.upgrade(req, { data: { kind: "device", id: auth[0] } }) ? undefined : new Response("Expected a WebSocket.", { status: 400 });
    }

    if (path === "/ws/host") {
      const auth = check(state.hosts, bearer(req, url));
      if (!auth) return new Response("Unknown Mac.", { status: 401 });
      return server.upgrade(req, { data: { kind: "host", id: auth[0] } }) ? undefined : new Response("Expected a WebSocket.", { status: 400 });
    }

    return new Response("spark relay", { status: path === "/" ? 200 : 404 });
  },
  websocket: {
    idleTimeout: 120,
    maxPayloadLength: 8 * 1024 * 1024,
    open(ws) {
      const { kind, id } = ws.data;
      if (kind === "device") {
        let set = deviceSockets.get(id);
        if (!set) deviceSockets.set(id, (set = new Set()));
        set.add(ws);
        ws.send(JSON.stringify({ relay: "hosts", hosts: hostsFor(id) }));
      } else {
        hostSockets.get(id)?.close(4000, "Replaced by a newer connection.");
        hostSockets.set(id, ws);
        announce(id);
        ws.send(JSON.stringify({ relay: "library", library: library.snapshot(), sessionTitles: !!titles }));
      }
    },
    message(ws, raw) {
      let m: any;
      try {
        m = JSON.parse(String(raw));
      } catch {
        return;
      }
      const { kind, id } = ws.data;
      if (kind === "device") {
        const target = String(m.host ?? "");
        const msg = m.msg as Request;
        if (!msg || typeof msg !== "object") return;
        // a server's command runs on every paired Mac, so a relay anyone can join keeps them read-only
        if (OPEN && target === "cloud" && MCP_EDITS.has(msg.op)) {
          return void ws.send(JSON.stringify({ host: target, msg: { t: "reply", id: msg.id, ok: false, error: "This relay lets anyone in, so its MCP servers are edited on the server itself." } }));
        }
        if (target === "cloud" && CLOUD) return void cloudFor(id).handle(msg, id);
        const h = state.hosts[target];
        if (!h || !h.devices.includes(id)) return void ws.send(JSON.stringify({ host: target, msg: { t: "reply", id: msg.id, ok: false, error: "This iPhone isn't paired with that Mac." } }));
        const socket = hostSockets.get(target);
        if (!socket) return void ws.send(JSON.stringify({ host: target, msg: { t: "reply", id: msg.id, ok: false, error: `${h.name} is offline.` } }));
        socket.send(JSON.stringify({ from: id, msg }));
      } else {
        const h = state.hosts[id];
        if (!h || hostSockets.get(id) !== ws) return;
        if (typeof m.name === "string" && m.name && m.name !== h.name) {
          h.name = name(m.name, h.name);
          save();
          announce(id);
        }
        if (m.library && typeof m.rid === "number") {
          macLibraryOp(m.library).then(
            () => ws.send(JSON.stringify({ relay: "library-reply", rid: m.rid, ok: true })),
            (e) => ws.send(JSON.stringify({ relay: "library-reply", rid: m.rid, ok: false, error: e instanceof Error ? e.message : String(e) })),
          );
          return;
        }
        if (!m.msg) return;
        const to: string[] = m.to ? [m.to].filter((d: string) => h.devices.includes(d)) : h.devices;
        for (const d of to) toDevice(d, { host: id, msg: m.msg });
      }
    },
    close(ws) {
      const { kind, id } = ws.data;
      if (kind === "device") deviceSockets.get(id)?.delete(ws);
      else if (hostSockets.get(id) === ws) {
        hostSockets.delete(id);
        announce(id);
      }
    },
  },
});

console.log(`spark relay on :${PORT}${CLOUD ? `, cloud sessions in ${CLOUD}` : ""}`);
