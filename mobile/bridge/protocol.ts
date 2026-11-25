/**
 * What the phone and a host say to each other. The relay only routes these: a phone wraps each one
 * as `{ host, msg }`, and a host answers with `{ to?, msg }`.
 */

export type Role = "user" | "assistant" | "thought" | "tool" | "notice";

export type Item = {
  id: string;
  role: Role;
  text: string;
  /** tools only */
  name?: string;
  title?: string;
  kind?: string;
  status?: "pending" | "in_progress" | "completed" | "failed";
  /** tools only: what it ran or touched, for one line in the chat */
  detail?: string;
  /** tools only: the tail of what it printed */
  output?: string;
};

export type ConfigOption = {
  id: string;
  name: string;
  category?: string;
  currentValue: string;
  options: { value: string; name: string; description?: string }[];
};

export type Permission = {
  id: string;
  title: string;
  detail?: string;
  kind?: string;
  options: { optionId: string; name: string; kind: string }[];
};

export type SessionInfo = {
  id: string;
  title: string;
  cwd: string;
  updatedAt: string;
  live: boolean;
  running: boolean;
  /** "phone": started from the phone. "mac": open in a spark process on the Mac, such as a terminal */
  origin: "phone" | "mac";
  /** started without a folder: it runs in a folder of its own, which goes when the chat is deleted */
  scratch?: boolean;
};

/** one provider in a profile's settings.json */
export type ProviderSummary = {
  name: string;
  /** the name menus show, such as "OpenCode Go" for oc-go */
  displayName?: string;
  protocol: string;
  baseUrl: string;
  auth: "none" | "key" | "bearer";
  /** the key's last 4 characters, for auth "key" */
  keyHint?: string;
  /** the variable the key is read from, for auth "bearer" */
  keyEnv?: string;
  /** the variables its header values are read from */
  headerEnv: string[];
  models: string[];
  /** the saved model for this provider (`models[name]`) */
  model?: string;
  /** the profile's chosen provider */
  active: boolean;
  /** the whole provider as settings.json holds it, with its key left out */
  provider: Record<string, unknown>;
};

/** a Mac provider ready for the cloud: its bearer key is now a key, and `env` holds its header values */
export type ProviderExport = {
  name: string;
  provider: Record<string, unknown>;
  model?: string;
  env: Record<string, string>;
  /** the Mac variable the key came from, when it was a bearer provider */
  keyFrom?: string;
};

export type Snapshot = SessionInfo & {
  /**
   * Open in another spark process, which remains the session's sole writer. A terminal owner
   * lets the phone send to that process; without one, only saved turns are available.
   */
  elsewhere?: boolean;
  terminalOwner?: string;
  terminalRevision?: string;
  items: Item[];
  config: ConfigOption[];
  permission: Permission | null;
  usage?: { used: number; size: number };
  /** the library prompt the session runs with instead of spark's own */
  prompt?: string;
  mcpDisabled?: string[];
  /** after a rewind before a message: that message's text, for the composer */
  restored?: string;
};

export type Folder = { name: string; path: string; git: boolean };

/** one thing in a folder, for the chat's file browser; `size` is in bytes and only for files */
export type FileEntry = { name: string; path: string; dir: boolean; size?: number };
export type FileListing = { path: string; name: string; entries: FileEntry[] };

/**
 * A file to show. Text comes as text, cut at a limit; an image comes as base64; anything else is
 * only named, with its size.
 */
export type FileContent = {
  path: string;
  name: string;
  size: number;
  kind: "text" | "image" | "binary";
  text?: string;
  data?: string;
  truncated?: boolean;
  /** when it last changed, in ms; a save sends it back so it can't overwrite newer work */
  modified: number;
};

/** one piece of a file; the phone asks again from `offset + bytes` until it has `size` */
export type FileData = { path: string; name: string; size: number; offset: number; data: string };

/** one prompt in the library: a whole system prompt a new chat can start with */
export type PromptSummary = { name: string; text: string; updatedAt: string };

/**
 * One MCP server in the library. `server` is the entry as mcp.json holds it, except that each env
 * or header value other than a ${VAR} reference is null; `hints` has its last 4 characters, keyed
 * "env.NAME" or "headers.NAME". A null sent back keeps the saved value.
 */
export type McpSummary = { name: string; server: Record<string, unknown>; hints: Record<string, string> };

