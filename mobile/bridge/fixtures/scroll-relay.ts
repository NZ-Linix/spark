// Local responder for FlowTests: the scroll tests, and the library's MCP servers on a scratch folder.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Library } from "../library";

const library = new Library({ dir: mkdtempSync(join(tmpdir(), "spark-fixture-library-")), spark: "spark" });
const sharedAccounts = process.env.SPARK_CHATGPT_FIXTURE === "1";
const host = { id: "cloud", name: "Cloud", kind: "cloud", online: true, sharedAccounts };
const mac = { id: "demo-mac", name: "Demo Mac", kind: "mac", online: true };
const hostSwitchFixture = process.env.SPARK_HOST_SWITCH_FIXTURE === "1";
const hosts = sharedAccounts || hostSwitchFixture ? [host, mac] : [host];
const accounts: Record<string, unknown>[] = [];
const session = { id: "scroll", cwd: "/tmp", title: "Scroll regression", updatedAt: new Date().toISOString(), live: true, running: false };
const items = [
  ...Array.from({ length: 18 }, (_, i) => ({ id: `message-${i}`, role: i % 2 ? "assistant" : "user", text: `Earlier message ${i}\n\n${"A paragraph in the scroll fixture. ".repeat(8)}` })),
  { id: "thinking", role: "thought", text: "Expanded thought.\n\n" + "This text gives the disclosure height. ".repeat(45) },
  { id: "tool", role: "tool", text: "", kind: "read", status: "completed", detail: "scroll-fixture.txt", output: "Expanded tool output.\n" + "line of output\n".repeat(20) },
  { id: "last", role: "assistant", text: "The last saved answer." },
];
const config = [
  { id: "model", name: "Model", currentValue: "local", options: [{ value: "local", name: "Local" }] },
  { id: "context", name: "Context limit", currentValue: "auto", options: [
    { value: "auto", name: "Model default" },
    ...[32, 64, 100, 128, 200, 256, 300, 400, 500, 512, 1024].map(k => ({ value: String(k * 1024), name: k === 1024 ? "1M tokens" : `${k}k tokens` })),
  ] },
];
Bun.serve({
  hostname: "127.0.0.1", port: 18772,
  fetch(req, server) {
    switch (new URL(req.url).pathname) {
      case "/api/info": return Response.json({ cloud: true });
      case "/api/devices": return Response.json({ token: "fixture", hosts });
      case "/api/fixture/mac":
        if (hostSwitchFixture && req.method === "POST") {
          mac.online = new URL(req.url).searchParams.get("online") === "1";
          server.publish("hosts", JSON.stringify({ relay: "hosts", hosts }));
          return new Response(null, { status: 204 });
        }
        break;
      case "/ws/device": if (server.upgrade(req)) return;
    }
    return new Response(null, { status: 404 });
  },
  websocket: {
    open(ws) {
      ws.subscribe("hosts");
      ws.send(JSON.stringify({ relay: "hosts", hosts }));
    },
    message(ws, data) {
      const { host: target, msg: req } = JSON.parse(String(data));
      if (!req) return;
      const send = (msg: object) => ws.send(JSON.stringify({ host: target, msg }));
      const plan: string = req.op === "planAccounts" || req.op === "planAccount" ? req.plan : "chatgpt";
      const product = ({ chatgpt: "Codex", claude: "Claude", antigravity: "Antigravity" } as Record<string, string>)[plan];
      const ofPlan = () => accounts.filter(account => account.auth === `${plan}-plan`);
      if (target === host.id && (req.op === "chatgptAccounts" || req.op === "planAccounts")) {
        send({ t: "reply", id: req.id, ok: true, result: ofPlan() });
        return;
      }
      if ((req.op === "chatgptAccount" || req.op === "planAccount") && target === (req.action === "remove" ? host.id : mac.id)) {
        if (req.action === "connect") {
          accounts.push({ name: `${plan}-plan-${crypto.randomUUID().replaceAll("-", "")}`, label: req.value || String(ofPlan().length + 1), baseUrl: "https://example.com", protocol: "openai-responses", auth: `${plan}-plan`, models: ["example-model"], active: accounts.length === 0, headerEnv: [], provider: {} });
        }
        if (req.action === "remove") {
          const index = accounts.findIndex(account => account.name === req.value);
          if (index >= 0) accounts.splice(index, 1);
        }
        // As spark names them: the plan's only account without its label.
        for (const account of ofPlan()) account.displayName = ofPlan().length > 1 ? `${product} (${account.label})` : product;
        send({ t: "reply", id: req.id, ok: true, result: { accounts: ofPlan() } });
        return;
      }
      if (typeof req.op === "string" && req.op.startsWith("mcp") && req.op !== "mcpServers") {
        try {
          const result = req.op === "mcpList" ? library.mcp() : req.op === "mcpPut" ? library.putMcp(req) : req.op === "mcpDelete" ? library.deleteMcp(req.name) : library.setMcpEnabled(req.name, req.enabled);
          send({ t: "reply", id: req.id, ok: true, result });
        } catch (e) {
          send({ t: "reply", id: req.id, ok: false, error: e instanceof Error ? e.message : String(e) });
        }
        return;
      }
      if (req.op === "config") {
        const option = config.find(o => o.id === req.option);
        if (option?.options.some(o => o.value === req.value)) option.currentValue = req.value;
      }
      const results: Record<string, unknown> = {
        config,
        sessions: target === mac.id ? [] : [session], open: { ...session, items, config, permission: null }, options: config,
        prompts: [], mcpServers: ["fixture-mcp"], sessionMcp: req.disabled,
      };
      send({ t: "reply", id: req.id, ok: true, result: results[req.op] ?? null });
      if (req.op === "prompt") {
        send({ t: "item", s: session.id, item: { id: req.item, role: "user", text: req.text } });
        send({ t: "state", s: session.id, running: true });
        if (/stream/i.test(req.text)) {
          // a long reply a few words at a time, for following the newest text
          const id = `stream-${req.item}`;
          send({ t: "item", s: session.id, item: { id, role: "assistant", text: "" } });
          const words = Array.from({ length: 300 }, (_, i) => (i % 40 === 39 ? "word.\n\n" : "word "));
          let i = 0;
          const tick = setInterval(() => {
            send({ t: "append", s: session.id, id, text: words.slice(i, i + 3).join("") });
            i += 3;
            if (i < words.length) return;
            clearInterval(tick);
            send({ t: "append", s: session.id, id, text: "Streamed to the end." });
            send({ t: "state", s: session.id, running: false });
          }, 40);
          return;
        }
        setTimeout(() => {
          send({ t: "item", s: session.id, item: { id: "live", role: "assistant", text: "Visible follow-up reply." } });
          send({ t: "state", s: session.id, running: false });
        }, 800);
      }
    },
  },
});
