//! The values set in spark's settings files as dotted `key=value` entries, for
//! `spark config list` and `spark config get`.

const std = @import("std");
const env_settings = @import("env_settings.zig");
const settings_keys = @import("settings_keys.zig");

const Allocator = std.mem.Allocator;

pub const Origin = enum {
    /// A project `.spark.json`.
    project,
    /// The top level of the profile `settings.json`.
    global,
    /// This workspace's override inside the profile `settings.json`.
    workspace,
    /// An `SPARK_*` variable set for this process.
    env,
    /// Nothing sets it, so spark uses its built-in value.
    default,
};

pub const Scope = enum { all, global, workspace };

pub const Entry = struct {
    /// Dotted key under its current name, such as `status_line.context`.
    key: []const u8,
    /// Borrowed from the parsed file or the environment.
    value: std.json.Value,
    origin: Origin,
    /// The variable an `env` entry comes from, such as `SPARK_MAX_AGENT_STEPS`.
    variable: ?[]const u8 = null,
};

pub const Files = struct {
    /// The parsed profile `settings.json`, or null when it is absent.
    profile: ?std.json.Value = null,
    /// The parsed project `.spark.json`, or null when it is absent.
    project: ?std.json.Value = null,
    /// The workspace whose override applies, as `workspaces` stores it.
    workspace_root: []const u8,
};

pub const Entries = struct {
    items: []Entry,

    pub fn deinit(self: *Entries, alloc: Allocator) void {
        for (self.items) |entry| alloc.free(entry.key);
        alloc.free(self.items);
        self.* = undefined;
    }
};

/// Every value set in `files` for `scope`, lowest precedence first: the
/// project-safe keys of `.spark.json`, the profile's own settings, then this
/// workspace's override. A key that repeats takes its last entry. Unknown and
/// retired keys are left out; `settings_keys.findUnknown` reports them.
/// Caller deinits the result, whose values borrow from `files`.
pub fn collect(alloc: Allocator, files: Files, scope: Scope) !Entries {
    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |entry| alloc.free(entry.key);
        list.deinit(alloc);
    }

    if (scope == .all) {
        if (files.project) |project| {
            if (project == .object) try appendSettings(alloc, &list, project.object, .project);
        }
    }
    if (files.profile) |profile| {
        if (profile == .object) {
            if (scope != .workspace) try appendSettings(alloc, &list, profile.object, .global);
            if (scope != .global) {
                if (workspaceOverride(profile.object, files.workspace_root)) |override| {
                    try appendSettings(alloc, &list, override, .workspace);
                }
            }
        }
    }
    return .{ .items = try list.toOwnedSlice(alloc) };
}

/// Adds the `SPARK_*` setting overrides as the last, highest-precedence entries,
/// as spark applies them. Their values stay borrowed from `overrides`.
pub fn appendEnv(alloc: Allocator, entries: *Entries, overrides: []const env_settings.Override) !void {
    if (overrides.len == 0) return;
    const start = entries.items.len;
    const grown = try alloc.alloc(Entry, start + overrides.len);
    errdefer alloc.free(grown);
    @memcpy(grown[0..start], entries.items);
    var added: usize = 0;
    errdefer for (grown[start..][0..added]) |entry| alloc.free(entry.key);
    for (overrides, grown[start..]) |override, *slot| {
        slot.* = .{ .key = try alloc.dupe(u8, override.key), .value = override.value, .origin = .env, .variable = override.variable };
        added += 1;
    }
    alloc.free(entries.items);
    entries.items = grown;
}

/// The entries for `key` and the keys under it, such as every `status_line.*`
/// for `status_line`, keeping only the entry spark uses for each. Caller frees the
/// returned slice; its entries borrow from `entries`.
pub fn lookup(alloc: Allocator, entries: []const Entry, key: []const u8) ![]Entry {
    var found: std.ArrayList(Entry) = .empty;
    errdefer found.deinit(alloc);
    for (entries, 0..) |entry, index| {
        if (!coveredBy(entry.key, key)) continue;
        if (overriddenLater(entries[index + 1 ..], entry.key)) continue;
        try found.append(alloc, entry);
    }
    return found.toOwnedSlice(alloc);
}

