//! `~/.spark/mcp.json` and `.mcp.json` edited in place. `add` and
//! `remove` change one entry of the file's JSON tree, so keys spark doesn't
//! know, the other top-level keys, the order, the spelling, and the text of
//! numbers all stay as written. `update` writes only what spark's own reader
//! then loads, and never a profile whose servers key looks misspelled
//! (`tests/tla/mcp_host/ConfigEdit.tla` `AddedIsLoaded`, `NoRewriteOfMisspelled`).

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const project_config = @import("../mcp/project_config.zig");

const Allocator = std.mem.Allocator;
const json = std.json;

/// Which file is edited: the profile reads `mcp` or `mcpServers`, a
/// project's `.mcp.json` only `mcpServers`.
pub const File = enum { profile, project };

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Entry = union(enum) {
    stdio: struct { command: []const u8, args: []const []const u8 = &.{}, env: []const Pair = &.{} },
    http: struct { url: []const u8, headers: []const Pair = &.{} },
};

pub const Error = Allocator.Error || error{
    /// The file isn't JSON, or repeats a key.
    Unreadable,
    /// The file's top level, or its server list, isn't an object.
    NotAnObject,
    /// A profile with both `mcp` and `mcpServers`.
    BothKeys,
    /// `add`: the name is already in the file.
    Exists,
};

/// The file with `name` added. `text` is null when the file doesn't exist yet.
pub fn add(alloc: Allocator, file: File, text: ?[]const u8, name: []const u8, entry: Entry) Error![]u8 {
    return addOrReplace(alloc, file, text, name, entry, false);
}

/// Like `add`, but `replace` swaps an entry already named `name` in place,
/// keeping whether it was turned off.
pub fn addOrReplace(alloc: Allocator, file: File, text: ?[]const u8, name: []const u8, entry: Entry, replace: bool) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, true)).?;
    var value = try entryValue(a, entry);
    if (servers.get(name)) |old| {
        if (!replace) return error.Exists;
        if (old == .object) if (old.object.get("enabled")) |enabled| try value.object.put(a, "enabled", enabled);
    }
    try servers.put(a, name, value);
    return render(alloc, root);
}

/// The entry named `name` as the add form shows it, or null when the file
/// doesn't define it or it isn't an object. Slices belong to `arena`.
pub fn entryOf(arena: Allocator, file: File, text: []const u8, name: []const u8) ?Entry {
    var root = parse(arena, text) catch return null;
    const servers = (serversOf(arena, file, &root, false) catch return null) orelse return null;
    const value = servers.get(name) orelse return null;
    if (value != .object) return null;
    const o = value.object;
    const str = struct {
        fn of(v: ?json.Value) ?[]const u8 {
            return if (v) |x| (if (x == .string) x.string else null) else null;
        }
        fn pairsOf(a: Allocator, v: ?json.Value) []const Pair {
            const obj = if (v) |x| (if (x == .object) x.object else return &.{}) else return &.{};
            var out: std.ArrayList(Pair) = .empty;
            var it = obj.iterator();
            while (it.next()) |kv| if (kv.value_ptr.* == .string) out.append(a, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.string }) catch return out.items;
            return out.items;
        }
    };
    if (str.of(o.get("url"))) |url| return .{ .http = .{ .url = url, .headers = str.pairsOf(arena, o.get("headers")) } };
    const command = str.of(o.get("command")) orelse return null;
    var args: std.ArrayList([]const u8) = .empty;
    if (o.get("args")) |list| if (list == .array) for (list.array.items) |item| if (item == .string) args.append(arena, item.string) catch return null;
    return .{ .stdio = .{ .command = command, .args = args.items, .env = str.pairsOf(arena, o.get("env")) } };
}

pub const Removed = struct {
    text: []u8,
    /// The entry's `url`, which keys an HTTP server's token.
    url: ?[]u8,

    pub fn deinit(r: *Removed, alloc: Allocator) void {
        alloc.free(r.text);
        if (r.url) |url| alloc.free(url);
        r.* = undefined;
    }
};

