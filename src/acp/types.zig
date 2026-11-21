const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc.zig");
const core_types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;

pub const MessageIdBuffer = [32]u8;

pub fn generateMessageId(storage: *MessageIdBuffer) []const u8 {
    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    storage.* = std.fmt.bytesToHex(random_bytes, .lower);
    return storage;
}

pub const protocol_version: u32 = 1;

/// Returns the borrowed value at `_meta.spark.<key>` on an ACP params object.
/// spark reads and writes its protocol extensions under that one namespace.
pub fn fxMetaField(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const meta = object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const spark = meta.object.get("spark") orelse return null;
    if (spark != .object) return null;
    return spark.object.get(key);
}

/// Returns `_meta.spark.<key>` when it is a JSON boolean.
pub fn fxMetaBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = fxMetaField(object, key) orelse return null;
    return if (value == .bool) value.bool else null;
}

/// Returns `_meta.spark.<key>` when it is a JSON integer.
pub fn fxMetaInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = fxMetaField(object, key) orelse return null;
    return if (value == .integer) value.integer else null;
}

const model_recovery_update_prefix = "{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"spark\":{\"modelResponseRecovery\":";

/// What a session load reports for a request an earlier spark process was
/// running when it stopped.
/// `_meta.spark.modelResponseRecovery`: the recovery module's shape, as in
/// `spark ask --json` (decision 38). Null clears the client's status.
pub fn writeModelRecoveryInfoUpdate(
    writer: *std.Io.Writer,
    status: ?core_types.RouteRecoveryStatus,
) !void {
    try writer.writeAll(model_recovery_update_prefix);
    const recovery = status orelse {
        try writer.writeAll("null}}}");
        return;
    };
    var label_buf: [core_types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try recovery.report(&label_buf).writeJson(writer);
    try writer.writeAll("}}}");
}

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,
    /// The host gave the turn a time to stop at, and it stopped before its
    /// next model request with the turn kept open for a later resume.
    yielded,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
            .yielded => "yielded",
        };
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub fn writeSessionUpdate(w: *std.Io.Writer, session_id: []const u8, update_json: []const u8) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    try w.writeAll(",\"update\":");
    try w.writeAll(update_json);
    try w.writeAll("}");
}

pub fn writeAgentMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

/// ACP v1 Session Notice: shown to the user, never part of the session's
/// history. Only for a client that advertised `session.notices`.
pub fn writeNotice(w: *std.Io.Writer, severity: []const u8, title: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"notice\",\"severity\":");
    try writeJsonStr(severity, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeByte('}');
}

test "writeNotice writes an ACP v1 notice update" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeNotice(&out.writer, "info", "A \"quoted\" title");
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"notice\",\"severity\":\"info\",\"title\":\"A \\\"quoted\\\" title\"}", out.written());
}

pub fn writeAgentThoughtChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserImageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    media_type: []const u8,
    bytes: []const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"image\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(w, bytes);
    try w.writeAll("\",\"mimeType\":");
    try writeJsonStr(media_type, w);
    try w.writeAll("}}");
}

/// Host-facing identity of a tool call, sent as `_meta.spark.toolCall` so
/// clients never need to match on tool names.
pub const ToolCallMeta = struct {
    /// spark's own discovery or bookkeeping step, which hosts may hide.
    internal: bool = false,
    /// The MCP server and its own tool name, for MCP tool calls.
    mcp: ?struct { server: []const u8, tool: []const u8 } = null,
};

fn writeToolCallMeta(w: *std.Io.Writer, meta: ToolCallMeta) !void {
    try w.writeAll(",\"_meta\":{\"spark\":{\"toolCall\":{\"internal\":");
    try w.writeAll(if (meta.internal) "true" else "false");
    if (meta.mcp) |mcp| {
        try w.writeAll(",\"mcp\":{\"server\":");
        try writeJsonStr(mcp.server, w);
        try w.writeAll(",\"tool\":");
        try writeJsonStr(mcp.tool, w);
        try w.writeByte('}');
    }
    try w.writeAll("}}}");
}

