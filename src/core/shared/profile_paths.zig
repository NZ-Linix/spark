const std = @import("std");

const Allocator = std.mem.Allocator;

pub const root_dir_name = ".spark";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
const hosts_dir_name = "hosts";
/// Side folders older v2 sessions kept (D27): v1's per-session layout, one
/// folder per session id. A session moves out on its first open (D47).
pub const session_files_dir_name = "session-files";
/// Hosted terminal state of v2 sessions, one folder per session id (D45).
pub const terminal_dir_name = "terminal";
pub const prompt_history_file_name = "history.jsonl";
pub const backups_dir_name = "backups";
pub const mcp_credentials_dir_name = "mcp-credentials";
pub const mcp_credentials_file_name = "credentials.json";

const settings_file_name = "settings.json";
const mcp_config_file_name = "mcp.json";
const managed_skills_dir_name = "skills";
const logs_dir_name = "logs";
const trace_log_file_name = "trace.log";
const recordings_dir_name = "recordings";

/// The folder `SPARK_HOME` names, set once at startup by `useFxHome` before any
/// other thread runs. Null means spark keeps its files in `~/.spark`.
var spark_home: ?[]const u8 = null;

pub const SparkHomeError = error{ SparkHomeNotAbsolute, SparkHomeIsRoot, SparkHomeIsHome };

/// Points every profile path at `value`, which must be an absolute path
/// other than `/` and other than `home`: spark keeps its folder private, which
/// would close the home folder to everyone else. Trailing slashes are
/// ignored, and an empty value leaves the default. `value` must outlive the
/// process, as an environment string does.
pub fn useFxHome(value: []const u8, home: ?[]const u8) SparkHomeError!void {
    const trimmed = std.mem.trimEnd(u8, value, "/");
    if (value.len == 0) return;
    if (!std.Io.Dir.path.isAbsolute(value)) return error.SparkHomeNotAbsolute;
    if (trimmed.len == 0) return error.SparkHomeIsRoot;
    if (home) |path| if (std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, path, "/"))) return error.SparkHomeIsHome;
    spark_home = trimmed;
}

/// The folder that holds `$SPARK_HOME`, or null when it isn't set. spark uses it
/// as the home folder when `HOME` is unset, since profile paths then come
/// from `SPARK_HOME` alone.
pub fn fxHomeParent() ?[]const u8 {
    const root = spark_home orelse return null;
    return std.Io.Dir.path.dirname(root) orelse "/";
}

/// Whether `SPARK_HOME` moved spark's folder for this process.
pub fn fxHomeActive() bool {
    return spark_home != null;
}

const display_default = "~/" ++ root_dir_name;
const display_moved = "$SPARK_HOME";

/// How messages name spark's folder: `~/.spark`, or `$SPARK_HOME` when it is set.
pub fn displayRoot() []const u8 {
    return if (spark_home != null) display_moved else display_default;
}

/// `text` as written, with each `~/.spark` read as `$SPARK_HOME` when it is set.
/// Both versions are built at compile time.
pub fn displayText(comptime text: []const u8) []const u8 {
    const moved = comptime movedText(text);
    return if (spark_home != null) moved else text;
}

fn movedText(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var out: []const u8 = "";
        var rest: []const u8 = text;
        while (std.mem.find(u8, rest, display_default)) |at| {
            out = out ++ rest[0..at] ++ display_moved;
            rest = rest[at + display_default.len ..];
        }
        return out ++ rest;
    }
}

/// Writes runtime `text` the way `displayText` reads it.
pub fn writeDisplayText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (spark_home == null) return writer.writeAll(text);
    var rest = text;
    while (std.mem.find(u8, rest, display_default)) |at| {
        try writer.writeAll(rest[0..at]);
        try writer.writeAll(display_moved);
        rest = rest[at + display_default.len ..];
    }
    try writer.writeAll(rest);
}

/// The folder that holds spark's folder: `home`, or the parent of `$SPARK_HOME`.
/// Code that opens spark's folder without following symlinks opens this, then
/// `rootName()` inside it.
pub fn rootParent(home: []const u8) []const u8 {
    const root = spark_home orelse return home;
    return std.Io.Dir.path.dirname(root) orelse "/";
}

/// The name of spark's folder inside `rootParent`: `.spark`, or the last part of
/// `$SPARK_HOME`.
pub fn rootName() []const u8 {
    const root = spark_home orelse return root_dir_name;
    return std.Io.Dir.path.basename(root);
}

/// Joins `parts` under spark's folder. The caller owns the result.
pub fn rootPath(alloc: Allocator, home: []const u8, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(alloc);
    try all.appendSlice(alloc, &.{ rootParent(home), rootName() });
    try all.appendSlice(alloc, parts);
    return std.Io.Dir.path.join(alloc, all.items);
}

pub fn rootDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{});
}

/// spark's folder as `spark status` shows it, or null when neither `SPARK_HOME` nor
/// `home` names one. The caller owns the result.
pub fn activeRoot(alloc: Allocator, home: ?[]const u8) !?[]u8 {
    if (spark_home == null and home == null) return null;
    return try rootDir(alloc, home orelse "");
}

pub fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{settings_file_name});
}

pub fn mcpConfigPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{mcp_config_file_name});
}

