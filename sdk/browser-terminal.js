// The spark terminal for `libfx/browser`, with its packaged spark-term.wasm.
import { createFxTerminal as createWasmTerminal } from "./wasm-terminal.js";

export function createFxTerminal(options = {}) {
  // A literal URL, which bundlers rewrite to the spark-term.wasm they emit.
  return createWasmTerminal({ ...options, wasm: options.wasm ?? new URL("./spark-term.wasm", import.meta.url).href });
}
