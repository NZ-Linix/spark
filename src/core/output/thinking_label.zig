//! The words spark shows for the model's thinking: "Thinking for 3s..." while
//! it thinks, and "Thought for 1m 5s" on the block it leaves behind. The
//! status line, the live preview, and the transcript all format through here,
//! so the time a block settles on reads like the one counted up to it.

const std = @import("std");

/// The thinking block's marker, in the transcript and the live preview.
pub const glyph = "✻";

/// The frames the status line's marker steps through while a turn runs,
/// growing and then shrinking back.
pub const spinner_frames = [_][]const u8{ "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" };

/// `seconds` as `3s`, `1m 5s`, or `1h 2m 3s`.
pub fn writeDuration(writer: *std.Io.Writer, seconds: u64) !void {
    const secs = seconds % 60;
    const mins = (seconds / 60) % 60;
    const hours = seconds / 3600;
    if (hours > 0) {
        try writer.print("{d}h {d}m {d}s", .{ hours, mins, secs });
    } else if (mins > 0) {
        try writer.print("{d}m {d}s", .{ mins, secs });
    } else {
        try writer.print("{d}s", .{secs});
    }
}

/// Whole seconds in `ms`, never below one: a block that exists took some
/// thought, and "0s" reads as none.
pub fn thoughtSeconds(ms: u64) u64 {
    return @max(ms / std.time.ms_per_s, 1);
}

/// "Thought for 3s".
pub fn thought(buf: []u8, ms: u64) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll("Thought for ") catch return "Thought";
    writeDuration(&out, thoughtSeconds(ms)) catch return "Thought";
    return out.buffered();
}

/// "Thinking for 3s...".
pub fn thinking(buf: []u8, ms: u64) []const u8 {
    return activePhase(buf, "Thinking", ms);
}

/// "`verb` for 3s...", such as "Running for 1m 5s...".
pub fn activePhase(buf: []u8, verb: []const u8, ms: u64) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.print("{s} for ", .{verb}) catch return verb;
    writeDuration(&out, ms / std.time.ms_per_s) catch return verb;
    out.writeAll("...") catch return out.buffered();
    return out.buffered();
}

test "durations read as seconds, then minutes and seconds, then hours" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Thinking for 0s...", thinking(&buf, 400));
    try std.testing.expectEqualStrings("Thinking for 59s...", thinking(&buf, 59_999));
    try std.testing.expectEqualStrings("Thinking for 1m 0s...", thinking(&buf, 60_000));
    try std.testing.expectEqualStrings("Thinking for 1m 5s...", thinking(&buf, 65_000));
    try std.testing.expectEqualStrings("Thought for 2h 0m 1s", thought(&buf, 7_201_000));
    try std.testing.expectEqualStrings("Running for 7s...", activePhase(&buf, "Running", 7_300));
}

test "a thought never reads as zero seconds" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Thought for 1s", thought(&buf, 0));
    try std.testing.expectEqualStrings("Thought for 1s", thought(&buf, 1_999));
    try std.testing.expectEqualStrings("Thought for 2s", thought(&buf, 2_000));
}

test "the spinner grows and shrinks back so it loops without a jump" {
    try std.testing.expectEqualStrings(spinner_frames[1], spinner_frames[spinner_frames.len - 1]);
    try std.testing.expectEqual(@as(usize, 10), spinner_frames.len);
}