/// The file without `name`, or null when `name` isn't in it.
pub fn remove(alloc: Allocator, file: File, text: []const u8, name: []const u8) Error!?Removed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, false)) orelse return null;
    const old = servers.get(name) orelse return null;
    const url: ?[]u8 = if (old == .object) if (old.object.get("url")) |u| switch (u) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    } else null else null;
    errdefer if (url) |u| alloc.free(u);
    _ = servers.orderedRemove(name);
    return .{ .text = try render(alloc, root), .url = url };
}

/// The file with `name` turned on or off, or null when `name` isn't in it.
/// Off writes `"enabled": false`; on drops the key, so the entry reads as it
/// did before it was turned off.
pub fn setEnabled(alloc: Allocator, file: File, text: []const u8, name: []const u8, enabled: bool) Error!?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, false)) orelse return null;
    const entry = servers.getPtr(name) orelse return null;
    if (entry.* != .object) return error.NotAnObject;
    if (enabled) {
        _ = entry.object.orderedRemove("enabled");
    } else {
        try entry.object.put(a, "enabled", .{ .bool = false });
    }
    return try render(alloc, root);
}

/// Turns `name` in the file at `path` on or off under the profile's lock.
/// False when the file doesn't define it.
pub fn updateEnabled(alloc: Allocator, profile_path: []const u8, file: File, path: []const u8, name: []const u8, enabled: bool) !bool {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = (try read(alloc, path)) orelse return false;
    defer alloc.free(text);
    const next = (try setEnabled(alloc, file, text, name, enabled)) orelse return false;
    defer alloc.free(next);
    try write(alloc, file, path, next);
    return true;
}

test "setEnabled writes and drops enabled false" {
    const alloc = std.testing.allocator;
    const off = (try setEnabled(alloc, .profile, "{\"mcpServers\":{\"a\":{\"url\":\"https://x\"}}}", "a", false)).?;
    defer alloc.free(off);
    try std.testing.expect(std.mem.find(u8, off, "\"enabled\": false") != null or std.mem.find(u8, off, "\"enabled\":false") != null);
    const on = (try setEnabled(alloc, .profile, off, "a", true)).?;
    defer alloc.free(on);
    try std.testing.expect(std.mem.find(u8, on, "enabled") == null);
    try std.testing.expect((try setEnabled(alloc, .profile, on, "missing", true)) == null);
}

/// Whether the file defines `name`; false for a file that can't be read.
pub fn has(alloc: Allocator, file: File, text: []const u8, name: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var root = parse(arena.allocator(), text) catch return false;
    const servers = (serversOf(arena.allocator(), file, &root, false) catch return false) orelse return false;
    return servers.contains(name);
}

pub const Change = union(enum) {
    add: struct { name: []const u8, entry: Entry, replace: bool = false },
    remove: []const u8,
};

pub const Updated = union(enum) {
    added,
    /// The removed entry's `url`, owned by the caller's allocator.
    removed: ?[]u8,
    missing,
    /// Nothing was written.
    refused: Refusal,
};

/// Why an edit isn't made. Both carry bounded text only, never an entry's URL or headers.
pub const Refusal = union(enum) {
    /// The reader would skip the new entry.
    entry: project_config.EntryProblem,
    /// The profile has a key that looks like a misspelling of its servers key.
    misspelled: project_config.MisspelledKey,
};

/// Whether adding `name` to `file`, which held `before` and would hold `after`,
/// is refused: the profile's servers key looks misspelled, or the reader would
/// skip the new entry. Null for a file the reader loads the entry from. It runs
/// the reader on the text as it will be written, so the rules stay the reader's.
fn refusalOf(alloc: Allocator, file: File, before: ?[]const u8, after: []const u8, name: []const u8) Allocator.Error!?Refusal {
    if (file == .profile) {
        if (try misspelledIn(alloc, file, before)) |key| return .{ .misspelled = key };
    }
    if (try project_config.entryProblemIn(alloc, file == .profile, after, name)) |problem| return .{ .entry = problem };
    return null;
}

