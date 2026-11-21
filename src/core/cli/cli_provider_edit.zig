//! `spark provider show|set|unset|remove-model|rename`: change one field of a
//! saved connection, or one field of one of its models, without walking the
//! whole `/provider` form. Every edit is checked by the same parser spark
//! loads settings with before it is written.
const std = @import("std");
const Allocator = std.mem.Allocator;
const config_runtime = @import("../config/config_runtime.zig");
const configured_provider = @import("../config/configured_provider.zig");
const model_provider = @import("../config/model_provider.zig");

pub const usage =
    \\usage: spark provider <name>
    \\       spark provider show <name>
    \\       spark provider set <name> <field> <value>
    \\       spark provider set <name> <model> <model-field> <value>
    \\       spark provider unset <name> [<model>] <field>
    \\       spark provider remove-model <name> <model>
    \\       spark provider rename <name> <new-name>
    \\fields: display_name, base_url, protocol, key, key_env, model,
    \\        tool_choice_mode, fetch_models, connect_ms, first_response_ms, stall_ms
    \\model fields: display_name, context_window, max_output_tokens,
    \\        supports_tool_use, supports_vision, reasoning_efforts (e.g. low,high,max)
    \\
;

pub const Outcome = struct {
    status: enum { ok, failed, usage },
    /// Text for stdout when `ok`, stderr otherwise. Caller owns it.
    text: []u8,
};

const Action = enum { show, set, unset, @"remove-model", rename };

/// True when `words` (after `provider`) is one of these subcommands rather
/// than a provider name to switch to.
pub fn handles(words: []const []const u8) bool {
    if (words.len < 2) return false;
    return std.meta.stringToEnum(Action, words[0]) != null;
}

const provider_fields = [_][]const u8{ "display_name", "base_url", "protocol", "key", "key_env", "model", "tool_choice_mode", "fetch_models", "connect_ms", "first_response_ms", "stall_ms" };
const model_fields = [_][]const u8{ "display_name", "context_window", "max_output_tokens", "supports_tool_use", "supports_vision", "reasoning_efforts" };

