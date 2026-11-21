//! `spark config`: show the values set in spark's settings files in git's
//! `key=value` format, and set or unset the plain preferences in the profile.

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("cli_flags.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const config_runtime = @import("../config/config_runtime.zig");
const env_settings = @import("../config/env_settings.zig");
const model_provider = @import("../config/model_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_messages = @import("settings_messages.zig");
const settings_store = @import("../config/settings_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const theme = @import("../shared/theme.zig");
const types = @import("../shared/types.zig");
const update_target = @import("../upgrade/update_target.zig");
const compactor = @import("../compactor/compactor.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");

const Allocator = std.mem.Allocator;

fn profileDisplay() []const u8 {
    return profile_paths.displayText("~/.spark/settings.json");
}
pub const project_display = ".spark.json";

pub const Action = enum { list, get, set, unset, schema };

pub const Options = struct {
    action: Action = .list,
    /// The key `get`, `set`, or `unset` names; null for `list`.
    key: ?[]const u8 = null,
    /// The value `set` writes, as typed.
    value: ?[]const u8 = null,
    scope: settings_entries.Scope = .all,
    show_origin: bool = false,
    format: output_contracts.OutputFormat = .text,
    /// `schema --project`: describe `.spark.json` instead of `settings.json`.
    project: bool = false,
};

const ConfigFlag = enum { global, workspace, show_origin, json, project };
const config_flag_ids = cli_flags.idTable(ConfigFlag, &builtin_commands.config_parse_options);

/// Parses `spark config [list|get <key>|set <key> <value>|unset <key>]` and its
/// flags. On a key that names no setting, sets `unknown_key` to the part that
/// isn't known; on other mistakes in the words, sets `problem` to what is
/// wrong. A value may start with a dash, as `-5` does. Slices borrow from
/// `args`.
pub fn parseArgs(
    args: []const [:0]const u8,
    unknown_key: *?settings_keys.UnknownPart,
    problem: *?[]const u8,
) error{ InvalidConfigArgs, UnknownConfigSetting, WorkspaceConfigWrite }!Options {
    var options: Options = .{};
    var words: [3][]const u8 = undefined;
    var word_count: usize = 0;
    var parser: cli_flags.Parser = .initDashOperands(&builtin_commands.config_parse_options, args);
    while (parser.next() catch return error.InvalidConfigArgs) |item| switch (item) {
        .positional => |word| {
            if (word_count == words.len) return wordsProblem(problem, "takes at most a command, a key, and a value; quote a value with spaces");
            words[word_count] = word;
            word_count += 1;
        },
        .option => |match| switch (config_flag_ids[match.index].?) {
            .global => options.scope = .global,
            .workspace => options.scope = .workspace,
            .show_origin => options.show_origin = true,
            .json => options.format = .json,
            .project => options.project = true,
        },
    };

    if (word_count == 0) {
        if (options.project) return wordsProblem(problem, "--project goes with spark config schema");
        return options;
    }
    options.action = std.meta.stringToEnum(Action, words[0]) orelse
        return wordsProblem(problem, "the first word is list, get, set, unset, or schema");
    if (options.project and options.action != .schema) return wordsProblem(problem, "--project goes with spark config schema");
    switch (options.action) {
        .list, .schema => if (word_count > 1) return wordsProblem(problem, "list and schema take no key"),
        .get, .unset => {
            if (word_count < 2) return wordsProblem(problem, "get and unset need a key, as in spark config get fast_mode");
            if (word_count > 2) return wordsProblem(problem, "get and unset take one key");
        },
        .set => if (word_count < 3) return wordsProblem(problem, if (std.mem.findScalar(u8, words[word_count - 1], '=') != null)
            "set takes the key and the value as two words, as in spark config set fast_mode true"
        else
            "set needs a key and a value, as in spark config set fast_mode true"),
    }
    if (options.action == .list) return options;
    // The schema is already JSON and describes files, not one scope's values.
    if (options.action == .schema) {
        if (options.scope != .all or options.show_origin or options.format == .json) return wordsProblem(problem, "schema takes only --project");
        return options;
    }

    // An older name, such as `statusLine.context`, means its current one.
    const key = settings_keys.currentPath(words[1]);
    if (key.len == 0) return wordsProblem(problem, "the key is empty");
    if (settings_keys.unknownPart(key)) |part| {
        unknown_key.* = part;
        return error.UnknownConfigSetting;
    }
    options.key = key;
    if (options.action == .get) return options;

    // Writes go to the profile's top level only: spark treats preferences in a
    // workspace override as legacy and removes them when it saves.
    if (options.show_origin) return wordsProblem(problem, "--show-origin goes with list and get");
    if (options.scope == .workspace) return error.WorkspaceConfigWrite;
    if (options.action == .set) options.value = words[2];
    return options;
}

/// The plain preferences `set` and `unset` change, named by their dotted keys.
/// Security and account keys aren't here on purpose: an agent can run
/// `spark config` through its shell tool, so it must not be able to raise its own
/// permissions or swap the model behind permission reviews.
const Writable = enum {
    auto_compact_percent,
    auto_upgrade,
    cache_warming,
    collapse_tool_calls,
    context,
    effort,
    fast_mode,
    max_agent_steps,
    max_tool_result_bytes,
    @"prompt_history.enabled",
    session_titles,
    slash_menu_categories,
    @"sound.attention_required",
    @"sound.max",
    @"sound.turn_end",
    startup_scrollback,
    @"status_line.context",
    @"status_line.session",
    @"status_line.workspace",
    theme,
    ultrafast_mode,
    update_channel,
};

pub const Change = struct {
    patch: settings_store.UserSettingsPatch,
    /// The value as it will be saved, or null for `unset`. Strings borrow from
    /// the arguments.
    value: ?std.json.Value,
};

pub const WriteProblem = union(enum) {
    none,
    /// The key isn't changed with `spark config`; what to use instead.
    refused: []const u8,
    /// The value doesn't fit the key; what the key takes.
    invalid_value: []const u8,
};

/// The profile change `set` or `unset` makes for `options`. Sets `problem` and
/// fails for a key `spark config` doesn't change or a value the key can't take.
pub fn change(options: Options, problem: *WriteProblem) error{ RefusedConfigSetting, InvalidConfigValue }!Change {
    const key = options.key.?;
    if (config_runtime.tool_placement.toolOfKey(key)) |tool| {
        if (options.action == .unset) return .{ .patch = .{ .remove = key }, .value = null };
        const placement = config_runtime.tool_placement.Placement.parse(options.value.?) orelse return invalid(problem, "toolbox or direct");
        return .{
            .patch = .{ .tool_placement = .{ .tool = @tagName(tool), .placement = @tagName(placement) } },
            .value = .{ .string = @tagName(placement) },
        };
    }
    const writable = std.meta.stringToEnum(Writable, key) orelse {
        problem.* = .{ .refused = ownerHint(key) };
        return error.RefusedConfigSetting;
    };
    if (options.action == .unset) return .{ .patch = .{ .remove = key }, .value = null };

    const raw = options.value.?;
    var patch: settings_store.UserSettingsPatch = .{};
    switch (writable) {
        .effort => {
            patch.effort = types.ReasoningEffort.parse(raw) orelse
                return invalid(problem, "auto or an effort name such as high");
            return .{ .patch = patch, .value = .{ .string = raw } };
        },
        .update_channel => {
            patch.update_channel = update_target.Channel.parse(raw) orelse return invalid(problem, "stable or dev");
            return .{ .patch = patch, .value = .{ .string = patch.update_channel.?.label() } };
        },
        .theme => {
            const saved: []const u8 = switch (theme.classifyValue(raw) orelse return invalid(problem, profile_paths.displayText(theme_values))) {
                .pin_light => "light",
                .pin_dark => "dark",
                .custom => |name| if (theme.validThemeName(name)) name else return invalid(problem, profile_paths.displayText(theme_values)),
            };
            patch.theme = saved;
            return .{ .patch = patch, .value = .{ .string = saved } };
        },
        .max_agent_steps => {
            const steps = std.fmt.parseUnsigned(u32, raw, 10) catch
                return invalid(problem, "a whole number of steps; 0 means no limit");
            patch.max_agent_steps = steps;
            return .{ .patch = patch, .value = .{ .integer = steps } };
        },
        .max_tool_result_bytes => {
            const bytes = std.fmt.parseUnsigned(u32, raw, 10) catch 0;
            if (bytes < tool_result_limits.min_configured_tool_result_bytes) {
                return invalid(problem, "a whole number of bytes, at least 1024");
            }
            patch.max_tool_result_bytes = bytes;
            return .{ .patch = patch, .value = .{ .integer = bytes } };
        },
        .auto_compact_percent => {
            const percent = std.fmt.parseUnsigned(u8, raw, 10) catch 0;
            if (!compactor.isValidPercent(percent)) return invalid(problem, "a whole number from 10 to 80");
            patch.auto_compact_percent = percent;
            return .{ .patch = patch, .value = .{ .integer = percent } };
        },
        else => {},
    }

    const enabled = parseSwitch(raw) orelse return invalid(problem, "true or false");
    switch (writable) {
        .auto_upgrade => patch.auto_upgrade = enabled,
        .cache_warming => patch.cache_warming = enabled,
        .collapse_tool_calls => patch.collapse_tool_calls = enabled,
        .context => patch.context = enabled,
        .fast_mode => patch.fast_mode = enabled,
        .@"prompt_history.enabled" => patch.prompt_history_enabled = enabled,
        .session_titles => patch.session_titles = enabled,
        .slash_menu_categories => patch.slash_menu_categories = enabled,
        .@"sound.attention_required" => patch.notification_attention_required = enabled,
        .@"sound.max" => patch.notification_max = enabled,
        .@"sound.turn_end" => patch.notification_turn_end = enabled,
        .startup_scrollback => patch.startup_scrollback = enabled,
        .@"status_line.context" => patch.statusline_item = .{ .item = .context, .enabled = enabled },
        .@"status_line.session" => patch.statusline_item = .{ .item = .session, .enabled = enabled },
        .@"status_line.workspace" => patch.statusline_item = .{ .item = .workspace, .enabled = enabled },
        .ultrafast_mode => patch.ultrafast_mode = enabled,
        .effort, .update_channel, .theme, .max_agent_steps, .max_tool_result_bytes, .auto_compact_percent => unreachable,
    }
    return .{ .patch = patch, .value = .{ .bool = enabled } };
}

const theme_values = "light, dark, or the name of a theme file in ~/.spark/themes";

fn invalid(problem: *WriteProblem, expected: []const u8) error{InvalidConfigValue} {
    problem.* = .{ .invalid_value = expected };
    return error.InvalidConfigValue;
}

fn parseSwitch(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "on")) return true;
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "off")) return false;
    return null;
}

