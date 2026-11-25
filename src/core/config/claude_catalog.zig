//! A Claude subscription's model list, `GET /v1/models`, as the models and
//! effort levels of the account's connection. The levels come from each
//! model's own `capabilities`, so a new model or level appears without a
//! Spark update.
const std = @import("std");
const plan_catalog = @import("plan_catalog.zig");
const configured = @import("configured_provider.zig");
const Allocator = std.mem.Allocator;

const Supported = struct { supported: bool = false };

const Capabilities = struct {
    image_input: ?Supported = null,
    thinking: ?struct {
        supported: bool = false,
        types: ?struct { adaptive: ?Supported = null, enabled: ?Supported = null } = null,
    } = null,
    effort: ?std.json.Value = null,
};

const RemoteModel = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    max_input_tokens: ?u32 = null,
    max_tokens: ?u32 = null,
    capabilities: ?Capabilities = null,
};

/// The effort names this API knows, in order.
pub const efforts = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };

/// The thinking budget of each level on a model that takes only a budget.
pub fn budgetOf(level: []const u8) ?u32 {
    const budgets = [_]struct { []const u8, u32 }{ .{ "low", 4096 }, .{ "medium", 10_000 }, .{ "high", 16_000 }, .{ "xhigh", 24_000 }, .{ "max", 31_999 } };
    for (budgets) |entry| if (std.mem.eql(u8, entry[0], level)) return entry[1];
    return null;
}

pub const Thinking = enum { adaptive, budget, none };

/// How a level turns thinking on, and what it sets. Caller owns nothing:
/// the fields are written into `arena`.
pub fn levelFields(arena: Allocator, thinking: Thinking, with_effort: bool, level: []const u8) !std.json.Value {
    var fields: std.json.ObjectMap = .empty;
    switch (thinking) {
        .adaptive => try fields.put(arena, "thinking", try plan_catalog.jsonValue(arena, "{\"type\":\"adaptive\",\"display\":\"summarized\"}")),
        .budget => try fields.put(arena, "thinking", try plan_catalog.jsonValue(arena, try arena.print("{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budgetOf(level) orelse 16_000}))),
        .none => {},
    }
    if (with_effort) try fields.put(arena, "output_config", try plan_catalog.jsonValue(arena, try arena.print("{{\"effort\":\"{s}\"}}", .{level})));
    return .{ .object = fields };
}

/// Whether a capability node says `"supported": true`.
fn isSupported(value: ?std.json.Value) bool {
    const node = value orelse return false;
    if (node != .object) return false;
    const flag = node.object.get("supported") orelse return false;
    return flag == .bool and flag.bool;
}

/// Whether the child `key` of a capability node is supported.
fn supported(value: ?std.json.Value, key: []const u8) bool {
    const node = value orelse return false;
    return node == .object and isSupported(node.object.get(key));
}

/// `Sonnet 5.5` for `Claude Sonnet 5.5`: the account name already says Claude.
fn shortName(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "Claude ") and name.len > "Claude ".len) name["Claude ".len..] else name;
}

pub fn connection(arena: Allocator, display_name: []const u8, bytes: []const u8) !std.json.Value {
    const response = std.json.parseFromSliceLeaky(struct { data: []RemoteModel }, arena, bytes, .{ .ignore_unknown_fields = true }) catch return error.NoPlanModels;
    var models: std.json.ObjectMap = .empty;
    for (response.data) |row| {
        if (row.type) |kind| if (!std.mem.eql(u8, kind, "model")) continue;
        configured.validate_model_id(row.id) catch continue;
        if (models.contains(row.id)) continue;
        if (models.count() == 256) break;
        const base = if (row.display_name) |name| if (plan_catalog.usableLabel(name, 128)) shortName(name) else row.id else row.id;
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "display_name", .{ .string = try plan_catalog.modelName(arena, base, display_name) });
        if (row.max_input_tokens) |n| if (n != 0) try model.put(arena, "context_window", .{ .integer = n });
        if (row.max_tokens) |n| if (n != 0 and (row.max_input_tokens == null or n < row.max_input_tokens.?)) try model.put(arena, "max_output_tokens", .{ .integer = n });
        try model.put(arena, "supports_tool_use", .{ .bool = true });
        const caps = row.capabilities;
        // Every model this API still serves reads images; a listing without
        // capabilities says nothing to the contrary.
        const vision = if (caps) |known| if (known.image_input) |image| image.supported else true else true;
        try model.put(arena, "supports_vision", .{ .bool = vision });
        var levels: std.json.ObjectMap = .empty;
        if (caps) |known| {
            const types = if (known.thinking) |thinking| thinking.types else null;
            const adaptive = if (types) |t| if (t.adaptive) |v| v.supported else false else false;
            const enabled = if (types) |t| if (t.enabled) |v| v.supported else false else false;
            const thinking: Thinking = if (adaptive) .adaptive else if (enabled) .budget else .none;
            if (isSupported(known.effort)) {
                for (efforts) |level| if (supported(known.effort, level)) try levels.put(arena, level, try levelFields(arena, thinking, true, level));
            } else if (thinking == .budget) {
                for ([_][]const u8{ "low", "medium", "high" }) |level| try levels.put(arena, level, try levelFields(arena, .budget, false, level));
            }
        } else {
            // A listing without capabilities: the levels every current model takes.
            for ([_][]const u8{ "low", "medium", "high", "max" }) |level| try levels.put(arena, level, try levelFields(arena, .adaptive, true, level));
        }
        try model.put(arena, "reasoning_efforts", .{ .object = levels });
        try models.put(arena, row.id, .{ .object = model });
    }
    return plan_catalog.connection(arena, .claude, display_name, models);
}

