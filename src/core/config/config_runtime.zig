const std = @import("std");
const agent_steps = @import("agent_steps.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const types = @import("../shared/types.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const settings_store = @import("settings_store.zig");
const settings_keys = @import("settings_keys.zig");
const project_config = @import("../mcp/project_config.zig");
const model_provider = @import("model_provider.zig");
const model_preferences = @import("model_preferences.zig");
const configured_provider = @import("configured_provider.zig");
const update_target = @import("../upgrade/update_target.zig");
pub const context_limits = @import("context_limits.zig");
pub const tool_placement = @import("tool_placement.zig");

const Allocator = std.mem.Allocator;
const max_settings_bytes: usize = 64 * 1024;
pub const default_permission_mode: types.PermissionMode = .yolo;

pub const Paths = struct {
    home_dir: ?[]u8 = null,
    user_settings: ?[]u8 = null,
    workspace_settings: []u8,
    home_spark_dir: ?[]u8 = null,
    sessions_dir: ?[]u8 = null,
    workspace_root: []u8,

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        if (self.home_dir) |path| alloc.free(path);
        if (self.user_settings) |path| alloc.free(path);
        alloc.free(self.workspace_settings);
        if (self.home_spark_dir) |path| alloc.free(path);
        if (self.sessions_dir) |path| alloc.free(path);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const Settings = struct {
    providers: ?configured_provider.Registry = null,
    models: model_preferences.Preferences = .{},
    provider: ?model_provider.ProviderId = null,
    permission_mode: ?types.PermissionMode = null,
    credential_source: ?types.CredentialSource = null,
    yolo_acknowledged: ?bool = null,
    max_agent_steps: ?usize = null,
    max_tool_result_bytes: ?usize = null,
    /// Share of usable input, 10 to 80 percent, at which automatic
    /// compaction starts. Profile-only.
    auto_compact_percent: ?u8 = null,
    context_limits: context_limits.Overrides = .{},
    /// Where built-in tools are offered, by tool. Profile-only.
    tool_placement: tool_placement.Overrides = .{},
    first_call_tool_choice: ?types.ToolChoice = null,
    context: ?bool = null,
    fast_mode: ?bool = null,
    ultrafast_mode: ?bool = null,
    fast_mode_model_bound: ?bool = null,
    /// Owned gateway provider slugs in preference order; null leaves routing
    /// to the gateway. Freed in deinit.
    slash_menu_categories: ?bool = null,
    collapse_tool_calls: ?bool = null,
    auto_upgrade: ?bool = null,
    update_channel: ?update_target.Channel = null,
    theme: ?[]const u8 = null,
    startup_scrollback: ?bool = null,
    prompt_history_enabled: ?bool = null,
    effort: ?types.ReasoningEffort = null,
    /// Optional review-model override for automatic permission review. Owned by
    /// this Settings; freed in deinit. Null keeps the provider's default.
    statusline_context: ?bool = null,
    statusline_session: ?bool = null,
    statusline_workspace: ?bool = null,
    session_titles: ?bool = null,
    /// Ping a waiting Claude conversation's prompt cache so it stays alive.
    cache_warming: ?bool = null,
    notification_turn_end: ?bool = null,
    notification_attention_required: ?bool = null,
    notification_max: ?bool = null,
    /// `experimental.workspace_capture`, profile-only.
    experimental_workspace_capture: ?bool = null,
    /// Owned absolute directories whose contents symlinked skills may resolve
    /// into. Profile-only; a later layer replaces the whole list. Freed in deinit.
    skill_symlink_authorities: ?[][]u8 = null,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        if (self.skill_symlink_authorities) |paths| freeStringSlice(alloc, paths);
        self.models.deinit(alloc);
        if (self.providers) |*providers| providers.deinit(alloc);
        if (self.theme) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const ProjectMcpChoiceLoad = struct {
    choices: project_config.ProjectMcpChoices = .{},
    diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *ProjectMcpChoiceLoad, alloc: Allocator) void {
        self.choices.deinit(alloc);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }
};

pub const StartupStatusSettings = struct {
    model: ?[]u8 = null,
    permission_mode: ?types.PermissionMode = null,
    max_agent_steps: ?usize = null,

    pub fn deinit(self: *StartupStatusSettings, alloc: Allocator) void {
        if (self.model) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const ConfigLayer = enum {
    user,
    project,
};

pub const ConfigSource = enum {
    compiled_default,
    user_global,
    project,
    user_workspace,
    process_override,
};

pub const ModelSource = ConfigSource;

pub const ConfigSources = struct {
    models: ProviderModelSources = .{},
    provider: ConfigSource = .compiled_default,
    permission_mode: ConfigSource = .compiled_default,
    effort: ConfigSource = .compiled_default,
    fast_mode: ConfigSource = .compiled_default,
    ultrafast_mode: ConfigSource = .compiled_default,
    fast_mode_model_bound: ConfigSource = .compiled_default,
    slash_menu_categories: ConfigSource = .compiled_default,
    collapse_tool_calls: ConfigSource = .compiled_default,
    startup_scrollback: ConfigSource = .compiled_default,
    prompt_history_enabled: ConfigSource = .compiled_default,
    statusline_context: ConfigSource = .compiled_default,
    statusline_session: ConfigSource = .compiled_default,
    session_titles: ConfigSource = .compiled_default,
    cache_warming: ConfigSource = .compiled_default,
    notification_turn_end: ConfigSource = .compiled_default,
    notification_attention_required: ConfigSource = .compiled_default,
    notification_max: ConfigSource = .compiled_default,
};

pub const ProviderModelSources = struct {
    const Entry = struct { provider: model_provider.NameKey, source: ConfigSource };
    entries: [model_preferences.max_preferences]?Entry = @splat(null),

    pub fn get(self: *const ProviderModelSources, provider: model_provider.NameKey) ConfigSource {
        for (self.entries) |entry| if (entry) |*value| {
            if (value.provider.eqlName(provider.label())) return value.source;
        };
        return .compiled_default;
    }

    pub fn set(self: *ProviderModelSources, provider: model_provider.NameKey, source: ConfigSource) !void {
        for (&self.entries) |*entry| {
            if (entry.*) |*value| {
                if (!value.provider.eqlName(provider.label())) continue;
                value.source = source;
                return;
            } else {
                entry.* = .{ .provider = provider, .source = source };
                return;
            }
        }
        return error.TooManyModelPreferences;
    }
};

pub fn resolveContextLimits(settings: *const Settings, command_line: []const context_limits.Override) context_limits.Values {
    var values = context_limits.Values{};
    values.apply(settings.context_limits);
    values.applyCommandLine(command_line);
    return values;
}

pub const ConfigDiagnosticCause = enum {
    malformed_settings,
    settings_too_large,
    durable_path_unsafe,
    private_state_permissions_unsupported,
    private_state_permissions_tightened,
    invalid_model_id,
    ignored_project_user_only_setting,
    legacy_workspace_preferences,
    manual_backup_available,
    retired_skill_match_fuzzy,
    invalid_context_limits,
    invalid_tool_placement,
    invalid_additional_directories,
    invalid_skill_symlink_authorities,
    invalid_ultrafast_mode_override,
};

pub const ConfigDiagnostic = struct {
    layer: ConfigLayer,
    cause: ConfigDiagnosticCause,
    setting_key: ?[]u8 = null,
    recovery_path: ?[]u8 = null,

    pub fn reportAtStartup(self: ConfigDiagnostic) bool {
        return self.cause != .legacy_workspace_preferences and self.note() == null;
    }

    /// A one-line note for the user instead of a configuration issue.
    pub fn note(self: ConfigDiagnostic) ?[]const u8 {
        return switch (self.cause) {
            .private_state_permissions_tightened => profile_paths.displayText("Other users could write to ~/.spark, so spark took that access away. " ++
                "If you didn't write ~/.spark/settings.json yourself, check it."),
            else => null,
        };
    }

    pub fn deinit(self: *ConfigDiagnostic, alloc: Allocator) void {
        if (self.setting_key) |key| alloc.free(key);
        if (self.recovery_path) |path| alloc.free(path);
        self.* = undefined;
    }
};

pub fn writeDiagnosticMetadata(writer: *std.Io.Writer, diagnostic: ConfigDiagnostic) !void {
    if (diagnostic.setting_key) |key| try writer.print("; key={s}", .{key});
    if (diagnostic.recovery_path) |path| try writer.print("; recovery={s}", .{path});
    if (diagnostic.cause == .retired_skill_match_fuzzy) {
        try writer.writeAll("; remove skill_match_fuzzy; skills now load only through explicit invocation or toolbox open");
    }
    if (diagnostic.cause == .invalid_context_limits) {
        try writer.writeAll("; context_limits keys must be documented limit names with a non-negative integer or \"off\" value");
    }
    if (diagnostic.cause == .invalid_tool_placement) {
        try writer.writeAll("; tool_placement keys must be built-in tools that can move (" ++ tool_placement.movable_list ++ ") with the value \"toolbox\" or \"direct\"");
    }
    if (diagnostic.cause == .invalid_additional_directories) {
        try writer.print(
            "; additional_directories must be an array of at most {d} unique absolute directory paths for the current primary workspace",
            .{workspace_access.max_additional_directories},
        );
    }
    if (diagnostic.cause == .invalid_skill_symlink_authorities) {
        try writer.print(
            "; skill_symlink_authorities must be an array of at most {d} absolute directory paths without .. components",
            .{max_skill_symlink_authorities},
        );
    }
    if (diagnostic.cause == .invalid_ultrafast_mode_override) {
        try writer.writeAll("; SPARK_ULTRAFAST must be a boolean value");
    }
}

/// Upper bound on profile `skill_symlink_authorities` entries.
const max_skill_symlink_authorities: usize = 32;

pub const DetailedSettings = struct {
    settings: Settings,
    diagnostics: []ConfigDiagnostic = &.{},
    model_source: ?ModelSource = null,
    sources: ConfigSources = .{},
    /// Process-only override; null leaves the profile preference in effect.
    ultrafast_mode_env_override: ?bool = null,
    prompt_history_store_allowed: bool = true,
    additional_directories: ?[][]u8 = null,
    additional_directory_sources: ?[][]u8 = null,

    pub fn deinit(self: *DetailedSettings, alloc: Allocator) void {
        self.settings.deinit(alloc);
        if (self.additional_directories) |paths| freeStringSlice(alloc, paths);
        if (self.additional_directory_sources) |paths| freeStringSlice(alloc, paths);
        if (self.diagnostics.len > 0) {
            for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.diagnostics);
        }
        self.* = undefined;
    }
};

pub fn discoverPaths(alloc: Allocator, workspace_root: []const u8) !Paths {
    return discoverPathsWithOptionalHome(alloc, io_mod.homeDir(), workspace_root);
}

pub fn discoverPathsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Paths {
    return discoverPathsWithOptionalHome(alloc, home_dir, workspace_root);
}

pub fn providerEnvOverride() ?[]const u8 {
    const raw = io_mod.getenv("SPARK_PROVIDER") orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

/// Trimmed SPARK_MODEL, or null when unset or blank. Borrows process environment storage.
pub fn modelEnvOverride() ?[]const u8 {
    const raw = io_mod.getenv("SPARK_MODEL") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub const ModelSelectionError = error{
    ConfiguredModelNotSelected,
};

/// Chooses the provider and the model it persists as its preference. A saved
/// model wins; otherwise `run_model` (--model or SPARK_MODEL) serves this run,
/// and with no provider chosen, `default_model`.
/// The result borrows from its arguments.
pub fn selectProviderModel(
    default_model: []const u8,
    settings: *const Settings,
    provider_override: ?model_provider.ProviderId,
    run_model: ?[]const u8,
) ModelSelectionError!model_provider.ProviderSelection {
    const provider = provider_override orelse settings.provider orelse .none;
    const model = settings.models.get(provider) orelse switch (provider) {
        .none => run_model orelse default_model,
        .configured => run_model orelse return error.ConfiguredModelNotSelected,
    };
    return .{ .provider = provider, .model = model };
}

/// What spark says about a provider name that isn't built in and isn't defined
/// under "providers". `spark provider` and `spark ask --provider` both print it.
pub fn unknownProviderMessage(alloc: Allocator, name: []const u8) ![]u8 {
    return alloc.print(
        "unknown provider {s}; expected a name under \"providers\" in {s}; add one with /provider",
        .{ name, profile_paths.displayText("~/.spark/settings.json") },
    );
}

/// User-facing guidance for a `ModelSelectionError`, or null for any other error.
pub fn modelNotSelectedMessage(err: anyerror) ?[]const u8 {
    const for_this_run = "or set a model for this run with --model or SPARK_MODEL";
    return switch (err) {
        error.ConfiguredModelNotSelected => profile_paths.displayText("no model is selected for this connection; save one under \"models\" in ~/.spark/settings.json, " ++ for_this_run),
        else => null,
    };
}

fn resolve_provider_selection(settings: *Settings) !void {
    if (providerEnvOverride()) |raw| {
        settings.provider = model_provider.parse(raw) orelse return error.InvalidProviderValue;
    }
    if (settings.provider) |provider| settings.provider = try provider.bind(settings.providers orelse .{});
}

/// The raw `providers.<id>` object from the profile settings, so an edit can
/// keep fields `/provider` does not show. Allocated in `arena`; null when absent.
pub fn loadConnectionJson(arena: Allocator, id: []const u8) !?std.json.Value {
    var paths = try discoverPaths(arena, ".");
    defer paths.deinit(arena);
    const bytes = (try readOptionalUserSettingsFile(arena, paths)) orelse return null;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" });
    if (parsed != .object) return null;
    const providers = parsed.object.get("providers") orelse return null;
    if (providers != .object) return null;
    return providers.object.get(id);
}

/// The whole profile settings object, so a one-field edit can read the
/// connection and its saved model together. Allocated in `arena`; null when
/// the file is absent or isn't an object.
pub fn loadUserSettingsJson(arena: Allocator) !?std.json.Value {
    var paths = try discoverPaths(arena, ".");
    defer paths.deinit(arena);
    const bytes = (try readOptionalUserSettingsFile(arena, paths)) orelse return null;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" });
    if (parsed != .object) return null;
    return parsed;
}

/// Reads only profile-global connection definitions. Caller owns the registry.
pub fn loadConfiguredProviders(alloc: Allocator) !configured_provider.Registry {
    var paths = try discoverPaths(alloc, ".");
    defer paths.deinit(alloc);
    const bytes = (try readOptionalUserSettingsFile(alloc, paths)) orelse return .{};
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsShape;
    const definitions = parsed.value.object.get("providers") orelse return .{};
    return configured_provider.Registry.parse(alloc, definitions);
}

/// What to do when a saved session's custom connection changed or was
/// removed after the session was saved (`model_provider.ProviderId.bind`).
/// Its history may go only to that connection, so nothing is sent
/// (`tests/tla/configured_provider/ConfiguredResume.tla`).
pub fn sessionConnectionNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ConfiguredProviderChanged => profile_paths.displayText("This session's custom connection changed in ~/.spark/settings.json after the session was saved: its protocol, base_url, or auth. Change it back, or start a new session."),
        error.ConfiguredProviderRemoved => profile_paths.displayText("This session's custom connection is no longer in ~/.spark/settings.json. Add it back, or start a new session."),
        else => null,
    };
}

/// spark's words for an error a custom connection's settings caused: the file,
/// the setting's path, and what to do, the header whose environment variable
/// cannot be sent, or a saved session's changed or removed connection. Null
/// for any other error, and when the settings no longer show it. Reads the
/// settings again, so call it only on a failure. Caller owns the message.
pub fn configuredProviderMessage(alloc: Allocator, err: anyerror) Allocator.Error!?[]u8 {
    if (sessionConnectionNotice(err)) |notice| return try alloc.dupe(u8, notice);
    if (configured_provider.failure_advice(err)) |advice| {
        var at: configured_provider.FailurePath = .{};
        const refusal = (try refusedProviderSetting(alloc, &at)) orelse return null;
        if (refusal.err != err) return null;
        return try alloc.print("{s}: providers.{s}: {s}", .{ profile_paths.displayText("~/.spark/settings.json"), at.text(), advice });
    }
    if (err == error.MissingConfiguredProviderHeader or err == error.InvalidConfiguredProviderHeader) return headerVariableMessage(alloc);
    return null;
}

const ProviderRefusal = struct { err: anyerror };

/// The error the profile's providers fail to parse with, leaving in `at` where
/// the refused setting is; null when they parse or cannot be read.
fn refusedProviderSetting(alloc: Allocator, at: *configured_provider.FailurePath) Allocator.Error!?ProviderRefusal {
    var paths = discoverPaths(alloc, ".") catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
    defer paths.deinit(alloc);
    const bytes = (readOptionalUserSettingsFile(alloc, paths) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null) orelse return null;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const providers = parsed.value.object.get("providers") orelse return null;
    var registry = configured_provider.Registry.parse_located(alloc, providers, at) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = err },
    };
    registry.deinit(alloc);
    return null;
}

/// Names each header whose environment variable cannot be sent, by the rule
/// the transport applies (`configured_provider.header_value`), with its
/// connection: the error doesn't say which connection's request failed, so
/// a message about one header must not stand for another's.
fn headerVariableMessage(alloc: Allocator) Allocator.Error!?[]u8 {
    var registry = loadConfiguredProviders(alloc) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
    defer registry.deinit(alloc);
    var listed: std.ArrayList(u8) = .empty;
    defer listed.deinit(alloc);
    var only: ?[]u8 = null;
    defer if (only) |message| alloc.free(message);
    var count: usize = 0;
    for (registry.definitions) |definition| {
        for (definition.headers) |header| {
            if (header.session_id) continue;
            const state = configured_provider.header_value(io_mod.getenv(header.env));
            if (state == .usable) continue;
            count += 1;
            if (count == 1) only = try alloc.print("the header {s} of connection {s} reads {s}, {s}", .{ header.name, definition.id, header.env, headerProblem(state, true) });
            if (count > max_listed_headers) continue;
            if (count > 1) try listed.appendSlice(alloc, "; ");
            try listed.print(alloc, "{s} of connection {s} reads {s}, {s}", .{ header.name, definition.id, header.env, headerProblem(state, false) });
        }
    }
    if (count == 0) return null;
    if (count == 1) {
        defer only = null;
        return only.?;
    }
    const advice = profile_paths.displayText("Set or fix each variable, or remove its header from ~/.spark/settings.json");
    const unlisted = count -| max_listed_headers;
    if (unlisted == 0) return try alloc.print("{d} headers can't be sent: {s}. {s}", .{ count, listed.items, advice });
    return try alloc.print("{d} headers can't be sent: {s} ({d} more). {s}", .{ count, listed.items, unlisted, advice });
}

const max_listed_headers = 3;

/// Why a header's variable can't be sent; with `fix`, also what to do.
fn headerProblem(state: configured_provider.HeaderValue, fix: bool) []const u8 {
    return switch (state) {
        .usable => "which can be sent",
        .unset => if (fix) profile_paths.displayText("which is not set; set it, or remove the header from ~/.spark/settings.json") else "which is not set",
        .empty => if (fix) profile_paths.displayText("which is empty; set it, or remove the header from ~/.spark/settings.json") else "which is empty",
        .too_long => if (fix)
            std.fmt.comptimePrint("whose value is longer than {d} bytes; shorten it", .{configured_provider.max_header_value_bytes})
        else
            std.fmt.comptimePrint("whose value is longer than {d} bytes", .{configured_provider.max_header_value_bytes}),
        .unsendable => if (fix) "whose value has a character a header can't carry; fix the variable" else "whose value has a character a header can't carry",
    };
}

pub fn loadMergedSettings(alloc: Allocator, workspace_root: []const u8) !Settings {
    var paths = try discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);
    return loadMergedSettingsFromPaths(alloc, paths);
}

