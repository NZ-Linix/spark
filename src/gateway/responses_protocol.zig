const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const json_depth = @import("../core/shared/json_depth.zig");
const json_comparison = @import("../core/shared/json_comparison.zig");
const text_utils = @import("../core/shared/text_utils.zig");

pub fn selectReplayParts(alloc: std.mem.Allocator, replay: ?types.ProviderReplay, _: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const source = replay orelse return null;
    if (source.source.provider == .none) return error.InvalidProviderState;
    if (text and reasoning) return source;
    if (!text and !reasoning) return null;
    if (source.parts_json.len > types.ProviderReplay.max_bytes) return error.ProviderStateTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, source.parts_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderState,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeByte('[') catch return error.OutOfMemory;
    var count: usize = 0;
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidProviderState;
        const kind = stringField(item.object, "type") orelse return error.InvalidProviderState;
        const keep = if (std.mem.eql(u8, kind, "reasoning")) reasoning else if (std.mem.eql(u8, kind, "message")) text else return error.InvalidProviderState;
        if (!keep) continue;
        if (count > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        std.json.Stringify.value(item, .{}, &out.writer) catch return error.OutOfMemory;
        count += 1;
    }
    if (count == 0) return null;
    if (count == parsed.value.array.items.len) return source;
    out.writer.writeByte(']') catch return error.OutOfMemory;
    return .{ .source = source.source, .parts_json = try out.toOwnedSlice() };
}

pub const ReplayLimits = struct {
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    provider_state_bytes: usize,
};

/// Verifies captured image files and releases replay/image scratch before returning.
/// Scratch must be independent of the writer's request-body arena.
pub fn writeInput(
    writer: *std.Io.Writer,
    scratch_alloc: std.mem.Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    limits: ReplayLimits,
    budget: image_attachments.CaptureBudget,
) !void {
    try budget.check();
    if (verified_images != null and (messages.len != 1 or
        messages[0].role != .user or messages[0].images.len != 0))
    {
        return error.InvalidVerifiedImagePlacement;
    }
    for (messages) |message| {
        if (message.role == .assistant) try validateReplayMessage(scratch_alloc, message, limits);
    }
    var ids = try tool_call_ids.Projection.init(scratch_alloc, messages);
    defer ids.deinit(scratch_alloc);
    var first = true;
    for (messages) |message| {
        try budget.check();
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeInputImage(writer, image, budget);
                        first_part = false;
                    }
                } else {
                    for (message.images) |attachment| {
                        var image = try image_attachments.loadVerifiedSnapshot(scratch_alloc, attachment, budget);
                        defer image.deinit(scratch_alloc);
                        if (!first_part) try writer.writeByte(',');
                        try writeInputImage(writer, image, budget);
                        first_part = false;
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                var legacy_phase: ?AssistantMessagePhase = null;
                var span_end: ?usize = null;
                const content = message.content orelse "";
                if (message.provider_replay) |replay| {
                    const state_json = replay.parts_json;
                    var state = std.json.parseFromSlice(std.json.Value, scratch_alloc, state_json, .{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidProviderState,
                    };
                    defer state.deinit();
                    if (state.value != .array) return error.InvalidProviderState;
                    for (state.value.array.items) |item| {
                        if (item != .object) return error.InvalidProviderState;
                        const kind = item.object.get("type") orelse return error.InvalidProviderState;
                        if (kind != .string) return error.InvalidProviderState;
                        if (std.mem.eql(u8, kind.string, "message")) {
                            const phase = assistantMessagePhase(item.object) catch return error.InvalidProviderState;
                            if (item.object.contains("offset") or item.object.contains("length")) {
                                if (legacy_phase != null) return error.InvalidProviderState;
                                const offset = replay_index(item.object, "offset") orelse return error.InvalidProviderState;
                                const length = replay_index(item.object, "length") orelse return error.InvalidProviderState;
                                if (offset > content.len or length == 0 or length > content.len - offset) return error.InvalidProviderState;
                                if (span_end) |end| {
                                    if (offset < end or !std.mem.eql(u8, content[end..offset], "\n\n")) return error.InvalidProviderState;
                                } else if (offset != 0) return error.InvalidProviderState;
                                try write_assistant_text(writer, &first, content[offset..][0..length], phase);
                                span_end = offset + length;
                            } else {
                                if (span_end != null or phase == null) return error.InvalidProviderState;
                                if (legacy_phase) |prior| if (prior != phase.?) return error.InvalidProviderState;
                                legacy_phase = phase;
                            }
                            continue;
                        }
                        if (!std.mem.eql(u8, kind.string, "reasoning")) return error.InvalidProviderState;
                        try writeComma(writer, &first);
                        try std.json.Stringify.value(item, .{}, writer);
                    }
                }
                if (span_end) |end| {
                    // Capture can end inside the separator before the next message.
                    const tail = content[end..];
                    if (tail.len > 2 or !std.mem.startsWith(u8, "\n\n", tail)) return error.InvalidProviderState;
                } else if (content.len > 0) try write_assistant_text(writer, &first, content, legacy_phase);
                for (message.tool_calls) |call| {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(ids.resolve(call.id), .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(ids.resolve(message.tool_call_id orelse ""), .{}, writer);
                try writer.writeAll(",\"output\":");
                const tool_images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
                if (tool_images.len == 0) {
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                } else {
                    const failed = message.tool_result_status == .failure;
                    const text = if (failed) try scratch_alloc.print("Tool error: {s}", .{message.content orelse ""}) else message.content orelse "";
                    defer if (failed) scratch_alloc.free(text);
                    try writer.writeByte('[');
                    if (text.len > 0) {
                        try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                        try std.json.Stringify.value(text, .{}, writer);
                        try writer.writeByte('}');
                    }
                    for (tool_images, 0..) |image, index| {
                        try budget.check();
                        const url = try scratch_alloc.print("data:{s};base64,{s}", .{ image.mime_type, image.data });
                        defer scratch_alloc.free(url);
                        if (index > 0 or text.len > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"type\":\"input_image\",\"image_url\":");
                        try std.json.Stringify.value(url, .{}, writer);
                        try writer.writeByte('}');
                        try budget.check();
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
        }
    }
}

fn replay_index(fields: std.json.ObjectMap, name: []const u8) ?usize {
    const value = fields.get(name) orelse return null;
    if (value != .integer) return null;
    return std.math.cast(usize, value.integer);
}

fn write_assistant_text(writer: *std.Io.Writer, first: *bool, content: []const u8, phase: ?AssistantMessagePhase) !void {
    try writeComma(writer, first);
    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeAll(",\"annotations\":[]}]");
    if (phase) |value| {
        try writer.writeAll(",\"phase\":");
        try std.json.Stringify.value(@tagName(value), .{}, writer);
    }
    try writer.writeByte('}');
}

test "Responses request projects long call ids with matching outputs" {
    const source_id = text_utils.repeat("c", 65);
    const calls = [_]types.ToolCall{.{ .id = source_id, .name = "read_file", .arguments_json = "{}" }};
    const images = [_]types.ToolImage{.{ .data = @constCast("cG5n"), .mime_type = @constCast("image/png") }};
    for ([_]bool{ false, true }) |with_images| {
        const messages = [_]types.ChatMessage{
            .{ .role = .assistant, .tool_calls = &calls },
            .{ .role = .tool, .tool_call_id = source_id, .tool_name = "read_file", .content = "result", .tool_result_memory = if (with_images) .{ .tool_images = &images } else null },
        };
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try out.writer.writeByte('[');
        try writeInput(&out.writer, std.testing.allocator, &messages, null, .{ .tool_calls = 128, .tool_identity_bytes = 256, .tool_arguments_bytes = 4096, .provider_state_bytes = 4096 }, .{});
        try out.writer.writeByte(']');
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        const call_id = items[0].object.get("call_id").?.string;
        try std.testing.expect(call_id.len <= 64);
        try std.testing.expectEqualStrings(call_id, items[1].object.get("call_id").?.string);
        try std.testing.expectEqualStrings(source_id, calls[0].id);
        if (with_images) {
            const output = items[1].object.get("output").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), output.len);
            try std.testing.expectEqualStrings("result", output[0].object.get("text").?.string);
            try std.testing.expectEqualStrings("input_image", output[1].object.get("type").?.string);
            try std.testing.expectEqualStrings("data:image/png;base64,cG5n", output[1].object.get("image_url").?.string);
        } else {
            try std.testing.expectEqualStrings("result", items[1].object.get("output").?.string);
        }
    }
}

fn validateReplayMessage(alloc: std.mem.Allocator, message: types.ChatMessage, limits: ReplayLimits) !void {
    if (message.provider_replay) |replay| {
        const state_json = replay.parts_json;
        if (state_json.len > limits.provider_state_bytes) return error.ProviderStateTooLarge;
    }
    if (message.tool_calls.len > limits.tool_calls) return error.ToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.ToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.ToolArgumentsTooLarge;
        }
        if (call.provenance != .provider_executed and
            try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, call.arguments_json) != .valid)
        {
            return error.InvalidToolArguments;
        }
    }
}

