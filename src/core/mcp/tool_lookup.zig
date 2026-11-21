//! What `spark mcp call list`, `search`, and `help` print: plain text for a
//! shell command, made from the same search pages and tool schemas the agent's
//! own toolbox search uses (`tool_search.zig`, `selected_schema.zig`).
//!
//! The pages and schemas carry server text encoded for the model
//! (`model_context_encoding.writeScalar`), so it is decoded first. It comes
//! from MCP servers, so it is then written the way spark shows any outside text
//! on a terminal (`text_utils.encodeTerminalSafeInline`: control bytes and
//! non-printing characters become visible escapes), and every part is
//! bounded. Pure: it formats bytes it is given.
const std = @import("std");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("../tooling/tool_args.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The longest tool name `list`, `search`, and `help` print.
const max_name_bytes = 256;
/// The longest reason `list` or `search` gives for finding no tools.
const max_problem_bytes = 1024;
/// The longest description on a `list` or `search` line.
pub const max_line_description_bytes = 160;
/// The longest tool description `help` prints.
pub const max_help_description_bytes = 2000;
/// The longest argument description `help` prints.
const max_argument_description_bytes = 200;
/// The most top-level arguments `help` lists, and the widest its name column gets.
const max_arguments = 64;
const max_name_column = 40;
/// How deep `help` spells out nested objects, and how many of their keys.
const max_type_depth = 3;
const max_inline_keys = 12;
/// The most choices `help` lists for one enum or union.
const max_choices = 12;
/// The longest literal `help` prints for a `const` or an enum choice.
const max_literal_bytes = 40;

pub const Page = struct {
    /// Tools on this page.
    tools: usize,
    /// Where the next page starts, or null on the last page.
    next_cursor: ?[]const u8,
    /// Why the page holds no tools, when the search said: a server that needs
    /// a login, failed, or does not exist.
    problem: ?[]const u8,
};

pub const PageError = error{ InvalidSearchPage, OutOfMemory, WriteFailed };

/// Writes one `NAME<TAB>DESCRIPTION` line per tool on a search page and says
/// where the next page starts. Slices in the result borrow from `arena`.
pub fn writeToolLines(arena: Allocator, out: *Writer, page_json: []const u8) PageError!Page {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, page_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSearchPage,
    };
    if (value != .object) return error.InvalidSearchPage;
    const page = value.object;
    const tools = page.get("tools") orelse return error.InvalidSearchPage;
    if (tools != .array) return error.InvalidSearchPage;
    var written: usize = 0;
    for (tools.array.items) |tool| {
        if (tool != .object) continue;
        const name = tool.object.get("name") orelse continue;
        if (name != .string or name.string.len == 0) continue;
        try writeSafe(arena, out, try model_context_encoding.decodeScalarAlloc(arena, name.string), max_name_bytes);
        try out.writeByte('\t');
        if (tool_args.optionalStringArg(tool.object, "description")) |description| {
            try writeSafe(arena, out, try model_context_encoding.decodeScalarAlloc(arena, description), max_line_description_bytes);
        }
        try out.writeByte('\n');
        written += 1;
    }
    const next_cursor: ?[]const u8 = if (page.get("next_cursor")) |cursor| switch (cursor) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    } else null;
    return .{ .tools = written, .next_cursor = next_cursor, .problem = if (written == 0) try pageProblem(arena, page) else null };
}

/// Why a page holds no tools, as one terminal-safe line: the client prints it.
fn pageProblem(arena: Allocator, page: std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const raw = try pageProblemText(arena, page) orelse return null;
    const decoded = try model_context_encoding.decodeScalarAlloc(arena, raw);
    return (try text_utils.encodeTerminalSafeInline(arena, decoded, max_problem_bytes)).bytes;
}

fn pageProblemText(arena: Allocator, page: std.json.ObjectMap) Allocator.Error!?[]const u8 {
    if (page.get("authentication_required")) |required| if (required == .object) {
        const server = tool_args.optionalStringArg(required.object, "server") orelse "this server";
        const message = tool_args.optionalStringArg(required.object, "message") orelse "it needs a login";
        return try arena.print("MCP server '{s}' needs a login: {s}", .{ server, message });
    };
    if (tool_args.optionalStringArg(page, "error")) |message| return message;
    if (tool_args.optionalStringArg(page, "state")) |state| {
        if (std.mem.eql(u8, state, "server_not_found")) return "No MCP server by that name is available to this agent.";
    }
    if (page.get("unavailable")) |reasons| if (reasons == .array) {
        var text: Writer.Allocating = .init(arena);
        for (reasons.array.items) |reason| if (reason == .string) {
            if (text.written().len > 0) text.writer.writeByte(' ') catch return error.OutOfMemory;
            text.writer.writeAll(reason.string) catch return error.OutOfMemory;
        };
        if (text.written().len > 0) return text.written();
    };
    return null;
}