pub fn loadProjectMcpChoices(
    alloc: Allocator,
    workspace_root: []const u8,
) !ProjectMcpChoiceLoad {
    const home = io_mod.homeDir() orelse return .{};
    return loadProjectMcpChoicesFromHome(alloc, home, workspace_root);
}

pub fn loadProjectMcpChoicesFromHome(
    alloc: Allocator,
    home: []const u8,
    workspace_root: []const u8,
) !ProjectMcpChoiceLoad {
    var store = try settings_store.Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);
    var primary = try store.loadPrimary(alloc);
    defer primary.deinit(alloc);
    const bytes = switch (primary) {
        .absent => return .{},
        .valid => |value| value,
        .invalid => return error.InvalidSettingsFormat,
        .oversized => return error.SettingsPrimaryTooLarge,
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsFormat;
    const workspaces = parsed.value.object.get("workspaces") orelse return .{};
    if (workspaces != .object) return error.InvalidSettingsFormat;
    const normalized_root = normalizeWorkspaceRoot(workspace_root);
    const workspace = workspaces.object.get(normalized_root) orelse return .{};

    var result: ProjectMcpChoiceLoad = .{};
    errdefer result.deinit(alloc);
    result.choices = project_config.parseChoices(
        alloc,
        workspace,
        &result.diagnostics,
    ) catch return error.InvalidSettingsFormat;
    return result;
}

