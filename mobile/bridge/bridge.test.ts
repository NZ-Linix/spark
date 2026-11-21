import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { macSessions, parseRunning } from "./mac_sessions";
import { PhoneSessions } from "./phone_sessions";
import type { SessionInfo } from "./protocol";
import { Profile } from "./providers";

/** the spark this checkout builds; the provider checks run it against a scratch profile */
const SPARK = process.env.SPARK_BIN ?? resolve(import.meta.dir, "../../zig-out/bin/spark");

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "spark-bridge-test-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const session = (id: string, updatedAt = "2026-11-01T00:00:00.000Z"): SessionInfo => ({ id, title: id, cwd: "/Users/example/p", updatedAt, live: false, running: false, origin: "phone" });

describe("PhoneSessions", () => {
  test("adds, survives a restart, and prunes what spark no longer lists", () => {
    const file = join(dir, "mobile-sessions.json");
    const a = new PhoneSessions(file);
    expect(a.all().size).toBe(0);
    a.add("s1");
    a.add("s2");
    a.add("s1");
    expect([...new PhoneSessions(file).all()].sort()).toEqual(["s1", "s2"]);
    a.prune(new Set(["s2", "other"]));
    expect([...new PhoneSessions(file).all()]).toEqual(["s2"]);
  });

  test("writes with a rename and leaves no temp file, readable only by its owner", () => {
    const file = join(dir, "mobile-sessions.json");
    new PhoneSessions(file).add("s1");
    expect(readdirSync(dir)).toEqual(["mobile-sessions.json"]);
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });

  test("a damaged file reads as empty instead of failing", () => {
    const file = join(dir, "mobile-sessions.json");
    writeFileSync(file, "{not json");
    expect(new PhoneSessions(file).all().size).toBe(0);
  });
});

describe("Mac session filter", () => {
  test("shows the phone's sessions, running ones, and the bridge's own, and nothing else", () => {
    const saved = [session("phone"), session("terminal"), session("old"), session("bridge")];
    const running = [{ id: "terminal", title: "t", cwd: "/x", updatedAt: "" }, { id: "unsaved", title: "u", cwd: "/y", updatedAt: "2026-11-02T00:00:00.000Z" }];
    const live = [{ ...session("bridge"), live: true, running: true }];
    const out = macSessions(saved, new Set(["phone", "gone"]), running, live);
    const byId = Object.fromEntries(out.map((s) => [s.id, s]));
    expect(Object.keys(byId).sort()).toEqual(["bridge", "phone", "terminal", "unsaved"]);
    expect(byId.phone.origin).toBe("phone");
    expect(byId.terminal.origin).toBe("mac");
    // the saved entry knows the title and time better than the live list
    expect(byId.terminal.title).toBe("terminal");
    expect(byId.unsaved.cwd).toBe("/y");
    expect(byId.bridge).toMatchObject({ live: true, running: true, origin: "mac" });
  });

  test("a phone session open in the bridge stays a phone session", () => {
    const out = macSessions([session("p")], new Set(["p"]), [{ id: "p", title: "p", cwd: "", updatedAt: "" }], [{ ...session("p"), live: true }]);
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ id: "p", live: true, origin: "phone" });
  });

  test("reads spark sessions --live --json", () => {
    const text = JSON.stringify({ kind: "live_sessions", count: 1, sessions: [{ id: "a", title: "Fix it", workspace_root: "/Users/example/p", saved_model: null, state: "busy", created_at_ms: 0, updated_at_ms: 1_700_000_000_000, agents: [] }] });
    expect(parseRunning(text)).toEqual([{ id: "a", title: "Fix it", cwd: "/Users/example/p", updatedAt: new Date(1_700_000_000_000).toISOString() }]);
    expect(parseRunning(JSON.stringify({ kind: "other" }))).toEqual([]);
  });
});

const router = {
  protocol: "openai-chat-completions",
  base_url: "https://example.com/v1",
  auth: { type: "bearer", env: "TEST_ROUTER_KEY" },
  headers: { "X-Org": { env: "TEST_ROUTER_ORG" } },
  timeouts: { connect_ms: 10000 },
  model_metadata: { "m-large": { context_window: 8192, supports_tool_use: true } },
};

