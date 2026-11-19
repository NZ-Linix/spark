//! The launch splash: the version line, drawn by the footer while spark
//! waits for its first prompt, with a spark that streaks across the rest of
//! the row through a field of twinkling dots. White and gray only. At the
//! first keystroke or turn it leaves for good, and the app writes the plain
//! version line to the transcript in its place.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);

/// The version row and the blank row under it, as the transcript has them.
pub const banner_rows: u16 = 2;
pub const frame_ms = 60;

const bright = "\x1b[0;1;97m";
const normal = "\x1b[0;37m";
const faint = "\x1b[0;2;37m";
const reset = "\x1b[0m";

/// The comet's tail, nearest the head first.
const tail = [_]struct { glyph: []const u8, style: []const u8 }{
    .{ .glyph = "━", .style = bright },
    .{ .glyph = "━", .style = normal },
    .{ .glyph = "─", .style = normal },
    .{ .glyph = "─", .style = faint },
    .{ .glyph = "╌", .style = faint },
    .{ .glyph = "·", .style = faint },
};
const twinkle = [_]struct { glyph: []const u8, style: []const u8 }{
    .{ .glyph = "·", .style = faint },
    .{ .glyph = "·", .style = normal },
    .{ .glyph = "+", .style = normal },
    .{ .glyph = "✧", .style = bright },
    .{ .glyph = "+", .style = normal },
    .{ .glyph = "·", .style = normal },
};

pub const State = struct {
    active: bool = true,
    /// The app held back the transcript's version line for the splash.
    welcome_pending: bool = false,
    frame: u32 = 0,
    last_ms: i64 = 0,

    /// Advances the animation when a frame is due. Returns true when it
    /// moved, so the footer needs a redraw.
    pub fn tick(self: *State, now_ms: i64) bool {
        if (!self.active) return false;
        if (now_ms - self.last_ms < frame_ms) return false;
        self.last_ms = now_ms;
        self.frame +%= 1;
        return true;
    }

    pub fn dismiss(self: *State) void {
        self.active = false;
    }
};

/// Row 0: `welcome` (the version line, without its newlines) followed by
/// the animation. Row 1 stays blank, like the gap under the transcript's
/// version line.
pub fn composeRow(alloc: Allocator, state: *const State, index: u16, width: u16, welcome: []const u8) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    if (index != 0 or width == 0) return row;
    const line = std.mem.trimEnd(u8, welcome, "\n");
    try row.appendSlice(alloc, line);
    try row.appendSlice(alloc, reset);
    const used = display_width.visibleWidthIgnoringAnsi(line);
    const start = used + 2;
    if (width < start + 12) return row;
    const field: u32 = @intCast(width - start - 1);
    try row.appendSlice(alloc, "  ");

    // The head crosses the field, then rests out of sight for a moment.
    const lap = field + 30;
    const head: i64 = @intCast(state.frame % lap);
    var col: u32 = 0;
    while (col < field) : (col += 1) {
        const behind = head - @as(i64, col);
        if (behind == 0) {
            try row.appendSlice(alloc, bright ++ "✦");
            continue;
        }
        if (behind > 0 and behind <= tail.len) {
            const t = tail[@intCast(behind - 1)];
            try row.appendSlice(alloc, t.style);
            try row.appendSlice(alloc, t.glyph);
            continue;
        }
        // Sparse dots, each on its own slow cycle.
        var seed = col +% 0x9e3779b9;
        seed = (seed ^ (seed >> 16)) *% 0x7feb352d;
        seed = (seed ^ (seed >> 15)) *% 0x846ca68b;
        seed ^= seed >> 16;
        if (seed % 7 == 0) {
            const phase = (state.frame / 3 +% (seed >> 9)) % 28;
            if (phase < twinkle.len) {
                try row.appendSlice(alloc, twinkle[phase].style);
                try row.appendSlice(alloc, twinkle[phase].glyph);
            } else {
                try row.appendSlice(alloc, faint ++ "·");
            }
            continue;
        }
        try row.append(alloc, ' ');
    }
    try row.appendSlice(alloc, reset);
    return row;
}

test "the splash row starts with the version line and stays inside the width" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    try std.testing.expect(state.tick(1000));
    try std.testing.expect(!state.tick(1010));
    var frame: u32 = 0;
    while (frame < 200) : (frame += 7) {
        state.frame = frame;
        var row = try composeRow(alloc, &state, 0, 60, "-=✦ v1\n\n");
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.startsWith(u8, row.items, "-=✦ v1"));
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 60);
    }
    var gap = try composeRow(alloc, &state, 1, 60, "-=✦ v1\n\n");
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);
    state.dismiss();
    try std.testing.expect(!state.tick(5000));
}