pub fn mcpCredentialsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{mcp_credentials_dir_name});
}

pub fn mcpCredentialsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ mcp_credentials_dir_name, mcp_credentials_file_name });
}

pub fn managedSkillsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{managed_skills_dir_name});
}

/// `managedSkillsDir` inside `root_parent`, the folder that holds spark's
/// folder, such as the real path of `rootParent`. The caller owns the result.
pub fn managedSkillsDirIn(alloc: Allocator, root_parent: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ root_parent, rootName(), managed_skills_dir_name });
}

/// Agent profiles, one folder each. A repository keeps its own under
/// `<workspace>/.spark/agents`.
pub const agents_dir_name = "agents";

pub fn agentsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, agents_dir_name });
}

pub fn authPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{auth_file_name});
}

pub fn chatgptAuthPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{chatgpt_auth_file_name});
}

pub fn apiKeyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{api_key_file_name});
}

pub fn sessionsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{sessions_dir_name});
}

/// The host records, which list the sessions that ran together in one spark
/// process.
pub fn hostsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, root_dir_name, hosts_dir_name });
}

pub fn promptHistoryPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{prompt_history_file_name});
}

pub fn backupsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{backups_dir_name});
}

pub fn logsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{logs_dir_name});
}

pub fn traceLogPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ logs_dir_name, trace_log_file_name });
}

pub const diagnostics_dir_name = "diagnostics";
pub const last_shutdown_report_file_name = "last-shutdown.json";

pub fn lastShutdownReportPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ diagnostics_dir_name, last_shutdown_report_file_name });
}

pub fn recordingsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{recordings_dir_name});
}

test "profile path helpers preserve current default locations" {
    const alloc = std.testing.allocator;

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark", root);

    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/settings.json", settings);

    const mcp = try mcpConfigPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/mcp.json", mcp);

    const mcp_credentials_dir = try mcpCredentialsDir(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials_dir);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.spark/mcp-credentials",
        mcp_credentials_dir,
    );

    const mcp_credentials = try mcpCredentialsPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.spark/mcp-credentials/credentials.json",
        mcp_credentials,
    );

    const skills = try managedSkillsDir(alloc, "/tmp/fake-home");
    defer alloc.free(skills);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/skills", skills);

    const auth = try authPath(alloc, "/tmp/fake-home");
    defer alloc.free(auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/auth.json", auth);

    const chatgpt_auth = try chatgptAuthPath(alloc, "/tmp/fake-home");
    defer alloc.free(chatgpt_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/chatgpt-auth.json", chatgpt_auth);

    const api_key = try apiKeyPath(alloc, "/tmp/fake-home");
    defer alloc.free(api_key);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/api-key", api_key);

    const sessions = try sessionsDir(alloc, "/tmp/fake-home");
    defer alloc.free(sessions);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/sessions", sessions);

    const history = try promptHistoryPath(alloc, "/tmp/fake-home");
    defer alloc.free(history);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/history.jsonl", history);

    const backups = try backupsDir(alloc, "/tmp/fake-home");
    defer alloc.free(backups);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/backups", backups);

    const logs = try logsDir(alloc, "/tmp/fake-home");
    defer alloc.free(logs);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/logs", logs);

    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/logs/trace.log", trace);

    const recordings = try recordingsDir(alloc, "/tmp/fake-home");
    defer alloc.free(recordings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.spark/recordings", recordings);
}

test "SPARK_HOME moves every profile path and how messages name it" {
    const alloc = std.testing.allocator;
    defer spark_home = null;

    try std.testing.expectEqualStrings("~/.spark", displayRoot());
    try std.testing.expectEqualStrings("/tmp/fake-home", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings(".spark", rootName());
    try std.testing.expectEqualStrings("back up ~/.spark/sessions", displayText("back up ~/.spark/sessions"));
    try useFxHome("", null);
    try std.testing.expect(!fxHomeActive());
    try std.testing.expectError(error.SparkHomeNotAbsolute, useFxHome("profiles/work", null));
    try std.testing.expectError(error.SparkHomeIsRoot, useFxHome("///", null));
    try std.testing.expectError(error.SparkHomeIsHome, useFxHome("/Users/me/", "/Users/me"));
    try std.testing.expect(!fxHomeActive());

    try useFxHome("/tmp/spark-profile/", "/Users/me");
    try std.testing.expectEqualStrings("/tmp", fxHomeParent().?);
    try std.testing.expect(fxHomeActive());
    try std.testing.expectEqualStrings("$SPARK_HOME", displayRoot());
    try std.testing.expectEqualStrings(
        "back up $SPARK_HOME/sessions, or $SPARK_HOME/backups",
        displayText("back up ~/.spark/sessions, or ~/.spark/backups"),
    );
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeDisplayText(&writer, "edit ~/.spark/settings.json");
    try std.testing.expectEqualStrings("edit $SPARK_HOME/settings.json", writer.buffered());
    try std.testing.expectEqualStrings("/tmp", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings("spark-profile", rootName());

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/spark-profile", root);
    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/spark-profile/settings.json", settings);
    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/spark-profile/logs/trace.log", trace);

    try useFxHome("/spark", null);
    try std.testing.expectEqualStrings("/", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings("spark", rootName());
}
