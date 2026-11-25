//! Google's Cloud Code Assist codec, the protocol of Antigravity plan
//! accounts (`"protocol": "gemini-code-assist"`): the body for
//! `POST {base_url}/v1internal:streamGenerateContent?alt=sse`, which wraps a
//! Gemini `generateContent` request, and the reducer for its server-sent
//! events. The transport fills in the account's Cloud Code project, its
//! token and User-Agent. Tool selection, history checks and limits follow
//! the Anthropic Messages codec (`anthropic_messages_protocol.zig`).
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const function_tools = @import("function_tools.zig");
const json_depth = @import("../core/shared/json_depth.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

/// The opening every body starts with. The transport puts the account's
/// project between the quotes.
pub const project_placeholder = "{\"project\":\"\"";

/// The identity Antigravity's own requests open their system instruction
/// with; Cloud Code expects it. Spark's prompt follows and takes precedence.
pub const identity =
    \\You are Antigravity, a powerful agentic AI coding assistant designed by the Google DeepMind team working on Advanced Agentic Coding.
    \\
    \\<priority>IMPORTANT: The instructions that follow supersede all above. Follow them as your primary directives.</priority>
;

/// Lets Gemini 3 accept a function call whose thought signature was not kept.
pub const skip_signature = "skip_thought_signature_validator";

pub const Options = struct {
    /// Borrowed during serialization; the configured authority binding.
    provider: ?*const model_provider.ProviderId = null,
    /// The model ID sent, when a level picks another one than the request's.
    model: ?[]const u8 = null,
    /// The `thinkingConfig` object as JSON, or null to send none.
    thinking_json: ?[]const u8 = null,
    /// The output limit when the request sets none.
    default_max_tokens: ?u32 = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedProviderOption,
    UnsupportedVision,
    UnsupportedResponseFormat,
    UnsupportedReplay,
    InvalidProviderState,
    ReplayTooLarge,
    UnsupportedToolProvenance,
    InvalidOutputLimit,
    InvalidToolSelection,
    InvalidToolSchema,
    InvalidToolCallId,
    InvalidToolName,
    InvalidToolArguments,
    InvalidToolHistory,
    ImageUnavailable,
    RequiredToolMissing,
    UnexpectedToolCall,
    InvalidEvent,
    MalformedGeminiEvent,
    InvalidFinishReason,
    IncompleteStream,
    StreamClosed,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

const max_selected_tools = function_tools.max_selected_tools;
const max_history_arguments_bytes = 1024 * 1024;
const max_error_detail_bytes = 64 * 1024;

fn validate_request(request: stream_provider.RequestData) Error!void {
    try request.validatePrompt();
    if (request.model.len == 0 or request.model.len > 1024) return error.InvalidModel;
    if (request.provider_options.fast) return error.UnsupportedProviderOption;
    if (request.response_format) |format| {
        if (format.schema != .object) return error.UnsupportedResponseFormat;
        function_tools.validate_name(format.name) catch return error.UnsupportedResponseFormat;
    }
    if (request.verified_images) |images| if (images.len != 0) {
        if (request.response_format == null or function_tools.last_user_index(request.messages) == null) return error.UnsupportedVision;
    };
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
        if (message.provider_replay != null and message.role != .assistant) return error.InvalidProviderState;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
    }
}

fn validate_arguments(alloc: Allocator, text: []const u8) Error!void {
    if (json_depth.exceeds(text)) return error.JsonTooDeep;
    if (try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, text) != .valid) return error.InvalidToolArguments;
}

/// Checks the tool history and returns each call's name by its ID, which a
/// function response must repeat. Borrows the messages.
fn call_names(alloc: Allocator, messages: []const types.ChatMessage) Error!std.StringHashMapUnmanaged([]const u8) {
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer names.deinit(alloc);
    var pending: usize = 0;
    for (messages) |message| {
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolCallId;
            const name = names.get(id) orelse return error.InvalidToolHistory;
            if (message.tool_name) |tool_name| if (!std.mem.eql(u8, tool_name, name)) return error.InvalidToolHistory;
            if (pending == 0) return error.InvalidToolHistory;
            pending -= 1;
            continue;
        }
        if (pending != 0) return error.InvalidToolHistory;
        if (message.tool_calls.len > max_selected_tools) return error.TooManyTools;
        for (message.tool_calls) |call| {
            if (call.provenance != .spark_local or call.provider_result != null) return error.UnsupportedToolProvenance;
            if (call.id.len == 0 or call.final_identity != .valid) return error.InvalidToolCallId;
            try function_tools.validate_name(call.name);
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            try validate_arguments(alloc, call.arguments_json);
            const entry = try names.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
            pending += 1;
        }
    }
    if (pending != 0) return error.InvalidToolHistory;
    return names;
}

/// One assistant message's replay, as `Reducer.provider_state` wrote it:
/// the reply's thoughts with their signatures, and the signatures Gemini
/// put on its text and on each function call, by call ID.
const Replay = struct {
    thoughts: []const struct { text: []const u8 = "", signature: ?[]const u8 = null } = &.{},
    text_signature: ?[]const u8 = null,
    calls: []const struct { id: []const u8, signature: []const u8 } = &.{},
};

fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(Replay) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    if (json_depth.exceeds(raw)) return error.JsonTooDeep;
    return std.json.parseFromSlice(Replay, alloc, raw, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
}

/// Keeps the replay while reasoning does: the signatures belong to the reply.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, _: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    if (value.source.provider == .none) return error.InvalidProviderState;
    if (!reasoning) return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    parsed.deinit();
    return value;
}

/// Caller owns the body. It opens with `project_placeholder`.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input);
    var projected: ?[]types.ChatMessage = null;
    if (options.provider) |provider| {
        projected = try types.projectProviderReplay(alloc, input.messages, .{ .provider = provider.*, .model = input.model });
    } else {
        for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    }
    defer if (projected) |messages| alloc.free(messages);
    var request = input;
    request.messages = projected orelse input.messages;
    var names = try call_names(alloc, request.messages);
    defer names.deinit(alloc);
    var functions: std.ArrayList(function_tools.Function) = if (request.response_format == null)
        try function_tools.select_functions(alloc, request.tools, request.tool_choice, request.vision_mode)
    else
        .empty;
    defer functions.deinit(alloc);
    var projection = tool_call_ids.Projection.init(alloc, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const model = options.model orelse request.model;
    write_request(&out.writer, alloc, request, options, model, functions.items, &projection, &names) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn write_request(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.RequestData,
    options: Options,
    model: []const u8,
    functions: []const function_tools.Function,
    projection: *const tool_call_ids.Projection,
    names: *const std.StringHashMapUnmanaged([]const u8),
) !void {
    try writer.writeAll(project_placeholder ++ ",\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"request\":{");
    try write_contents(writer, alloc, request, model, projection, names);
    try write_system(writer, alloc, request.instructions);
    const claude = std.mem.startsWith(u8, model, "claude-");
    if (request.response_format) |format| {
        try writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        try write_declaration(writer, alloc, format.name, format.description, .{ .dynamic = format.schema });
        try writer.writeAll("]}],\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"ANY\",\"allowedFunctionNames\":[");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll("]}}");
    } else if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            try write_declaration(writer, alloc, function.name, function.description, switch (function.schema) {
                .builtin => |schema| .{ .builtin = schema },
                .dynamic => |schema| .{ .dynamic = schema },
            });
        }
        try writer.writeAll("]}]");
        const choice: types.ToolChoice = if (request.vision_mode == .required) .required else request.tool_choice;
        // Claude behind Cloud Code calls tools only with their schemas checked.
        const mode: ?[]const u8 = if (choice == .required) "ANY" else if (claude) "VALIDATED" else null;
        if (mode) |value| try writer.print(",\"toolConfig\":{{\"functionCallingConfig\":{{\"mode\":\"{s}\"}}}}", .{value});
    }
    try writer.writeAll(",\"generationConfig\":{");
    var first = true;
    if (request.max_output_tokens orelse options.default_max_tokens) |limit| {
        try writer.print("\"maxOutputTokens\":{d}", .{limit});
        first = false;
    }
    if (options.thinking_json) |thinking| {
        if (!first) try writer.writeByte(',');
        try writer.writeAll("\"thinkingConfig\":");
        try writer.writeAll(thinking);
        first = false;
    }
    try writer.writeByte('}');
    try writer.writeAll("},\"requestType\":\"agent\",\"userAgent\":\"antigravity\",\"requestId\":");
    var random: [16]u8 = undefined;
    io_mod.getIo().random(&random);
    try writer.print("\"agent-{s}\"}}", .{std.fmt.bytesToHex(random, .lower)});
}

const Schema = union(enum) {
    builtin: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

fn write_declaration(writer: *std.Io.Writer, alloc: Allocator, name: []const u8, description: []const u8, schema: Schema) !void {
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, description);
    // Cloud Code checks schemas against the OpenAPI subset Gemini reads.
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    switch (schema) {
        .builtin => |shape| try model_tool_schema.writeObjectSchema(alloc, &encoded.writer, shape),
        .dynamic => |value| try std.json.Stringify.value(value, .{}, &encoded.writer),
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), encoded.written(), .{});
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(try sanitize(arena.allocator(), value, false), .{}, writer);
    try writer.writeByte('}');
}

/// Schema keywords Cloud Code refuses.
const unsupported_keys = [_][]const u8{
    "$schema",          "$id",                  "$ref",              "$defs",            "$comment",
    "definitions",      "additionalProperties", "patternProperties", "propertyNames",    "unevaluatedProperties",
    "unevaluatedItems", "dependentRequired",    "dependentSchemas",  "if",               "then",
    "else",             "not",                  "const",             "contentMediaType", "contentEncoding",
    "minContains",      "maxContains",          "examples",          "title",            "default",
    "exclusiveMinimum", "exclusiveMaximum",     "pattern",           "format",           "minLength",
    "maxLength",        "minItems",             "maxItems",
};