/// The profile's misspelled servers key, found by reading every key; null for
/// `.mcp.json`, whose keys spark doesn't check, and for a file that isn't there.
fn misspelledIn(alloc: Allocator, file: File, text: ?[]const u8) Allocator.Error!?project_config.MisspelledKey {
    if (file != .profile) return null;
    return project_config.misspelledKey(alloc, text orelse return null);
}

/// Applies `change` to the file at `path`. Every MCP config write holds the
/// profile's lock, next to `profile_path`, so two spark processes can't lose
/// each other's change. The reader's check reads the file under that lock, as
/// it is then, so a key that appears between two commands is found by the
/// next one. A refused change writes nothing.
pub fn update(alloc: Allocator, profile_path: []const u8, file: File, path: []const u8, change: Change) !Updated {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = try read(alloc, path);
    defer if (text) |t| alloc.free(t);
    switch (change) {
        .add => |a| {
            const next = try addOrReplace(alloc, file, text, a.name, a.entry, a.replace);
            defer alloc.free(next);
            if (try refusalOf(alloc, file, text, next, a.name)) |refusal| return .{ .refused = refusal };
            try write(alloc, file, path, next);
            return .added;
        },
        .remove => |name| {
            const removed = (try remove(alloc, file, text orelse return .missing, name)) orelse return .missing;
            defer alloc.free(removed.text);
            errdefer if (removed.url) |u| alloc.free(u);
            if (try misspelledIn(alloc, file, text)) |key| {
                if (removed.url) |u| alloc.free(u);
                return .{ .refused = .{ .misspelled = key } };
            }
            try write(alloc, file, path, removed.text);
            return .{ .removed = removed.url };
        },
    }
}

/// The most of an MCP config file `read` takes; a larger one fails with
/// StreamTooLong.
pub const max_read_bytes: usize = 1024 * 1024;

/// The file's text, or null when it doesn't exist; owned by `alloc`. A path
/// that isn't a regular file, such as a fifo, fails with DurablePathUnsafe
/// instead of waiting for a writer.
pub fn read(alloc: Allocator, path: []const u8) !?[]u8 {
    var f = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &f, max_read_bytes);
}

const profile_lock_deadline_ms: u64 = 2_000;

/// The lock every MCP config write holds, in the profile directory.
pub fn lockProfile(profile_path: []const u8) !io_mod.TimedAdvisoryLock {
    var dir = try profileDir(profile_path);
    defer dir.close();
    return io_mod.acquireTimedAdvisoryLock(&dir, "mcp.lock", profile_lock_deadline_ms);
}

/// Replaces the profile file durably, readable only by its owner.
pub fn replaceProfile(alloc: Allocator, profile_path: []const u8, text: []const u8) !void {
    var dir = try profileDir(profile_path);
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, std.Io.Dir.path.basename(profile_path), text);
}

fn profileDir(profile_path: []const u8) !io_mod.VerifiedDir {
    const parent = std.Io.Dir.path.dirname(profile_path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.Io.Dir.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.Io.Dir.path.basename(parent));
}

/// A project's `.mcp.json` is shared, so it keeps its mode.
fn write(alloc: Allocator, file: File, path: []const u8, text: []const u8) !void {
    switch (file) {
        .profile => try replaceProfile(alloc, path, text),
        .project => {
            // A link isn't replaced, which forks the file it points to, nor
            // followed, which could write outside the project.
            // The profile's own replace refuses one too.
            if (std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .sym_link or stat.nlink > 1) return error.Linked;
            } else |err| if (err != error.FileNotFound) return err;
            try io_mod.writeFileAtomic(alloc, path, text);
        },
    }
}