const ImageInputTest = struct {
    const limits = ReplayLimits{ .tool_calls = 128, .tool_identity_bytes = 256, .tool_arguments_bytes = 4096, .provider_state_bytes = 4096 };

    fn capture(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8, id: usize) !types.ImageAttachment {
        const io_mod = @import("../core/shared/io.zig");
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
        const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
        defer alloc.free(path);
        const source = [_]types.ImageAttachment{.{ .id = id, .path = @constCast(path), .media_type = @constCast("image/png") }};
        const owned = try types.dupeImageAttachmentSlice(alloc, &source);
        defer alloc.free(owned);
        var attachment = owned[0];
        errdefer types.freeImageAttachment(alloc, attachment);
        const snapshot_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshot(alloc, &attachment, snapshot_dir);
        return attachment;
    }

    fn write(alloc: std.mem.Allocator, writer: *std.Io.Writer, messages: []const types.ChatMessage, verified: ?[]const image_attachments.VerifiedSnapshot) !void {
        try writer.writeByte('[');
        try writeInput(writer, alloc, messages, verified, limits, .{});
        try writer.writeByte(']');
    }
};

fn expectImageInputAllocations(alloc: std.mem.Allocator, attachment: types.ImageAttachment) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ImageInputTest.write(alloc, &out.writer, &.{.{ .role = .user, .images = &.{attachment} }}, null);
}

fn writeInputImage(
    writer: *std.Io.Writer,
    image: image_attachments.VerifiedSnapshot,
    budget: image_attachments.CaptureBudget,
) !void {
    try budget.check();
    try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    var offset: usize = 0;
    while (offset < image.bytes.len) {
        try budget.check();
        const end = @min(offset + 3 * 1024, image.bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, image.bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}");
    try budget.check();
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

/// Serializes the provider-neutral function tool selection into the Responses
/// API shape. Provider-executed tools remain owned by their concrete provider.
pub fn writeTools(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(",\"tools\":[");

    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .static = tool.input_schema },
        );
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .static = tool.input_schema },
        );
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .dynamic = tool.input_schema },
        );
        count += 1;
    }
    try out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(out.written());
    return count;
}

pub const StreamLimits = struct {
    aggregate_bytes: usize,
    count_json_bytes: bool = true,
    events: usize,
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    provider_state_bytes: usize,
};

pub const StreamCallbacks = struct {
    context: *anyopaque,
    on_content: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback = null,
    on_reasoning: ?stream_provider.StreamCallback = null,
    on_tool_input: ?stream_provider.StreamCallback = null,
};

