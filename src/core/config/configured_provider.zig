const std = @import("std");
const request_fragment = @import("request_fragment.zig");
const plan_kind = @import("../auth/plan_kind.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

const max_providers = 32;
const max_models = 256;
pub const max_id_bytes = 64;
pub const max_model_bytes = 1024;
const max_url_bytes = 2048;
const max_env_bytes = 128;
const max_json_bytes = 1024 * 1024;
/// As many levels as spark offers for any model (`types.ReasoningEffort.max_options`).
pub const max_effort_levels = 16;
const max_effort_name_bytes = 64;
const max_headers = 16;
const max_header_name_bytes = 64;
/// One day: longer than any wait a person sits through, and it keeps every
/// bound far from overflow.
pub const max_timeout_ms = 24 * 60 * 60 * 1000;

pub const ParseError = Allocator.Error || error{
    InvalidJson,
    DuplicateField,
    LimitExceeded,
    InvalidObject,
    UnknownField,
    MissingField,
    InvalidProviderId,
    ReservedProviderId,
    InvalidProtocol,
    InvalidBaseUrl,
    InsecureBaseUrl,
    InvalidAuth,
    InvalidEnvironmentName,
    InvalidToolChoiceMode,
    InvalidModelId,
    InvalidModelMetadata,
    InvalidRequestFields,
    ReservedRequestField,
    InvalidEffortLevel,
    InvalidHeader,
    InvalidHeaderName,
    ReservedHeader,
    InvalidTimeout,
    InvalidConnectionOption,
    InvalidDisplayName,
};

pub const Protocol = enum {
    @"openai-chat-completions",
    @"openai-responses",
    @"anthropic-messages",
    /// Google's Cloud Code Assist wrapper around Gemini `generateContent`,
    /// spoken only by Antigravity plan accounts.
    @"gemini-code-assist",

    /// Where a model request goes, after the connection's base URL.
    pub fn request_path(self: Protocol) []const u8 {
        return switch (self) {
            .@"openai-chat-completions" => "/chat/completions",
            .@"openai-responses" => "/responses",
            .@"anthropic-messages" => "/messages",
            .@"gemini-code-assist" => "/v1internal:streamGenerateContent?alt=sse",
        };
    }

    /// The top-level request fields spark writes itself. A model's `request`
    /// fields and its effort levels cannot name one
    /// (`tests/tla/configured_provider/ConfiguredRequest.tla`
    /// OwnedKeysKeepFxValue). The reasoning controls are left out on purpose:
    /// an effort level is how a connection sets them.
    pub fn owned_request_fields(self: Protocol) []const []const u8 {
        return switch (self) {
            .@"openai-chat-completions" => &.{ "model", "messages", "stream", "stream_options", "tools", "tool_choice", "parallel_tool_calls", "max_tokens", "max_completion_tokens", "response_format" },
            .@"openai-responses" => &.{ "model", "input", "instructions", "stream", "store", "tools", "tool_choice", "parallel_tool_calls", "max_output_tokens", "include", "text" },
            .@"anthropic-messages" => &.{ "model", "messages", "system", "stream", "tools", "tool_choice", "max_tokens" },
            // An effort level may name the model of its tier (`gemini-3-pro-high`).
            .@"gemini-code-assist" => &.{ "project", "request", "requestType", "userAgent", "requestId" },
        };
    }
};

pub const ToolChoiceMode = enum { omit, send };

/// The Chat Completions field that carries the output limit. Servers differ:
/// some read only one of the two and ignore the other without an error.
pub const OutputLimitField = enum { max_tokens, max_completion_tokens };

/// Describes a credential slot, never a credential value. Resolution belongs at
/// the effectful edge; `none` must omit Authorization rather than supply a token.
pub const Auth = union(enum) {
    none,
    bearer: []const u8,
    /// A key saved by `/provider` in the profile settings file itself.
    key: []const u8,
    /// A subscription account signed in with `/provider`; its OAuth
    /// credentials stay in the plan's private folder in the profile.
    chatgpt_plan,
    claude_plan,
    antigravity_plan,

    pub fn plan(self: Auth) ?plan_kind.Kind {
        return switch (self) {
            .chatgpt_plan => .chatgpt,
            .claude_plan => .claude,
            .antigravity_plan => .antigravity,
            .none, .bearer, .key => null,
        };
    }

    pub fn of_plan(kind: plan_kind.Kind) Auth {
        return switch (kind) {
            .chatgpt => .chatgpt_plan,
            .claude => .claude_plan,
            .antigravity => .antigravity_plan,
        };
    }
};

/// A request header whose value is read from the environment variable `env`
/// when a request is sent, or, with `session_id`, is spark's ID for the
/// session the request belongs to. Like `Auth`, it never holds the value.
pub const Header = struct {
    name: []const u8,
    /// Empty when `session_id` is set.
    env: []const u8 = "",
    /// `{"session_id": true}`: the session's ID, so a server can keep one
    /// conversation's requests together. A request with no session, such as
    /// listing models, leaves the header out.
    session_id: bool = false,
};

/// How long one request may wait. Null keeps spark's own bound for that wait
/// (`tests/tla/configured_provider/ConfiguredDeadlines.tla`).
pub const Timeouts = struct {
    connect_ms: ?u32 = null,
    first_response_ms: ?u32 = null,
    stall_ms: ?u32 = null,
};

/// One effort level a model offers, and the request fields that choose it.
pub const EffortLevel = struct {
    name: []const u8,
    fields: request_fragment.Fragment,
};

pub const ModelMetadata = struct {
    id: []const u8,
    /// The name pickers show in place of `id`.
    display_name: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_tool_use: ?bool = null,
    supports_vision: ?bool = null,
    /// Chat Completions only. Null sends `max_tokens`.
    output_limit_field: ?OutputLimitField = null,
    /// Fields sent with every request for the model.
    request: ?request_fragment.Fragment = null,
    /// The levels spark offers for the model, in the settings' order. Null means
    /// the settings do not say; an empty list says the model has none.
    reasoning_efforts: ?[]const EffortLevel = null,

    pub fn effort(self: *const ModelMetadata, name: []const u8) ?*const EffortLevel {
        const levels = self.reasoning_efforts orelse return null;
        for (levels) |*level| {
            if (std.mem.eql(u8, level.name, name)) return level;
        }
        return null;
    }
};

/// Registry owns all slices. Treat definitions as immutable while borrowed by
/// requests; destroying the registry invalidates every definition and lookup.
pub const Definition = struct {
    id: []const u8,
    /// The name menus show in place of `id`, such as "OpenCode Go" for `oc-go`.
    display_name: ?[]const u8 = null,
    /// A subscription account's own label, such as `Work`. Its names carry
    /// the label only while its plan has more than one account.
    account_label: ?[]const u8 = null,
    protocol: Protocol,
    base_url: []const u8,
    auth: Auth,
    tool_choice_mode: ToolChoiceMode = .omit,
    /// The model that names a session from its first prompt. Null: sessions
    /// on this connection keep the title derived from the prompt.
    title_model: ?[]const u8 = null,
    /// The model that reads images for a selected model that cannot. Null:
    /// the connection has no image fallback.
    vision_model: ?[]const u8 = null,
    headers: []const Header = &.{},
    timeouts: Timeouts = .{},
    /// Ask the server for its model list (`GET {base_url}/models`). Off unless
    /// the settings turn it on, so spark never probes a server on its own
    /// (`tests/tla/configured_provider/ConfiguredCatalog.tla` NoRequestWhenOff).
    fetch_models: bool = false,
    /// Metadata for every model on the connection that does not set a field
    /// itself, including one the settings do not declare. Its `id` is empty.
    model_defaults: ?ModelMetadata = null,
    model_metadata: []const ModelMetadata = &.{},

    /// Caller owns the returned URL. base_url is already a validated API prefix.
    pub fn chat_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, "/chat/completions" });
    }

    /// The URL model requests go to for the connection's protocol. Caller owns it.
    pub fn request_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, self.protocol.request_path() });
    }

    /// The URL of the server's model list. Caller owns it.
    pub fn models_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, "/models" });
    }

    /// Borrowed metadata; absence and unspecified fields remain unknown.
    pub fn model(self: Definition, id: []const u8) ?*const ModelMetadata {
        if (id.len > max_model_bytes) return null;
        for (self.model_metadata) |*metadata| {
            if (std.mem.eql(u8, metadata.id, id)) return metadata;
        }
        return null;
    }

    /// What the connection knows about `id`: the model's own metadata, with
    /// `model_defaults` for each field it leaves out. Null when the settings
    /// say nothing about the model. The result borrows `id` and the registry.
    pub fn metadata_for(self: Definition, id: []const u8) ?ModelMetadata {
        if (id.len > max_model_bytes) return null;
        const declared = self.model(id);
        const defaults = self.model_defaults orelse return if (declared) |metadata| metadata.* else null;
        var merged: ModelMetadata = if (declared) |metadata| metadata.* else .{ .id = id };
        inline for (@typeInfo(ModelMetadata).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "id")) {
                if (@field(merged, name) == null) @field(merged, name) = @field(defaults, name);
            }
        }
        return merged;
    }

    /// Non-secret route provenance, stable across credential rotation in the
    /// same environment slot. Length framing prevents ambiguous concatenations.
    /// This does not snapshot model/compatibility policy or authorize a send.
    pub fn binding_identity(self: Definition) [32]u8 {
        // Test bundles bind a definition at comptime, where hashing needs room.
        @setEvalBranchQuota(100_000);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("spark-configured-provider-v1");
        hash_part(&hash, self.id);
        hash_part(&hash, @tagName(self.protocol));
        hash_part(&hash, self.base_url);
        hash_part(&hash, @tagName(self.auth));
        switch (self.auth) {
            .none, .chatgpt_plan, .claude_plan, .antigravity_plan => {},
            .bearer => |env| hash_part(&hash, env),
            .key => {},
        }
        return hash.finalResult();
    }
};