fn isOne(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

pub fn run(alloc: Allocator, words: []const []const u8) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const action = std.meta.stringToEnum(Action, words[0]) orelse return fail(alloc, .usage, usage);
    const args = words[1..];
    const id = args[0];

    const settings = (try config_runtime.loadUserSettingsJson(arena)) orelse return fail(alloc, .failed, "no provider is saved; add one with /provider");
    const providers = settings.object.get("providers") orelse return unknown(alloc, id);
    if (providers != .object) return unknown(alloc, id);
    const current = providers.object.get(id) orelse return unknown(alloc, id);
    if (current != .object) return unknown(alloc, id);
    var root = try current.object.clone(arena);
    var selected: ?[]const u8 = null;
    if (settings.object.get("models")) |models| if (models == .object) if (models.object.get(id)) |m| if (m == .string) {
        selected = m.string;
    };

    switch (action) {
        .show => {
            if (args.len != 1) return fail(alloc, .usage, usage);
            return .{ .status = .ok, .text = try describe(alloc, id, root, selected) };
        },
        .rename => {
            if (args.len != 2) return fail(alloc, .usage, usage);
            configured_provider.validate_id(args[1]) catch return fail(alloc, .failed, "a provider's name starts with a letter and uses letters, digits, _, and -");
            if (providers.object.contains(args[1])) return fail(alloc, .failed, "another provider already has that name");
            return save(alloc, arena, args[1], .{ .object = root }, id, null, "Renamed.");
        },
        .@"remove-model" => {
            if (args.len != 2) return fail(alloc, .usage, usage);
            const metadata = root.getPtr("model_metadata") orelse return fail(alloc, .failed, "that model isn't on this provider");
            if (metadata.* != .object or !metadata.object.contains(args[1])) return fail(alloc, .failed, "that model isn't on this provider");
            if (metadata.object.count() == 1) return fail(alloc, .failed, "a provider keeps at least one model; add another first");
            _ = metadata.object.orderedRemove(args[1]);
            var model: ?[]const u8 = null;
            if (selected) |name| if (std.mem.eql(u8, name, args[1])) {
                var it = metadata.object.iterator();
                model = it.next().?.key_ptr.*;
            };
            return save(alloc, arena, id, .{ .object = root }, null, model, "Removed the model.");
        },
        .set, .unset => {
            const is_set = action == .set;
            const want: usize = if (is_set) 3 else 2;
            if (args.len != want and args.len != want + 1) return fail(alloc, .usage, usage);
            const on_model = args.len == want + 1;
            const field = args[if (on_model) 2 else 1];
            const value: ?[]const u8 = if (is_set) args[args.len - 1] else null;
            if (on_model) {
                if (!isOne(&model_fields, field)) return fail(alloc, .usage, usage);
                const model = args[1];
                configured_provider.validate_model_id(model) catch return fail(alloc, .failed, "a model id is text with no control characters and no spaces at either end");
                if (root.get("model_metadata") == null or root.get("model_metadata").? != .object)
                    try root.put(arena, "model_metadata", .{ .object = .empty });
                const metadata = &root.getPtr("model_metadata").?.object;
                if (!metadata.contains(model)) {
                    if (!is_set) return fail(alloc, .failed, "that model isn't on this provider");
                    var fresh: std.json.ObjectMap = .empty;
                    try fresh.put(arena, "supports_tool_use", .{ .bool = true });
                    try metadata.put(arena, model, .{ .object = fresh });
                }
                const entry = &metadata.getPtr(model).?.object;
                if (value) |text| {
                    const parsed = modelValue(arena, field, text, entry.get(field)) catch |err| return fail(alloc, .failed, valueProblem(err));
                    try entry.put(arena, field, parsed);
                } else _ = entry.orderedRemove(field);
                return save(alloc, arena, id, .{ .object = root }, null, null, "Saved.");
            }
            if (!isOne(&provider_fields, field)) return fail(alloc, .usage, usage);
            if (std.mem.eql(u8, field, "model")) {
                const text = value orelse return fail(alloc, .failed, "a provider always has a selected model; set another instead");
                return save(alloc, arena, id, .{ .object = root }, null, text, "Saved.");
            }
            try setProviderField(arena, &root, field, value);
            return save(alloc, arena, id, .{ .object = root }, null, null, "Saved.");
        },
    }
}

const ValueError = error{ NotNumber, NotBool, OutOfMemory, BadEffort };

fn valueProblem(err: ValueError) []const u8 {
    return switch (err) {
        error.NotNumber => "this field takes a whole number",
        error.NotBool => "this field takes true or false",
        error.BadEffort => "levels use letters, digits, -, _, and ., separated by commas",
        error.OutOfMemory => "out of memory",
    };
}

fn number(text: []const u8) ValueError!std.json.Value {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(std.heap.page_allocator);
    for (text) |c| if (c != '_' and c != ',') digits.append(std.heap.page_allocator, c) catch return error.OutOfMemory;
    var value = std.fmt.parseInt(i64, digits.items, 10) catch blk: {
        // 200k and 1m are common ways to write a context window.
        if (digits.items.len < 2) return error.NotNumber;
        const unit: i64 = switch (std.ascii.toLower(digits.items[digits.items.len - 1])) {
            'k' => 1000,
            'm' => 1_000_000,
            else => return error.NotNumber,
        };
        break :blk (std.fmt.parseInt(i64, digits.items[0 .. digits.items.len - 1], 10) catch return error.NotNumber) * unit;
    };
    if (value < 0) value = 0;
    return .{ .integer = value };
}