/// A copy of `value` without the keywords Cloud Code refuses. A type list
/// becomes its first non-null type; `properties` keeps every name.
fn sanitize(arena: Allocator, value: std.json.Value, names: bool) Allocator.Error!std.json.Value {
    switch (value) {
        .object => |fields| {
            var copy: std.json.ObjectMap = .empty;
            var iterator = fields.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!names and function_tools.contains_name(&unsupported_keys, key)) continue;
                var child = entry.value_ptr.*;
                if (!names and std.mem.eql(u8, key, "type") and child == .array) {
                    var chosen: std.json.Value = .{ .string = "string" };
                    for (child.array.items) |item| if (item == .string and !std.mem.eql(u8, item.string, "null")) {
                        chosen = item;
                        break;
                    };
                    child = chosen;
                }
                try copy.put(arena, key, try sanitize(arena, child, !names and std.mem.eql(u8, key, "properties")));
            }
            if (!names) {
                // `required` may name only properties that exist.
                if (copy.get("required")) |required| if (required == .array) {
                    const properties = copy.get("properties");
                    var kept: std.json.Array = .init(arena);
                    for (required.array.items) |item| {
                        if (item != .string) continue;
                        if (properties != null and properties.? == .object and properties.?.object.contains(item.string)) try kept.append(item);
                    }
                    if (kept.items.len == 0) _ = copy.orderedRemove("required") else try copy.put(arena, "required", .{ .array = kept });
                };
            }
            return .{ .object = copy };
        },
        .array => |items| {
            var copy: std.json.Array = .init(arena);
            for (items.items) |item| try copy.append(try sanitize(arena, item, false));
            return .{ .array = copy };
        },
        else => return value,
    }
}

fn write_system(writer: *std.Io.Writer, alloc: Allocator, instructions: []const types.ChatMessage) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    try joined.appendSlice(alloc, identity);
    for (instructions) |instruction| {
        const text = instruction.content orelse continue;
        if (text.len == 0) continue;
        try joined.appendSlice(alloc, "\n\n");
        try joined.appendSlice(alloc, text);
    }
    try writer.writeAll(",\"systemInstruction\":{\"role\":\"user\",\"parts\":[{\"text\":");
    try std.json.Stringify.value(joined.items, .{}, writer);
    try writer.writeAll("}]}");
}

const WireRole = enum { user, model };

/// Writes `contents` one part at a time, joining parts of the same role.
const Turns = struct {
    writer: *std.Io.Writer,
    role: ?WireRole = null,
    parts: usize = 0,

    fn begin_part(self: *Turns, role: WireRole) !void {
        if (self.role != role) {
            if (self.role == null and role != .user) return error.InvalidProviderPrompt;
            if (self.role != null) try self.writer.writeAll("]},");
            try self.writer.writeAll(switch (role) {
                .user => "{\"role\":\"user\",\"parts\":[",
                .model => "{\"role\":\"model\",\"parts\":[",
            });
            self.role = role;
            self.parts = 0;
        }
        if (self.parts != 0) try self.writer.writeByte(',');
        self.parts += 1;
    }

    fn finish(self: *Turns) !void {
        if (self.role == null) return;
        try self.writer.writeAll("]}");
    }
};

fn write_contents(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, model: []const u8, projection: *const tool_call_ids.Projection, names: *const std.StringHashMapUnmanaged([]const u8)) !void {
    try writer.writeAll("\"contents\":[");
    var turns: Turns = .{ .writer = writer };
    const verified = request.verified_images orelse &.{};
    const verified_at = if (verified.len != 0) function_tools.last_user_index(request.messages) else null;
    for (request.messages, 0..) |message, index| switch (message.role) {
        .user => try write_user(&turns, alloc, message, if (verified_at == index) verified else &.{}),
        .assistant => try write_model(&turns, alloc, message, model, projection),
        .tool => try write_function_response(&turns, message, projection, names),
        .system => return error.InvalidProviderPrompt,
    };
    try turns.finish();
    try writer.writeByte(']');
}

fn write_user(turns: *Turns, alloc: Allocator, message: types.ChatMessage, verified: []const image_attachments.VerifiedSnapshot) !void {
    if (message.content) |text| if (text.len != 0) {
        try turns.begin_part(.user);
        try write_text(turns.writer, text);
    };
    for (message.images) |image| {
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ImageUnavailable,
        };
        defer snapshot.deinit(alloc);
        try turns.begin_part(.user);
        try write_inline_data(turns.writer, snapshot.media_type, snapshot.bytes);
    }
    for (verified) |snapshot| {
        try turns.begin_part(.user);
        try write_inline_data(turns.writer, snapshot.media_type, snapshot.bytes);
    }
}

