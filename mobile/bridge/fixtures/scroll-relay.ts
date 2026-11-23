// Local responder for FlowTests.testChatScrollAndDisclosure.
const host = { id: "cloud", name: "Cloud", kind: "cloud", online: true };
const session = { id: "scroll", cwd: "/tmp", title: "Scroll regression", updatedAt: new Date().toISOString(), live: true, running: false };
const items = [
  ...Array.from({ length: 18 }, (_, i) => ({ id: `message-${i}`, role: i % 2 ? "assistant" : "user", text: `Earlier message ${i}\n\n${"A paragraph in the scroll fixture. ".repeat(8)}` })),
  { id: "thinking", role: "thought", text: "Expanded thought.\n\n" + "This text gives the disclosure height. ".repeat(45) },
  { id: "tool", role: "tool", text: "", kind: "read", status: "completed", detail: "scroll-fixture.txt", output: "Expanded tool output.\n" + "line of output\n".repeat(20) },
  { id: "last", role: "assistant", text: "The last saved answer." },
];
const config = [{ id: "model", name: "Model", currentValue: "local", options: [{ value: "local", name: "Local" }] }];
Bun.serve({
  hostname: "127.0.0.1", port: 18772,
  fetch(req, server) {
    switch (new URL(req.url).pathname) {
      case "/api/info": return Response.json({ cloud: true });
      case "/api/devices": return Response.json({ token: "fixture", hosts: [host] });
      case "/ws/device": if (server.upgrade(req)) return;
    }
    return new Response(null, { status: 404 });
  },
  websocket: {
    open(ws) { ws.send(JSON.stringify({ relay: "hosts", hosts: [host] })); },
    message(ws, data) {
      const { msg: req } = JSON.parse(String(data));
      if (!req) return;
      const send = (msg: object) => ws.send(JSON.stringify({ host: host.id, msg }));
      const results: Record<string, unknown> = {
        sessions: [session], open: { ...session, items, config, permission: null }, options: config,
        prompts: [], mcpServers: ["fixture-mcp"], sessionMcp: req.disabled,
      };
      send({ t: "reply", id: req.id, ok: true, result: results[req.op] ?? null });
      if (req.op === "prompt") {
        send({ t: "item", s: session.id, item: { id: req.item, role: "user", text: req.text } });
        send({ t: "state", s: session.id, running: true });
        setTimeout(() => {
          send({ t: "item", s: session.id, item: { id: "live", role: "assistant", text: "Visible follow-up reply." } });
          send({ t: "state", s: session.id, running: false });
        }, 800);
      }
    },
  },
});
