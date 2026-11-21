//! The toolbox menu: one short line for each skill, MCP server, custom tool,
//! and built-in tool that spark keeps out of the tools list, so the model sees
//! what it can use without spark sending all of it. The `toolbox` tool opens and
//! runs what the menu lists.
//!
//! spark renders the menu once for a session and sends the same bytes on every
//! request, so a server going down, or a skill installed mid-session, never
//! changes what an earlier request sent (`tests/tla/toolbox/Toolbox.tla`
//! MenuFixed and PrefixStable). Changes reach the model as notes at the end
//! of the conversation instead.
const std = @import("std");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const text_utils = @import("../shared/text_utils.zig");
const mcp_call_capability = @import("mcp_call_capability.zig");
const core_types = @import("../shared/types.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_args = @import("tool_args.zig");

const Allocator = std.mem.Allocator;

/// The name of the tool that opens and runs what the menu lists.
pub const tool_name = "toolbox";

/// Whether a request's advertised tools include toolbox.
pub fn isAdvertised(advertised_names: []const []const u8) bool {
    for (advertised_names) |name| if (std.mem.eql(u8, name, tool_name)) return true;
    return false;
}

/// Built-in tools whose work toolbox does: spark doesn't send them.
pub const replaced = [_][]const u8{ "capability_search", "mcp_select_tool", "skill" };

/// Built-in tools spark lists in the menu and runs through toolbox instead of
/// sending them, unless settings say otherwise.
pub const default_behind = [_][]const u8{"install_skill"};

/// What a toolbox open or search stands for, so the permission rules and a
/// subagent's profile decide it as the tool it replaced: reading a skill is
/// `skill` with the skill's name, opening an MCP server or tool is
/// `mcp_select_tool` with its name, and searching is `capability_search`.
/// Null for a run, which is admitted as the call it carries, for opening a
/// built-in tool's definition, and for arguments that don't parse. An open
/// with `kind` is decided as that kind. Without one it is decided in the
/// order open reads: a skill in `locations` first, whatever other tool or
/// server shares its name, then a built-in, an MCP tool, and one of the
/// turn's `servers`. Any other name is taken as a skill's, since open reads
/// it as a skill installed since the turn began. The result borrows `arena`.
pub fn lookupOf(
    arena: Allocator,
    call: core_types.ToolCall,
    locations: ?*const skill_contract.Locations,
    servers: []const []const u8,
    registry: tool_dispatch.Registry,
) Allocator.Error!?core_types.ToolboxLookup {
    if (!std.mem.eql(u8, call.name, tool_name)) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    if (parsed.object.get("search") != null) return .{ .permission = "capability_search", .target = "*" };
    const opened = parsed.object.get("open") orelse return null;
    if (opened != .string or opened.string.len == 0) return null;
    const target = opened.string;
    const kind: ?Kind = if (parsed.object.get("kind")) |value|
        if (value == .string) std.meta.stringToEnum(Kind, value.string) else null
    else
        null;
    if (kind) |chosen| return switch (chosen) {
        .skill => .{ .permission = "skill", .target = (try skillNamed(arena, locations, target)) orelse target },
        .mcp_server => .{ .permission = "mcp_select_tool", .target = target },
        .tool => if (registry.lookup(target) != null) null else .{ .permission = "mcp_select_tool", .target = target },
    };
    if (try skillNamed(arena, locations, target)) |skill| return .{ .permission = "skill", .target = skill };
    if (registry.lookup(target) != null) return null;
    if (core_types.isMcpToolName(target)) return .{ .permission = "mcp_select_tool", .target = target };
    for (servers) |server| {
        if (std.mem.eql(u8, server, target)) return .{ .permission = "mcp_select_tool", .target = target };
    }
    return .{ .permission = "skill", .target = target };
}

/// The name of the skill `target` opens, a name or a location, or null when
/// it names no skill. A location spark can't resolve keeps its own text, so a
/// rule for every skill still holds.
fn skillNamed(arena: Allocator, locations: ?*const skill_contract.Locations, target: []const u8) Allocator.Error!?[]const u8 {
    const catalog = if (locations) |value| value.* else skill_contract.Locations{};
    const is_location = std.mem.startsWith(u8, target, "skill:") or std.Io.Dir.path.isAbsolute(target);
    if (!is_location) {
        for (catalog.skills) |skill| if (std.mem.eql(u8, skill.name, target)) return skill.name;
        return null;
    }
    const path = catalog.resolve(arena, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return target,
    };
    for (catalog.skills) |skill| if (std.mem.eql(u8, skill.path, path)) return skill.name;
    return target;
}

/// Whether toolbox runs `tool` for the model. A host's own tool is called
/// directly instead: a durable session reruns it by its name after a crash,
/// under the host's rerun policy.
pub fn runs(tool: tool_dispatch.Tool) bool {
    return tool.executor_kind != .host;
}

pub const Carried = struct {
    name: []const u8,
    arguments_json: []const u8,
    /// The model wrote the arguments as JSON text, which `runArguments` read.
    arguments_from_text: bool = false,
};

/// A run's `arguments` as the object the tool takes: the object itself, or
/// the object that JSON text holds, since some models write the arguments as
/// text. Only one level of text is read. Null for any other value, which the
/// tool's decode refuses; a decoded object is allocated in `arena`. Decode
/// and `carriedCall` both read arguments through this, so a call is carried
/// exactly when decode reads it as a run.
pub fn runArguments(arena: Allocator, value: std.json.Value) Allocator.Error!?std.json.Value {
    var decoded = value;
    tool_args.normalizeCompositeObjectValue(arena, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return if (decoded == .object) decoded else null;
}

/// The keys toolbox reads for open and search. The tool's decode
/// (`src/tools/capabilities/toolbox.zig`) refuses a run that has any of them.
const not_run_keys = [_][]const u8{ "open", "search", "resource", "server", "offset", "kind", "limit", "cursor" };

/// The call a `toolbox {run}` call carries: the tool it names and its
/// arguments as JSON, "{}" when it gives none. Null for any other call and
/// for arguments the tool's decode doesn't read as a run, such as a run that
/// also opens or searches, so that call reaches decode and gets its reason.
pub fn carriedCall(arena: Allocator, name: []const u8, arguments_json: []const u8) Allocator.Error!?Carried {
    if (!std.mem.eql(u8, name, tool_name)) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    for (not_run_keys) |key| if (parsed.object.get(key) != null) return null;
    const target = parsed.object.get("run") orelse return null;
    if (target != .string or std.mem.trim(u8, target.string, " \t\r\n").len == 0) return null;
    var arguments: std.Io.Writer.Allocating = .init(arena);
    var from_text = false;
    if (parsed.object.get("arguments")) |value| {
        const object = (try runArguments(arena, value)) orelse return null;
        from_text = value == .string;
        std.json.Stringify.value(object, .{}, &arguments.writer) catch return error.OutOfMemory;
    } else arguments.writer.writeAll("{}") catch return error.OutOfMemory;
    return .{ .name = target.string, .arguments_json = arguments.written(), .arguments_from_text = from_text };
}

test "a run's arguments written as JSON text are carried as their object, and other text is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const carried = (try carriedCall(arena, tool_name, "{\"run\":\"mcp_fixture_echo\",\"arguments\":\"{\\\"text\\\":\\\"hi\\\",\\\"n\\\":[1,{\\\"a\\\":null}]}\"}")).?;
    try std.testing.expectEqualStrings("mcp_fixture_echo", carried.name);
    try std.testing.expectEqualStrings("{\"text\":\"hi\",\"n\":[1,{\"a\":null}]}", carried.arguments_json);
    try std.testing.expect(carried.arguments_from_text);
    const empty = (try carriedCall(arena, tool_name, "{\"run\":\"mcp_fixture_echo\",\"arguments\":\"{}\"}")).?;
    try std.testing.expectEqualStrings("{}", empty.arguments_json);
    try std.testing.expect(empty.arguments_from_text);
    const object = (try carriedCall(arena, tool_name, "{\"run\":\"mcp_fixture_echo\",\"arguments\":{\"text\":\"hi\"}}")).?;
    try std.testing.expect(!object.arguments_from_text);

    const refused = [_][]const u8{
        "\"text\"",
        "\"[1]\"",
        "\"40\"",
        "\"true\"",
        "\"null\"",
        "\"\"",
        "\"  \"",
        "\"{\\\"a\\\":1} x\"",
        // Text of text of an object: only one level is read.
        "\"\\\"{\\\\\\\"a\\\\\\\":1}\\\"\"",
        "null",
        "40",
    };
    for (refused) |arguments| {
        const call = try std.mem.concat(arena, u8, &.{ "{\"run\":\"mcp_fixture_echo\",\"arguments\":", arguments, "}" });
        try std.testing.expect(try carriedCall(arena, tool_name, call) == null);
    }

    // Text nested past what Stringify can write back is refused, not carried.
    var deep: std.Io.Writer.Allocating = .init(arena);
    try deep.writer.writeAll("{\"run\":\"mcp_fixture_echo\",\"arguments\":\"");
    for (0..300) |_| try deep.writer.writeAll("{\\\"a\\\":");
    try deep.writer.writeAll("1");
    for (0..300) |_| try deep.writer.writeAll("}");
    try deep.writer.writeAll("\"}");
    try std.testing.expect(try carriedCall(arena, tool_name, deep.written()) == null);
}