/// The reply's thoughts first, then its text and calls, each with the
/// signature Gemini put on it.
fn write_model(turns: *Turns, alloc: Allocator, message: types.ChatMessage, model: []const u8, projection: *const tool_call_ids.Projection) !void {
    var replay: ?std.json.Parsed(Replay) = null;
    defer if (replay) |parsed| parsed.deinit();
    if (message.provider_replay) |state| replay = try parse_replay(alloc, state.parts_json);
    const saved: Replay = if (replay) |parsed| parsed.value else .{};
    for (saved.thoughts) |thought| {
        try turns.begin_part(.model);
        try turns.writer.writeAll("{\"thought\":true,\"text\":");
        try std.json.Stringify.value(thought.text, .{}, turns.writer);
        if (thought.signature) |signature| try write_signature(turns.writer, signature);
        try turns.writer.writeByte('}');
    }
    if (message.content) |text| if (text.len != 0) {
        try turns.begin_part(.model);
        try turns.writer.writeAll("{\"text\":");
        try std.json.Stringify.value(text, .{}, turns.writer);
        if (saved.text_signature) |signature| try write_signature(turns.writer, signature);
        try turns.writer.writeByte('}');
    };
    for (message.tool_calls, 0..) |call, index| {
        try turns.begin_part(.model);
        const writer = turns.writer;
        try writer.writeAll("{\"functionCall\":{\"name\":");
        try std.json.Stringify.value(call.name, .{}, writer);
        try writer.writeAll(",\"id\":");
        try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
        // call_names proved the arguments are one JSON object.
        try writer.writeAll(",\"args\":");
        try writer.writeAll(call.arguments_json);
        try writer.writeByte('}');
        const signature = for (saved.calls) |kept| {
            if (std.mem.eql(u8, kept.id, call.id)) break kept.signature;
        } else null;
        if (signature) |value| {
            try write_signature(writer, value);
        } else if (index == 0 and std.mem.startsWith(u8, model, "gemini-")) {
            // Gemini 3 refuses a step's first call without a signature.
            try write_signature(writer, skip_signature);
        }
        try writer.writeByte('}');
    }
}

fn write_signature(writer: *std.Io.Writer, signature: []const u8) !void {
    try writer.writeAll(",\"thoughtSignature\":");
    try std.json.Stringify.value(signature, .{}, writer);
}

fn write_function_response(turns: *Turns, message: types.ChatMessage, projection: *const tool_call_ids.Projection, names: *const std.StringHashMapUnmanaged([]const u8)) !void {
    const id = message.tool_call_id.?;
    try turns.begin_part(.user);
    const writer = turns.writer;
    try writer.writeAll("{\"functionResponse\":{\"name\":");
    try std.json.Stringify.value(names.get(id).?, .{}, writer);
    try writer.writeAll(",\"id\":");
    try std.json.Stringify.value(projection.resolve(id), .{}, writer);
    try writer.writeAll(",\"response\":{");
    try writer.writeAll(if (message.tool_result_status == .failure) "\"error\":" else "\"output\":");
    try std.json.Stringify.value(message.content.?, .{}, writer);
    try writer.writeAll("}}}");
    const retained: []const types.ToolImage = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    if (function_tools.toolResultDenied(message)) return;
    for (retained) |image| {
        try turns.begin_part(.user);
        try writer.writeAll("{\"inlineData\":{\"mimeType\":");
        try std.json.Stringify.value(image.mime_type, .{}, writer);
        try writer.writeAll(",\"data\":");
        try std.json.Stringify.value(image.data, .{}, writer);
        try writer.writeAll("}}");
    }
}

fn write_text(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

fn write_inline_data(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"inlineData\":{\"mimeType\":");
    try std.json.Stringify.value(media_type, .{}, writer);
    try writer.writeAll(",\"data\":\"");
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}}");
}

pub const Limits = struct {
    event_bytes: usize = 4 * 1024 * 1024,
    total_wire_bytes: usize = 64 * 1024 * 1024,
    events: usize = 100_000,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    content_bytes: usize = 8 * 1024 * 1024,
    reasoning_bytes: usize = types.ProviderReplay.max_bytes,
};

const Deltas = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_started: ?struct { id: []const u8, name: []const u8 } = null,
    tool_input: ?[]const u8 = null,
};

const Call = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,
    signature: ?[]u8 = null,
    structured: bool = false,

    fn deinit(self: *Call, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.arguments);
        if (self.signature) |value| alloc.free(value);
    }
};

const Thought = struct {
    text: std.ArrayList(u8) = .empty,
    signature: ?[]u8 = null,
};

const Failure = struct {
    kind: stream_provider.FailureKind,
    detail: []u8,
};