const ToolAccumulator = struct {
    output_index: i64,
    id: []u8,
    name: []u8,
    item_id: ?[]u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    arguments_finalized: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        if (self.item_id) |id| alloc.free(id);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }

    fn reconcileIdentity(
        self: *ToolAccumulator,
        alloc: std.mem.Allocator,
        fields: std.json.ObjectMap,
        item_id_key: []const u8,
        limits: StreamLimits,
    ) !void {
        try checkOptionalIdentity(fields, "call_id", self.id);
        try checkOptionalIdentity(fields, "name", self.name);
        if (fields.get(item_id_key)) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidEvent;
            if (value.string.len > limits.tool_identity_bytes) return error.ToolCallLimitExceeded;
            if (self.item_id) |id| {
                if (!std.mem.eql(u8, id, value.string)) return error.ResponsesToolCallConflict;
            } else {
                self.item_id = try alloc.dupe(u8, value.string);
            }
        }
    }

    fn finalizeArguments(
        self: *ToolAccumulator,
        alloc: std.mem.Allocator,
        arguments: []const u8,
        callbacks: StreamCallbacks,
        limits: StreamLimits,
    ) !void {
        if (arguments.len > limits.tool_arguments_bytes) return error.ToolArgumentsTooLarge;
        if (self.arguments_finalized) {
            if (!try json_comparison.serializedEqual(alloc, self.arguments.items, arguments)) return error.ResponsesToolCallConflict;
            return;
        }
        const previous_len = self.arguments.items.len;
        if (std.mem.startsWith(u8, arguments, self.arguments.items)) {
            const suffix = arguments[previous_len..];
            try appendToolArguments(alloc, &self.arguments, suffix, limits.tool_arguments_bytes);
            if (suffix.len > 0) if (callbacks.on_tool_input) |callback| callback(callbacks.context, suffix);
        } else {
            try self.arguments.ensureTotalCapacity(alloc, arguments.len);
            self.arguments.clearRetainingCapacity();
            self.arguments.appendSliceAssumeCapacity(arguments);
        }
        self.arguments_finalized = true;
    }
};

fn checkOptionalIdentity(fields: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    if (fields.get(key)) |value| {
        if (value != .string) return error.InvalidEvent;
        if (!std.mem.eql(u8, value.string, expected)) return error.ResponsesToolCallConflict;
    }
}

fn optional_index(fields: std.json.ObjectMap, name: []const u8) error{InvalidEvent}!?i64 {
    const value = fields.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return error.InvalidEvent;
    return value.integer;
}

const TextKey = struct {
    output_index: i64,
    content_index: i64,

    fn precedes(self: TextKey, other: TextKey) bool {
        return self.output_index < other.output_index or
            (self.output_index == other.output_index and self.content_index < other.content_index);
    }
};

const TextKind = enum { text, refusal };
const TextMode = enum { delta, final };
const TextDigest = std.crypto.hash.sha2.Sha256;

const TextUpdate = struct {
    key: TextKey,
    kind: TextKind,
    item_id_hash: ?[TextDigest.digest_length]u8,
    text: []const u8,
    mode: TextMode,
};

const TextPart = struct {
    kind: TextKind,
    received_bytes: usize = 0,
    digest: TextDigest = .init(.{}),
    finalized: bool = false,

    // Receipt is independent of capture: capped text cannot validate a final prefix.
    fn final_suffix(self: *const TextPart, text: []const u8) ![]const u8 {
        if (text.len < self.received_bytes or
            (self.finalized and text.len != self.received_bytes)) return error.ResponsesTextConflict;
        var actual: [TextDigest.digest_length]u8 = undefined;
        TextDigest.hash(text[0..self.received_bytes], &actual, .{});
        var prior = self.digest;
        const expected = prior.finalResult();
        if (!std.mem.eql(u8, &actual, &expected)) return error.ResponsesTextConflict;
        return text[self.received_bytes..];
    }
};

fn text_key(fields: std.json.ObjectMap) !TextKey {
    return .{
        .output_index = try optional_index(fields, "output_index") orelse 0,
        .content_index = try optional_index(fields, "content_index") orelse 0,
    };
}

fn text_identity(fields: std.json.ObjectMap, name: []const u8) !?[TextDigest.digest_length]u8 {
    const value = fields.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidEvent;
    var digest: [TextDigest.digest_length]u8 = undefined;
    TextDigest.hash(value.string, &digest, .{});
    return digest;
}

const AssistantMessagePhase = enum { commentary, final_answer };

fn assistantMessagePhase(fields: std.json.ObjectMap) !?AssistantMessagePhase {
    const raw = fields.get("phase") orelse return null;
    if (raw == .null) return null;
    if (raw != .string) return error.InvalidEvent;
    return std.meta.stringToEnum(AssistantMessagePhase, raw.string);
}

