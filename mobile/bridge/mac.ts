#!/usr/bin/env bun
/**
 * spark-bridge: lets a paired iPhone see and drive spark on this Mac. `spark pair` runs it.
 *
 *   spark-bridge pair [--foreground]   show a code for the iPhone; once paired, keep this Mac
 *                                      reachable at login (or, with --foreground, in this terminal)
 *   spark-bridge serve                 keep this Mac reachable (what the login item runs)
 *   spark-bridge unpair                stop, and forget the relay and every pairing
 *
 * The relay is built in (SPARK_DEFAULT_RELAY at build time); SPARK_RELAY or --relay overrides it.
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import { $ } from "bun";
import { Host } from "./host";
import { runningSessions } from "./mac_sessions";
import { PhoneSessions } from "./phone_sessions";
import { loginShellVariable, Profile } from "./providers";
import type { Request } from "./protocol";
import { type LibraryOp, Mirror } from "./sync";

const HOME = homedir();
const CONFIG = process.env.SPARK_MOBILE_CONFIG ?? join(HOME, ".spark", "mobile.json");
/** the Mac sessions the phone started, beside the pairing */
const PHONE_SESSIONS = join(dirname(CONFIG), "mobile-sessions.json");
/** which library prompt each phone session runs with */
const SESSION_PROMPTS = join(dirname(CONFIG), "mobile-prompts.json");
/** what the copy of the relay's library last wrote here */
const LIBRARY_STATE = join(dirname(CONFIG), "mobile-library.json");
/** the spark profile whose providers the phone can copy to the cloud */
const SPARK_HOME = process.env.SPARK_HOME ?? join(HOME, ".spark");
const ROOT = process.env.SPARK_MOBILE_ROOT ?? HOME;
const AGENT = "com.spark.mobile-bridge";
const DEFAULT_RELAY = process.env.SPARK_RELAY ?? process.env.SPARK_DEFAULT_RELAY ?? "http://127.0.0.1:8799";
/** a compiled spark-bridge runs from Bun's embedded filesystem; `bun mac.ts` runs from a file */
const COMPILED = import.meta.path.startsWith("/$bunfs");
const PLIST = join(HOME, "Library", "LaunchAgents", `${AGENT}.plist`);

type Config = { relay: string; token: string };

const args = process.argv.slice(2);
const command = args.find((a) => !a.startsWith("-")) ?? "serve";
const flag = (n: string) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 ? args[i + 1] : undefined;
};

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const bold = (s: string) => `\x1b[1m${s}\x1b[0m`;

async function macName(): Promise<string> {
  try {
    const n = (await $`scutil --get ComputerName`.quiet().text()).trim();
    if (n) return n;
  } catch {}
  return hostname().replace(/\.local$/, "");
}

function load(): Config | null {
  try {
    return JSON.parse(readFileSync(CONFIG, "utf8"));
  } catch {
    return null;
  }
}

function store(c: Config) {
  mkdirSync(join(CONFIG, ".."), { recursive: true });
  writeFileSync(CONFIG, JSON.stringify(c, null, 2), { mode: 0o600 });
}

const http = (relay: string) => relay.replace(/\/+$/, "");
const ws = (relay: string) => http(relay).replace(/^http/, "ws");

/** lets this Mac register on a relay that only takes Macs it knows; build.ts sets it */
const ENROLL = process.env.SPARK_RELAY_ENROLL ?? "";

async function post(url: string, body: unknown, token?: string) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...(ENROLL ? { "x-spark-enroll": ENROLL } : {}) },
    body: JSON.stringify(body),
  });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error ?? `The relay answered ${r.status}.`);
  return j;
}

function spark(): string {
  const beside = join(process.execPath, "..", "spark");
  const found = process.env.SPARK_BIN ?? (COMPILED && existsSync(beside) ? beside : null) ?? Bun.which("spark") ?? join(HOME, ".local", "bin", "spark");
  if (!existsSync(found) && !Bun.which(found)) {
    console.error("Couldn't find spark. Install it, or set SPARK_BIN.");
    process.exit(1);
  }
  return found;
}