pub fn isReplaced(name: []const u8) bool {
    for (replaced) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

pub const Kind = enum { skill, mcp_server, tool };

pub const Entry = struct {
    kind: Kind,
    /// What the model passes to `toolbox {open}` or `toolbox {run}`.
    name: []const u8,
    /// Free text from the entry's owner; the menu keeps its first sentence.
    description: []const u8 = "",
    /// For an MCP server: how many tools it has, when spark knows.
    tool_count: ?usize = null,
    /// What to open it as when `name` alone is ambiguous: the location of a
    /// skill that shares its name with another.
    open_as: ?[]const u8 = null,
};

/// The most a rendered menu may take; `renderBounded` lists fewer entries of
/// each kind until it fits.
pub const max_menu_bytes = 32 * 1024;

/// Room before the menu for a line that leads it, such as the skill
/// discovery warning.
pub const max_lead_bytes = 512;

pub const Bounded = struct {
    /// Owned by the caller.
    menu: []u8,
    /// True when the menu had to shorten descriptions or list fewer entries
    /// to fit.
    shortened: bool,
};

/// `render` within `limits.max_bytes` and `max_menu_bytes`: shorter
/// descriptions first, down to names alone, so every listed name stays, and
/// only then fewer entries of each kind.
pub fn renderBounded(alloc: Allocator, entries: []const Entry, limits: Limits) Allocator.Error!Bounded {
    const bound = @min(limits.max_bytes, max_menu_bytes);
    var current = limits;
    while (true) {
        const menu = try render(alloc, entries, current);
        if (menu.len <= bound or current.per_kind == 0) {
            const shortened = current.line_bytes != limits.line_bytes or current.per_kind != limits.per_kind;
            if (menu.len <= bound) return .{ .menu = menu, .shortened = shortened };
            // Nothing listed and still past the bound, which is then smaller
            // than the menu's own text: keep the bound, cut on a character.
            defer alloc.free(menu);
            return .{ .menu = try alloc.dupe(u8, text_utils.utf8PrefixByBytes(menu, bound)), .shortened = true };
        }
        alloc.free(menu);
        if (current.line_bytes > 0) {
            current.line_bytes = if (current.line_bytes > 24) current.line_bytes / 2 else 0;
        } else current.per_kind /= 2;
    }
}

pub const Limits = struct {
    /// Entries of one kind listed in full; the rest are counted and left to
    /// `toolbox {search}`.
    per_kind: usize = 60,
    /// The longest short line, in bytes, before it is cut.
    line_bytes: usize = 100,
    /// The most the menu may take, such as the skill catalog's budget; never
    /// more than `max_menu_bytes`.
    max_bytes: usize = max_menu_bytes,
};

/// The menu's opening, the same in every workspace.
pub const intro =
    "Skills, MCP servers, and tools you can use through the toolbox tool are listed below; they are not in your tool list.\n" ++
    "Use toolbox with open to read a skill's instructions, see a tool's arguments, or list an MCP server's tools; with search to find skills and tools by what you need, each tool with its arguments; with run to run a tool by its name with its arguments. To use an MCP server, search it with its name as server, then run what you find. To open a name listed under two headings, add kind.\n" ++
    "Use named skills and clearly matching skills before substantive work, and read a selected skill completely, including its required references. A listed server is not a reason to use MCP.\n";

const sections = [_]struct { kind: Kind, title: []const u8, noun: []const u8 }{
    .{ .kind = .skill, .title = "Skills", .noun = "skills" },
    .{ .kind = .mcp_server, .title = "MCP servers", .noun = "MCP servers" },
    .{ .kind = .tool, .title = "Tools", .noun = "tools" },
};

/// The menu for `entries`, or "" when there is nothing to list. Entries keep
/// the order they come in within each kind, so the same entries always give
/// the same bytes. The caller owns the result.
pub fn render(alloc: Allocator, entries: []const Entry, limits: Limits) Allocator.Error![]u8 {
    if (entries.len == 0) return alloc.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    renderTo(&out.writer, entries, limits) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// How to keep a large MCP result out of the conversation, for a menu that
/// lists MCP servers. Empty where the `spark mcp call` bridge does not exist
/// (`mcp_call_capability.supported`), so the model is never told to use it
/// there.
pub const mcp_call_hint = if (mcp_call_capability.supported)
    "When an MCP tool's result would be large or needs filtering, run it from a shell command instead: spark mcp call TOOL_NAME '<JSON arguments>' > FILE. Only what the command prints returns to you.\n"
else
    "";

fn renderTo(w: *std.Io.Writer, entries: []const Entry, limits: Limits) std.Io.Writer.Error!void {
    try w.writeAll(intro);
    for (entries) |entry| {
        if (entry.kind != .mcp_server) continue;
        try w.writeAll(mcp_call_hint);
        break;
    }
    try w.writeAll("<toolbox>\n");
    for (sections) |section| {
        const total = countOf(entries, section.kind);
        if (total == 0) continue;
        try w.print("{s}\n", .{section.title});
        var listed: usize = 0;
        for (entries) |entry| {
            if (entry.kind != section.kind) continue;
            if (listed == limits.per_kind) break;
            listed += 1;
            try w.writeAll("- ");
            try model_context_encoding.writeScalar(w, entry.name);
            if (entry.open_as) |key| {
                try w.writeAll(" (open as ");
                try model_context_encoding.writeScalar(w, key);
                try w.writeByte(')');
            }
            if (entry.tool_count) |count| {
                try w.print(" ({d} tool{s})", .{ count, if (count == 1) "" else "s" });
            }
            const line = shortLine(entry.description, limits.line_bytes);
            if (line.text.len > 0) {
                try w.writeAll(": ");
                try writeLine(w, line.text);
                if (line.cut) try w.writeAll("…");
            }
            try w.writeByte('\n');
        }
        if (total > listed) {
            try w.print("- and {d} more {s}: find them with toolbox search\n", .{ total - listed, section.noun });
        }
    }
    try w.writeAll("</toolbox>\n");
}

/// The longest change note, in bytes; past it, names are counted.
pub const max_change_note_bytes = 4 * 1024;

/// A hash of what `entries` lists: each entry's kind and name, in order. A
/// conversation compares it with its menu's to see the toolbox change.
pub fn entriesHash(entries: []const Entry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (entries) |entry| {
        hasher.update(@tagName(entry.kind));
        hasher.update(&.{0});
        hasher.update(entry.name);
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// The note, at the end of a conversation, for a toolbox that holds
/// something other than the conversation's menu lists: what it holds now, by
/// name, within `max_change_note_bytes`. The menu itself stays as it was, so
/// nothing earlier requests sent changes. The caller owns the result.
pub fn renderChangeNote(alloc: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    renderChangeNoteTo(&out.writer, entries) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// How many of `entries` are of `kind`.
fn countOf(entries: []const Entry, kind: Kind) usize {
    var total: usize = 0;
    for (entries) |entry| {
        if (entry.kind == kind) total += 1;
    }
    return total;
}

/// The bytes `model_context_encoding.writeScalar` writes for `value`.
fn scalarBytes(value: []const u8) std.Io.Writer.Error!usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try model_context_encoding.writeScalar(&counter.writer, value);
    return @intCast(counter.fullCount());
}

fn renderChangeNoteTo(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
    if (entries.len == 0) {
        try w.writeAll("The toolbox is now empty: nothing the toolbox menu above lists can be opened or run.\n");
        return;
    }
    try w.writeAll("The toolbox now holds something other than the toolbox menu above lists. This is what it holds now, by name; open any of them with toolbox:\n");
    // Room for the opening, every section's title, and its count line.
    const budget = max_change_note_bytes - 512;
    var used: usize = 0;
    for (sections) |section| {
        const total = countOf(entries, section.kind);
        if (total == 0) continue;
        try w.print("{s}: ", .{section.title});
        var listed: usize = 0;
        for (entries) |entry| {
            if (entry.kind != section.kind) continue;
            // A name that needs escaping takes more room than its bytes.
            const name_bytes = try scalarBytes(entry.name);
            if (used + name_bytes + 2 > budget) break;
            if (listed > 0) try w.writeAll(", ");
            try model_context_encoding.writeScalar(w, entry.name);
            used += name_bytes + 2;
            listed += 1;
        }
        if (total > listed) try w.print("{s}and {d} more: find them with toolbox search", .{ if (listed > 0) ", " else "", total - listed });
        try w.writeByte('\n');
    }
}

/// Writes `text` with every run of whitespace as one space, encoded for the
/// model.
fn writeLine(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!std.ascii.isWhitespace(text[index])) continue;
        try model_context_encoding.writeScalar(w, text[start..index]);
        while (index + 1 < text.len and std.ascii.isWhitespace(text[index + 1])) index += 1;
        if (index + 1 < text.len) try w.writeByte(' ');
        start = index + 1;
    }
    if (start < text.len) try model_context_encoding.writeScalar(w, text[start..]);
}

pub const ShortLine = struct {
    text: []const u8,
    /// True when the sentence was longer than the limit and ends early.
    cut: bool,
};

/// The first sentence of `description`, trimmed, and no longer than
/// `max_bytes`, cut at a UTF-8 boundary and a word where it can be.
pub fn shortLine(description: []const u8, max_bytes: usize) ShortLine {
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    var end = trimmed.len;
    var index: usize = 0;
    while (index < trimmed.len) : (index += 1) {
        if (trimmed[index] != '.') continue;
        if (index + 1 == trimmed.len or std.ascii.isWhitespace(trimmed[index + 1])) {
            end = index + 1;
            break;
        }
    }
    const sentence = trimmed[0..end];
    if (sentence.len <= max_bytes) return .{ .text = sentence, .cut = false };
    const prefix = text_utils.utf8PrefixByBytes(sentence, max_bytes);
    const at_word = if (std.mem.findScalarLast(u8, prefix, ' ')) |space|
        if (space > prefix.len / 2) prefix[0..space] else prefix
    else
        prefix;
    return .{ .text = std.mem.trimEnd(u8, at_word, " ,;:"), .cut = true };
}

fn fuzzMenu(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];
    var entries: [32]Entry = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (count == entries.len or line.len == 0) continue;
        const kind: Kind = @fromBackingInt(@intCast(line[0] % @typeInfo(Kind).@"enum".field_names.len));
        const rest = line[1..];
        const tab = std.mem.findScalar(u8, rest, '\t') orelse rest.len;
        entries[count] = .{
            .kind = kind,
            .name = rest[0..tab],
            .description = if (tab < rest.len) rest[tab + 1 ..] else "",
            .tool_count = if (line[0] & 0x80 != 0) line.len else null,
        };
        count += 1;
    }
    const limits: Limits = .{ .per_kind = 1 + (len % 5), .line_bytes = 8 + (len % 64) };
    const first = try render(std.testing.allocator, entries[0..count], limits);
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, entries[0..count], limits);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    // The bounded menu keeps any limit, even one smaller than its own text,
    // and the change note keeps its own, however much the names escape.
    const max_bytes = len % 1024;
    const bounded = try renderBounded(std.testing.allocator, entries[0..count], .{ .per_kind = limits.per_kind, .line_bytes = limits.line_bytes, .max_bytes = max_bytes });
    defer std.testing.allocator.free(bounded.menu);
    try std.testing.expect(bounded.menu.len <= max_bytes);
    const note = try renderChangeNote(std.testing.allocator, entries[0..count]);
    defer std.testing.allocator.free(note);
    try std.testing.expect(note.len <= max_change_note_bytes);
    if (count == 0) return try std.testing.expectEqual(@as(usize, 0), first.len);
    // One opening and one closing tag, whatever the entries say.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "<toolbox>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "</toolbox>"));
    // Escaping at most multiplies each input byte by six. The fixed text is
    // the intro and, when the menu lists an MCP server, the `spark mcp call` hint.
    try std.testing.expect(first.len <= intro.len + mcp_call_hint.len + 256 + 8 * input.len);
}