fn parse(a: Allocator, text: ?[]const u8) Error!json.Value {
    const t = text orelse return .{ .object = .empty };
    if (std.mem.trim(u8, t, " \t\r\n").len == 0) return .{ .object = .empty };
    return json.parseFromSliceLeaky(json.Value, a, t, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

fn serversOf(a: Allocator, file: File, root: *json.Value, create: bool) Error!?*json.ObjectMap {
    if (root.* != .object) return error.NotAnObject;
    const top = &root.object;
    const current = top.getPtr("mcpServers");
    const old = if (file == .profile) top.getPtr("mcp") else null;
    if (current != null and old != null) return error.BothKeys;
    const value = current orelse old orelse {
        if (!create) return null;
        try top.put(a, "mcpServers", .{ .object = .empty });
        return &top.getPtr("mcpServers").?.object;
    };
    if (value.* != .object) return error.NotAnObject;
    return &value.object;
}

fn entryValue(a: Allocator, entry: Entry) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    switch (entry) {
        .stdio => |s| {
            try object.put(a, "command", .{ .string = s.command });
            if (s.args.len > 0) {
                var args: json.Array = .init(a);
                for (s.args) |arg| try args.append(.{ .string = arg });
                try object.put(a, "args", .{ .array = args });
            }
            if (s.env.len > 0) try object.put(a, "env", try pairs(a, s.env));
        },
        .http => |h| {
            try object.put(a, "type", .{ .string = "http" });
            try object.put(a, "url", .{ .string = h.url });
            if (h.headers.len > 0) try object.put(a, "headers", try pairs(a, h.headers));
        },
    }
    return .{ .object = object };
}

fn pairs(a: Allocator, list: []const Pair) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    for (list) |p| try object.put(a, p.key, .{ .string = p.value });
    return .{ .object = object };
}

fn render(alloc: Allocator, root: json.Value) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const bad_entry: Entry = .{ .http = .{ .url = "http://example.com/mcp" } };
const good_entry: Entry = .{ .http = .{ .url = "https://mcp.example/mcp" } };
const authorized: Entry = .{ .http = .{ .url = "https://mcp.example/mcp", .headers = &.{.{ .key = "authorization", .value = "Bearer x" }} } };

/// The entry problem an `update` refused with, or a failed test: an edit that wasn't refused,
/// or was refused for a key, reads as a failure the test names, not a crash.
fn refusedEntry(updated: Updated) !project_config.EntryProblem {
    switch (updated) {
        .refused => |refusal| switch (refusal) {
            .entry => |problem| return problem,
            .misspelled => {},
        },
        else => {},
    }
    return error.TestUnexpectedResult;
}

/// The misspelled key an `update` refused with, or a failed test.
fn refusedKey(updated: Updated) !project_config.MisspelledKey {
    switch (updated) {
        .refused => |refusal| switch (refusal) {
            .misspelled => |key| return key,
            .entry => {},
        },
        else => {},
    }
    return error.TestUnexpectedResult;
}

// The entries and files a fuzzed add draws from: addresses that load, that the
// reader skips for each reason it has, and headers and variables of every class.
const fuzz_schemes = [_][]const u8{ "https", "https", "http", "HTTP", "ftp", "" };
const fuzz_hosts = [_][]const u8{ "x.example", "localhost", "localhost.", "127.0.0.1", "127.0.0.2", "[::1]", "", "x y", "u:p@x.example", "u@localhost" };
const fuzz_ports = [_][]const u8{ "", "", ":80", ":8080", ":0", ":99999", ":" };
const fuzz_tails = [_][]const u8{ "/mcp", "/mcp", "", "/mcp#part", "?a=1" };
const fuzz_header_names = [_][]const u8{ "X-A", "x-a", "Authorization", "authorization", "Host", "Mcp-Param-X", "Bad Header", "" };
const fuzz_values = [_][]const u8{ "1", "", "${X}", "${", "${1X}", "${X:-d}", "a\x01b" };
const fuzz_commands = [_][]const u8{ "node", "", "x y", "${C}", "${" };
const fuzz_env_names = [_][]const u8{ "K", "1X", "BAD NAME", "" };
const fuzz_names = [_][]const u8{ "a", "web", "x-1", "s_2" };
const fuzz_typo_keys = [_][]const u8{ "servers", "mcp_servers", "MCP-Servers", "mcpserver", "ModelContextProtocol", "notes", "mcp" };