pub const HelpError = error{ InvalidToolSchema, OutOfMemory, WriteFailed };

/// Writes what `help` prints for one tool's schema, `{"name", "description",
/// "inputSchema"}`: its name and description, then each argument with its
/// type, `?` when it is optional, and its own description.
pub fn writeHelp(arena: Allocator, out: *Writer, schema_json: []const u8) HelpError!void {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    if (value != .object) return error.InvalidToolSchema;
    const name = tool_args.optionalStringArg(value.object, "name") orelse return error.InvalidToolSchema;
    if (name.len == 0) return error.InvalidToolSchema;
    try writeSafe(arena, out, name, max_name_bytes);
    try out.writeByte('\n');
    // The description and the server's instructions are encoded for the
    // model (`selected_schema.zig`); the arguments' own descriptions are not.
    if (tool_args.optionalStringArg(value.object, "description")) |description| {
        try writeDescription(arena, out, try model_context_encoding.decodeScalarAlloc(arena, description));
    }
    const input = value.object.get("inputSchema") orelse return error.InvalidToolSchema;
    const properties = if (input == .object) input.object.get("properties") else null;
    if (properties == null or properties.? != .object or properties.?.object.count() == 0) {
        return out.writeAll("\nArguments: none; pass {} or nothing.\n");
    }
    try out.writeAll("\nArguments, as one JSON object:\n");
    const required = input.object.get("required");
    var lines: std.ArrayList([]const u8) = .empty;
    var width: usize = 0;
    var listed: usize = 0;
    var it = properties.?.object.iterator();
    while (it.next()) |entry| : (listed += 1) {
        if (listed == max_arguments) break;
        var line: Writer.Allocating = .init(arena);
        try writeKey(arena, &line.writer, entry.key_ptr.*);
        if (!isRequired(required, entry.key_ptr.*)) try line.writer.writeByte('?');
        try line.writer.writeAll(": ");
        try writeType(arena, &line.writer, entry.value_ptr.*, 0);
        width = @max(width, line.written().len);
        try lines.append(arena, line.written());
    }
    it = properties.?.object.iterator();
    for (lines.items) |line| {
        const entry = it.next().?;
        try out.writeAll("  ");
        try out.writeAll(line);
        const description = if (entry.value_ptr.* == .object) tool_args.optionalStringArg(entry.value_ptr.object, "description") else null;
        if (description) |text| if (text.len > 0) {
            try out.splatByteAll(' ', @min(width, max_name_column) -| line.len + 2);
            try writeSafe(arena, out, text, max_argument_description_bytes);
        };
        try out.writeByte('\n');
    }
    if (properties.?.object.count() > max_arguments) {
        try out.print("  … and {d} more\n", .{properties.?.object.count() - max_arguments});
    }
}

fn isRequired(required: ?std.json.Value, key: []const u8) bool {
    const list = required orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, key)) return true;
    }
    return false;
}

/// A key as written, or JSON-quoted when it is not a plain name.
fn writeKey(arena: Allocator, out: *Writer, key: []const u8) WriteError!void {
    const plain = key.len > 0 and for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '$') break false;
    } else true;
    if (plain) return out.writeAll(key);
    const safe = try text_utils.encodeTerminalSafeInline(arena, key, 128);
    try std.json.Stringify.value(safe.bytes, .{}, out);
}

/// A JSON Schema as a short type: `string`, `"a" | "b"`, `number[]`,
/// `{id: string, done?: boolean}`, or `any` for what it does not spell out.
fn writeType(arena: Allocator, out: *Writer, schema: std.json.Value, depth: usize) WriteError!void {
    if (schema != .object) return out.writeAll("any");
    const object = schema.object;
    if (object.get("const")) |literal| return writeLiteral(arena, out, literal);
    if (object.get("enum")) |choices| if (choices == .array and choices.array.items.len > 0) {
        for (choices.array.items, 0..) |choice, index| {
            if (index == max_choices) return out.writeAll(" | …");
            if (index > 0) try out.writeAll(" | ");
            try writeLiteral(arena, out, choice);
        }
        return;
    };
    inline for (.{ "anyOf", "oneOf" }) |key| {
        if (object.get(key)) |members| if (members == .array and members.array.items.len > 0) {
            for (members.array.items, 0..) |member, index| {
                if (index == max_choices) return out.writeAll(" | …");
                if (index > 0) try out.writeAll(" | ");
                try writeType(arena, out, member, depth + 1);
            }
            return;
        };
    }
    const declared = object.get("type");
    if (declared) |kind| switch (kind) {
        .string => |name| return writeNamedType(arena, out, object, name, depth),
        .array => |names| if (names.items.len > 0) {
            for (names.items, 0..) |name, index| {
                if (index > 0) try out.writeAll(" | ");
                try writeNamedType(arena, out, object, if (name == .string) name.string else "any", depth);
            }
            return;
        },
        else => {},
    };
    if (object.get("properties") != null) return writeNamedType(arena, out, object, "object", depth);
    if (object.get("items") != null) return writeNamedType(arena, out, object, "array", depth);
    return out.writeAll("any");
}

