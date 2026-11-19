// `libfx` in browsers and other non-Node hosts, and `libfx/browser` (browser.js).
import type {
  SparkAgent,
  SparkAgentOptions,
  SparkBrowserBackendOptions,
  SparkEngine,
  SparkEngineOptions,
  SparkTerminal,
  SparkTerminalOptions,
} from "./libfx.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  SparkFencedError,
  SparkJournalVersionError,
  fxSdkApiVersion,
  listModels,
  memory,
  supportsJspi,
  xtermAdapter,
} from "./libfx.cjs";

export type {
  Durability,
  SparkAccepted,
  SparkAgent,
  SparkAgentEvent,
  SparkAgentHostTool,
  SparkAgentKeyedTool,
  SparkAgentOptions,
  SparkAgentTool,
  SparkAgentTools,
  SparkApiKeyCredentials,
  SparkBrowserBackendOptions,
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
  SparkIdleResult,
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
  SparkPromptOptions,
  SparkProviderCredentials,
  SparkProviderTool,
  SparkResizedImage,
  SparkResourceBlock,
  SparkResumeOptions,
  SparkResumeTurn,
  SparkSession,
  SparkSessionEvent,
  SparkSessionImageBlock,
  SparkSessionOptions,
  SparkSessionPromptInput,
  SparkSessionTurnEvent,
  SparkSharedOptions,
  SparkSteer,
  SparkSteerOptions,
  SparkSteered,
  SparkSteeringInput,
  SparkStopReason,
  SparkStreamLine,
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
  SparkTurn,
  SparkTurnEvent,
  SparkTurnResult,
  SparkTurnView,
  SparkUsage,
  SparkWasmModule,
  SparkWasmSource,
  SparkWorkspace,
  SparkWorkspaceExecResult,
  SparkXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryOptions,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libfx.cjs";

/** Options for `createFxAgent()` in browsers. */
export type SparkBrowserAgentOptions = SparkAgentOptions & SparkBrowserBackendOptions;

/** Options for `createFxEngine()` in browsers. */
export type SparkBrowserEngineOptions = SparkEngineOptions & SparkBrowserBackendOptions;

/** Options for `createFxTerminal()` in browsers. */
export type SparkBrowserTerminalOptions = SparkTerminalOptions & SparkBrowserBackendOptions;

/**
 * An agent whose sessions live in this page unless `durability` says
 * otherwise. It returns at once and does no I/O until a session runs a turn.
 */
export declare function createFxAgent(options?: SparkBrowserAgentOptions): SparkAgent;

/** One spark session on WebAssembly, with no durability of its own. `apiKey` is required. */
export declare function createFxEngine(options: SparkBrowserEngineOptions): Promise<SparkEngine>;

/** The interactive terminal harness. Connect it to xterm.js with `xtermAdapter()`. */
export declare function createFxTerminal(options: SparkBrowserTerminalOptions): Promise<SparkTerminal>;

/** The version of the libfx agent API. */
export declare const libfxApiVersion: 3;
