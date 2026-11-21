//! Request fields a custom model connection's settings add to a request body
//! (`configured_provider.zig`): a model's own `request` fields and the fields
//! of each effort level it declares. A fragment is a JSON object whose keys
//! go into the top level of the body. spark keeps the fields it writes itself,
//! so a fragment that names one fails when settings load
//! (`tests/tla/configured_provider/ConfiguredRequest.tla` OwnedKeysKeepFxValue).
//!
//! Imports only the standard library.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_fields = 32;
pub const max_key_bytes = 128;
/// The serialized size of one fragment.
pub const max_bytes = 16 * 1024;
pub const max_depth = 16;

pub const Error = Allocator.Error || error{
    /// Not an object, an empty key, or a value nested too deeply.
    InvalidRequestFields,
    /// A key spark writes itself.
    ReservedRequestField,
    LimitExceeded,
};

pub const Field = struct {
    key: []const u8,
    /// The value as JSON text.
    value_json: []const u8,
};

pub const Fragment = struct {
    fields: []const Field = &.{},

    pub fn has(self: Fragment, key: []const u8) bool {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.key, key)) return true;
        }
        return false;
    }
};

/// Copies `value` into `alloc`, which owns the result: the caller frees it by
/// freeing each key and value and then the field list, or by using an arena.
/// `reserved` lists the fields spark writes for the connection's protocol.
pub fn parse(alloc: Allocator, value: std.json.Value, reserved: []const []const u8) Error!Fragment {
    return parseReporting(alloc, value, reserved, null);
}

/// `parse`, setting `refused` to the key that made it fail when a key did, so
/// the person can be told which one. The key borrows `value`.
pub fn parseReporting(alloc: Allocator, value: std.json.Value, reserved: []const []const u8, refused: ?*?[]const u8) Error!Fragment {
    if (value != .object) return error.InvalidRequestFields;
    if (value.object.count() > max_fields) return error.LimitExceeded;
    const fields = try alloc.alloc(Field, value.object.count());
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |field| {
            alloc.free(field.key);
            alloc.free(field.value_json);
        }
        alloc.free(fields);
    }
    var total: usize = 0;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (refused) |slot| slot.* = key;
        if (key.len == 0) return error.InvalidRequestFields;
        if (key.len > max_key_bytes) return error.LimitExceeded;
        for (reserved) |name| {
            if (std.mem.eql(u8, key, name)) return error.ReservedRequestField;
        }
        if (!withinDepth(entry.value_ptr.*, max_depth)) return error.InvalidRequestFields;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer) catch return error.OutOfMemory;
        total += key.len + out.written().len;
        if (total > max_bytes) return error.LimitExceeded;
        const owned_key = try alloc.dupe(u8, key);
        errdefer alloc.free(owned_key);
        fields[initialized] = .{ .key = owned_key, .value_json = try out.toOwnedSlice() };
        initialized += 1;
        if (refused) |slot| slot.* = null;
    }
    return .{ .fields = fields };
}

fn withinDepth(value: std.json.Value, remaining: usize) bool {
    switch (value) {
        .object => |object| {
            if (remaining == 0) return false;
            for (object.values()) |child| {
                if (!withinDepth(child, remaining - 1)) return false;
            }
        },
        .array => |array| {
            if (remaining == 0) return false;
            for (array.items) |child| {
                if (!withinDepth(child, remaining - 1)) return false;
            }
        },
        .null, .bool, .integer, .float, .number_string, .string => {},
    }
    return true;
}

/// Writes `,"key":value` for every field: the model's own request fields
/// first, then the chosen level's. A field both set goes out once, with the
/// level's value (`tests/tla/configured_provider/ConfiguredRequest.tla`
/// LevelBeatsRequest).
pub fn write(writer: *std.Io.Writer, request: Fragment, level: Fragment) std.Io.Writer.Error!void {
    for (request.fields) |field| {
        if (!level.has(field.key)) try writeField(writer, field);
    }
    for (level.fields) |field| try writeField(writer, field);
}

fn writeField(writer: *std.Io.Writer, field: Field) std.Io.Writer.Error!void {
    try writer.writeByte(',');
    try std.json.Stringify.value(field.key, .{}, writer);
    try writer.writeByte(':');
    try writer.writeAll(field.value_json);
}

/// `std.testing.allocator` without in-place resizing, so the allocation
/// sequence repeats (`src/core/shared/testing_allocator.zig`, which this
/// file cannot import).
const no_resize: Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = testAlloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = testFree },
};

fn testAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn testFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}

fn testParse(arena: Allocator, json: []const u8, reserved: []const []const u8) !Fragment {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return parse(arena, value, reserved);
}

fn testBody(arena: Allocator, request: Fragment, level: Fragment) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"model\":\"m\"");
    try write(&out.writer, request, level);
    try out.writer.writeByte('}');
    return out.written();
}

fn testParseAllocations(alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":{\"b\":[1,2]},\"c\":\"d\",\"model\":1}", .{});
    defer parsed.deinit();
    // The reserved key comes last, after two fields were copied.
    if (parse(alloc, parsed.value, &.{"model"})) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ReservedRequestField => {},
        else => return err,
    }
    const fragment = try parse(alloc, parsed.value, &.{});
    for (fragment.fields) |field| {
        alloc.free(field.key);
        alloc.free(field.value_json);
    }
    alloc.free(fragment.fields);
}
