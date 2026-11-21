const std = @import("std");
const builtin = @import("builtin");
const file_picker_path = @import("../input/file_picker_path.zig");
const file_index = @import("file_index.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const QueryMode = enum {
    workspace_index,
    explicit_path,
};

pub const Error = error{
    NoSpaceLeft,
    PathUnavailable,
};

const ParsedQuery = struct {
    parent: []const u8,
    display_prefix: []const u8,
    basename_query: []const u8,
};

pub fn queryMode(query: []const u8) QueryMode {
    return if (parseExplicitQuery(query) != null) .explicit_path else .workspace_index;
}

pub fn complete(
    workspace_root: []const u8,
    query: []const u8,
    out: []file_index.SearchResult,
    match_spans: []file_index.MatchSpan,
    path_storage: []u8,
) Error!usize {
    return completeCancellable(workspace_root, io_mod.homeDir(), query, null, out, match_spans, path_storage) catch |err| switch (err) {
        error.Cancelled => unreachable,
        else => |failure| return failure,
    };
}

/// Blocking directory operation. Inputs and output storage belong to the caller;
/// cancellation is cooperative and cannot interrupt an in-flight filesystem call.
pub fn completeCancellable(
    workspace_root: []const u8,
    home_dir: ?[]const u8,
    query: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    out: []file_index.SearchResult,
    match_spans: []file_index.MatchSpan,
    path_storage: []u8,
) (Error || error{Cancelled})!usize {
    try checkCancellation(cancel);
    if (out.len == 0) return 0;
    const parsed = parseExplicitQuery(query) orelse return 0;
    const matcher = file_index.NameQuery.init(parsed.basename_query) orelse return 0;
    var scores: [file_index.max_search_results]file_index.NameQuery.Score = undefined;
    const slot_len: usize = file_index.max_path_len;
    if (out.len > scores.len or out.len > path_storage.len / slot_len) return error.NoSpaceLeft;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    try checkCancellation(cancel);
    const resolved = pathing.resolve_workspace_or_external_literal_path_with_home(
        resolve_fba.allocator(),
        workspace_root,
        parsed.parent,
        home_dir,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.NoSpaceLeft,
        else => return error.PathUnavailable,
    };

    const io = io_mod.getIo();
    try checkCancellation(cancel);
    var dir = std.Io.Dir.openDirAbsolute(io, resolved, .{ .iterate = true }) catch return error.PathUnavailable;
    defer dir.close(io);

    // Listing a folder's contents: the folder itself is the first row, so it
    // can be selected and not only opened.
    const folder = listedFolder(parsed);
    const reserved: usize = @intFromBool(folder != null);
    const entries = out[reserved..];
    const entry_storage = path_storage[reserved * slot_len ..];

    var count: usize = 0;
    var iterator = dir.iterate();
    while (true) {
        try checkCancellation(cancel);
        const entry = (iterator.next(io) catch return error.PathUnavailable) orelse break;
        try checkCancellation(cancel);
        if (!text_utils.isTerminalSafe(entry.name)) continue;
        const score = matcher.score(entry.name) orelse continue;
        // candidateKind may stat symlinks or unknown kinds.
        try checkCancellation(cancel);
        const kind = candidateKind(&dir, entry.name, entry.kind) orelse continue;

        var candidate_storage: [file_index.max_path_len]u8 = undefined;
        const candidate_len = parsed.display_prefix.len + entry.name.len;
        if (candidate_len > candidate_storage.len) continue;
        @memcpy(candidate_storage[0..parsed.display_prefix.len], parsed.display_prefix);
        @memcpy(candidate_storage[parsed.display_prefix.len..candidate_len], entry.name);
        const candidate = candidate_storage[0..candidate_len];
        if (!text_utils.isTerminalSafe(candidate)) continue;
        if (!file_picker_path.isRepresentable(candidate)) continue;
        count = insertCandidate(entries, entry_storage, &scores, &matcher, count, candidate, kind, score);
    }

    var spans_used: usize = 0;
    for (entries[0..count]) |*result| {
        try checkCancellation(cancel);
        const span_count = matcher.match_spans(result.path[parsed.display_prefix.len..], match_spans[spans_used..]) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.InvalidIndexData => return error.PathUnavailable,
        };
        const spans = match_spans[spans_used..][0..span_count];
        for (spans) |*span| {
            span.byte_start += @intCast(parsed.display_prefix.len);
            span.byte_end += @intCast(parsed.display_prefix.len);
        }
        result.matched_spans = spans;
        spans_used += span_count;
    }
    if (folder) |path| {
        const slot = pathSlot(path_storage, 0);
        @memcpy(slot[0..path.len], path);
        out[0] = .{ .path = slot[0..path.len], .kind = .directory, .matched_spans = &.{} };
    }
    try checkCancellation(cancel);
    return reserved + count;
}

