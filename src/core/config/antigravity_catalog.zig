//! An Antigravity account's model list, Cloud Code's `fetchAvailableModels`,
//! as the models and thinking levels of the account's connection. Cloud Code
//! lists some models once per thinking tier (`gemini-3.8-flash-low`,
//! `-medium`, `-high`); those become one model whose levels pick the tier.
const std = @import("std");
const plan_catalog = @import("plan_catalog.zig");
const configured = @import("configured_provider.zig");
const request_fragment = @import("request_fragment.zig");
const Allocator = std.mem.Allocator;

const RemoteModel = struct {
    displayName: ?[]const u8 = null,
    maxTokens: ?u32 = null,
    maxOutputTokens: ?u32 = null,
    supportsImages: ?bool = null,
    supportsThinking: ?bool = null,
    disabled: ?bool = null,
    selectable: ?bool = null,
};

const Response = struct {
    models: ?std.json.ArrayHashMap(RemoteModel) = null,
    agentModelSorts: ?[]const struct { groups: ?[]const struct { modelIds: ?[]const []const u8 = null } = null } = null,
};

/// Thinking tiers, in order.
pub const tiers = [_][]const u8{ "minimal", "low", "medium", "high", "xhigh" };
const xhigh = tiers.len - 1;

const TieredId = struct {
    base: []const u8,
    tier: usize,
    alias: bool,
};

fn tieredId(id: []const u8) ?TieredId {
    // `gpt-oss-120b-medium` is a model name, not a thinking tier.
    const gemini = std.mem.startsWith(u8, id, "gemini-");
    if (!gemini and !std.mem.startsWith(u8, id, "claude-")) return null;
    for (tiers, 0..) |tier, index| {
        if (index == xhigh and !gemini) continue;
        if (!std.mem.endsWith(u8, id, tier) or id.len <= tier.len + 1 or id[id.len - tier.len - 1] != '-') continue;
        const stem = id[0 .. id.len - tier.len - 1];
        const suffix = "-tiered";
        const alias = gemini and std.mem.endsWith(u8, stem, suffix);
        return .{ .base = if (alias) stem[0 .. stem.len - suffix.len] else stem, .tier = index, .alias = alias };
    }
    return null;
}

fn selectable(id: []const u8, model: RemoteModel) bool {
    const families = [_][]const u8{ "gemini-", "claude-", "gpt-oss-" };
    const known = for (families) |prefix| {
        if (std.mem.startsWith(u8, id, prefix)) break true;
    } else false;
    if (!known or model.disabled == true or model.selectable == false) return false;
    if (std.mem.find(u8, id, "image") != null or std.mem.find(u8, id, "imagen") != null) return false;
    return !std.mem.endsWith(u8, id, "-tiered") and !std.mem.endsWith(u8, id, "-disabled");
}

/// How a model's levels think: Gemini 3 and later by level name, Claude
/// and Gemini 2.5 by token budget.
pub const Style = enum { level, budget, none };

pub fn styleOf(id: []const u8) Style {
    if (std.mem.startsWith(u8, id, "claude-") or std.mem.startsWith(u8, id, "gemini-2.")) return .budget;
    if (std.mem.startsWith(u8, id, "gemini-")) return .level;
    return .none;
}

/// The thinking budget of tier `tier` for a budget-style model.
pub fn budgetOf(id: []const u8, tier: []const u8) u32 {
    const table: [4]u32 = if (std.mem.startsWith(u8, id, "claude-") or std.mem.startsWith(u8, id, "gemini-2.5-pro"))
        .{ 2048, 8192, 16_384, 32_768 }
    else if (std.mem.startsWith(u8, id, "gemini-2.5-flash"))
        .{ 1024, 6144, 12_288, 24_576 }
    else
        .{ 1024, 4096, 8192, 16_384 };
    for (tiers[0..xhigh], 0..) |name, index| if (std.mem.eql(u8, name, tier)) return table[index];
    return table[2];
}

