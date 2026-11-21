//! The settings spark knows, like the kernel's sysctl table: every key it reads
//! from the profile `settings.json`, a workspace override inside it, or a
//! project `.spark.json`. Startup ignores keys missing from this list; `spark doctor`
//! reports them.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Where = enum {
    /// Profile `settings.json` and its workspace overrides. A project
    /// `.spark.json` that sets it is ignored with a warning.
    profile,
    /// Also a repo-safe default in a project `.spark.json`.
    project_safe,
    /// No longer used. Read only so it is ignored without being reported.
    retired,
    /// Known in every settings file and never read by spark: `$schema`, which
    /// editors use to check the file.
    editor,
};

/// The JSON value spark accepts for a key, as `spark config schema` describes it.
pub const Kind = enum {
    /// Anything. Only retired keys, which spark ignores, use it.
    any,
    boolean,
    integer,
    string,
    /// A string, or null for the default.
    string_or_null,
    /// An array of strings.
    strings,
    /// An object whose values are strings, such as `models`.
    string_map,
    /// An object of switches, named by `children`.
    switches,
    /// An object that spark checks with its own rules, such as `permission`.
    object,
    /// The `workspaces` map from a workspace path to its overrides.
    workspaces,
    /// A key spark refuses to load, so a file that has it fails.
    refused,
};

pub const Key = struct {
    name: []const u8,
    where: Where,
    kind: Kind,
    description: []const u8,
    /// Fixed child keys of an object setting, such as `statusLine.context`.
    /// Empty for plain values and for maps. Every child is a switch.
    children: []const []const u8 = &.{},
    /// What each of `children` does, in the same order.
    child_descriptions: []const []const u8 = &.{},
    /// The strings spark accepts for a string key, or for each value of a string
    /// map, with a fixed set. spark ignores case; the schema lists the spellings
    /// spark writes and documents.
    values: []const []const u8 = &.{},
    /// Inclusive bounds of an integer key.
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    /// The most items a `strings` key may hold.
    max_items: ?usize = null,
    /// An object whose keys are free-form, such as `models.codex`.
    map: bool = false,
    /// The current name of a setting that was renamed. spark still reads the
    /// older name, writes only the current one, and the current one wins for
    /// any value both set.
    renamed_to: ?[]const u8 = null,
    /// The key that replaced an older form spark still reads but no longer
    /// writes, such as `models.gateway` for `model`.
    superseded_by: ?[]const u8 = null,
    /// Read only inside a `workspaces` entry, never at the top of the file.
    workspace_only: bool = false,
    /// Read only at the top of the profile, never inside a `workspaces` entry.
    top_level_only: bool = false,

    pub fn hasChild(self: Key, name: []const u8) bool {
        for (self.children) |child| {
            if (std.mem.eql(u8, child, name)) return true;
        }
        return false;
    }

    /// Whether editors should mark the key as old: retired, renamed, or
    /// superseded.
    pub fn deprecated(self: Key) bool {
        return self.where == .retired or self.renamed_to != null or self.superseded_by != null;
    }
};

const sound_children = [_][]const u8{ "attention_required", "max", "turn_end" };
const sound_child_descriptions = [_][]const u8{
    "Play a sound when spark needs your attention",
    "Play extra interaction sounds when sound is on",
    "Play a sound when a turn finishes",
};
const status_line_children = [_][]const u8{ "context", "session", "workspace" };
const status_line_child_descriptions = [_][]const u8{
    "Show context usage in the footer",
    "Show the session title in the footer",
    "Show the workspace path and Git branch in the footer",
};
const experimental_children = [_][]const u8{"workspace_capture"};
const experimental_child_descriptions = [_][]const u8{
    "Record the repository's state at each turn's start and end in the session, for evals",
};
const retired_description = "No longer used; spark ignores it";

