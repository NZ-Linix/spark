//! Request headers for Streamable HTTP (2026): the headers that mirror the
//! body, `x-mcp-header` checks and
//! mirroring, and value encoding. Pure: the caller passes
//! an allocator for the header values, normally a per-request arena.

const std = @import("std");
const wire = @import("wire.zig");

pub const Header = std.http.Header;

/// Most `x-mcp-header` annotations in one tool, and the deepest property path.
pub const max_annotations = 32;
pub const max_depth = 8;

/// Whether every byte is printable ASCII, 0x20..0x7E, as a header value can
/// hold it unchanged.
pub fn printable(value: []const u8) bool {
    for (value) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

/// Whether every header can go out as it is: a name of token characters
/// (RFC 9110 §5.6.2) and a value with no control character but tab (§5.5).
/// A line break would split the header, and `std.http` asserts on CR LF.
pub fn sendable(headers: []const Header) bool {
    for (headers) |h| {
        if (h.name.len == 0) return false;
        for (h.name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
        for (h.value) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
    }
    return true;
}

/// Whether a header value must be sent base64-wrapped: any byte
/// outside 0x20..0x7E, tab included, a leading or trailing space, or a
/// value that already looks wrapped.
pub fn needsEncoding(value: []const u8) bool {
    if (!printable(value)) return true;
    if (value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) return true;
    return std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=");
}

/// `value`, or its `=?base64?...?=` form when it can't be sent as is.
pub fn encodeValue(gpa: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!needsEncoding(value)) return value;
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, "=?base64?".len + encoder.calcSize(value.len) + "?=".len);
    @memcpy(out[0..9], "=?base64?");
    _ = encoder.encode(out[9 .. out.len - 2], value);
    @memcpy(out[out.len - 2 ..], "?=");
    return out;
}

pub const Kind = enum { string, integer, boolean };

/// One `x-mcp-header` annotation: the header name part, and the chain of
/// `properties` keys leading to the annotated property. Slices of the schema.
pub const Annotation = struct {
    name: []const u8,
    path: [max_depth][]const u8 = undefined,
    depth: u8 = 0,
    kind: Kind,
};

pub const Invalid = error{
    /// Empty, not an HTTP token, or written with escapes.
    NotToken,
    /// Two annotations differ only in case.
    Duplicate,
    /// On a property that isn't a string, integer, or boolean.
    NotPrimitive,
    /// Anywhere but on a property reached through `properties` keys alone.
    NotReachable,
    /// More annotations or deeper paths than this client handles.
    TooMany,
    /// The schema isn't valid JSON.
    Malformed,
};

/// RFC 9110 tchar.
fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

const Frame = struct {
    /// An object that is a schema reached through `properties` keys alone
    /// (or the root schema itself).
    reachable: bool,
    /// An object that is the value of a reachable schema's `properties`.
    properties: bool,
    /// A reachable property schema, not the root.
    property: bool,
    is_array: bool,
    key: ?[]const u8 = null,
    header: ?[]const u8 = null,
    type: ?[]const u8 = null,
    depth: u8,
};