fn wordsProblem(problem: *?[]const u8, text: []const u8) error{InvalidConfigArgs} {
    problem.* = text;
    return error.InvalidConfigArgs;
}

/// Whether `spark config set` and `unset` change `key`.
pub fn settable(key: []const u8) bool {
    return std.meta.stringToEnum(Writable, key) != null or config_runtime.tool_placement.toolOfKey(key) != null;
}

/// What to use instead of `spark config` for a setting it doesn't change.
fn ownerHint(key: []const u8) []const u8 {
    const head = key[0 .. std.mem.findScalar(u8, key, '.') orelse key.len];
    const hints = [_]struct { keys: []const []const u8, hint: []const u8 }{
        .{ .keys = &.{ "model", "models", "codex_model", "grok_model" }, .hint = "use /model in a session" },
        .{ .keys = &.{"provider"}, .hint = "use spark provider <name>" },
        .{ .keys = &.{"permission_mode"}, .hint = "use /permissions in a session, or --permission-mode for one run" },
        .{ .keys = &.{"permission"}, .hint = "use /permissions in a session" },
        .{ .keys = &.{ "workspaces", "additional_directories" }, .hint = "use spark workspace" },
        .{ .keys = &.{ "enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers" }, .hint = "use spark mcp approve or reject" },
        .{ .keys = &.{"context_limits"}, .hint = profile_paths.displayText("use --context-limit for one run, or edit ~/.spark/settings.json") },
        .{ .keys = &.{ "yolo_acknowledged", "fast_mode_model_bound", "skill_match_fuzzy" }, .hint = "spark manages it" },
        .{ .keys = &.{"status_line"}, .hint = "set status_line.context, status_line.session, or status_line.workspace" },
        .{ .keys = &.{"sound"}, .hint = "set sound.turn_end, sound.attention_required, or sound.max" },
        .{ .keys = &.{"prompt_history"}, .hint = "set prompt_history.enabled" },
        .{ .keys = &.{"tool_placement"}, .hint = "set tool_placement.<tool> to toolbox or direct, for one of " ++ config_runtime.tool_placement.movable_list },
    };
    for (hints) |entry| {
        for (entry.keys) |name| {
            if (std.mem.eql(u8, name, head)) return entry.hint;
        }
    }
    return profile_paths.displayText("edit ~/.spark/settings.json");
}

