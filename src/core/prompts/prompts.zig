//! Custom system prompts. The user lists folders in `~/.spark/prompts.json`,
//! and every `.md` or `.txt` file in them is a prompt named after the file.
//! `/prompt <name>` makes that file the agent's whole system prompt: spark
//! sends it alone, without its own prompt, tool guidance, skill catalog, or
//! project rules. `/prompt default` goes back to spark's own.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const json_decode = @import("../shared/json_decode.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mod_registry = @import("../mods/registry.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const command = "/prompt";
pub const default_name = "default";
pub const config_file_name = "prompts.json";
pub const max_dirs = 32;
pub const max_prompts = 512;
pub const max_prompt_bytes = 256 * 1024;
const max_config_bytes = 64 * 1024;
const extensions = [_][]const u8{ ".md", ".txt" };

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
};

/// What `~/.spark/prompts.json` holds: the prompt folders, in order, and
/// the names of the prompts the user starred.
pub const Config = struct {
    dirs: []const []const u8 = &.{},
    starred: []const []const u8 = &.{},
};

/// Reads `~/.spark/prompts.json`. A missing file is an empty config. The
/// result belongs to `arena`.
pub fn loadConfig(arena: Allocator, home: []const u8) !Config {
    const path = try profile_paths.rootPath(arena, home, &.{config_file_name});
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(arena, &file, max_config_bytes);
    return parseConfig(arena, text);
}

/// The folders saved in `~/.spark/prompts.json`, in order. A missing file is
/// no folders. The result belongs to `arena`.
pub fn loadDirs(arena: Allocator, home: []const u8) ![]const []const u8 {
    return (try loadConfig(arena, home)).dirs;
}

fn parseConfig(arena: Allocator, text: []const u8) !Config {
    const parsed = try json_decode.parseFromSliceLeaky(Config, arena, text, .{ .ignore_unknown_fields = true });
    return .{
        .dirs = parsed.dirs[0..@min(parsed.dirs.len, max_dirs)],
        .starred = parsed.starred[0..@min(parsed.starred.len, max_prompts)],
    };
}

fn saveConfig(alloc: Allocator, home: []const u8, config: Config) !void {
    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const path = try profile_paths.rootPath(alloc, home, &.{config_file_name});
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

fn saveDirs(arena: Allocator, home: []const u8, dirs: []const []const u8) !void {
    var config = try loadConfig(arena, home);
    config.dirs = dirs;
    try saveConfig(arena, home, config);
}

pub fn isStarred(starred: []const []const u8, name: []const u8) bool {
    for (starred) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

/// Stars the prompt `name`, or unstars it when it is starred. Returns
/// whether it is starred now.
pub fn toggleStar(arena: Allocator, home: []const u8, name: []const u8) !bool {
    var config = try loadConfig(arena, home);
    var next: std.ArrayList([]const u8) = .empty;
    for (config.starred) |entry| {
        if (!std.mem.eql(u8, entry, name)) try next.append(arena, entry);
    }
    const starred = next.items.len == config.starred.len;
    if (starred) {
        if (next.items.len >= max_prompts) return error.TooManyStars;
        try next.append(arena, name);
    }
    config.starred = next.items;
    try saveConfig(arena, home, config);
    return starred;
}

pub const DirChange = enum { added, removed, unchanged };

/// Adds `raw` (absolute, `~/`, or relative to the working directory) to the
/// saved folders. The folder must exist. `resolved` is set to the stored
/// path, owned by `arena`.
pub fn addDir(arena: Allocator, home: []const u8, raw: []const u8, resolved: *[]const u8) !DirChange {
    const expanded = try expandHome(arena, home, raw);
    const real = try io_mod.realpathAlloc(arena, expanded);
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), real, .{});
    dir.close(io_mod.getIo());
    resolved.* = real;
    const dirs = try loadDirs(arena, home);
    for (dirs) |existing| if (std.mem.eql(u8, existing, real)) return .unchanged;
    if (dirs.len >= max_dirs) return error.TooManyDirs;
    const next = try arena.alloc([]const u8, dirs.len + 1);
    @memcpy(next[0..dirs.len], dirs);
    next[dirs.len] = real;
    try saveDirs(arena, home, next);
    return .added;
}