/// Single-owner, request-local state machine over Cloud Code's events. Each
/// event carries the reply's next parts; the last one names why it stopped,
/// and the stream ends after it.
const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    structured_name: ?[]const u8,
    calls: std.ArrayList(Call) = .empty,
    thoughts: std.ArrayList(Thought) = .empty,
    content: std.ArrayList(u8) = .empty,
    text_signature: ?[]u8 = null,
    generation_id: ?[]u8 = null,
    usage: types.Usage = .{},
    stop: ?[]const u8 = null,
    failure: ?Failure = null,
    phase: enum { streaming, stopped, failed, closed } = .streaming,
    event_count: usize = 0,
    json_bytes: usize = 0,
    reasoning_bytes: usize = 0,
    /// Whether the last part was a thought, so the next thought joins it.
    thinking: bool = false,

    fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try validate_request(request);
        return .{
            .alloc = alloc,
            .limits = limits,
            .choice = request.tool_choice,
            .structured_name = if (request.response_format) |format| format.name else null,
        };
    }

    fn deinit(self: *Reducer) void {
        for (self.calls.items) |*call| call.deinit(self.alloc);
        self.calls.deinit(self.alloc);
        for (self.thoughts.items) |*thought| {
            thought.text.deinit(self.alloc);
            if (thought.signature) |value| self.alloc.free(value);
        }
        self.thoughts.deinit(self.alloc);
        self.content.deinit(self.alloc);
        if (self.text_signature) |value| self.alloc.free(value);
        if (self.generation_id) |id| self.alloc.free(id);
        if (self.failure) |failure| self.alloc.free(failure.detail);
        self.* = undefined;
    }

    /// Reads one event and tells `events` about each of its parts as it goes:
    /// a part's deltas borrow storage the next part may move.
    fn accept(self: *Reducer, data: []const u8, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool)) Error!void {
        const cancelled = cancel_flag.load(.seq_cst);
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase != .streaming and self.phase != .stopped) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        if (json_depth.exceeds(data)) return error.JsonTooDeep;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedGeminiEvent,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (root.get("error")) |failure| {
            try self.accept_error(data, failure);
            return;
        }
        // Cloud Code wraps Gemini's response; a direct one is read the same.
        const response = if (root.get("response")) |inner| try object(inner) else root;
        if (non_null(response, "responseId")) |value| if (self.generation_id == null) {
            const id = try string(value);
            if (id.len > self.limits.identity_bytes) return error.IdentityTooLarge;
            if (id.len != 0) self.generation_id = try self.alloc.dupe(u8, id);
        };
        if (non_null(response, "usageMetadata")) |usage| self.accept_usage(usage);
        const candidates = non_null(response, "candidates") orelse return;
        if (candidates != .array) return error.InvalidEvent;
        if (candidates.array.items.len == 0) return;
        const candidate = try object(candidates.array.items[0]);
        if (non_null(candidate, "content")) |content| {
            const fields = try object(content);
            if (non_null(fields, "parts")) |parts| {
                if (parts != .array) return error.InvalidEvent;
                for (parts.array.items) |part| {
                    const deltas = try self.accept_part(try object(part));
                    if (events) |sink| try emit(sink, deltas, cancel_flag);
                }
            }
        }
        if (non_null(candidate, "finishReason")) |reason| {
            self.stop = finish_name(try string(reason));
            self.phase = .stopped;
        }
    }

    fn accept_part(self: *Reducer, part: std.json.ObjectMap) Error!Deltas {
        const signature: ?[]const u8 = if (non_null(part, "thoughtSignature")) |value| try string(value) else null;
        if (non_null(part, "functionCall")) |value| {
            self.thinking = false;
            return self.accept_call(try object(value), signature);
        }
        const thought = if (non_null(part, "thought")) |value| value == .bool and value.bool else false;
        const text = if (non_null(part, "text")) |value| try string(value) else "";
        if (thought) {
            if (!self.thinking or (self.thoughts.items.len != 0 and self.thoughts.items[self.thoughts.items.len - 1].signature != null)) {
                try self.thoughts.append(self.alloc, .{});
            }
            self.thinking = true;
            const current = &self.thoughts.items[self.thoughts.items.len - 1];
            const shown = try self.append_reasoning(&current.text, text);
            if (signature) |value| try self.keep_signature(&current.signature, value);
            return .{ .reasoning = shown };
        }
        self.thinking = false;
        if (signature) |value| {
            // A signature on an empty part belongs to the thought before it.
            if (text.len == 0 and self.thoughts.items.len != 0 and self.thoughts.items[self.thoughts.items.len - 1].signature == null) {
                try self.keep_signature(&self.thoughts.items[self.thoughts.items.len - 1].signature, value);
            } else if (self.text_signature == null) try self.keep_signature(&self.text_signature, value);
        }
        if (text.len == 0) return .{};
        const start = self.content.items.len;
        if (text.len > self.limits.content_bytes - start) return error.ContentTooLarge;
        try self.content.appendSlice(self.alloc, text);
        if (self.structured_name != null) return .{};
        return .{ .content = self.content.items[start..] };
    }

    fn keep_signature(self: *Reducer, destination: *?[]u8, value: []const u8) Error!void {
        if (value.len > types.ProviderReplay.max_bytes - self.reasoning_bytes) return error.ReplayTooLarge;
        self.reasoning_bytes += value.len;
        if (destination.*) |old| self.alloc.free(old);
        destination.* = try self.alloc.dupe(u8, value);
    }

    fn append_reasoning(self: *Reducer, destination: *std.ArrayList(u8), text: []const u8) Error!?[]const u8 {
        const limit = @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes);
        if (text.len > limit - self.reasoning_bytes) return error.ReplayTooLarge;
        self.reasoning_bytes += text.len;
        const start = destination.items.len;
        try destination.appendSlice(self.alloc, text);
        return if (text.len == 0) null else destination.items[start..];
    }

    fn accept_call(self: *Reducer, call: std.json.ObjectMap, signature: ?[]const u8) Error!Deltas {
        const name = try string(call.get("name") orelse return error.InvalidEvent);
        if (name.len == 0 or name.len > @min(function_tools.max_name_bytes, self.limits.identity_bytes)) return error.IdentityTooLarge;
        const structured = if (self.structured_name) |expected| std.mem.eql(u8, expected, name) else false;
        if (self.structured_name != null and (!structured or self.calls.items.len != 0)) return error.UnexpectedToolCall;
        if (self.choice == .none and !structured) return error.UnexpectedToolCall;
        if (self.calls.items.len == self.limits.tool_calls) return error.TooManyTools;
        const arguments = if (non_null(call, "args")) |args| blk: {
            if (args != .object) return error.InvalidEvent;
            break :blk try std.json.Stringify.valueAlloc(self.alloc, args, .{});
        } else try self.alloc.dupe(u8, "{}");
        errdefer self.alloc.free(arguments);
        if (arguments.len > if (structured) self.limits.content_bytes else self.limits.arguments_bytes) return error.ArgumentsTooLarge;
        // Gemini names a call only sometimes; Spark needs an ID for each.
        const given: ?[]const u8 = if (non_null(call, "id")) |value| try string(value) else null;
        const id = if (given) |value| (if (value.len != 0) try self.alloc.dupe(u8, value) else null) else null;
        const owned_id = id orelse try std.fmt.allocPrint(self.alloc, "call_{d}_{s}", .{ self.calls.items.len, std.fmt.bytesToHex(random_bytes(), .lower) });
        errdefer self.alloc.free(owned_id);
        if (owned_id.len > self.limits.identity_bytes) return error.IdentityTooLarge;
        for (self.calls.items) |prior| if (std.mem.eql(u8, prior.id, owned_id)) return error.InvalidEvent;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        var stored: Call = .{ .id = owned_id, .name = owned_name, .arguments = arguments, .structured = structured };
        if (signature) |value| try self.keep_signature(&stored.signature, value);
        try self.calls.append(self.alloc, stored);
        if (structured) return .{};
        const kept = &self.calls.items[self.calls.items.len - 1];
        return .{ .tool_started = .{ .id = kept.id, .name = kept.name }, .tool_input = kept.arguments };
    }

    fn accept_usage(self: *Reducer, value: std.json.Value) void {
        if (value != .object) return;
        const fields = value.object;
        if (count(fields, "promptTokenCount")) |n| self.usage.input_tokens = n;
        const candidates = count(fields, "candidatesTokenCount");
        const thoughts = count(fields, "thoughtsTokenCount");
        if (candidates != null or thoughts != null) self.usage.output_tokens = (candidates orelse 0) +| (thoughts orelse 0);
        if (thoughts) |n| self.usage.reasoning_tokens = n;
        if (count(fields, "cachedContentTokenCount")) |n| self.usage.cache_read_tokens = n;
    }

    fn accept_error(self: *Reducer, data: []const u8, value: std.json.Value) Error!void {
        const status = if (value == .object) if (non_null(value.object, "status")) |name| (if (name == .string) name.string else "") else "" else "";
        const detail = try self.alloc.dupe(u8, if (data.len > max_error_detail_bytes) "Provider error details exceeded the local limit" else data);
        self.failure = .{ .kind = failure_kind(status), .detail = detail };
        self.phase = .failed;
    }

    fn provider_state(self: *const Reducer) Error!?[]u8 {
        var any = self.text_signature != null;
        for (self.thoughts.items) |thought| any = any or thought.text.items.len != 0 or thought.signature != null;
        for (self.calls.items) |call| any = any or (call.signature != null and !call.structured);
        if (!any) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const writer = &out.writer;
        write_state(writer, self) catch return error.OutOfMemory;
        if (out.written().len > @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes)) return error.ReplayTooLarge;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    fn write_state(writer: *std.Io.Writer, self: *const Reducer) !void {
        try writer.writeAll("{\"thoughts\":[");
        for (self.thoughts.items, 0..) |thought, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"text\":");
            try std.json.Stringify.value(thought.text.items, .{}, writer);
            if (thought.signature) |value| try write_signature_field(writer, "signature", value);
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
        if (self.text_signature) |value| try write_signature_field(writer, "text_signature", value);
        try writer.writeAll(",\"calls\":[");
        var first = true;
        for (self.calls.items) |call| {
            const value = call.signature orelse continue;
            if (call.structured) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(call.id, .{}, writer);
            try write_signature_field(writer, "signature", value);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }

    fn write_signature_field(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
        try writer.print(",\"{s}\":", .{name});
        try std.json.Stringify.value(value, .{}, writer);
    }

    fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        switch (self.phase) {
            .closed => return error.StreamClosed,
            .failed => {
                const failure = self.failure.?;
                self.failure = null;
                self.phase = .closed;
                return .{ .failed = .{ .kind = failure.kind, .detail = failure.detail, .ownership = .owned } };
            },
            .stopped => {},
            .streaming => return error.IncompleteStream,
        }
        const raw = self.stop orelse return error.InvalidFinishReason;
        var reason = finish_reason_of(raw);
        if (self.structured_name != null) {
            if (self.calls.items.len == 0 and reason == .stop and self.content.items.len == 0) return error.RequiredToolMissing;
        } else if (reason == .stop) {
            if (self.calls.items.len != 0) reason = .tool_calls;
            if (self.choice == .required and self.calls.items.len == 0) return error.RequiredToolMissing;
        }
        const state = try self.provider_state();
        errdefer if (state) |bytes| self.alloc.free(bytes);
        var content: ?[]u8 = null;
        errdefer if (content) |text| self.alloc.free(text);
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        try calls.ensureTotalCapacityPrecise(self.alloc, self.calls.items.len);
        for (self.calls.items) |*call| {
            if (call.structured) {
                content = call.arguments;
                call.arguments = &.{};
                continue;
            }
            try function_tools.validate_name(call.name);
            calls.appendAssumeCapacity(.{ .id = call.id, .name = call.name, .arguments_json = call.arguments });
            call.id = &.{};
            call.name = &.{};
            call.arguments = &.{};
        }
        if (self.structured_name != null and reason == .tool_calls) reason = .stop;
        if (content == null and self.content.items.len != 0) content = try self.content.toOwnedSlice(self.alloc);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        const generation_id = self.generation_id;
        self.generation_id = null;
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{
                .content = content,
                .tool_calls = owned_calls,
                .generation_id = generation_id,
                .finish_reason = reason,
                .finish_reason_raw = .init(raw),
                .usage = self.usage,
                .provider_state_json = state,
            },
            .ownership = .owned,
        } };
    }
};