/// `can't change permission_mode with spark config; use /permissions ...` or
/// `invalid value for fast_mode: maybe (use true or false)`, where `via` names
/// the surface, such as `spark config` or `--config`. Caller owns the result.
pub fn formatWriteProblem(alloc: Allocator, key: []const u8, value: ?[]const u8, problem: WriteProblem, via: []const u8) ![]u8 {
    return switch (problem) {
        .none => alloc.dupe(u8, key),
        .refused => |hint| alloc.print("can't change {f} with {s}; {s}", .{ text_utils.terminalSafe(key), via, hint }),
        .invalid_value => |expected| alloc.print("invalid value for {f}: {f} (use {s})", .{ text_utils.terminalSafe(key), text_utils.terminalSafe(value orelse ""), expected }),
    };
}

pub const OverrideProblem = union(enum) {
    none,
    /// The argument isn't `key=value`.
    malformed,
    unknown: settings_keys.UnknownPart,
    write: struct { key: []const u8, value: []const u8, problem: WriteProblem },
};

/// Parses one `--config key=value` for `spark ask`, with the keys, values, and
/// checks of `spark config set`. On failure, `problem` says why. Slices borrow
/// from `text`.
pub fn parseOverride(text: []const u8, problem: *OverrideProblem) error{InvalidConfigOverride}!config_runtime.SettingOverride {
    const at = std.mem.findScalar(u8, text, '=') orelse return overrideProblem(problem, .malformed);
    const key = settings_keys.currentPath(text[0..at]);
    const value = text[at + 1 ..];
    if (key.len == 0) return overrideProblem(problem, .malformed);
    if (settings_keys.unknownPart(key)) |part| return overrideProblem(problem, .{ .unknown = part });
    var write_problem: WriteProblem = .none;
    const planned = change(.{ .action = .set, .key = key, .value = value }, &write_problem) catch
        return overrideProblem(problem, .{ .write = .{ .key = key, .value = value, .problem = write_problem } });
    return .{ .key = key, .value = planned.value.? };
}

