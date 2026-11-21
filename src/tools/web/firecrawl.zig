//! The `web_search` tool's backend: a Firecrawl server's `/v2/search`. The
//! server's URL can be set in `~/.spark/web_search.json` as `firecrawl_url`.
//! Requests run through `curl` so each one has a hard time limit.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const json_decode = @import("../../core/shared/json_decode.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const web_search_contract = @import("../../core/tooling/web_search_contract.zig");

const Allocator = std.mem.Allocator;

pub const default_url = "https://firecrawl.nzlinix.com";
pub const config_file_name = "web_search.json";
const max_results = 8;
const max_response_bytes = 4 * 1024 * 1024;
/// How long one search may take.
pub const search_timeout_s = 60;

pub const Config = struct {
    url: []const u8 = default_url,
};

const FileShape = struct {
    firecrawl_url: ?[]const u8 = null,
};

/// Reads `~/.spark/web_search.json`; a missing or broken file means the
/// defaults. Strings live in `arena`.
pub fn load(arena: Allocator) Config {
    const home = io_mod.homeDir() orelse return .{};
    const path = profile_paths.rootPath(arena, home, &.{config_file_name}) catch return .{};
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return .{};
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(arena, &file, 64 * 1024) catch return .{};
    const shape = json_decode.parseFromSliceLeaky(FileShape, arena, text, .{ .ignore_unknown_fields = true }) catch return .{};
    var config: Config = .{};
    if (shape.firecrawl_url) |url| if (url.len > 0) {
        config.url = url;
    };
    return config;
}

const Hit = struct {
    url: []const u8 = "",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

const ResponseShape = struct {
    success: bool = false,
    @"error": ?[]const u8 = null,
    data: ?std.json.Value = null,
};

/// Searches Firecrawl and returns the results in the web search contract's
/// shape. Everything lives in `arena`.
pub fn search(
    arena: Allocator,
    base_url: []const u8,
    query: []const u8,
    allowed_domains: ?[]const []const u8,
    blocked_domains: ?[]const []const u8,
    timeout_s: u32,
) !web_search_contract.Output {
    const started = io_mod.milliTimestamp();
    var full_query: std.ArrayList(u8) = .empty;
    try full_query.appendSlice(arena, query);
    if (allowed_domains) |domains| for (domains, 0..) |domain, i| {
        if (domain.len == 0) continue;
        try full_query.appendSlice(arena, if (i == 0) " (site:" else " OR site:");
        try full_query.appendSlice(arena, domain);
        if (i + 1 == domains.len) try full_query.append(arena, ')');
    };
    if (blocked_domains) |domains| for (domains) |domain| {
        if (domain.len == 0) continue;
        try full_query.appendSlice(arena, " -site:");
        try full_query.appendSlice(arena, domain);
    };
    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .query = full_query.items, .limit = max_results }, .{}, &body.writer);

    const endpoint = try arena.print("{s}/v2/search", .{std.mem.trimEnd(u8, base_url, "/")});
    const max_time = try arena.print("{d}", .{timeout_s});
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ "curl", "-sS", "--fail-with-body", "-m", max_time, "-X", "POST", endpoint, "-H", "content-type: application/json", "--data-binary", body.written() },
        .stdout_limit = .limited(max_response_bytes),
    }) catch return error.FirecrawlUnavailable;
    switch (result.term) {
        .exited => |code| if (code == 28) return error.FirecrawlTimedOut else if (code != 0) return error.FirecrawlFailed,
        else => return error.FirecrawlFailed,
    }
    const parsed = json_decode.parseFromSliceLeaky(ResponseShape, arena, result.stdout, .{ .ignore_unknown_fields = true }) catch return error.FirecrawlBadResponse;
    if (!parsed.success) return error.FirecrawlFailed;
    // v2 puts web results under `data.web`; v1 returned `data` as the list.
    const list: std.json.Value = blk: {
        const data = parsed.data orelse return error.FirecrawlBadResponse;
        if (data == .array) break :blk data;
        if (data == .object) if (data.object.get("web")) |web| break :blk web;
        return error.FirecrawlBadResponse;
    };
    if (list != .array) return error.FirecrawlBadResponse;

    var sources: std.ArrayList(web_search_contract.Source) = .empty;
    var summary: std.ArrayList(u8) = .empty;
    for (list.array.items) |item| {
        const hit = std.json.parseFromValueLeaky(Hit, arena, item, .{ .ignore_unknown_fields = true }) catch continue;
        if (hit.url.len == 0) continue;
        const title = if (hit.title) |t| (if (t.len > 0) t else hit.url) else hit.url;
        try sources.append(arena, .{ .title = title, .url = hit.url });
        if (hit.description) |description| if (description.len > 0) {
            try summary.print(arena, "- {s}: {s}\n", .{ title, description });
        };
    }
    var results: std.ArrayList(web_search_contract.ResultItem) = .empty;
    if (summary.items.len > 0) try results.append(arena, .{ .commentary = summary.items });
    try results.append(arena, .{ .search = .{ .tool_use_id = "firecrawl", .content = sources.items } });
    return .{
        .query = query,
        .results = results.items,
        .duration_ms = @intCast(@max(0, io_mod.milliTimestamp() - started)),
        .web_search_requests = 1,
    };
}