async function identity(relay?: string): Promise<Config> {
  const saved = load();
  if (saved && (!relay || http(relay) === saved.relay)) return saved;
  if (!relay) {
    if (saved) return saved;
    console.error("This Mac isn't paired yet. Run: spark pair");
    process.exit(1);
  }
  const r = await post(`${http(relay)}/api/hosts`, { name: await macName() });
  const c = { relay: http(relay), token: r.token };
  store(c);
  return c;
}

function serve(c: Config, onPaired?: (device: string) => void, quiet = false) {
  const name = macName();
  let socket: WebSocket | null = null;
  let delay = 500;
  let announced = false;

  const info = { name: "Mac", kind: "mac" as const, home: ROOT, platform: process.platform };
  name.then((n) => (info.name = n));
  const bin = spark();
  const profile = new Profile({ home: SPARK_HOME, spark: bin, role: "mac", lookup: loginShellVariable });
  let rid = 0;
  const waiting = new Map<number, { resolve: () => void; reject: (e: Error) => void }>();
  const mirror = new Mirror({
    home: SPARK_HOME,
    stateFile: LIBRARY_STATE,
    profile,
    log: (line) => console.log(dim(line)),
    send: (op: LibraryOp) =>
      new Promise<void>((resolve, reject) => {
        if (socket?.readyState !== WebSocket.OPEN) return reject(new Error("The relay isn't connected."));
        const id = ++rid;
        waiting.set(id, { resolve, reject });
        socket.send(JSON.stringify({ rid: id, library: op }));
        setTimeout(() => {
          if (waiting.delete(id)) reject(new Error("The relay didn't answer."));
        }, 30_000);
      }),
  });
  mirror.start();
  const host = new Host({
    info,
    spark: bin,
    // SPARK_MOBILE_ROOT keeps the phone's folder picker (and new sessions) inside one folder
    root: ROOT,
    confine: ROOT !== HOME,
    filter: { phone: new PhoneSessions(PHONE_SESSIONS), running: () => runningSessions(bin) },
    profile,
    prompts: { home: SPARK_HOME, sessions: SESSION_PROMPTS },
    send: (msg, to) => {
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ to, msg }));
    },
  });

  const connect = () => {
    const s = new WebSocket(`${ws(c.relay)}/ws/host`, { headers: { authorization: `Bearer ${c.token}` } } as any);
    socket = s;
    s.onopen = async () => {
      delay = 500;
      s.send(JSON.stringify({ name: await name, msg: null }));
      if (!announced && !quiet) console.log(dim(`Connected to ${c.relay}.`));
      announced = true;
    };
    s.onmessage = (e) => {
      let m: any;
      try {
        m = JSON.parse(String(e.data));
      } catch {
        return;
      }
      if (m.relay === "paired") {
        console.log(`  ${bold("Paired")} with ${m.device}.`);
        onPaired?.(m.device);
        return;
      }
      if (m.relay === "library" && m.library) {
        void mirror.receive(m.library).then(() => host.invalidate());
        return;
      }
      if (m.relay === "library-reply") {
        const w = waiting.get(m.rid);
        waiting.delete(m.rid);
        if (m.ok) w?.resolve();
        else w?.reject(new Error(m.error ?? "The relay refused it."));
        return;
      }
      if (m.msg) host.handle(m.msg as Request, m.from);
    };
    s.onclose = (e) => {
      if (socket !== s) return;
      socket = null;
      if (e.code === 4000) {
        console.error("Another bridge for this Mac connected to the relay, so this one stopped.");
        process.exit(0);
      }
      if (e.code === 1008 || e.reason?.includes("Unknown")) {
        console.error("The relay doesn't know this Mac any more. Pair again with: spark pair");
        process.exit(1);
      }
      setTimeout(connect, delay);
      delay = Math.min(delay * 2, 15_000);
    };
    s.onerror = () => {};
  };
  connect();
  // the relay closes quiet sockets; a ping now and then keeps this one open
  setInterval(() => {
    if (socket?.readyState === WebSocket.OPEN) (socket as any).ping?.();
  }, 30_000);
}

