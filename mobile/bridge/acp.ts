import type { Subprocess } from "bun";

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void };

/** `p`, or `message` as an error once `ms` pass */
export function deadline<T>(p: Promise<T>, ms: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const late = new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(message)), ms)));
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

/** One `spark acp` process, spoken to over newline-delimited JSON-RPC on stdio. */
export class Acp {
  private proc: Subprocess<"pipe", "pipe", "pipe">;
  private next = 1;
  private pending = new Map<number, Pending>();
  private closed = false;
  onNotify: (method: string, params: any) => void = () => {};
  onRequest: (id: number | string, method: string, params: any) => void = () => {};
  onExit: () => void = () => {};

  constructor(spark: string, cwd: string, env: Record<string, string | undefined>) {
    this.proc = Bun.spawn([spark, "acp"], {
      cwd,
      env: { ...process.env, ...env, SPARK_SOUND: "0" },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    this.read();
    this.drain();
    this.proc.exited.then(() => {
      this.closed = true;
      for (const p of this.pending.values()) p.reject(new Error("spark stopped"));
      this.pending.clear();
      this.onExit();
    });
  }

  get alive() {
    return !this.closed;
  }

  private async read() {
    const decoder = new TextDecoder();
    let buf = "";
    for await (const chunk of this.proc.stdout) {
      buf += decoder.decode(chunk, { stream: true });
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) this.handle(line);
      }
    }
  }

  /** stderr is only kept clear so the process never blocks on a full pipe */
  private async drain() {
    for await (const _ of this.proc.stderr) {
    }
  }

  private handle(line: string) {
    let m: any;
    try {
      m = JSON.parse(line);
    } catch {
      return;
    }
    if (m.method && m.id !== undefined) return this.onRequest(m.id, m.method, m.params);
    if (m.method) return this.onNotify(m.method, m.params);
    const p = this.pending.get(m.id);
    if (!p) return;
    this.pending.delete(m.id);
    if (m.error) p.reject(new Error(m.error.message ?? "spark error"));
    else p.resolve(m.result);
  }

  private write(o: unknown) {
    if (this.closed) return;
    this.proc.stdin.write(JSON.stringify(o) + "\n");
    this.proc.stdin.flush();
  }

  call<T = any>(method: string, params: unknown): Promise<T> {
    if (this.closed) return Promise.reject(new Error("spark stopped"));
    const id = this.next++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.write({ jsonrpc: "2.0", method, params });
  }

  respond(id: number | string, result: unknown) {
    this.write({ jsonrpc: "2.0", id, result });
  }

  async initialize() {
    return this.call("initialize", { protocolVersion: 1, clientCapabilities: {} });
  }

  kill() {
    if (!this.closed) this.proc.kill();
  }

  /** stops spark and waits until it has exited, so its session lock is free */
  async stop() {
    this.kill();
    await this.proc.exited;
  }
}