fn random_bytes() [6]u8 {
    var bytes: [6]u8 = undefined;
    io_mod.getIo().random(&bytes);
    return bytes;
}

/// The finish reasons Gemini sends, as static strings Spark keeps.
fn finish_name(raw: []const u8) []const u8 {
    const known = [_][]const u8{ "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "IMAGE_SAFETY", "OTHER" };
    for (known) |name| if (std.mem.eql(u8, name, raw)) return name;
    return "FINISH_REASON_UNSPECIFIED";
}

fn finish_reason_of(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "STOP")) return .stop;
    if (std.mem.eql(u8, raw, "MAX_TOKENS")) return .length;
    const filtered = [_][]const u8{ "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "LANGUAGE" };
    if (function_tools.contains_name(&filtered, raw)) return .content_filter;
    return .provider_error;
}

/// The kind each Google status gets when it arrives as an HTTP status.
fn failure_kind(status: []const u8) stream_provider.FailureKind {
    const kinds = [_]struct { []const u8, stream_provider.FailureKind }{
        .{ "INVALID_ARGUMENT", .invalid_request },
        .{ "FAILED_PRECONDITION", .invalid_request },
        .{ "UNAUTHENTICATED", .unauthorized },
        .{ "PERMISSION_DENIED", .forbidden },
        .{ "RESOURCE_EXHAUSTED", .rate_limited },
        .{ "INTERNAL", .server_error },
        .{ "UNAVAILABLE", .unavailable },
        .{ "DEADLINE_EXCEEDED", .gateway_timeout },
    };
    for (kinds) |entry| if (std.mem.eql(u8, entry[0], status)) return entry[1];
    return .provider_error;
}

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidEvent;
}

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidEvent;
}

