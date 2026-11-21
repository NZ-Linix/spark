//! Rewrites text that spark already drew in one theme into another theme's
//! colors, by escape bytes. A loaded theme gives each slot that its file sets
//! its own escape, within the padding limits of `theme.parse`, so each of those
//! slots maps to its own new color. Slots left to the builtin variant, and
//! repeats past the limits, share an escape: the first slot that has it
//! decides its new color.

const std = @import("std");
const shared_theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Theme = shared_theme.Theme;

pub const Token = struct {
    from: []const u8,
    to: []const u8,
};

pub const max_tokens = shared_theme.style_slot_count;

// The builtin themes share escapes between slots that change to different
// colors, so their flips keep a hand-pinned map.
const dark_to_light_builtin = [_]Token{
    .{ .from = "\x1b[1;38;5;255m", .to = "\x1b[1;38;5;235m" },
    .{ .from = "\x1b[38;5;255m", .to = "\x1b[38;5;235m" },
    .{ .from = "\x1b[1;38;5;252m", .to = "\x1b[1;38;5;238m" },
    .{ .from = "\x1b[38;5;252m", .to = "\x1b[38;5;238m" },
    .{ .from = "\x1b[38;5;250m", .to = "\x1b[38;5;241m" },
    .{ .from = "\x1b[38;5;245m", .to = "\x1b[38;5;247m" },
    .{ .from = shared_theme.spark_dark.link_style, .to = shared_theme.spark_light.link_style },
};

const light_to_dark_builtin = [_]Token{
    .{ .from = "\x1b[1;38;5;235m", .to = "\x1b[1;38;5;255m" },
    .{ .from = "\x1b[38;5;235m", .to = "\x1b[38;5;255m" },
    .{ .from = "\x1b[1;38;5;238m", .to = "\x1b[1;38;5;252m" },
    .{ .from = "\x1b[38;5;238m", .to = "\x1b[38;5;252m" },
    .{ .from = "\x1b[38;5;241m", .to = "\x1b[38;5;250m" },
    .{ .from = "\x1b[38;5;247m", .to = "\x1b[38;5;245m" },
    .{ .from = shared_theme.spark_light.link_style, .to = shared_theme.spark_dark.link_style },
};

fn isBuiltin(theme: Theme) bool {
    return std.mem.eql(u8, theme.name, shared_theme.spark_dark.name) or std.mem.eql(u8, theme.name, shared_theme.spark_light.name);
}

/// The escape rewrite map from `from` to `to`, built in `buf` or pinned for a
/// builtin-to-builtin flip. Empty when both themes have the same variant. Any
/// custom theme involved gets a map pairing each slot's old escape with its
/// new one, the first slot winning when slots share an escape, longest first
/// so combined forms match before their fg-only equivalents.
pub fn tokens(from: Theme, to: Theme, buf: *[max_tokens]Token) []const Token {
    if (from.light == to.light) return &.{};
    if (isBuiltin(from) and isBuiltin(to)) {
        return if (to.light) dark_to_light_builtin[0..] else light_to_dark_builtin[0..];
    }

    var n: usize = 0;
    for (0..max_tokens) |index| {
        n = appendPair(buf, n, shared_theme.styleSlot(from, index), shared_theme.styleSlot(to, index));
    }
    sortLongestFirst(buf[0..n]);
    return buf[0..n];
}

fn appendPair(buf: *[max_tokens]Token, n: usize, from: []const u8, to: []const u8) usize {
    if (from.len == 0 or std.mem.eql(u8, from, to) or n >= buf.len) return n;
    for (buf[0..n]) |existing| {
        if (std.mem.eql(u8, existing.from, from)) return n;
    }
    buf[n] = .{ .from = from, .to = to };
    return n + 1;
}

fn sortLongestFirst(map: []Token) void {
    if (map.len < 2) return;
    // The list is bounded by the theme's slots; a local insertion sort avoids
    // pulling a general block-sort implementation into this cold path.
    for (map[1..], 1..) |token, index| {
        var insert_at = index;
        while (insert_at > 0 and token.from.len > map[insert_at - 1].from.len) : (insert_at -= 1) {
            map[insert_at] = map[insert_at - 1];
        }
        map[insert_at] = token;
    }
}

/// `bytes` with each escape of `map` rewritten in one left-to-right pass, so
/// a rewritten escape is never rewritten again. Null when nothing matched.
/// Caller owns the returned slice.
pub fn rewrite(alloc: Allocator, bytes: []const u8, map: []const Token) !?[]u8 {
    if (map.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var changed = false;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == 0x1b) {
            for (map) |token| {
                if (!std.mem.startsWith(u8, bytes[index..], token.from)) continue;
                try out.writer.writeAll(token.to);
                index += token.from.len;
                changed = true;
                break;
            } else {
                try out.writer.writeByte(bytes[index]);
                index += 1;
            }
            continue;
        }
        const next = std.mem.findScalarPos(u8, bytes, index, 0x1b) orelse bytes.len;
        try out.writer.writeAll(bytes[index..next]);
        index = next;
    }

    if (!changed) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

/// The escape `escape` maps to, or null when the map does not rewrite it.
pub fn mapped(escape: []const u8, map: []const Token) ?[]const u8 {
    for (map) |token| {
        if (std.mem.eql(u8, token.from, escape)) return token.to;
    }
    return null;
}

test "custom flip maps each slot to its own color" {
    var dark = shared_theme.spark_dark;
    dark.name = "probe-dark";
    dark.inline_code_open = "\x1b[38;2;136;192;208m";
    dark.link_style = "\x1b[38;2;129;161;193m";
    var light = shared_theme.spark_light;
    light.name = "probe-light";
    light.inline_code_open = "\x1b[38;2;23;108;116m";
    light.link_style = "\x1b[38;2;0;100;176m";

    var buf: [max_tokens]Token = undefined;
    const map = tokens(dark, light, &buf);
    try std.testing.expectEqualStrings("\x1b[38;2;23;108;116m", mapped(dark.inline_code_open, map).?);
    try std.testing.expectEqualStrings("\x1b[38;2;0;100;176m", mapped(dark.link_style, map).?);

    const alloc = std.testing.allocator;
    const out = (try rewrite(alloc, "a \x1b[38;2;136;192;208mcode\x1b[39m and \x1b[38;2;129;161;193mlink\x1b[39m", map)).?;
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a \x1b[38;2;23;108;116mcode\x1b[39m and \x1b[38;2;0;100;176mlink\x1b[39m", out);
}
