import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { macSessions, parseRunning } from "./mac_sessions";
import { PhoneSessions } from "./phone_sessions";
import type { SessionInfo } from "./protocol";
import { Host } from "./host";
import { historyItems } from "./session_view";
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
    expect(parseRunning(text)).toEqual([{ id: "a", title: "Fix it", cwd: "/Users/example/p", updatedAt: new Date(1_700_000_000_000).toISOString(), working: false }]);
    expect(parseRunning(text.replace('"busy"', '"working"'))[0].working).toBe(true);
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

  test("mirrors cloud MCP definitions without copying OAuth state", () => {
    const lib = new Library({ dir: join(dir, "lib"), spark: SPARK });
    const home = join(dir, "home");
    mkdirSync(home);
    const file = join(home, "mcp.json");
    const matches = (servers: unknown) => expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ mcpServers: servers });
    writeFileSync(file, JSON.stringify({ mcpServers: { local: { command: "local-mcp" } } }));
    applySnapshot(home, lib.snapshot());
    matches({ local: { command: "local-mcp" } });
    const shared = { remote: { type: "http", url: "https://mcp.example.test", headers: { Authorization: "Bearer test-key" } } };
    writeFileSync(join(dir, "lib", "mcp.json"), JSON.stringify({ mcpServers: shared }));
    mkdirSync(join(dir, "lib", "mcp-credentials"));
    applySnapshot(home, lib.snapshot());
    matches(shared);
    expect(statSync(file).mode & 0o777).toBe(0o600);
    expect(existsSync(join(home, "mcp-credentials"))).toBe(false);
  });

  test("adds, edits, renames, turns off and deletes MCP servers, keeping secrets out of the list", () => {
    const lib = new Library({ dir: join(dir, "lib"), spark: SPARK });
    let changes = 0;
    lib.onChange(() => changes++);
    const headers = { Authorization: "Bearer secret-token-5678", "X-Org": "${MCP_ORG}" };
    let list = lib.putMcp({ name: "docs", server: { type: "http", url: " https://mcp.example.test/mcp ", headers } });
    expect(list).toEqual([{ name: "docs", server: { type: "http", url: "https://mcp.example.test/mcp", headers: { Authorization: null, "X-Org": "${MCP_ORG}" } }, hints: { "headers.Authorization": "5678" } }]);
    // a value sent back as null keeps the saved one, and a renamed server keeps its place
    lib.putMcp({ name: "files", server: { command: "npx", args: ["-y", "files-mcp"], env: { ROOT: "/srv" } } });
    lib.putMcp({ name: "remote docs", previous: "docs", server: { url: "https://mcp.example.test/v2", headers: { Authorization: null } } });
    const file = () => JSON.parse(readFileSync(join(dir, "lib", "mcp.json"), "utf8")).mcpServers;
    expect(Object.keys(file())).toEqual(["remote docs", "files"]);
    expect(file()["remote docs"]).toEqual({ type: "http", url: "https://mcp.example.test/v2", headers: { Authorization: "Bearer secret-token-5678" } });
    expect(lib.setMcpEnabled("files", false).find((m) => m.name === "files")?.server.enabled).toBe(false);
    expect(lib.setMcpEnabled("files", true).find((m) => m.name === "files")?.server.enabled).toBeUndefined();
    expect(() => lib.putMcp({ name: "bad", server: { url: "ftp://x" } })).toThrow("https://");
    expect(() => lib.putMcp({ name: "bad", server: { args: [] } })).toThrow("command");
    expect(() => lib.putMcp({ name: "bad", server: { command: "x", env: { "A-B": "1" } } })).toThrow("A-B");
    expect(() => lib.putMcp({ name: "new", server: { command: "x", env: { KEY: null } } })).toThrow("Enter a value for KEY");
    expect(() => lib.putMcp({ name: "files", previous: "remote docs", server: { command: "x" } })).toThrow("already");
    expect(lib.deleteMcp("files").map((m) => m.name)).toEqual(["remote docs"]);
    expect(() => lib.deleteMcp("files")).toThrow("already gone");
    expect(lib.snapshot().mcp).toEqual(file());
    expect(changes).toBe(6);
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

test("a Mac sends the MCP servers only it has, then its own MCP edits", async () => {
  writeFileSync(join(dir, "settings.json"), JSON.stringify({ providers: {} }));
  writeFileSync(join(dir, "mcp.json"), JSON.stringify({ mcpServers: { mine: { command: "mine-mcp" }, shared: { command: "old" } } }));
  const sent: LibraryOp[] = [];
  const mirror = new Mirror({
    home: dir,
    stateFile: join(dir, "mobile-library.json"),
    profile: new Profile({ home: dir, spark: SPARK, role: "mac", lookup: async () => "" }),
    send: async (op) => void sent.push(op),
  });
  const servers = { shared: { command: "shared-mcp" } };
  await mirror.receive({ providers: {}, models: {}, env: {}, prompts: {}, mcp: servers });
  expect(sent).toEqual([{ op: "mcpPut", name: "mine", server: { command: "mine-mcp" } }]);
  // the library sent here wins; it holds "mine" once the relay has it
  expect(JSON.parse(readFileSync(join(dir, "mcp.json"), "utf8")).mcpServers).toEqual(servers);
  sent.length = 0;
  await Bun.sleep(20);
  writeFileSync(join(dir, "mcp.json"), JSON.stringify({ mcpServers: { shared: { command: "shared-mcp", enabled: false }, added: { url: "https://mcp.example.test" } } }));
  await mirror.poll();
  expect(sent.map((o) => o.op + " " + o.name)).toEqual(["mcpPut shared", "mcpPut added"]);
  expect(JSON.parse(readFileSync(join(dir, "mobile-library.json"), "utf8")).mcp).toBeDefined();
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

describe("files and the terminal from the phone", () => {
  /** a host confined to a scratch root, with every event it sends */
  function host() {
    mkdirSync(join(dir, "root", "app", "src"), { recursive: true });
    // the host answers with real paths; a temp folder on macOS sits behind a link
    const root = realpathSync(join(dir, "root"));
    mkdirSync(join(root, "app", ".git"));
    writeFileSync(join(root, "app", "README.md"), "# App\n");
    writeFileSync(join(root, "app", ".env"), "KEY=1\n");
    writeFileSync(join(root, "app", "blob.bin"), Buffer.from([1, 0, 2]));
    const events: any[] = [];
    const h = new Host({ info: { name: "Cloud", kind: "cloud", home: root, platform: process.platform }, spark: SPARK, root, confine: true, send: (e) => events.push(e) });
    let n = 0;
    const ask = async (req: Record<string, unknown>) => {
      const id = `r${++n}`;
      await h.handle({ id, ...req } as any);
      return events.find((r) => r.t === "reply" && r.id === id);
    };
    /** resolves with a command's output and its done event */
    const run = async (run: string, cwd: string, command: string) => {
      const started = await ask({ op: "run", run, cwd, command });
      expect(started.ok).toBe(true);
      for (let i = 0; i < 200 && !events.some((e) => e.t === "term" && e.run === run && e.done); i++) await Bun.sleep(25);
      const mine = events.filter((e) => e.t === "term" && e.run === run);
      return { out: mine.map((e) => e.data ?? "").join(""), done: mine.find((e) => e.done) };
    };
    return { root, ask, run, h };
  }

  test("lists folders first, leaves out .git, and reads text and binary files", async () => {
    const { root, ask } = host();
    const list = await ask({ op: "files", path: join(root, "app") });
    expect(list.result.entries.map((e: any) => e.name)).toEqual(["src", ".env", "blob.bin", "README.md"]);
    const text = await ask({ op: "file", path: join(root, "app", "README.md") });
    expect(text.result.kind).toBe("text");
    expect(text.result.text).toBe("# App\n");
    expect(typeof text.result.modified).toBe("number");
    expect((await ask({ op: "file", path: join(root, "app", "blob.bin") })).result.kind).toBe("binary");
    expect((await ask({ op: "files", path: dir })).ok).toBe(false);
  });

  test("creates, saves, renames, and deletes, and won't save over newer work", async () => {
    const { root, ask } = host();
    const app = join(root, "app");
    const made = await ask({ op: "fileCreate", path: app, name: "notes.txt" });
    expect(made.result).toBe(join(app, "notes.txt"));
    expect((await ask({ op: "fileCreate", path: app, name: "notes.txt" })).ok).toBe(false);
    expect((await ask({ op: "fileCreate", path: app, name: "lib", dir: true })).ok).toBe(true);
    expect(statSync(join(app, "lib")).isDirectory()).toBe(true);

    const read = await ask({ op: "file", path: join(app, "notes.txt") });
    const saved = await ask({ op: "fileWrite", path: join(app, "notes.txt"), text: "hello", modified: read.result.modified });
    expect(saved.ok).toBe(true);
    expect(readFileSync(join(app, "notes.txt"), "utf8")).toBe("hello");
    const stale = await ask({ op: "fileWrite", path: join(app, "notes.txt"), text: "older", modified: read.result.modified - 5000 });
    expect(stale.ok).toBe(false);
    expect(readFileSync(join(app, "notes.txt"), "utf8")).toBe("hello");

    expect((await ask({ op: "entryRename", path: join(app, "notes.txt"), name: ".notes" })).result).toBe(join(app, ".notes"));
    expect((await ask({ op: "entryRename", path: join(app, ".notes"), name: "../out" })).ok).toBe(false);
    expect((await ask({ op: "entryDelete", path: join(app, ".notes") })).ok).toBe(true);
    expect((await ask({ op: "entryDelete", path: join(app, "lib") })).ok).toBe(true);
    expect(existsSync(join(app, ".notes")) || existsSync(join(app, "lib"))).toBe(false);
    expect((await ask({ op: "entryDelete", path: root })).ok).toBe(false);
    expect(existsSync(root)).toBe(true);
  });

  test("runs a command, keeps the folder it moved to, and reports the exit code", async () => {
    const { root, run } = host();
    const app = join(root, "app");
    const first = await run("t1", app, "echo hi; echo oops >&2; cd src");
    expect(first.out).toContain("hi");
    expect(first.out).toContain("oops");
    expect(first.done.code).toBe(0);
    expect(first.done.cwd).toBe(join(app, "src"));
    const failed = await run("t2", app, "exit 3");
    expect(failed.done.code).toBe(3);
    expect(failed.done.cwd).toBe(app);
  });

  test("sends a file in pieces", async () => {
    const { root, ask } = host();
    const big = Buffer.alloc(3 * 1024 * 1024 + 10, 7);
    writeFileSync(join(root, "app", "big.bin"), big);
    const first = await ask({ op: "fileData", path: join(root, "app", "big.bin") });
    expect(first.result.size).toBe(big.length);
    const got = Buffer.from(first.result.data, "base64").length;
    const rest = await ask({ op: "fileData", path: join(root, "app", "big.bin"), offset: got });
    expect(got + Buffer.from(rest.result.data, "base64").length).toBe(big.length);
    expect((await ask({ op: "fileData", path: join(root, "app", "big.bin"), offset: big.length + 1 })).ok).toBe(false);
  });

  test("gives a chat without a folder one of its own, and deletes it with the chat", async () => {
    const root = realpathSync(mkdtempSync(join(dir, "own-")));
    const events: any[] = [];
    const h = new Host({
      info: { name: "Cloud", kind: "cloud", home: root, platform: process.platform },
      spark: SPARK,
      root,
      confine: true,
      env: () => ({ SPARK_HOME: join(dir, "spark-home") }),
      send: (e) => events.push(e),
    });
    try {
      await h.handle({ id: 1, op: "new" } as any);
      const made = events.find((e) => e.id === 1);
      expect(made.ok).toBe(true);
      expect(made.result.scratch).toBe(true);
      expect(made.result.cwd.startsWith(join(root, ".spark-chats", "chat-"))).toBe(true);
      expect(existsSync(made.result.cwd)).toBe(true);
      await h.handle({ id: 2, op: "sessionDelete", s: made.result.id } as any);
      expect(events.find((e) => e.id === 2).ok).toBe(true);
      expect(existsSync(made.result.cwd)).toBe(false);
    } finally {
      h.stop();
    }
  }, 30000);

  test("stops a running command", async () => {
    const { root, ask, run } = host();
    const going = run("t3", join(root, "app"), "sleep 30");
    await Bun.sleep(300);
    expect((await ask({ op: "runStop", run: "t3" })).ok).toBe(true);
    const { done } = await going;
    expect(done).toBeTruthy();
    expect(done.code).not.toBe(0);
  });
});

/** a saved session as `spark session <id> --json` prints it: one turn with a shell call and its reply */
const DETAIL = {
  kind: "session_detail",
  id: "held",
  created_at_ms: 1_700_000_000_000,
  updated_at_ms: 1_700_000_100_000,
  history_len: 2,
  history: [
    {
      kind: "assistant",
      user: { text: "list the files", images: [] },
      assistant: "There are two files.",
      execution: {
        tool_steps: [
          {
            assistant: "Looking.",
            tool_calls: [{ id: "call_1", name: "shell", arguments_json: JSON.stringify({ action: "run", command: "ls" }) }],
            tool_results: [{ tool_call_id: "call_1", tool_name: "shell", status: "success", output: JSON.stringify({ state: "completed", exit_code: 0, output_delta: "a\nb\n" }) }],
          },
        ],
        steering: [{ text: "only top level", assistant_prefix: null, after_tool_step_count: 1 }],
      },
    },
    { kind: "interrupted", user: { text: "and now?", images: [] }, assistant: null, tool_call: null, completed_tool_names: [] },
  ],
};

describe("read-only history", () => {
  test("turns a saved session into the rows spark replays, with ids that stay put", () => {
    const items = historyItems(DETAIL);
    expect(items.map((i) => [i.id, i.role])).toEqual([
      ["h1:u", "user"],
      ["h1:a0", "assistant"],
      ["call_1", "tool"],
      ["h1:s0", "user"],
      ["h1:a1", "assistant"],
      ["h2:u", "user"],
      ["h2:stopped", "notice"],
    ]);
    expect(items[2]).toMatchObject({ name: "shell", kind: "execute", status: "completed", detail: "ls", output: "a\nb\n" });
    expect(historyItems(structuredClone(DETAIL))).toEqual(items);
  });

  test("says when earlier turns are left out", () => {
    const items = historyItems({ ...DETAIL, first_turn: 5 });
    expect(items[0]).toMatchObject({ role: "notice" });
    expect(items[1].id).toBe("h5:u");
  });

  test("tolerates a damaged detail", () => {
    expect(historyItems(null)).toEqual([]);
    expect(historyItems({ history: [null, { kind: "assistant", execution: { tool_steps: [null] } }] })).toEqual([]);
  });
});

/**
 * A spark that has session "held" saved and refuses to load it, as spark does while another spark
 * process holds its writer lock. `spark session held --json` still reads it.
 */
function fakeSpark(): string {
  const path = join(dir, "spark");
  writeFileSync(
    path,
    `#!/usr/bin/env bun
const args = process.argv.slice(2);
if (args[0] === "session") {
  process.stdout.write(${JSON.stringify(JSON.stringify(DETAIL))});
  process.exit(0);
}
const lines = require("node:readline").createInterface({ input: process.stdin });
const reply = (id, body) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, ...body }) + "\\n");
lines.on("line", (line) => {
  const m = JSON.parse(line);
  if (m.method === "initialize") reply(m.id, { result: { protocolVersion: 1 } });
  else if (m.method === "session/list") reply(m.id, { result: { sessions: [{ sessionId: "held", title: "Held", cwd: ${JSON.stringify(dir)}, updatedAt: "2026-11-01T00:00:00Z" }] } });
  else if (m.method === "session/load") reply(m.id, { error: { code: -32603, message: "Session is busy" } });
  else reply(m.id, { error: { code: -32601, message: "no" } });
});
`,
  );
  chmodSync(path, 0o755);
  return path;
}

describe("a session another spark process has open", () => {
  const hostWith = (running: () => Promise<{ id: string; title: string; cwd: string; updatedAt: string; working?: boolean }[]>) => {
    const events: any[] = [];
    const h = new Host({
      info: { name: "Studio", kind: "mac", home: dir, platform: process.platform },
      spark: fakeSpark(),
      root: dir,
      filter: { phone: new PhoneSessions(join(dir, "phone.json")), running },
      send: (e) => events.push(e),
    });
    const open = async () => {
      await h.handle({ id: 1, op: "open", s: "held" } as any);
      return events.find((e) => e.t === "reply" && e.id === 1);
    };
    return { h, open };
  };

  test("opens read-only, with its saved turns, while spark there works on it", async () => {
    const { h, open } = hostWith(async () => [{ id: "held", title: "Fix it", cwd: dir, updatedAt: "", working: true }]);
    try {
      const r = await open();
      expect(r.ok).toBe(true);
      expect(r.result).toMatchObject({ id: "held", title: "Fix it", elsewhere: true, live: false, running: true, origin: "mac", config: [] });
      expect(r.result.items.map((i: any) => i.id)).toEqual([...historyItems(DETAIL).map((i) => i.id), "elsewhere:working"]);
    } finally {
      h.stop();
    }
  }, 15000);

  test("opens read-only when spark refuses to load it after the live list missed it", async () => {
    const { h, open } = hostWith(async () => []);
    try {
      const r = await open();
      expect(r.ok).toBe(true);
      expect(r.result).toMatchObject({ id: "held", title: "Held", elsewhere: true, running: false });
      expect(r.result.items).toHaveLength(historyItems(DETAIL).length);
    } finally {
      h.stop();
    }
  }, 15000);

  test("writing to it names the host instead of spark's busy error", async () => {
    const { h } = hostWith(async () => []);
    const events: any[] = [];
    (h as any).o.send = (e: any) => events.push(e);
    try {
      await h.handle({ id: 2, op: "prompt", s: "held", text: "hi" } as any);
      expect(events.find((e) => e.id === 2)).toMatchObject({ ok: false, error: "This chat is open in spark on Studio. Close it there to write here." });
    } finally {
      h.stop();
    }
  }, 15000);
});