/// The request fields of tier `tier` of model `base`; `model` names the
/// tier's own model ID when Cloud Code lists the tiers separately.
pub fn levelFields(arena: Allocator, base: []const u8, tier: []const u8, model: ?[]const u8) Allocator.Error!std.json.Value {
    var fields: std.json.ObjectMap = .empty;
    if (model) |id| try fields.put(arena, "model", .{ .string = id });
    var thinking: std.json.ObjectMap = .empty;
    try thinking.put(arena, "includeThoughts", .{ .bool = true });
    // Extra-high is selected by the model ID, not a Gemini thinkingLevel enum.
    if (!std.mem.eql(u8, tier, tiers[xhigh])) switch (styleOf(base)) {
        .level => try thinking.put(arena, "thinkingLevel", .{ .string = tier }),
        .budget, .none => try thinking.put(arena, "thinkingBudget", .{ .integer = budgetOf(base, tier) }),
    };
    try fields.put(arena, "thinkingConfig", .{ .object = thinking });
    return .{ .object = fields };
}

/// Strips a trailing tier from a name: `Gemini 3.8 Flash (Low)` or
/// `Gemini 3.8 Flash Low` is `Gemini 3.8 Flash`.
fn untiered(name: []const u8) []const u8 {
    for (tiers) |tier| {
        var buf: [16]u8 = undefined;
        const capital = std.fmt.bufPrint(&buf, "{c}{s}", .{ std.ascii.toUpper(tier[0]), tier[1..] }) catch continue;
        for ([_][]const u8{ "(", "" }) |open| {
            const close: []const u8 = if (open.len == 0) "" else ")";
            var pattern: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&pattern, " {s}{s}{s}", .{ open, capital, close }) catch continue;
            if (std.ascii.endsWithIgnoreCase(name, text) and name.len > text.len) return name[0 .. name.len - text.len];
        }
    }
    return name;
}

const ListedTier = struct {
    id: []const u8,
    model: RemoteModel,
    alias: bool,
};

const Family = struct {
    base: []const u8,
    /// The listed model without a tier, when there is one.
    bare: ?RemoteModel = null,
    /// The actual wire ID for each tier; prefer the plain ID to a `-tiered-` alias.
    tiered: [tiers.len]?ListedTier = @splat(null),

    fn representative(self: Family) RemoteModel {
        if (self.bare) |model| return model;
        var index = tiers.len;
        while (index > 0) {
            index -= 1;
            if (self.tiered[index]) |listed| return listed.model;
        }
        unreachable;
    }

    fn tierCount(self: Family) usize {
        var count: usize = 0;
        for (self.tiered) |model| count += @intFromBool(model != null);
        return count;
    }
};

