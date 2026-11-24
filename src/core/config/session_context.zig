const std = @import("std");
const model_capabilities = @import("model_capabilities.zig");

pub const min_tokens = 8_192;
pub const presets = [_]u32{ 16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576 };
pub const usage = "Use /context <tokens> (e.g. 64k), or /context auto to use the model default.";

pub fn parse(text: []const u8) error{InvalidContextWindow}!?u32 {
    if (std.ascii.eqlIgnoreCase(text, "auto")) return null;
    const kilo = text.len > 0 and std.ascii.toLower(text[text.len - 1]) == 'k';
    const digits = if (kilo) text[0 .. text.len - 1] else text;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidContextWindow;
    const number = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidContextWindow;
    const tokens = if (kilo) std.math.mul(u32, number, 1024) catch return error.InvalidContextWindow else number;
    if (tokens < min_tokens) return error.InvalidContextWindow;
    return tokens;
}

pub fn window(advertised: ?u32, limit: ?u32) ?u32 {
    const ceiling = limit orelse return advertised;
    return @min(advertised orelse ceiling, ceiling);
}

/// A reduced window must also reserve room for a reply. Keep the model's
/// native output policy when the session ceiling does not reduce its window.
pub fn apply(capabilities: model_capabilities.Capabilities, limit: ?u32) model_capabilities.Capabilities {
    const effective = window(capabilities.context_window, limit);
    if (effective == capabilities.context_window) return capabilities;
    var capped = capabilities;
    capped.context_window = effective;
    if (model_capabilities.emptyLengthRetryOutputTokens(capped)) |reserve| {
        capped.max_output_tokens = @min(capabilities.max_output_tokens orelse reserve, reserve);
    }
    return capped;
}

test "session context parses limits and bounds known and unknown models" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(?u32, null), try parse("AUTO"));
    try expectEqual(@as(?u32, 65_536), try parse("64k"));
    try expectEqual(@as(?u32, 100_000), try parse("100000"));
    for ([_][]const u8{ "", "0", "7k", "-32000", "32 k", "30_000", "4294967295k" }) |invalid| {
        try std.testing.expectError(error.InvalidContextWindow, parse(invalid));
    }
    const native: model_capabilities.Capabilities = .{ .context_window = 200_000, .max_output_tokens = 32_000 };
    try expectEqual(native, apply(native, null));
    try expectEqual(native, apply(native, 262_144));
    const capped = apply(native, 65_536);
    try expectEqual(@as(?u32, 65_536), capped.context_window);
    try expectEqual(@as(?u32, 8192), model_capabilities.requestOutputTokens(capped));
    try expectEqual(@as(?u32, 4096), model_capabilities.requestOutputTokens(apply(.{}, 32_768)));
}