fn boolean(text: []const u8) ValueError!std.json.Value {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or std.mem.eql(u8, text, "1")) return .{ .bool = true };
    if (std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "no") or std.mem.eql(u8, text, "0")) return .{ .bool = false };
    return error.NotBool;
}

fn modelValue(arena: Allocator, field: []const u8, text: []const u8, old: ?std.json.Value) ValueError!std.json.Value {
    if (std.mem.eql(u8, field, "display_name")) return .{ .string = try arena.dupe(u8, text) };
    if (std.mem.startsWith(u8, field, "supports_")) return boolean(text);
    if (std.mem.eql(u8, field, "reasoning_efforts")) {
        // A level already saved keeps its request fields; a new one asks
        // with `reasoning_effort`, as `/provider` writes it.
        var levels: std.json.ObjectMap = .empty;
        var names = std.mem.tokenizeAny(u8, text, ", ");
        while (names.next()) |name| {
            if (std.ascii.eqlIgnoreCase(name, "none") and levels.count() == 0) continue;
            configured_provider.validate_effort_name(name) catch return error.BadEffort;
            const kept: ?std.json.Value = if (old) |o| (if (o == .object) o.object.get(name) else null) else null;
            const fields = kept orelse blk: {
                var fresh: std.json.ObjectMap = .empty;
                try fresh.put(arena, "reasoning_effort", .{ .string = try arena.dupe(u8, name) });
                break :blk std.json.Value{ .object = fresh };
            };
            try levels.put(arena, try arena.dupe(u8, name), fields);
        }
        return .{ .object = levels };
    }
    return number(text);
}

fn setProviderField(arena: Allocator, root: *std.json.ObjectMap, field: []const u8, value: ?[]const u8) !void {
    if (std.mem.eql(u8, field, "key") or std.mem.eql(u8, field, "key_env")) {
        var auth: std.json.ObjectMap = .empty;
        if (value) |text| {
            const is_key = std.mem.eql(u8, field, "key");
            try auth.put(arena, "type", .{ .string = if (is_key) "key" else "bearer" });
            try auth.put(arena, if (is_key) "key" else "env", .{ .string = try arena.dupe(u8, text) });
        } else try auth.put(arena, "type", .{ .string = "none" });
        try root.put(arena, "auth", .{ .object = auth });
        return;
    }
    if (std.mem.endsWith(u8, field, "_ms")) {
        if (root.get("timeouts") == null or root.get("timeouts").? != .object) try root.put(arena, "timeouts", .{ .object = .empty });
        const timeouts = &root.getPtr("timeouts").?.object;
        if (value) |text| try timeouts.put(arena, field, number(text) catch .{ .string = text }) else _ = timeouts.orderedRemove(field);
        if (timeouts.count() == 0) _ = root.orderedRemove("timeouts");
        return;
    }
    const text = value orelse {
        _ = root.orderedRemove(field);
        return;
    };
    const parsed: std.json.Value = if (std.mem.eql(u8, field, "fetch_models"))
        boolean(text) catch .{ .string = text }
    else
        .{ .string = try arena.dupe(u8, text) };
    try root.put(arena, field, parsed);
}

fn save(alloc: Allocator, arena: Allocator, id: []const u8, value: std.json.Value, previous: ?[]const u8, model: ?[]const u8, done: []const u8) !Outcome {
    var providers: std.json.ObjectMap = .empty;
    try providers.put(arena, id, value);
    var at: configured_provider.FailurePath = .{};
    var checked = configured_provider.Registry.parse_located(alloc, .{ .object = providers }, &at) catch |err| {
        const advice = configured_provider.failure_advice(err) orelse @errorName(err);
        return .{ .status = .failed, .text = try alloc.print("spark provider: {s}: {s}\n", .{ at.text(), advice }) };
    };
    defer checked.deinit(alloc);
    if (model) |name| {
        const definition = checked.get(id).?;
        var known = false;
        for (definition.model_metadata) |entry| known = known or std.mem.eql(u8, entry.id, name);
        if (!known) return fail(alloc, .failed, "that model isn't on this provider; add it with spark provider set <name> <model> display_name <text>");
    }
    const target = model_provider.parse(id) orelse return fail(alloc, .failed, "that name can't be used");
    var outcome = try config_runtime.setUserPreferences(alloc, .{
        .connection = .{ .id = id, .value = value, .previous_id = previous },
        .model_preference = if (model) |name| .{ .provider = target, .model = name } else null,
    });
    outcome.deinit(alloc);
    return .{ .status = .ok, .text = try alloc.print("{s}\n", .{done}) };
}