fn coveredBy(entry_key: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, entry_key, key)) return false;
    return entry_key.len == key.len or entry_key[key.len] == '.';
}

fn overriddenLater(rest: []const Entry, key: []const u8) bool {
    for (rest) |later| {
        if (std.mem.eql(u8, later.key, key)) return true;
    }
    return false;
}

fn workspaceOverride(profile: std.json.ObjectMap, workspace_root: []const u8) ?std.json.ObjectMap {
    const workspaces = profile.get("workspaces") orelse return null;
    if (workspaces != .object) return null;
    const override = workspaces.object.get(workspace_root) orelse return null;
    if (override != .object) return null;
    return override.object;
}

fn appendSettings(alloc: Allocator, list: *std.ArrayList(Entry), object: std.json.ObjectMap, origin: Origin) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = settings_keys.find(name) orelse continue;
        switch (key.where) {
            .retired, .editor => continue,
            .profile => if (origin == .project) continue,
            .project_safe => {},
        }
        // Workspace overrides are shown as their own origin.
        if (std.mem.eql(u8, name, "workspaces")) continue;
        if (key.renamed_to) |current| {
            try appendRenamed(alloc, list, entry.value_ptr.*, object.get(current), settings_keys.find(current).?, origin);
            continue;
        }
        try appendValue(alloc, list, name, entry.value_ptr.*, origin, key);
    }
}

/// Shows a setting saved under its older name, such as `statusLine`, under its
/// current one, leaving out each value the current key also sets, since that
/// one wins.
fn appendRenamed(
    alloc: Allocator,
    list: *std.ArrayList(Entry),
    older: std.json.Value,
    current: ?std.json.Value,
    key: settings_keys.Key,
    origin: Origin,
) !void {
    if (older != .object) {
        if (current == null) try appendValue(alloc, list, key.name, older, origin, key);
        return;
    }
    const shadow: ?std.json.ObjectMap = if (current) |value| (if (value == .object) value.object else null) else null;
    var iterator = older.object.iterator();
    while (iterator.next()) |child| {
        if (!key.hasChild(child.key_ptr.*)) continue;
        if (shadow) |object| if (object.contains(child.key_ptr.*)) continue;
        const child_key = try std.mem.concat(alloc, u8, &.{ key.name, ".", child.key_ptr.* });
        defer alloc.free(child_key);
        try appendValue(alloc, list, child_key, child.value_ptr.*, origin, null);
    }
}

fn appendValue(
    alloc: Allocator,
    list: *std.ArrayList(Entry),
    key: []const u8,
    value: std.json.Value,
    origin: Origin,
    setting: ?settings_keys.Key,
) !void {
    if (value == .object and value.object.count() > 0) {
        var iterator = value.object.iterator();
        while (iterator.next()) |child| {
            if (setting) |known| {
                if (known.children.len > 0 and !known.hasChild(child.key_ptr.*)) continue;
            }
            const child_key = try std.mem.concat(alloc, u8, &.{ key, ".", child.key_ptr.* });
            defer alloc.free(child_key);
            try appendValue(alloc, list, child_key, child.value_ptr.*, origin, null);
        }
        return;
    }
    try list.ensureUnusedCapacity(alloc, 1);
    list.appendAssumeCapacity(.{ .key = try alloc.dupe(u8, key), .value = value, .origin = origin });
}

fn parseForTest(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "an older name shows under the current one, which wins any value both set" {
    const alloc = std.testing.allocator;
    var profile = try parseForTest(
        \\{"status_line":{"context":true},"statusLine":{"context":false,"session":true},
        \\ "notifications":{"max":true}}
    );
    defer profile.deinit();
    var entries = try collect(alloc, .{ .profile = profile.value, .workspace_root = "/w" }, .all);
    defer entries.deinit(alloc);

    const expected = [_]struct { key: []const u8, value: bool }{
        .{ .key = "status_line.context", .value = true },
        .{ .key = "status_line.session", .value = true },
        .{ .key = "sound.max", .value = true },
    };
    try std.testing.expectEqual(expected.len, entries.items.len);
    for (expected, entries.items) |want, got| {
        try std.testing.expectEqualStrings(want.key, got.key);
        try std.testing.expectEqual(want.value, got.value.bool);
    }
}