pub fn loadMergedSettingsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Settings {
    var paths = try discoverPathsFromHome(alloc, home_dir, workspace_root);
    defer paths.deinit(alloc);
    return loadMergedSettingsFromPaths(alloc, paths);
}

pub fn loadMergedSettingsDetailedFromHome(
    alloc: Allocator,
    home_dir: []const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, home_dir, workspace_root);
}

pub fn loadMergedSettingsDetailed(alloc: Allocator, workspace_root: []const u8) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, io_mod.homeDir(), workspace_root);
}

fn loadMergedSettingsDetailedWithOptionalHome(
    alloc: Allocator,
    home_dir: ?[]const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);
    var diagnostics: std.ArrayList(ConfigDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        diagnostics.deinit(alloc);
    }
    var sources = ConfigSources{};
    var prompt_history_store_allowed = home_dir != null;
    var additional_directories: ?[][]u8 = null;
    errdefer if (additional_directories) |paths| freeStringSlice(alloc, paths);
    var additional_directory_sources: ?[][]u8 = null;
    errdefer if (additional_directory_sources) |paths| freeStringSlice(alloc, paths);
    const detailed_merge_state: DetailedSettingsMergeState = .{
        .settings = &settings,
        .sources = &sources,
        .diagnostics = &diagnostics,
        .prompt_history_store_allowed = &prompt_history_store_allowed,
    };

    var user_root: ?std.json.Parsed(std.json.Value) = null;
    defer if (user_root) |*parsed| parsed.deinit();

    if (home_dir) |home| {
        var store: ?settings_store.Store = settings_store.Store.initFromHomeTighteningReadOnly(alloc, home) catch |err| blk: {
            prompt_history_store_allowed = false;
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = diagnosticCauseForUserStoreError(err),
            });
            break :blk null;
        };
        if (store) |*usable_store| {
            defer usable_store.deinit(alloc);
            var primary = usable_store.loadPrimary(alloc) catch |err| blk: {
                prompt_history_store_allowed = false;
                try diagnostics.append(alloc, .{
                    .layer = .user,
                    .cause = diagnosticCauseForUserStoreError(err),
                });
                break :blk settings_store.PrimaryLoad.absent;
            };
            defer primary.deinit(alloc);
            switch (primary) {
                .absent => {},
                .invalid => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .oversized => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .settings_too_large });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .valid => |bytes| {
                    user_root = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
                    if (user_root.?.value != .object) {
                        prompt_history_store_allowed = false;
                        try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                        user_root.?.deinit();
                        user_root = null;
                    }
                },
            }
            if (usable_store.tightened.any()) {
                try diagnostics.append(alloc, .{ .layer = .user, .cause = .private_state_permissions_tightened });
            }
        }
    }

    const project_path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".spark.json" });
    defer alloc.free(project_path);
    const project_text = readOptionalFile(alloc, project_path) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = switch (err) {
                error.StreamTooLong => .settings_too_large,
                error.DurablePathUnsafe => .durable_path_unsafe,
                else => .malformed_settings,
            },
        });
        break :blk null;
    };
    defer if (project_text) |text| alloc.free(text);
    if (project_text) |text| {
        if (std.json.parseFromSlice(std.json.Value, alloc, text, .{})) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            if (parsed.value != .object) {
                try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
            } else {
                try appendIgnoredProjectProfileSettingDiagnostics(alloc, &diagnostics, parsed.value);
                try mergeDetailedSettingsLayer(
                    alloc,
                    &detailed_merge_state,
                    parsed.value,
                    .project,
                    false,
                    .project,
                    .project,
                );
            }
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
        }
    }

    if (user_root) |parsed| {
        if (parsed.value.object.contains("additional_directories")) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .invalid_additional_directories,
                .setting_key = try alloc.dupe(u8, "additional_directories"),
            });
        }
        if (hasLegacyWorkspacePreferences(parsed.value)) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .legacy_workspace_preferences,
            });
        }
        try mergeDetailedSettingsLayer(
            alloc,
            &detailed_merge_state,
            parsed.value,
            .profile,
            false,
            .user,
            .user_global,
        );
    }

    if (user_root) |parsed| {
        const workspaces = parsed.value.object.get("workspaces");
        if (workspaces) |workspaces_value| {
            if (workspaces_value != .object) {
                try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
            } else if (workspaces_value.object.get(workspace_root)) |workspace_value| {
                if (workspace_value != .object) {
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                } else {
                    if (workspace_value.object.get("additional_directories")) |value| {
                        const parsed_directories = parseAdditionalDirectories(
                            alloc,
                            workspace_root,
                            value,
                        ) catch |err| blk: {
                            if (err == error.OutOfMemory) return err;
                            try diagnostics.append(alloc, .{
                                .layer = .user,
                                .cause = .invalid_additional_directories,
                                .setting_key = try alloc.dupe(u8, "additional_directories"),
                            });
                            break :blk null;
                        };
                        if (parsed_directories) |directories| {
                            additional_directories = directories.canonical;
                            additional_directory_sources = directories.sources;
                        }
                    }
                    try mergeDetailedSettingsLayer(
                        alloc,
                        &detailed_merge_state,
                        workspace_value,
                        .profile,
                        true,
                        .user,
                        .user_workspace,
                    );
                }
            }
        }
    }

    try resolve_provider_selection(&settings);
    if (providerEnvOverride() != null) sources.provider = .process_override;
    if (modelEnvOverride() != null) {
        const override_provider = model_provider.NameKey.fromProvider(settings.provider orelse .none);
        sources.models.set(override_provider, .process_override) catch |err| switch (err) {
            error.TooManyModelPreferences => debug_trace.logf(
                "config",
                "dropping process model override provenance provider={s}: provenance table holds at most {d} provider names",
                .{ override_provider.label(), model_preferences.max_preferences },
            ),
        };
    }
    const ultrafast_mode_env_override = ultrafastModeEnvOverride() catch |err| blk: {
        try diagnostics.append(alloc, .{
            .layer = .user,
            .cause = .invalid_ultrafast_mode_override,
        });
        debug_trace.logf("config", "invalid SPARK_ULTRAFAST value err={s}", .{@errorName(err)});
        break :blk null;
    };

    return .{
        .settings = settings,
        .diagnostics = try diagnostics.toOwnedSlice(alloc),
        .model_source = sources.models.get(model_provider.NameKey.fromProvider(settings.provider orelse .none)),
        .sources = sources,
        .ultrafast_mode_env_override = ultrafast_mode_env_override,
        .prompt_history_store_allowed = prompt_history_store_allowed,
        .additional_directories = additional_directories,
        .additional_directory_sources = additional_directory_sources,
    };
}