/// Finds every `x-mcp-header` annotation in a tool's `inputSchema` and checks
/// it. Returns how many it stored in `out`; any invalid annotation
/// makes the whole tool invalid.
pub fn annotations(schema: []const u8, out: *[max_annotations]Annotation) Invalid!usize {
    var stack_bytes: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack_bytes);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), schema);
    var frames: [64]Frame = undefined;
    var top: usize = 0;
    var path: [max_depth][]const u8 = undefined;
    var count: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.Malformed;
        switch (token) {
            .object_begin, .array_begin => {
                if (top == frames.len) return error.Malformed;
                var frame: Frame = .{ .reachable = false, .properties = false, .property = false, .is_array = token == .array_begin, .depth = 0 };
                if (top == 0) {
                    frame.reachable = !frame.is_array;
                } else {
                    const parent = &frames[top - 1];
                    frame.depth = parent.depth;
                    if (!frame.is_array and !parent.is_array) {
                        const key = parent.key orelse "";
                        if (parent.properties) {
                            if (parent.depth == max_depth) return error.TooMany;
                            path[parent.depth] = key;
                            frame.depth = parent.depth + 1;
                            frame.reachable = true;
                            frame.property = true;
                        } else if (parent.reachable and std.mem.eql(u8, key, "properties")) {
                            frame.properties = true;
                        }
                    }
                    parent.key = null;
                }
                frames[top] = frame;
                top += 1;
            },
            .object_end, .array_end => {
                top -= 1;
                const frame = frames[top];
                if (frame.header) |name| {
                    if (!frame.property) return error.NotReachable;
                    const kind: Kind = if (std.mem.eql(u8, frame.type orelse "", "string"))
                        .string
                    else if (std.mem.eql(u8, frame.type orelse "", "integer"))
                        .integer
                    else if (std.mem.eql(u8, frame.type orelse "", "boolean"))
                        .boolean
                    else
                        return error.NotPrimitive;
                    for (out[0..count]) |other| if (std.ascii.eqlIgnoreCase(other.name, name)) return error.Duplicate;
                    if (count == max_annotations) return error.TooMany;
                    out[count] = .{ .name = name, .depth = frame.depth, .kind = kind };
                    @memcpy(out[count].path[0..frame.depth], path[0..frame.depth]);
                    count += 1;
                }
                if (top == 0) {
                    if ((scanner.next() catch return error.Malformed) != .end_of_document) return error.Malformed;
                    return count;
                }
            },
            .string, .number, .true, .false, .null, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .partial_number => {
                if (top == 0) return error.Malformed;
                const frame = &frames[top - 1];
                // A key written with escapes arrives in pieces; it matches nothing.
                const whole = token == .string or token == .number or token == .true or token == .false or token == .null;
                if (!frame.is_array and frame.key == null) {
                    frame.key = if (token == .string) token.string else "";
                    if (!whole) try skipRest(&scanner);
                    continue;
                }
                const key = frame.key orelse "";
                frame.key = null;
                if (std.mem.eql(u8, key, "x-mcp-header")) {
                    if (token != .string) return error.NotToken;
                    const name = token.string;
                    if (name.len == 0) return error.NotToken;
                    for (name) |c| if (!isTokenChar(c)) return error.NotToken;
                    frame.header = name;
                } else if (std.mem.eql(u8, key, "type") and token == .string) {
                    frame.type = token.string;
                }
                if (!whole) {
                    // An escaped x-mcp-header value is never a valid token.
                    if (std.mem.eql(u8, key, "x-mcp-header")) return error.NotToken;
                    try skipRest(&scanner);
                }
            },
            .end_of_document => return error.Malformed,
            else => return error.Malformed,
        }
    }
}

/// Skips the remaining pieces of a string or number the scanner splits.
fn skipRest(scanner: *std.json.Scanner) Invalid!void {
    while (true) switch (scanner.next() catch return error.Malformed) {
        .string, .number => return,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .partial_number => {},
        else => return error.Malformed,
    };
}

/// The `Mcp-Param-*` headers for a tool call: each annotated
/// argument's value at its exact path, encoded. Absent and null
/// values are omitted, and so are objects and arrays, which no annotation
/// may name. Appends to `out`; values are allocated with `gpa`.
pub fn paramHeaders(
    gpa: std.mem.Allocator,
    found: []const Annotation,
    arguments: []const u8,
    out: *std.ArrayList(Header),
) (std.mem.Allocator.Error || wire.DecodeError)!void {
    for (found) |a| {
        var level = arguments;
        var value: ?[]const u8 = level;
        for (a.path[0..a.depth]) |key| {
            var field: [1]?[]const u8 = undefined;
            wire.objectFields(level, &.{key}, &field) catch {
                value = null;
                break;
            };
            value = field[0];
            level = value orelse break;
        }
        const raw = value orelse continue;
        const text: []const u8 = switch (raw[0]) {
            '"' => try decodeString(gpa, raw),
            't', 'f', '-', '0'...'9' => raw,
            else => continue,
        };
        try out.append(gpa, .{
            .name = try std.mem.concat(gpa, u8, &.{ "Mcp-Param-", a.name }),
            .value = try encodeValue(gpa, text),
        });
    }
}