/// Where in the providers object a refused setting is: its keys joined with
/// dots, such as `local.model_metadata.m.request.messages`, for the message
/// that tells the person (`config_runtime.configuredProviderMessage`). A key
/// that is not a plain word is quoted, and a long one is cut on a character
/// boundary, so the path stays one short line.
pub const FailurePath = struct {
    bytes: [max_bytes]u8 = undefined,
    len: usize = 0,
    starts: [max_depth]usize = undefined,
    depth: usize = 0,

    /// Deeper than any settings path: a connection, a model, a level, a field.
    const max_depth = 8;
    const max_key_bytes = 48;
    const cut_mark = "…";
    /// Every segment at its longest, so a path never runs out of room.
    const max_bytes = max_depth * (max_key_bytes + cut_mark.len + 3);

    pub fn text(self: *const FailurePath) []const u8 {
        return self.bytes[0..self.len];
    }

    fn push(self: *FailurePath, key: []const u8) void {
        if (self.depth < max_depth) self.starts[self.depth] = self.len;
        self.depth += 1;
        if (self.depth > max_depth) return;
        if (self.depth > 1) self.append(".");
        const plain = key.len > 0 and for (key) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') break false;
        } else true;
        if (!plain) self.append("\"");
        var end = @min(key.len, max_key_bytes);
        while (end < key.len and end > 0 and key[end] & 0xC0 == 0x80) end -= 1;
        for (key[0..end]) |byte| self.append(&.{if (byte < 0x20 or byte == 0x7f) '?' else byte});
        if (end < key.len) self.append(cut_mark);
        if (!plain) self.append("\"");
    }

    fn pop(self: *FailurePath) void {
        self.depth -= 1;
        if (self.depth < max_depth) self.len = self.starts[self.depth];
    }

    fn append(self: *FailurePath, part: []const u8) void {
        const room = @min(part.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..room], part[0..room]);
        self.len += room;
    }
};