/// The folder whose contents a query lists (`src/` lists `src`, `~` lists
/// `~`), or null when the query names a partial entry or the root.
fn listedFolder(parsed: ParsedQuery) ?[]const u8 {
    if (parsed.basename_query.len != 0) return null;
    const prefix = parsed.display_prefix;
    if (prefix.len < 2 or !std.Io.Dir.path.isSep(prefix[prefix.len - 1])) return null;
    const folder = prefix[0 .. prefix.len - 1];
    if (std.Io.Dir.path.isSep(folder[folder.len - 1])) return null;
    if (!text_utils.isTerminalSafe(folder) or !file_picker_path.isRepresentable(folder)) return null;
    return folder;
}

fn checkCancellation(cancel: ?*const std.atomic.Value(bool)) error{Cancelled}!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
}

pub fn isCurrentCandidateKind(
    workspace_root: []const u8,
    path: []const u8,
    expected_kind: file_index.CandidateKind,
) bool {
    if (!text_utils.isTerminalSafe(path)) return false;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    const resolved = pathing.resolve_workspace_or_external_literal_path(
        resolve_fba.allocator(),
        workspace_root,
        path,
    ) catch return false;
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        resolved,
        .{ .follow_symlinks = true },
    ) catch return false;
    return kindMatchesStat(expected_kind, stat.kind);
}

fn parseExplicitQuery(query: []const u8) ?ParsedQuery {
    inline for (.{ "~", ".", ".." }) |shortcut| {
        if (std.mem.eql(u8, query, shortcut)) return .{
            .parent = query,
            .display_prefix = shortcut ++ "/",
            .basename_query = "",
        };
    }
    var separator_index: ?usize = null;
    for (query, 0..) |byte, index| {
        if (std.Io.Dir.path.isSep(byte)) separator_index = index;
    }
    const separator = separator_index orelse return null;
    const parent = if (separator == 0) query[0..1] else query[0..separator];
    return .{
        .parent = parent,
        .display_prefix = query[0 .. separator + 1],
        .basename_query = query[separator + 1 ..],
    };
}

fn candidateKind(
    dir: *std.Io.Dir,
    name: []const u8,
    observed_kind: std.Io.File.Kind,
) ?file_index.CandidateKind {
    return switch (observed_kind) {
        .file => .file,
        .directory => .directory,
        .sym_link, .unknown => {
            const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = true }) catch return null;
            return kindFromStat(stat.kind);
        },
        else => null,
    };
}

fn kindFromStat(kind: std.Io.File.Kind) ?file_index.CandidateKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        else => null,
    };
}

fn kindMatchesStat(expected: file_index.CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file,
        .directory => actual == .directory,
    };
}

fn insertCandidate(
    out: []file_index.SearchResult,
    path_storage: []u8,
    scores: []file_index.NameQuery.Score,
    matcher: *const file_index.NameQuery,
    count: usize,
    path: []const u8,
    kind: file_index.CandidateKind,
    score: file_index.NameQuery.Score,
) usize {
    var insertion_index: usize = 0;
    while (insertion_index < count and !matcher.better(score, path, scores[insertion_index], out[insertion_index].path)) : (insertion_index += 1) {}
    if (insertion_index >= out.len) return count;

    const next_count = @min(count + 1, out.len);
    var index = next_count - 1;
    while (index > insertion_index) : (index -= 1) {
        const previous = out[index - 1];
        scores[index] = scores[index - 1];
        const slot = pathSlot(path_storage, index);
        @memcpy(slot[0..previous.path.len], previous.path);
        out[index] = .{
            .path = slot[0..previous.path.len],
            .kind = previous.kind,
            .matched_spans = &.{},
        };
    }

    const slot = pathSlot(path_storage, insertion_index);
    scores[insertion_index] = score;
    @memcpy(slot[0..path.len], path);
    out[insertion_index] = .{
        .path = slot[0..path.len],
        .kind = kind,
        .matched_spans = &.{},
    };
    return next_count;
}

fn pathSlot(storage: []u8, index: usize) []u8 {
    const slot_len: usize = file_index.max_path_len;
    const start = index * slot_len;
    return storage[start .. start + slot_len];
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    file.close(std.testing.io);
}

test "path completion classifies and splits only path-shaped queries" {
    try std.testing.expectEqual(QueryMode.workspace_index, queryMode("main"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("~"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("~/Dow"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("/tmp/fi"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("./src/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("../shared/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("src/core/"));

    const parsed = parseExplicitQuery("../shared/na").?;
    try std.testing.expectEqualStrings("../shared", parsed.parent);
    try std.testing.expectEqualStrings("../shared/", parsed.display_prefix);
    try std.testing.expectEqualStrings("na", parsed.basename_query);
}