pub fn connection(arena: Allocator, display_name: []const u8, bytes: []const u8) !std.json.Value {
    const response = std.json.parseFromSliceLeaky(Response, arena, bytes, .{ .ignore_unknown_fields = true }) catch return error.NoPlanModels;
    const listed = response.models orelse return error.NoPlanModels;
    // Cloud Code's own order, then every other model by ID.
    var order: std.ArrayList([]const u8) = .empty;
    if (response.agentModelSorts) |sorts| for (sorts) |sort| for (sort.groups orelse &.{}) |group| for (group.modelIds orelse &.{}) |id| {
        try order.append(arena, id);
    };
    var rest: std.ArrayList([]const u8) = .empty;
    for (listed.map.keys()) |id| try rest.append(arena, id);
    std.mem.sort([]const u8, rest.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    try order.appendSlice(arena, rest.items);

    var families: std.StringArrayHashMapUnmanaged(Family) = .empty;
    for (order.items) |id| {
        const model = listed.map.get(id) orelse continue;
        if (!selectable(id, model)) continue;
        configured.validate_model_id(id) catch continue;
        const tiered = tieredId(id);
        const base = if (tiered) |variant| variant.base else id;
        const entry = try families.getOrPut(arena, base);
        if (!entry.found_existing) entry.value_ptr.* = .{ .base = base };
        if (tiered) |variant| {
            const slot = &entry.value_ptr.tiered[variant.tier];
            if (slot.* == null or (slot.*.?.alias and !variant.alias)) slot.* = .{ .id = id, .model = model, .alias = variant.alias };
        } else entry.value_ptr.bare = model;
    }

    var models: std.json.ObjectMap = .empty;
    for (families.values()) |family| {
        if (models.count() == 256) break;
        // A lone tiered ID is a model of its own (`claude-opus-5-5-high`)
        // whose tier is fixed: it thinks at that tier and offers no levels.
        if (family.bare == null and family.tierCount() == 1) {
            for (family.tiered, 0..) |listed_model, index| if (listed_model) |tier| {
                var entry = try modelEntry(arena, display_name, tier.id, tier.model, family, false);
                try entry.object.put(arena, "reasoning_efforts", .{ .object = .empty });
                if (tier.model.supportsThinking orelse false) try entry.object.put(arena, "request", try levelFields(arena, family.base, tiers[index], null));
                try models.put(arena, tier.id, entry);
            };
            continue;
        }
        try models.put(arena, family.base, try modelEntry(arena, display_name, family.base, family.representative(), family, true));
    }
    return plan_catalog.connection(arena, .antigravity, display_name, models);
}

fn modelEntry(arena: Allocator, account: []const u8, id: []const u8, model: RemoteModel, family: Family, grouped: bool) !std.json.Value {
    var fields: std.json.ObjectMap = .empty;
    const listed_name = if (model.displayName) |name| if (plan_catalog.usableLabel(name, 128)) name else id else id;
    const base_name = if (grouped and family.bare == null) untiered(listed_name) else listed_name;
    try fields.put(arena, "display_name", .{ .string = try plan_catalog.modelName(arena, base_name, account) });
    if (model.maxTokens) |n| if (n != 0) try fields.put(arena, "context_window", .{ .integer = n });
    if (model.maxOutputTokens) |n| if (n != 0 and (model.maxTokens == null or n < model.maxTokens.?)) try fields.put(arena, "max_output_tokens", .{ .integer = n });
    try fields.put(arena, "supports_tool_use", .{ .bool = true });
    try fields.put(arena, "supports_vision", .{ .bool = model.supportsImages orelse std.mem.startsWith(u8, id, "gemini-") });
    var levels: std.json.ObjectMap = .empty;
    if (grouped and family.tierCount() != 0) {
        for (family.tiered, 0..) |listed_model, index| if (listed_model) |tier| {
            try levels.put(arena, tiers[index], try levelFields(arena, family.base, tiers[index], tier.id));
        };
    } else if (model.supportsThinking orelse false) {
        const offered: []const []const u8 = switch (styleOf(id)) {
            .level => if (std.mem.find(u8, id, "flash") != null) tiers[0..xhigh] else &.{ "low", "high" },
            .budget => &.{ "low", "medium", "high" },
            .none => &.{},
        };
        for (offered) |tier| try levels.put(arena, tier, try levelFields(arena, id, tier, null));
    }
    try fields.put(arena, "reasoning_efforts", .{ .object = levels });
    if (grouped and family.bare == null) {
        // Keep the default at the highest standard tier. Extra-high is opt-in.
        var index = xhigh;
        while (index > 0) {
            index -= 1;
            const tier = family.tiered[index] orelse continue;
            try fields.put(arena, "request", try levelFields(arena, family.base, tiers[index], tier.id));
            return .{ .object = fields };
        }
        if (family.tiered[xhigh]) |tier| try fields.put(arena, "request", try levelFields(arena, family.base, tiers[xhigh], tier.id));
    }
    return .{ .object = fields };
}

pub const SavedModels = struct {
    visible: []const configured.ModelMetadata,
    aliases: []const configured.ModelMetadata = &.{},
};

/// Fold redundant rows in existing settings too, without rewriting the profile.
/// Keep their metadata addressable for sessions that saved the old model IDs.
pub fn normalizeSaved(arena: Allocator, models: []const configured.ModelMetadata) configured.ParseError!SavedModels {
    var visible: std.ArrayList(configured.ModelMetadata) = .empty;
    var aliases: std.ArrayList(configured.ModelMetadata) = .empty;
    for (models) |model| {
        if (savedAliasOf(model.id)) |base| {
            if (findModel(models, base) != null) {
                var alias = model;
                if (tieredId(model.id)) |variant| {
                    alias.request = try savedTier(arena, variant, model.id);
                    alias.reasoning_efforts = &.{};
                    alias.default_effort = null;
                }
                try aliases.append(arena, alias);
                continue;
            }
        }
        try visible.append(arena, model);
    }
    if (aliases.items.len == 0) return .{ .visible = models };
    for (visible.items) |*base| {
        var extra: std.ArrayList(configured.EffortLevel) = .empty;
        if (!std.mem.startsWith(u8, base.id, "gemini-")) continue;
        for (tiers, 0..) |tier, index| {
            if (base.effort(tier) != null) continue;
            const saved: []const configured.EffortLevel = base.reasoning_efforts orelse &.{};
            if (saved.len + extra.items.len >= configured.max_effort_levels) break;
            var fields: ?request_fragment.Fragment = null;
            for (aliases.items) |alias| {
                if (!std.mem.eql(u8, savedAliasOf(alias.id).?, base.id)) continue;
                if (tieredId(alias.id)) |variant| {
                    if (variant.tier != index) continue;
                    fields = alias.request;
                    if (!variant.alias) break;
                } else if (fields == null) {
                    if (alias.effort(tier)) |level| fields = level.fields;
                }
            }
            if (fields) |found| try extra.append(arena, .{ .name = tier, .fields = found });
        }
        if (extra.items.len != 0) base.reasoning_efforts = try std.mem.concat(arena, configured.EffortLevel, &.{ @as([]const configured.EffortLevel, base.reasoning_efforts orelse &.{}), extra.items });
    }
    return .{ .visible = visible.items, .aliases = aliases.items };
}

fn savedAliasOf(id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, id, "gemini-")) return null;
    if (tieredId(id)) |variant| return variant.base;
    const suffix = "-tiered";
    return if (std.mem.endsWith(u8, id, suffix)) id[0 .. id.len - suffix.len] else null;
}