fn enter(at: ?*FailurePath, key: []const u8) void {
    if (at) |path| path.push(key);
}

fn leave(at: ?*FailurePath) void {
    if (at) |path| path.pop();
}

/// What the person does about a setting spark refused with `err`, or null when
/// `err` is not one the settings parser returns.
pub fn failure_advice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ReservedRequestField => "spark writes this field itself; remove it",
        error.ReservedHeader => "spark sets this header itself; remove it",
        error.InvalidHeader => "a header's value is {\"env\": \"VARIABLE\"}, the environment variable that holds it",
        error.InvalidHeaderName => "a header's name uses letters, digits, and !#$%&'*+-.^_`|~",
        error.DuplicateField => "another key here names the same thing, perhaps in other letter case; keep one",
        error.InvalidTimeout => "a timeout is a whole number of milliseconds from 1 to 86400000",
        error.InvalidEffortLevel => "an effort level's name uses letters, digits, -, _, and ., and is not auto, adaptive, or default",
        error.UnknownField => "spark doesn't know this field; check its spelling or remove it",
        error.MissingField => "this field is required; add it",
        error.InvalidObject => "this must be a JSON object",
        error.InvalidProtocol => "the protocol is openai-chat-completions, openai-responses, or anthropic-messages",
        error.InvalidBaseUrl => "base_url is an http or https URL with no user, query, or fragment",
        error.InsecureBaseUrl => "base_url uses https, or http only for localhost, 127.0.0.1, or [::1]",
        error.InvalidAuth => "auth is {\"type\": \"none\"}, {\"type\": \"bearer\", \"env\": \"VARIABLE\"}, or {\"type\": \"key\", \"key\": \"...\"}",
        error.InvalidEnvironmentName => "a variable's name uses letters, digits, and _, and does not start with a digit",
        error.InvalidProviderId => "a connection's name starts with a letter and uses letters, digits, _, and -",
        error.ReservedProviderId => "gateway, codex, and grok are reserved names; give the provider another name",
        error.InvalidToolChoiceMode => "tool_choice_mode is omit or send",
        error.InvalidConnectionOption => "this is true or false",
        error.InvalidDisplayName => "a display name is text of 1 to 80 bytes",
        error.InvalidModelId => "a model id is text with no control characters and no spaces at either end",
        error.InvalidModelMetadata => "spark can't use this value; spark.sh/docs/configure-spark/custom-model-connections lists each field",
        error.InvalidRequestFields => "request fields are a JSON object with non-empty keys, nested at most 16 deep",
        error.LimitExceeded => "this is over spark's limit; make it shorter, or use fewer entries",
        else => null,
    };
}

/// The longest header value spark sends from an environment variable.
pub const max_header_value_bytes = 16 * 1024;

/// Whether an environment variable's value can travel as a header value.
pub const HeaderValue = enum { usable, unset, empty, too_long, unsendable };

pub fn header_value(value: ?[]const u8) HeaderValue {
    const present = value orelse return .unset;
    if (present.len == 0) return .empty;
    if (present.len > max_header_value_bytes) return .too_long;
    for (present) |byte| {
        if (byte < 0x20 or byte == 0x7f) return .unsendable;
    }
    return .usable;
}

pub const Registry = struct {
    definitions: []const Definition = &.{},
    /// Holds every slice the definitions point at. Null for an empty registry
    /// and for a view built from another registry's `definitions`.
    arena: ?*std.heap.ArenaAllocator = null,

    /// Parse the providers object itself, not the surrounding settings object.
    /// All returned storage is owned, independent of `providers`, and must be
    /// freed with deinit using the same allocator. Errors leave no owned state.
    /// PRECONDITION: the caller's JSON parser must reject duplicate keys at all
    /// depths (including providers in the enclosing settings). Value's ObjectMap
    /// cannot retain evidence of duplicates already discarded by another parser.
    pub fn parse(alloc: Allocator, providers: std.json.Value) ParseError!Registry {
        return parse_located(alloc, providers, null);
    }

    /// `parse`, leaving in `at` where a refused setting is.
    pub fn parse_located(alloc: Allocator, providers: std.json.Value, at: ?*FailurePath) ParseError!Registry {
        if (providers != .object) return error.InvalidObject;
        if (providers.object.count() > max_providers) return error.LimitExceeded;
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const owned = arena.allocator();
        const definitions = try owned.alloc(Definition, providers.object.count());
        var iterator = providers.object.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            enter(at, entry.key_ptr.*);
            definitions[index] = try parse_definition(owned, entry.key_ptr.*, entry.value_ptr.*, at);
            leave(at);
        }
        return .{ .definitions = definitions, .arena = arena };
    }

    /// Bounded, duplicate-rejecting convenience parser for a raw providers object.
    /// std.json.Value parses iteratively; input size also bounds nesting/work.
    /// The temporary JSON tree is released before returning the owned registry.
    /// A string longer than a URL may be, a request field's value included, is
    /// refused here.
    pub fn parse_json(alloc: Allocator, json: []const u8) ParseError!Registry {
        if (json.len > max_json_bytes) return error.LimitExceeded;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{
            .duplicate_field_behavior = .@"error",
            .max_value_len = max_url_bytes,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return error.DuplicateField,
            error.ValueTooLong => return error.LimitExceeded,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();
        return parse(alloc, parsed.value);
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
        }
        self.* = .{};
    }

    /// Returns a borrow valid until registry teardown. IDs are case-sensitive.
    pub fn get(self: Registry, id: []const u8) ?*const Definition {
        if (id.len > max_id_bytes) return null;
        for (self.definitions) |*definition| {
            if (std.mem.eql(u8, definition.id, id)) return definition;
        }
        return null;
    }
};

