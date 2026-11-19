// `libfx` and `libfx/node` on Node.js, for `require` (node.cjs). The ESM entry,
// node.d.ts, re-exports this file: node.cjs is built from node.js.
import type {
  SparkAgent,
  SparkAgentOptions,
  SparkBackendInfo,
  SparkBackendInfoOptions,
  SparkEngine,
  SparkEngineOptions,
  SparkNodeBackendOptions,
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
  wakeHandler,
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
  SparkBackendAttempt,
  SparkBackendChoice,
  SparkBackendInfo,
  SparkBackendInfoOptions,
  SparkBackendReason,
  SparkBackendReasonCode,
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
  SparkNodeBackendOptions,
  SparkNodeWasmSource,
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

/** Options for `createFxAgent()` on Node.js. */
export type SparkNodeAgentOptions = SparkAgentOptions & SparkNodeBackendOptions;

/** Options for `createFxEngine()` on Node.js. */
export type SparkNodeEngineOptions = SparkEngineOptions & SparkNodeBackendOptions;

/** Options for `createFxTerminal()` on Node.js. */
export type SparkNodeTerminalOptions = SparkTerminalOptions & SparkNodeBackendOptions;

/**
 * An agent whose sessions survive crashes, timeouts, and redeployments. It
 * returns at once and does no I/O until a session runs a turn. Without
 * `durability`, sessions live in Vercel's World on Vercel and in local files
 * elsewhere.
 */
export declare function createFxAgent(options?: SparkNodeAgentOptions): SparkAgent;

/**
 * The kernel under `createFxAgent()`: one conversation, held in the memory of
 * the process that runs it. `apiKey` is required, and it resolves once its
 * backend has loaded.
 */
export declare function createFxEngine(options: SparkNodeEngineOptions): Promise<SparkEngine>;

/** The interactive terminal harness. */
export declare function createFxTerminal(options: SparkNodeTerminalOptions): Promise<SparkTerminal>;

/** Inspects backend availability without creating an agent or terminal. */
export declare function getBackendInfo(options?: SparkBackendInfoOptions): Promise<SparkBackendInfo>;

/** The version of the libfx agent API. */
export declare const libfxApiVersion: 3;