pub const Reducer = struct {
    const MessageItem = struct {
        output_index: i64,
        id_hash: ?[TextDigest.digest_length]u8,
        phase: ?AssistantMessagePhase,
        offset: usize = 0,
        length: usize = 0,

        fn replay_json(self: MessageItem, buffer: []u8) ![]const u8 {
            var out: std.Io.Writer = .fixed(buffer);
            try std.json.Stringify.value(.{ .type = "message", .offset = self.offset, .length = self.length, .phase = self.phase }, .{ .emit_null_optional_fields = false }, &out);
            return out.buffered();
        }
    };

    const ReasoningItem = struct {
        output_index: i64,
        id_hash: ?[TextDigest.digest_length]u8,
        json: ?[]u8,
    };

    content: std.ArrayList(u8) = .empty,
    message_items: std.ArrayList(MessageItem) = .empty,
    reasoning_items: std.ArrayList(ReasoningItem) = .empty,
    reasoning_bytes: usize = 0,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    generation_id: ?[]u8 = null,
    provider_failure_detail: ?[]u8 = null,
    provider_failure_cause: ?types.ProviderFailureCause = null,
    /// An error event or a failed response said why the request failed.
    failure_explained: bool = false,
    terminal_seen: bool = false,
    text_parts: std.AutoHashMapUnmanaged(TextKey, TextPart) = .empty,
    last_text_key: ?TextKey = null,
    text_bytes: usize = 0,
    event_count: usize = 0,
    aggregate_bytes: usize = 0,

    pub fn init(_: std.mem.Allocator) Reducer {
        return .{};
    }

    pub fn deinit(self: *Reducer, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
        self.message_items.deinit(alloc);
        self.text_parts.deinit(alloc);
        for (self.reasoning_items.items) |item| if (item.json) |json| alloc.free(json);
        self.reasoning_items.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
        if (self.provider_failure_detail) |detail| alloc.free(detail);
        self.* = undefined;
    }

    /// Reduces one decoded SSE data payload. Returns true after a terminal
    /// Responses event so the framing reader can stop without consuming more.
    pub fn applyJson(
        self: *Reducer,
        alloc: std.mem.Allocator,
        json_text: []const u8,
        callbacks: StreamCallbacks,
        cancel_flag: *std.atomic.Value(bool),
        content_capture_limit: ?usize,
        limits: StreamLimits,
    ) !bool {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (self.terminal_seen) return true;
        self.event_count = try checkedAccumulatedSize(self.event_count, 1, limits.events);
        if (limits.count_json_bytes) {
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                json_text.len,
                limits.aggregate_bytes,
            );
        }
        // spark serializes parts of an event, such as a reasoning item or a tool
        // input, and std.json.Stringify aborts past 256 levels.
        if (json_depth.exceeds(json_text)) return error.InvalidEvent;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Valid JSON that spark refuses ends the turn. Text that is not JSON
            // at all was damaged on the way, so the caller resends it.
            error.DuplicateField => return error.InvalidEvent,
            else => return error.MalformedEvent,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const event_type = stringField(parsed.value.object, "type") orelse return false;

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const output_index = try optional_index(parsed.value.object, "output_index") orelse return false;
            const item = parsed.value.object.get("item") orelse return false;
            if (item != .object) return false;
            const item_type = stringField(item.object, "type") orelse return false;
            if (std.mem.eql(u8, item_type, "function_call")) {
                try self.check_output_kind(output_index, .function_call);
                const call_id = stringField(item.object, "call_id") orelse return false;
                const name = stringField(item.object, "name") orelse return false;
                if (findTool(self.tools.items, output_index) == null) {
                    try appendTool(alloc, &self.tools, output_index, call_id, name, limits);
                    const tool = &self.tools.items[self.tools.items.len - 1];
                    try tool.reconcileIdentity(alloc, item.object, "id", limits);
                    if (item.object.get("arguments")) |value| {
                        if (value != .string) return error.InvalidEvent;
                        try appendToolArguments(alloc, &tool.arguments, value.string, limits.tool_arguments_bytes);
                    }
                    if (callbacks.on_tool_start) |callback| {
                        callback(callbacks.context, call_id, name, null, null);
                    }
                } else {
                    const index = findTool(self.tools.items, output_index).?;
                    try self.tools.items[index].reconcileIdentity(alloc, item.object, "id", limits);
                }
            } else if (std.mem.eql(u8, item_type, "reasoning")) {
                try self.reconcile_reasoning(alloc, output_index, item.object, .identity, limits);
            } else if (std.mem.eql(u8, item_type, "message")) {
                _ = try self.reconcile_message(alloc, output_index, try text_identity(item.object, "id"), try assistantMessagePhase(item.object), limits);
            } else {
                try self.check_output_kind(output_index, .unknown);
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            try self.accept_text(alloc, .{
                .key = try text_key(parsed.value.object),
                .kind = if (std.mem.eql(u8, event_type, "response.refusal.delta")) .refusal else .text,
                .item_id_hash = try text_identity(parsed.value.object, "item_id"),
                .text = stringField(parsed.value.object, "delta") orelse return error.InvalidEvent,
                .mode = .delta,
            }, callbacks, content_capture_limit, limits);
        } else if (std.mem.eql(u8, event_type, "response.output_text.done") or
            std.mem.eql(u8, event_type, "response.refusal.done"))
        {
            const refusal = std.mem.eql(u8, event_type, "response.refusal.done");
            try self.accept_text(alloc, .{
                .key = try text_key(parsed.value.object),
                .kind = if (refusal) .refusal else .text,
                .item_id_hash = try text_identity(parsed.value.object, "item_id"),
                .text = stringField(parsed.value.object, if (refusal) "refusal" else "text") orelse return error.InvalidEvent,
                .mode = .final,
            }, callbacks, content_capture_limit, limits);
        } else if (std.mem.eql(u8, event_type, "response.content_part.done")) {
            const part = parsed.value.object.get("part") orelse return error.InvalidEvent;
            if (part != .object) return error.InvalidEvent;
            try self.finalize_text_part(alloc, try text_key(parsed.value.object), try text_identity(parsed.value.object, "item_id"), part.object, callbacks, content_capture_limit, limits);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            if (try optional_index(parsed.value.object, "output_index")) |index| try self.check_output_kind(index, .reasoning);
            const delta = stringField(parsed.value.object, "delta") orelse return false;
            if (callbacks.on_reasoning) |callback| callback(callbacks.context, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            if (try optional_index(parsed.value.object, "output_index")) |index| try self.check_output_kind(index, .reasoning);
            if (callbacks.on_reasoning) |callback| callback(callbacks.context, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const output_index = try optional_index(parsed.value.object, "output_index") orelse return false;
            try self.check_output_kind(output_index, .function_call);
            const delta = stringField(parsed.value.object, "delta") orelse return false;
            const index = findTool(self.tools.items, output_index) orelse return false;
            try self.tools.items[index].reconcileIdentity(alloc, parsed.value.object, "item_id", limits);
            if (self.tools.items[index].arguments_finalized and delta.len > 0) return error.ResponsesToolCallConflict;
            try appendToolArguments(alloc, &self.tools.items[index].arguments, delta, limits.tool_arguments_bytes);
            if (callbacks.on_tool_input) |callback| callback(callbacks.context, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const output_index = try optional_index(parsed.value.object, "output_index") orelse return false;
            try self.check_output_kind(output_index, .function_call);
            const arguments = stringField(parsed.value.object, "arguments") orelse return error.InvalidEvent;
            const index = findTool(self.tools.items, output_index) orelse return error.ResponsesToolCallConflict;
            try self.tools.items[index].reconcileIdentity(alloc, parsed.value.object, "item_id", limits);
            try self.tools.items[index].finalizeArguments(alloc, arguments, callbacks, limits);
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const output_index = try optional_index(parsed.value.object, "output_index") orelse return false;
            const item = parsed.value.object.get("item") orelse return false;
            if (item != .object) return false;
            const item_type = stringField(item.object, "type") orelse return false;
            if (std.mem.eql(u8, item_type, "function_call")) {
                try self.reconcileToolItem(alloc, output_index, item.object, callbacks, limits);
            } else if (std.mem.eql(u8, item_type, "reasoning")) {
                try self.reconcile_reasoning(alloc, output_index, item.object, .completed, limits);
            } else if (std.mem.eql(u8, item_type, "message")) {
                try self.finalize_text_message(alloc, output_index, item.object, callbacks, cancel_flag, content_capture_limit, limits);
            } else {
                try self.check_output_kind(output_index, .unknown);
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete") or
            std.mem.eql(u8, event_type, "response.failed"))
        {
            const response_value = parsed.value.object.get("response") orelse return error.InvalidEvent;
            if (response_value != .object) return error.InvalidEvent;
            const status = try terminal_status(event_type, response_value.object);
            const output = response_value.object.get("output") orelse .null;
            if (status == .failed) {
                const failure = response_value.object.get("error");
                try self.accept_failure(alloc, if (failure != null and failure.? == .object) failure.?.object else .{});
            } else if (output != .null) {
                if (output != .array) return error.InvalidEvent;
                for (output.array.items, 0..) |item, output_index| {
                    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                    if (item != .object) continue;
                    const item_type = stringField(item.object, "type") orelse continue;
                    const index = std.math.cast(i64, output_index) orelse return error.ResourceLimitExceeded;
                    if (std.mem.eql(u8, item_type, "function_call")) {
                        try self.reconcileToolItem(alloc, index, item.object, callbacks, limits);
                    } else if (std.mem.eql(u8, item_type, "reasoning")) {
                        try self.reconcile_reasoning(alloc, index, item.object, .completed, limits);
                    } else if (std.mem.eql(u8, item_type, "message")) {
                        try self.finalize_text_message(alloc, index, item.object, callbacks, cancel_flag, content_capture_limit, limits);
                    } else {
                        try self.check_output_kind(index, .unknown);
                    }
                }
            }
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            self.terminal_seen = true;
            self.finish_reason = finishReason(
                status,
                response_value.object,
                self.tools.items.len > 0,
            );
            // An incomplete response with no known reason, or a cancelled
            // one, failed without saying why, and spark resends it.
            if (self.finish_reason == .provider_error and !self.failure_explained) {
                self.provider_failure_cause = .unexplained_error_finish;
            }
            self.usage = parseUsage(response_value.object);
            if (stringField(response_value.object, "id")) |id| {
                if (self.generation_id) |prior| alloc.free(prior);
                self.generation_id = try alloc.dupe(u8, id);
            }
            return true;
        } else if (std.mem.eql(u8, event_type, "error")) {
            try self.accept_failure(alloc, parsed.value.object);
            self.terminal_seen = true;
            self.finish_reason = .provider_error;
            return true;
        }
        return false;
    }

    fn check_output_kind(self: *const Reducer, output_index: i64, kind: enum { function_call, reasoning, message, unknown }) error{ResponsesOutputItemConflict}!void {
        if (kind != .function_call and findTool(self.tools.items, output_index) != null) return error.ResponsesOutputItemConflict;
        if (kind != .reasoning) for (self.reasoning_items.items) |item| {
            if (item.output_index == output_index) return error.ResponsesOutputItemConflict;
        };
        if (kind != .message) for (self.message_items.items) |item| {
            if (item.output_index == output_index) return error.ResponsesOutputItemConflict;
        };
    }

    fn reconcile_reasoning(self: *Reducer, alloc: std.mem.Allocator, output_index: i64, fields: std.json.ObjectMap, evidence: enum { identity, completed }, limits: StreamLimits) !void {
        try self.check_output_kind(output_index, .reasoning);
        const id_hash = try text_identity(fields, "id");
        var low: usize = 0;
        var high = self.reasoning_items.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.reasoning_items.items[middle].output_index < output_index) low = middle + 1 else high = middle;
        }
        const found = low < self.reasoning_items.items.len and self.reasoning_items.items[low].output_index == output_index;
        if (id_hash) |id| for (self.reasoning_items.items) |prior| {
            const prior_id = prior.id_hash orelse continue;
            const same_id = std.mem.eql(u8, &prior_id, &id);
            if (prior.output_index == output_index and !same_id) return error.ResponsesReasoningConflict;
            if (prior.output_index != output_index and same_id) return error.ResponsesReasoningConflict;
        };
        const encrypted = fields.get("encrypted_content") orelse .null;
        if (encrypted != .null and encrypted != .string) return error.InvalidEvent;
        const json = if (evidence == .completed and encrypted == .string)
            try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = fields }, .{})
        else
            null;
        errdefer if (json) |bytes| alloc.free(bytes);
        if (found) if (self.reasoning_items.items[low].json) |prior| {
            if (json) |bytes| {
                if (!try json_comparison.serializedEqual(alloc, prior, bytes)) return error.ResponsesReasoningConflict;
                alloc.free(bytes);
            }
            if (id_hash != null) self.reasoning_items.items[low].id_hash = id_hash;
            return;
        };
        var total = self.reasoning_bytes;
        if (json) |bytes| {
            const overhead: usize = if (total == 0) 2 else 1;
            const size = try checkedAccumulatedSize(bytes.len, overhead, limits.provider_state_bytes);
            total = try checkedAccumulatedSize(total, size, limits.provider_state_bytes);
        }
        if (found) {
            const prior = &self.reasoning_items.items[low];
            if (id_hash != null) prior.id_hash = id_hash;
            prior.json = json;
        } else {
            if (self.reasoning_items.items.len >= limits.events) return error.ResourceLimitExceeded;
            try self.reasoning_items.insert(alloc, low, .{ .output_index = output_index, .id_hash = id_hash, .json = json });
        }
        self.reasoning_bytes = total;
    }

    fn reconcile_message(self: *Reducer, alloc: std.mem.Allocator, output_index: i64, id_hash: ?[TextDigest.digest_length]u8, phase: ?AssistantMessagePhase, limits: StreamLimits) !*MessageItem {
        try self.check_output_kind(output_index, .message);
        var low: usize = 0;
        var high = self.message_items.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.message_items.items[middle].output_index < output_index) low = middle + 1 else high = middle;
        }
        if (id_hash) |id| for (self.message_items.items) |prior| {
            const prior_id = prior.id_hash orelse continue;
            const same_id = std.mem.eql(u8, &prior_id, &id);
            if (prior.output_index == output_index and !same_id) return error.ResponsesTextConflict;
            if (prior.output_index != output_index and same_id) return error.ResponsesTextConflict;
        };
        if (low < self.message_items.items.len and self.message_items.items[low].output_index == output_index) {
            const prior = &self.message_items.items[low];
            if (phase) |value| {
                if (prior.phase) |old| if (old != value) return error.ResponsesTextConflict;
                prior.phase = value;
            }
            if (id_hash != null) prior.id_hash = id_hash;
            return prior;
        }
        if (self.message_items.items.len >= limits.events) return error.ResourceLimitExceeded;
        try self.message_items.insert(alloc, low, .{ .output_index = output_index, .id_hash = id_hash, .phase = phase });
        return &self.message_items.items[low];
    }

    /// The AI Gateway's SSE classifier differs on purpose: `client.zig` `ErrorEventClass`.
    fn accept_failure(self: *Reducer, alloc: std.mem.Allocator, fields: std.json.ObjectMap) !void {
        self.failure_explained = true;
        const code = stringField(fields, "code") orelse "provider_error";
        const message = stringField(fields, "message") orelse "Provider response failed";
        const bounded_code = types.ModelFailureDiagnostic.init(code);
        const bounded_message = types.ModelFailureDiagnostic.init(message);
        var buffer: [2 * types.ModelFailureDiagnostic.max_bytes + 2]u8 = undefined;
        const text = try std.mem.print(&buffer, "{s}: {s}", .{ bounded_code.view(), bounded_message.view() });
        const detail = types.ModelFailureDiagnostic.init(text);
        self.provider_failure_detail = try alloc.dupe(u8, detail.view());
        self.provider_failure_cause = if (std.mem.eql(u8, code, "server_error"))
            null
        else if (std.mem.eql(u8, code, "rate_limit_exceeded"))
            .rate_limited
        else
            .non_retryable;
    }

    fn accept_text(
        self: *Reducer,
        alloc: std.mem.Allocator,
        update: TextUpdate,
        callbacks: StreamCallbacks,
        capture_limit: ?usize,
        limits: StreamLimits,
    ) !void {
        const message = try self.reconcile_message(alloc, update.key.output_index, update.item_id_hash, null, limits);
        if (self.text_parts.count() >= limits.events and !self.text_parts.contains(update.key)) return error.ResourceLimitExceeded;
        const entry = try self.text_parts.getOrPut(alloc, update.key);
        if (!entry.found_existing) entry.value_ptr.* = .{ .kind = update.kind };
        const part = entry.value_ptr;
        if (part.kind != update.kind) return error.ResponsesTextConflict;
        const suffix = switch (update.mode) {
            .final => try part.final_suffix(update.text),
            .delta => blk: {
                if (part.finalized and update.text.len != 0) return error.ResponsesTextConflict;
                break :blk update.text;
            },
        };
        if (suffix.len != 0) {
            if (self.last_text_key) |last| if (update.key.precedes(last)) return error.ResponsesTextConflict;
            const boundary = if (self.last_text_key) |last| last.output_index != update.key.output_index else false;
            const with_boundary = try checkedAccumulatedSize(self.text_bytes, if (boundary) 2 else 0, limits.aggregate_bytes);
            const total = try checkedAccumulatedSize(with_boundary, suffix.len, limits.aggregate_bytes);
            if (boundary) try appendCaptured(alloc, &self.content, "\n\n", capture_limit);
            const before = self.content.items.len;
            try appendCaptured(alloc, &self.content, suffix, capture_limit);
            if (message.length == 0) message.offset = before;
            message.length += self.content.items.len - before;
            part.digest.update(suffix);
            part.received_bytes += suffix.len; // Bounded by the aggregate total above.
            self.text_bytes = total;
            self.last_text_key = update.key;
            if (boundary) callbacks.on_content(callbacks.context, "\n\n");
        }
        if (update.mode == .final) part.finalized = true;
        if (suffix.len != 0) callbacks.on_content(callbacks.context, suffix);
    }

    fn finalize_text_part(
        self: *Reducer,
        alloc: std.mem.Allocator,
        key: TextKey,
        item_id_hash: ?[TextDigest.digest_length]u8,
        fields: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        capture_limit: ?usize,
        limits: StreamLimits,
    ) !void {
        const kind = stringField(fields, "type") orelse return error.InvalidEvent;
        const refusal = std.mem.eql(u8, kind, "refusal");
        if (!refusal and !std.mem.eql(u8, kind, "output_text")) return;
        try self.accept_text(alloc, .{
            .key = key,
            .kind = if (refusal) .refusal else .text,
            .item_id_hash = item_id_hash,
            .text = stringField(fields, if (refusal) "refusal" else "text") orelse return error.InvalidEvent,
            .mode = .final,
        }, callbacks, capture_limit, limits);
    }

    fn finalize_text_message(
        self: *Reducer,
        alloc: std.mem.Allocator,
        output_index: i64,
        fields: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        cancel_flag: *std.atomic.Value(bool),
        capture_limit: ?usize,
        limits: StreamLimits,
    ) !void {
        _ = try self.reconcile_message(alloc, output_index, try text_identity(fields, "id"), try assistantMessagePhase(fields), limits);
        const parts = fields.get("content") orelse return error.InvalidEvent;
        if (parts != .array) return error.InvalidEvent;
        const identity = try text_identity(fields, "id");
        for (parts.array.items, 0..) |part, content_index| {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (part != .object) return error.InvalidEvent;
            try self.finalize_text_part(alloc, .{
                .output_index = output_index,
                .content_index = std.math.cast(i64, content_index) orelse return error.ResourceLimitExceeded,
            }, identity, part.object, callbacks, capture_limit, limits);
        }
    }

    fn reconcileToolItem(
        self: *Reducer,
        alloc: std.mem.Allocator,
        output_index: i64,
        fields: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        limits: StreamLimits,
    ) !void {
        try self.check_output_kind(output_index, .function_call);
        const index = findTool(self.tools.items, output_index) orelse return error.ResponsesToolCallConflict;
        const tool = &self.tools.items[index];
        try tool.reconcileIdentity(alloc, fields, "id", limits);
        if (fields.get("arguments")) |value| {
            if (value != .string) return error.InvalidEvent;
            try tool.finalizeArguments(alloc, value.string, callbacks, limits);
        }
    }

    pub fn finish(
        self: *Reducer,
        alloc: std.mem.Allocator,
        cancel_flag: *std.atomic.Value(bool),
        limits: StreamLimits,
    ) !types.ModelCompletion {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!self.terminal_seen) return error.StreamIncomplete;

        const owned_content = if (self.content.items.len > 0)
            try self.content.toOwnedSlice(alloc)
        else
            null;
        if (owned_content != null) self.content = .empty;
        errdefer if (owned_content) |value| alloc.free(value);
        const owned_provider_state = state: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var reasoning_index: usize = 0;
            for (self.message_items.items) |message| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                while (reasoning_index < self.reasoning_items.items.len and self.reasoning_items.items[reasoning_index].output_index <= message.output_index) : (reasoning_index += 1) {
                    if (self.reasoning_items.items[reasoning_index].json) |json| try append_replay_item(&out, json, limits.provider_state_bytes);
                }
                if (message.length == 0) continue;
                if (self.message_items.items.len == 1 and message.phase == null) continue;
                var buffer: [160]u8 = undefined;
                try append_replay_item(&out, try message.replay_json(&buffer), limits.provider_state_bytes);
            }
            for (self.reasoning_items.items[reasoning_index..]) |item| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                if (item.json) |json| try append_replay_item(&out, json, limits.provider_state_bytes);
            }
            if (out.written().len == 0) break :state null;
            try out.writer.writeByte(']');
            break :state try out.toOwnedSlice();
        };
        errdefer if (owned_provider_state) |value| alloc.free(value);
        const owned_tools: []types.ToolCall = if (self.tools.items.len > 0)
            try alloc.alloc(types.ToolCall, self.tools.items.len)
        else
            &.{};
        errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
        var initialized: usize = 0;
        errdefer for (owned_tools[0..initialized]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
        };
        for (self.tools.items, 0..) |*tool, index| {
            const arguments = if (tool.arguments_finalized or tool.arguments.items.len > 0)
                try tool.arguments.toOwnedSlice(alloc)
            else
                try alloc.dupe(u8, "{}");
            tool.arguments = .empty;
            owned_tools[index] = .{
                .id = tool.id,
                .name = tool.name,
                .arguments_json = arguments,
            };
            tool.id = &.{};
            tool.name = &.{};
            initialized += 1;
        }
        const generation_id = self.generation_id;
        self.generation_id = null;
        const provider_failure_detail = self.provider_failure_detail;
        self.provider_failure_detail = null;
        return .{
            .content = owned_content,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .provider_failure_detail = provider_failure_detail,
            .provider_failure_cause = self.provider_failure_cause,
            .provider_state_json = owned_provider_state,
            .finish_reason = self.finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
            .usage = self.usage,
        };
    }
};