const ParsedAdditionalDirectories = struct {
    canonical: [][]u8,
    sources: [][]u8,
};

pub const UltrafastModeEnvError = error{InvalidUltrafastMode};

/// Reads the process-only paid lane override using the repository's standard
/// environment-boolean vocabulary. A malformed value cannot widen cost.
pub fn ultrafastModeEnvOverride() UltrafastModeEnvError!?bool {
    const raw = io_mod.getenv("SPARK_ULTRAFAST") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return parseEnvBool(trimmed) orelse error.InvalidUltrafastMode;
}

/// The env-var booleans: `1`, `true`, `on`, or `yes`, and `0`, `false`, `off`,
/// or `no`, in any case.
pub fn parseEnvBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "on") or std.ascii.eqlIgnoreCase(raw, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    return null;
}

fn parseAdditionalDirectories(
    alloc: Allocator,
    workspace_root: []const u8,
    value: std.json.Value,
) !ParsedAdditionalDirectories {
    if (value != .array) return error.InvalidAdditionalDirectories;

    var raw_paths: std.ArrayList([]const u8) = .empty;
    defer raw_paths.deinit(alloc);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidAdditionalDirectories;
        if (raw_paths.items.len >= workspace_access.max_additional_directories) {
            return error.InvalidAdditionalDirectories;
        }
        for (raw_paths.items) |path| {
            if (std.mem.eql(u8, path, item.string)) return error.InvalidAdditionalDirectories;
        }
        try raw_paths.append(alloc, item.string);
    }

    var access = workspace_access.WorkspaceAccess.init(
        alloc,
        workspace_root,
        raw_paths.items,
        &.{},
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAdditionalDirectories,
    };
    defer access.deinit(alloc);
    const canonical = try access.savedDirectoriesAlloc(alloc);
    errdefer freeStringSlice(alloc, canonical);
    return .{
        .canonical = canonical,
        .sources = try access.savedSourcePathsAlloc(alloc),
    };
}

fn hasLegacyWorkspacePreferences(root: std.json.Value) bool {
    if (root != .object) return false;
    const workspaces = root.object.get("workspaces") orelse return false;
    if (workspaces != .object) return false;

    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const workspace = entry.value_ptr.object;
        inline for (&.{
            "model",
            "effort",
            "fast_mode",
            "ultrafast_mode",
            "fast_mode_model_bound",
            "slash_menu_categories",
            "collapse_tool_calls",
            "startup_scrollback",
        }) |key| {
            if (workspace.contains(key)) return true;
        }
        if (workspace.get("prompt_history")) |value| {
            if (value == .object and value.object.contains("enabled")) return true;
        }
        for ([_]?std.json.Value{ workspace.get("statusLine"), workspace.get("status_line") }) |group| {
            if (group) |value| {
                if (value == .object and
                    (value.object.contains("context") or
                        value.object.contains("session")))
                {
                    return true;
                }
            }
        }
    }
    return false;
}

fn appendIgnoredProjectProfileSettingDiagnostics(
    alloc: Allocator,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    root: std.json.Value,
) !void {
    if (root != .object) return;
    var iterator = root.object.iterator();
    while (iterator.next()) |entry| {
        if (!settings_keys.ignoredInProject(entry.key_ptr.*)) continue;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = .ignored_project_user_only_setting,
            .setting_key = try alloc.dupe(u8, entry.key_ptr.*),
        });
    }
}

/// The profile layer parse is atomic: one malformed field discards every
/// field, including provider routing. When that happens, re-parse only the
/// provider routing triple (connections, selection, per-provider models)
/// through the same layer-scoped parser so a broken sibling (for example a
/// mistyped effort) cannot silently drop the configured connection and fall
/// back to Gateway. The layer scope is identical to normal parsing, so
/// workspace override provider definitions stay ignored here too. Returns
/// true when the layer declared routing that is now installed; errors when
/// the routing fields themselves are broken.
fn salvageProviderRouting(alloc: Allocator, settings: *Settings, sources: *ConfigSources, value: std.json.Value, layer: SettingsLayer, source: ConfigSource) error{ OutOfMemory, InvalidProviderRouting }!bool {
    var routing_only: std.json.ObjectMap = .empty;
    defer routing_only.deinit(alloc);
    for ([_][]const u8{ "provider", "providers", "models" }) |key| {
        const field = value.object.get(key) orelse continue;
        routing_only.put(alloc, key, field) catch return error.OutOfMemory;
    }
    if (routing_only.count() == 0) return false;
    var salvaged = parseSettingsValueForLayer(alloc, .{ .object = routing_only }, layer, false, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderRouting,
    };
    defer salvaged.deinit(alloc);
    if (salvaged.provider == null and salvaged.providers == null and salvaged.models.isEmpty()) return false;
    updateConfigSources(sources, salvaged, source);
    if (salvaged.providers) |registry| {
        if (settings.providers) |*old| old.deinit(alloc);
        settings.providers = registry;
        salvaged.providers = null;
    }
    if (salvaged.provider) |provider| settings.provider = provider;
    settings.models.mergeOwnedFrom(alloc, &salvaged.models) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyModelPreferences => return error.InvalidProviderRouting,
    };
    return true;
}

fn updateConfigSources(sources: *ConfigSources, settings: Settings, source: ConfigSource) void {
    for (settings.models.entries.items) |entry| sources.models.set(entry.provider, source) catch |err| switch (err) {
        error.TooManyModelPreferences => debug_trace.logf(
            "config",
            "dropping model provenance provider={s} source={s}: provenance table holds at most {d} provider names",
            .{ entry.provider.label(), @tagName(source), model_preferences.max_preferences },
        ),
    };
    if (settings.provider != null) sources.provider = source;
    if (settings.permission_mode != null) sources.permission_mode = source;
    if (settings.effort != null) sources.effort = source;
    if (settings.fast_mode != null) sources.fast_mode = source;
    if (settings.ultrafast_mode != null) sources.ultrafast_mode = source;
    if (settings.fast_mode_model_bound != null) sources.fast_mode_model_bound = source;
    if (settings.slash_menu_categories != null) sources.slash_menu_categories = source;
    if (settings.collapse_tool_calls != null) sources.collapse_tool_calls = source;
    if (settings.session_titles != null) sources.session_titles = source;
    if (settings.cache_warming != null) sources.cache_warming = source;
    if (settings.startup_scrollback != null) sources.startup_scrollback = source;
    if (settings.prompt_history_enabled != null) sources.prompt_history_enabled = source;
    if (settings.statusline_context != null) sources.statusline_context = source;
    if (settings.statusline_session != null) sources.statusline_session = source;
    if (settings.notification_turn_end != null) sources.notification_turn_end = source;
    if (settings.notification_attention_required != null) sources.notification_attention_required = source;
    if (settings.notification_max != null) sources.notification_max = source;
}

const DetailedSettingsMergeState = struct {
    settings: *Settings,
    sources: *ConfigSources,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    prompt_history_store_allowed: *bool,
};

fn mergeDetailedSettingsLayer(
    alloc: Allocator,
    state: *const DetailedSettingsMergeState,
    value: std.json.Value,
    settings_layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    diagnostic_layer: ConfigLayer,
    source: ConfigSource,
) !void {
    if (parseSettingsValueForLayer(
        alloc,
        value,
        if (source == .user_workspace) .profile_workspace else settings_layer,
        tolerate_non_object_user_containers,
        source != .user_workspace,
    )) |layer_settings| {
        var incoming = layer_settings;
        defer incoming.deinit(alloc);
        incoming.context_limits.retag(switch (source) {
            .user_global => .user_global,
            .user_workspace => .user_workspace,
            else => .compiled_default,
        });
        if (source == .user_workspace) {
            incoming.update_channel = null;
        }
        updateConfigSources(state.sources, incoming, source);
        try mergeSettings(state.settings, &incoming, alloc);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        if (diagnostic_layer == .user and value == .object) {
            _ = salvageProviderRouting(alloc, state.settings, state.sources, value, if (source == .user_workspace) .profile_workspace else settings_layer, source) catch |salvage_err| switch (salvage_err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidProviderRouting => return err,
            };
        }
        if (diagnostic_layer == .user and err == error.InvalidModelValue) state.prompt_history_store_allowed.* = false;
        try state.diagnostics.append(alloc, .{
            .layer = diagnostic_layer,
            .cause = diagnosticCauseForParseError(err),
        });
    }
}

