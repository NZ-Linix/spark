import { expect, test } from "bun:test";
import { join } from "node:path";
import { writeFileSync } from "node:fs";
import { SPARK_BIN } from "../evals/eval-helpers";
import { completion, createConfiguredProviderFixture, toolCompletion } from "./fixtures/chat-completions";
import { tmuxAvailable, TmuxSession } from "./tmux-helpers";
import { Host } from "../../mobile/bridge/host";
import { runningSessions } from "../../mobile/bridge/mac_sessions";
import { PhoneSessions } from "../../mobile/bridge/phone_sessions";
import type { Event, Request, Snapshot } from "../../mobile/bridge/protocol";
import { TerminalSessions } from "../../mobile/bridge/terminal_sessions";

const spark = process.env.SPARK_TERMINAL_TEST_BIN ?? SPARK_BIN;

test.skipIf(!tmuxAvailable())("a phone can read a partial answer and steer a terminal-owned chat", async () => {
  const encoder = new TextEncoder();
  let closeStream: (() => void) | undefined;
  const heldPrompts = new Set<string>();
  const fixture = createConfiguredProviderFixture(body => {
    const input = JSON.stringify(body.messages);
    const prompt = String(body.messages.at(-1)?.content ?? "");
    if (!prompt.startsWith("Hold") || heldPrompts.has(prompt)) {
      return input.includes("Follow-up from phone")
        ? completion(body.model, "Phone message received.")
        : completion(body.model, "Saved terminal answer.", 2_600, 2_400);
    }
    heldPrompts.add(prompt);
    return new Response(new ReadableStream({ start(controller) {
      const send = (delta: object, finish_reason: string | null) => {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ id: "held", model: body.model, choices: [{ index: 0, delta, finish_reason }] })}\n\n`));
      };
      send({ content: "Partial **markdown** from the Mac" }, null);
      closeStream = () => {
        send({}, "stop");
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      };
    }, cancel() { closeStream = undefined; } }), { headers: { "content-type": "text/event-stream" } });
  });
  const home = join(fixture.home, ".spark");
  const terminal = new TerminalSessions(home);
  const env = { ...fixture.env, SPARK_HOME: home };
  let reply: Event | undefined;
  const host = new Host({
    info: { name: "Test Mac", kind: "mac", home, platform: process.platform },
    spark: spark,
    root: home,
    env: () => env,
    terminal,
    filter: { phone: new PhoneSessions(join(home, "phone.json")), running: () => runningSessions(spark, env) },
    send: e => { if (e.t === "reply") reply = e; },
  });
  const pane = await TmuxSession.create({ cmd: spark, cwd: fixture.workspace, env, isolated: true });
  const ask = async (req: Request) => {
    reply = undefined;
    await host.handle(req);
    const event = reply as Extract<Event, { t: "reply" }> | undefined;
    if (!event?.ok) throw new Error(event?.error ?? "No reply");
    return event.result;
  };
  try {
    await pane.waitForComposer();
    await pane.sendText("First message in the Mac terminal");
    await pane.waitForText("Saved terminal answer.");
    await pane.waitForText("CH92.3%");
    const start = await until(async () => (await runningSessions(spark, env))[0]);
    const id = start.id;
    const initial = await until(async () => {
      const snap = await ask({ id: 1, op: "open", s: id }) as Snapshot;
      return snap.terminalOwner && snap.items.some(i => i.text.includes("Saved terminal answer.")) ? snap : undefined;
    });
    await pane.sendText("Hold this stream");
    const live = await until(async () => {
      const snap = await ask({ id: 2, op: "watchTerminal", s: id, revision: initial.terminalRevision }) as Snapshot | null;
      return snap?.running && snap.items.some(i => i.text.includes("Partial **markdown** from the Mac")) ? snap : undefined;
    });
    expect(live.items[0]?.id).toBe(initial.items[0]?.id);
    await ask({ id: 3, op: "prompt", s: id, terminalOwner: live.terminalOwner, text: "Follow-up from phone" });
    closeStream?.();
    await pane.waitForText("Phone message received.");
    const done = await until(async () => {
      const snap = await ask({ id: 4, op: "watchTerminal", s: id, revision: live.terminalRevision }) as Snapshot | null;
      return snap?.items.some(i => i.text.includes("Phone message received.")) && !snap.running ? snap : undefined;
    });
    expect(done.id).toBe(id);
    expect(done.items.filter(i => i.text === "Follow-up from phone")).toHaveLength(1);
    await pane.sendText("Hold until the phone presses Stop");
    const active = await until(async () => {
      const snap = await ask({ id: 5, op: "watchTerminal", s: id, revision: done.terminalRevision }) as Snapshot | null;
      return snap?.running && snap.items.some(i => i.text === "Hold until the phone presses Stop") ? snap : undefined;
    });
    await ask({ id: 6, op: "cancel", s: id, terminalOwner: active.terminalOwner });
    const stopped = await until(async () => {
      const snap = await ask({ id: 7, op: "watchTerminal", s: id, revision: active.terminalRevision }) as Snapshot | null;
      return snap && !snap.running ? snap : undefined;
    });
    expect(stopped.terminalOwner).toBe(initial.terminalOwner);
  } finally {
    await pane.kill();
    host.stop();
    fixture.close();
  }
}, 60_000);

test("a profile MCP server starts enabled and can be toggled for an existing chat", async () => {
  let calls = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(req) {
      if (req.method !== "POST") return new Response(null, { status: 405 });
      const rpc = await req.json();
      if (rpc.id === undefined) return new Response(null, { status: 202 });
      if (rpc.method === "initialize") calls += 1;
      const result = rpc.method === "initialize" ? { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } }
        : { tools: [{ name: "echo", description: "Fixture echo", inputSchema: { type: "object", properties: {} } }] };
      return Response.json({ jsonrpc: "2.0", id: rpc.id, result });
    },
  });
  const fixture = createConfiguredProviderFixture(body => {
    const last = body.messages.at(-1);
    return last?.role === "user"
      ? toolCompletion(body.model, "toolbox", { search: "fixture echo", server: "fixture" }, `search-${last.content}`)
      : completion(body.model, "MCP turn completed.");
  });
  const home = join(fixture.home, ".spark");
  writeFileSync(join(home, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { type: "http", url: `http://127.0.0.1:${server.port}/mcp` } } }), { mode: 0o600 });
  const events: Event[] = [];
  const host = new Host({
    info: { name: "Test host", kind: "cloud", home, platform: process.platform },
    spark: spark, root: fixture.workspace, env: () => ({ ...fixture.env, SPARK_HOME: home }),
    prompts: { home, sessions: join(home, "phone-prompts.json") }, send: e => events.push(e),
  });
  let requestId = 0;
  const ask = async (req: Request) => {
    req.id = ++requestId;
    await host.handle(req);
    const event = events.find((e): e is Extract<Event, { t: "reply" }> => e.t === "reply" && e.id === req.id);
    if (!event?.ok) throw new Error(event?.error ?? "No reply");
    return event.result;
  };
  const prompt = async (s: string, text: string) => {
    const from = events.length;
    await ask({ id: 0, op: "prompt", s, text });
    const state = await until(async () => events.slice(from).find((e): e is Extract<Event, { t: "state" }> => e.t === "state" && !e.running));
    expect(state.error).toBeUndefined();
  };
  try {
    expect(await ask({ id: 0, op: "mcpServers" })).toEqual(["fixture"]);
    const chat = await ask({ id: 0, op: "new", cwd: fixture.workspace }) as Snapshot;
    expect(chat.mcpDisabled).toEqual([]);
    await prompt(chat.id, "first");
    expect(calls).toBe(1);
    await ask({ id: 0, op: "sessionMcp", s: chat.id, disabled: ["fixture"] });
    await prompt(chat.id, "second");
    expect(calls).toBe(1);
    const opened = await ask({ id: 0, op: "open", s: chat.id }) as Snapshot;
    expect(opened.mcpDisabled).toEqual(["fixture"]);
    await ask({ id: 0, op: "sessionMcp", s: chat.id, disabled: [] });
    await prompt(chat.id, "third");
    expect(calls).toBe(2);
  } finally {
    host.stop();
    server.stop(true);
    fixture.close();
  }
}, 45_000);

async function until<T>(read: () => Promise<T | undefined>): Promise<T> {
  const expires = Date.now() + 12_000;
  while (Date.now() < expires) {
    const result = await read();
    if (result !== undefined) return result;
    await Bun.sleep(150);
  }
  throw new Error("Timed out waiting for the Mac session.");
}
