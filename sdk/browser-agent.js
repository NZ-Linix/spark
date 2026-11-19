// The agent and engine for `libfx/browser`, with their packaged spark-core.wasm.
import { createDurableAgentFactory, memory } from "./durable.js";
import { createFxEngine as createEngine } from "./engine.js";
import { fxHarness } from "./spark-harness.js";
import { wasmRuntimeFactory } from "./wasm-runtime.js";

export const libfxApiVersion = 3;

/** One spark session on WebAssembly, with no durability of its own. */
export function createFxEngine(options = {}) {
  // A literal URL, which bundlers rewrite to the spark-core.wasm they emit.
  return createEngine({ ...options, wasm: options.wasm ?? new URL("./spark-core.wasm", import.meta.url).href }, wasmRuntimeFactory());
}

/** An agent whose sessions live in this page unless `durability` says otherwise. */
export const createFxAgent = /* @__PURE__ */ createDurableAgentFactory({
  name: "createFxAgent",
  label: "spark agent",
  defaultDurability: async () => memory(),
  harness: /* @__PURE__ */ fxHarness({ createEngine: createFxEngine }),
});