fn append_replay_item(out: *std.Io.Writer.Allocating, json: []const u8, maximum: usize) !void {
    const item_size = try checkedAccumulatedSize(json.len, 2, maximum);
    _ = try checkedAccumulatedSize(out.written().len, item_size, maximum);
    try out.ensureUnusedCapacity(item_size);
    try out.writer.writeByte(if (out.written().len == 0) '[' else ',');
    try out.writer.writeAll(json);
}

const ToolRecordTest = struct {
    alloc: std.mem.Allocator,
    reducer: Reducer,
    cancelled: std.atomic.Value(bool) = .init(false),
    context: u8 = 0,
    const limits = StreamLimits{ .aggregate_bytes = 64 * 1024, .events = 100, .tool_calls = 4, .tool_identity_bytes = 1024, .tool_arguments_bytes = 4096, .provider_state_bytes = 4096 };
    const start = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"write_file\",\"arguments\":\"\"}}";
    const finalized = "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_1\",\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"preview.txt\\\"}\"}";
    const terminal = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}";

    fn init(alloc: std.mem.Allocator) ToolRecordTest {
        return .{ .alloc = alloc, .reducer = .init(alloc) };
    }

    fn deinit(self: *ToolRecordTest) void {
        self.reducer.deinit(self.alloc);
    }

    fn apply(self: *ToolRecordTest, event: []const u8) !void {
        _ = try self.reducer.applyJson(self.alloc, event, .{ .context = &self.context, .on_content = ignore }, &self.cancelled, null, limits);
    }

    fn finish(self: *ToolRecordTest) !types.ModelCompletion {
        return self.reducer.finish(self.alloc, &self.cancelled, limits);
    }

    fn freeCompletion(self: *ToolRecordTest, completion: types.ModelCompletion) void {
        types.freeToolCallSlice(self.alloc, @constCast(completion.tool_calls));
        if (completion.content) |value| self.alloc.free(value);
        if (completion.provider_state_json) |value| self.alloc.free(value);
        if (completion.generation_id) |value| self.alloc.free(value);
        if (completion.provider_failure_detail) |value| self.alloc.free(value);
    }

    fn ignore(_: *anyopaque, _: []const u8) void {}
};

