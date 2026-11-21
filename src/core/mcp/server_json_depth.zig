//! The depth limit on a server's JSON, where the host turns it into a value.
//!
//! The engine hands the host a message up to about 2,580 levels deep. Writers then write that value, or
//! a part of it, again with `std.json.Stringify`, which keeps its nesting in a fixed stack of 256 levels
//! in a safe build (Debug and ReleaseSafe) and aborts past it. So each place that reads a server's JSON
//! into a value checks it with `require` first: a tool call's result and an error's data
//! (`features/tools.zig`), a listed tool (`features/tools.zig`) and an elicitation form
//! (`elicitation.zig`). There is no per-writer limit.
//!
//! This is not `../shared/json_depth.zig`, which limits the raw text of a provider's JSON to 64 levels
//! before it is parsed. This file limits a parsed value from an MCP server to 128 levels.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");

/// The deepest value spark accepts from a server: 128 levels of arrays and objects, where `{}` is one level.
/// `std.json.Stringify` holds 256 levels, and a writer wraps the value it writes in at most 4 more
/// (headroom: none adds more than 2, `bridgeResultData`'s envelope), so 128 leaves room.
/// `tests/tla/mcp/WireDepth.tla` `NoWriterOverflow`: whatever an entry point accepts, every writer behind
/// it can write. Change this limit only with that model's `Limit` and `Capacity`.
pub const max_server_json_depth: usize = 128;

/// Where a value too deep was met, as the trace names it.
const Place = enum { result, tool, form, data };

const Frame = union(enum) {
    array: struct { items: []const std.json.Value, next: usize },
    object: std.json.ObjectMap.Iterator,
};

/// Whether `value` is at most `max` levels deep. The walk keeps its own stack of at most
/// `max_server_json_depth` frames, never recurses, and stops at the first level past `max`, so a value
/// nested a hundred thousand levels deep costs no more than one nested 129.
pub fn within(value: std.json.Value, max: usize) bool {
    std.debug.assert(max <= max_server_json_depth);
    var stack: [max_server_json_depth]Frame = undefined;
    var len: usize = 0;
    var pending: ?std.json.Value = value;
    while (true) {
        if (pending) |entered| {
            pending = null;
            switch (entered) {
                .array => |array| {
                    if (len == max) return false;
                    stack[len] = .{ .array = .{ .items = array.items, .next = 0 } };
                    len += 1;
                },
                .object => |object| {
                    if (len == max) return false;
                    stack[len] = .{ .object = object.iterator() };
                    len += 1;
                },
                else => {},
            }
        }
        if (len == 0) return true;
        switch (stack[len - 1]) {
            .array => |*frame| {
                if (frame.next < frame.items.len) {
                    pending = frame.items[frame.next];
                    frame.next += 1;
                } else len -= 1;
            },
            .object => |*iterator| {
                if (iterator.next()) |entry| pending = entry.value_ptr.* else len -= 1;
            },
        }
    }
}

/// Writes the trace line for a value refused past the limit: the code, the limit and the place, and
/// nothing the server sent.
pub fn traceRefused(place: Place) void {
    debug_trace.logf("mcp", "MCP server JSON refused code=NestingTooDeep limit={d} at={t}", .{ max_server_json_depth, place });
}

/// `value` as it is, or `error.NestingTooDeep` with its trace line.
pub fn require(value: std.json.Value, place: Place) error{NestingTooDeep}!void {
    if (within(value, max_server_json_depth)) return;
    traceRefused(place);
    return error.NestingTooDeep;
}

const depth_testing = @import("server_json_depth_testing.zig");

test "a scalar is no level, and an empty array or object is one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(within(.{ .integer = 1 }, 0));
    try std.testing.expect(within(.null, 0));
    try std.testing.expect(within(.{ .string = "[[[[[[[[[[" }, 0));
    try std.testing.expect(!within(try depth_testing.value(arena, 1, .arrays), 0));
    try std.testing.expect(within(try depth_testing.value(arena, 1, .arrays), 1));
    try std.testing.expect(within(.{ .object = .empty }, 1));
    try std.testing.expect(!within(.{ .object = .empty }, 0));
}
