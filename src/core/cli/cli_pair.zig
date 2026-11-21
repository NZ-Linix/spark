//! `spark pair`: pairs an iPhone with this computer. The phone link lives in
//! `spark-bridge`, a separate program installed beside spark, so spark hands
//! the terminal over to it and returns its exit code.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const bridge_name = "spark-bridge";

pub const Outcome = union(enum) {
    exited: u8,
    /// spark-bridge is neither beside spark nor on PATH
    missing,
};

/// Runs `spark-bridge pair <args>` with spark's terminal. Prefers the copy in
/// spark's own folder, then PATH.
pub fn run(alloc: std.mem.Allocator, args: []const [:0]const u8) !Outcome {
    const io = io_mod.getIo();
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    const beside: ?[]u8 = if (exe_len > 0) blk: {
        const dir = std.Io.Dir.path.dirname(exe_buf[0..exe_len]) orelse break :blk null;
        break :blk try std.Io.Dir.path.join(alloc, &.{ dir, bridge_name });
    } else null;
    defer if (beside) |p| alloc.free(p);

    const program: []const u8 = if (beside) |p|
        (if (std.Io.Dir.cwd().access(io, p, .{})) |_| p else |_| bridge_name)
    else
        bridge_name;

    const argv = try alloc.alloc([]const u8, args.len + 2);
    defer alloc.free(argv);
    argv[0] = program;
    argv[1] = "pair";
    for (args, 0..) |a, i| argv[i + 2] = a;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    const term = try child.wait(io);
    return .{ .exited = switch (term) {
        .exited => |code| code,
        else => 1,
    } };
}