fn findModel(models: []const configured.ModelMetadata, id: []const u8) ?configured.ModelMetadata {
    for (models) |model| if (std.mem.eql(u8, model.id, id)) return model;
    return null;
}

fn savedTier(arena: Allocator, variant: TieredId, id: []const u8) configured.ParseError!request_fragment.Fragment {
    return request_fragment.parse(arena, try levelFields(arena, variant.base, tiers[variant.tier], id), &.{});
}

/// The model ID and thinking settings a request for `model` at `level` sends
/// when the account's saved catalog has no level by that name: a model listed
/// since sign-in. Gemini 3 and later take the level by name.
pub fn fallbackFields(arena: Allocator, model: []const u8, level: []const u8) !std.json.Value {
    return levelFields(arena, model, level, null);
}

test "Antigravity catalogs fold tiered models into one model with levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "antigravity-plan-00000000000000000000000000000000";
    var map: std.json.ObjectMap = .empty;
    try map.put(a, id, try connection(a, "Antigravity (Personal)",
        \\{"models":{
        \\ "gemini-3.8-flash-low":{"displayName":"Gemini 3.8 Flash (Low)","maxTokens":1048576,"maxOutputTokens":65536,"supportsImages":true,"supportsThinking":true},
        \\ "gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)","maxTokens":1048576,"maxOutputTokens":65536,"supportsImages":true,"supportsThinking":true},
        \\ "gemini-3.1-pro":{"displayName":"Gemini 3.1 Pro","maxTokens":1048576,"supportsThinking":true},
        \\ "claude-opus-5-5-high":{"displayName":"Claude Opus 5.5","maxTokens":200000,"supportsThinking":true},
        \\ "claude-sonnet-4-6-thinking":{"displayName":"Claude Sonnet 4.6 (Thinking)","supportsThinking":true},
        \\ "gpt-oss-120b-medium":{"displayName":"GPT-OSS 120B"},
        \\ "gemini-3-pro-image":{"displayName":"Image"},
        \\ "chat_20706":{"displayName":"internal"},
        \\ "gemini-2.5-flash":{"displayName":"Gemini 2.5 Flash","disabled":true}
        \\},"agentModelSorts":[{"groups":[{"modelIds":["claude-opus-5-5-high","gemini-3.8-flash-high"]}]}]}
    ));
    var registry = try configured.Registry.parse(std.testing.allocator, .{ .object = map });
    defer registry.deinit(std.testing.allocator);
    const definition = registry.get(id).?;
    try std.testing.expect(definition.auth == .antigravity_plan);
    try std.testing.expect(definition.protocol == .@"gemini-code-assist");
    const models = definition.model_metadata;
    try std.testing.expectEqual(@as(usize, 5), models.len);
    try std.testing.expectEqualStrings("claude-opus-5-5-high", models[0].id);
    try std.testing.expectEqualStrings("Claude Opus 5.5 (Personal)", models[0].display_name.?);
    try std.testing.expectEqual(@as(usize, 0), models[0].reasoning_efforts.?.len);
    try std.testing.expectEqualStrings("{\"includeThoughts\":true,\"thinkingBudget\":32768}", models[0].request.?.fields[0].value_json);
    try std.testing.expectEqualStrings("gemini-3.8-flash", models[1].id);
    try std.testing.expectEqualStrings("Gemini 3.8 Flash (Personal)", models[1].display_name.?);
    const flash = models[1].reasoning_efforts.?;
    try std.testing.expectEqual(@as(usize, 2), flash.len);
    try std.testing.expectEqualStrings("low", flash[0].name);
    try std.testing.expectEqualStrings("\"gemini-3.8-flash-high\"", flash[1].fields.fields[0].value_json);
    try std.testing.expectEqualStrings("\"gemini-3.8-flash-high\"", models[1].request.?.fields[0].value_json);
    try std.testing.expect(models[3].request == null);
    try std.testing.expectEqualStrings("claude-sonnet-4-6-thinking", models[2].id);
    try std.testing.expectEqual(@as(usize, 3), models[2].reasoning_efforts.?.len);
    try std.testing.expectEqualStrings("gemini-3.1-pro", models[3].id);
    try std.testing.expectEqual(@as(usize, 2), models[3].reasoning_efforts.?.len);
    try std.testing.expectEqualStrings("gpt-oss-120b-medium", models[4].id);
    try std.testing.expectEqual(@as(usize, 0), models[4].reasoning_efforts.?.len);
}

