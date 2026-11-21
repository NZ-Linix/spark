const std = @import("std");
const result_store = @import("../../core/session/result_store.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const io_mod = @import("../../core/shared/io.zig");
const json_depth = @import("../../core/shared/json_depth.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const compactor = @import("../../core/compactor/compactor.zig");
const read_result_presentation = @import("../../core/tooling/read_tool_result_presentation.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    handle: []u8,
    selector: union(enum) {
        range: struct {
            start_byte: usize = 1,
            byte_count: usize = result_store.read_default_bytes,
        },
        query: []u8,
        /// Searches every turn, tool call and earlier compaction saved by
        /// context compaction.
        search: [][]u8,
    } = .{ .range = .{} },

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.handle);
        switch (self.selector) {
            .range => {},
            .query => |query| alloc.free(query),
            .search => |phrases| {
                for (phrases) |phrase| alloc.free(phrase);
                alloc.free(phrases);
            },
        }
        self.* = .{ .handle = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var decoder: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "read_tool_result" };
    var parsed = decoder.parse(args_json) catch |err| return .{ .failure = try decoder.takeFailure(err) };
    defer parsed.deinit();
    // The row reads the request the same way (read_tool_result_presentation.zig).
    const args = (try tool_args.unwrapRequest(parsed.arena.allocator(), parsed.value.object)) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"request\" must be an object") };
    };
    if (args.get("search")) |value| {
        // search reads saved history and ignores a handle, so a call that
        // sends both meant to look inside the handle's output.
        if (args.get("handle")) |handle| if (handle != .null) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result: search finds saved turns and takes no handle; to find text in this handle's output, pass query instead") };
        };
        return decodeSearch(ctx.allocator, value);
    }
    const handle = decoder.requiredString(args, "handle") catch |err| return .{ .failure = try decoder.takeFailure(err) };

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .handle = try ctx.allocator.dupe(u8, handle) };
    errdefer input.deinit(ctx.allocator);

    if (args.get("start_byte")) |value| {
        const start_byte = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"start_byte\" must be a positive integer") };
        };
        input.selector.range.start_byte = @intCast(start_byte);
    }
    if (args.get("byte_count")) |value| {
        const byte_count = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"byte_count\" must be a positive integer") };
        };
        input.selector.range.byte_count = @intCast(@min(byte_count, result_store.read_max_bytes));
    }
    if (args.get("query")) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"query\" must be a string") };
        }
        if (value.string.len > 0) {
            input.selector = .{ .query = try ctx.allocator.dupe(u8, value.string) };
        }
    }

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn decodeSearch(alloc: Allocator, value: std.json.Value) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const invalid = std.fmt.comptimePrint("read_tool_result field \"search\" must be 1 to {d} non-empty strings", .{compactor.max_search_phrases});
    const items: []const std.json.Value = switch (value) {
        .string => (&value)[0..1],
        .array => |array| array.items,
        else => return .{ .failure = try alloc.dupe(u8, invalid) },
    };
    if (items.len == 0 or items.len > compactor.max_search_phrases) return .{ .failure = try alloc.dupe(u8, invalid) };
    for (items) |item| {
        if (item != .string or std.mem.trim(u8, item.string, " \t\r\n").len == 0) return .{ .failure = try alloc.dupe(u8, invalid) };
    }
    const input = try alloc.create(Input);
    errdefer alloc.destroy(input);
    input.* = .{ .handle = &.{} };
    const phrases = try alloc.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (phrases[0..copied]) |phrase| alloc.free(phrase);
        alloc.free(phrases);
    }
    for (items, phrases) |item, *phrase| {
        phrase.* = try alloc.dupe(u8, item.string);
        copied += 1;
    }
    input.selector = .{ .search = phrases };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn parsePositiveInteger(value: std.json.Value) ?i64 {
    if (value != .integer or value.integer < 1) return null;
    return value.integer;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.selector == .search) return null;
    const normalization = read_result_presentation.classifyHandleNormalization(input.handle);
    if (normalization.trimmed.len == 0) return try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must not be empty");
    var record_buffer: compactor.RecordFileBuffer = undefined;
    if (compactor.recordFile(&record_buffer, normalization.trimmed)) |file| {
        // A turn, tool call or earlier compaction saved by compaction, opened
        // by its ID (M12, T12, L2).
        const owned = try ctx.allocator.dupe(u8, file);
        ctx.allocator.free(input.handle);
        input.handle = owned;
        return null;
    }
    if (normalization.suffix.len > 0 or !std.mem.eql(u8, input.handle, normalization.trimmed)) {
        const owned = try std.mem.concat(ctx.allocator, u8, &.{ normalization.trimmed, normalization.suffix });
        ctx.allocator.free(input.handle);
        input.handle = owned;
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.selector == .search) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "Nothing is saved: this session has no tool-result store."),
        };
        const queries: []const []const u8 = input.selector.search;
        const output = compactor.search(ctx.allocator, result_store.compactorStore(capability), queries) catch |err| return .{
            .failure = try ctx.allocator.print("Searching saved turns, tool calls and earlier compactions failed: {s}", .{@errorName(err)}),
        };
        return .{ .success = output };
    }
    if (result_store.isImageHandle(input.handle)) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "No active session image store is available."),
        };
        if (input.selector == .query or input.selector.range.start_byte != 1) return .{
            .failure = try ctx.allocator.dupe(u8, "Stored images are read as complete images. Use the handle without a query or byte offset."),
        };
        const images = result_store.loadToolImages(ctx.allocator, capability, input.handle) catch |err| return .{
            .failure = try formatReadFailure(ctx.allocator, input.handle, err),
        };
        errdefer @import("../../core/shared/types.zig").freeToolImages(ctx.allocator, images);
        return .{ .rich = .{
            .text = try ctx.allocator.dupe(u8, "Stored tool images attached to this result. They are sent to the model with your next request when this model accepts image input; when they cannot be sent, that request notes why and what to do instead."),
            .images = images,
            .is_error = false,
        } };
    }
    if (ctx.session_child_capability == null and
        ctx.ephemeral_command_replay == null and
        ctx.tool_result_dir == null)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "No active session tool-result store is available.") };
    }

    const output = readOutput(ctx, input) catch |err| {
        return .{ .failure = try formatReadFailure(ctx.allocator, input.handle, err) };
    };
    return .{ .success = output };
}