/** phone → host */
export type Request =
  | { id: number; op: "hello" }
  | { id: number; op: "sessions" }
  | { id: number; op: "open"; s: string }
  | { id: number; op: "watchTerminal"; s: string; revision?: string }
  /**
   * `prompt` names a library prompt the session runs with instead of spark's own. Without `cwd` the
   * session gets a new folder of its own.
   */
  | { id: number; op: "new"; cwd?: string; prompt?: string; mcpDisabled?: string[] }
  /** `item` is the id the phone shows the message under until the host's copy arrives */
  | { id: number; op: "prompt"; s: string; text: string; item?: string; terminalOwner?: string }
  | { id: number; op: "cancel"; s: string; terminalOwner?: string }
  /**
   * Takes the chat back to message `item`: without `keep`, to just before it (its text comes back
   * as `restored`); with `keep`, to just after the reply it belongs to. spark keeps the chat's turns
   * before that point under a new id, and the old session goes. Answers the new Snapshot.
   */
  | { id: number; op: "rewind"; s: string; item: string; keep?: boolean }
  /** runs the session with library prompt `prompt` from its next message, or spark's own with null */
  | { id: number; op: "sessionPrompt"; s: string; prompt: string | null }
  | { id: number; op: "config"; s: string; option: string; value: string }
  | { id: number; op: "options" }
  | { id: number; op: "mcpServers" }
  | { id: number; op: "sessionMcp"; s: string; disabled: string[] }
  | { id: number; op: "answer"; s: string; request: string; option: string | null }
  | { id: number; op: "close"; s: string }
  | { id: number; op: "sessionRename"; s: string; title: string }
  | { id: number; op: "sessionDelete"; s: string }
  | { id: number; op: "folders"; path?: string }
  | { id: number; op: "mkdir"; path: string; name: string }
  | { id: number; op: "folderRename"; path: string; name: string }
  | { id: number; op: "folderDelete"; path: string }
  | { id: number; op: "search"; query: string; path?: string }
  | { id: number; op: "files"; path: string }
  | { id: number; op: "file"; path: string }
  /** a file's bytes for the phone to keep or share, a piece at a time from `offset` */
  | { id: number; op: "fileData"; path: string; offset?: number }
  /** `modified` is the time the phone read it; a file changed since is left alone */
  | { id: number; op: "fileWrite"; path: string; text: string; modified?: number }
  /** a new empty file, or a folder with `dir`, named `name` in the folder at `path` */
  | { id: number; op: "fileCreate"; path: string; name: string; dir?: boolean }
  | { id: number; op: "entryRename"; path: string; name: string }
  | { id: number; op: "entryDelete"; path: string }
  /** runs one shell command in `cwd`; its output comes as `term` events under `run`, the phone's id for it */
  | { id: number; op: "run"; run: string; cwd: string; command: string }
  | { id: number; op: "runStop"; run: string }
  | { id: number; op: "providers" }
  | { id: number; op: "chatgptAccounts" }
  | { id: number; op: "chatgptAccount"; action: "connect" | "reconnect" | "remove"; value: string }
  /** Mac only */
  | { id: number; op: "providerExport"; name: string }
  /** a key left out keeps the saved one; `env` is cloud only; `previous` renames */
  | { id: number; op: "providerPut"; name: string; provider: Record<string, unknown>; model?: string; env?: Record<string, string>; previous?: string }
  | { id: number; op: "providerDelete"; name: string }
  /** the library's prompts; the cloud keeps them */
  | { id: number; op: "prompts" }
  /** `previous` renames */
  | { id: number; op: "promptPut"; name: string; text: string; previous?: string }
  | { id: number; op: "promptDelete"; name: string }
  /** the library's MCP servers; the cloud keeps them, and every Mac gets a copy */
  | { id: number; op: "mcpList" }
  /** `previous` renames */
  | { id: number; op: "mcpPut"; name: string; server: Record<string, unknown>; previous?: string }
  | { id: number; op: "mcpDelete"; name: string }
  | { id: number; op: "mcpEnabled"; name: string; enabled: boolean };

/** host → phone */
export type Event =
  | { t: "reply"; id: number; ok: true; result: unknown }
  | { t: "reply"; id: number; ok: false; error: string }
  | { t: "item"; s: string; item: Item }
  | { t: "append"; s: string; id: string; text: string }
  | { t: "state"; s: string; running: boolean; reason?: string; error?: string }
  | { t: "info"; s: string; title: string; updatedAt: string }
  | { t: "config"; s: string; config: ConfigOption[] }
  | { t: "usage"; s: string; used: number; size: number }
  | { t: "permission"; s: string; permission: Permission | null }
  | { t: "sessions"; sessions: SessionInfo[] }
  /** a command's output as it comes, then once with `done`, its exit code, and the folder it ended in */
  | { t: "term"; run: string; data: string }
  | { t: "term"; run: string; done: true; code: number; cwd: string };

export type HostInfo = { name: string; kind: "mac" | "cloud"; home: string; platform: string };
