// `libfx/wasm` (spark-sdk.js): the WebAssembly SDK with no packaged asset paths,
// so every factory takes its `wasm` explicitly.
import type { SparkEngine, SparkEngineOptions, SparkTerminal, SparkTerminalOptions, SparkWasmSource } from "./libfx.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  SparkFencedError,
  SparkJournalVersionError,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./libfx.cjs";

export type {
  SparkApiKeyCredentials,
  SparkBytes,
  SparkCheckpointMeta,
  SparkCodexProvider,
  SparkCustomProvider,
  SparkCustomProviderDefinition,
  SparkCustomProviderModel,
  SparkEffort,
  SparkEngine,
  SparkEngineEvent,
  SparkEngineOptions,
  SparkEnginePromptOptions,
  SparkEngineStorage,
  SparkEngineTurn,
  SparkEngineTurnResult,
  SparkErrorSummary,
  SparkFetch,
  SparkFollowUp,
  SparkGatewayProvider,
  SparkGrokProvider,
  SparkHostTool,
  SparkHooks,
  SparkHookEvent,
  SparkHookMessage,
  SparkHookToolCall,
  SparkImageBlock,
  SparkJsonSchema,
  SparkKeyedTool,
  SparkKeyEventLike,
  SparkListModelsOptions,
  SparkModelCatalogEntry,
  SparkModelChoice,
  SparkModelOptions,
  SparkOnAmbiguous,
  SparkPromptBlock,
  SparkPromptInput,
  SparkProviderCredentials,
  SparkProviderTool,
  SparkResizedImage,
  SparkResourceBlock,
  SparkResumeOptions,
  SparkSharedOptions,
  SparkSteer,
  SparkSteeringInput,
  SparkStopReason,
  SparkTerminal,
  SparkTerminalAdapter,
  SparkTerminalEvent,
  SparkTerminalOptions,
  SparkTextBlock,
  SparkTool,
  SparkToolContext,
  SparkToolObservation,
  SparkWaitRequest,
  SparkWaitResponse,
  SparkToolImage,
  SparkToolResult,
  SparkTools,
  SparkTurnEvent,
  SparkUsage,
  SparkWasmModule,
  SparkWasmSource,
  SparkWorkspace,
  SparkWorkspaceExecResult,
  SparkXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libfx.cjs";

/** Options for `createFxEngine()` from `libfx/wasm`. */
export type SparkWasmEngineOptions = SparkEngineOptions & {
  /** The `spark-core.wasm` asset. */
  wasm: SparkWasmSource;
};

/** Options for `createFxTerminal()` from `libfx/wasm`. */
export type SparkWasmTerminalOptions = SparkTerminalOptions & {
  /** The `spark-term.wasm` asset. */
  wasm: SparkWasmSource;
};

/** One session on one spark core, with no durability of its own. Requires JSPI. */
export declare function createFxEngine(options: SparkWasmEngineOptions): Promise<SparkEngine>;

/** The interactive terminal harness on WebAssembly. Requires JSPI. */
export declare function createFxTerminal(options: SparkWasmTerminalOptions): Promise<SparkTerminal>;