fn overrideProblem(problem: *OverrideProblem, why: OverrideProblem) error{InvalidConfigOverride} {
    problem.* = why;
    return error.InvalidConfigOverride;
}

/// The message for a rejected `--config` value, such as `--config needs
/// key=value` or `unknown setting fast_mdoe (did you mean fast_mode?)`.
/// Caller owns the result.
pub fn formatOverrideProblem(alloc: Allocator, problem: OverrideProblem) ![]u8 {
    return switch (problem) {
        .none, .malformed => alloc.dupe(u8, "--config needs key=value, such as --config fast_mode=on"),
        .unknown => |part| settings_messages.formatUnknownPath(alloc, part),
        .write => |bad| formatWriteProblem(alloc, bad.key, bad.value, bad.problem, "--config"),
    };
}

pub const Loaded = struct {
    profile: ?std.json.Parsed(std.json.Value) = null,
    project: ?std.json.Parsed(std.json.Value) = null,
    entries: settings_entries.Entries,
    unknown: []output_contracts.ConfigUnknownSetting,
    /// Holds the values of the `SPARK_*` entries.
    env: std.heap.ArenaAllocator,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        alloc.free(self.unknown);
        self.entries.deinit(alloc);
        self.env.deinit();
        if (self.project) |*parsed| parsed.deinit();
        if (self.profile) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

/// Reads the settings files in `paths` and collects the entries and unknown
/// keys for `scope`. Without a scope, the `SPARK_*` setting overrides set in this
/// process come last, as spark applies them. When a file can't be read or parsed,
/// sets `failed_file` to its display name and returns the error. Caller deinits
/// the result.
pub fn load(
    alloc: Allocator,
    paths: config_runtime.Paths,
    workspace_root: []const u8,
    scope: settings_entries.Scope,
    failed_file: *?[]const u8,
) !Loaded {
    var profile: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (profile) |*parsed| parsed.deinit();
    if (paths.user_settings) |path| {
        failed_file.* = profileDisplay();
        profile = try config_runtime.readSettingsFileJson(alloc, path);
    }
    var project: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (project) |*parsed| parsed.deinit();
    if (scope == .all) {
        failed_file.* = project_display;
        project = try config_runtime.readSettingsFileJson(alloc, paths.workspace_settings);
    }
    failed_file.* = null;

    var entries = try settings_entries.collect(alloc, .{
        .profile = if (profile) |parsed| parsed.value else null,
        .project = if (project) |parsed| parsed.value else null,
        .workspace_root = workspace_root,
    }, scope);
    errdefer entries.deinit(alloc);

    var env: std.heap.ArenaAllocator = .init(alloc);
    errdefer env.deinit();
    if (scope == .all) {
        const overrides = try env_settings.collect(env.allocator(), savedProvider(entries.items));
        try settings_entries.appendEnv(alloc, &entries, overrides);
    }

    var unknown: std.ArrayList(output_contracts.ConfigUnknownSetting) = .empty;
    errdefer unknown.deinit(alloc);
    if (profile) |parsed| {
        const found = try settings_keys.findUnknown(alloc, parsed.value, .profile);
        defer alloc.free(found);
        for (found) |key| {
            const shown = if (key.workspace) |workspace|
                scope != .global and std.mem.eql(u8, workspace, workspace_root)
            else
                scope != .workspace;
            if (shown) try unknown.append(alloc, unknownSetting(key, profileDisplay()));
        }
    }
    if (project) |parsed| {
        const found = try settings_keys.findUnknown(alloc, parsed.value, .project);
        defer alloc.free(found);
        for (found) |key| try unknown.append(alloc, unknownSetting(key, project_display));
    }

    return .{
        .profile = profile,
        .project = project,
        .entries = entries,
        .unknown = try unknown.toOwnedSlice(alloc),
        .env = env,
    };
}

/// A key's value in a run, as `spark config` reports it.
pub const Effective = union(enum) {
    /// spark resolves the key where `spark config` doesn't look, so it reports the
    /// value the files set.
    unresolved,
    /// spark uses no value, such as an unset theme.
    none,
    value: std.json.Value,
};

/// The keys `spark config` reads from the resolved state instead of the files.
/// A test checks that each plain key is here or in `files_only_keys`.
pub const resolved_keys = [_][]const u8{
    "auto_compact_percent",           "auto_upgrade",             "cache_warming",
    "collapse_tool_calls",            "context",                  "effort",
    "experimental.workspace_capture", "fast_mode",                "first_call_tool_choice",
    "max_agent_steps",                "max_tool_result_bytes",    "permission_mode",
    "prompt_history.enabled",         "provider",                 "session_titles",
    "slash_menu_categories",          "sound.attention_required", "sound.max",
    "sound.turn_end",                 "startup_scrollback",       "status_line.context",
    "status_line.session",            "status_line.workspace",    "theme",
    "ultrafast_mode",                 "update_channel",
};

/// Keys `spark config` shows as the files set them: objects spark checks with its
/// own rules, model choices, editor hints, and values spark manages itself.
const files_only_keys = [_][]const u8{
    "$schema",                    "additional_directories", "codex_model",
    "context_limits",             "credential_source",      "disabledMcpjsonServers",
    "enableAllProjectMcpServers", "enabledMcpjsonServers",  "fast_mode_model_bound",
    "grok_model",                 "model",                  "models",
    "permission",                 "providers",              "skill_symlink_authorities",
    "tool_placement",             "workspaces",             "yolo_acknowledged",
    "review_model",
};

/// The value a run uses for `key`, read from a state that
/// `app_lifecycle.resolveSettings` filled; `provider` is the provider the run
/// selects. Strings borrow from `state`, and `arena` holds anything built here.
pub fn effectiveValue(
    arena: Allocator,
    state: *const app_lifecycle.StartupState,
    provider: model_provider.ProviderId,
    key: []const u8,
) Allocator.Error!Effective {
    const eql = std.mem.eql;
    if (eql(u8, key, "auto_compact_percent")) return integer(arena, state.auto_compact_percent);
    if (eql(u8, key, "auto_upgrade")) return boolean(state.auto_upgrade);
    if (eql(u8, key, "collapse_tool_calls")) return boolean(state.collapse_tool_calls);
    if (eql(u8, key, "context")) return boolean(state.context_enabled);
    if (eql(u8, key, "effort")) return string(state.effort.label());
    if (eql(u8, key, "experimental.workspace_capture")) return boolean(state.workspace_capture);
    if (eql(u8, key, "fast_mode")) return boolean(state.fast_mode);
    if (eql(u8, key, "first_call_tool_choice")) return string(state.first_call_tool_choice.label());
    if (eql(u8, key, "max_agent_steps")) return integer(arena, state.agent_step_limit);
    if (eql(u8, key, "max_tool_result_bytes")) return integer(arena, state.max_tool_result_bytes);
    if (eql(u8, key, "permission_mode")) return string(state.permission_mode.label());
    if (eql(u8, key, "prompt_history.enabled")) return boolean(state.prompt_history_enabled);
    if (eql(u8, key, "provider")) return string(try arena.dupe(u8, provider.label()));
    if (eql(u8, key, "session_titles")) return boolean(state.session_title_generation);
    if (eql(u8, key, "cache_warming")) return boolean(state.cache_warming);
    if (eql(u8, key, "slash_menu_categories")) return boolean(state.slash_menu_categories);
    if (eql(u8, key, "sound.attention_required")) return boolean(state.notification_attention_required);
    if (eql(u8, key, "sound.max")) return boolean(state.notification_max);
    if (eql(u8, key, "sound.turn_end")) return boolean(state.notification_turn_end);
    if (eql(u8, key, "startup_scrollback")) return boolean(state.startup_scrollback);
    if (eql(u8, key, "status_line.context")) return boolean(state.statusline_context);
    if (eql(u8, key, "status_line.session")) return boolean(state.statusline_session);
    if (eql(u8, key, "status_line.workspace")) return boolean(state.statusline_workspace);
    if (eql(u8, key, "theme")) {
        if (app_lifecycle.themeEnvOverride()) |value| return string(value);
        return if (state.theme) |value| string(value) else .none;
    }
    if (eql(u8, key, "ultrafast_mode")) return boolean(state.ultrafast_mode);
    if (eql(u8, key, "update_channel")) return string(state.update_channel.label());
    if (config_runtime.tool_placement.toolOfKey(key)) |tool| {
        return string(@tagName(config_runtime.tool_placement.placementOf(state.tool_placement, tool)));
    }
    return .unresolved;
}

fn boolean(value: bool) Effective {
    return .{ .value = .{ .bool = value } };
}

fn string(value: []const u8) Effective {
    return .{ .value = .{ .string = value } };
}

fn integer(arena: Allocator, value: usize) Allocator.Error!Effective {
    if (std.math.cast(i64, value)) |fits| return .{ .value = .{ .integer = fits } };
    return .{ .value = .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{value}) } };
}

