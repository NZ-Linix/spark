//! What a subagent's profile set when the subagent started. spark saves it with
//! the child, on each of its spawn lines (`src/core/subagent/child_state.zig`),
//! so a restart, a resume in another repository, or an edit of the profile
//! file cannot change what the child may do.
//!
//! Only what the profile itself set is saved: its tool list, its MCP server
//! list, and its permission mode, with where it came from. What a profile left
//! unset has no entry, and follows the agent that started the child, live. The
//! lists are saved as written, patterns included, so spark's own tools and the
//! live MCP servers still decide what they name. A profile's prompt, model,
//! effort, and description are not saved here. The prompt is read again by
//! name, from the folder of the source saved here. The model and effort are
//! kept in memory until the child's first turn starts, and then saved in the
//! child's own preferences, so a child that is lost before that turn loses
//! them (`tests/tla/session_manager/system-design.md` D34).
//!
//! The spawn line's data is kept small (4096 bytes in the session manager,
//! because every snapshot holds it for every child), so a block that would not
//! leave room for the rest of it is not saved (`max_bytes`).

const std = @import("std");
const profiles = @import("profiles.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// The key of the block in a spawn line's data.
pub const key = "started_with";

/// The most bytes of a saved block. A spawn line's data holds at most 4096, and
/// the rest of it (the name, the fingerprint, the profile's name, a purpose)
/// takes about 450 at most.
pub const max_bytes: usize = 3072;

const version: u32 = 1;

pub const StartedWith = struct {
    /// Where the profile came from. A repository's and spark's own profiles never
    /// set a mode, and spark's own set no lists.
    source: profiles.Source,
    permission_mode: ?types.PermissionMode = null,
    /// A list the profile set, as written. Null when it set none.
    tools: ?[]const []const u8 = null,
    mcp_servers: ?[]const []const u8 = null,
};

/// What `profile` set. The result borrows `profile`.
pub fn of(profile: *const profiles.Profile) StartedWith {
    return .{
        .source = profile.source,
        .permission_mode = if (profile.source == .home) profile.permission_mode else null,
        .tools = if (profile.source == .builtin) null else profile.tools,
        .mcp_servers = if (profile.source == .builtin) null else profile.mcp_servers,
    };
}

/// The profile named `name` that `started` describes, for an agent that is
/// started in it. It has no prompt and no description. The result borrows
/// `name` and `started`.
pub fn toProfile(started: StartedWith, name: []const u8) profiles.Profile {
    return .{
        .name = name,
        .description = "",
        .source = started.source,
        .permission_mode = started.permission_mode,
        .tools = started.tools,
        .mcp_servers = started.mcp_servers,
    };
}

const Wire = struct {
    v: u32 = version,
    from: []const u8,
    permission_mode: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    mcp_servers: ?[]const []const u8 = null,
};

/// The block as spark saves it: one JSON object with nothing in it for what the
/// profile left unset. The caller checks `fits`. The text belongs to `arena`.
pub fn encode(arena: Allocator, started: StartedWith) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(Wire{
        .from = @tagName(started.source),
        .permission_mode = if (started.permission_mode) |mode| @tagName(mode) else null,
        .tools = started.tools,
        .mcp_servers = started.mcp_servers,
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Whether an encoded block leaves room in a spawn line's data.
pub fn fits(encoded: []const u8) bool {
    return encoded.len <= max_bytes;
}

const Read = union(enum) {
    /// The data has no block: a child from before blocks, or one a profile
    /// did not start.
    none,
    /// The data has a block that spark would not have written.
    invalid,
    started: StartedWith,
};

/// The block in a spawn line's `data`, if spark wrote it. What it accepts is a
/// block whose parsed value is what `encode` gives for what it says: the same
/// keys in the same order with values spark can write. Another JSON spelling of
/// that value, with spaces or `\u` escapes, reads the same. Anything else, such
/// as a version spark does not know, an unknown key, a mode on a repository's
/// profile, or a repeated key anywhere in the data, reads as `.invalid`, and
/// the child is treated as if it had none. A repeated key is the one way saved
/// data fails to parse and still gets here: data cut short breaks its log line,
/// which spark refuses with the whole session, and a repeated key in a field the
/// child's own load reads fails that load first. The result belongs to `arena`.
pub fn read(arena: Allocator, spawn_data: []const u8) Allocator.Error!Read {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, spawn_data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return if (std.mem.find(u8, spawn_data, "\"" ++ key ++ "\"") != null) .invalid else .none,
    };
    if (root != .object) return .none;
    const block = root.object.get(key) orelse return .none;
    const started = (try extract(arena, block)) orelse return .invalid;
    const canonical = try encode(arena, started);
    if (!fits(canonical)) return .invalid;
    var again: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(block, .{}, &again.writer) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, again.written(), canonical)) return .invalid;
    return .{ .started = started };
}