/// `owned` is the registry's arena: a failure frees nothing here.
fn parse_definition(owned: Allocator, id: []const u8, value: std.json.Value, at: ?*FailurePath) ParseError!Definition {
    try validate_id(id);
    try check_fields(value, &.{ "display_name", "account_label", "protocol", "base_url", "auth", "tool_choice_mode", "reviewer_model", "title_model", "vision_model", "headers", "timeouts", "fetch_models", "model_defaults", "model_metadata" }, at);
    enter(at, "protocol");
    const protocol_name = try required(value, "protocol");
    if (protocol_name != .string) return error.InvalidProtocol;
    const protocol = std.meta.stringToEnum(Protocol, protocol_name.string) orelse return error.InvalidProtocol;
    leave(at);
    enter(at, "base_url");
    const url = try required(value, "base_url");
    if (url != .string) return error.InvalidBaseUrl;
    const normalized = try validate_url(url.string);
    leave(at);
    enter(at, "auth");
    const auth = try parse_auth(try required(value, "auth"), at);
    if (auth.plan()) |kind| {
        if (!kind.isId(id) or !std.mem.eql(u8, @tagName(protocol), kind.protocolName()) or !std.mem.eql(u8, normalized, kind.baseUrl()) or value.object.contains("headers")) return error.InvalidAuth;
    } else {
        if (plan_kind.Kind.reserving(id) != null) return error.ReservedProviderId;
        // Only an Antigravity account speaks Google's internal protocol.
        if (protocol == .@"gemini-code-assist") return error.InvalidProtocol;
    }
    leave(at);
    var mode: ToolChoiceMode = .omit;
    if (value.object.get("tool_choice_mode")) |choice| {
        enter(at, "tool_choice_mode");
        if (choice != .string) return error.InvalidToolChoiceMode;
        mode = if (std.mem.eql(u8, choice.string, "omit")) .omit else if (std.mem.eql(u8, choice.string, "send")) .send else return error.InvalidToolChoiceMode;
        leave(at);
    }
    var fetch_models = false;
    if (value.object.get("fetch_models")) |fetch| {
        enter(at, "fetch_models");
        if (fetch != .bool) return error.InvalidConnectionOption;
        fetch_models = fetch.bool;
        leave(at);
    }
    _ = try optional_model(owned, value, "reviewer_model", at);
    const title_model = try optional_model(owned, value, "title_model", at);
    const vision_model = try optional_model(owned, value, "vision_model", at);
    const headers = if (value.object.get("headers")) |headers| try parse_headers(owned, headers, at) else &.{};
    const timeouts = if (value.object.get("timeouts")) |timeouts| try parse_timeouts(timeouts, at) else Timeouts{};
    var model_defaults: ?ModelMetadata = null;
    if (value.object.get("model_defaults")) |defaults| {
        enter(at, "model_defaults");
        model_defaults = try parse_model(owned, protocol, "", defaults, at);
        leave(at);
    }
    const model_metadata = if (value.object.get("model_metadata")) |metadata| try parse_metadata(owned, protocol, metadata, at) else &.{};
    var display_name: ?[]const u8 = null;
    if (value.object.get("display_name")) |name| {
        enter(at, "display_name");
        if (name != .string or name.string.len == 0 or name.string.len > 80) return error.InvalidDisplayName;
        display_name = try owned.dupe(u8, name.string);
        leave(at);
    }
    var account_label: ?[]const u8 = null;
    if (value.object.get("account_label")) |label| {
        enter(at, "account_label");
        if (auth.plan() == null or label != .string or label.string.len == 0 or label.string.len > 48) return error.InvalidDisplayName;
        for (label.string) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidDisplayName;
        account_label = try owned.dupe(u8, label.string);
        leave(at);
    }
    return .{
        .id = try owned.dupe(u8, id),
        .display_name = display_name,
        .account_label = account_label,
        .protocol = protocol,
        .base_url = try owned.dupe(u8, normalized),
        .auth = switch (auth) {
            .none => .none,
            .chatgpt_plan => .chatgpt_plan,
            .claude_plan => .claude_plan,
            .antigravity_plan => .antigravity_plan,
            .bearer => |env| .{ .bearer = try owned.dupe(u8, env) },
            .key => |key| .{ .key = try owned.dupe(u8, key) },
        },
        .tool_choice_mode = mode,
        .title_model = title_model,
        .vision_model = vision_model,
        .headers = headers,
        .timeouts = timeouts,
        .fetch_models = fetch_models,
        .model_defaults = model_defaults,
        .model_metadata = model_metadata,
    };
}