test "Claude catalogs name models after the account and offer each model's own levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "claude-plan-00000000000000000000000000000000";
    var map: std.json.ObjectMap = .empty;
    try map.put(a, id, try connection(a, "Claude (Work)",
        \\{"data":[
        \\ {"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","max_input_tokens":1000000,"max_tokens":128000,
        \\  "capabilities":{"image_input":{"supported":true},"thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true}}},
        \\  "effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}}}},
        \\ {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","max_input_tokens":200000,"max_tokens":64000,
        \\  "capabilities":{"image_input":{"supported":true},"thinking":{"supported":true,"types":{"enabled":{"supported":true},"adaptive":{"supported":false}}},
        \\  "effort":{"supported":false,"low":{"supported":false}}}},
        \\ {"type":"model","id":"claude-future","display_name":"Claude Future"}
        \\],"has_more":false}
    ));
    var registry = try configured.Registry.parse(std.testing.allocator, .{ .object = map });
    defer registry.deinit(std.testing.allocator);
    const definition = registry.get(id).?;
    try std.testing.expect(definition.auth == .claude_plan);
    const models = definition.model_metadata;
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("Sonnet 5.5 (Work)", models[0].display_name.?);
    try std.testing.expectEqual(@as(u32, 1_000_000), models[0].context_window.?);
    try std.testing.expectEqual(@as(usize, 5), models[0].reasoning_efforts.?.len);
    try std.testing.expectEqualStrings("xhigh", models[0].reasoning_efforts.?[3].name);
    const xhigh = models[0].reasoning_efforts.?[3].fields;
    try std.testing.expect(xhigh.has("thinking") and xhigh.has("output_config"));
    try std.testing.expectEqualStrings("Haiku 4.5 (Work)", models[1].display_name.?);
    try std.testing.expectEqual(@as(usize, 3), models[1].reasoning_efforts.?.len);
    try std.testing.expect(!models[1].reasoning_efforts.?[0].fields.has("output_config"));
    try std.testing.expectEqual(@as(usize, 4), models[2].reasoning_efforts.?.len);
}
