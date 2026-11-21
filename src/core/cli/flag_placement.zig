//! Where a flag goes on the command line. As in git (`git -C dir log
//! --oneline`), launch-wide flags such as `--add-dir` come before the
//! command, and the flags that shape an agent run come after it.

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("cli_flags.zig");

/// After `unknown flag --add-dir`, explains that a launch-wide flag goes
/// before `command`: `; it goes before the command: spark --add-dir <path> ask`.
/// Writes nothing for any other flag.
pub fn writeLaunchFlagHint(writer: *std.Io.Writer, command: []const u8, failure: cli_flags.Failure) std.Io.Writer.Error!void {
    const unknown = switch (failure) {
        .unknown => |unknown| unknown,
        else => return,
    };
    const name = unknown.flag[0 .. std.mem.findScalar(u8, unknown.flag, '=') orelse unknown.flag.len];
    for (builtin_commands.launch_wide_options) |doc| {
        if (!std.mem.eql(u8, cli_flags.flagName(doc), name)) continue;
        try writer.print("; it goes before the command: spark {s} {s}", .{ doc.flag, command });
        return;
    }
}