/// A profile or `.mcp.json` text: some unrelated top-level keys, the real
/// servers key (or none), and a key that may or may not be a misspelling.
fn fuzzBefore(a: Allocator, smith: *std.testing.Smith) Allocator.Error!?[]const u8 {
    if (smith.valueRangeAtMost(u8, 0, 5) == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '{');
    var first = true;
    const fillers = smith.valueRangeAtMost(u8, 0, 80);
    for (0..fillers) |i| {
        if (!first) try out.append(a, ',');
        first = false;
        try out.print(a, "\"note{d}\":{d}", .{ i, i });
    }
    const real = smith.valueRangeAtMost(u8, 0, 3);
    if (real != 0) {
        if (!first) try out.append(a, ',');
        first = false;
        const key: []const u8 = if (real == 3) "mcp" else "mcpServers";
        try out.print(a, "\"{s}\":{{\"old\":{{\"command\":\"x\"}}}}", .{key});
    }
    if (smith.value(bool)) {
        if (!first) try out.append(a, ',');
        const key = fuzz_typo_keys[smith.index(fuzz_typo_keys.len)];
        // Servers, or entries that aren't servers first: the load scan gives up on a wide one.
        const junk = smith.valueRangeAtMost(u8, 0, 70);
        try out.print(a, "\"{s}\":{{", .{key});
        for (0..junk) |i| try out.print(a, "\"n{d}\":{d},", .{ i, i });
        try out.appendSlice(a, "\"real\":{\"command\":\"y\"}}");
    }
    try out.append(a, '}');
    return out.items;
}

fn fuzzEntry(a: Allocator, smith: *std.testing.Smith) Allocator.Error!Entry {
    if (smith.value(bool)) {
        const url = try a.print("{s}://{s}{s}{s}", .{
            fuzz_schemes[smith.index(fuzz_schemes.len)],
            fuzz_hosts[smith.index(fuzz_hosts.len)],
            fuzz_ports[smith.index(fuzz_ports.len)],
            fuzz_tails[smith.index(fuzz_tails.len)],
        });
        const count = smith.valueRangeAtMost(u8, 0, 3);
        const headers = try a.alloc(Pair, count);
        for (headers) |*h| h.* = .{
            .key = fuzz_header_names[smith.index(fuzz_header_names.len)],
            .value = fuzz_values[smith.index(fuzz_values.len)],
        };
        return .{ .http = .{ .url = url, .headers = headers } };
    }
    const args = try a.alloc([]const u8, smith.valueRangeAtMost(u8, 0, 2));
    for (args) |*arg| arg.* = fuzz_values[smith.index(fuzz_values.len)];
    const env = try a.alloc(Pair, smith.valueRangeAtMost(u8, 0, 2));
    for (env) |*pair| pair.* = .{
        .key = fuzz_env_names[smith.index(fuzz_env_names.len)],
        .value = fuzz_values[smith.index(fuzz_values.len)],
    };
    return .{ .stdio = .{ .command = fuzz_commands[smith.index(fuzz_commands.len)], .args = args, .env = env } };
}

/// Writes `text` into `tmp` at `sub_path`, with the folders above it. A test's own
/// write: no sync, so a fuzzed run stays quick.
fn writeTempFile(tmp: *testing.TmpDir, sub_path: []const u8, text: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io_mod.getIo(), parent);
    var f = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer f.close(io_mod.getIo());
    try f.writeStreamingAll(io_mod.getIo(), text);
}

