//! The documented `SPARK_*` variables that override a setting for the whole
//! process, read the way spark reads them, so `spark config list` and `get` can show
//! the value spark uses and where it came from.

const std = @import("std");
const agent_steps = @import("agent_steps.zig");
const compactor = @import("../compactor/compactor.zig");
const config_runtime = @import("config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Override = struct {
    /// The variable, such as `SPARK_MAX_AGENT_STEPS`.
    variable: []const u8,
    /// The dotted setting it overrides, such as `max_agent_steps`.
    key: []const u8,
    /// The value spark uses, in settings-file form.
    value: std.json.Value,
};

/// `SPARK_SOUND` is a preset for the whole `sound` group.
pub const SoundPreset = enum {
    /// Every sound off.
    off,
    /// Turn-end and attention sounds on, `max` off.
    on,
    /// Every sound on.
    max,
};

/// The preset `SPARK_SOUND` names: `max`, or `0`, `false`, or `off` for off.
/// Any other non-blank value turns sounds on.
pub fn soundPreset(raw: []const u8) ?SoundPreset {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return .max;
    const off = std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "off");
    return if (off) .off else .on;
}

/// True when `SPARK_AUTO_UPGRADE` turns automatic upgrades off: `0` or `false`.
/// No value turns them on.
pub fn autoUpgradeOff(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false");
}

/// Every documented `SPARK_*` setting override set in this process, in a fixed
/// order, with the value spark uses. A value spark ignores or rejects, such as
/// `SPARK_MAX_AGENT_STEPS=many`, is left out. `SPARK_MODEL` overrides the model of
/// `provider`, the provider spark would use without it. Everything, including
/// the returned slice, is allocated with `arena`.
pub fn collect(arena: Allocator, provider: model_provider.ProviderId) ![]Override {
    var list: std.ArrayList(Override) = .empty;
    const getenv = io_mod.getenv;

    var model_provider_id = provider;
    if (config_runtime.providerEnvOverride()) |raw| {
        if (model_provider.parse(std.mem.trim(u8, raw, " \t\r\n"))) |parsed| {
            model_provider_id = parsed;
            try list.append(arena, .{ .variable = "SPARK_PROVIDER", .key = "provider", .value = .{ .string = try arena.dupe(u8, parsed.label()) } });
        }
    }
    if (config_runtime.modelEnvOverride()) |model| {
        const key = try std.mem.concat(arena, u8, &.{ "models.", model_provider.NameKey.fromProvider(model_provider_id).label() });
        try list.append(arena, .{ .variable = "SPARK_MODEL", .key = key, .value = .{ .string = model } });
    }
    if (config_runtime.ultrafastModeEnvOverride() catch null) |enabled| {
        try list.append(arena, .{ .variable = "SPARK_ULTRAFAST", .key = "ultrafast_mode", .value = .{ .bool = enabled } });
    }
    if (getenv("SPARK_PERMISSION_MODE")) |raw| {
        if (types.PermissionMode.parse(raw)) |mode| {
            try list.append(arena, .{ .variable = "SPARK_PERMISSION_MODE", .key = "permission_mode", .value = .{ .string = mode.label() } });
        }
    }
    if (agent_steps.parseMaxAgentSteps(getenv("SPARK_MAX_AGENT_STEPS"))) |steps| {
        // spark accepts any usize, which can exceed a JSON integer.
        const value: std.json.Value = if (std.math.cast(i64, steps)) |fits|
            .{ .integer = fits }
        else
            .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{steps}) };
        try list.append(arena, .{ .variable = "SPARK_MAX_AGENT_STEPS", .key = "max_agent_steps", .value = value });
    }
    if (compactor.parsePercent(getenv("SPARK_AUTO_COMPACT_PERCENT"))) |percent| {
        try list.append(arena, .{ .variable = "SPARK_AUTO_COMPACT_PERCENT", .key = "auto_compact_percent", .value = .{ .integer = percent } });
    }
    if (getenv("SPARK_THEME")) |raw| {
        if (raw.len > 0) try list.append(arena, .{ .variable = "SPARK_THEME", .key = "theme", .value = .{ .string = raw } });
    }
    if (getenv("SPARK_SOUND")) |raw| {
        if (soundPreset(raw)) |preset| {
            const values = [_]struct { key: []const u8, on: bool }{
                .{ .key = "sound.turn_end", .on = preset != .off },
                .{ .key = "sound.attention_required", .on = preset != .off },
                .{ .key = "sound.max", .on = preset == .max },
            };
            for (values) |entry| try list.append(arena, .{ .variable = "SPARK_SOUND", .key = entry.key, .value = .{ .bool = entry.on } });
        }
    }
    if (getenv("SPARK_AUTO_UPGRADE")) |raw| {
        if (autoUpgradeOff(raw)) try list.append(arena, .{ .variable = "SPARK_AUTO_UPGRADE", .key = "auto_upgrade", .value = .{ .bool = false } });
    }
    return list.toOwnedSlice(arena);
}

var test_empty_environ: ?*std.process.Environ.Map = null;

/// An empty environment that outlives every test, for a test that installs
/// its own to restore afterwards.
pub fn emptyTestEnviron() !*const std.process.Environ.Map {
    if (test_empty_environ) |map| return map;
    const map = try std.heap.page_allocator.create(std.process.Environ.Map);
    map.* = .init(std.heap.page_allocator);
    test_empty_environ = map;
    return map;
}