fn readOutput(ctx: tool_dispatch.DispatchContext, input: *Input) ![]u8 {
    if (ctx.session_child_capability) |capability| {
        const ordinary = switch (input.selector) {
            .query => |query| result_store.searchByQueryManaged(ctx.allocator, capability, input.handle, query),
            .range => |range| result_store.readByRangeManaged(ctx.allocator, capability, input.handle, range.start_byte, range.byte_count),
            .search => unreachable,
        };
        return ordinary catch |err| switch (err) {
            error.ResultHandleNotFound => switch (input.selector) {
                .query => |query| command_replay_store.searchAgentQueryManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    query,
                    result_store.read_max_bytes,
                ),
                .range => |range| command_replay_store.readAgentPageManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    range.start_byte,
                    range.byte_count,
                ),
                .search => unreachable,
            },
            else => return err,
        };
    }

    if (ctx.ephemeral_command_replay) |store| {
        return switch (input.selector) {
            .query => |query| command_replay_store.searchAgentQueryEphemeral(
                ctx.allocator,
                store,
                input.handle,
                query,
                result_store.read_max_bytes,
            ),
            .range => |range| command_replay_store.readAgentPageEphemeral(
                ctx.allocator,
                store,
                input.handle,
                range.start_byte,
                range.byte_count,
            ),
            .search => unreachable,
        };
    }

    const dir = ctx.tool_result_dir.?;
    return switch (input.selector) {
        .query => |query| result_store.searchByQuery(ctx.allocator, dir, input.handle, query),
        .range => |range| result_store.readByRange(ctx.allocator, dir, input.handle, range.start_byte, range.byte_count),
        .search => unreachable,
    };
}

