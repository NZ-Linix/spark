const std = @import("std");
const commands = @import("../../builtins/commands.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");
const cli_flags = @import("cli_flags.zig");

const Dir = std.Io.Dir;
const Flag = enum { yes };
const flag_ids = cli_flags.idTable(Flag, &commands.uninstall_options);

pub fn parse(args: []const [:0]const u8) !bool {
    var parser: cli_flags.Parser = .init(&commands.uninstall_options, args);
    var assume_yes = false;
    while (try parser.next()) |item| switch (item) {
        .positional => return error.UnexpectedPositional,
        .option => |match| switch (flag_ids[match.index].?) {
            .yes => assume_yes = true,
        },
    };
    return assume_yes;
}

const Outcome = enum { removed, declined, confirmation_required };

pub fn run(alloc: std.mem.Allocator, assume_yes: bool) !Outcome {
    const io = io_mod.getIo();
    if (profile_paths.fxHomeActive()) return error.CustomSparkHome;
    const home = io_mod.homeDir() orelse return error.UnsafeHome;
    const real_home = try io_mod.realpathAlloc(alloc, home);
    defer alloc.free(real_home);
    if (std.mem.eql(u8, real_home, "/")) return error.UnsafeHome;

    var executable_buffer: [Dir.max_path_bytes]u8 = undefined;
    const executable_len = try std.process.executablePath(io, &executable_buffer);
    const executable = executable_buffer[0..executable_len];
    if (!Dir.path.isAbsolute(executable) or !std.mem.eql(u8, Dir.path.basename(executable), "spark"))
        return error.UnsafeExecutable;

    if (!assume_yes) {
        const stdin = std.Io.File.stdin();
        const stderr = std.Io.File.stderr();
        if (!try stdin.isTty(io) or !try stderr.isTty(io)) return .confirmation_required;
        var output_buffer: [256]u8 = undefined;
        var output = stderr.writer(io, &output_buffer);
        try output.interface.print(
            "Permanently delete {f} and {f}/" ++ profile_paths.root_dir_name ++ " (including saved sessions and credentials)? [y/N] ",
            .{ text_utils.terminalSafe(executable), text_utils.terminalSafe(real_home) },
        );
        try output.interface.flush();
        var input_buffer: [64]u8 = undefined;
        var input = stdin.reader(io, &input_buffer);
        const line = input.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return .declined,
            else => return err,
        } orelse return .declined;
        const answer = std.mem.trim(u8, line, " \t\r");
        if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) return .declined;
    }

    var home_dir = try Dir.openDirAbsolute(io, real_home, .{});
    defer home_dir.close(io);
    if (native_keychain.isAvailable() and !native_keychain.isDisabled()) {
        try native_keychain.deleteSparkCredentials(alloc);
    }
    try home_dir.deleteTree(io, profile_paths.root_dir_name);
    try Dir.deleteFileAbsolute(io, executable);
    return .removed;
}