const TextRecordTest = struct {
    alloc: std.mem.Allocator,
    reducer: Reducer,
    cancelled: std.atomic.Value(bool) = .init(false),
    capture_limit: ?usize = null,
    emitted_bytes: usize = 0,
    emitted_digest: TextDigest = .init(.{}),
    cancel_on_content: bool = false,
    limits: StreamLimits = ToolRecordTest.limits,

    fn init(alloc: std.mem.Allocator) TextRecordTest {
        return .{ .alloc = alloc, .reducer = .init(alloc) };
    }

    fn deinit(self: *TextRecordTest) void {
        self.reducer.deinit(self.alloc);
    }

    fn content(raw: *anyopaque, bytes: []const u8) void {
        const self: *TextRecordTest = @ptrCast(@alignCast(raw));
        self.emitted_bytes += bytes.len;
        self.emitted_digest.update(bytes);
        if (self.cancel_on_content) self.cancelled.store(true, .seq_cst);
    }

    fn apply(self: *TextRecordTest, event: []const u8) !void {
        _ = try self.reducer.applyJson(self.alloc, event, .{ .context = self, .on_content = content }, &self.cancelled, self.capture_limit, self.limits);
    }

    fn json(self: *TextRecordTest, event: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try std.json.Stringify.value(event, .{}, &out.writer);
        try self.apply(out.written());
    }

    fn delta(self: *TextRecordTest, item: i64, part: i64, text: []const u8) !void {
        try self.json(.{ .type = "response.output_text.delta", .output_index = item, .content_index = part, .delta = text });
    }

    fn final(self: *TextRecordTest, item: i64, part: i64, text: []const u8) !void {
        try self.json(.{ .type = "response.output_text.done", .output_index = item, .content_index = part, .text = text });
    }

    fn expect_emitted(self: *const TextRecordTest, expected: []const u8) !void {
        try std.testing.expectEqual(expected.len, self.emitted_bytes);
        var actual = self.emitted_digest;
        var expected_hash: [TextDigest.digest_length]u8 = undefined;
        TextDigest.hash(expected, &expected_hash, .{});
        try std.testing.expectEqual(expected_hash, actual.finalResult());
    }

    fn finish(self: *TextRecordTest, expected: []const u8) !void {
        try self.apply(ToolRecordTest.terminal);
        var result = stream_provider.Result{ .completed = .{
            .completion = try self.reducer.finish(self.alloc, &self.cancelled, self.limits),
            .ownership = .owned,
        } };
        defer result.deinit(self.alloc);
        const limit = self.capture_limit orelse expected.len;
        try std.testing.expectEqualStrings(expected[0..@min(expected.len, limit)], result.completed.completion.content orelse "");
        try self.expect_emitted(expected);
    }
};

