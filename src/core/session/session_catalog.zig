const std = @import("std");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const session_summary_codec = @import("session_summary_codec.zig");
const text_utils = @import("../shared/text_utils.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");

const Allocator = std.mem.Allocator;

pub const Scope = enum {
    current_workspace,
    all_workspaces,
};

pub const LoadState = enum {
    loading,
    ready,
    failed,
};

pub const ResumeFailure = enum {
    open_elsewhere,
    being_updated,
    /// The session's custom connection changed or was removed in settings
    /// (`config_runtime.sessionConnectionNotice`).
    connection_changed,
    connection_removed,
    unavailable,
};

pub fn filteredCount(summaries: []const session_store.SessionSummary, query: []const u8) usize {
    return pickerFilter(summaries, null, query, .any).count();
}

pub fn summaryAt(
    summaries: []const session_store.SessionSummary,
    query: []const u8,
    display_index: usize,
) ?*const session_store.SessionSummary {
    return &summaries[pickerFilter(summaries, null, query, .any).at(display_index) orelse return null];
}

/// Which summaries a filter considers: every one, or only those the resume
/// picker can open.
const Candidates = enum { any, resumable };

/// The sessions the resume picker lists for `query` from newest-first
/// `summaries`, in `workspace_root` or every workspace when it is null,
/// kept in their order (`fuzzy_match.Filter`): the ones that match as typed
/// when any does, and otherwise every match.
pub fn pickerFilter(
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    candidates: Candidates,
) fuzzy_match.Filter(PickerMatches) {
    return .init(.{ .summaries = summaries, .workspace_root = workspace_root, .query = query, .candidates = candidates }, summaries.len);
}

const PickerMatches = struct {
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    candidates: Candidates,

    pub fn matchAt(self: PickerMatches, position: usize) ?fuzzy_match.Match {
        const summary = self.summaries[position];
        if (self.workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse return null;
            if (!std.mem.eql(u8, summary_workspace, root)) return null;
        }
        if (self.candidates == .resumable and !summary.hasResumableContent()) return null;
        return sessionMatch(summary, self.query);
    }
};

/// One resume picker page from newest-first `summaries`: up to `limit` that
/// the picker lists for `query` in `workspace_root`, after `continuation`.
/// `has_more` is set only when another listed summary follows, so loading
/// more always has a match to show. Caller owns the returned page.
pub fn resumablePage(
    alloc: Allocator,
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: session_store.ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    const listed = pickerFilter(summaries, workspace_root, query, .resumable);
    for (summaries, 0..) |summary, index| {
        if (!listed.keeps(index)) continue;
        if (continuation) |position| {
            if (!session_summary_codec.summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn displayTitle(summary: session_store.SessionSummary) []const u8 {
    return summary.title orelse session_display_metadata.fallback_title;
}

pub fn workspacePath(summary: session_store.SessionSummary) []const u8 {
    return summary.workspace_root orelse summary.origin_workspace_root orelse "(unknown workspace)";
}

pub fn relativeActivityAge(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "just now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m ago", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h ago", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d ago", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

// Same buckets as relativeActivityAge without the " ago" suffix, for tight
// single-line layouts: "now", "5m", "2h", "1d".
pub fn relativeActivityAgeCompact(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

/// A session matches by its title, or by the words of its workspace path or
/// preview.
fn sessionMatch(summary: session_store.SessionSummary, query: []const u8) ?fuzzy_match.Match {
    return fuzzy_match.match(query, &.{
        .{ .text = displayTitle(summary) },
        .{ .text = workspacePath(summary), .kind = .text },
        .{ .text = summary.preview orelse "", .kind = .text },
    });
}
