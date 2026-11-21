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
  items: Item[];
  config: ConfigOption[];
  permission: Permission | null;
  usage?: { used: number; size: number };
};

export type Folder = { name: string; path: string; git: boolean };

/** one prompt in the library: a whole system prompt a new chat can start with */
export type PromptSummary = { name: string; text: string; updatedAt: string };

/** phone → host */
export type Request =
  | { id: number; op: "hello" }
  | { id: number; op: "sessions" }
  | { id: number; op: "open"; s: string }
  /** `prompt` names a library prompt the session runs with instead of spark's own */
  | { id: number; op: "new"; cwd: string; prompt?: string }
  /** `item` is the id the phone shows the message under until the host's copy arrives */
  | { id: number; op: "prompt"; s: string; text: string; item?: string }
  | { id: number; op: "cancel"; s: string }
  | { id: number; op: "config"; s: string; option: string; value: string }
  | { id: number; op: "options" }
  | { id: number; op: "answer"; s: string; request: string; option: string | null }
  | { id: number; op: "close"; s: string }
  | { id: number; op: "sessionRename"; s: string; title: string }
  | { id: number; op: "sessionDelete"; s: string }
  | { id: number; op: "folders"; path?: string }
  | { id: number; op: "mkdir"; path: string; name: string }
  | { id: number; op: "folderRename"; path: string; name: string }
  | { id: number; op: "folderDelete"; path: string }
  | { id: number; op: "search"; query: string; path?: string }
  | { id: number; op: "providers" }
  /** Mac only */
  | { id: number; op: "providerExport"; name: string }
  /** a key left out keeps the saved one; `env` is cloud only; `previous` renames */
  | { id: number; op: "providerPut"; name: string; provider: Record<string, unknown>; model?: string; env?: Record<string, string>; previous?: string }
  | { id: number; op: "providerDelete"; name: string }
  /** the library's prompts; the cloud keeps them */
  | { id: number; op: "prompts" }
  /** `previous` renames */
  | { id: number; op: "promptPut"; name: string; text: string; previous?: string }
  | { id: number; op: "promptDelete"; name: string };

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
  | { t: "sessions"; sessions: SessionInfo[] };

export type HostInfo = { name: string; kind: "mac" | "cloud"; home: string; platform: string };