fn diagnosticCauseForParseError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.InvalidModelValue => .invalid_model_id,
        error.RetiredSkillMatchFuzzy => .retired_skill_match_fuzzy,
        error.InvalidContextLimitsType,
        error.UnknownContextLimit,
        error.InvalidContextLimitValue,
        => .invalid_context_limits,
        error.InvalidToolPlacementType,
        error.UnknownToolPlacementTool,
        error.InvalidToolPlacementValue,
        => .invalid_tool_placement,
        error.InvalidSkillSymlinkAuthorities => .invalid_skill_symlink_authorities,
        else => .malformed_settings,
    };
}

fn diagnosticCauseForUserStoreError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.DurablePathUnsafe => .durable_path_unsafe,
        error.PrivateStatePermissionsUnsupported => .private_state_permissions_unsupported,
        else => .malformed_settings,
    };
}

pub fn loadStartupStatusSettingsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !StartupStatusSettings {
    var paths = try discoverPathsFromHome(alloc, home_dir, workspace_root);
    defer paths.deinit(alloc);
    return loadStartupStatusSettingsFromPaths(alloc, paths);
}

pub fn ensureStateLayout(paths: Paths) !void {
    if (paths.home_spark_dir) |dir| try ensureAbsoluteDir(dir);
    if (paths.sessions_dir) |dir| try ensureAbsoluteDir(dir);
}

pub fn parsePermissionMode(raw: []const u8) ?types.PermissionMode {
    return types.PermissionMode.parse(raw);
}

pub fn makeAbsolutePath(path_abs: []const u8) !void {
    const zio = io_mod.getIo();
    var root = try std.Io.Dir.openDirAbsolute(zio, "/", .{});
    defer root.close(zio);

    const relative_to_root = std.mem.trimStart(u8, path_abs, "/");
    if (relative_to_root.len == 0) return;
    try root.createDirPath(zio, relative_to_root);
}

fn ensureAbsoluteDir(path_abs: []const u8) !void {
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try makeAbsolutePath(path_abs);
            return;
        },
        else => return err,
    };
    dir.close(zio);
}

pub fn userSettingsPath(alloc: Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    return try profile_paths.settingsPath(alloc, home);
}

pub const StatuslineItem = settings_store.StatuslineItem;
pub const UserSettingsPatch = settings_store.UserSettingsPatch;
pub const WorkspaceDirectoryMutation = settings_store.WorkspaceDirectoryMutation;
pub const CommitOutcome = settings_store.CommitOutcome;
pub const LegacyCleanup = settings_store.LegacyCleanup;

pub const CommitFailure = struct {
    err: anyerror,
    cleanup: LegacyCleanup = .{},

    pub fn deinit(self: *CommitFailure, alloc: Allocator) void {
        self.cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const CommitAttempt = union(enum) {
    outcome: CommitOutcome,
    failure: CommitFailure,

    pub fn deinit(self: *CommitAttempt, alloc: Allocator) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn attemptUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) CommitAttempt {
    const home = io_mod.homeDir() orelse return .{ .failure = .{ .err = error.HomeNotSet } };
    return attemptUserPreferencesInHome(alloc, home, patch);
}

/// Like attemptUserPreferences, for hosts that run with their own home.
pub fn attemptUserPreferencesInHome(
    alloc: Allocator,
    home: []const u8,
    patch: UserSettingsPatch,
) CommitAttempt {
    var store = settings_store.Store.initFromHome(alloc, home, .writable) catch |err| {
        return .{ .failure = .{ .err = err } };
    };
    defer store.deinit(alloc);
    const outcome = store.applyUserPatch(alloc, patch) catch |err| {
        return .{ .failure = .{
            .err = err,
            .cleanup = store.takeFailureCleanup(),
        } };
    };
    return .{ .outcome = outcome };
}

pub fn attemptProjectMcpMutation(
    alloc: Allocator,
    workspace_root: []const u8,
    action: project_config.ProjectMcpAction,
) CommitAttempt {
    const home = io_mod.homeDir() orelse return .{ .failure = .{ .err = error.HomeNotSet } };
    var store = settings_store.Store.initFromHome(alloc, home, .writable) catch |err| {
        return .{ .failure = .{ .err = err } };
    };
    defer store.deinit(alloc);
    const outcome = store.applyProjectMcpMutation(alloc, .{
        .workspace_root = workspace_root,
        .action = action,
    }) catch |err| return .{ .failure = .{
        .err = err,
        .cleanup = store.takeFailureCleanup(),
    } };
    return .{ .outcome = outcome };
}

pub fn setUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) !CommitOutcome {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyUserPatch(alloc, patch);
}

pub fn mutateWorkspaceDirectory(
    alloc: Allocator,
    mutation: WorkspaceDirectoryMutation,
) !CommitOutcome {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyWorkspaceDirectoryPatch(alloc, mutation);
}

fn discoverPathsWithOptionalHome(alloc: Allocator, home_dir: ?[]const u8, workspace_root: []const u8) !Paths {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var paths: Paths = .{
        .workspace_settings = undefined,
        .workspace_root = try alloc.dupe(u8, trimmed_workspace),
    };
    errdefer alloc.free(paths.workspace_root);

    if (home_dir) |home| {
        paths.home_dir = try alloc.dupe(u8, home);
        errdefer alloc.free(paths.home_dir.?);

        paths.home_spark_dir = try profile_paths.rootDir(alloc, home);
        errdefer alloc.free(paths.home_spark_dir.?);

        paths.user_settings = try profile_paths.settingsPath(alloc, home);
        errdefer alloc.free(paths.user_settings.?);

        paths.sessions_dir = try profile_paths.sessionsDir(alloc, home);
        errdefer alloc.free(paths.sessions_dir.?);
    }

    paths.workspace_settings = try std.Io.Dir.path.join(alloc, &.{ trimmed_workspace, ".spark.json" });
    errdefer alloc.free(paths.workspace_settings);

    return paths;
}

pub fn loadMergedSettingsFromPaths(alloc: Allocator, paths: Paths) !Settings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);

    const user_text = try readOptionalUserSettingsFile(alloc, paths);
    defer if (user_text) |owned| alloc.free(owned);

    if (user_text) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettingsShape;

        try mergeSettingsFile(&settings, alloc, paths.workspace_settings);

        var user_settings = try parseSettingsValueForLayer(alloc, parsed.value, .profile, false, true);
        defer user_settings.deinit(alloc);
        user_settings.context_limits.retag(.user_global);
        try mergeSettings(&settings, &user_settings, alloc);

        try mergeWorkspaceOverridesFromValue(&settings, alloc, parsed.value, paths.workspace_root);
        try resolve_provider_selection(&settings);
        return settings;
    }

    try mergeSettingsFile(&settings, alloc, paths.workspace_settings);
    try resolve_provider_selection(&settings);
    return settings;
}

pub fn loadStartupStatusSettingsFromPaths(alloc: Allocator, paths: Paths) !StartupStatusSettings {
    return loadStartupStatusSettingsFromPathsFast(alloc, paths) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var settings = try loadMergedSettingsFromPaths(alloc, paths);
            defer settings.deinit(alloc);
            return startupStatusSettingsFromSettings(alloc, settings);
        },
    };
}

fn loadStartupStatusSettingsFromPathsFast(alloc: Allocator, paths: Paths) !StartupStatusSettings {
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    const user_text = try readOptionalUserSettingsFile(alloc, paths);
    defer if (user_text) |owned| alloc.free(owned);

    if (try readOptionalFile(alloc, paths.workspace_settings)) |workspace_text| {
        defer alloc.free(workspace_text);
        var workspace_settings = try parseStartupStatusSettingsJson(alloc, workspace_text, null, .project);
        defer workspace_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
    }

    if (user_text) |text| {
        var user_settings = try parseStartupStatusSettingsJson(alloc, text, null, .profile);
        defer user_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &user_settings, alloc);
    }

    if (user_text) |text| {
        var override_settings = try parseStartupStatusSettingsJson(alloc, text, paths.workspace_root, .profile);
        defer override_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &override_settings, alloc);
    }

    return settings;
}

fn readOptionalUserSettingsFile(alloc: Allocator, paths: Paths) !?[]u8 {
    if (paths.home_dir) |home| {
        var store = try settings_store.Store.initFromHome(alloc, home, .read_only);
        defer store.deinit(alloc);
        var primary = try store.loadPrimary(alloc);
        errdefer primary.deinit(alloc);
        return switch (primary) {
            .absent => null,
            .valid => |bytes| blk: {
                primary = .absent;
                break :blk bytes;
            },
            .invalid => error.InvalidSettingsFormat,
            .oversized => error.StreamTooLong,
        };
    }
    if (paths.user_settings) |path| return try readOptionalFile(alloc, path);
    return null;
}