fn expectToolFinalizationAllocations(alloc: std.mem.Allocator) !void {
    var stream = ToolRecordTest.init(alloc);
    defer stream.deinit();
    try stream.apply(ToolRecordTest.start);
    try stream.apply("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"discarded preview\"}");
    try stream.apply(ToolRecordTest.finalized);
    try stream.apply("{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"arguments\":\" {\\\"path\\\":\\\"preview.txt\\\"} \"}}");
    try stream.apply("{\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"finished\"}");
    try stream.apply("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}");
    const completion = try stream.finish();
    defer stream.freeCompletion(completion);
    try std.testing.expectEqualStrings("{\"path\":\"preview.txt\"}", completion.tool_calls[0].arguments_json);
}

fn appendTool(
    alloc: std.mem.Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    output_index: i64,
    call_id: []const u8,
    name: []const u8,
    limits: StreamLimits,
) !void {
    if (tools.items.len >= limits.tool_calls or
        call_id.len == 0 or call_id.len > limits.tool_identity_bytes or
        name.len == 0 or name.len > limits.tool_identity_bytes)
    {
        return error.ToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .output_index = output_index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: std.mem.Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
    maximum: usize,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, maximum) catch
        return error.ToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

pub fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.ResourceLimitExceeded;
    if (next > maximum) return error.ResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: std.mem.Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum|
        maximum -| @min(maximum, content.items.len)
    else
        delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, output_index: i64) ?usize {
    for (tools, 0..) |tool, index| if (tool.output_index == output_index) return index;
    return null;
}