/// The text of a raw JSON string, with escapes decoded.
fn decodeString(gpa: std.mem.Allocator, raw: []const u8) (std.mem.Allocator.Error || wire.DecodeError)![]const u8 {
    if (wire.plainString(raw)) |plain| return plain;
    var scanner: std.json.Scanner = .initCompleteInput(gpa, raw);
    defer scanner.deinit();
    const token = scanner.nextAlloc(gpa, .alloc_always) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    return switch (token) {
        .allocated_string => |s| s,
        else => error.InvalidJson,
    };
}

const post_accept = "application/json, text/event-stream";

/// What a 2025 request carries: `Accept` with both types for a POST and only
/// SSE for a GET, the agreed `MCP-Protocol-Version` once
/// initialize was answered, the session id, and, to
/// resume a stream, `Last-Event-ID`. Appends to `out`.
pub fn sessionHeaders(
    gpa: std.mem.Allocator,
    get: bool,
    version: ?[]const u8,
    session: ?[]const u8,
    last_event_id: ?[]const u8,
    out: *std.ArrayList(Header),
) std.mem.Allocator.Error!void {
    try out.append(gpa, .{ .name = "Accept", .value = if (get) "text/event-stream" else post_accept });
    if (version) |v| try out.append(gpa, .{ .name = "MCP-Protocol-Version", .value = v });
    if (session) |id| try out.append(gpa, .{ .name = "Mcp-Session-Id", .value = id });
    if (last_event_id) |id| try out.append(gpa, .{ .name = "Last-Event-ID", .value = id });
}

/// A session id the client will echo: visible ASCII only, as the spec
/// requires of servers, and at most 1 KiB.
pub fn validSessionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

/// An event id the client can send back as `Last-Event-ID`: printable ASCII
/// and at most 1 KiB. A stream with any other id isn't resumable.
pub fn validEventId(value: []const u8) bool {
    return value.len != 0 and value.len <= 1024 and printable(value);
}

/// The headers every POST carries: `Accept`,
/// `MCP-Protocol-Version`, `Mcp-Method`, and, for a tool call, `Mcp-Name`.
/// Then the `extra` headers the host configured. Appends to `out`.
pub fn requestHeaders(
    gpa: std.mem.Allocator,
    version: []const u8,
    method: []const u8,
    name: ?[]const u8,
    extra: []const Header,
    out: *std.ArrayList(Header),
) std.mem.Allocator.Error!void {
    try out.appendSlice(gpa, &.{
        .{ .name = "Accept", .value = post_accept },
        .{ .name = "MCP-Protocol-Version", .value = version },
        .{ .name = "Mcp-Method", .value = method },
    });
    if (name) |n| try out.append(gpa, .{ .name = "Mcp-Name", .value = try encodeValue(gpa, n) });
    try out.appendSlice(gpa, extra);
}

const testing = std.testing;

test "a header goes out only if HTTP can carry it as it is" {
    try testing.expect(sendable(&.{ .{ .name = "Authorization", .value = "Bearer abc" }, .{ .name = "X-Team", .value = "a b\tc \xc3\xa9" } }));
    for ([_][]const u8{ "a\r\nb", "a\nInjected: yes", "a\rb", "a\x00b", "a\x7fb" }) |value| {
        try testing.expect(!sendable(&.{.{ .name = "X-Team", .value = value }}));
    }
    for ([_][]const u8{ "", "X Team", "X:Team", "X\nTeam" }) |name| {
        try testing.expect(!sendable(&.{.{ .name = name, .value = "v" }}));
    }
}

fn checked(schema: []const u8) Invalid!usize {
    var out: [max_annotations]Annotation = undefined;
    return annotations(schema, &out);
}