fn optional_model(owned: Allocator, parent: std.json.Value, key: []const u8, at: ?*FailurePath) ParseError!?[]const u8 {
    const present = parent.object.get(key) orelse return null;
    enter(at, key);
    if (present != .string) return error.InvalidModelId;
    try validate_model_id(present.string);
    leave(at);
    return try owned.dupe(u8, present.string);
}

fn parse_auth(value: std.json.Value, at: ?*FailurePath) ParseError!Auth {
    try check_fields(value, &.{ "type", "env", "key" }, at);
    const kind = try required(value, "type");
    if (kind != .string) return error.InvalidAuth;
    if (std.mem.eql(u8, kind.string, "none")) {
        if (value.object.contains("env") or value.object.contains("key")) return error.InvalidAuth;
        return .none;
    }
    if (plan_kind.Kind.fromAuthType(kind.string)) |plan| {
        if (value.object.count() != 1) return error.InvalidAuth;
        return Auth.of_plan(plan);
    }
    if (std.mem.eql(u8, kind.string, "key")) {
        if (value.object.contains("env")) return error.InvalidAuth;
        const key = try required(value, "key");
        if (key != .string or key.string.len == 0) return error.InvalidAuth;
        for (key.string) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidAuth;
        return .{ .key = key.string };
    }
    if (value.object.contains("key")) return error.InvalidAuth;
    if (!std.mem.eql(u8, kind.string, "bearer")) return error.InvalidAuth;
    enter(at, "env");
    const env = try environment_name(try required(value, "env"));
    leave(at);
    return .{ .bearer = env };
}

/// The name of an environment variable, borrowed from `value`.
fn environment_name(value: std.json.Value) ParseError![]const u8 {
    if (value != .string) return error.InvalidEnvironmentName;
    const env = value.string;
    if (env.len > max_env_bytes) return error.LimitExceeded;
    if (env.len == 0 or (!std.ascii.isAlphabetic(env[0]) and env[0] != '_')) return error.InvalidEnvironmentName;
    for (env) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEnvironmentName;
    }
    return env;
}

/// Headers spark sets on every request, or that the transport owns. `auth` is
/// how a connection sets Authorization.
const reserved_headers = [_][]const u8{ "authorization", "content-type", "content-length", "host", "accept", "accept-encoding", "user-agent", "connection", "transfer-encoding" };

fn parse_headers(owned: Allocator, value: std.json.Value, at: ?*FailurePath) ParseError![]const Header {
    enter(at, "headers");
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_headers) return error.LimitExceeded;
    const headers = try owned.alloc(Header, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const name = entry.key_ptr.*;
        enter(at, name);
        if (name.len > max_header_name_bytes) return error.LimitExceeded;
        if (name.len == 0) return error.InvalidHeaderName;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeaderName;
        }
        for (reserved_headers) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
        }
        // Header names are case-insensitive, so two spellings are one header.
        for (headers[0..index]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, name)) return error.DuplicateField;
        }
        const slot = entry.value_ptr.*;
        if (slot != .object) return error.InvalidHeader;
        if (slot.object.get("session_id")) |flag| {
            try check_fields(slot, &.{"session_id"}, at);
            enter(at, "session_id");
            if (flag != .bool or !flag.bool) return error.InvalidHeader;
            leave(at);
            headers[index] = .{ .name = try owned.dupe(u8, name), .session_id = true };
            leave(at);
            continue;
        }
        try check_fields(slot, &.{"env"}, at);
        enter(at, "env");
        const env = try environment_name(try required(slot, "env"));
        leave(at);
        headers[index] = .{
            .name = try owned.dupe(u8, name),
            .env = try owned.dupe(u8, env),
        };
        leave(at);
    }
    leave(at);
    return headers;
}

fn parse_timeouts(value: std.json.Value, at: ?*FailurePath) ParseError!Timeouts {
    enter(at, "timeouts");
    if (value != .object) return error.InvalidObject;
    try check_fields(value, &.{ "connect_ms", "first_response_ms", "stall_ms" }, at);
    const timeouts: Timeouts = .{
        .connect_ms = try timeout(value, "connect_ms", at),
        .first_response_ms = try timeout(value, "first_response_ms", at),
        .stall_ms = try timeout(value, "stall_ms", at),
    };
    leave(at);
    return timeouts;
}

fn timeout(parent: std.json.Value, key: []const u8, at: ?*FailurePath) ParseError!?u32 {
    const present = parent.object.get(key) orelse return null;
    enter(at, key);
    if (present != .integer or present.integer <= 0 or present.integer > max_timeout_ms) return error.InvalidTimeout;
    leave(at);
    return @intCast(present.integer);
}

fn parse_metadata(owned: Allocator, protocol: Protocol, value: std.json.Value, at: ?*FailurePath) ParseError![]const ModelMetadata {
    enter(at, "model_metadata");
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_models) return error.LimitExceeded;
    const models = try owned.alloc(ModelMetadata, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        enter(at, entry.key_ptr.*);
        try validate_model_id(entry.key_ptr.*);
        models[index] = try parse_model(owned, protocol, entry.key_ptr.*, entry.value_ptr.*, at);
        leave(at);
    }
    leave(at);
    return models;
}

