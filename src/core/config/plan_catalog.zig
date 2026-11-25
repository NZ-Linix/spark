//! What the catalogs of every subscription plan share: the account's label
//! in model names, and the settings shape of an account's connection.
const std = @import("std");
const configured = @import("configured_provider.zig");
const plan_kind = @import("../auth/plan_kind.zig");
const Allocator = std.mem.Allocator;

/// `Work` in `Claude (Work)`; the whole name when it has no label.
pub fn labelOf(provider: []const u8) []const u8 {
    for (plan_kind.Kind.all) |kind| {
        const product = kind.product();
        if (provider.len > product.len + 3 and std.mem.startsWith(u8, provider, product) and
            std.mem.startsWith(u8, provider[product.len..], " (") and std.mem.endsWith(u8, provider, ")"))
            return provider[product.len + 2 .. provider.len - 1];
    }
    return provider;
}

pub fn usableLabel(text: []const u8, limit: usize) bool {
    if (text.len == 0 or text.len > limit or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// `Sonnet 5.5 (Work)`: the model's name with the account's label, cut on
/// a character boundary so the label survives the length bound. An account
/// named without a label, its plan's only one, leaves the name as it is.
pub fn modelName(arena: Allocator, base: []const u8, account: []const u8) ![]u8 {
    const suffix = labelOf(account);
    if (suffix.len == account.len) return arena.dupe(u8, base);
    const max_base = configured.max_model_bytes -| (suffix.len + 3);
    var end = @min(base.len, max_base);
    while (end < base.len and end > 0 and base[end] & 0xc0 == 0x80) end -= 1;
    return arena.print("{s} ({s})", .{ base[0..end], suffix });
}

/// What an account is called: `Claude (Work)` while its plan has more than
/// one account (`labeled`), else just `Claude`.
pub fn accountName(arena: Allocator, kind: plan_kind.Kind, label: []const u8, labeled: bool) ![]u8 {
    return if (labeled) arena.print("{s} ({s})", .{ kind.product(), label }) else arena.dupe(u8, kind.product());
}

/// The label an account was saved with: its own field, else the one in its
/// name, as accounts saved before labels had a field of their own.
pub fn savedLabel(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("account_label")) |label| if (label == .string and label.string.len != 0) return label.string;
    const name = value.object.get("display_name") orelse return null;
    if (name != .string) return null;
    const label = labelOf(name.string);
    return if (label.len == name.string.len) null else label;
}

/// A copy of the account's saved connection named for `labeled`: its own
/// name and each model's, which drop their old label and take the new one.
pub fn presented(arena: Allocator, kind: plan_kind.Kind, value: std.json.Value, label: []const u8, labeled: bool) !std.json.Value {
    if (value != .object) return error.InvalidSettingsFormat;
    const old_name = if (value.object.get("display_name")) |name| (if (name == .string) name.string else "") else "";
    const old_label = labelOf(old_name);
    const had_label = old_label.len != old_name.len;
    const name = try accountName(arena, kind, label, labeled);
    var copy = try value.object.clone(arena);
    try copy.put(arena, "display_name", .{ .string = name });
    try copy.put(arena, "account_label", .{ .string = label });
    if (copy.get("model_metadata")) |models| if (models == .object) {
        var renamed = try models.object.clone(arena);
        for (renamed.values()) |*model| {
            if (model.* != .object) continue;
            const shown = model.object.get("display_name") orelse continue;
            if (shown != .string) continue;
            var base = shown.string;
            if (had_label) {
                const suffix = try arena.print(" ({s})", .{old_label});
                if (std.mem.endsWith(u8, base, suffix)) base = base[0 .. base.len - suffix.len];
            }
            var fields = try model.object.clone(arena);
            try fields.put(arena, "display_name", .{ .string = try modelName(arena, base, name) });
            model.* = .{ .object = fields };
        }
        try copy.put(arena, "model_metadata", .{ .object = renamed });
    };
    return .{ .object = copy };
}

/// The settings of an account's connection with `models` as its catalog.
pub fn connection(arena: Allocator, kind: plan_kind.Kind, display_name: []const u8, models: std.json.ObjectMap) !std.json.Value {
    if (models.count() == 0) return error.NoPlanModels;
    var auth: std.json.ObjectMap = .empty;
    try auth.put(arena, "type", .{ .string = kind.authType() });
    var definition: std.json.ObjectMap = .empty;
    try definition.put(arena, "auth", .{ .object = auth });
    try definition.put(arena, "protocol", .{ .string = kind.protocolName() });
    try definition.put(arena, "base_url", .{ .string = kind.baseUrl() });
    try definition.put(arena, "display_name", .{ .string = display_name });
    try definition.put(arena, "model_metadata", .{ .object = models });
    return .{ .object = definition };
}

/// Parses `text` as JSON into `arena`, as a value to put in settings.
pub fn jsonValue(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "a plan's only account goes without its label, and a second one brings it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Sonnet 5.5", try modelName(a, "Sonnet 5.5", "Claude"));
    const saved = try jsonValue(a,
        \\{"display_name":"Claude","account_label":"Work","model_metadata":{"m":{"display_name":"Sonnet 5.5"}}}
    );
    try std.testing.expectEqualStrings("Work", savedLabel(saved).?);
    const labeled = try presented(a, .claude, saved, "Work", true);
    try std.testing.expectEqualStrings("Claude (Work)", labeled.object.get("display_name").?.string);
    try std.testing.expectEqualStrings("Sonnet 5.5 (Work)", labeled.object.get("model_metadata").?.object.get("m").?.object.get("display_name").?.string);
    const alone = try presented(a, .claude, labeled, "Work", false);
    try std.testing.expectEqualStrings("Claude", alone.object.get("display_name").?.string);
    try std.testing.expectEqualStrings("Sonnet 5.5", alone.object.get("model_metadata").?.object.get("m").?.object.get("display_name").?.string);
    // Accounts saved before `account_label` keep the label of their name.
    try std.testing.expectEqualStrings("Old", savedLabel(try jsonValue(a, "{\"display_name\":\"Codex (Old)\"}")).?);
    try std.testing.expect(savedLabel(try jsonValue(a, "{\"display_name\":\"Codex\"}")) == null);
}

test "account labels come from any plan's product name" {
    try std.testing.expectEqualStrings("Work", labelOf("Claude (Work)"));
    try std.testing.expectEqualStrings("2", labelOf("Antigravity (2)"));
    try std.testing.expectEqualStrings("Personal", labelOf("Codex (Personal)"));
    try std.testing.expectEqualStrings("Other", labelOf("Other"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Sonnet 5.5 (Work)", try modelName(arena.allocator(), "Sonnet 5.5", "Claude (Work)"));
}