pub fn writeToolCall(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    raw_input: ?std.json.Value,
    meta: ToolCallMeta,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"name\":");
    try writeJsonStr(name, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"kind\":");
    try writeJsonStr(kind.jsonString(), w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (raw_input) |value| {
        try w.writeAll(",\"rawInput\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    try writeToolCallMeta(w, meta);
    try w.writeAll("}");
}

pub fn writeToolCallUpdate(w: *std.Io.Writer, tool_call_id: []const u8, status: ToolCallStatus, content_text: ?[]const u8) !void {
    try writeToolCallUpdateWithCommandResult(w, tool_call_id, status, content_text, null);
}

pub fn writeToolCallUpdateWithCommandResult(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    content_text: ?[]const u8,
    command_result_json: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (content_text) |text| {
        try w.writeAll(",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
        try writeJsonStr(text, w);
        try w.writeAll("}}]");
    }
    if (command_result_json) |json| {
        try w.writeAll(",\"command_result\":");
        try w.writeAll(json);
    }
    try w.writeAll("}");
}

pub const AgentCapabilities = struct {
    image_prompts: bool,
    /// Accepts client `mcpServers` on session setup.
    mcp_servers: bool = true,
    /// Accepts steering prompts through `session/prompt` during a turn.
    steering: bool = false,
    /// Accepts a client system prompt on `session/new` in append mode.
    system_prompt: bool = false,
    /// Serves `type: "acp"` MCP servers over this connection.
    mcp_over_acp: bool = false,
    /// Speaks MCP's HTTP+SSE transport (2024-11-05), which spark's MCP engine doesn't.
    mcp_sse: bool = true,
};

pub fn writeInitializeResponse(w: *std.Io.Writer, capabilities: AgentCapabilities) !void {
    const mcp_servers = if (capabilities.mcp_servers) "true" else "false";
    try w.writeAll("{\"protocolVersion\":");
    try w.print("{d}", .{protocol_version});
    try w.writeAll(",\"agentCapabilities\":{");
    try w.writeAll("\"loadSession\":true,");
    try w.print("\"promptCapabilities\":{{\"image\":{s},\"audio\":false,\"embeddedContext\":true}},", .{if (capabilities.image_prompts) "true" else "false"});
    try w.print("\"mcpCapabilities\":{{\"http\":{s},\"sse\":{s},\"acp\":{s}}},", .{
        mcp_servers,
        if (capabilities.mcp_servers and capabilities.mcp_sse) "true" else "false",
        if (capabilities.mcp_over_acp) "true" else "false",
    });
    try w.writeAll("\"sessionCapabilities\":{\"list\":{},\"resume\":{},\"close\":{}");
    if (capabilities.system_prompt) try w.writeAll(",\"systemPrompt\":{}");
    try w.writeByte('}');
    try w.print(",\"_meta\":{{\"spark\":{{\"steering\":{s}}}}}", .{if (capabilities.steering) "true" else "false"});
    try w.writeAll("},\"agentInfo\":{\"name\":\"spark\",\"title\":\"spark\",\"version\":");
    try writeJsonStr(build_options.app_version, w);
    try w.writeAll("},");
    try w.writeAll("\"authMethods\":[]}");
}

pub fn writePromptResponse(w: *std.Io.Writer, reason: StopReason) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll("}");
}

/// How a steering `session/prompt` fared in the turn that received it.
pub const SteeringDelivery = enum {
    absorbed,
    dropped,
};

/// Answers a steering prompt with its receiving turn's stop reason. Usage is
/// reported once, on the response to the prompt that started the turn.
pub fn writeSteeringPromptResponse(w: *std.Io.Writer, reason: StopReason, delivery: SteeringDelivery) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll(",\"_meta\":{\"spark\":{\"steering\":");
    try writeJsonStr(@tagName(delivery), w);
    try w.writeAll("}}}");
}

/// Replays delivered steering where the agent inserted it into the turn. A
/// libfx steer carries the input id its host gave it.
pub fn writeSteeringUserMessageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    text: []const u8,
    request_id: ?jsonrpc.RequestId,
    input_id: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("},\"_meta\":{\"spark\":{\"steering\":{\"requestId\":");
    try jsonrpc.Writer.writeId(w, request_id);
    if (input_id) |id| {
        try w.writeAll(",\"inputId\":");
        try writeJsonStr(id, w);
    }
    try w.writeAll("}}}}");
}

pub fn writePromptResponseWithUsage(
    w: *std.Io.Writer,
    reason: StopReason,
    usage: core_types.Usage,
) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll(",\"usage\":{");
    var first = true;
    inline for (.{
        .{ "inputTokens", usage.input_tokens },
        .{ "outputTokens", usage.output_tokens },
        .{ "cacheReadTokens", usage.cache_read_tokens },
        .{ "cacheWriteTokens", usage.cache_write_tokens },
        .{ "reasoningTokens", usage.reasoning_tokens },
    }) |field| {
        if (field[1]) |value| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonStr(field[0], w);
            try w.print(":{d}", .{value});
        }
    }
    try w.writeAll("}}");
}

pub fn writeAvailableCommandsUpdate(w: *std.Io.Writer, commands_json: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":");
    try w.writeAll(commands_json);
    try w.writeAll("}");
}

pub fn writeSessionInfoUpdate(w: *std.Io.Writer, title: []const u8, updated_at: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"session_info_update\",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"updatedAt\":");
    try writeJsonStr(updated_at, w);
    try w.writeAll("}");
}

pub fn writeUsageUpdate(w: *std.Io.Writer, used: u64, size: u64) !void {
    try w.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}}}", .{ used, size });
}
