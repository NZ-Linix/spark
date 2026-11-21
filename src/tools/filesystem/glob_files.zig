const std = @import("std");
const builtin = @import("builtin");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const io_mod = @import("../../core/shared/io.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const tool_files = @import("../../core/workspace/tool_files.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

const OutputMode = enum {
    matches,
    count,
};

/// Typed input for the built-in glob_files tool.
pub const Input = struct {
    pattern: []u8,
    path: []u8,
    mode: OutputMode = .matches,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        self.* = .{ .pattern = &.{}, .path = &.{}, .mode = .matches };
    }
};

/// Decodes glob_files JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "glob_files" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    const pattern = args.requiredString(object, "pattern") catch |err| return .{ .failure = try args.takeFailure(err) };
    const path_string = args.optionalString(object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };
    const raw_mode = args.optionalString(object, "mode") catch |err| return .{ .failure = try args.takeFailure(err) };
    const mode: OutputMode = if (raw_mode) |raw| std.meta.stringToEnum(OutputMode, raw) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"mode\" must be one of matches, count") };
    } else .matches;

    const owned_pattern = try ctx.allocator.dupe(u8, pattern);
    errdefer ctx.allocator.free(owned_pattern);
    const effective_path = if (path_string) |path|
        if (path.len == 0) "." else path
    else
        ".";
    const owned_path = try ctx.allocator.dupe(u8, effective_path);
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .mode = mode,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// Searches the resolved root and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithWorkspaceOptions(ctx, erased, .{});
}

