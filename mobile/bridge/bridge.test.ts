import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { macSessions, parseRunning } from "./mac_sessions";
import { PhoneSessions } from "./phone_sessions";
import type { SessionInfo } from "./protocol";
import { Host } from "./host";
import { applySnapshot, fingerprint, Library, type LibrarySnapshot, PROMPT_DIR } from "./library";
import { Profile } from "./providers";
import { type LibraryOp, Mirror } from "./sync";

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

  test("the Mac takes no header values from the phone", async () => {
    const mac = new Profile({ home: dir, spark: SPARK, role: "mac" });
    await expect(mac.put({ name: "x", provider: {}, env: { X: "1" } })).rejects.toThrow("own environment");
  });
});

describe.skipIf(!existsSync(SPARK))("provider edit (Mac)", () => {
  test("renames a provider, keeps its env key, and shows the display name", async () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ theme: "dark", provider: "router", models: { router: "m-large" }, providers: { router } }));
    const mac = new Profile({ home: dir, spark: SPARK, role: "mac" });
    const list = await mac.put({ name: "oc-go", previous: "router", provider: { ...router, display_name: "OpenCode Go" } });
    expect(list).toMatchObject([{ name: "oc-go", displayName: "OpenCode Go", auth: "bearer", keyEnv: "TEST_ROUTER_KEY", active: true, model: "m-large" }]);
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(s.theme).toBe("dark");
    expect(s.providers.router).toBeUndefined();
    expect(s.provider).toBe("oc-go");
    expect(existsSync(join(dir, "cloud-env.json"))).toBe(false);
  });

  test("a removed model is no longer the saved one", async () => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ provider: "router", models: { router: "m-large" }, providers: { router } }));
    const mac = new Profile({ home: dir, spark: SPARK, role: "mac" });
    const [p] = await mac.put({ name: "router", provider: { ...router, model_metadata: { "m-small": { display_name: "Small" } } } });
    expect(p.model).toBe("m-small");
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