fn non_null(fields: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = fields.get(key) orelse return null;
    return if (value == .null) null else value;
}

fn count(fields: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = non_null(fields, key) orelse return null;
    return switch (value) {
        .integer => |n| std.math.cast(u64, n),
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn emit(sink: stream_provider.EventSink, deltas: Deltas, cancel_flag: *const std.atomic.Value(bool)) Error!void {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (deltas.reasoning) |text| sink.emit(.{ .reasoning_delta = text });
    if (deltas.content) |text| sink.emit(.{ .content_delta = text });
    if (deltas.tool_started) |tool| sink.emit(.{ .tool_started = .{ .id = tool.id, .name = tool.name } });
    if (deltas.tool_input) |text| sink.emit(.{ .tool_input_delta = text });
}

/// Reads the reply until the stream ends after the event that names why it
/// stopped, or an error event. The caller masks credentials in a failure.
pub fn consume_stream(alloc: Allocator, source: *std.Io.Reader, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool), progress: ?sse.Progress) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes, .progress = progress };
    defer framing.deinit(alloc);
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        const event_limited = limits.event_bytes < remaining;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return if (event_limited) error.EventTooLarge else error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse return reducer.finish(cancel_flag.load(.seq_cst));
        try reducer.accept(chunk, events, cancel_flag);
        if (reducer.phase == .failed) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

const test_functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read_file", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
        .additional_properties = false,
    } },
};

fn test_request() stream_provider.RequestData {
    return .{
        .model = "gemini-3.8-flash",
        .instructions = &.{ .{ .role = .system, .content = "first" }, .{ .role = .system, .content = "second" } },
        .messages = &.{.{ .role = .user, .content = "Read x" }},
        .tool_choice = .auto,
        .provider_options = .{},
        .tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &test_functions },
    };
}

const Recorder = struct {
    alloc: Allocator,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    started: std.ArrayList(u8) = .empty,

    fn sink(self: *Recorder) stream_provider.EventSink {
        return .{ .context = self, .emit_fn = record };
    }

    fn record(context: *anyopaque, event: stream_provider.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        switch (event) {
            .content_delta => |text| self.content.appendSlice(self.alloc, text) catch {},
            .reasoning_delta => |text| self.reasoning.appendSlice(self.alloc, text) catch {},
            .tool_started => |tool| self.started.appendSlice(self.alloc, tool.name) catch {},
            else => {},
        }
    }

    fn deinit(self: *Recorder) void {
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        self.started.deinit(self.alloc);
    }
};

const test_wire =
    "data: {\"response\":{\"responseId\":\"resp-1\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Looking \",\"thought\":true},{\"text\":\"for x.\",\"thought\":true,\"thoughtSignature\":\"sig-thought\"}]}}]}}\n\n" ++
    "data: {\"response\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Reading.\"},{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"x\"}},\"thoughtSignature\":\"sig-call\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"thoughtsTokenCount\":3}}}\n\n";