/// The entries `spark config get` looks a key up in when no scope is chosen.
/// `set` holds the values the files and `SPARK_*` variables set, lowest
/// precedence first. Every resolved key gets the value a run uses, labeled
/// with the highest layer that sets that value, or `default` when none does,
/// as when nothing sets it or spark rejects or ignores what a file says. A key
/// spark doesn't resolve keeps its last entry in `set`. Everything is in `arena`.
pub fn effectiveEntries(
    arena: Allocator,
    state: *const app_lifecycle.StartupState,
    provider: model_provider.ProviderId,
    set: []const settings_entries.Entry,
) ![]settings_entries.Entry {
    var out: std.ArrayList(settings_entries.Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (set) |entry| {
        if (seen.contains(entry.key)) continue;
        try seen.put(arena, entry.key, {});
        switch (try effectiveValue(arena, state, provider, entry.key)) {
            .unresolved => try out.append(arena, lastEntry(set, entry.key)),
            .none => {},
            .value => |value| try out.append(arena, labeled(set, entry.key, value)),
        }
    }
    for (resolved_keys ++ config_runtime.tool_placement.setting_keys) |key| {
        if (seen.contains(key)) continue;
        switch (try effectiveValue(arena, state, provider, key)) {
            .value => |value| try out.append(arena, .{ .key = key, .value = value, .origin = .default }),
            .none, .unresolved => {},
        }
    }
    return out.toOwnedSlice(arena);
}

fn lastEntry(set: []const settings_entries.Entry, key: []const u8) settings_entries.Entry {
    var index = set.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, set[index].key, key)) return set[index];
    }
    unreachable;
}