const TerminalStatus = enum { completed, incomplete, failed, cancelled };

fn terminal_status(event_type: []const u8, response: std.json.ObjectMap) error{InvalidEvent}!TerminalStatus {
    const expected: ?TerminalStatus = if (std.mem.eql(u8, event_type, "response.completed"))
        .completed
    else if (std.mem.eql(u8, event_type, "response.incomplete"))
        .incomplete
    else if (std.mem.eql(u8, event_type, "response.failed"))
        .failed
    else
        null;
    if (response.get("status")) |value| {
        if (value != .string) return error.InvalidEvent;
        const status = std.meta.stringToEnum(TerminalStatus, value.string) orelse return error.InvalidEvent;
        if (expected) |kind| if (status != kind) return error.InvalidEvent;
        return status;
    }
    if (expected) |kind| return kind;
    if (response.get("error")) |value| if (value != .null) return .failed;
    if (response.get("incomplete_details")) |value| if (value != .null) return .incomplete;
    return .completed;
}

fn finishReason(
    status: TerminalStatus,
    response: std.json.ObjectMap,
    has_tools: bool,
) types.ProviderFinishReason {
    if (status == .completed) return if (has_tools) .tool_calls else .stop;
    if (status == .incomplete) {
        if (response.get("incomplete_details")) |details| if (details == .object) {
            if (stringField(details.object, "reason")) |reason| {
                if (std.mem.eql(u8, reason, "max_output_tokens")) return .length;
                if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
            }
        };
        return .provider_error;
    }
    return .provider_error;
}

fn parseUsage(response: std.json.ObjectMap) types.Usage {
    const value = response.get("usage") orelse return .{};
    if (value != .object) return .{};
    const input_details = value.object.get("input_tokens_details");
    const output_details = value.object.get("output_tokens_details");
    return .{
        .input_tokens = unsignedField(value.object, "input_tokens"),
        .output_tokens = unsignedField(value.object, "output_tokens"),
        .cache_read_tokens = nestedUnsignedField(
            input_details,
            "cached_tokens",
        ),
        .cache_write_tokens = nestedUnsignedField(
            input_details,
            "cache_write_tokens",
        ),
        .reasoning_tokens = nestedUnsignedField(
            output_details,
            "reasoning_tokens",
        ),
    };
}

fn nestedUnsignedField(value: ?std.json.Value, key: []const u8) ?u64 {
    const object = value orelse return null;
    if (object != .object) return null;
    return unsignedField(object.object, key);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

const InputSchema = union(enum) {
    static: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

fn writeFunctionTool(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
) !void {
    if (name.len == 0) return error.InvalidToolSchema;
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (description.len > 0) {
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, description);
    }
    try writer.writeAll(",\"parameters\":");
    switch (input_schema) {
        .static => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
        .dynamic => |schema| {
            if (schema != .object) return error.InvalidToolSchema;
            try std.json.Stringify.value(schema, .{}, writer);
        },
    }
    try writer.writeAll(",\"strict\":false}");
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}