fn startupStatusSettingsFromSettings(alloc: Allocator, settings: Settings) !StartupStatusSettings {
    return .{
        .model = if (settings.provider) |provider| if (settings.models.get(provider)) |model| try alloc.dupe(u8, model) else null else null,
        .permission_mode = settings.permission_mode,
        .max_agent_steps = settings.max_agent_steps,
    };
}

fn mergeStartupStatusSettings(target: *StartupStatusSettings, incoming: *StartupStatusSettings, alloc: Allocator) void {
    if (incoming.model) |value| {
        if (target.model) |current| alloc.free(current);
        target.model = value;
        incoming.model = null;
    }
    if (incoming.permission_mode) |value| target.permission_mode = value;
    if (incoming.max_agent_steps) |value| target.max_agent_steps = value;
}

fn mergeWorkspaceOverridesFromValue(target: *Settings, alloc: Allocator, root_value: std.json.Value, workspace_root: []const u8) !void {
    if (root_value != .object) return error.InvalidSettingsShape;

    const workspaces_val = root_value.object.get("workspaces") orelse return;
    if (workspaces_val != .object) return;

    const override_val = workspaces_val.object.get(workspace_root) orelse return;
    if (override_val != .object) return;

    var override_settings = try parseSettingsValueForLayer(alloc, override_val, .profile_workspace, true, false);
    defer override_settings.deinit(alloc);
    override_settings.update_channel = null;
    override_settings.context_limits.retag(.user_workspace);
    try mergeSettings(target, &override_settings, alloc);
}

fn mergeSettingsFile(target: *Settings, alloc: Allocator, path: []const u8) !void {
    const bytes = (try readOptionalFile(alloc, path)) orelse return;
    defer alloc.free(bytes);

    var parsed = try parseSettingsJsonForLayer(alloc, bytes, .project);
    defer parsed.deinit(alloc);
    try mergeSettings(target, &parsed, alloc);
}

fn readOptionalFile(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = io_mod.openExistingRegularFile(
        std.Io.Dir.cwd(),
        path,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size > max_settings_bytes) return error.StreamTooLong;
    return try io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1);
}

/// One `--config key=value` for a single run, with the value already checked
/// and in settings-file form. The key is dotted, such as `statusLine.context`.
pub const SettingOverride = struct {
    key: []const u8,
    value: std.json.Value,
};

/// Applies one run's `--config` values as the top settings layer, above every
/// settings file. Flags and SPARK_* variables are resolved later, so they still
/// win, as they do over the files. A later override for a key replaces an
/// earlier one. Nothing is saved.
pub fn applySettingOverrides(alloc: Allocator, settings: *Settings, overrides: []const SettingOverride) !void {
    if (overrides.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    var root: std.json.ObjectMap = .empty;
    for (overrides) |override| {
        const dot = std.mem.findScalar(u8, override.key, '.') orelse {
            try root.put(scratch, override.key, override.value);
            continue;
        };
        const parent = try root.getOrPut(scratch, override.key[0..dot]);
        if (!parent.found_existing or parent.value_ptr.* != .object) parent.value_ptr.* = .{ .object = .empty };
        try parent.value_ptr.object.put(scratch, override.key[dot + 1 ..], override.value);
    }

    var incoming = try parseSettingsValueForLayer(alloc, .{ .object = root }, .profile, false, true);
    defer incoming.deinit(alloc);
    try mergeSettings(settings, &incoming, alloc);
    // Like git's GIT_* variables over -c, an SPARK_* override still wins.
}

/// Reads and parses one settings file for inspection, such as `spark doctor`'s
/// unknown-key check, with the same size limit as loading. Null when the file
/// is absent. Caller deinits the result, which owns all of its strings.
pub fn readSettingsFileJson(alloc: Allocator, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const bytes = try readOptionalFile(alloc, path) orelse return null;
    defer alloc.free(bytes);
    return try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
}

fn parseSettingsJson(alloc: Allocator, json_text: []const u8) !Settings {
    return parseSettingsJsonForLayer(alloc, json_text, .profile);
}

fn parseSettingsJsonForLayer(alloc: Allocator, json_text: []const u8, layer: SettingsLayer) !Settings {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    return parseSettingsValueForLayer(alloc, parsed.value, layer, false, true);
}

const JsonStringToken = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: JsonStringToken, alloc: Allocator) void {
        if (self.owned) |value| alloc.free(value);
    }
};

const SettingsLayer = enum {
    profile,
    profile_workspace,
    project,
};

fn parseStartupStatusSettingsJson(
    alloc: Allocator,
    json_text: []const u8,
    target_workspace: ?[]const u8,
    layer: SettingsLayer,
) !StartupStatusSettings {
    var scanner = std.json.Scanner.initCompleteInput(alloc, json_text);
    defer scanner.deinit();

    var settings = try parseStartupStatusObject(&scanner, alloc, target_workspace, layer);
    errdefer settings.deinit(alloc);
    try expectConfigJsonToken(try scanner.next(), .end_of_document);
    return settings;
}

fn parseStartupStatusObject(
    scanner: *std.json.Scanner,
    alloc: Allocator,
    target_workspace: ?[]const u8,
    layer: SettingsLayer,
) anyerror!StartupStatusSettings {
    try expectConfigJsonToken(try scanner.next(), .object_begin);
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => return settings,
            .string, .allocated_string => {
                const key = try configJsonStringFromToken(token);
                defer key.deinit(alloc);

                if (target_workspace) |workspace| {
                    if (std.mem.eql(u8, key.text, "workspaces")) {
                        var workspace_settings = try parseStartupStatusWorkspaceOverrides(scanner, alloc, workspace);
                        defer workspace_settings.deinit(alloc);
                        mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
                    } else {
                        try scanner.skipValue();
                    }
                } else if (layer == .profile and std.mem.eql(u8, key.text, "model")) {
                    try readStartupStatusModel(scanner, alloc, &settings);
                } else if (layer == .profile and std.mem.eql(u8, key.text, "permission_mode")) {
                    settings.permission_mode = try readStartupStatusPermissionMode(scanner);
                } else if (std.mem.eql(u8, key.text, "max_agent_steps")) {
                    settings.max_agent_steps = try readStartupStatusUsize(scanner);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeConfigJsonToken(alloc, token);
                return error.InvalidSettingsShape;
            },
        }
    }
}

fn parseStartupStatusWorkspaceOverrides(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) anyerror!StartupStatusSettings {
    try expectConfigJsonToken(try scanner.next(), .object_begin);
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => return settings,
            .string, .allocated_string => {
                const key = try configJsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, target_workspace)) {
                    var workspace_settings = try parseStartupStatusObject(scanner, alloc, null, .profile);
                    defer workspace_settings.deinit(alloc);
                    mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeConfigJsonToken(alloc, token);
                return error.InvalidSettingsShape;
            },
        }
    }
}

fn readStartupStatusModel(scanner: *std.json.Scanner, alloc: Allocator, settings: *StartupStatusSettings) !void {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .string, .allocated_string => {
            const value = try configJsonStringFromToken(token);
            defer value.deinit(alloc);
            const trimmed = std.mem.trim(u8, value.text, " \t\r\n");
            if (trimmed.len == 0) return;
            const owned = try alloc.dupe(u8, trimmed);
            if (settings.model) |current| alloc.free(current);
            settings.model = owned;
        },
        else => {
            freeConfigJsonToken(alloc, token);
            return error.InvalidModelType;
        },
    }
}

fn readStartupStatusPermissionMode(scanner: *std.json.Scanner) !types.PermissionMode {
    const token = try scanner.next();
    switch (token) {
        .string => |value| return parsePermissionMode(value) orelse error.InvalidPermissionMode,
        else => return error.InvalidPermissionModeType,
    }
}

fn readStartupStatusUsize(scanner: *std.json.Scanner) !usize {
    const token = try scanner.next();
    switch (token) {
        .number => |raw| return std.fmt.parseUnsigned(usize, raw, 10) catch error.InvalidMaxAgentStepsValue,
        else => return error.InvalidMaxAgentStepsType,
    }
}

fn configJsonStringFromToken(token: std.json.Token) !JsonStringToken {
    return switch (token) {
        .string => |text| .{ .text = text },
        .allocated_string => |text| .{ .text = text, .owned = text },
        else => error.InvalidSettingsShape,
    };
}

fn freeConfigJsonToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |text| alloc.free(text),
        .allocated_number => |text| alloc.free(text),
        else => {},
    }
}

fn expectConfigJsonToken(token: std.json.Token, comptime expected: std.json.TokenType) !void {
    const actual: std.json.TokenType = switch (token) {
        .object_begin => .object_begin,
        .object_end => .object_end,
        .array_begin => .array_begin,
        .array_end => .array_end,
        .true => .true,
        .false => .false,
        .null => .null,
        .number, .partial_number, .allocated_number => .number,
        .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .allocated_string => .string,
        .end_of_document => .end_of_document,
    };
    if (actual != expected) return error.InvalidSettingsShape;
}