fn writeNamedType(arena: Allocator, out: *Writer, object: std.json.ObjectMap, name: []const u8, depth: usize) WriteError!void {
    if (std.mem.eql(u8, name, "array")) {
        const items = object.get("items") orelse return out.writeAll("any[]");
        if (depth >= max_type_depth) return out.writeAll("any[]");
        var buffer: [512]u8 = undefined;
        var inner: Writer = .fixed(&buffer);
        writeType(arena, &inner, items, depth + 1) catch |err| switch (err) {
            error.WriteFailed => return out.writeAll("any[]"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const text = inner.buffered();
        const union_type = std.mem.find(u8, text, " | ") != null;
        if (union_type) try out.writeByte('(');
        try out.writeAll(text);
        if (union_type) try out.writeByte(')');
        return out.writeAll("[]");
    }
    if (std.mem.eql(u8, name, "object")) {
        const properties = object.get("properties") orelse return out.writeAll("object");
        if (properties != .object or properties.object.count() == 0 or depth >= max_type_depth) return out.writeAll("object");
        const required = object.get("required");
        try out.writeByte('{');
        var it = properties.object.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) {
            if (index > 0) try out.writeAll(", ");
            if (index == max_inline_keys) {
                try out.writeAll("…");
                break;
            }
            try writeKey(arena, out, entry.key_ptr.*);
            if (!isRequired(required, entry.key_ptr.*)) try out.writeByte('?');
            try out.writeAll(": ");
            try writeType(arena, out, entry.value_ptr.*, depth + 1);
        }
        return out.writeByte('}');
    }
    for ([_][]const u8{ "string", "number", "integer", "boolean", "null" }) |known| {
        if (std.mem.eql(u8, name, known)) return out.writeAll(known);
    }
    return out.writeAll("any");
}

fn writeLiteral(arena: Allocator, out: *Writer, literal: std.json.Value) WriteError!void {
    var buffer: [max_literal_bytes * 2]u8 = undefined;
    var json: Writer = .fixed(&buffer);
    std.json.Stringify.value(literal, .{}, &json) catch {};
    const text = json.buffered();
    if (text.len == 0) return out.writeAll("any");
    try writeSafe(arena, out, text, max_literal_bytes);
}

const WriteError = Writer.Error || Allocator.Error;

/// Writes `text` the way spark shows outside text on one terminal line, at most
/// `max_bytes` of it.
fn writeSafe(arena: Allocator, out: *Writer, text: []const u8, max_bytes: usize) WriteError!void {
    const safe = try text_utils.encodeTerminalSafeInline(arena, text, max_bytes);
    try out.writeAll(safe.bytes);
}

/// Writes a tool's description line by line, each as `writeSafe` does, at
/// most `max_help_description_bytes` in all.
fn writeDescription(arena: Allocator, out: *Writer, text: []const u8) WriteError!void {
    var budget: usize = max_help_description_bytes;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        const safe = try text_utils.encodeTerminalSafeInline(arena, line, budget);
        try out.writeAll(safe.bytes);
        try out.writeByte('\n');
        if (safe.truncated) return;
        budget -|= safe.bytes.len + 1;
        if (budget == 0 and lines.peek() != null) return out.writeAll("...\n");
    }
}

const testing = std.testing;

test "a search page becomes one line per tool, and says where the next starts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    const page = try writeToolLines(arena, &out.writer,
        \\{"tools":[{"name":"mcp_linear_list_issues","server":"linear","description":"List issues.\nOne per\tline"},
        \\{"name":"mcp_linear_get_issue","description":"Get one \u001b]52;c;x\u0007issue \u0085now"},{"name":""},7],
        \\"count":2,"next_cursor":"c2"}
    );
    try testing.expectEqual(@as(usize, 2), page.tools);
    try testing.expectEqualStrings("c2", page.next_cursor.?);
    try testing.expect(page.problem == null);
    try testing.expectEqualStrings(
        "mcp_linear_list_issues\tList issues. One per line\n" ++
            "mcp_linear_get_issue\tGet one \\x1b]52;c;x\\x07issue \\u{0085}now\n",
        out.written(),
    );
    try testing.expect(std.mem.findScalar(u8, out.written(), 0x1b) == null);
}
