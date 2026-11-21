const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const json_depth = @import("../shared/json_depth.zig");

pub fn parseToolArgsObject(alloc: std.mem.Allocator, args_json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
    // The returned object map is backed by the parse allocation; callers should
    // use an arena or allocator lifetime that outlives all borrowed values.
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed.value.object;
}

/// Some models send an object argument as JSON text. This reads the text back
/// into the object it names, allocated in `alloc`, and leaves any other value
/// as it is. Text that is not an object, or that nests deeper than tool input
/// may (`json_depth.max_depth`), is error.InvalidCompositeArgument.
pub fn normalizeCompositeObjectValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .object);
}

/// The array counterpart of normalizeCompositeObjectValue.
pub fn normalizeCompositeArrayValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .array);
}

fn normalizeCompositeValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
    kind: std.meta.Tag(std.json.Value),
) !void {
    if (value.* != .string) return;
    // The gateway's depth check doesn't count brackets inside a string, and
    // std.json.Stringify stops at 256 levels, so text that nests deeper than
    // `json_depth.max_depth` is refused before it is read.
    if (json_depth.exceeds(value.string)) return error.InvalidCompositeArgument;
    const decoded = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        value.string,
        .{ .allocate = .alloc_always },
    );
    if (std.meta.activeTag(decoded) != kind) return error.InvalidCompositeArgument;
    value.* = decoded;
}

/// The arguments a call asks with: its `request` wrapper, read from JSON text
/// when the model wrote it as text, or else the arguments themselves. Null
/// when `request` is neither an object nor JSON text of one. Text read from
/// JSON is allocated in `alloc`.
pub fn unwrapRequest(alloc: std.mem.Allocator, args: std.json.ObjectMap) std.mem.Allocator.Error!?std.json.ObjectMap {
    var request = args.get("request") orelse return args;
    normalizeCompositeObjectValue(alloc, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (request) {
        .object => |object| object,
        else => null,
    };
}

pub fn requiredStringArg(args: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = args.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Tool schemas that require every field tell the model to send null for the
/// fields its selected action does not use. Models routinely serialize that null
/// as the literal text "null", so readers treat it as the absence it expresses.
pub fn isNullPlaceholderText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, &std.ascii.whitespace), "null");
}

/// A known field set to an empty string or false asks for nothing, so for an
/// action that does not take the field it means the same as leaving it out.
/// Some models fill every advertised field this way. Any other value can carry
/// intent, so decoders still check it.
pub fn isEmptyArgumentValue(value: std.json.Value) bool {
    return switch (value) {
        .bool => |flag| !flag,
        .string => |text| text.len == 0,
        else => false,
    };
}

/// Reads an optional string argument from a schema whose unused fields arrive as
/// nulls, so textual null placeholders read as absent instead of as a value.
pub fn nullablePlaceholderStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const text = optionalStringArg(args, key) orelse return null;
    if (isNullPlaceholderText(text)) return null;
    return text;
}

pub fn optionalBoolArg(args: std.json.ObjectMap, key: []const u8) ?bool {
    const value = args.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn optionalIntArg(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

/// Reads a built-in tool's JSON arguments. The first problem becomes the
/// failure text the model receives, such as `read_file requires string field
/// "path"`, and the read returns error.InvalidArguments; `takeFailure` hands
/// that text, allocated in `alloc`, to the tool's decode result.
pub const ArgsDecoder = struct {
    alloc: std.mem.Allocator,
    tool: []const u8,
    failure: ?[]u8 = null,

    const Error = std.mem.Allocator.Error || error{InvalidArguments};

    /// The parsed arguments, which must be an object; the caller deinits them.
    /// Any parse error, out of memory included, reads as invalid JSON.
    pub fn parse(self: *ArgsDecoder, args_json: []const u8) Error!std.json.Parsed(std.json.Value) {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, args_json, .{}) catch
            return self.fail("{s} arguments must be valid JSON", .{self.tool});
        errdefer parsed.deinit();
        if (parsed.value != .object) return self.fail("{s} arguments must be an object", .{self.tool});
        return parsed;
    }

    pub fn requiredString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error![]const u8 {
        const value = args.get(key) orelse return self.fail("{s} requires string field \"{s}\"", .{ self.tool, key });
        if (value != .string) return self.stringFailure(key);
        return value.string;
    }

    /// A missing field and JSON null both read as not given.
    pub fn optionalString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
        const value = args.get(key) orelse return null;
        return switch (value) {
            .null => null,
            .string => |text| text,
            else => self.stringFailure(key),
        };
    }

    fn stringFailure(self: *ArgsDecoder, key: []const u8) Error {
        return self.fail("{s} field \"{s}\" must be a string", .{ self.tool, key });
    }

    /// Records the failure text and returns error.InvalidArguments.
    fn fail(self: *ArgsDecoder, comptime fmt: []const u8, args: anytype) Error {
        self.failure = try self.alloc.print(fmt, args);
        return error.InvalidArguments;
    }

    /// The recorded failure text, owned by the caller, for error.InvalidArguments;
    /// an allocation failure stays an error.
    pub fn takeFailure(self: *ArgsDecoder, err: Error) std.mem.Allocator.Error![]u8 {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => {
                const failure = self.failure.?;
                self.failure = null;
                return failure;
            },
        };
    }
};

test "parseToolArgsObject parses object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\"}");

    try std.testing.expectEqualStrings("src/main.zig", args.get("path").?.string);
}

fn nestedText(arena: std.mem.Allocator, opener: []const u8, inner: []const u8, closer: []const u8, levels: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (0..levels) |_| try out.writer.writeAll(opener);
    try out.writer.writeAll(inner);
    for (0..levels) |_| try out.writer.writeAll(closer);
    return out.written();
}

fn expectDecoderFailure(expected: []const u8, comptime read: fn (*ArgsDecoder, std.json.ObjectMap) ArgsDecoder.Error!void, args_json: []const u8) !void {
    const alloc = std.testing.allocator;
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse(args_json) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    defer parsed.deinit();
    read(&decoder, parsed.value.object) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        try std.testing.expectEqual(null, decoder.failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    return error.TestExpectedFailure;
}

fn readNothing(_: *ArgsDecoder, _: std.json.ObjectMap) ArgsDecoder.Error!void {
    return error.InvalidArguments;
}

fn readRequiredPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.requiredString(args, "path");
}

fn readOptionalPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.optionalString(args, "path");
}

fn decodeRequiredPathAllocation(alloc: std.mem.Allocator) !void {
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse("{\"path\":3}") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    defer parsed.deinit();
    _ = decoder.requiredString(parsed.value.object, "path") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    return error.TestExpectedFailure;
}
