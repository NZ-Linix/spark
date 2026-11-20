//! `spark --convo FILE`: one conversation kept in one file. spark unpacks the
//! file into a private session store of its own, so the conversation never
//! joins `~/.spark/sessions` or `/resume`, saves the store back into the file
//! after every turn and on exit, and removes the store when it closes. The
//! same command opens the conversation again, on any machine.

const std = @import("std");
const commands = @import("../../builtins/commands.zig");
const cli_flags = @import("../cli/cli_flags.zig");
const io_mod = @import("../shared/io.zig");
const json_decode = @import("../shared/json_decode.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

const format_version = 1;
const max_file_bytes = 256 * 1024 * 1024;
const index_name = "index.jsonl";

const Bundle = struct {
    spark_convo: u32,
    session: []const u8,
    files: []const File,

    const File = struct { path: []const u8, data: []const u8 };
};

const State = struct {
    alloc: Allocator,
    /// The conversation file, absolute.
    file: []const u8,
    /// The private store spark uses instead of `~/.spark/sessions/v2`.
    root: []const u8,
    /// The session the file holds: the one loaded, then the last one saved.
    session: ?[]const u8 = null,
};

var active: ?State = null;

/// The private store when `--convo` is in use, read by the session store.
pub fn storeRoot() ?[]const u8 {
    return if (active) |s| s.root else null;
}

/// Finds `--convo FILE` in `args`. Returns FILE and writes the other
/// arguments to `rest`, or returns null when the flag is absent.
pub fn takeFlag(args: []const [:0]const u8, rest: [][:0]const u8, rest_len: *usize) error{ MissingConvoFile, TooManyArgs }!?[]const u8 {
    var file: ?[]const u8 = null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) {
        var parser = cli_flags.Parser.initPrefix(&.{commands.convo_option}, args[i..]);
        if (parser.next() catch return error.MissingConvoFile) |item| {
            file = item.option.value.?;
            i += parser.index;
            continue;
        }
        if (n >= rest.len) return error.TooManyArgs;
        rest[n] = args[i];
        n += 1;
        i += 1;
    }
    rest_len.* = n;
    return file;
}

/// Sets up the private store for `file` and unpacks it there when it exists.
/// Returns the id of the session it holds, or null for a new conversation.
pub fn start(alloc: Allocator, home: []const u8, file: []const u8) !?[]const u8 {
    const io = io_mod.getIo();
    const absolute = if (std.Io.Dir.path.isAbsolute(file)) try alloc.dupe(u8, file) else blk: {
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        break :blk try std.Io.Dir.path.join(alloc, &.{ cwd, file });
    };
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "{d}-{d}", .{ std.c.getpid(), io_mod.milliTimestamp() });
    const root = try profile_paths.rootPath(alloc, home, &.{ "convo", name, "v2" });
    try std.Io.Dir.cwd().createDirPath(io, root);
    active = .{ .alloc = alloc, .file = absolute, .root = root };

    var handle = std.Io.Dir.openFileAbsolute(io, absolute, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer handle.close(io);
    const text = try io_mod.readFileToEnd(alloc, &handle, max_file_bytes);
    defer alloc.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bundle = json_decode.parseFromSliceLeaky(Bundle, arena, text, .{ .ignore_unknown_fields = true }) catch return error.NotAConvoFile;
    if (bundle.spark_convo != format_version) return error.UnsupportedConvoVersion;
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    for (bundle.files) |entry| {
        if (!safeRelative(entry.path)) return error.NotAConvoFile;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(entry.data) catch return error.NotAConvoFile;
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, entry.data) catch return error.NotAConvoFile;
        if (std.Io.Dir.path.dirname(entry.path)) |parent| try root_dir.createDirPath(io, parent);
        try root_dir.writeFile(io, .{ .sub_path = entry.path, .data = bytes });
    }
    if (bundle.session.len == 0 or !safeRelative(bundle.session)) return null;
    // The store refuses folders and files others can read, and expects each
    // session's lock file.
    try root_dir.createDirPath(io, bundle.session);
    const lock_path = try std.Io.Dir.path.join(arena, &.{ bundle.session, "lock" });
    try root_dir.writeFile(io, .{ .sub_path = lock_path, .data = "" });
    try makePrivate(arena, root);
    if (std.Io.Dir.path.dirname(root)) |run_dir| try chmod(arena, run_dir, 0o700);
    active.?.session = try alloc.dupe(u8, bundle.session);
    return active.?.session;
}

/// Saves the store into the conversation file. `session` is the session on
/// screen, or null to keep the one saved last.
pub fn save(session: ?[]const u8) void {
    saveOrError(session) catch {};
}