fn formatReadFailure(alloc: Allocator, handle: []const u8, err: anyerror) ![]u8 {
    if (err == error.ResultHandleNotFound) {
        return alloc.print(
            "read_tool_result failed for handle {s}: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.",
            .{handle},
        );
    }
    return alloc.print("read_tool_result failed for handle {s}: {s}", .{ handle, @errorName(err) });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Labels each call by what it reads. See `read_tool_result_presentation.zig`.
pub const presentation = read_result_presentation.presentation;

test "read_tool_result decodes range and query inputs" {
    const alloc = std.testing.allocator;
    const decoded_range = try decode(.{ .allocator = alloc }, "{\"handle\":\"h.txt\",\"start_byte\":2,\"byte_count\":9}");
    const range_input = switch (decoded_range) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer range_input.deinit(alloc);
    const typed_range = range_input.as(Input);
    switch (typed_range.selector) {
        .range => |range| {
            try std.testing.expectEqual(@as(usize, 2), range.start_byte);
            try std.testing.expectEqual(@as(usize, 9), range.byte_count);
        },
        .query => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }

    const decoded_query = try decode(.{ .allocator = alloc }, "{\"handle\":\"h.txt\",\"query\":\"needle\"}");
    const query_input = switch (decoded_query) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer query_input.deinit(alloc);
    const typed_query = query_input.as(Input);
    try std.testing.expectEqualStrings("h.txt", typed_query.handle);
    switch (typed_query.selector) {
        .query => |query| try std.testing.expectEqualStrings("needle", query),
        .range => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }
}

const request_refusal = "read_tool_result field \"request\" must be an object";

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqualStrings(expected, failure);
        },
    }
}

const max_fuzz_request_text_bytes: usize = 16 * 1024;

fn fuzzRequestText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_request_text_bytes + 1]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];
    // Text that is not UTF-8 fails the argument parse before request is read.
    if (!std.unicode.utf8ValidateSlice(text)) return;

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args_json = try std.json.Stringify.valueAlloc(arena, .{ .request = text }, .{});
    const args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{})).object;
    const request = try tool_args.unwrapRequest(arena, args);

    // decode refuses the request exactly when the row finds no object in it.
    switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |input| {
            input.deinit(alloc);
            try std.testing.expect(request != null);
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqual(request == null, std.mem.eql(u8, failure, request_refusal));
        },
    }

    // The row reads the text in place, whatever its length, and gives it the
    // label of the object a full parse finds in it. Its two differences are
    // here. A parse refuses a text that repeats a field, at any depth, but the
    // row sees only a repeat of a field it reads. And a handle written with
    // escapes that decodes to more than the row has room for keeps the tool's
    // default label.
    const from_text = presentation(args);
    const object = request orelse {
        if (from_text != null) try expectRefusedOnlyForRepeatedField(arena, text);
        return;
    };
    const object_json = try std.json.Stringify.valueAlloc(arena, .{ .request = std.json.Value{ .object = object } }, .{});
    const object_args = (try std.json.parseFromSliceLeaky(std.json.Value, arena, object_json, .{})).object;
    const from_object = presentation(object_args);
    const label = from_text orelse {
        if (from_object != null) {
            try std.testing.expect(object.get("search") == null);
            const handle = object.get("handle") orelse return error.TestExpectedHandle;
            try std.testing.expect(handle == .string);
            try std.testing.expect(handle.string.len > read_result_presentation.max_escaped_handle_bytes);
            try std.testing.expect(std.mem.findScalar(u8, text, '\\') != null);
        }
        return;
    };
    const expected = from_object orelse return error.TestRowNamesWhatTheObjectDoesNot;
    try std.testing.expectEqual(expected.activity_kind, label.activity_kind);
    try std.testing.expectEqualStrings(expected.action_label, label.action_label);
    try std.testing.expectEqualStrings(expected.completed_action_label, label.completed_action_label);
    try std.testing.expectEqualStrings(expected.label_arg_default, label.label_arg_default);
}

/// The text a parse refuses and the row names anyway: a parse of it fails only
/// on a field that repeats.
fn expectRefusedOnlyForRepeatedField(arena: Allocator, text: []const u8) !void {
    try std.testing.expect(!json_depth.exceeds(text));
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always });
    if (parsed) |_| return error.TestParseAcceptedTheText else |err| {
        if (err != error.DuplicateField) return error.TestParseFailedForAnotherReason;
    }
}