fn parse_model(owned: Allocator, protocol: Protocol, id: []const u8, metadata: std.json.Value, at: ?*FailurePath) ParseError!ModelMetadata {
    try check_fields(metadata, &.{ "display_name", "context_window", "max_output_tokens", "supports_tool_use", "supports_vision", "output_limit_field", "request", "reasoning_efforts" }, at);
    var display_name: ?[]const u8 = null;
    if (metadata.object.get("display_name")) |name| {
        enter(at, "display_name");
        if (name != .string or name.string.len == 0 or name.string.len > max_model_bytes) return error.InvalidModelMetadata;
        display_name = try owned.dupe(u8, name.string);
        leave(at);
    }
    const context = try positive_limit(metadata, "context_window", at);
    const output = try positive_limit(metadata, "max_output_tokens", at);
    if (context != null and output != null and output.? >= context.?) {
        enter(at, "max_output_tokens");
        return error.InvalidModelMetadata;
    }
    var limit_field: ?OutputLimitField = null;
    if (metadata.object.get("output_limit_field")) |field| {
        enter(at, "output_limit_field");
        // The other protocols each have one field for the limit.
        if (protocol != .@"openai-chat-completions" or field != .string) return error.InvalidModelMetadata;
        limit_field = std.meta.stringToEnum(OutputLimitField, field.string) orelse return error.InvalidModelMetadata;
        leave(at);
    }
    const spark_fields = protocol.owned_request_fields();
    var request: ?request_fragment.Fragment = null;
    if (metadata.object.get("request")) |fields| {
        enter(at, "request");
        request = try parse_fragment(owned, fields, spark_fields, at);
        leave(at);
    }
    var efforts: ?[]const EffortLevel = null;
    if (metadata.object.get("reasoning_efforts")) |levels| {
        enter(at, "reasoning_efforts");
        efforts = try parse_efforts(owned, levels, spark_fields, at);
        leave(at);
    }
    return .{
        .id = try owned.dupe(u8, id),
        .display_name = display_name,
        .context_window = context,
        .max_output_tokens = output,
        .supports_tool_use = try optional_bool(metadata, "supports_tool_use", at),
        .supports_vision = try optional_bool(metadata, "supports_vision", at),
        .output_limit_field = limit_field,
        .request = request,
        .reasoning_efforts = efforts,
    };
}

fn parse_efforts(owned: Allocator, value: std.json.Value, spark_fields: []const []const u8, at: ?*FailurePath) ParseError![]const EffortLevel {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_effort_levels) return error.LimitExceeded;
    const levels = try owned.alloc(EffortLevel, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        enter(at, entry.key_ptr.*);
        try validate_effort_name(entry.key_ptr.*);
        levels[index] = .{
            .name = try owned.dupe(u8, entry.key_ptr.*),
            .fields = try parse_fragment(owned, entry.value_ptr.*, spark_fields, at),
        };
        leave(at);
    }
    return levels;
}

/// A request fragment; when a key is refused, `at` ends at that key.
fn parse_fragment(owned: Allocator, value: std.json.Value, spark_fields: []const []const u8, at: ?*FailurePath) ParseError!request_fragment.Fragment {
    var refused: ?[]const u8 = null;
    return request_fragment.parseReporting(owned, value, spark_fields, &refused) catch |err| {
        if (refused) |key| enter(at, key);
        return err;
    };
}

/// A level's name follows the rule for an effort anywhere in spark
/// (`types.ReasoningEffort`), and is never one of the words for "no level".
pub fn validate_effort_name(name: []const u8) error{ LimitExceeded, InvalidEffortLevel }!void {
    if (name.len > max_effort_name_bytes) return error.LimitExceeded;
    if (name.len == 0) return error.InvalidEffortLevel;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidEffortLevel;
    }
    for ([_][]const u8{ "auto", "adaptive", "default" }) |unset| {
        if (std.ascii.eqlIgnoreCase(name, unset)) return error.InvalidEffortLevel;
    }
}

fn positive_limit(parent: std.json.Value, key: []const u8, at: ?*FailurePath) ParseError!?u32 {
    const present = parent.object.get(key) orelse return null;
    enter(at, key);
    if (present != .integer or present.integer <= 0 or present.integer > std.math.maxInt(u32)) return error.InvalidModelMetadata;
    leave(at);
    return @intCast(present.integer);
}

fn optional_bool(parent: std.json.Value, key: []const u8, at: ?*FailurePath) ParseError!?bool {
    const present = parent.object.get(key) orelse return null;
    enter(at, key);
    if (present != .bool) return error.InvalidModelMetadata;
    leave(at);
    return present.bool;
}

/// Refuses a key `allowed` does not list; `at` then ends at that key.
fn check_fields(value: std.json.Value, allowed: []const []const u8, at: ?*FailurePath) ParseError!void {
    if (value != .object) return error.InvalidObject;
    for (value.object.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else {
            enter(at, key);
            return error.UnknownField;
        }
    }
}

fn required(value: std.json.Value, name: []const u8) ParseError!std.json.Value {
    return value.object.get(name) orelse error.MissingField;
}

// Named connection IDs are ASCII [A-Za-z][A-Za-z0-9_-]*. Built-in names are
// reserved case-insensitively, matching the existing provider selector.
pub fn validate_id(id: []const u8) error{ LimitExceeded, InvalidProviderId, ReservedProviderId }!void {
    if (id.len > max_id_bytes) return error.LimitExceeded;
    if (id.len == 0 or !std.ascii.isAlphabetic(id[0])) return error.InvalidProviderId;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidProviderId;
    }
    for ([_][]const u8{ "gateway", "codex", "grok" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(id, reserved)) return error.ReservedProviderId;
    }
}

pub fn validate_model_id(id: []const u8) error{ LimitExceeded, InvalidModelId }!void {
    if (id.len > max_model_bytes) return error.LimitExceeded;
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidModelId;
    if (std.mem.trim(u8, id, " \t\r\n").len != id.len) return error.InvalidModelId;
    for (id) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidModelId;
    }
}