/// Removes `raw` from the saved folders, matching it as typed or resolved.
pub fn removeDir(arena: Allocator, home: []const u8, raw: []const u8, resolved: *[]const u8) !DirChange {
    const expanded = try expandHome(arena, home, raw);
    const real = io_mod.realpathAlloc(arena, expanded) catch expanded;
    resolved.* = real;
    const dirs = try loadDirs(arena, home);
    var next: std.ArrayList([]const u8) = .empty;
    for (dirs) |existing| {
        if (std.mem.eql(u8, existing, real) or std.mem.eql(u8, existing, expanded) or std.mem.eql(u8, existing, raw)) continue;
        try next.append(arena, existing);
    }
    if (next.items.len == dirs.len) return .unchanged;
    try saveDirs(arena, home, next.items);
    return .removed;
}

fn expandHome(arena: Allocator, home: []const u8, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "~")) return home;
    if (std.mem.startsWith(u8, raw, "~/")) return std.Io.Dir.path.join(arena, &.{ home, raw[2..] });
    return raw;
}

/// The name a file in a prompt folder is listed under, or null when it is
/// not a prompt: its path inside the folder without the extension, with
/// whitespace turned into `_` so the name is one word on the command line.
fn promptName(arena: Allocator, rel_path: []const u8) !?[]const u8 {
    const base = std.Io.Dir.path.basename(rel_path);
    if (base.len == 0 or base[0] == '.') return null;
    for (extensions) |ext| {
        if (base.len > ext.len and std.ascii.endsWithIgnoreCase(base, ext)) {
            const name = try arena.dupe(u8, rel_path[0 .. rel_path.len - ext.len]);
            for (name) |*byte| switch (byte.*) {
                ' ', '\t', '\r', '\n' => byte.* = '_',
                '\\' => byte.* = '/',
                else => {},
            };
            if (std.mem.eql(u8, name, default_name)) return null;
            return name;
        }
    }
    return null;
}

/// Every prompt in `dirs` and their subfolders, sorted by name. When two
/// folders hold the same name, the earlier folder wins. A folder that cannot
/// be read is skipped. The result belongs to `arena`.
pub fn list(arena: Allocator, dirs: []const []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    for (dirs) |dir_path| {
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io_mod.getIo());
        var walker = dir.walk(arena) catch continue;
        defer walker.deinit();
        while (walker.next(io_mod.getIo()) catch null) |item| {
            if (entries.items.len >= max_prompts) break;
            if (item.kind == .directory and item.basename.len > 0 and item.basename[0] == '.') {
                walker.leave(io_mod.getIo());
                continue;
            }
            if (item.kind != .file and item.kind != .sym_link) continue;
            const name = (try promptName(arena, item.path)) orelse continue;
            if (find(entries.items, name) != null) continue;
            try entries.append(arena, .{
                .name = name,
                .path = try std.Io.Dir.path.join(arena, &.{ dir_path, item.path }),
            });
        }
    }
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return entries.items;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The file's name without its extension, as menus show it.
pub fn displayName(entry: Entry) []const u8 {
    const file = std.Io.Dir.path.basename(entry.path);
    return file[0 .. std.mem.findScalarLast(u8, file, '.') orelse file.len];
}

pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

/// Reads a prompt file. The caller owns the result through `alloc`.
pub fn read(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .allow_directory = false });
    defer file.close(io_mod.getIo());
    if ((try file.stat(io_mod.getIo())).kind != .file) return error.NotRegularFile;
    return io_mod.readFileToEnd(alloc, &file, max_prompt_bytes);
}