describe("relay registration", () => {
  test("takes Macs with the enrollment secret and phones with a pairing code", async () => {
    const port = 20000 + Math.floor(Math.random() * 20000);
    const relay = Bun.spawn(["bun", resolve(import.meta.dir, "relay.ts")], {
      env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", SPARK_RELAY_DATA: dir, SPARK_RELAY_ENROLL: "enroll-secret", SPARK_CLOUD_ROOT: join(dir, "cloud") },
      stdout: "ignore",
      stderr: "ignore",
    });
    try {
      const base = `http://127.0.0.1:${port}`;
      const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
        fetch(base + path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
      for (let i = 0; i < 50; i++) {
        if (await fetch(base + "/api/info").then((r) => r.ok, () => false)) break;
        await Bun.sleep(100);
      }
      // a phone can't start on the cloud by itself
      expect(await (await fetch(base + "/api/info")).json()).toMatchObject({ cloud: false });

      expect((await post("/api/hosts", { name: "Mac" })).status).toBe(403);
      expect((await post("/api/hosts", { name: "Mac" }, { "x-spark-enroll": "wrong" })).status).toBe(403);
      const host = await (await post("/api/hosts", { name: "Mac" }, { "x-spark-enroll": "enroll-secret" })).json();
      expect(host.token).toBeString();

      expect((await post("/api/devices", { name: "iPhone" })).status).toBe(403);
      expect((await post("/api/devices", { name: "iPhone", code: "000000" })).status).toBe(403);
      const { code } = await (await post("/api/hosts/code", {}, { authorization: `Bearer ${host.token}` })).json();
      const device = await (await post("/api/devices", { name: "iPhone", code })).json();
      expect(device.token).toBeString();
      const paired = await post("/api/pair", { code }, { authorization: `Bearer ${device.token}` });
      expect(paired.status).toBe(200);
      // the code is used up
      expect((await post("/api/devices", { name: "Other", code })).status).toBe(403);
    } finally {
      relay.kill();
    }
  });
});

test("ten wrong codes cancel every open code", async () => {
  const port = 20000 + Math.floor(Math.random() * 20000);
  const relay = Bun.spawn(["bun", resolve(import.meta.dir, "relay.ts")], {
    env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", SPARK_RELAY_DATA: dir, SPARK_RELAY_ENROLL: "e" },
    stdout: "ignore",
    stderr: "ignore",
  });
  try {
    const base = `http://127.0.0.1:${port}`;
    const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
      fetch(base + path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
    for (let i = 0; i < 50; i++) {
      if (await fetch(base + "/api/info").then((r) => r.ok, () => false)) break;
      await Bun.sleep(100);
    }
    const host = await (await post("/api/hosts", {}, { "x-spark-enroll": "e" })).json();
    const { code } = await (await post("/api/hosts/code", {}, { authorization: `Bearer ${host.token}` })).json();
    const wrong = code === "000000" ? "000001" : "000000";
    for (let i = 0; i < 10; i++) expect((await post("/api/devices", { code: wrong })).status).toBe(403);
    expect((await post("/api/devices", { code })).status).toBe(403);
  } finally {
    relay.kill();
  }
});

describe("library", () => {
  const key = { ...router, auth: { type: "key", key: "sk-abcdefghijkl9876" }, headers: {} };

  test("adds, renames and deletes prompts, and refuses a name that is a path", () => {
    const lib = new Library({ dir, spark: SPARK });
    let changes = 0;
    lib.onChange(() => changes++);
    lib.putPrompt({ name: "Reviewer", text: "Review." });
    expect(lib.putPrompt({ name: "Strict reviewer", previous: "Reviewer", text: "Be strict." }).map((p) => p.name)).toEqual(["Strict reviewer"]);
    expect(() => lib.putPrompt({ name: "../x", text: "" })).toThrow("prompt's name");
    expect(() => lib.putPrompt({ name: ".hidden", text: "" })).toThrow("prompt's name");
    expect(lib.deletePrompt("Strict reviewer")).toEqual([]);
    expect(() => lib.deletePrompt("Strict reviewer")).toThrow("already gone");
    expect(changes).toBe(3);
  });

  test("a copy replaces the providers, keeps the profile's choices, and lists the prompts", () => {
    const home = join(dir, "home");
    mkdirSync(home);
    writeFileSync(join(home, "settings.json"), JSON.stringify({ theme: "dark", provider: "b", models: { b: "m-large", gone: "x" }, providers: { gone: key } }));
    writeFileSync(join(home, "prompts.json"), JSON.stringify({ dirs: ["/Users/example/prompts"], starred: ["a"] }));
    const snap: LibrarySnapshot = { providers: { a: key, b: key }, models: { a: "m-large" }, provider: "a", env: {}, prompts: { Reviewer: "Review." } };
    const marks = applySnapshot(home, snap);
    const s = JSON.parse(readFileSync(join(home, "settings.json"), "utf8"));
    expect(Object.keys(s.providers).sort()).toEqual(["a", "b"]);
    expect(s).toMatchObject({ theme: "dark", provider: "b", models: { a: "m-large", b: "m-large" } });
    expect(s.models.gone).toBeUndefined();
    expect(readFileSync(join(home, PROMPT_DIR, "Reviewer.md"), "utf8")).toBe("Review.");
    const list = JSON.parse(readFileSync(join(home, "prompts.json"), "utf8"));
    expect(list).toEqual({ dirs: ["/Users/example/prompts", join(home, PROMPT_DIR)], starred: ["a"] });
    expect(marks.a).toBe(fingerprint(key));
    expect(statSync(join(home, "settings.json")).mode & 0o777).toBe(0o600);
    // a deleted prompt leaves the profile too
    applySnapshot(home, { ...snap, prompts: {} });
    expect(readdirSync(join(home, PROMPT_DIR))).toEqual([]);
  });

  test("starts from the providers the cloud profiles already had", () => {
    for (const [d, p] of [["one", "a"], ["two", "b"]]) {
      mkdirSync(join(dir, d));
      writeFileSync(join(dir, d, "settings.json"), JSON.stringify({ provider: p, providers: { [p]: key } }));
    }
    writeFileSync(join(dir, "two", "cloud-env.json"), JSON.stringify({ TEST_ORG: "o" }));
    utimesSync(join(dir, "one", "settings.json"), new Date(2026, 0, 1), new Date(2026, 0, 1));
    const lib = new Library({ dir: join(dir, "lib"), spark: SPARK });
    lib.adopt([join(dir, "one"), join(dir, "two")]);
    const snap = lib.snapshot();
    expect(Object.keys(snap.providers).sort()).toEqual(["a", "b"]);
    expect(snap.env).toEqual({ TEST_ORG: "o" });
    // the newest profile's choice wins, and spark gets a model for it
    expect(snap.provider).toBe("b");
    expect(snap.models).toEqual({ b: "m-large" });
  });
});

describe("Mac mirror", () => {
  const key = (k: string) => ({ ...router, auth: { type: "key", key: k }, headers: {} });
  const setup = (local: Record<string, unknown>) => {
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ provider: Object.keys(local)[0], providers: local }));
    const sent: LibraryOp[] = [];
    let refuse = false;
    const mirror = new Mirror({
      home: dir,
      stateFile: join(dir, "mobile-library.json"),
      profile: new Profile({ home: dir, spark: SPARK, role: "mac", lookup: async () => "sk-from-the-shell-1234" }),
      send: async (op) => {
        if (refuse) throw new Error("no");
        sent.push(op);
      },
    });
    return { mirror, sent, refuse: () => (refuse = true) };
  };
  const snap = (providers: Record<string, any>): LibrarySnapshot => ({ providers, models: {}, env: {}, prompts: {} });

  test("the first sync sends only the providers the library lacks, then copies the library", async () => {
    const { mirror, sent } = setup({ mine: router, both: key("sk-local-0000000000") });
    await mirror.receive(snap({ both: key("sk-cloud-1111111111") }));
    expect(sent.map((o) => o.op + " " + o.name)).toEqual(["providerPut mine"]);
    expect((sent[0] as any).provider.auth).toEqual({ type: "key", key: "sk-from-the-shell-1234" });
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(s.providers.both.auth.key).toBe("sk-cloud-1111111111");
  });

  test("a local edit goes to the library and a refused one is undone", async () => {
    const { mirror, sent, refuse } = setup({ a: key("sk-cloud-1111111111") });
    await mirror.receive(snap({ a: key("sk-cloud-1111111111") }));
    expect(sent).toEqual([]);
    await Bun.sleep(20);
    const edited = { ...key("sk-cloud-1111111111"), display_name: "Router" };
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ provider: "a", providers: { a: edited, b: key("sk-new-22222222222") } }));
    await mirror.poll();
    expect(sent.map((o) => o.op + " " + o.name)).toEqual(["providerPut a", "providerPut b"]);
    expect((sent[0] as any).provider.display_name).toBe("Router");
    // a deletion the relay refuses comes back
    await Bun.sleep(20);
    refuse();
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ provider: "a", providers: {} }));
    await mirror.poll();
    const s = JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
    expect(Object.keys(s.providers)).toEqual(["a"]);
  });
});