/// Returns a borrow, removing only one optional trailing slash. No decoding,
/// case folding, default-port removal, or path-prefix rewriting is performed.
pub fn validate_url(url: []const u8) ParseError![]const u8 {
    if (url.len > max_url_bytes) return error.LimitExceeded;
    for (url) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return error.InvalidBaseUrl;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBaseUrl;
    const host = (uri.host orelse return error.InvalidBaseUrl).percent_encoded;
    if (host.len == 0) return error.InvalidBaseUrl;
    // Check the complete authority: Uri.parse alone accepts some malformed
    // bracket suffixes and parseInt accepts signs/underscores in ports.
    const rest = url[uri.scheme.len + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return error.InvalidBaseUrl;
    const authority = rest[2 .. 2 + (std.mem.findScalar(u8, rest[2..], '/') orelse rest.len - 2)];
    if (!std.mem.startsWith(u8, authority, host)) return error.InvalidBaseUrl;
    const port = authority[host.len..];
    if (port.len != 0) {
        if (port[0] != ':' or port.len < 2 or port.len > 6) return error.InvalidBaseUrl;
        for (port[1..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidBaseUrl;
        const number = std.fmt.parseInt(u16, port[1..], 10) catch return error.InvalidBaseUrl;
        if (number == 0) return error.InvalidBaseUrl;
    }
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidBaseUrl;
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return error.InvalidBaseUrl;
    } else {
        if (host.len > 253) return error.InvalidBaseUrl;
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidBaseUrl;
            for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidBaseUrl;
        }
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InsecureBaseUrl;
        if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "[::1]") and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.InsecureBaseUrl;
    }
    // Preserve encoded path bytes but reject malformed escapes and encoded
    // controls so later HTTP construction cannot reinterpret unsafe bytes.
    const path = uri.path.percent_encoded;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        const byte = path[index];
        if (byte == '%') {
            if (path.len - index < 3) return error.InvalidBaseUrl;
            const decoded = std.fmt.parseInt(u8, path[index + 1 ..][0..2], 16) catch return error.InvalidBaseUrl;
            if (!std.ascii.isHex(path[index + 1]) or !std.ascii.isHex(path[index + 2]) or decoded < 0x20 or decoded == 0x7f) return error.InvalidBaseUrl;
            index += 2;
        } else if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "/-._~!$&'()*+,;=:@", byte) == null) return error.InvalidBaseUrl;
    }
    return if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url;
}

fn hash_part(hash: *std.crypto.hash.sha2.Sha256, part: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(part.len), .big);
    hash.update(&length);
    hash.update(part);
}

const test_json =
    \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:11434/v1/","auth":{"type":"none"}},
    \\"router":{"protocol":"openai-chat-completions","base_url":"https://openrouter.ai/api/v1","auth":{"type":"bearer","env":"OPENROUTER_API_KEY"},"tool_choice_mode":"send","reviewer_model":"openai/review","model_metadata":{"openai/gpt-4.1":{"context_window":8192,"max_output_tokens":1024,"supports_tool_use":true,"supports_vision":false},"unknown":{}}}}
;

test "configured provider owns definitions and preserves unknown metadata" {
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, test_json);
    var registry = try Registry.parse_json(alloc, input);
    alloc.free(input);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), registry.definitions.len);
    const local = registry.get("local").?;
    try std.testing.expectEqual(Auth.none, local.auth);
    try std.testing.expectEqual(ToolChoiceMode.omit, local.tool_choice_mode);
    const chat = try local.chat_url(alloc);
    defer alloc.free(chat);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", chat);
    const router = registry.get("router").?;
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", router.auth.bearer);
    try std.testing.expectEqual(ToolChoiceMode.send, router.tool_choice_mode);
    const metadata = router.model("openai/gpt-4.1").?;
    try std.testing.expectEqual(@as(?u32, 8192), metadata.context_window);
    try std.testing.expectEqual(@as(?u32, 1024), metadata.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), metadata.supports_tool_use);
    try std.testing.expectEqual(@as(?bool, false), metadata.supports_vision);
    const unknown = router.model("unknown").?;
    try std.testing.expect(unknown.context_window == null and unknown.max_output_tokens == null);
    try std.testing.expect(unknown.supports_tool_use == null and unknown.supports_vision == null);
    try std.testing.expect(router.model("missing") == null);
    try std.testing.expect(registry.get("Router") == null);
}

fn test_allocations(alloc: Allocator) !void {
    var registry = try Registry.parse_json(alloc, test_json);
    defer registry.deinit(alloc);
    const definition = registry.get("router").?;
    const chat = try definition.chat_url(alloc);
    defer alloc.free(chat);
    _ = definition.binding_identity();
}

const test_required_fields = "\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"}";

fn test_invalid_allocations(alloc: Allocator) !void {
    const json = "{\"first\":{" ++ test_required_fields ++ "},\"second\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"valid\":{},\"invalid\":{\"max_output_tokens\":0}}}}";
    var registry = Registry.parse_json(alloc, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidModelMetadata => return,
        else => return err,
    };
    defer registry.deinit(alloc);
    return error.TestUnexpectedResult;
}

const test_options_json =
    \\{"router":{"protocol":"openai-chat-completions","base_url":"https://example.com/v1","auth":{"type":"bearer","env":"ROUTER_KEY"},
    \\"title_model":"small/title","vision_model":"small/vision","fetch_models":true,
    \\"headers":{"X-Org":{"env":"ROUTER_ORG"},"x-trace":{"env":"_TRACE"}},
    \\"timeouts":{"connect_ms":1,"first_response_ms":600000,"stall_ms":86400000},
    \\"model_defaults":{"context_window":65536,"supports_tool_use":true,"request":{"top_p":0.9},"reasoning_efforts":{"low":{"reasoning_effort":"low"}}},
    \\"model_metadata":{
    \\"thinker":{"max_output_tokens":4096,"output_limit_field":"max_completion_tokens","request":{"temperature":0.2},
    \\"reasoning_efforts":{"high":{"reasoning":{"effort":"high"}},"low":{"reasoning":{"effort":"low"}},"x-high.2":{}}},
    \\"plain":{"reasoning_efforts":{}}}}}
