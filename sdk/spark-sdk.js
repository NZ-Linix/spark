// `libfx/wasm`: the spark engine and terminal on WebAssembly. It names no
// packaged asset, so every factory takes its `wasm` explicitly.
import { createFxEngine as createEngine } from "./engine.js";
import { wasmRuntimeFactory } from "./wasm-runtime.js";

export {
  checkPromptInput,
  coreAnswered,
  createMemoryPersistence,
  engineInternals,
  SparkFencedError,
  SparkJournalVersionError,
  fxSdkApiVersion,
  journalMarksWanted,
  listModels,
  normalizeAgentOptions,
  normalizeInstructions,
  normalizeModelChoice,
  persistenceImages,
  resumeOutputShown,
  supportsJspi,
} from "./engine.js";
export { encodeXtermKeyEvent, xtermAdapter } from "./xterm.js";
export { createFxTerminal } from "./wasm-terminal.js";

export function createFxEngine(options = {}) {
  return createEngine(options, wasmRuntimeFactory());
}