fn parseSettingsValueForLayer(
    alloc: Allocator,
    root: std.json.Value,
    layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !Settings {
    if (root != .object) return error.InvalidSettingsShape;

    var settings = Settings{};
    errdefer settings.deinit(alloc);

    if (layer == .profile) {
        if (root.object.get("providers")) |value| settings.providers = try configured_provider.Registry.parse(alloc, value);
    }
    if (layer != .project) try parseProfileOnlyFields(
        &settings,
        alloc,
        root,
        tolerate_non_object_user_containers,
        parse_workspace_statusline,
    );
    try parseProjectSafeFields(&settings, root);

    return settings;
}

fn parseProfileOnlyFields(
    settings: *Settings,
    alloc: Allocator,
    root: std.json.Value,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !void {
    if (root.object.contains("skill_match_fuzzy")) return error.RetiredSkillMatchFuzzy;
    if (root.object.get("auto_compact_percent")) |value| {
        if (value != .integer) return error.InvalidAutoCompactPercentType;
        if (value.integer < 0 or !compactor.isValidPercent(@intCast(value.integer))) return error.InvalidAutoCompactPercentValue;
        settings.auto_compact_percent = @intCast(value.integer);
    }

    if (root.object.get("provider")) |provider_value| {
        if (provider_value != .string) return error.InvalidProviderType;
        // A built-in provider that spark no longer has leaves none chosen.
        settings.provider = model_provider.parse(provider_value.string) orelse
            if (model_provider.isRemovedBuiltin(provider_value.string)) null else return error.InvalidProviderValue;
    }

    if (root.object.get("models")) |models_value| {
        if (models_value != .object) return error.InvalidModelType;
        var iterator = models_value.object.iterator();
        while (iterator.next()) |entry| {
            const provider = model_provider.parse(entry.key_ptr.*) orelse {
                if (model_provider.isRemovedBuiltin(entry.key_ptr.*)) continue;
                return error.InvalidProviderValue;
            };
            const model_value = entry.value_ptr.*;
            if (model_value != .string) return error.InvalidModelType;
            settings_store.validateModel(model_value.string) catch return error.InvalidModelValue;
            try settings.models.putCopy(alloc, provider, model_value.string);
        }
    }

    if (root.object.get("permission_mode")) |permission_mode_value| {
        const value = permission_mode_value;
        if (value != .string) return error.InvalidPermissionModeType;
        settings.permission_mode = parsePermissionMode(value.string) orelse return error.InvalidPermissionMode;
    }

    if (root.object.get("credential_source")) |credential_source_value| {
        if (credential_source_value != .string) return error.InvalidCredentialSourceType;
        settings.credential_source = types.parseCredentialSource(credential_source_value.string) orelse
            return error.InvalidCredentialSource;
    }

    if (root.object.get("yolo_acknowledged")) |acknowledged_value| {
        if (acknowledged_value != .bool) return error.InvalidYoloAcknowledgedType;
        settings.yolo_acknowledged = acknowledged_value.bool;
    }

    if (root.object.get("context_limits")) |context_limits_value| {
        settings.context_limits = try context_limits.parseJsonObject(context_limits_value);
    }

    if (root.object.get("tool_placement")) |tool_placement_value| {
        settings.tool_placement = try tool_placement.parseJsonObject(tool_placement_value);
    }

    if (root.object.get("first_call_tool_choice")) |first_call_tool_choice_value| {
        const value = first_call_tool_choice_value;
        if (value != .string) return error.InvalidFirstCallToolChoiceType;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (types.ToolChoice.parse(trimmed)) |choice| {
            settings.first_call_tool_choice = choice;
        } else if (trimmed.len > 0) {
            debug_trace.logf("core", "ignoring invalid first_call_tool_choice value={s}", .{trimmed});
        }
    }

    // `review_model` is read and ignored: spark has no permission reviewer.

    if (root.object.get("fast_mode")) |fast_mode_value| {
        const value = fast_mode_value;
        if (value != .bool) return error.InvalidFastModeType;
        settings.fast_mode = value.bool;
    }

    if (root.object.get("ultrafast_mode")) |ultrafast_mode_value| {
        const value = ultrafast_mode_value;
        if (value != .bool) return error.InvalidUltrafastModeType;
        settings.ultrafast_mode = value.bool;
    }

    if (root.object.get("fast_mode_model_bound")) |bound_value| {
        if (bound_value != .bool) return error.InvalidFastModeBindingType;
        settings.fast_mode_model_bound = bound_value.bool;
    }

    if (root.object.get("slash_menu_categories")) |slash_menu_categories_value| {
        const value = slash_menu_categories_value;
        if (value != .bool) return error.InvalidSlashMenuCategoriesType;
        settings.slash_menu_categories = value.bool;
    }

    if (root.object.get("collapse_tool_calls")) |collapse_tool_calls_value| {
        const value = collapse_tool_calls_value;
        if (value != .bool) return error.InvalidCollapseToolCallsType;
        settings.collapse_tool_calls = value.bool;
    }

    if (root.object.get("session_titles")) |session_titles_value| {
        const value = session_titles_value;
        if (value != .bool) return error.InvalidSessionTitlesType;
        settings.session_titles = value.bool;
    }

    if (root.object.get("cache_warming")) |value| {
        if (value != .bool) return error.InvalidCacheWarmingType;
        settings.cache_warming = value.bool;
    }

    if (root.object.get("auto_upgrade")) |auto_upgrade_value| {
        const value = auto_upgrade_value;
        if (value != .bool) return error.InvalidAutoUpgradeType;
        settings.auto_upgrade = value.bool;
    }

    if (root.object.get("update_channel")) |update_channel_value| {
        const value = update_channel_value;
        if (value != .string) return error.InvalidUpdateChannelType;
        settings.update_channel = update_target.Channel.parse(value.string) orelse
            return error.InvalidUpdateChannelValue;
    }

    if (root.object.get("theme")) |theme_value| {
        const value = theme_value;
        if (value != .string) return error.InvalidThemeType;
        if (value.string.len > 0) settings.theme = try alloc.dupe(u8, value.string);
    }

    if (root.object.get("startup_scrollback")) |startup_scrollback_value| {
        const value = startup_scrollback_value;
        if (value != .bool) return error.InvalidStartupScrollbackType;
        settings.startup_scrollback = value.bool;
    }

    if (root.object.get("skill_symlink_authorities")) |value| {
        const paths = try parseSkillSymlinkAuthorities(alloc, value);
        if (settings.skill_symlink_authorities) |old| freeStringSlice(alloc, old);
        settings.skill_symlink_authorities = paths;
    }

    if (root.object.get("prompt_history")) |prompt_history_value| {
        if (prompt_history_value != .object) return error.InvalidPromptHistoryType;
        if (prompt_history_value.object.get("enabled")) |enabled| {
            if (enabled != .bool) return error.InvalidPromptHistoryEnabledType;
            settings.prompt_history_enabled = enabled.bool;
        }
    }

    if (root.object.get("effort")) |effort_value| {
        const value = effort_value;
        switch (value) {
            .string => |raw| settings.effort = types.ReasoningEffort.parse(raw) orelse return error.InvalidEffortValue,
            .null => settings.effort = .auto,
            else => return error.InvalidEffortType,
        }
    }

    // `status_line` and `sound` were `statusLine` and `notifications`. The
    // older name is read first, so the current one wins any value both set.
    // The current names were unknown keys before, which startup ignores, so a
    // value under one that isn't an object is still ignored.
    for ([_]?std.json.Value{ root.object.get("statusLine"), root.object.get("status_line") }, 0..) |group, index| {
        if (group) |value| {
            if (value != .object) {
                if (index == 1) {
                    debug_trace.logf("config", "ignoring status_line: not an object", .{});
                    continue;
                }
                if (!tolerate_non_object_user_containers) return error.InvalidStatusLineType;
            } else {
                if (value.object.get("context")) |v| {
                    if (v != .bool) return error.InvalidStatusLineContextType;
                    settings.statusline_context = v.bool;
                }
                if (value.object.get("session")) |v| {
                    if (v != .bool) return error.InvalidStatusLineSessionType;
                    settings.statusline_session = v.bool;
                }
                if (parse_workspace_statusline) {
                    if (value.object.get("workspace")) |v| {
                        if (v != .bool) return error.InvalidStatusLineWorkspaceType;
                        settings.statusline_workspace = v.bool;
                    }
                }
            }
        }
    }

    for ([_]?std.json.Value{ root.object.get("notifications"), root.object.get("sound") }, 0..) |group, index| {
        if (group) |sound_value| {
            if (sound_value != .object) {
                if (index == 0) return error.InvalidNotificationsType;
                debug_trace.logf("config", "ignoring sound: not an object", .{});
                continue;
            }
            if (sound_value.object.get("turn_end")) |value| {
                if (value != .bool) return error.InvalidNotificationTurnEndType;
                settings.notification_turn_end = value.bool;
            }
            if (sound_value.object.get("attention_required")) |value| {
                if (value != .bool) return error.InvalidNotificationAttentionRequiredType;
                settings.notification_attention_required = value.bool;
            }
            if (sound_value.object.get("max")) |value| {
                if (value != .bool) return error.InvalidNotificationMaxType;
                settings.notification_max = value.bool;
            }
        }
    }

    if (root.object.get("experimental")) |experimental_value| {
        if (experimental_value != .object) {
            debug_trace.logf("config", "ignoring experimental: not an object", .{});
        } else if (experimental_value.object.get("workspace_capture")) |value| {
            if (value != .bool) return error.InvalidExperimentalWorkspaceCaptureType;
            settings.experimental_workspace_capture = value.bool;
        }
    }

    // `permission` held allow, ask and deny rules. spark always has full
    // access, so the key is read and ignored.
}

/// Parses `skill_symlink_authorities` into caller-owned path copies. Every
/// entry must be an absolute path without `..` components so a typo cannot
/// silently widen or narrow the directories skills may resolve into.
fn parseSkillSymlinkAuthorities(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidSkillSymlinkAuthorities;
    const items = value.array.items;
    if (items.len > max_skill_symlink_authorities) return error.InvalidSkillSymlinkAuthorities;
    for (items) |item| {
        if (item != .string or
            !std.Io.Dir.path.isAbsolute(item.string) or
            pathHasDotDotComponent(item.string))
        {
            return error.InvalidSkillSymlinkAuthorities;
        }
    }
    const paths = try alloc.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |path| alloc.free(path);
        alloc.free(paths);
    }
    for (items) |item| {
        paths[filled] = try alloc.dupe(u8, item.string);
        filled += 1;
    }
    return paths;
}

fn pathHasDotDotComponent(path: []const u8) bool {
    var it = std.Io.Dir.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return true;
    }
    return false;
}