test "Antigravity folds Gemini extra-high tiers and tiered aliases into one model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "antigravity-plan-00000000000000000000000000000001";
    var map: std.json.ObjectMap = .empty;
    try map.put(a, id, try connection(a, "Antigravity (1)",
        \\{"models":{
        \\ "gemini-5-nova":{"displayName":"Gemini 5 Nova","maxTokens":1048576,"maxOutputTokens":262144,"supportsThinking":true},
        \\ "gemini-5-nova-xhigh":{"displayName":"Gemini 5 Nova (XHigh)","maxTokens":1048576,"maxOutputTokens":262144,"supportsThinking":true},
        \\ "gemini-5-nova-tiered-high":{"displayName":"Gemini 5 Nova (High)","maxTokens":1048576,"maxOutputTokens":262144,"supportsThinking":true},
        \\ "gemini-5-nova-tiered-xhigh":{"displayName":"Gemini 5 Nova (XHigh)","maxTokens":1048576,"maxOutputTokens":262144,"supportsThinking":true},
        \\ "gemini-5-nova-sonar":{"displayName":"Gemini 5 Nova Sonar","maxTokens":1048576,"maxOutputTokens":65536,"supportsThinking":true}
        \\}}
    ));
    var registry = try configured.Registry.parse(std.testing.allocator, .{ .object = map });
    defer registry.deinit(std.testing.allocator);
    const models = registry.get(id).?.model_metadata;
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gemini-5-nova", models[0].id);
    try std.testing.expectEqualStrings("Gemini 5 Nova (1)", models[0].display_name.?);
    const levels = models[0].reasoning_efforts.?;
    try std.testing.expectEqual(@as(usize, 2), levels.len);
    try std.testing.expectEqualStrings("high", levels[0].name);
    try std.testing.expectEqualStrings("\"gemini-5-nova-tiered-high\"", levels[0].fields.fields[0].value_json);
    try std.testing.expectEqualStrings("xhigh", levels[1].name);
    try std.testing.expectEqualStrings("\"gemini-5-nova-xhigh\"", levels[1].fields.fields[0].value_json);
    try std.testing.expectEqualStrings("{\"includeThoughts\":true}", levels[1].fields.fields[1].value_json);
    try std.testing.expect(models[0].request == null);
    try std.testing.expectEqualStrings("gemini-5-nova-sonar", models[1].id);
}