describe("provider export (Mac)", () => {
  test("copies the whole provider and turns a bearer variable into a key", async () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ providers: { router }, models: { router: "m-large" } }));
    const lookups: string[] = [];
    const mac = new Profile({
      home: dir,
      spark: SPARK,
      role: "mac",
      lookup: async (name) => {
        lookups.push(name);
        return { TEST_ROUTER_KEY: " sk-1234567890abcd \n", TEST_ROUTER_ORG: "org-1" }[name];
      },
    });
    const out = await mac.export("router");
    expect(out.provider.auth).toEqual({ type: "key", key: "sk-1234567890abcd" });
    expect(out.provider.timeouts).toEqual(router.timeouts);
    expect(out.provider.model_metadata).toEqual(router.model_metadata);
    expect(out.provider.headers).toEqual(router.headers);
    expect(out.env).toEqual({ TEST_ROUTER_ORG: "org-1" });
    expect(out.model).toBe("m-large");
    expect(out.keyFrom).toBe("TEST_ROUTER_KEY");
    expect(lookups.sort()).toEqual(["TEST_ROUTER_KEY", "TEST_ROUTER_ORG"]);
  });

  test("refuses when a variable isn't set, naming it", async () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ providers: { router } }));
    const mac = new Profile({ home: dir, spark: SPARK, role: "mac", lookup: async () => undefined });
    await expect(mac.export("router")).rejects.toThrow("TEST_ROUTER_KEY, TEST_ROUTER_ORG aren't set on this Mac");
  });

  test("lists with the key masked", () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ provider: "k", providers: { k: { ...router, auth: { type: "key", key: "sk-abcdefghijkl9876" } } } }));
    const [p] = new Profile({ home: dir, spark: SPARK, role: "mac" }).list();
    expect(p).toMatchObject({ name: "k", auth: "key", keyHint: "…9876", active: true, models: ["m-large"], headerEnv: ["TEST_ROUTER_ORG"] });
    expect(JSON.stringify(p)).not.toContain("abcdefgh");
  });

  test("the Mac never writes", async () => {
    const mac = new Profile({ home: dir, spark: SPARK, role: "mac" });
    await expect(mac.put({ name: "x", provider: {} })).rejects.toThrow("only changed on the cloud");
  });
});

describe.skipIf(!existsSync(SPARK))("provider put (cloud)", () => {
  const keyed = { protocol: "openai-chat-completions", base_url: "https://example.com/v1", auth: { type: "key", key: "sk-first" }, model_metadata: { m1: {} } };

  test("writes a provider spark accepts, keeping the other settings", async () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ theme: "dark" }));
    const cloud = new Profile({ home: dir, spark: SPARK, role: "cloud" });
    const list = await cloud.put({ name: "router", provider: { ...router, auth: { type: "key", key: "sk-1" } }, model: "m-large", env: { TEST_ROUTER_ORG: "org-1" } });
    expect(list.map((p) => p.name)).toEqual(["router"]);
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(s.theme).toBe("dark");
    expect(s.provider).toBe("router");
    expect(s.models.router).toBe("m-large");
    expect(s.providers.router.timeouts).toEqual(router.timeouts);
    expect(statSync(join(dir, "settings.json")).mode & 0o777).toBe(0o600);
    expect(cloud.env()).toEqual({ TEST_ROUTER_ORG: "org-1" });
    // the scratch profile spark checked is gone
    expect(readdirSync(dir).sort()).toEqual(["cloud-env.json", "settings.json"]);
  });

  test("replaces a provider, and a key left out keeps the saved one", async () => {
    const cloud = new Profile({ home: dir, spark: SPARK, role: "cloud" });
    await cloud.put({ name: "local", provider: keyed });
    await cloud.put({ name: "local", provider: { ...keyed, base_url: "https://example.com/v2", auth: { type: "key" } } });
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(s.providers.local.base_url).toBe("https://example.com/v2");
    expect(s.providers.local.auth.key).toBe("sk-first");
  });

  test("a provider spark refuses leaves the file as it was, with spark's reason", async () => {
    const cloud = new Profile({ home: dir, spark: SPARK, role: "cloud" });
    await cloud.put({ name: "local", provider: keyed });
    const before = readFileSync(join(dir, "settings.json"), "utf8");
    await expect(cloud.put({ name: "local", provider: { ...keyed, auth: { type: "key", key: "has space" } } })).rejects.toThrow(/spark refused it: providers\.local\.auth/);
    expect(readFileSync(join(dir, "settings.json"), "utf8")).toBe(before);
  });

  test("refuses bad names and variables that change how processes run", async () => {
    const cloud = new Profile({ home: dir, spark: SPARK, role: "cloud" });
    await expect(cloud.put({ name: "1bad", provider: keyed })).rejects.toThrow("starts with a letter");
    await expect(cloud.put({ name: "ok", provider: keyed, env: { PATH: "/tmp" } })).rejects.toThrow("can't set PATH");
    await expect(cloud.put({ name: "ok", provider: keyed, env: { DYLD_INSERT_LIBRARIES: "x" } })).rejects.toThrow("can't set DYLD_INSERT_LIBRARIES");
    expect(existsSync(join(dir, "settings.json"))).toBe(false);
  });

  test("delete drops the provider, its model, and values only it read", async () => {
    const cloud = new Profile({ home: dir, spark: SPARK, role: "cloud" });
    await cloud.put({ name: "local", provider: keyed });
    await cloud.put({ name: "router", provider: { ...router, auth: { type: "key", key: "sk-1" } }, model: "m-large", env: { TEST_ROUTER_ORG: "org-1" } });
    const list = await cloud.delete("router");
    expect(list.map((p) => p.name)).toEqual(["local"]);
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(s.models?.router).toBeUndefined();
    expect(s.provider).toBe("local");
    expect(cloud.env()).toEqual({});
  });
});
