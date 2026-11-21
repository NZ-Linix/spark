/**
 * The relay: pairs phones with Macs, carries their messages both ways, and (when SPARK_CLOUD_ROOT is
 * set) runs cloud sessions itself, so a phone can keep working while its Mac is asleep.
 *
 *   PORT                 port to listen on (8787)
 *   SPARK_RELAY_DATA     where pairings are kept (./data)
 *   SPARK_RELAY_NAME     what the phone calls this relay (spark)
 *   SPARK_CLOUD_ROOT     turns on cloud sessions; each phone gets a folder under it
 *   SPARK_CLOUD_SETTINGS a spark settings.json copied into each phone's cloud profile when it is
 *                        first used; after that the phone manages that profile's providers
 *   SPARK_BIN            the spark binary for cloud sessions (spark)
 */
import type { ServerWebSocket } from "bun";
import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Host } from "./host";
import { Profile } from "./providers";
import type { Event, Request } from "./protocol";

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
const clouds = new Map<string, Host>();

function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

function toDevice(device: string, payload: unknown) {
  const text = JSON.stringify(payload);
  for (const ws of deviceSockets.get(device) ?? []) ws.send(text);
}

function hostsFor(device: string) {
  const list = Object.entries(state.hosts)
    .filter(([, h]) => h.devices.includes(device))
    .map(([hid, h]) => ({ id: hid, name: h.name, kind: "mac", online: hostSockets.has(hid) }));
  if (CLOUD) list.push({ id: "cloud", name: "Cloud", kind: "cloud", online: true });
  return list;
}

function announce(hostId: string) {
  for (const d of state.hosts[hostId]?.devices ?? []) toDevice(d, { relay: "hosts", hosts: hostsFor(d) });
}

function cloudFor(device: string): Host {
  let h = clouds.get(device);
  if (h) return h;
  const base = join(CLOUD!, device);
  const work = join(base, "work");
  const home = join(base, "spark");
  mkdirSync(work, { recursive: true });
  mkdirSync(home, { recursive: true, mode: 0o700 });
  if (CLOUD_SETTINGS && existsSync(CLOUD_SETTINGS) && !existsSync(join(home, "settings.json"))) {
    copyFileSync(CLOUD_SETTINGS, join(home, "settings.json"));
    // it holds provider keys
    chmodSync(join(home, "settings.json"), 0o600);
  }
  // only this phone's profile: every file it touches is under this phone's own folder
  const profile = new Profile({ home, spark: SPARK, role: "cloud" });
  h = new Host({
    info: { name: "Cloud", kind: "cloud", home: work, platform: process.platform },
    spark: SPARK,
    root: work,
    confine: true,
    env: () => ({ ...profile.env(), SPARK_HOME: home }),
    profile,
    send: (event: Event) => toDevice(device, { host: "cloud", msg: event }),
  });
  clouds.set(device, h);
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

/** an unexpired pairing code; joining checks it, pairing uses it up */
function liveCode(v: unknown): boolean {
  const entry = codes.get(String(v ?? "").replace(/\D/g, ""));
  return Boolean(entry && entry.expires >= Date.now());
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
      return json({ code, expires: Date.now() + CODE_MS });
    }

    if (path === "/api/pair" && req.method === "POST") {
      const auth = check(state.devices, bearer(req, url));
      if (!auth) return json({ error: "This iPhone isn't known to the relay." }, 401);
      const b = await body(req);
      const code = String(b.code ?? "").replace(/\D/g, "");
      const entry = codes.get(code);
      if (!entry || entry.expires < Date.now()) return json({ error: "That code didn't work. Check it on your Mac, or make a new one." }, 404);
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
        if (target === "cloud" && CLOUD) return void cloudFor(id).handle(msg, id);
        const h = state.hosts[target];
        if (!h || !h.devices.includes(id)) return void ws.send(JSON.stringify({ host: target, msg: { t: "reply", id: msg.id, ok: false, error: "This iPhone isn't paired with that Mac." } }));
        const socket = hostSockets.get(target);
        if (!socket) return void ws.send(JSON.stringify({ host: target, msg: { t: "reply", id: msg.id, ok: false, error: `${h.name} is offline.` } }));
        socket.send(JSON.stringify({ from: id, msg }));
      } else {
        const h = state.hosts[id];
        if (!h) return;
        if (typeof m.name === "string" && m.name && m.name !== h.name) {
          h.name = name(m.name, h.name);
          save();
          announce(id);
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