test "saved Antigravity tier rows fold into their model but still resolve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"antigravity-plan-00000000000000000000000000000002":{"auth":{"type":"antigravity-plan"},"protocol":"gemini-code-assist",
        \\ "base_url":"https://daily-cloudcode-pa.googleapis.com","display_name":"Antigravity (2)","model_metadata":{
        \\ "gemini-4-hydrogen":{"display_name":"Gemini 4 Hydrogen (2)","reasoning_efforts":{"high":{"model":"gemini-4-hydrogen-high","thinkingConfig":{"includeThoughts":true,"thinkingLevel":"high"}}},"request":{"model":"gemini-4-hydrogen-high"}},
        \\ "gemini-4-hydrogen-xhigh":{"display_name":"Gemini 4 Hydrogen (XHigh) (2)","reasoning_efforts":{"high":{"thinkingConfig":{"includeThoughts":true,"thinkingLevel":"high"}}}},
        \\ "gemini-4-hydrogen-tiered-high":{"display_name":"Gemini 4 Hydrogen (High) (2)","reasoning_efforts":{}},
        \\ "gemini-4-hydrogen-tiered-xhigh":{"display_name":"Gemini 4 Hydrogen (XHigh) (2)","reasoning_efforts":{}},
        \\ "gemini-4-hydrogen-sonar":{"display_name":"gemini-4-hydrogen-sonar (2)"},
        \\ "gpt-oss-120b-medium":{"display_name":"GPT-OSS 120B (2)"}
        \\}}}
    , .{});
    var registry = try configured.Registry.parse(std.testing.allocator, parsed);
    defer registry.deinit(std.testing.allocator);
    const definition = registry.get("antigravity-plan-00000000000000000000000000000002").?;
    const models = definition.model_metadata;
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("gemini-4-hydrogen", models[0].id);
    try std.testing.expectEqualStrings("gemini-4-hydrogen-sonar", models[1].id);
    try std.testing.expectEqualStrings("gpt-oss-120b-medium", models[2].id);
    const levels = models[0].reasoning_efforts.?;
    try std.testing.expectEqual(@as(usize, 2), levels.len);
    try std.testing.expectEqualStrings("xhigh", levels[1].name);
    try std.testing.expectEqualStrings("\"gemini-4-hydrogen-xhigh\"", levels[1].fields.fields[0].value_json);
    const old = definition.model("gemini-4-hydrogen-tiered-high").?;
    try std.testing.expectEqualStrings("\"gemini-4-hydrogen-tiered-high\"", old.request.?.fields[0].value_json);
}