;

fn test_option_allocations(alloc: Allocator) !void {
    var registry = try Registry.parse_json(alloc, test_options_json);
    defer registry.deinit(alloc);
    const url = try registry.get("router").?.request_url(alloc);
    defer alloc.free(url);
    const invalid = "{\"first\":{" ++ test_required_fields ++ ",\"headers\":{\"X-A\":{\"env\":\"A\"}},\"model_metadata\":{\"m\":{\"request\":{\"a\":[1,{\"b\":2}]},\"reasoning_efforts\":{\"low\":{\"c\":1},\"high\":{\"model\":2}}}}}}";
    if (Registry.parse_json(alloc, invalid)) |parsed| {
        var unexpected = parsed;
        unexpected.deinit(alloc);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ReservedRequestField => {},
        else => return err,
    }
}

/// Whatever bytes the settings hold, the parser refuses them or returns a
/// registry that keeps its own limits: no fragment names a field spark writes
/// for the connection's protocol, and no model offers more levels than spark can.
fn fuzzDefinition(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    const json = buffer[0..@intCast(smith.slice(&buffer))];
    try expectPathMatchesVerdict(alloc, json);
    var registry = Registry.parse_json(alloc, json) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer registry.deinit(alloc);
    for (registry.definitions) |definition| {
        const owned = definition.protocol.owned_request_fields();
        if (definition.model_defaults) |defaults| try expectWithinLimits(defaults, owned);
        for (definition.model_metadata) |metadata| {
            try expectWithinLimits(metadata, owned);
            try std.testing.expect(definition.metadata_for(metadata.id) != null);
        }
        try std.testing.expect(definition.headers.len <= max_headers);
        _ = definition.binding_identity();
    }
}

/// The path recorder agrees with `parse_json`: a parse that succeeds leaves
/// the path empty, and a refusal of settings that name a connection leaves a
/// path that is one printable line (`config_runtime.configuredProviderMessage`).
fn expectPathMatchesVerdict(alloc: Allocator, json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_url_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    var at: FailurePath = .{};
    const verdict = Registry.parse_json(alloc, json);
    if (verdict) |registry| {
        var plain = registry;
        plain.deinit(alloc);
    } else |err| if (err == error.OutOfMemory) return err;
    if (Registry.parse_located(alloc, parsed.value, &at)) |registry| {
        var located = registry;
        located.deinit(alloc);
        if (verdict) |_| {} else |_| return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), at.text().len);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectError(err, verdict);
        const path = at.text();
        try std.testing.expect(std.unicode.utf8ValidateSlice(path));
        for (path) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
        const count = if (parsed.value == .object) parsed.value.object.count() else 0;
        if (count > 0 and count <= max_providers) try std.testing.expect(path.len > 0);
    }
}

fn expectWithinLimits(metadata: ModelMetadata, owned: []const []const u8) !void {
    for (owned) |name| {
        if (metadata.request) |fields| try std.testing.expect(!fields.has(name));
        for (metadata.reasoning_efforts orelse &.{}) |level| try std.testing.expect(!level.fields.has(name));
    }
    if (metadata.reasoning_efforts) |levels| try std.testing.expect(levels.len <= max_effort_levels);
}

/// Two fragments from arbitrary bytes, the model's and a level's, split at
/// the first NUL, written after spark's own fields: the body stays one valid
/// JSON object, every field spark writes keeps spark's value, and a field both set
/// carries the level's value
/// (`tests/tla/configured_provider/ConfiguredRequest.tla` OwnedKeysKeepFxValue,
/// LevelBeatsRequest). The input's length picks the protocol whose fields spark owns.
fn fuzzFragments(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [2048]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const protocols = std.enums.values(Protocol);
    const owned = protocols[bytes.len % protocols.len].owned_request_fields();
    const split = std.mem.findScalar(u8, bytes, 0);
    const request = fuzzFragment(arena, if (split) |at| bytes[0..at] else bytes, owned) orelse return;
    const level = fuzzFragment(arena, if (split) |at| bytes[at + 1 ..] else "{}", owned) orelse return;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"model\":\"spark-model\",\"stream\":true");
    try request_fragment.write(&out.writer, request, level);
    try out.writer.writeByte('}');
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, out.written(), .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const body = parsed.value.object;
    try std.testing.expectEqualStrings("spark-model", body.get("model").?.string);
    try std.testing.expect(body.get("stream").?.bool);
    for (level.fields) |field| {
        var expected = try std.json.parseFromSlice(std.json.Value, arena, field.value_json, .{});
        defer expected.deinit();
        var sent: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(body.get(field.key).?, .{}, &sent.writer);
        var wanted: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(expected.value, .{}, &wanted.writer);
        try std.testing.expectEqualStrings(wanted.written(), sent.written());
    }
}

/// A fragment parsed from `bytes`, or null when the settings would refuse it.
fn fuzzFragment(arena: Allocator, bytes: []const u8, owned: []const []const u8) ?request_fragment.Fragment {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_url_bytes }) catch return null;
    return request_fragment.parse(arena, value, owned) catch null;
}