async function pair() {
  let c: Config;
  let code: string;
  try {
    c = await identity(flag("relay") ?? (load()?.relay ?? DEFAULT_RELAY));
    code = String((await post(`${c.relay}/api/hosts/code`, {}, c.token)).code);
  } catch (e) {
    console.error(`Couldn't reach the relay${e instanceof Error ? `: ${e.message}` : "."}`);
    process.exit(1);
  }
  const foreground = args.includes("--foreground");
  console.log();
  console.log(`  Open spark on your iPhone and enter this code:`);
  console.log();
  console.log(`      ${bold(code.slice(0, 3) + " " + code.slice(3))}`);
  console.log();
  console.log(dim(`  It works once, for 10 minutes.`));
  console.log();
  serve(c, async (device) => {
    if (foreground) {
      console.log(dim(`  ${device} can reach this Mac while this keeps running.`));
      return;
    }
    await install(true);
    console.log(dim(`  This Mac stays reachable whenever it's on. To stop: spark-bridge unpair`));
    process.exit(0);
  }, true);
}

async function install(quiet = false) {
  if (!load()) {
    console.error("Pair first: spark pair");
    process.exit(1);
  }
  const program = COMPILED ? [process.execPath] : [process.execPath, import.meta.path];
  const logs = join(HOME, "Library", "Logs", "spark-mobile.log");
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENT}</string>
  <key>ProgramArguments</key><array>${[...program, "serve"].map((a) => `<string>${a}</string>`).join("")}</array>
  <key>EnvironmentVariables</key><dict>
    <key>SPARK_BIN</key><string>${spark()}</string>
    <key>PATH</key><string>${process.env.PATH ?? "/usr/bin:/bin"}</string>${process.env.SPARK_MOBILE_ROOT ? `
    <key>SPARK_MOBILE_ROOT</key><string>${ROOT}</string>` : ""}
  </dict>
  <key>WorkingDirectory</key><string>${HOME}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${logs}</string>
  <key>StandardErrorPath</key><string>${logs}</string>
</dict>
</plist>
`;
  mkdirSync(join(PLIST, ".."), { recursive: true });
  await $`launchctl bootout gui/${process.getuid!()} ${PLIST}`.quiet().nothrow();
  writeFileSync(PLIST, plist);
  await $`launchctl bootstrap gui/${process.getuid!()} ${PLIST}`.quiet();
  if (!quiet) console.log(`The bridge now runs at login. Logs: ${logs}`);
}

async function uninstall() {
  await $`launchctl bootout gui/${process.getuid!()} ${PLIST}`.quiet().nothrow();
  rmSync(PLIST, { force: true });
  console.log("The bridge no longer runs at login.");
}

switch (command) {
  case "pair":
    await pair();
    break;
  case "serve":
    serve(await identity(flag("relay")));
    break;
  case "install":
    await install();
    break;
  case "uninstall":
    await uninstall();
    break;
  case "unpair":
  case "forget":
    await $`launchctl bootout gui/${process.getuid!()} ${PLIST}`.quiet().nothrow();
    rmSync(PLIST, { force: true });
    rmSync(CONFIG, { force: true });
    rmSync(PHONE_SESSIONS, { force: true });
    rmSync(SESSION_PROMPTS, { force: true });
    rmSync(LIBRARY_STATE, { force: true });
    console.log("This Mac is unpaired. Run spark pair to pair again.");
    break;
  default:
    console.error(`Unknown command: ${command}`);
    process.exit(2);
}