describe("folders from the phone", () => {
  /** a host on a scratch root; each request resolves with its reply */
  function host(confine = true) {
    const root = join(dir, "root");
    mkdirSync(join(root, "work", "app"), { recursive: true });
    const replies: any[] = [];
    const h = new Host({ info: { name: "Cloud", kind: "cloud", home: root, platform: process.platform }, spark: SPARK, root, confine, send: (e) => replies.push(e) });
    let n = 0;
    const ask = async (req: Record<string, unknown>) => {
      const id = `r${++n}`;
      await h.handle({ id, ...req } as any);
      return replies.find((r) => r.id === id);
    };
    return { root, ask };
  }

  test("renames and deletes a folder inside the root", async () => {
    const { root, ask } = host();
    const renamed = await ask({ op: "folderRename", path: join(root, "work", "app"), name: "site" });
    expect(renamed.ok).toBe(true);
    expect(existsSync(join(root, "work", "site"))).toBe(true);
    expect(existsSync(join(root, "work", "app"))).toBe(false);

    mkdirSync(join(root, "work", "taken"));
    const clash = await ask({ op: "folderRename", path: join(root, "work", "site"), name: "taken" });
    expect(clash.ok).toBe(false);
    expect(clash.error).toContain("already a folder named taken");

    writeFileSync(join(root, "work", "site", "file.txt"), "x");
    const deleted = await ask({ op: "folderDelete", path: join(root, "work", "site") });
    expect(deleted.ok).toBe(true);
    expect(existsSync(join(root, "work", "site"))).toBe(false);
  });

  test("refuses the root, what holds it, and paths outside it", async () => {
    const { root, ask } = host();
    for (const path of [root, dir, "/", join(dir, "elsewhere")]) {
      const r = await ask({ op: "folderDelete", path });
      expect(r.ok).toBe(false);
    }
    expect(existsSync(root)).toBe(true);
    const bad = await ask({ op: "folderRename", path: join(root, "work"), name: "../escape" });
    expect(bad.ok).toBe(false);
    expect(existsSync(join(root, "work"))).toBe(true);
  });
});