fn extract(arena: Allocator, block: std.json.Value) Allocator.Error!?StartedWith {
    if (block != .object) return null;
    var started: StartedWith = .{ .source = .builtin };
    var has_version = false;
    var has_source = false;
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "v")) {
            if (value != .integer or value.integer != version) return null;
            has_version = true;
        } else if (std.mem.eql(u8, name, "from")) {
            if (value != .string) return null;
            started.source = std.meta.stringToEnum(profiles.Source, value.string) orelse return null;
            has_source = true;
        } else if (std.mem.eql(u8, name, "permission_mode")) {
            if (value != .string) return null;
            started.permission_mode = std.meta.stringToEnum(types.PermissionMode, value.string) orelse return null;
        } else if (std.mem.eql(u8, name, "tools")) {
            started.tools = (try names(arena, value)) orelse return null;
        } else if (std.mem.eql(u8, name, "mcp_servers")) {
            started.mcp_servers = (try names(arena, value)) orelse return null;
        } else return null;
    }
    if (!has_version or !has_source) return null;
    if (started.source != .home and started.permission_mode != null) return null;
    if (started.source == .builtin and (started.tools != null or started.mcp_servers != null)) return null;
    return started;
}

fn names(arena: Allocator, value: std.json.Value) Allocator.Error!?[]const []const u8 {
    if (value != .array) return null;
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| slot.* = profiles.listEntry(item) orelse return null;
    return out;
}

/// A copy of `started` that `alloc` owns. Free it with `free`.
pub fn dupe(alloc: Allocator, started: StartedWith) Allocator.Error!StartedWith {
    const tools = if (started.tools) |list| try profiles.cloneNames(alloc, list) else null;
    errdefer if (tools) |list| freeNames(alloc, list);
    const mcp_servers = if (started.mcp_servers) |list| try profiles.cloneNames(alloc, list) else null;
    return .{ .source = started.source, .permission_mode = started.permission_mode, .tools = tools, .mcp_servers = mcp_servers };
}

pub fn free(alloc: Allocator, started: StartedWith) void {
    if (started.tools) |list| freeNames(alloc, list);
    if (started.mcp_servers) |list| freeNames(alloc, list);
}

fn freeNames(alloc: Allocator, list: []const []const u8) void {
    for (list) |text| alloc.free(text);
    alloc.free(list);
}

pub fn eql(a: StartedWith, b: StartedWith) bool {
    return a.source == b.source and a.permission_mode == b.permission_mode and
        namesEql(a.tools, b.tools) and namesEql(a.mcp_servers, b.mcp_servers);
}

fn namesEql(a: ?[]const []const u8, b: ?[]const []const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

const testing = std.testing;
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");

fn fuzzRead(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [4096]u8 = undefined;
    const spawn = buffer[0..smith.slice(&buffer)];
    switch (try read(arena, spawn)) {
        .none, .invalid => {},
        .started => |started| {
            // What is accepted is what `encode` writes: it fits, a mode only
            // comes with a profile of the user's own, and spark's own set no lists.
            const encoded = try encode(arena, started);
            try testing.expect(fits(encoded));
            if (started.source != .home) try testing.expect(started.permission_mode == null);
            if (started.source == .builtin) try testing.expect(started.tools == null and started.mcp_servers == null);
            const spawn_again = try arena.print("{{\"{s}\":{s}}}", .{ key, encoded });
            const again = try read(arena, spawn_again);
            try testing.expect(again == .started and eql(started, again.started));
            // The profile built from it allows exactly what its lists say.
            const built = toProfile(started, "fuzz");
            try testing.expectEqual(started.tools != null, profiles.setsTools(&built));
            try testing.expectEqual(started.mcp_servers != null, profiles.setsMcpServers(&built));
        },
    }
}