pub const keys = [_]Key{
    .{ .name = "$schema", .where = .editor, .kind = .string, .top_level_only = true, .description = "The JSON Schema editors use to check this file" },
    .{ .name = "additional_directories", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Directories added to this workspace; manage them with spark workspace" },
    .{ .name = "auto_compact_percent", .where = .profile, .kind = .integer, .minimum = 10, .maximum = 80, .description = "Start automatic compaction at this percentage of usable input capacity" },
    .{ .name = "auto_upgrade", .where = .profile, .kind = .boolean, .description = "Download and install updates in the background" },
    .{ .name = "cache_warming", .where = .profile, .kind = .boolean, .description = "Keep a waiting Claude conversation's prompt cache alive for up to 30 minutes" },
    .{ .name = "codex_model", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "collapse_tool_calls", .where = .profile, .kind = .boolean, .description = "Show a summary for each group of tool calls" },
    .{ .name = "context", .where = .project_safe, .kind = .boolean, .description = "Load project instructions such as AGENTS.md" },
    .{ .name = "context_limits", .where = .profile, .kind = .object, .map = true, .description = "Context limits by name, in bytes or off, as --context-limit takes them" },
    .{ .name = "credential_source", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "disabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers rejected in this workspace; manage them with spark mcp approve and reject" },
    .{ .name = "effort", .where = .profile, .kind = .string_or_null, .description = "Reasoning effort: auto or a name the model supports; null means auto" },
    .{ .name = "enableAllProjectMcpServers", .where = .profile, .kind = .boolean, .workspace_only = true, .description = "Approve every server in this workspace's .mcp.json; manage it with spark mcp approve and reject" },
    .{ .name = "enabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers approved in this workspace; manage them with spark mcp approve and reject" },
    .{ .name = "experimental", .where = .profile, .kind = .switches, .children = &experimental_children, .child_descriptions = &experimental_child_descriptions, .description = "Unfinished features, off by default" },
    .{ .name = "fast_mode", .where = .profile, .kind = .boolean, .description = "Use faster inference when the model supports it" },
    .{ .name = "fast_mode_model_bound", .where = .profile, .kind = .boolean, .description = "Managed by spark alongside fast_mode" },
    .{ .name = "first_call_tool_choice", .where = .profile, .kind = .string, .values = &.{ "auto", "none" }, .description = "Tool choice for the first request of a turn" },
    .{ .name = "grok_model", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "input_appearance", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "max_agent_steps", .where = .project_safe, .kind = .integer, .minimum = 0, .description = "Most agent steps per turn; 0 means no limit" },
    .{ .name = "max_tool_result_bytes", .where = .project_safe, .kind = .integer, .minimum = 1024, .description = "Tool output budget in model context, in bytes" },
    .{ .name = "maxxing_mode", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "model", .where = .profile, .kind = .string, .superseded_by = "models.gateway", .description = "Older form of models.gateway" },
    .{ .name = "models", .where = .profile, .kind = .string_map, .map = true, .description = "The saved model for each provider or connection, such as {\"local\": \"<model id>\"}" },
    .{ .name = "notifications", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .renamed_to = "sound", .description = "Renamed to sound" },
    .{ .name = "permission", .where = .profile, .kind = .object, .map = true, .description = "Permission rules; manage them with /permissions" },
    .{ .name = "permission_mode", .where = .profile, .kind = .string, .values = &.{ "ask", "auto", "full-access", "yolo" }, .description = "How spark handles tool calls that need permission; yolo is an older name for full-access" },
    .{ .name = "prompt_history", .where = .profile, .kind = .switches, .children = &.{"enabled"}, .child_descriptions = &.{"Save prompts and slash commands for input history"}, .description = "Input history" },
    .{ .name = "provider", .where = .profile, .kind = .string, .description = "The model provider: a name under providers" },
    .{ .name = "provider_order", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "provider_strict", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "providers", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Named custom model connections" },
    .{ .name = "review_model", .where = .profile, .kind = .string, .description = "Unused: spark always runs with full access" },
    .{ .name = "sandbox", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "session_titles", .where = .profile, .kind = .boolean, .description = "Name each session from its first prompt" },
    // Retired, but still read so that spark can explain the migration.
    .{ .name = "skill_match_fuzzy", .where = .profile, .kind = .refused, .description = "No longer supported; spark refuses a file that sets it, so remove it" },
    .{ .name = "skill_symlink_authorities", .where = .profile, .kind = .strings, .description = "Absolute directories that symlinked skills may resolve into" },
    .{ .name = "slash_menu_categories", .where = .profile, .kind = .boolean, .description = "Show command categories and skill sources in slash menu results" },
    .{ .name = "sound", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .description = "Sounds" },
    .{ .name = "startup_scrollback", .where = .profile, .kind = .boolean, .description = "Restore terminal output at startup" },
    .{ .name = "statusLine", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .renamed_to = "status_line", .description = "Renamed to status_line" },
    .{ .name = "status_line", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .description = "What the footer shows" },
    .{ .name = "theme", .where = .profile, .kind = .string, .description = "light, dark, or the name of a theme file in ~/.spark/themes" },
    .{ .name = "tool_placement", .where = .profile, .kind = .string_map, .map = true, .values = &.{ "direct", "toolbox" }, .description = "Where each built-in tool is offered: \"direct\" sends it with the tools, \"toolbox\" lists it in the toolbox menu" },
    .{ .name = "ultrafast_mode", .where = .profile, .kind = .boolean, .description = "Request the higher-priced Ultrafast tier for an eligible model" },
    .{ .name = "update_channel", .where = .profile, .kind = .string, .values = &.{ "stable", "dev" }, .description = "Release channel for updates" },
    .{ .name = "web_fetch_worker_model", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "workspaces", .where = .profile, .kind = .workspaces, .map = true, .top_level_only = true, .description = "Overrides for each workspace, by absolute path" },
    .{ .name = "yolo_acknowledged", .where = .profile, .kind = .boolean, .description = "Managed by spark after you first confirm full-access mode" },
};

const names = blk: {
    var list: [keys.len][]const u8 = undefined;
    for (keys, 0..) |key, index| list[index] = key.name;
    break :blk list;
};

pub fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

/// True when a project `.spark.json` that sets `name` is ignored and the user
/// should be told: a known setting that only the profile may set.
pub fn ignoredInProject(name: []const u8) bool {
    const key = find(name) orelse return false;
    return key.where == .profile;
}

/// `path` under a renamed setting's current name, such as
/// `status_line.context` for `statusLine.context`. Any other path comes back
/// unchanged. The result is `path` or a string in the list.
pub fn currentPath(path: []const u8) []const u8 {
    inline for (keys) |key| {
        if (key.renamed_to) |current| {
            if (std.mem.eql(u8, path, key.name)) return current;
            inline for (key.children) |child| {
                if (std.mem.eql(u8, path, key.name ++ "." ++ child)) return current ++ "." ++ child;
            }
        }
    }
    return path;
}

pub const File = enum { profile, project };

pub const OlderName = struct {
    older: []const u8,
    current: []const u8,
    /// Whether the current name is set beside it.
    both: bool = true,
    /// The workspace override holding both, borrowed from the parsed
    /// settings, or null at the top level.
    workspace: ?[]const u8 = null,
};

/// Lists the renamed settings that `root` sets under both their older and
/// their current name, where the current one wins. A profile `settings.json`
/// is also checked inside each `workspaces` override. Caller owns the
/// returned slice; its strings borrow from `root` and the list.
pub fn findOlderNames(alloc: Allocator, root: std.json.Value, file: File) ![]OlderName {
    var found: std.ArrayList(OlderName) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);
    try appendOlderNames(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendOlderNames(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendOlderNames(alloc: Allocator, found: *std.ArrayList(OlderName), object: std.json.ObjectMap, workspace: ?[]const u8) !void {
    for (keys) |key| {
        const current = key.renamed_to orelse continue;
        const older_value = object.get(key.name) orelse continue;
        const current_value = object.get(current) orelse {
            try found.append(alloc, .{ .older = key.name, .current = current, .both = false, .workspace = workspace });
            continue;
        };
        // spark ignores a current group that isn't an object and keeps using the
        // older one, so advising to remove the older one would lose settings.
        if (older_value == .object and current_value != .object) continue;
        try found.append(alloc, .{ .older = key.name, .current = current, .workspace = workspace });
    }
}

pub const UnknownKey = struct {
    /// The key, borrowed from the parsed settings.
    name: []const u8,
    /// The object setting holding the key, such as `statusLine`, or null at
    /// the top level.
    parent: ?[]const u8 = null,
    /// The workspace override holding the key, borrowed from the parsed
    /// settings, or null outside `workspaces`.
    workspace: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Lists the keys in `root` that spark doesn't know. A profile `settings.json`
/// is also checked inside each `workspaces` override. Values of the wrong
/// type are left to the settings parser. Caller owns the returned slice;
/// its strings borrow from `root`.
pub fn findUnknown(alloc: Allocator, root: std.json.Value, file: File) ![]UnknownKey {
    var found: std.ArrayList(UnknownKey) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);

    try appendUnknown(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendUnknown(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendUnknown(
    alloc: Allocator,
    found: *std.ArrayList(UnknownKey),
    object: std.json.ObjectMap,
    workspace: ?[]const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = find(name) orelse {
            try found.append(alloc, .{ .name = name, .workspace = workspace, .known = &names });
            continue;
        };
        if (key.children.len == 0 or entry.value_ptr.* != .object) continue;
        var children = entry.value_ptr.object.iterator();
        while (children.next()) |child| {
            if (key.hasChild(child.key_ptr.*)) continue;
            try found.append(alloc, .{
                .name = child.key_ptr.*,
                .parent = key.name,
                .workspace = workspace,
                .known = key.children,
            });
        }
    }
}

pub const UnknownPart = struct {
    /// The part of the path that names no setting.
    name: []const u8,
    /// The setting holding it, such as `statusLine`, or null at the top level.
    parent: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Null when a dotted `path` names a setting: a listed key, a fixed child
/// such as `statusLine.context`, or any path into a map such as
/// `models.codex`. Otherwise the part that isn't known. Retired keys aren't
/// settings. Slices borrow from `path` and the list.
pub fn unknownPart(path: []const u8) ?UnknownPart {
    const dot = std.mem.findScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    const key = find(head) orelse return .{ .name = head, .known = &names };
    if (key.where == .retired) return .{ .name = head, .known = &names };
    const at = dot orelse return null;
    if (key.map) return null;
    const rest = path[at + 1 ..];
    const parent = key.renamed_to orelse key.name;
    if (key.children.len == 0) return .{ .name = rest, .parent = parent, .known = &.{} };
    if (std.mem.findScalar(u8, rest, '.') == null and key.hasChild(rest)) return null;
    return .{ .name = rest, .parent = parent, .known = key.children };
}

test "every key says what it holds and what it does" {
    for (keys) |key| {
        errdefer std.debug.print("key {s}\n", .{key.name});
        try std.testing.expect(key.description.len > 0);
        try std.testing.expectEqual(key.children.len, key.child_descriptions.len);
        try std.testing.expectEqual(key.children.len > 0, key.kind == .switches);
        try std.testing.expectEqual(key.where == .retired, key.kind == .any);
        try std.testing.expect(!(key.workspace_only and key.top_level_only));
        if (key.values.len > 0) try std.testing.expect(key.kind == .string or key.kind == .string_map);
        if (key.minimum != null or key.maximum != null) try std.testing.expectEqual(Kind.integer, key.kind);
        if (key.max_items != null) try std.testing.expectEqual(Kind.strings, key.kind);
        if (key.superseded_by) |path| {
            const dot = std.mem.findScalar(u8, path, '.') orelse path.len;
            try std.testing.expect(find(path[0..dot]) != null);
        }
    }
}
