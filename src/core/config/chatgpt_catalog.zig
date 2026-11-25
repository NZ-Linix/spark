//! The account catalog returned by Sign in with ChatGPT, not the API-key
//! catalog. Convert it to Spark's configured model metadata without guessing
//! which models or reasoning levels are present on an account.
const std = @import("std");
const configured = @import("configured_provider.zig");
const plan = @import("../auth/chatgpt_plan.zig");
const plan_catalog = @import("plan_catalog.zig");
const Allocator = std.mem.Allocator;

const RemoteModel = struct {
    slug: []const u8 = "",
    display_name: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    supported_in_api: ?bool = null,
    context_window: ?u32 = null,
    max_context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    input_modalities: ?[]const []const u8 = null,
    supported_reasoning_levels: ?[]const struct { effort: []const u8 } = null,
};

pub fn connection(arena: Allocator, display_name: []const u8, bytes: []const u8) !std.json.Value {
    const response = try std.json.parseFromSliceLeaky(struct { models: []RemoteModel }, arena, bytes, .{ .ignore_unknown_fields = true });
    var models: std.json.ObjectMap = .empty;
    for (response.models) |row| {
        if (!std.mem.eql(u8, row.visibility orelse "", "list") or row.supported_in_api == false) continue;
        configured.validate_model_id(row.slug) catch continue;
        if (models.contains(row.slug)) continue;
        if (models.count() == 256) break;
        const base_name = if (row.display_name) |name| if (plan_catalog.usableLabel(name, 128)) name else row.slug else row.slug;
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "display_name", .{ .string = try plan_catalog.modelName(arena, base_name, display_name) });
        const context = row.context_window orelse row.max_context_window orelse 0;
        if (context != 0) try model.put(arena, "context_window", .{ .integer = context });
        if (row.max_output_tokens) |n| if (n != 0 and (context == 0 or n < context)) try model.put(arena, "max_output_tokens", .{ .integer = n });
        try model.put(arena, "supports_tool_use", .{ .bool = true });
        const vision = for (row.input_modalities orelse &.{}) |modality| {
            if (std.mem.eql(u8, modality, "image")) break true;
        } else false;
        try model.put(arena, "supports_vision", .{ .bool = vision });
        var efforts: std.json.ObjectMap = .empty;
        for (row.supported_reasoning_levels orelse &.{}) |level| {
            configured.validate_effort_name(level.effort) catch continue;
            if (efforts.contains(level.effort)) continue;
            if (efforts.count() == configured.max_effort_levels) break;
            try efforts.put(arena, level.effort, try effortValue(arena, level.effort));
        }
        try model.put(arena, "reasoning_efforts", .{ .object = efforts });
        try models.put(arena, row.slug, .{ .object = model });
    }
    if (models.count() == 0) return error.NoChatGPTModels;
    return plan_catalog.connection(arena, .chatgpt, display_name, models);
}

fn effortValue(alloc: Allocator, level: []const u8) !std.json.Value {
    var reasoning: std.json.ObjectMap = .empty;
    try reasoning.put(alloc, "effort", .{ .string = level });
    if (!std.mem.eql(u8, level, "none")) try reasoning.put(alloc, "summary", .{ .string = "auto" });
    var value: std.json.ObjectMap = .empty;
    try value.put(alloc, "reasoning", .{ .object = reasoning });
    return .{ .object = value };
}

test "ChatGPT catalogs keep visible models in order with account labels and advertised efforts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = plan.id_prefix ++ "00000000000000000000000000000000";
    var map: std.json.ObjectMap = .empty;
    try map.put(a, id, try connection(a, "Codex (Work)",
        \\{"models":[
        \\ {"slug":"gpt-hidden","visibility":"hide"},
        \\ {"slug":"gpt-unavailable","visibility":"list","supported_in_api":false},
        \\ {"slug":"gpt-visible","display_name":"GPT Visible","visibility":"list","context_window":128000,
        \\  "input_modalities":["text","image"],"supported_reasoning_levels":[{"effort":"none"},{"effort":"high"}]},
        \\ {"slug":"gpt-visible","display_name":"duplicate","visibility":"list"},
        \\ {"slug":"gpt-next","visibility":"list"}
        \\]}
    ));
    var registry = try configured.Registry.parse(std.testing.allocator, .{ .object = map });
    defer registry.deinit(std.testing.allocator);
    const models = registry.get(id).?.model_metadata;
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("GPT Visible (Work)", models[0].display_name.?);
    try std.testing.expectEqualStrings("gpt-next", models[1].id);
    try std.testing.expect(models[0].supports_vision.?);
    try std.testing.expectEqual(@as(u32, 128000), models[0].context_window.?);
    try std.testing.expectEqualStrings("none", models[0].reasoning_efforts.?[0].name);
    try std.testing.expectEqualStrings("high", models[0].reasoning_efforts.?[1].name);
    try std.testing.expectEqual(@as(usize, 0), models[1].reasoning_efforts.?.len);
    // The plan's only account names its models without a label.
    var single: std.json.ObjectMap = .empty;
    try single.put(a, id, try connection(a, "Codex", "{\"models\":[{\"slug\":\"gpt-next\",\"display_name\":\"GPT Next\",\"visibility\":\"list\"}]}"));
    var alone = try configured.Registry.parse(std.testing.allocator, .{ .object = single });
    defer alone.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("GPT Next", alone.get(id).?.model_metadata[0].display_name.?);
}