/// The prompt an agent runs with in place of spark's system prompt, or none.
pub const Selected = struct {
    arena: ?std.heap.ArenaAllocator = null,
    name: []const u8 = default_name,
    /// The whole system prompt, or null for spark's own.
    text: ?[]const u8 = null,

    /// Takes ownership of nothing; copies `name` and `text`.
    pub fn set(self: *Selected, alloc: Allocator, name: []const u8, text: []const u8) !void {
        var next = std.heap.ArenaAllocator.init(alloc);
        errdefer next.deinit();
        const arena = next.allocator();
        const owned_name = try arena.dupe(u8, name);
        const owned_text = try arena.dupe(u8, text);
        self.deinit();
        self.* = .{ .arena = next, .name = owned_name, .text = owned_text };
    }

    pub fn deinit(self: *Selected) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

/// `/prompt`'s argument completions: `default` and every listed prompt.
/// Built when the input starts with `/prompt` and dropped when it no longer
/// does, so changes on disk appear the next time the menu opens.
pub const Completion = struct {
    entries: []const mod_registry.ArgumentCompletion = &.{},
    arena: ?std.heap.ArenaAllocator = null,
    attempted: bool = false,

    pub fn deinit(self: *Completion) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    /// Returns whether the footer needs repainting.
    pub fn refresh(self: *Completion, alloc: Allocator, input: []const u8, home: ?[]const u8, current: []const u8) bool {
        const typed = std.mem.trimStart(u8, input, " \t");
        const active = std.mem.startsWith(u8, typed, command) and
            (typed.len == command.len or typed[command.len] == ' ' or typed[command.len] == '\t');
        if (!active) {
            const had_entries = self.entries.len > 0;
            self.deinit();
            return had_entries;
        }
        if (self.attempted) return false;
        self.attempted = true;
        var next: std.heap.ArenaAllocator = .init(alloc);
        const entries = build(next.allocator(), home, current) catch |err| {
            next.deinit();
            debug_trace.logf("prompts", "prompt listing failed err={s}", .{@errorName(err)});
            return false;
        };
        if (self.arena) |*old| old.deinit();
        self.arena = next;
        self.entries = entries;
        return true;
    }

    fn build(arena: Allocator, home: ?[]const u8, current: []const u8) ![]const mod_registry.ArgumentCompletion {
        const config: Config = if (home) |h| try loadConfig(arena, h) else .{};
        const listed = try list(arena, config.dirs);
        var out: std.ArrayList(mod_registry.ArgumentCompletion) = try .initCapacity(arena, listed.len + 1);
        // Starred prompts come first, then spark's own, then the rest.
        for (listed) |entry| if (isStarred(config.starred, entry.name)) {
            out.appendAssumeCapacity(try completionFor(arena, entry, current, true));
        };
        out.appendAssumeCapacity(.{
            .full = command ++ " " ++ default_name,
            .label = if (std.mem.eql(u8, current, default_name)) "✓ Default" else "  Default",
            .description = "spark's own system prompt",
        });
        for (listed) |entry| if (!isStarred(config.starred, entry.name)) {
            out.appendAssumeCapacity(try completionFor(arena, entry, current, false));
        };
        return out.items;
    }

    fn completionFor(arena: Allocator, entry: Entry, current: []const u8, starred: bool) !mod_registry.ArgumentCompletion {
        const active = std.mem.eql(u8, current, entry.name);
        const folder = std.Io.Dir.path.dirname(entry.path) orelse "";
        return .{
            .full = try arena.print(command ++ " {s}", .{entry.name}),
            .label = try arena.print("{s}{f}{s}", .{ if (active) "✓ " else "  ", text_utils.terminalSafe(displayName(entry)), if (starred) " ★" else "" }),
            .description = try arena.print("{f}", .{text_utils.terminalSafe(std.Io.Dir.path.basename(folder))}),
        };
    }
};

pub const Command = union(enum) {
    show,
    select: []const u8,
    add_dir: []const u8,
    remove_dir: []const u8,
    invalid,
};

pub const usage = "usage: /prompt [<name>|default|dir add PATH|dir remove PATH]";

pub fn parseCommand(rest: []const u8) Command {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return .show;
    if (std.mem.startsWith(u8, trimmed, "dir ") or std.mem.startsWith(u8, trimmed, "dir\t")) {
        const after = std.mem.trimStart(u8, trimmed[4..], " \t");
        inline for (.{ .{ "add", "add_dir" }, .{ "remove", "remove_dir" } }) |verb| {
            if (std.mem.startsWith(u8, after, verb[0]) and after.len > verb[0].len and (after[verb[0].len] == ' ' or after[verb[0].len] == '\t')) {
                const path = std.mem.trim(u8, after[verb[0].len..], " \t");
                if (path.len == 0) return .invalid;
                return @unionInit(Command, verb[1], path);
            }
        }
        return .invalid;
    }
    if (std.mem.findAny(u8, trimmed, " \t") != null) return .invalid;
    return .{ .select = trimmed };
}