/// `value` labeled with the highest layer in `set` that sets it.
fn labeled(set: []const settings_entries.Entry, key: []const u8, value: std.json.Value) settings_entries.Entry {
    var index = set.len;
    while (index > 0) {
        index -= 1;
        const entry = set[index];
        if (!std.mem.eql(u8, entry.key, key)) continue;
        if (sameValue(key, entry.value, value)) return .{ .key = key, .value = value, .origin = entry.origin, .variable = entry.variable };
    }
    return .{ .key = key, .value = value, .origin = .default };
}

/// Whether a file's `raw` value is the resolved `value`. Words are compared
/// after the runtime's own parse, so an older spelling such as `yolo` matches
/// `full-access`.
fn sameValue(key: []const u8, raw: std.json.Value, value: std.json.Value) bool {
    switch (raw) {
        .string => |text| if (value == .string) {
            const eql = std.mem.eql;
            if (eql(u8, key, "permission_mode")) {
                const mode = types.PermissionMode.parse(text) orelse return false;
                return eql(u8, mode.label(), value.string);
            }
            if (eql(u8, key, "effort")) {
                const effort = types.ReasoningEffort.parse(text) orelse return false;
                return eql(u8, effort.label(), value.string);
            }
            return eql(u8, text, value.string);
        },
        else => {},
    }
    return jsonEqual(raw, value);
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| b == .integer and b.integer == x,
        .float => |x| b == .float and b.float == x,
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |left, right| if (!jsonEqual(left, right)) break :blk false;
            break :blk true;
        },
        .object => false,
    };
}