fn describe(alloc: Allocator, id: []const u8, root: std.json.ObjectMap, selected: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{s}", .{id});
    if (str(root, "display_name")) |name| try w.print("  ({s})", .{name});
    try w.writeAll("\n");
    if (str(root, "protocol")) |v| try w.print("  protocol  {s}\n", .{v});
    if (str(root, "base_url")) |v| try w.print("  base_url  {s}\n", .{v});
    if (root.get("auth")) |auth| if (auth == .object) {
        if (str(auth.object, "env")) |env| try w.print("  key_env   {s}\n", .{env}) else if (str(auth.object, "key")) |key| {
            try w.print("  key       saved (ends {s})\n", .{if (key.len > 4) key[key.len - 4 ..] else "****"});
        } else try w.writeAll("  key       none\n");
    };
    if (selected) |m| try w.print("  model     {s}\n", .{m});
    if (root.get("model_metadata")) |metadata| if (metadata == .object) {
        try w.writeAll("  models\n");
        var it = metadata.object.iterator();
        while (it.next()) |entry| {
            try w.print("    {s}", .{entry.key_ptr.*});
            if (entry.value_ptr.* == .object) {
                const m = entry.value_ptr.object;
                if (str(m, "display_name")) |name| try w.print("  ({s})", .{name});
                if (m.get("context_window")) |c| if (c == .integer) try w.print("  context {d}", .{c.integer});
                if (m.get("reasoning_efforts")) |levels| if (levels == .object) {
                    try w.writeAll("  efforts ");
                    var names = levels.object.iterator();
                    var first = true;
                    while (names.next()) |level| {
                        try w.print("{s}{s}", .{ if (first) "" else ",", level.key_ptr.* });
                        first = false;
                    }
                    if (first) try w.writeAll("none");
                };
            }
            try w.writeAll("\n");
        }
    };
    return out.toOwnedSlice();
}

fn str(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn unknown(alloc: Allocator, id: []const u8) !Outcome {
    return .{ .status = .failed, .text = try alloc.print("spark provider: no provider named {s}\n", .{id}) };
}

fn fail(alloc: Allocator, status: anytype, message: []const u8) !Outcome {
    const text = if (status == .usage) try alloc.dupe(u8, message) else try alloc.print("spark provider: {s}\n", .{message});
    return .{ .status = status, .text = text };
}

test "number reads plain, grouped, and k or m suffixed counts" {
    try std.testing.expectEqual(@as(i64, 200000), (try number("200k")).integer);
    try std.testing.expectEqual(@as(i64, 1000000), (try number("1m")).integer);
    try std.testing.expectEqual(@as(i64, 128000), (try number("128_000")).integer);
    try std.testing.expectError(error.NotNumber, number("lots"));
}

test "efforts keep saved request fields and add new levels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"high\":{\"reasoning\":{\"effort\":\"high\"}}}", .{});
    const levels = try modelValue(arena, "reasoning_efforts", "low,high", old);
    try std.testing.expectEqualStrings("low", levels.object.get("low").?.object.get("reasoning_effort").?.string);
    try std.testing.expect(levels.object.get("high").?.object.get("reasoning") != null);
    try std.testing.expectError(error.BadEffort, modelValue(arena, "reasoning_efforts", "auto", null));
}
