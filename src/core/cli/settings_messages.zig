//! Messages about settings keys spark doesn't know, shared by `spark doctor` and
//! `spark config`.

const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const cli_flags = @import("cli_flags.zig");
const settings_keys = @import("../config/settings_keys.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// The known key closest to `name` within two edits, if any.
pub fn closest(name: []const u8, known: []const []const u8) ?[]const u8 {
    var nearest: cli_flags.Nearest = .{ .word = name };
    for (known) |candidate| nearest.offer(candidate);
    return nearest.best;
}

/// `unknown setting statusLine.contxt in ~/.spark/settings.json (did you mean
/// statusLine.context?)`, for a key found in a settings file. Caller owns the
/// result.
pub fn formatUnknownSetting(alloc: Allocator, key: settings_keys.UnknownKey, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("unknown setting ");
    try writeDotted(writer, key.parent, key.name);
    try writer.print(" in {s}", .{display_path});
    try writeWorkspace(writer, key.workspace);
    try writeSuggestion(writer, key.parent, closest(key.name, key.known));
    return out.toOwnedSlice();
}

/// `statusLine and status_line are both set in ~/.spark/settings.json; spark uses
/// status_line where they differ, so remove statusLine`. Caller owns the
/// result.
pub fn formatOlderName(alloc: Allocator, twice: settings_keys.OlderName, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    if (twice.both) {
        try writer.print("{s} and {s} are both set in {s}", .{ twice.older, twice.current, display_path });
        try writeWorkspace(writer, twice.workspace);
        try writer.print("; spark uses {s} where they differ, so remove {s}", .{ twice.current, twice.older });
    } else {
        try writer.print("{s} in {s}", .{ twice.older, display_path });
        try writeWorkspace(writer, twice.workspace);
        try writer.print(" " ++ command_specs.deprecated_until ++ "; rename it to {s}", .{twice.current});
    }
    return out.toOwnedSlice();
}

/// `permission_mode yolo in ~/.spark/settings.json is deprecated and stops
/// working in spark 26.12.20; use full-access`. Caller owns the result.
pub fn formatOldYolo(alloc: Allocator, workspace: ?[]const u8, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("permission_mode yolo in {s}", .{display_path});
    try writeWorkspace(&out.writer, workspace);
    try out.writer.writeAll(" " ++ command_specs.deprecated_until ++ "; use full-access");
    return out.toOwnedSlice();
}

/// `unknown setting fast_mdoe (did you mean fast_mode?)`, for a key typed on
/// the command line. Caller owns the result.
pub fn formatUnknownPath(alloc: Allocator, part: settings_keys.UnknownPart) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("unknown setting ");
    try writeDotted(&out.writer, part.parent, part.name);
    try writeSuggestion(&out.writer, part.parent, closest(part.name, part.known));
    return out.toOwnedSlice();
}

/// Keys and workspace paths come from the command line or a settings file, so
/// they are written terminal-safe.
fn writeDotted(writer: *std.Io.Writer, parent: ?[]const u8, name: []const u8) !void {
    if (parent) |value| try writer.print("{f}.", .{text_utils.terminalSafe(value)});
    try writer.print("{f}", .{text_utils.terminalSafe(name)});
}

fn writeWorkspace(writer: *std.Io.Writer, workspace: ?[]const u8) !void {
    if (workspace) |path| try writer.print(" for workspace {f}", .{text_utils.terminalSafe(path)});
}

fn writeSuggestion(writer: *std.Io.Writer, parent: ?[]const u8, suggestion: ?[]const u8) !void {
    const name = suggestion orelse return;
    try writer.writeAll(" (did you mean ");
    try writeDotted(writer, parent, name);
    try writer.writeAll("?)");
}