fn parseProjectSafeFields(settings: *Settings, root: std.json.Value) !void {
    if (root.object.get("max_agent_steps")) |max_agent_steps_value| {
        const value = max_agent_steps_value;
        if (value != .integer) return error.InvalidMaxAgentStepsType;
        if (value.integer < 0) return error.InvalidMaxAgentStepsValue;
        settings.max_agent_steps = std.math.cast(usize, value.integer) orelse return error.InvalidMaxAgentStepsValue;
    }

    if (root.object.get("max_tool_result_bytes")) |max_tool_result_bytes_value| {
        const value = max_tool_result_bytes_value;
        if (value != .integer) return error.InvalidMaxToolResultBytesType;
        if (value.integer < @as(i64, @intCast(tool_result_limits.min_configured_tool_result_bytes))) return error.InvalidMaxToolResultBytesValue;
        settings.max_tool_result_bytes = std.math.cast(usize, value.integer) orelse return error.InvalidMaxToolResultBytesValue;
    }

    if (root.object.get("context")) |context_value| {
        const value = context_value;
        if (value != .bool) return error.InvalidContextType;
        settings.context = value.bool;
    }
}

fn mergeSettings(target: *Settings, incoming: *Settings, alloc: Allocator) !void {
    try target.models.mergeOwnedFrom(alloc, &incoming.models);
    if (incoming.providers) |providers| {
        if (target.providers) |*old| old.deinit(alloc);
        target.providers = providers;
        incoming.providers = null;
    }
    if (incoming.provider) |value| target.provider = value;
    if (incoming.permission_mode) |value| target.permission_mode = value;
    if (incoming.credential_source) |value| target.credential_source = value;
    if (incoming.yolo_acknowledged) |value| target.yolo_acknowledged = value;
    if (incoming.max_agent_steps) |value| target.max_agent_steps = value;
    if (incoming.max_tool_result_bytes) |value| target.max_tool_result_bytes = value;
    if (incoming.auto_compact_percent) |value| target.auto_compact_percent = value;
    target.context_limits.merge(incoming.context_limits);
    target.tool_placement.merge(incoming.tool_placement);
    if (incoming.first_call_tool_choice) |value| target.first_call_tool_choice = value;
    if (incoming.context) |value| target.context = value;
    if (incoming.fast_mode) |value| target.fast_mode = value;
    if (incoming.ultrafast_mode) |value| target.ultrafast_mode = value;
    if (incoming.fast_mode_model_bound) |value| target.fast_mode_model_bound = value;
    if (incoming.slash_menu_categories) |value| target.slash_menu_categories = value;
    if (incoming.collapse_tool_calls) |value| target.collapse_tool_calls = value;
    if (incoming.session_titles) |value| target.session_titles = value;
    if (incoming.cache_warming) |value| target.cache_warming = value;
    if (incoming.auto_upgrade) |value| target.auto_upgrade = value;
    if (incoming.update_channel) |value| target.update_channel = value;
    if (incoming.theme) |value| {
        if (target.theme) |old| alloc.free(old);
        target.theme = value;
        incoming.theme = null;
    }
    if (incoming.startup_scrollback) |value| target.startup_scrollback = value;
    if (incoming.skill_symlink_authorities) |value| {
        if (target.skill_symlink_authorities) |old| freeStringSlice(alloc, old);
        target.skill_symlink_authorities = value;
        incoming.skill_symlink_authorities = null;
    }
    if (incoming.prompt_history_enabled) |value| target.prompt_history_enabled = value;
    if (incoming.effort) |value| target.effort = value;

    if (incoming.statusline_context) |value| target.statusline_context = value;
    if (incoming.statusline_session) |value| target.statusline_session = value;
    if (incoming.statusline_workspace) |value| target.statusline_workspace = value;
    if (incoming.notification_turn_end) |value| target.notification_turn_end = value;
    if (incoming.notification_attention_required) |value| target.notification_attention_required = value;
    if (incoming.notification_max) |value| target.notification_max = value;
    if (incoming.experimental_workspace_capture) |value| target.experimental_workspace_capture = value;
}

fn freeStringSlice(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn serializeJsonObject(alloc: Allocator, root: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJsonValue(&out.writer, root);
    return try out.toOwnedSlice();
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| try std.json.Stringify.value(s, .{}, writer),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

fn normalizeWorkspaceRoot(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and workspace_root[end - 1] == '/') {
        end -= 1;
    }
    return workspace_root[0..end];
}

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn writeRepeatedByteAbsolute(path: []const u8, byte: u8, count: usize) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());

    var chunk: [1024]u8 = undefined;
    @memset(&chunk, byte);

    var remaining = count;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try file.writeStreamingAll(io_mod.getIo(), chunk[0..n]);
        remaining -= n;
    }
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn expectIgnoredProjectKey(diagnostics: []const ConfigDiagnostic, key: []const u8) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.layer != .project or
            diagnostic.cause != .ignored_project_user_only_setting or
            diagnostic.setting_key == null)
        {
            continue;
        }
        if (std.mem.eql(u8, diagnostic.setting_key.?, key)) return;
    }
    return error.TestExpectedEqual;
}

fn readSettingsBytesForTest(alloc: Allocator, home: []const u8) ![]u8 {
    const path = try profile_paths.settingsPath(alloc, home);
    defer alloc.free(path);

    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_settings_bytes);
}

fn expectOneTrailingNewline(bytes: []const u8) !void {
    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
    if (bytes.len > 1) {
        try std.testing.expect(bytes[bytes.len - 2] != '\n');
    }
}

fn workspaceOverrideObject(root: *std.json.Value, workspace_root: []const u8) !*std.json.ObjectMap {
    if (root.* != .object) return error.InvalidSettingsShape;
    const workspaces = root.object.getPtr("workspaces") orelse return error.TestExpectedEqual;
    if (workspaces.* != .object) return error.TestExpectedEqual;
    const workspace = workspaces.object.getPtr(workspace_root) orelse return error.TestExpectedEqual;
    if (workspace.* != .object) return error.TestExpectedEqual;
    return &workspace.object;
}

test "discoverPathsFromHome returns home-backed and workspace paths" {
    var paths = try discoverPathsFromHome(std.testing.allocator, "/Users/tester", "/tmp/workspace");
    defer paths.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/Users/tester", paths.home_dir.?);
    try std.testing.expectEqualStrings("/Users/tester/.spark/settings.json", paths.user_settings.?);
    try std.testing.expectEqualStrings("/tmp/workspace/.spark.json", paths.workspace_settings);
    try std.testing.expectEqualStrings("/Users/tester/.spark", paths.home_spark_dir.?);
    try std.testing.expectEqualStrings("/Users/tester/.spark/sessions", paths.sessions_dir.?);
    try std.testing.expectEqualStrings("/tmp/workspace", paths.workspace_root);
}

const test_local = model_provider.parse("local").?;

/// Whether `parseSettingsValueForLayer` accepts `json` as a whole file.
fn settingsTextAcceptedForTest(layer: SettingsLayer, json: []const u8) !bool {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var settings = parseSettingsValueForLayer(alloc, parsed.value, layer, false, false) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    settings.deinit(alloc);
    return true;
}

fn expectSettingForTest(layer: SettingsLayer, name: []const u8, value_json: []const u8, accepted: bool) !void {
    const json = try std.testing.allocator.print("{{\"{s}\": {s}}}", .{ name, value_json });
    defer std.testing.allocator.free(json);
    errdefer std.debug.print("settings {s} in layer {t}\n", .{ json, layer });
    try std.testing.expectEqual(accepted, try settingsTextAcceptedForTest(layer, json));
}