fn callWithWorkspaceOptions(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, list_options: tool_files.Options) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    // The scan and the per-call work use the scratch allocator, so each search
    // returns its memory when it ends; only the result body comes from
    // `ctx.allocator`.
    var arena_state = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();

    const requested_root = resolveSearchRoot(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", input.path, err) };
        }
        return .{ .failure = try ctx.allocator.print("Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };
    const static_base = if (requested_root.is_directory)
        extractStaticGlobBase(input.pattern)
    else
        StaticGlobBase{ .base = "", .pattern = input.pattern };
    const maybe_root = if (requested_root.is_directory)
        resolveStaticBaseRoot(arena, requested_root.absolute, static_base.base) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", requested_root.absolute, err) };
            }
            return .{ .failure = try ctx.allocator.print("Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
        }
    else
        requested_root;
    const root = maybe_root orelse {
        if (input.mode == .count) {
            return .{ .success = try formatCount(ctx.allocator, input.pattern, 0, .{}) };
        }
        return .{ .success = try formatMatches(ctx.allocator, input.pattern, &.{}, false, .{}, ctx.max_list_entries) };
    };
    const root_relative = try pathing.workspaceRelativePath(arena, ctx.workspace_root, root.absolute);
    var compiled_pattern = glob_pattern.Pattern.compile(arena, static_base.pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PatternTooLong => return .{ .failure = try ctx.allocator.print("glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
    };
    defer compiled_pattern.deinit(arena);

    var matches: std.ArrayList([]u8) = .empty;
    defer matches.deinit(arena);
    var match_count: usize = 0;
    var output_truncated = false;
    var completeness: tool_files.Completeness = .{};
    var options = list_options;
    options.skipped_names = ctx.ignored_list_entries;
    options.include_hidden = options.include_hidden or shouldIncludeHidden(root_relative, input.pattern);

    if (root.is_directory) {
        const listing = tool_files.list(ctx.scratch_allocator, arena, ctx.workspace_root, root.absolute, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return .{ .failure = try ctx.allocator.print("Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) },
        };
        const candidate_files = listing.files;
        completeness = .of(listing);

        for (candidate_files) |candidate| {
            if (!compiled_pattern.matchesPath(candidate)) continue;

            match_count += 1;
            if (input.mode == .count) continue;

            if (matches.items.len >= ctx.max_list_entries) {
                output_truncated = true;
                break;
            }

            try matches.append(arena, try joinRelativeSearchPath(arena, root_relative, candidate));
        }
    } else {
        const basename = std.Io.Dir.path.basename(root_relative);
        if (compiled_pattern.matchesPath(basename)) {
            match_count += 1;
            if (input.mode == .matches) {
                try matches.append(arena, try arena.dupe(u8, root_relative));
            }
        }
    }

    if (input.mode == .count) {
        return .{ .success = try formatCount(ctx.allocator, input.pattern, match_count, completeness) };
    }
    return .{ .success = try formatMatches(ctx.allocator, input.pattern, matches.items, output_truncated, completeness, ctx.max_list_entries) };
}

fn formatCount(
    alloc: Allocator,
    pattern: []const u8,
    match_count: usize,
    completeness: tool_files.Completeness,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[glob] count {d} matches for {s}\n", .{ match_count, pattern }) catch return error.OutOfMemory;
    try completeness.writeNotes(&out.writer);
    return try out.toOwnedSlice();
}

fn formatMatches(
    alloc: Allocator,
    pattern: []const u8,
    matches: []const []const u8,
    output_truncated: bool,
    completeness: tool_files.Completeness,
    max_list_entries: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (matches.len == 0) {
        out.writer.print("[glob] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
        try completeness.writeNotes(&out.writer);
        return try out.toOwnedSlice();
    }

    out.writer.print("[glob] {d} matches for {s}\n", .{ matches.len, pattern }) catch return error.OutOfMemory;
    for (matches) |match| {
        out.writer.print(" - {s}\n", .{match}) catch return error.OutOfMemory;
    }
    if (output_truncated) {
        out.writer.print("... truncated to first {d} matches\n", .{max_list_entries}) catch return error.OutOfMemory;
    }
    try completeness.writeNotes(&out.writer);

    return try out.toOwnedSlice();
}

const SearchRoot = struct {
    absolute: []const u8,
    is_directory: bool,
};

fn resolveSearchRoot(arena: Allocator, workspace_root: []const u8, requested: []const u8) !SearchRoot {
    const absolute = try pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, requested);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return .{ .absolute = absolute, .is_directory = false },
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

fn resolveStaticBaseRoot(arena: Allocator, requested_root: []const u8, static_base: []const u8) !?SearchRoot {
    if (static_base.len == 0 or std.mem.eql(u8, static_base, ".")) {
        return .{ .absolute = requested_root, .is_directory = true };
    }
    const absolute = pathing.resolveWorkspacePath(arena, requested_root, static_base, .existing) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return null,
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

const StaticGlobBase = struct {
    base: []const u8,
    pattern: []const u8,
};

fn extractStaticGlobBase(pattern: []const u8) StaticGlobBase {
    const first_glob = firstGlobChar(pattern) orelse {
        const dirname = std.Io.Dir.path.dirname(pattern) orelse return .{ .base = "", .pattern = pattern };
        return .{ .base = dirname, .pattern = std.Io.Dir.path.basename(pattern) };
    };
    const static_prefix = pattern[0..first_glob];
    const last_sep = lastPathSeparator(static_prefix) orelse return .{ .base = "", .pattern = pattern };
    if (last_sep == 0 and isPathSeparator(static_prefix[0])) {
        return .{ .base = static_prefix[0..1], .pattern = pattern[1..] };
    }
    return .{ .base = static_prefix[0..last_sep], .pattern = pattern[last_sep + 1 ..] };
}

fn firstGlobChar(pattern: []const u8) ?usize {
    for (pattern, 0..) |ch, index| {
        switch (ch) {
            '*', '?', '[', '{' => return index,
            else => {},
        }
    }
    return null;
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (isPathSeparator(path[index])) return index;
    }
    return null;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn joinRelativeSearchPath(arena: Allocator, root_relative: []const u8, child_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) {
        return arena.dupe(u8, child_relative);
    }
    return std.Io.Dir.path.join(arena, &.{ root_relative, child_relative });
}

fn shouldIncludeHidden(root_relative: []const u8, pattern: []const u8) bool {
    return tool_files.pathContainsHiddenDirectoryComponent(root_relative) or patternContainsHiddenDirectoryComponent(pattern);
}

fn patternContainsHiddenDirectoryComponent(pattern: []const u8) bool {
    return tool_files.pathContainsHiddenDirectoryComponent(pattern);
}

/// Reports that glob_files only observes filesystem names and metadata.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that glob_files has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const glob_files_dispatch_tool = tool_dispatch.Tool{
    .name = "glob_files",
    .description = "Glob files dispatch test fixture.",
    .model_schema = .{
        .name = "glob_files",
        .description = "Glob files dispatch test fixture.",
    },
    .executor_kind = .glob_files,
    .activity_kind = .list,
    .permission_target_kind = .path_optional_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

fn expectDecodeFailure(args_json: []const u8, reason: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(reason, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectDecodeInput(args_json: []const u8, pattern: []const u8, input_path: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(pattern, input.pattern);
            try std.testing.expectEqualStrings(input_path, input.path);
        },
    }
}

fn globArgsJson(alloc: Allocator, pattern: []const u8, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGlobFiles(alloc: Allocator, workspace_root: []const u8, pattern: []const u8, maybe_path: ?[]const u8) !tool_dispatch.DispatchResult {
    const args = try globArgsJson(alloc, pattern, maybe_path);
    defer alloc.free(args);

    return dispatchGlobFilesRaw(alloc, workspace_root, args);
}

fn dispatchGlobFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{glob_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .permission_mode = .yolo,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "glob_files",
        .arguments_json = args_json,
    });
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn writeTempFileWithMtime(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    content: []const u8,
    mtime_ns: i96,
) ![]u8 {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    try file.setTimestamps(io_mod.getIo(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn createNumberedFiles(tmp: *std.testing.TmpDir, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{i});
        if (std.Io.Dir.path.dirname(name)) |parent| {
            try tmp.dir.createDirPath(io_mod.getIo(), parent);
        }
        {
            var file = try tmp.dir.createFile(std.testing.io, name, .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "x\n");
        }
    }
}

test "glob_files decodes invalid argument shapes as failures" {
    try expectDecodeFailure("{", "glob_files arguments must be valid JSON");
    try expectDecodeFailure("[]", "glob_files arguments must be an object");
    try expectDecodeFailure("{\"path\":\".\"}", "glob_files requires string field \"pattern\"");
    try expectDecodeFailure("{\"pattern\":1}", "glob_files field \"pattern\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"path\":1}", "glob_files field \"path\" must be a string");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"mode\":\"files\"}", "glob_files field \"mode\" must be one of matches, count");
    try expectDecodeFailure("{\"pattern\":\"*.zig\",\"mode\":true}", "glob_files field \"mode\" must be a string");
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}