test "Cloud Code streams thoughts, text and a call, and the next turn replays their signatures" {
    const a = std.testing.allocator;
    var source = std.Io.Reader.fixed(test_wire);
    var recorder: Recorder = .{ .alloc = a };
    defer recorder.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(a, &source, test_request(), .{}, recorder.sink(), &cancelled, null);
    defer result.deinit(a);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Looking for x.", recorder.reasoning.items);
    try std.testing.expectEqualStrings("Reading.", recorder.content.items);
    try std.testing.expectEqualStrings("read_file", recorder.started.items);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("resp-1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 8), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.reasoning_tokens);

    var provider = model_provider.parse("antigravity-plan-00000000000000000000000000000001").?;
    provider.configured.binding = @splat(1);
    var request = test_request();
    request.messages = &.{
        .{ .role = .user, .content = "Read x" },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = completion.tool_calls, .provider_replay = .{ .source = .{ .provider = provider, .model = request.model }, .parts_json = completion.provider_state_json.? } },
        .{ .role = .tool, .tool_call_id = completion.tool_calls[0].id, .content = "contents of x" },
    };
    const body = try build_request(a, request, .{ .provider = &provider, .model = "gemini-3.8-flash-high", .thinking_json = "{\"includeThoughts\":true,\"thinkingLevel\":\"high\"}", .default_max_tokens = 65536 });
    defer a.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, project_placeholder));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gemini-3.8-flash-high", root.get("model").?.string);
    try std.testing.expectEqualStrings("agent", root.get("requestType").?.string);
    const inner = root.get("request").?.object;
    const system = inner.get("systemInstruction").?.object.get("parts").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.startsWith(u8, system, "You are Antigravity"));
    try std.testing.expect(std.mem.endsWith(u8, system, "first\n\nsecond"));
    const contents = inner.get("contents").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), contents.len);
    const model_parts = contents[1].object.get("parts").?.array.items;
    try std.testing.expect(model_parts[0].object.get("thought").?.bool);
    try std.testing.expectEqualStrings("sig-thought", model_parts[0].object.get("thoughtSignature").?.string);
    try std.testing.expectEqualStrings("Reading.", model_parts[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("sig-call", model_parts[2].object.get("thoughtSignature").?.string);
    const response = contents[2].object.get("parts").?.array.items[0].object.get("functionResponse").?.object;
    try std.testing.expectEqualStrings("read_file", response.get("name").?.string);
    try std.testing.expectEqualStrings("contents of x", response.get("response").?.object.get("output").?.string);
    const declaration = inner.get("tools").?.array.items[0].object.get("functionDeclarations").?.array.items[0].object;
    try std.testing.expect(declaration.get("parameters").?.object.get("additionalProperties") == null);
    const generation = inner.get("generationConfig").?.object;
    try std.testing.expectEqual(@as(i64, 65536), generation.get("maxOutputTokens").?.integer);
    try std.testing.expectEqualStrings("high", generation.get("thinkingConfig").?.object.get("thinkingLevel").?.string);
}

test "Cloud Code replies without a signature get Gemini's skip marker, and Claude tools are validated" {
    const a = std.testing.allocator;
    var request = test_request();
    request.messages = &.{
        .{ .role = .user, .content = "Read x" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" }} },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "denied", .tool_result_status = .failure },
    };
    const body = try build_request(a, request, .{});
    defer a.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"thoughtSignature\":\"" ++ skip_signature ++ "\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"error\":\"denied\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "toolConfig") == null);
    request.model = "claude-sonnet-5-5";
    const claude = try build_request(a, request, .{});
    defer a.free(claude);
    try std.testing.expect(std.mem.find(u8, claude, "\"mode\":\"VALIDATED\"") != null);
    try std.testing.expect(std.mem.find(u8, claude, skip_signature) == null);
}

test "Cloud Code error events fail the request with their kind, and a cut stream is incomplete" {
    const a = std.testing.allocator;
    const cancelled = std.atomic.Value(bool).init(false);
    var source = std.Io.Reader.fixed("data: {\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}\n\n");
    var result = try consume_stream(a, &source, test_request(), .{}, null, &cancelled, null);
    defer result.deinit(a);
    try std.testing.expectEqual(stream_provider.FailureKind.rate_limited, result.failed.kind);
    var cut = std.Io.Reader.fixed("data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]}}]}}\n\n");
    try std.testing.expectError(error.IncompleteStream, consume_stream(a, &cut, test_request(), .{}, null, &cancelled, null));
    var limited = std.Io.Reader.fixed("data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"MAX_TOKENS\"}]}}\n\n");
    var cut_off = try consume_stream(a, &limited, test_request(), .{}, null, &cancelled, null);
    defer cut_off.deinit(a);
    try std.testing.expectEqual(types.ProviderFinishReason.length, cut_off.completed.completion.finish_reason.?);
}

test "Cloud Code schemas drop the keywords Gemini refuses but keep property names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"object","additionalProperties":false,"$schema":"x","properties":{"format":{"type":["string","null"],"format":"uri"},"title":{"type":"integer","default":3}},"required":["format","missing"]}
    , .{});
    const clean = try sanitize(a, input, false);
    const text = try std.json.Stringify.valueAlloc(a, clean, .{});
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"format\":{\"type\":\"string\"},\"title\":{\"type\":\"integer\"}},\"required\":[\"format\"]}", text);
}