/// The provider the settings files choose, which `SPARK_MODEL` applies to unless
/// `SPARK_PROVIDER` picks another.
fn savedProvider(entries: []const settings_entries.Entry) model_provider.ProviderId {
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        if (!std.mem.eql(u8, entries[index].key, "provider")) continue;
        return model_provider.parse_saved(entries[index].value) catch .none;
    }
    return .none;
}

fn unknownSetting(key: settings_keys.UnknownKey, file: []const u8) output_contracts.ConfigUnknownSetting {
    return .{ .key = key, .file = file, .suggestion = settings_messages.closest(key.name, key.known) };
}

/// Why a settings file couldn't be loaded, in words, as in
/// `~/.spark/settings.json can't be read: permission denied`.
pub fn loadFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.StreamTooLong => "is larger than 64 KiB",
        error.SyntaxError, error.UnexpectedEndOfInput, error.InvalidNumber => "isn't valid JSON",
        error.DurablePathUnsafe => "can't be read: " ++ unsafe_settings_path,
        error.AccessDenied, error.PermissionDenied => "can't be read: permission denied",
        error.NotDir => "can't be read: a folder in its path is a file",
        else => "can't be read",
    };
}

/// Why saving the profile's settings file failed, in words, with what to do
/// where there is something, as in `failed to save ~/.spark/settings.json:
/// another spark is saving settings; try again`.
pub fn saveFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.DurablePathUnsafe => unsafe_settings_path,
        error.SettingsPrimaryTooLarge, error.FileTooBig => "it is larger than 64 KiB; remove settings you no longer use",
        error.SettingsLockBusy => "another spark is saving settings; try again",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.ReadOnlyFileSystem => "the disk is read-only",
        error.NoSpaceLeft => "the disk is full",
        error.NotDir => "a folder in its path is a file",
        error.PrivateStatePermissionsUnsupported => "the file system can't keep the file private",
        error.InvalidSettingsFormat => "it isn't valid JSON; fix it or move it aside",
        else => @errorName(err),
    };
}

const unsafe_settings_path = "spark keeps settings only in a regular file in a folder it owns, not through a symlink or a hard link";

test "settings failures name the cause in words" {
    try std.testing.expectEqualStrings("can't be read: permission denied", loadFailureReason(error.AccessDenied));
    try std.testing.expectEqualStrings("can't be read", loadFailureReason(error.Unexpected));
    try std.testing.expectEqualStrings("another spark is saving settings; try again", saveFailureReason(error.SettingsLockBusy));
    try std.testing.expect(std.mem.find(u8, saveFailureReason(error.DurablePathUnsafe), "symlink") != null);
    try std.testing.expectEqualStrings("Unexpected", saveFailureReason(error.Unexpected));
}

fn parseForTest(args: []const [:0]const u8) error{ InvalidConfigArgs, UnknownConfigSetting, WorkspaceConfigWrite }!Options {
    var unknown: ?settings_keys.UnknownPart = null;
    var problem: ?[]const u8 = null;
    return parseArgs(args, &unknown, &problem);
}

fn changeForTest(args: []const [:0]const u8, problem: *WriteProblem) !Change {
    return change(try parseForTest(args), problem);
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}
