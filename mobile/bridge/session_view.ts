import { deadline } from "./acp";
import type { Item } from "./protocol";

const READ_MS = 5_000;
/** the turns a read-only chat shows; spark's own limit for `--tail` is 1000 */
const TAIL_TURNS = 100;
const MAX_DETAIL_BYTES = 16 * 1024 * 1024;
const OUTPUT_TAIL = 6000;
/** what spark sends the model when it resumes a request; it replays as this notice, never as the user's words */
const RESUMED_PROMPT = "<session_resumed>";

/**
 * A saved session's finished turns, from `spark session <id> --json`. Reading takes no lock, so it
 * works while another spark process has the session open, such as spark in a terminal.
 */
export async function readSession(spark: string, id: string, env: Record<string, string | undefined> = {}): Promise<any> {
  const proc = Bun.spawn([spark, "session", id, "--json", "--tail", String(TAIL_TURNS)], {
    env: { ...process.env, ...env, SPARK_SOUND: "0" },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  });
  try {
    const text = await deadline(readCapped(proc.stdout, MAX_DETAIL_BYTES), READ_MS, "spark took too long to read that chat.");
    let parsed: any;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error("spark couldn't read that chat.");
    }
    if (parsed?.kind !== "session_detail") throw new Error(typeof parsed?.error === "string" ? `spark couldn't read that chat: ${parsed.error}` : "spark couldn't read that chat.");
    return parsed;
  } finally {
    proc.kill();
  }
}

async function readCapped(stream: ReadableStream<Uint8Array>, max: number): Promise<string> {
  const decoder = new TextDecoder();
  let out = "";
  let bytes = 0;
  for await (const chunk of stream) {
    bytes += chunk.length;
    if (bytes > max) throw new Error("That chat is too big to show on the phone.");
    out += decoder.decode(chunk, { stream: true });
  }
  return out + decoder.decode();
}

/**
 * The chat items for a `session_detail`, in the order spark replays them over ACP: each turn's
 * message, its tool steps with the text between them, then the reply. Ids come from the turn's
 * number and the tool call's id, so reading the session again keeps every row in place.
 */
export function historyItems(detail: any): Item[] {
  const items: Item[] = [];
  const history: any[] = Array.isArray(detail?.history) ? detail.history : [];
  const first = typeof detail?.first_turn === "number" ? detail.first_turn : 1;
  if (first > 1) items.push({ id: "h:earlier", role: "notice", text: `Earlier turns aren't shown here. ${first - 1} came before these.` });
  history.forEach((turn, i) => {
    const n = first + i;
    let part = 0;
    const say = (text: unknown) => {
      if (typeof text === "string" && text.length > 0) items.push({ id: `h${n}:a${part++}`, role: "assistant", text });
    };
    if (turn?.kind !== "assistant" && turn?.kind !== "interrupted") return;
    const user = typeof turn.user?.text === "string" ? turn.user.text : "";
    if (user.startsWith(RESUMED_PROMPT)) items.push({ id: `h${n}:u`, role: "notice", text: "spark resumed the request it was working on." });
    else if (user) items.push({ id: `h${n}:u`, role: "user", text: user });
    executionItems(turn.execution, n, items, say);
    say(turn.assistant);
    if (turn.kind === "interrupted") items.push({ id: `h${n}:stopped`, role: "notice", text: "This turn stopped before it finished." });
  });
  return items;
}

function executionItems(execution: any, n: number, items: Item[], say: (text: unknown) => void) {
  const steps: any[] = Array.isArray(execution?.tool_steps) ? execution.tool_steps : [];
  const steering: any[] = Array.isArray(execution?.steering) ? execution.steering : [];
  let s = 0;
  const steer = (done: number | null) => {
    for (; s < steering.length; s++) {
      const entry = steering[s];
      const text = typeof entry === "string" ? entry : entry?.text;
      const after = typeof entry?.after_tool_step_count === "number" ? entry.after_tool_step_count : steps.length;
      if (done !== null && after !== done) return;
      say(entry?.assistant_prefix);
      if (typeof text === "string" && text) items.push({ id: `h${n}:s${s}`, role: "user", text });
    }
  };
  steer(0);
  steps.forEach((step, i) => {
    say(step?.assistant);
    const calls: any[] = Array.isArray(step?.tool_calls) ? step.tool_calls : [];
    const results: any[] = Array.isArray(step?.tool_results) ? step.tool_results : [];
    const used = new Set<any>();
    for (const call of calls) {
      const result = results.find((r) => r?.tool_call_id === call?.id);
      if (result) used.add(result);
      items.push(toolItem(String(call?.id ?? `h${n}:t${items.length}`), String(call?.name ?? "tool"), call?.arguments_json, result));
    }
    // a result whose call was trimmed from the history still shows, as spark replays it
    for (const result of results) {
      if (!used.has(result)) items.push(toolItem(String(result?.tool_call_id ?? `h${n}:t${items.length}`), String(result?.tool_name ?? "tool"), "{}", result));
    }
    steer(i + 1);
  });
  steer(null);
}

/** spark's ACP tool kinds, from `mapToolKind` in `src/acp/tool_call_presentation.zig` */
const KINDS: Record<string, string> = {
  glob_files: "read",
  grep_files: "search",
  read_file: "read",
  web_fetch: "fetch",
  web_search: "search",
  write_file: "edit",
  edit_file: "edit",
  shell: "execute",
  terminal: "execute",
  run_command: "execute",
};

function toolItem(id: string, name: string, args: unknown, result: any): Item {
  let input: any;
  try {
    input = typeof args === "string" ? JSON.parse(args) : undefined;
  } catch {
    input = undefined;
  }
  const status = result ? (result.status === "failure" ? "failed" : "completed") : "pending";
  const item: Item = { id, role: "tool", text: "", name, title: name, kind: KINDS[name] ?? "other", status, detail: describe(input) };
  const output = resultText(name, result?.output);
  if (output) item.output = output.length > OUTPUT_TAIL ? output.slice(-OUTPUT_TAIL) : output;
  return item;
}

/** what a tool printed: a shell result is JSON around the command's output */
function resultText(name: string, output: unknown): string {
  if (typeof output !== "string") return "";
  if (name !== "shell") return output;
  try {
    const parsed = JSON.parse(output);
    if (typeof parsed?.output_delta === "string") return [parsed.notice, parsed.output_delta].filter((s) => typeof s === "string" && s).join("\n");
  } catch {
    // not JSON: show it as it is
  }
  return output;
}

export function describe(input: any): string | undefined {
  if (!input || typeof input !== "object") return undefined;
  const v = input.command ?? input.cmd ?? input.path ?? input.file_path ?? input.filePath ?? input.pattern ?? input.query ?? input.url ?? input.name;
  if (typeof v === "string") return v.length > 400 ? v.slice(0, 400) + "…" : v;
  if (Array.isArray(v)) return v.join(" ");
  return undefined;
}
