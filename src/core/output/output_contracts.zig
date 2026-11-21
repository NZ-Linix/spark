const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const doctor_runtime = @import("../cli/doctor_runtime.zig");
const io_mod = @import("../shared/io.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_health = @import("../mcp/health.zig");
const mode_contract = @import("../modes/mode_contract.zig");
const permissions = @import("../permissions/permissions.zig");
const session_codec = @import("../session/session_codec.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_json = @import("../session/session_json.zig");
const compactor = @import("../compactor/compactor.zig");
const session_store = @import("../session/session_store.zig");
const session_list_text = @import("session_list_text.zig");
const local_time = @import("../shared/local_time.zig");
const text_utils = @import("../shared/text_utils.zig");
const display_width = @import("../shared/display_width.zig");
const types = @import("../shared/types.zig");
const update_notes = @import("../upgrade/update_notes.zig");
const update_target = @import("../upgrade/update_target.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");

const Allocator = std.mem.Allocator;

fn permissionModeLabel(mode: types.PermissionMode) []const u8 {
    return permissions.permissionModeLabel(mode);
}

pub const OutputFormat = enum {
    text,
    json,
};

/// Process exit status when the command line itself is wrong: an unknown
/// command, an unknown or invalid flag, or a missing or bad argument. Work
/// that fails after the command line is accepted exits 1.
pub const usage_exit_code: u8 = 2;

pub const CommandFailureSnapshot = struct {
    kind: []const u8,
    message: []const u8,
    code: []const u8,

    pub fn renderJson(self: CommandFailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(self.kind, .{}, &out.writer);
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(self.message, .{}, &out.writer);
        try out.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(self.code, .{}, &out.writer);
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

/// `08:14 PDT`.
fn writeClock(writer: *std.Io.Writer, reading: *const local_time.Reading) !void {
    try writer.print("{d:0>2}:{d:0>2} {s}", .{ reading.hour, reading.minute, reading.zoneName() });
}

/// `Oct 11, 2026`.
fn formatDate(buf: *[24]u8, reading: *const local_time.Reading) []const u8 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month = months[reading.month.numeric() - 1];
    return std.mem.print(buf, "{s} {d}, {d}", .{ month, reading.day, reading.year }) catch "Unknown";
}

pub fn workspaceErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidWorkspaceArgs => null,
        error.InvalidPath => "path is invalid",
        error.PathNotFound => "directory does not exist",
        error.NotDirectory => "path is not a directory",
        error.UnknownAdditionalDirectory => "directory is not configured as an additional workspace",
        error.PrimaryDirectory => "the primary workspace cannot be added or removed",
        error.TooManyDirectories => "additional directory limit reached",
        error.HomeNotSet => io_mod.no_home_dir_reason,
        error.SettingsStoreUnavailable => "settings are unavailable",
        error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => "settings path is unsafe",
        else => "workspace update failed",
    };
}

pub const ConfigUnknownSetting = struct {
    key: settings_keys.UnknownKey,
    /// Where the key is: `~/.spark/settings.json` or `.spark.json`.
    file: []const u8,
    suggestion: ?[]const u8 = null,
};

/// `spark config list` and `spark config get` in git's format: one `key=value`
/// per line, lowest precedence first, with the origin first and a tab when
/// asked.
pub const ConfigSnapshot = struct {
    entries: []const settings_entries.Entry,
    /// Keys spark doesn't know. The JSON form lists them; the text form leaves
    /// them to the warnings on stderr.
    unknown: []const ConfigUnknownSetting = &.{},
    workspace_root: []const u8,
    show_origin: bool = false,
    /// `spark config get` of one plain key prints the value alone.
    value_only: bool = false,

    pub fn render(self: ConfigSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    fn renderText(self: ConfigSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        for (self.entries) |entry| {
            if (self.show_origin) {
                switch (entry.origin) {
                    .project => try out.writer.writeAll("file:.spark.json"),
                    .global => try out.writer.writeAll(profile_paths.displayText("file:~/.spark/settings.json")),
                    .workspace => {
                        try out.writer.writeAll("workspace:");
                        try writeTerminalSafe(&out.writer, alloc, self.workspace_root);
                    },
                    .env => try out.writer.print("env:{s}", .{entry.variable.?}),
                    .default => try out.writer.writeAll("default"),
                }
                try out.writer.writeByte('\t');
            }
            if (!self.value_only) {
                try writeTerminalSafe(&out.writer, alloc, entry.key);
                try out.writer.writeByte('=');
            }
            try writeConfigValue(&out.writer, alloc, entry.value);
            try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    fn renderJson(self: ConfigSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"kind\":\"config\",\"entries\":[");
        for (self.entries, 0..) |entry, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"key\":");
            try std.json.Stringify.value(entry.key, .{}, &out.writer);
            try out.writer.writeAll(",\"value\":");
            try std.json.Stringify.value(entry.value, .{}, &out.writer);
            try out.writer.print(",\"origin\":\"{s}\"", .{@tagName(entry.origin)});
            if (entry.origin == .env) {
                try out.writer.writeAll(",\"variable\":");
                try std.json.Stringify.value(entry.variable.?, .{}, &out.writer);
            } else if (entry.origin != .default) {
                try out.writer.writeAll(",\"file\":");
                try std.json.Stringify.value(if (entry.origin == .project) ".spark.json" else profile_paths.displayText("~/.spark/settings.json"), .{}, &out.writer);
            }
            if (entry.origin == .workspace) {
                try out.writer.writeAll(",\"workspace\":");
                try std.json.Stringify.value(self.workspace_root, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("],\"unknown\":[");
        for (self.unknown, 0..) |unknown, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"key\":\"");
            if (unknown.key.parent) |parent| try std.json.Stringify.encodeJsonStringChars(parent, .{}, &out.writer);
            if (unknown.key.parent != null) try out.writer.writeByte('.');
            try std.json.Stringify.encodeJsonStringChars(unknown.key.name, .{}, &out.writer);
            try out.writer.writeAll("\",\"file\":");
            try std.json.Stringify.value(unknown.file, .{}, &out.writer);
            try out.writer.writeAll(",\"workspace\":");
            try std.json.Stringify.value(unknown.key.workspace, .{}, &out.writer);
            try out.writer.writeAll(",\"suggestion\":");
            try std.json.Stringify.value(unknown.suggestion, .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

/// What `spark config set` or `spark config unset` did to the profile settings, as
/// one line naming the key, the value, and the file, like other setters.
pub const ConfigChangeSnapshot = struct {
    unset: bool,
    key: []const u8,
    /// The saved value; null for `unset`.
    value: ?std.json.Value = null,
    changed: bool,

    pub fn render(self: ConfigChangeSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        switch (format) {
            .text => {
                try writeTerminalSafe(&out.writer, alloc, self.key);
                if (self.unset) {
                    try out.writer.writeAll(if (self.changed) profile_paths.displayText(" removed from ~/.spark/settings.json.\n") else profile_paths.displayText(" isn't set in ~/.spark/settings.json.\n"));
                } else {
                    try out.writer.writeAll(if (self.changed) " set to " else " is already ");
                    try writeConfigValue(&out.writer, alloc, self.value orelse .null);
                    try out.writer.writeAll(if (self.changed) profile_paths.displayText(" in ~/.spark/settings.json.\n") else ".\n");
                }
            },
            .json => {
                try out.writer.print("{{\"kind\":\"config\",\"action\":\"{s}\",\"key\":", .{if (self.unset) "unset" else "set"});
                try std.json.Stringify.value(self.key, .{}, &out.writer);
                try out.writer.writeAll(",\"value\":");
                try std.json.Stringify.value(self.value orelse .null, .{}, &out.writer);
                try out.writer.print(",\"changed\":{},\"file\":", .{self.changed});
                try std.json.Stringify.value(profile_paths.displayText("~/.spark/settings.json"), .{}, &out.writer);
                try out.writer.writeByte('}');
            },
        }
        return try out.toOwnedSlice();
    }
};

/// A settings value as `spark config` prints it: text and numbers as they are,
/// lists and objects as compact JSON.
fn writeConfigValue(writer: *std.Io.Writer, alloc: Allocator, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try writeTerminalSafe(writer, alloc, text),
        .number_string => |text| try writeTerminalSafe(writer, alloc, text),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try writer.print("{d}", .{number}),
        .null => try writer.writeAll("null"),
        .array, .object => {
            var json: std.Io.Writer.Allocating = .init(alloc);
            defer json.deinit();
            try std.json.Stringify.value(value, .{}, &json.writer);
            try writeTerminalSafe(writer, alloc, json.written());
        },
    }
}

pub const WorkspaceSnapshot = struct {
    primary_directory: []const u8,
    saved_suppressed: bool,
    additional_directories: []const workspace_access.Entry,
    mutation: ?workspace_commands.Mutation = null,

    pub fn fromAccess(primary_directory: []const u8, access: *const workspace_access.WorkspaceAccess) WorkspaceSnapshot {
        return .{
            .primary_directory = primary_directory,
            .saved_suppressed = access.saved_suppressed,
            .additional_directories = access.entries,
        };
    }

    pub fn render(self: WorkspaceSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("[workspace] primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("[workspace] saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.print("[workspace] {s}", .{mutation.action});
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("[workspace] warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("[workspace] additional directories: (none)\n");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("[workspace] additional directories:\n");
        for (self.additional_directories) |entry| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}\n", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.writeAll(mutation.action);
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("additional directories: (none)");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("additional directories:\n");
        for (self.additional_directories, 0..) |entry, index| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
            if (index + 1 < self.additional_directories.len) try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const action = if (self.mutation) |mutation| mutation.action else "list";
        const changed = if (self.mutation) |mutation| mutation.saved_changed or mutation.runtime_changed else false;
        try out.writer.writeAll("{\"kind\":\"workspace\",\"action\":");
        try std.json.Stringify.value(action, .{}, &out.writer);
        try out.writer.print(",\"changed\":{}", .{changed});
        try out.writer.writeAll(",\"primary_directory\":");
        try std.json.Stringify.value(self.primary_directory, .{}, &out.writer);
        try out.writer.print(",\"saved_suppressed\":{},\"limit\":{d}", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            if (mutation.path) |path| {
                try out.writer.writeAll(",\"path\":");
                try std.json.Stringify.value(path, .{}, &out.writer);
            }
            try out.writer.print(",\"saved_changed\":{},\"runtime_changed\":{},\"launch_flag_can_restore\":{}", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
        }
        try out.writer.writeAll(",\"additional_directories\":[");
        for (self.additional_directories, 0..) |entry, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"path\":");
            try std.json.Stringify.value(entry.path, .{}, &out.writer);
            try out.writer.print(",\"saved\":{},\"command_line\":{},\"available\":{},\"active\":{}}}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeTerminalSafe(writer: *std.Io.Writer, alloc: Allocator, raw: []const u8) !void {
    var encoded = try text_utils.encodeTerminalSafe(alloc, raw, std.math.maxInt(usize));
    defer encoded.deinit(alloc);
    try writer.writeAll(encoded.bytes);
}

/// A terminal-safe copy of `raw`, allocated with `alloc`.
fn safeText(alloc: Allocator, raw: []const u8) ![]const u8 {
    return (try text_utils.encodeTerminalSafe(alloc, raw, std.math.maxInt(usize))).bytes;
}

/// How many entries a panel list holds, or `none`.
fn countText(alloc: Allocator, count: usize) ![]const u8 {
    return if (count == 0) "none" else alloc.print("{d}", .{count});
}

pub const McpServerResult = struct {
    /// The server's name, as the runtime knows it.
    name: []const u8,
    connection: Connection,
    authentication: Authentication,

    pub const Connection = enum { not_checked, ready, failed, timed_out };
    pub const Authentication = enum { not_checked, ok, needs_login };
};

pub const McpLocalSnapshot = struct {
    servers: []const mcp_health.ConfiguredServerSnapshot = &.{},
    configuration_issues: []const mcp_health.ConfigurationIssue = &.{},
    inspection_error: ?[]const u8 = null,
    /// `checked` once doctor has asked each server for its tools.
    connection_check: enum { not_checked, checked } = .not_checked,
    /// What doctor found for each server it checked. A server with no entry
    /// reads `not_checked`, as every server does for `spark status`.
    results: []const McpServerResult = &.{},

    fn resultFor(self: McpLocalSnapshot, name: []const u8) McpServerResult {
        for (self.results) |result| if (std.mem.eql(u8, result.name, name)) return result;
        return .{ .name = name, .connection = .not_checked, .authentication = .not_checked };
    }

    fn writeText(self: McpLocalSnapshot, writer: *std.Io.Writer, alloc: Allocator, prefix: []const u8) !void {
        try writer.print("[{s}] mcp_connection_check={s}\n", .{ prefix, @tagName(self.connection_check) });
        try writer.print(
            "[{s}] mcp_servers={d} mcp_configuration_issues={d}\n",
            .{ prefix, self.servers.len, self.configuration_issues.len },
        );
        for (self.servers) |server| {
            const result = self.resultFor(server.configured_name);
            try writer.print("[{s}] mcp_server=", .{prefix});
            try writeTerminalSafe(writer, alloc, server.configured_name);
            try writer.print(
                " source={s} scope={s} admission={s} transport={s} connection={s} authentication={s}\n",
                .{
                    @tagName(server.source),
                    @tagName(server.scope),
                    if (server.workspace_admission) |admission| @tagName(admission) else "not_applicable",
                    @tagName(server.transport),
                    @tagName(result.connection),
                    @tagName(result.authentication),
                },
            );
        }
        for (self.configuration_issues) |issue| {
            try writer.print("[{s}] mcp_configuration_issue=", .{prefix});
            try writeTerminalSafe(writer, alloc, issue.message);
            try writer.writeByte('\n');
        }
        if (self.inspection_error) |error_name| {
            try writer.print("[{s}] mcp_inspection_error={s}\n", .{ prefix, error_name });
        }
    }

    fn writeJson(self: McpLocalSnapshot, writer: *std.Io.Writer) !void {
        try writer.print("{{\"connection_check\":\"{s}\",\"servers\":[", .{@tagName(self.connection_check)});
        for (self.servers, 0..) |server, index| {
            if (index > 0) try writer.writeByte(',');
            const result = self.resultFor(server.configured_name);
            try std.json.Stringify.value(.{
                .name = server.configured_name,
                .source = server.source,
                .scope = server.scope,
                .admission = server.workspace_admission,
                .required = server.required,
                .transport = server.transport,
                .connection = result.connection,
                .authentication = result.authentication,
            }, .{}, writer);
        }
        try writer.writeAll("],\"configuration_issues\":[");
        for (self.configuration_issues, 0..) |issue, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(issue.message, .{}, writer);
        }
        try writer.writeAll("],\"inspection_error\":");
        if (self.inspection_error) |error_name| {
            try std.json.Stringify.value(error_name, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
};

pub const StatusSnapshot = struct {
    model: []const u8,
    /// Where startup found `model`: SPARK_MODEL, settings, or default.
    model_origin: ?[]const u8 = null,
    /// The reasoning effort a new session starts with, when the caller resolved one.
    effort: ?types.ReasoningEffort = null,
    provider_endpoint: ?[]const u8 = null,
    /// The configured provider the session uses, or `.none` when none is set.
    provider: model_provider.ProviderId = .none,
    update_channel: []const u8 = "stable",
    build_channel: []const u8 = "stable",
    build_revision: []const u8 = "",
    mcp: ?McpLocalSnapshot = null,
    mcp_config_error: ?[]const u8 = null,
    mcp_config_warning: ?mcp_contract.ProfileConfigWarning = null,
    permission_mode: types.PermissionMode,
    /// The session modes ACP offers and the one a new session starts in,
    /// when the caller has a mode registry with modes.
    modes: ?SessionModes = null,
    workspace_root: []const u8,
    /// The interactive shell's session, which only the `/status` panel
    /// shows. `spark status` runs outside any session and leaves it null.
    session: ?ShellSession = null,
    /// Why the profile settings could not be read, for the `/status` panel.
    settings_error: ?[]const u8 = null,
    /// spark's folder: `$SPARK_HOME`, or `~/.spark` expanded. Shown when set.
    spark_home: ?[]const u8 = null,
    history_turns: usize,
    agent_step_limit: usize,
    /// Requested Ultrafast mode. The serving provider may still fall back.
    ultrafast_requested: bool = false,

    pub const SessionModes = struct {
        current: []const u8,
        all: []const mode_contract.ModeSpec,
    };

    pub const ShellSession = union(enum) {
        /// No session could be created, so the shell saves nothing.
        unavailable,
        open: struct {
            id: []const u8,
            /// `spark --resume <id>` opens it now: its log is on disk (D90).
            saved: bool,
        },
    };

    /// The provider line: the configured provider's name, or where to set one.
    fn providerText(self: *const StatusSnapshot) []const u8 {
        return switch (self.provider) {
            .none => "no provider (run /provider)",
            .configured => self.provider.label(),
        };
    }

    /// The `/status` panel's rows, in order, the session first. Everything
    /// is allocated with `alloc`, which should be an arena.
    pub fn panelRows(self: StatusSnapshot, alloc: Allocator) ![]PanelRow {
        var rows: std.ArrayList(PanelRow) = .empty;
        if (self.session) |session| try rows.append(alloc, .{ .label = "Session", .value = switch (session) {
            .unavailable => "none · this shell can't save sessions",
            .open => |open| try alloc.print("{s} · {s}", .{
                try safeText(alloc, open.id),
                if (open.saved) "saved" else "not saved yet",
            }),
        } });
        try rows.append(alloc, .{ .label = "Model", .value = try safeText(alloc, self.model) });
        try rows.append(alloc, .{ .label = "Provider", .value = try safeText(alloc, self.providerText()) });
        if (self.provider_endpoint) |endpoint| {
            try rows.append(alloc, .{ .label = "Endpoint", .value = try safeText(alloc, endpoint) });
        }
        if (self.settings_error) |error_name| {
            try rows.append(alloc, .{ .label = "Settings", .value = try alloc.print("couldn't be read: {s}", .{error_name}) });
        }
        try rows.append(alloc, .{ .label = "Permissions", .value = permissions.permissionModeDisplayLabel(self.permission_mode) });
        try rows.append(alloc, .{ .label = "Workspace", .value = try safeText(alloc, self.workspace_root) });
        try rows.append(alloc, .{ .label = "Turns", .value = try alloc.print("{d}", .{self.history_turns}) });
        try rows.append(alloc, .{
            .label = "Step limit",
            .value = if (self.agent_step_limit == 0) "unlimited" else try alloc.print("{d}", .{self.agent_step_limit}),
        });
        try rows.append(alloc, .{ .label = "Ultrafast", .value = if (self.ultrafast_requested) "requested" else "not requested" });
        try rows.append(alloc, .{ .label = "Updates", .value = try safeText(alloc, self.update_channel) });
        try rows.append(alloc, .{
            .label = "Build",
            .value = if (self.build_revision.len > 0)
                try alloc.print("{s} · {s}", .{ try safeText(alloc, self.build_channel), try safeText(alloc, self.build_revision) })
            else
                try safeText(alloc, self.build_channel),
        });
        return rows.toOwnedSlice(alloc);
    }

    pub fn render(self: StatusSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[status] model={s}\n", .{self.model});
        if (self.model_origin) |origin| try out.writer.print("[status] model_origin={s}\n", .{origin});
        if (self.effort) |*effort| try out.writer.print("[status] effort={s}\n", .{effort.label()});
        try out.writer.print("[status] provider: {s}\n", .{self.providerText()});
        if (self.provider_endpoint) |endpoint| try out.writer.print("[status] provider_endpoint={s}\n", .{endpoint});
        try out.writer.print("[status] update_channel={s}\n", .{self.update_channel});
        try out.writer.print("[status] build_channel={s}\n", .{self.build_channel});
        if (self.build_revision.len > 0) {
            try out.writer.print("[status] build_revision={s}\n", .{self.build_revision});
        }
        if (self.mcp_config_error) |error_name| {
            try out.writer.print("[status] mcp_config_error={s}\n", .{error_name});
        }
        if (self.mcp_config_warning) |warning| {
            try out.writer.print(
                "[status] mcp_config_warning={s}",
                .{@tagName(warning.cause)},
            );
            if (warning.key()) |key| {
                try out.writer.writeAll(" key=");
                try writeTerminalSafe(&out.writer, alloc, key);
            }
            try out.writer.print(
                " additional_matches={d}\n",
                .{warning.additional_matches},
            );
        }
        try out.writer.print("[status] permission_mode={s}\n", .{permissions.permissionModeDisplayLabel(self.permission_mode)});
        try out.writer.print("[status] workspace={s}\n", .{self.workspace_root});
        if (self.spark_home) |path| try out.writer.print("[status] spark_home={s}\n", .{path});
        try out.writer.print("[status] history_turns={d}\n", .{self.history_turns});
        try out.writer.print("[status] agent_step_limit={d}\n", .{self.agent_step_limit});
        try out.writer.print("[status] ultrafast_requested={}\n", .{self.ultrafast_requested});
        if (self.mcp) |mcp| try mcp.writeText(&out.writer, alloc, "status");
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: StatusSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"kind\":\"status\",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        if (self.model_origin) |origin| {
            try writer.writeAll(",\"model_origin\":");
            try std.json.Stringify.value(origin, .{}, writer);
        }
        if (self.effort) |*effort| {
            try writer.writeAll(",\"effort\":");
            try std.json.Stringify.value(effort.label(), .{}, writer);
        }
        try writer.writeAll(",\"provider\":");
        switch (self.provider) {
            .none => try writer.writeAll("null"),
            .configured => try std.json.Stringify.value(self.provider.label(), .{}, writer),
        }
        if (self.provider_endpoint) |endpoint| {
            try writer.writeAll(",\"provider_endpoint\":");
            try std.json.Stringify.value(endpoint, .{}, writer);
        }
        try writer.writeAll(",\"update_channel\":");
        try std.json.Stringify.value(self.update_channel, .{}, writer);
        try writer.writeAll(",\"build_channel\":");
        try std.json.Stringify.value(self.build_channel, .{}, writer);
        try writer.writeAll(",\"build_revision\":");
        try std.json.Stringify.value(self.build_revision, .{}, writer);
        if (self.mcp_config_error) |error_name| {
            try writer.writeAll(",\"mcp_config_error\":");
            try std.json.Stringify.value(error_name, .{}, writer);
        }
        if (self.mcp_config_warning) |warning| {
            try writer.writeAll(",\"mcp_config_warning\":{\"cause\":");
            try std.json.Stringify.value(@tagName(warning.cause), .{}, writer);
            try writer.writeAll(",\"key\":");
            if (warning.key()) |key| {
                try std.json.Stringify.value(key, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.print(
                ",\"additional_matches\":{d}}}",
                .{warning.additional_matches},
            );
        }
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        if (self.modes) |modes| {
            try writer.writeAll(",\"mode\":");
            try std.json.Stringify.value(modes.current, .{}, writer);
            try writer.writeAll(",\"modes\":[");
            for (modes.all, 0..) |mode, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(mode.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(mode.name, .{}, writer);
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(mode.description, .{}, writer);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        }
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        if (self.spark_home) |path| {
            try writer.writeAll(",\"spark_home\":");
            try std.json.Stringify.value(path, .{}, writer);
        }
        try writer.print(",\"history_turns\":{d}", .{self.history_turns});
        try writer.print(",\"agent_step_limit\":{d}", .{self.agent_step_limit});
        try writer.print(",\"ultrafast_requested\":{}", .{self.ultrafast_requested});
        if (self.mcp) |mcp| {
            try writer.writeAll(",\"mcp\":");
            try mcp.writeJson(writer);
        }
        try writer.writeByte('}');
    }
};

/// One line of a read-only footer panel, such as `/status` and
/// `/permissions` open. Both texts are terminal-safe.
pub const PanelRow = struct {
    /// Empty for an entry of a list.
    label: []const u8,
    value: []const u8,
    /// An entry of the list the labeled row above it counts, drawn as a
    /// bullet under its value.
    item: bool = false,
};

/// What spark offers for one listed model: the same efforts and speed lanes a session on that model
/// exposes. `efforts` excludes `auto`, which every model accepts.
pub const ModelDetail = struct {
    name: ?[]const u8 = null,
    efforts: model_capabilities.ReasoningEffortOptions = .{},
    fast: bool = false,
    ultrafast: bool = false,
};

pub const ModelListSnapshot = struct {
    ids: []const []const u8,
    /// One per id when the provider's catalog describes its models; empty otherwise.
    details: []const ModelDetail = &.{},
    /// The configured provider the ids came from, or `.none`.
    provider: model_provider.ProviderId = .none,
    limit: ?usize = null,

    pub fn render(self: ModelListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            if (self.provider == .none) return alloc.dupe(u8, "[models] " ++ no_provider_text ++ "\n");
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return alloc.print("[models] no models returned by {s}\n[models] {s}\n", .{ provider_name, explanation });
            }
            return alloc.print("[models] no models returned by {s}\n", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[models] {d} available\n", .{self.ids.len});

        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            if (self.provider == .configured) {
                try out.writer.print(" - {s} · {s}\n", .{ id, self.provider.label() });
            } else {
                try out.writer.print(" - {s}\n", .{id});
            }
        }
        if (self.ids.len > shown) {
            try out.writer.print(" ... and {d} more\n", .{self.ids.len - shown});
        }
        if (self.catalogExplanation()) |explanation| try out.writer.print("[models] {s}\n", .{explanation});

        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            if (self.provider == .none) return alloc.dupe(u8, no_provider_text);
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return alloc.print("no models returned by {s}\n{s}", .{ provider_name, explanation });
            }
            return alloc.print("no models returned by {s}", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{d} available", .{self.ids.len});
        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            if (self.provider == .configured) {
                try out.writer.print("\n - {s} · {s}", .{ id, self.provider.label() });
            } else {
                try out.writer.print("\n - {s}", .{id});
            }
        }
        if (self.ids.len > shown) try out.writer.print("\n ... and {d} more", .{self.ids.len - shown});
        if (self.catalogExplanation()) |explanation| try out.writer.print("\n{s}", .{explanation});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const shown = self.shownCount();
        try out.writer.print(
            "{{\"kind\":\"models\",\"count\":{d},\"shown_count\":{d},\"more_count\":{d},\"ids\":[",
            .{ self.ids.len, shown, self.ids.len - shown },
        );
        for (self.ids[0..shown], 0..) |id, i| {
            if (i > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(id, .{}, &out.writer);
        }
        const has_details = self.ids.len > 0 and self.details.len == self.ids.len;
        if (self.provider == .configured or has_details) {
            try out.writer.writeAll("],\"models\":[");
            for (self.ids[0..shown], 0..) |id, i| {
                if (i > 0) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"id\":");
                try std.json.Stringify.value(id, .{}, &out.writer);
                if (self.provider == .configured) {
                    try out.writer.writeAll(",\"source\":");
                    try std.json.Stringify.value(self.provider.label(), .{}, &out.writer);
                }
                if (has_details) try writeModelDetailJson(&out.writer, &self.details[i]);
                try out.writer.writeByte('}');
            }
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn writeModelDetailJson(w: *std.Io.Writer, detail: *const ModelDetail) !void {
        if (detail.name) |name| {
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(name, .{}, w);
        }
        try w.writeAll(",\"efforts\":[");
        for (detail.efforts.slice(), 0..) |effort, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(effort.label(), .{}, w);
        }
        try w.print("],\"fast\":{},\"ultrafast\":{}", .{ detail.fast, detail.ultrafast });
    }

    fn shownCount(self: ModelListSnapshot) usize {
        return if (self.limit) |value| @min(self.ids.len, value) else self.ids.len;
    }

    const no_provider_text = "no provider is set; run /provider";

    fn emptyCatalogProviderName(self: ModelListSnapshot) []const u8 {
        return switch (self.provider) {
            .none => "the provider",
            .configured => self.provider.label(),
        };
    }

    fn catalogExplanation(self: ModelListSnapshot) ?[]const u8 {
        if (self.provider == .configured) return "Models from settings and, with fetch_models, the server; explicit model IDs need no catalog.";
        return null;
    }
};

/// How `spark sessions` and `spark sessions --live` print their text: color and
/// width for a terminal, and the clock and home folder rows read from.
pub const ListStyle = session_list_text.Style;

pub const SessionListSnapshot = struct {
    sessions: []const session_store.SessionSummary,
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
    skipped_invalid: usize = 0,
    all_workspaces: bool = false,
    style: ListStyle = .{},

    pub fn render(self: SessionListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try session_list_text.writeSaved(&out.writer, alloc, .{
            .sessions = self.sessions,
            .has_more = self.has_more,
            .next_cursor = self.next_cursor,
            .skipped_invalid = self.skipped_invalid,
            .all_workspaces = self.all_workspaces,
        }, self.style);
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        if (self.sessions.len == 0 and self.skipped_invalid == 0) {
            return alloc.dupe(u8, "{\"kind\":\"sessions\",\"count\":0,\"sessions\":[]}");
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{{\"kind\":\"sessions\",\"count\":{d}", .{self.sessions.len});
        if (self.skipped_invalid > 0) {
            try out.writer.print(",\"skipped_invalid\":{d}", .{self.skipped_invalid});
        }
        if (self.has_more) {
            try out.writer.writeAll(",\"has_more\":true,\"next_cursor\":");
            try std.json.Stringify.value(self.next_cursor orelse "", .{}, &out.writer);
        }
        try out.writer.writeAll(",\"sessions\":[");
        for (self.sessions, 0..) |entry, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.id, .{}, &out.writer);
            try writeSessionDisplayJsonFields(&out.writer, entry);
            try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ entry.created_at_ms, entry.updated_at_ms, entry.history_len });
            try out.writer.writeAll(",\"conversation_language\":");
            try std.json.Stringify.value(entry.conversation_language.view(), .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

pub const SessionSummarySnapshot = struct {
    summary: session_store.SessionSummary,

    pub fn render(self: SessionSummarySnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        return alloc.print(
            "[session] {s}\ncreated_at_ms: {d}\nupdated_at_ms: {d}\nlanguage: {s}\nhistory_len: {d}\n",
            .{
                self.summary.id,
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.conversation_language.view(),
                self.summary.history_len,
            },
        );
    }

    pub fn renderJson(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"session_summary\",\"id\":");
        try std.json.Stringify.value(self.summary.id, .{}, &out.writer);
        try writeSessionDisplayJsonFields(&out.writer, self.summary);
        try out.writer.print(
            ",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d},\"conversation_language\":",
            .{
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.history_len,
            },
        );
        try std.json.Stringify.value(
            self.summary.conversation_language.view(),
            .{},
            &out.writer,
        );
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }
};

fn writeSessionDisplayJsonFields(writer: *std.Io.Writer, summary: session_store.SessionSummary) !void {
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(
        summary.title orelse session_display_metadata.fallback_title,
        .{},
        writer,
    );
    try writer.writeAll(",\"preview\":");
    if (summary.preview) |preview| {
        try std.json.Stringify.value(preview, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"workspace_root\":");
    if (summary.workspace_root) |workspace_root| {
        try std.json.Stringify.value(workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"origin_workspace_root\":");
    if (summary.origin_workspace_root) |origin_workspace_root| {
        try std.json.Stringify.value(origin_workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

pub const SessionDetailSnapshot = struct {
    state: session_codec.DurableSessionState,
    /// `--tail`: only the last this many turns, each under its own number.
    tail: ?usize = null,
    /// The `<id>/<agent>` a subagent was read by.
    address: ?[]const u8 = null,

    /// Index of the first turn shown: the last `tail` of them, or all.
    fn firstShown(self: SessionDetailSnapshot) usize {
        const count = self.tail orelse return 0;
        return self.state.history.len - @min(count, self.state.history.len);
    }

    pub fn render(self: SessionDetailSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.state;
        const first = self.firstShown();
        try out.writer.print("[session] {s}\n", .{state.id});
        if (self.address) |address| try out.writer.print("address: {s}\n", .{address});
        try out.writer.print("created_at_ms: {d}\n", .{state.created_at_ms});
        try out.writer.print("updated_at_ms: {d}\n", .{state.updated_at_ms});
        try out.writer.print("language: {f}\n", .{text_utils.terminalSafe(state.conversation_language.view())});
        try out.writer.print("history_len: {d}\n", .{state.history.len});
        if (self.tail != null) try out.writer.print("first_turn: {d}\n", .{first + 1});

        if (state.history.len == 0) {
            try out.writer.writeAll("\n(no history yet)\n");
            return try out.toOwnedSlice();
        }

        for (state.history[first..], first..) |turn, i| {
            try out.writer.print("\n[turn {d}]\n", .{i + 1});
            try writeSessionHistoryTurnText(&out.writer, alloc, turn);
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.state;
        const first = self.firstShown();
        try out.writer.writeAll("{\"kind\":\"session_detail\",\"id\":");
        try std.json.Stringify.value(state.id, .{}, &out.writer);
        if (self.address) |address| {
            try out.writer.writeAll(",\"address\":");
            try std.json.Stringify.value(address, .{}, &out.writer);
        }
        try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ state.created_at_ms, state.updated_at_ms, state.history.len });
        if (self.tail != null) try out.writer.print(",\"first_turn\":{d}", .{first + 1});
        try out.writer.writeAll(",\"conversation_language\":");
        try std.json.Stringify.value(state.conversation_language.view(), .{}, &out.writer);
        try out.writer.writeAll(",\"history\":[");

        for (state.history[first..], 0..) |turn, i| {
            if (i > 0) try out.writer.writeByte(',');
            try writeSessionHistoryTurnJson(&out.writer, turn);
        }

        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

test "--tail keeps the last turns under their own numbers for every length and count" {
    // Seeded, so a failure names its case and replays.
    var prng = std.Random.DefaultPrng.init(0x7a11);
    const random = prng.random();
    var summary_text = "summary".*;
    var history: [40]types.HistoryTurn = undefined;
    for (&history, 0..) |*turn, i| turn.* = .{ .compacted_summary = .{ .summary = &summary_text, .removed_turn_count = i, .compaction_count = i } };
    var model = "m".*;
    for (0..2000) |_| {
        const len = random.uintAtMost(usize, history.len);
        const tail: ?usize = if (random.boolean()) null else 1 + random.uintAtMost(usize, 1000 - 1);
        const state: session_codec.DurableSessionState = .{
            .id = @constCast("abc"),
            .origin_workspace_root = @constCast("/Users/example/w"),
            .workspace_root = @constCast("/Users/example/w"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.default(),
            .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
            .history = history[0..len],
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        };
        const snapshot: SessionDetailSnapshot = .{ .state = state, .tail = tail };
        const first = snapshot.firstShown();
        const shown = len - first;
        if (tail) |count| {
            try std.testing.expectEqual(@min(count, len), shown);
        } else {
            try std.testing.expectEqual(@as(usize, 0), first);
        }
        const text = try snapshot.renderText(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqual(shown, std.mem.count(u8, text, "\n[turn "));
        if (shown > 0) {
            var buf: [32]u8 = undefined;
            try std.testing.expect(std.mem.find(u8, text, try std.mem.print(&buf, "\n[turn {d}]\n", .{first + 1})) != null);
            try std.testing.expect(std.mem.find(u8, text, try std.mem.print(&buf, "\n[turn {d}]\n", .{len})) != null);
        }
        const json = try snapshot.renderJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(len)), parsed.value.object.get("history_len").?.integer);
        try std.testing.expectEqual(shown, parsed.value.object.get("history").?.array.items.len);
        try std.testing.expectEqual(tail != null, parsed.value.object.get("first_turn") != null);
    }
}

/// `spark sessions --live`: each session an spark process has open now, with its
/// subagents, nested under the subagent that started them.
pub const LiveSessionListSnapshot = struct {
    sessions: []const session_store.LiveSession,
    all_workspaces: bool = false,
    style: ListStyle = .{},

    pub fn render(self: LiveSessionListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: LiveSessionListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try session_list_text.writeLive(&out.writer, alloc, self.sessions, self.all_workspaces, self.style);
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: LiveSessionListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{{\"kind\":\"live_sessions\",\"count\":{d},\"sessions\":[", .{self.sessions.len});
        for (self.sessions, 0..) |entry, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.summary.id, .{}, &out.writer);
            try out.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(entry.summary.title orelse session_display_metadata.fallback_title, .{}, &out.writer);
            try out.writer.writeAll(",\"workspace_root\":");
            try std.json.Stringify.value(entry.summary.workspace_root, .{}, &out.writer);
            try out.writer.writeAll(",\"saved_model\":");
            try std.json.Stringify.value(entry.saved_model, .{}, &out.writer);
            try out.writer.print(",\"state\":\"{s}\",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"agents\":", .{ @tagName(entry.state), entry.summary.created_at_ms, entry.summary.updated_at_ms });
            try writeLiveAgentsJson(&out.writer, entry.agents);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeLiveAgentsJson(writer: *std.Io.Writer, agents: []const session_store.LiveAgent) !void {
    try writer.writeByte('[');
    for (agents, 0..) |agent, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(agent.name, .{}, writer);
        try writer.writeAll(",\"address\":");
        try std.json.Stringify.value(agent.address, .{}, writer);
        try writer.writeAll(",\"id\":");
        try std.json.Stringify.value(agent.id, .{}, writer);
        try writer.print(",\"state\":\"{s}\",\"agents\":", .{@tagName(agent.state)});
        try writeLiveAgentsJson(writer, agent.agents);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

pub const SessionRecoverySnapshot = struct {
    result: session_store.SessionRecoveryResult,

    pub fn render(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        const result = self.result;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("[session recovery] copied {s} to {s}\nhistory_turns: {d}\n", .{
            result.source_session_id,
            result.recovered_session_id,
            result.history_len,
        });
        if (result.status == .recovered_with_unverified_artifacts) {
            try out.writer.writeAll("warning: legacy command artifacts could not be authenticated\n");
        }
        if (result.permission_rules_dropped) {
            try out.writer.writeAll("warning: saved permission rules could not be read and were not copied\n");
        }
        try out.writer.print("resume: spark --resume {s}\n", .{result.recovered_session_id});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(
            "{\"kind\":\"session_recovery\",\"source_id\":",
        );
        try std.json.Stringify.value(
            self.result.source_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"recovered_id\":");
        try std.json.Stringify.value(
            self.result.recovered_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(
            @tagName(self.result.status),
            .{},
            &out.writer,
        );
        try out.writer.print(
            ",\"history_turns\":{d},\"permission_rules_dropped\":{}",
            .{ self.result.history_len, self.result.permission_rules_dropped },
        );
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

/// What `spark sessions convert` did (D61): counts, then one line per session
/// it skipped.
pub const SessionConvertSnapshot = struct {
    converted: usize,
    busy: usize,
    unreadable: usize,
    skipped: []const Skipped,
    /// Each file a converted session was converted without, which its
    /// earlier folder keeps.
    left_out: []const LeftOut = &.{},
    /// Each subagent an older spark saved that no conversion takes, kept as it
    /// is, with why no spark opens it.
    kept: []const Kept = &.{},

    pub const Kept = struct {
        id: []const u8,
        reason: []const u8,
    };

    pub const Skipped = struct {
        id: []const u8,
        /// `SessionBusy` or `InvalidSessionFormat`.
        code: []const u8,
        /// The file and the reason, for an unreadable session.
        reason: ?[]const u8,
    };

    pub const LeftOut = struct {
        /// The converted session.
        id: []const u8,
        /// The session that kept the file: `id`, or one of its subagents.
        member: []const u8,
        file: []const u8,
        /// `too_large`, a side file over `limit`, which is `bytes` long; or
        /// `not_regular`, `unreadable` or `too_deep`, hosted terminal state
        /// the copy can't take.
        cause: []const u8,
        /// Why, as a clause.
        reason: []const u8,
        bytes: u64,
        limit: u64,
    };

    pub fn render(self: SessionConvertSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    fn renderText(self: SessionConvertSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("converted {d}, busy {d}, unreadable {d}\n", .{ self.converted, self.busy, self.unreadable });
        for (self.skipped) |skipped| {
            if (skipped.reason) |reason| {
                try out.writer.print("{s}: unreadable: {s}\n", .{ skipped.id, reason });
            } else if (std.mem.eql(u8, skipped.code, "SessionBusy")) {
                try out.writer.print("{s}: busy, open in another spark\n", .{skipped.id});
            } else try out.writer.print("{s}: unreadable\n", .{skipped.id});
        }
        for (self.left_out) |left| {
            try out.writer.print("{s}: converted without {s}", .{ left.id, left.file });
            if (!std.mem.eql(u8, left.member, left.id)) try out.writer.print(" of its subagent {s}", .{left.member});
            try out.writer.print(" because {s}; ~/.spark/sessions/{s} keeps it\n", .{ left.reason, left.member });
        }
        for (self.kept) |kept| try out.writer.print("{s}: kept as it is: {s}\n", .{ kept.id, kept.reason });
        return out.toOwnedSlice();
    }

    fn renderJson(self: SessionConvertSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{{\"kind\":\"sessions_convert\",\"converted\":{d},\"busy\":{d},\"unreadable\":{d}", .{ self.converted, self.busy, self.unreadable });
        // A skip fails the command; its error names the first one.
        if (self.skipped.len > 0) {
            try out.writer.writeAll(",\"error\":");
            try std.json.Stringify.value(self.skipped[0].code, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"skipped\":[");
        for (self.skipped, 0..) |skipped, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(skipped.id, .{}, &out.writer);
            try out.writer.writeAll(",\"error\":");
            try std.json.Stringify.value(skipped.code, .{}, &out.writer);
            if (skipped.reason) |reason| {
                try out.writer.writeAll(",\"reason\":");
                try std.json.Stringify.value(reason, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("],\"left_out\":[");
        for (self.left_out, 0..) |left, index| {
            if (index > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(left, .{}, &out.writer);
        }
        try out.writer.writeAll("],\"kept\":");
        try std.json.Stringify.value(self.kept, .{}, &out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }
};

pub const DoctorSnapshot = struct {
    /// The spark version that ran the checks.
    version: []const u8 = "",
    workspace_root: []const u8,
    model: []const u8,
    /// The configured provider the model comes from, or `.none`.
    provider: model_provider.ProviderId = .none,
    permission_mode: types.PermissionMode,
    agent_step_limit: usize,
    checks: []const doctor_runtime.Check,
    mcp: ?McpLocalSnapshot = null,

    pub fn render(self: DoctorSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        return self.renderTextStyled(alloc, .{});
    }

    pub const TextStyle = struct {
        /// Colors the status marks, headings, and fixes; for a terminal
        /// that allows color.
        color: bool = false,
        /// The terminal's width. A long value, detail, or fix then wraps
        /// at a space and goes on under its own column, so the columns
        /// stay whole. Null, as for a pipe, writes each on one line.
        columns: ?usize = null,
    };

    /// The report a person reads: what doctor ran with, then each check
    /// under its group, then the totals.
    pub fn renderTextStyled(self: DoctorSnapshot, alloc: Allocator, style: TextStyle) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;
        const paint: DoctorPaint = .{ .color = style.color };

        try paint.begin(w, .bold);
        try w.writeAll("spark doctor");
        try paint.end(w);
        if (self.version.len > 0) {
            try w.writeAll("  ");
            try paint.begin(w, .dim);
            try w.writeAll("spark ");
            try writeTerminalSafe(w, alloc, self.version);
            try paint.end(w);
        }
        try w.writeAll("\n\n");

        try writeDoctorField(w, alloc, "Workspace", self.workspace_root, style.columns);
        // Each value is built whole first, so it wraps as one.
        var value: std.Io.Writer.Allocating = .init(alloc);
        defer value.deinit();
        const v = &value.writer;
        try v.writeAll(self.model);
        switch (self.provider) {
            .none => try v.writeAll(" \u{00b7} no provider (run /provider)"),
            .configured => try v.print(" via {s}", .{self.provider.label()}),
        }
        try writeDoctorField(w, alloc, "Model", value.written(), style.columns);
        try writeDoctorField(w, alloc, "Permissions", permissions.permissionModeDisplayLabel(self.permission_mode), style.columns);
        try writeDoctorFieldLabel(w, "Step limit");
        if (self.agent_step_limit == 0) try w.writeAll("none\n") else try w.print("{d}\n", .{self.agent_step_limit});
        if (self.mcp) |mcp| {
            value.clearRetainingCapacity();
            try v.print("{d} server{s}", .{ mcp.servers.len, if (mcp.servers.len == 1) "" else "s" });
            if (mcp.configuration_issues.len > 0) try v.print(" \u{00b7} {d} config issue{s}", .{ mcp.configuration_issues.len, if (mcp.configuration_issues.len == 1) "" else "s" });
            if (mcp.inspection_error) |error_name| try v.print(" \u{00b7} could not be read: {s}", .{error_name});
            try writeDoctorField(w, alloc, "MCP", value.written(), style.columns);
        }

        for (std.enums.values(DoctorGroup)) |group| {
            var shown = false;
            for (self.checks) |entry| {
                if (DoctorGroup.of(entry.name) != group) continue;
                // The header already names the workspace.
                if (std.mem.eql(u8, entry.name, "workspace") and entry.status == .ok) continue;
                if (!shown) {
                    try w.writeByte('\n');
                    try paint.begin(w, .bold);
                    try w.writeAll(group.title());
                    try paint.end(w);
                    try w.writeByte('\n');
                    shown = true;
                }
                try w.writeAll("  ");
                try paint.begin(w, switch (entry.status) {
                    .ok => .green,
                    .warn => .yellow,
                    .fail => .red,
                });
                try w.writeAll(doctorStatusMark(entry.status));
                try paint.end(w);
                try w.writeByte(' ');
                try paint.begin(w, .dim);
                try writeTerminalSafe(w, alloc, entry.name);
                try paint.end(w);
                try w.splatByteAll(' ', @max(1, doctor_name_width -| entry.name.len));
                try writeDoctorWrapped(w, alloc, entry.detail, doctor_detail_column, style.columns);
                try w.writeByte('\n');
                if (entry.fix) |fix| {
                    try w.splatByteAll(' ', doctor_detail_column);
                    try paint.begin(w, .dim);
                    try w.writeAll("fix:");
                    try paint.end(w);
                    try w.writeByte(' ');
                    try writeDoctorWrapped(w, alloc, fix, doctor_fix_column, style.columns);
                    try w.writeByte('\n');
                }
            }
        }

        const counts = countDoctorChecks(self.checks);
        try w.writeByte('\n');
        try w.print("{d} ok \u{00b7} ", .{counts.ok});
        if (counts.warn > 0) try paint.begin(w, .yellow);
        try w.print("{d} warning{s}", .{ counts.warn, if (counts.warn == 1) "" else "s" });
        if (counts.warn > 0) try paint.end(w);
        try w.writeAll(" \u{00b7} ");
        if (counts.fail > 0) try paint.begin(w, .red);
        try w.print("{d} failure{s}", .{ counts.fail, if (counts.fail == 1) "" else "s" });
        if (counts.fail > 0) try paint.end(w);
        try w.writeByte('\n');

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: DoctorSnapshot, writer: *std.Io.Writer) !void {
        const counts = countDoctorChecks(self.checks);
        try writer.print(
            "{{\"kind\":\"doctor\",\"ok_count\":{d},\"warn_count\":{d},\"fail_count\":{d}",
            .{ counts.ok, counts.warn, counts.fail },
        );
        if (self.version.len > 0) {
            try writer.writeAll(",\"version\":");
            try std.json.Stringify.value(self.version, .{}, writer);
        }
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        try writer.writeAll(",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        try writer.writeAll(",\"provider\":");
        switch (self.provider) {
            .none => try writer.writeAll("null"),
            .configured => try std.json.Stringify.value(self.provider.label(), .{}, writer),
        }
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        try writer.print(",\"agent_step_limit\":{d},\"checks\":[", .{self.agent_step_limit});

        for (self.checks, 0..) |entry, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(entry.name, .{}, writer);
            try writer.writeAll(",\"status\":");
            try std.json.Stringify.value(checkStatusLabel(entry.status), .{}, writer);
            try writer.writeAll(",\"detail\":");
            try std.json.Stringify.value(entry.detail, .{}, writer);
            if (entry.fix) |fix| {
                try writer.writeAll(",\"fix\":");
                try std.json.Stringify.value(fix, .{}, writer);
            }
            try writer.writeByte('}');
        }

        try writer.writeByte(']');
        if (self.mcp) |mcp| {
            try writer.writeAll(",\"mcp\":");
            try mcp.writeJson(writer);
        }
        try writer.writeByte('}');
    }
};

pub const UpgradeSnapshot = struct {
    current: []const u8,
    latest: []const u8,
    channel: []const u8 = "stable",
    current_channel: []const u8 = "stable",
    current_revision: []const u8 = "",
    latest_revision: []const u8 = "",
    status: Status,
    err_message: ?[]const u8 = null,

    pub const Status = enum {
        upgraded,
        up_to_date,
        failed,

        fn label(self: Status) []const u8 {
            return switch (self) {
                .upgraded => "upgraded",
                .up_to_date => "up_to_date",
                .failed => "failed",
            };
        }
    };

    pub fn render(self: UpgradeSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: UpgradeSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.err_message) |msg| {
            try out.writer.print("error: {s}\n", .{msg});
            return try out.toOwnedSlice();
        }

        switch (self.status) {
            .upgraded => {
                try out.writer.writeAll("upgraded to ");
                if (std.mem.eql(u8, self.channel, "dev") and self.latest_revision.len > 0) {
                    try out.writer.print("dev {s} (", .{shortRevision(self.latest_revision)});
                    try writeVersionWithPrefix(&out.writer, self.latest);
                    try out.writer.writeByte(')');
                } else {
                    try writeVersionWithPrefix(&out.writer, self.latest);
                }
                try out.writer.writeByte('\n');
                const channel = update_target.Channel.parse(self.channel) orelse .stable;
                if (update_notes.destination(
                    channel,
                    self.latest,
                    self.current_revision,
                    self.latest_revision,
                )) |notes| {
                    try update_notes.writeLabel(notes.kind, &out.writer);
                    try out.writer.writeAll(": ");
                    try notes.writeUrl(&out.writer);
                    try out.writer.writeByte('\n');
                }
            },
            .up_to_date => {
                if (std.mem.eql(u8, self.channel, "dev") and self.latest_revision.len > 0) {
                    try out.writer.print("spark dev {s} is already up to date (", .{shortRevision(self.latest_revision)});
                } else {
                    try out.writer.writeAll("spark is already up to date (");
                }
                try writeVersionWithPrefix(&out.writer, self.latest);
                try out.writer.writeAll(")\n");
            },
            .failed => try out.writer.writeAll("upgrade failed\n"),
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: UpgradeSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"upgrade\"");

        if (self.err_message) |msg| {
            try out.writer.writeAll(",\"error\":");
            try std.json.Stringify.value(msg, .{}, &out.writer);
            try out.writer.writeByte('}');
            return try out.toOwnedSlice();
        }

        try out.writer.writeAll(",\"current\":");
        try std.json.Stringify.value(self.current, .{}, &out.writer);
        try out.writer.writeAll(",\"latest\":");
        try std.json.Stringify.value(self.latest, .{}, &out.writer);
        if (!std.mem.eql(u8, self.channel, "stable") or
            !std.mem.eql(u8, self.current_channel, "stable") or
            self.latest_revision.len > 0)
        {
            try out.writer.writeAll(",\"channel\":");
            try std.json.Stringify.value(self.channel, .{}, &out.writer);
            try out.writer.writeAll(",\"current_channel\":");
            try std.json.Stringify.value(self.current_channel, .{}, &out.writer);
            try out.writer.writeAll(",\"current_revision\":");
            try std.json.Stringify.value(self.current_revision, .{}, &out.writer);
            try out.writer.writeAll(",\"latest_revision\":");
            try std.json.Stringify.value(self.latest_revision, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(self.status.label(), .{}, &out.writer);
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

fn writeVersionWithPrefix(writer: *std.Io.Writer, version: []const u8) !void {
    if (version.len == 0 or version[0] != 'v') {
        try writer.writeByte('v');
    }
    try writer.writeAll(version);
}

const DoctorCheckCounts = struct {
    ok: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
};

fn countDoctorChecks(checks: []const doctor_runtime.Check) DoctorCheckCounts {
    var counts: DoctorCheckCounts = .{};
    for (checks) |entry| {
        switch (entry.status) {
            .ok => counts.ok += 1,
            .warn => counts.warn += 1,
            .fail => counts.fail += 1,
        }
    }
    return counts;
}

/// The groups `spark doctor` shows its checks under, in this order.
const DoctorGroup = enum {
    install,
    config,
    auth,
    sessions,
    mcp,
    tools,
    other,

    fn of(check_name: []const u8) DoctorGroup {
        const names = [_]struct { []const u8, DoctorGroup }{
            .{ "workspace", .install },
            .{ "install", .install },
            .{ "config", .config },
            .{ "env", .config },
            .{ "startup", .config },
            .{ "mcp_config", .mcp },
            .{ "auth", .auth },
            .{ "login", .auth },
            .{ "provider", .auth },
            .{ "model", .auth },
            .{ "state", .sessions },
            .{ "session", .sessions },
            .{ "sessions", .sessions },
            .{ "mcp", .mcp },
            .{ "git", .tools },
            .{ "gh", .tools },
            .{ "skills", .tools },
        };
        for (names) |entry| if (std.mem.eql(u8, entry[0], check_name)) return entry[1];
        return .other;
    }

    fn title(group: DoctorGroup) []const u8 {
        return switch (group) {
            .install => "Install",
            .config => "Config",
            .auth => "Auth and model",
            .sessions => "Sessions",
            .mcp => "MCP servers",
            .tools => "Tools",
            .other => "Other",
        };
    }
};

fn doctorStatusMark(status: doctor_runtime.CheckStatus) []const u8 {
    return switch (status) {
        .ok => "\u{2713}",
        .warn => "!",
        .fail => "\u{2717}",
    };
}

const doctor_field_width = 13;
/// The check name column, wide enough for `mcp_config`.
const doctor_name_width = 11;
/// Where a check's detail starts: two spaces, the mark, a space, the name.
const doctor_detail_column = 4 + doctor_name_width;
/// Where a fix's text starts, after `fix: ` under the detail.
const doctor_fix_column = doctor_detail_column + "fix: ".len;
/// Below this many columns for the text, wrapping would leave too little on
/// each line, so the text is written whole and the terminal wraps it.
const doctor_min_wrap_width = 20;

/// Writes `raw` made terminal-safe, starting at column `indent`. With a
/// known `columns`, it breaks at the last space that fits before the edge
/// and starts each next line at `indent`; a word wider than a whole line
/// breaks at the edge, between whole characters, emoji sequences included.
fn writeDoctorWrapped(w: *std.Io.Writer, alloc: Allocator, raw: []const u8, indent: usize, columns: ?usize) !void {
    const width = columns orelse return writeTerminalSafe(w, alloc, raw);
    if (width < indent + doctor_min_wrap_width) return writeTerminalSafe(w, alloc, raw);
    var encoded = try text_utils.encodeTerminalSafe(alloc, raw, std.math.maxInt(usize));
    defer encoded.deinit(alloc);
    var rest = display_width.trimBreakWhitespace(encoded.bytes);
    var first = true;
    while (rest.len > 0) {
        var line = display_width.wrapCutIgnoringAnsi(rest, width - indent);
        // A single character wider than the line still takes one line.
        if (line.len == 0) line = rest[0..display_width.displayUnitAt(rest, 0).byte_len];
        if (!first) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', indent);
        }
        try w.writeAll(std.mem.trimEnd(u8, line, " \t"));
        rest = display_width.trimBreakWhitespace(rest[line.len..]);
        first = false;
    }
}

fn writeDoctorFieldLabel(w: *std.Io.Writer, label: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(label);
    try w.splatByteAll(' ', doctor_field_width -| label.len);
}

fn writeDoctorField(w: *std.Io.Writer, alloc: Allocator, label: []const u8, value: []const u8, columns: ?usize) !void {
    try writeDoctorFieldLabel(w, label);
    try writeDoctorWrapped(w, alloc, value, 2 + doctor_field_width, columns);
    try w.writeByte('\n');
}

/// SGR codes for the doctor report, written only when color is on.
const DoctorPaint = struct {
    color: bool,

    const Tone = enum { bold, dim, green, yellow, red };

    fn begin(paint: DoctorPaint, w: *std.Io.Writer, tone: Tone) !void {
        if (!paint.color) return;
        try w.writeAll(switch (tone) {
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .red => "\x1b[31m",
        });
    }

    fn end(paint: DoctorPaint, w: *std.Io.Writer) !void {
        if (paint.color) try w.writeAll("\x1b[0m");
    }
};

fn checkStatusLabel(status: doctor_runtime.CheckStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warn => "warn",
        .fail => "fail",
    };
}

fn writeSessionHistoryTurnText(writer: *std.Io.Writer, alloc: Allocator, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.print("[compacted] removed_turns={d} compactions={d}\n", .{ entry.removed_turn_count, entry.compaction_count });
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const rendered = compactor.modelText(arena_state.allocator(), entry.summary) catch null;
            try writeTextBlock(writer, alloc, rendered orelse entry.summary);
        },
        .assistant => |entry| {
            try writeSessionUserTurnText(writer, alloc, entry.user);
            try writeSessionExecutionText(writer, alloc, entry.execution);
            try writer.writeAll("[assistant]\n");
            try writeTextBlock(writer, alloc, entry.assistant);
        },
        .interrupted => |entry| {
            try writeSessionUserTurnText(writer, alloc, entry.user);
            try writeSessionExecutionText(writer, alloc, entry.execution);
            if (entry.assistant) |assistant| {
                try writer.writeAll("[assistant]\n");
                try writeTextBlock(writer, alloc, assistant);
            }
            try writer.writeAll("[interrupted]\n");
            if (entry.tool_call) |tool_call| {
                try writer.print("tool_call_id: {f}\n", .{text_utils.terminalSafe(tool_call.id)});
                try writer.print("tool_name: {f}\n", .{text_utils.terminalSafe(tool_call.name)});
            } else {
                try writer.writeAll("tool: (none)\n");
            }
            if (entry.completed_tool_names.len > 0) {
                try writer.writeAll("completed_tools: ");
                for (entry.completed_tool_names, 0..) |name, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{f}", .{text_utils.terminalSafe(name)});
                }
                try writer.writeByte('\n');
            }
        },
    }
}

fn writeSessionExecutionText(writer: *std.Io.Writer, alloc: Allocator, execution: types.ExecutionMemory) !void {
    if (execution.isEmpty()) return;

    try writer.writeAll("[execution]\n");
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            try writer.writeAll("assistant:\n");
            try writeTextBlock(writer, alloc, assistant);
        }
        for (step.tool_calls) |call| {
            try writer.print("tool_call: {f} {f}\n", .{ text_utils.terminalSafe(call.id), text_utils.terminalSafe(call.name) });
            try writer.writeAll("arguments:\n");
            try writeTextBlock(writer, alloc, call.arguments_json);
        }
        for (step.tool_results) |result| {
            try writer.print(
                "tool_result: {f} {f} {s}\n",
                .{ text_utils.terminalSafe(result.tool_call_id), text_utils.terminalSafe(result.tool_name), @tagName(result.status) },
            );
            try writer.writeAll("output:\n");
            try writeTextBlock(writer, alloc, result.output);
        }
    }
    for (execution.files) |file| {
        try writer.print(
            "file: {s} {s} {f}\n",
            .{ @tagName(file.action), @tagName(file.status), text_utils.terminalSafe(file.path) },
        );
    }
}

fn writeSessionUserTurnText(writer: *std.Io.Writer, alloc: Allocator, user: types.UserTurn) !void {
    try writer.writeAll("[user]\n");
    try writeTextBlock(writer, alloc, user.text);
    if (user.images.len > 0) {
        try writer.print("[images] {d}\n", .{user.images.len});
        for (user.images) |image| {
            try writer.print(" - {f} ({f})\n", .{ text_utils.terminalSafe(image.path), text_utils.terminalSafe(image.media_type) });
        }
    }
}

/// Saved text as a terminal can show it: lines and tabs stay, and every
/// other control byte becomes a visible escape, so a model's or a tool's
/// own sequences never reach the terminal.
fn writeTextBlock(writer: *std.Io.Writer, alloc: Allocator, text: []const u8) !void {
    if (text.len == 0) {
        try writer.writeAll("(empty)\n");
        return;
    }

    var safe: std.ArrayList(u8) = .empty;
    defer safe.deinit(alloc);
    try text_utils.appendTerminalSafeText(alloc, &safe, text);
    try writer.writeAll(safe.items);
    if (safe.items.len == 0 or safe.items[safe.items.len - 1] != '\n') try writer.writeByte('\n');
}

fn writeSessionHistoryTurnJson(writer: *std.Io.Writer, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try std.json.Stringify.value(entry.summary, .{}, writer);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{ entry.removed_turn_count, entry.compaction_count });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try std.json.Stringify.value(entry.assistant, .{}, writer);
            try writer.writeAll(",\"execution\":");
            try session_json.writeExecutionMemoryJson(writer, entry.execution);
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            if (entry.assistant) |assistant| {
                try std.json.Stringify.value(assistant, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"arguments_json\":");
                try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
                try writer.writeByte('}');
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":[");
            for (entry.completed_tool_names, 0..) |name, i| {
                if (i > 0) try writer.writeByte(',');
                try std.json.Stringify.value(name, .{}, writer);
            }
            try writer.writeByte(']');
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try session_json.writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeSessionUserTurnJson(writer: *std.Io.Writer, user: types.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(user.text, .{}, writer);
    try writer.writeAll(",\"images\":[");

    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(image.path, .{}, writer);
        try writer.writeAll(",\"media_type\":");
        try std.json.Stringify.value(image.media_type, .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
}

pub const SlackSnapshot = struct {
    action: []const u8,
    installed: bool,
    app_id: ?[]const u8,
    team_id: ?[]const u8,
    bot_user_id: ?[]const u8,
    expires_at_ms: ?i64,
    refresh_expires_at_ms: ?i64,

    pub fn render(self: SlackSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (format == .json) {
            try std.json.Stringify.value(self, .{}, &out.writer);
        } else if (!self.installed) {
            try out.writer.writeAll("No local Slack bot installation. Run spark slack install.\n");
        } else {
            try out.writer.writeAll(if (std.mem.eql(u8, self.action, "install"))
                "spark is now installed in your Slack workspace.\n"
            else
                "Your spark Slack bot credentials are saved on this computer.\n");
            if (self.expires_at_ms) |expiry| {
                if (local_time.local(expiry)) |reading| {
                    var date_buf: [24]u8 = undefined;
                    try out.writer.print("Access expires on {s} at ", .{formatDate(&date_buf, &reading)});
                    try writeClock(&out.writer, &reading);
                    try out.writer.writeAll(".\n");
                } else {
                    try out.writer.writeAll("Access expiration time is unavailable.\n");
                }
                try out.writer.writeAll("Run spark slack refresh to renew locally.\n");
            }
        }
        return out.toOwnedSlice();
    }
};