fn saveOrError(session: ?[]const u8) !void {
    const state = &(active orelse return);
    const io = io_mod.getIo();
    if (session) |id| if (state.session == null or !std.mem.eql(u8, state.session.?, id)) {
        if (state.session) |old| state.alloc.free(old);
        state.session = try state.alloc.dupe(u8, id);
    };
    var arena_state = std.heap.ArenaAllocator.init(state.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root_dir = try std.Io.Dir.openDirAbsolute(io, state.root, .{ .iterate = true });
    defer root_dir.close(io);
    const id = state.session orelse (try newestSession(arena, root_dir)) orelse return;

    var files: std.ArrayList(Bundle.File) = .empty;
    // The index keeps only this session's lines, so the file holds one
    // conversation even after `/clear` started another.
    if (readAll(arena, root_dir, index_name)) |index| {
        var kept: std.ArrayList(u8) = .empty;
        var needle_buf: [128]u8 = undefined;
        const needle = try std.mem.print(&needle_buf, "\"id\":\"{s}\"", .{id});
        var lines = std.mem.splitScalar(u8, index, '\n');
        while (lines.next()) |line| if (std.mem.find(u8, line, needle) != null) {
            try kept.appendSlice(arena, line);
            try kept.append(arena, '\n');
        };
        try files.append(arena, .{ .path = index_name, .data = try encode(arena, kept.items) });
    }
    var session_dir = try root_dir.openDir(io, id, .{ .iterate = true });
    defer session_dir.close(io);
    var walker = try session_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        if (std.mem.eql(u8, item.basename, "lock") or std.mem.endsWith(u8, item.basename, ".lock")) continue;
        const data = readAll(arena, session_dir, item.path) orelse continue;
        try files.append(arena, .{
            .path = try std.Io.Dir.path.join(arena, &.{ id, item.path }),
            .data = try encode(arena, data),
        });
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(Bundle{ .spark_convo = format_version, .session = id, .files = files.items }, .{}, &out.writer);
    try io_mod.writeFileAtomic(arena, state.file, out.written());
}

/// Saves the file one last time and removes the private store.
pub fn finish() void {
    save(null);
    const state = active orelse return;
    const io = io_mod.getIo();
    // The store's parent is this run's own folder under `convo/`.
    if (std.Io.Dir.path.dirname(state.root)) |run_dir| std.Io.Dir.cwd().deleteTree(io, run_dir) catch {};
}

/// Gives every folder under `root`, and `root` itself, mode 0700 and every
/// file mode 0600.
fn makePrivate(arena: Allocator, root: []const u8) !void {
    const io = io_mod.getIo();
    try chmod(arena, root, 0o700);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |item| {
        const full = try std.Io.Dir.path.join(arena, &.{ root, item.path });
        try chmod(arena, full, if (item.kind == .directory) 0o700 else 0o600);
    }
}

fn chmod(arena: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const z = try arena.dupeSentinel(u8, path, 0);
    if (std.c.chmod(z, mode) != 0) return error.AccessDenied;
}

fn newestSession(arena: Allocator, root_dir: std.Io.Dir) !?[]const u8 {
    const io = io_mod.getIo();
    var it = root_dir.iterate();
    var best: ?[]const u8 = null;
    var best_size: u64 = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        const log_path = try std.Io.Dir.path.join(arena, &.{ entry.name, "log.jsonl" });
        const stat = root_dir.statFile(io, log_path, .{}) catch continue;
        if (best == null or stat.size > best_size) {
            best = try arena.dupe(u8, entry.name);
            best_size = stat.size;
        }
    }
    return best;
}

fn readAll(arena: Allocator, dir: std.Io.Dir, path: []const u8) ?[]u8 {
    const io = io_mod.getIo();
    var file = dir.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return io_mod.readFileToEnd(arena, &file, max_file_bytes) catch null;
}

fn encode(arena: Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

/// A path inside the store: relative, with no `..` or empty parts.
fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.findScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    }
    return true;
}

test "takeFlag finds --convo and keeps the other arguments" {
    var rest: [8][:0]const u8 = undefined;
    var n: usize = 0;
    const file = try takeFlag(&.{ "--model", "x", "--convo", "chat.spark" }, &rest, &n);
    try std.testing.expectEqualStrings("chat.spark", file.?);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(try takeFlag(&.{"ask"}, &rest, &n) == null);
    const repeated = try takeFlag(&.{ "--convo", "first.spark", "--convo=last.spark" }, &rest, &n);
    try std.testing.expectEqualStrings("last.spark", repeated.?);
    try std.testing.expectEqual(@as(usize, 0), n);

    try std.testing.expectError(error.MissingConvoFile, takeFlag(&.{"--convo"}, &rest, &n));
}

test "safeRelative refuses paths outside the store" {
    try std.testing.expect(safeRelative("abc/log.jsonl"));
    try std.testing.expect(!safeRelative("../x"));
    try std.testing.expect(!safeRelative("/etc/passwd"));
    try std.testing.expect(!safeRelative("a//b"));
}