/// Whether spark's own loaders load `name` from `text`, written where they read it: the
/// profile through `loadNativeConfigs`, which spark runs at start (with a folder of its
/// own as HOME), and a project's `.mcp.json` through `workspace_config.load`, with
/// the server approved. A server held back only for a variable that isn't set counts
/// as loaded: the loader says why in a note, and `add` saves such a server.
fn runtimeLoads(a: Allocator, file: File, text: []const u8, name: []const u8) !bool {
    const builtin_mcp = @import("../../builtins/mcp.zig");
    const workspace_config = @import("../mcp/workspace_config.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(a, tmp.dir, ".");
    switch (file) {
        .profile => {
            try writeTempFile(&tmp, ".spark/mcp.json", text);
            try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
            const workspace = try std.Io.Dir.path.join(a, &.{ root, "workspace" });
            var environment = std.process.Environ.Map.init(a);
            try environment.put("HOME", root);
            io_mod.setEnvironMap(&environment);
            defer io_mod.resetEnvironForTest();
            var loaded = builtin_mcp.loadNativeConfigs(a, workspace) catch return false;
            defer loaded.deinit(a);
            // `loadHost` expands the variables of what was loaded, as it starts the host, and drops an entry whose variable isn't valid.
            var inherited = try io_mod.cloneEnvironMap(a);
            defer inherited.deinit();
            try project_config.expandProfileConfigs(a, &loaded.configs, &loaded.diagnostics, &inherited);
            return loadedOrHeld(loaded.configs.items, loaded.diagnostics.items, name);
        },
        .project => {
            try writeTempFile(&tmp, ".mcp.json", text);
            var approved = [_][]u8{@constCast(name)};
            var result = workspace_config.load(a, root, .workspace, .{ .approved = &approved }) catch return false;
            defer result.deinit(a);
            return loadedOrHeld(result.configs.items, result.diagnostics.items, name);
        },
    }
}

/// `configs` are the loader's servers and `diagnostics` its notes.
fn loadedOrHeld(configs: anytype, diagnostics: []const project_config.WorkspaceDiagnostic, name: []const u8) bool {
    for (configs) |c| if (std.mem.eql(u8, c.name, name)) return true;
    for (diagnostics) |d| {
        const named = if (d.server_name) |n| std.mem.eql(u8, n, name) else false;
        if (named and d.cause == .missing_environment_variable) return true;
    }
    return false;
}

fn fuzzAddReaderAgree(_: void, smith: *std.testing.Smith) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: File = if (smith.value(bool)) .profile else .project;
    const name = fuzz_names[smith.index(fuzz_names.len)];
    const before = try fuzzBefore(a, smith);
    const entry = try fuzzEntry(a, smith);
    // A file add refuses on its own (not JSON, both keys, a name that is there) has nothing to check.
    const after = add(a, file, before, name, entry) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    // Whatever add writes is JSON, and it keeps what was there.
    const written = try std.json.parseFromSliceLeaky(std.json.Value, a, after, .{});
    try testing.expect(written == .object);
    if (before) |text| {
        const old = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        var keys = old.object.iterator();
        while (keys.next()) |key| try testing.expect(written.object.contains(key.key_ptr.*));
    }

    // The reader's check against spark's own loaders: it refuses an entry exactly when they
    // would skip it (a refusal for a misspelled key says nothing of the entry).
    const refusal = try refusalOf(a, file, before, after, name);
    const loads = try runtimeLoads(a, file, after, name);
    const refused_entry = if (refusal) |why| why == .entry else false;
    if ((refused_entry and loads) or (refusal == null and !loads)) {
        std.debug.print("{s}: add {s} {s}, and spark's loader {s} it\nbefore: {?s}\nafter: {s}\n", .{
            @tagName(file),
            name,
            if (refusal) |why| (if (why == .entry) @tagName(why.entry) else "was refused for a misspelled key") else "was accepted",
            if (loads) "loads" else "skips",
            before,
            after,
        });
        return error.TestUnexpectedResult;
    }
    // No misspelled key is left for the next edit to find.
    if (refusal == null and file == .profile) try testing.expect(try project_config.misspelledKey(a, after) == null);
    // The load path's bounded scan never finds a misspelling the edit's complete scan misses.
    if (before) |text| {
        var bounded = project_config.parseProfileDocument(a, text) catch return;
        defer bounded.deinit(a);
        if (bounded.diagnostic) |d| {
            if (d.cause == .suspicious_server_key) try testing.expect(try project_config.misspelledKey(a, text) != null);
        }
    }
}
