// Host contract:
// - fields: stdout_file, shadow_vt, shadow_vt_alloc, layout,
//   viewport_top_row, installed pre-spark document state
// This module owns the normal frame sink. Exact probes, lifecycle controls,
// titles, crash recovery, and noninteractive output stay with their domain
// owners.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const record_tape = @import("../../core/workspace/record_tape.zig");
const types = @import("../../core/shared/types.zig");
const terminal_diff = @import("../render_engine/terminal_diff.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub fn enableShadowVt(shell: anytype, alloc: Allocator) !void {
    if (shell.shadow_vt != null) return;
    const cols: u16 = if (shell.layout.cols > 0) shell.layout.cols else 80;
    const rows: u16 = if (shell.layout.rows > 0) shell.layout.rows else 24;
    const grid = try alloc.create(vt_emulator.Grid);
    errdefer alloc.destroy(grid);
    grid.* = try vt_emulator.Grid.init(alloc, cols, rows);
    // The render oracle needs committed cells, not deferred sync state.
    grid.defer_sync_updates = false;
    grid.autowrap = false;
    shell.shadow_vt = grid;
    shell.shadow_vt_alloc = alloc;
}

pub fn disableShadowVt(shell: anytype) void {
    if (shell.shadow_vt) |grid| {
        grid.deinit();
        if (shell.shadow_vt_alloc) |alloc| alloc.destroy(grid);
        shell.shadow_vt = null;
        shell.shadow_vt_alloc = null;
    }
}

/// Writes `bytes` to the terminal. A write that fails because the terminal
/// hung up reports `error.TerminalHungUp` (`terminalHungUp`), so the frame
/// commit can close spark as a hang-up; every other failure reports its own
/// error.
pub fn writeFrameBytes(shell: anytype, metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
    var accepted_bytes: usize = 0;
    while (accepted_bytes < bytes.len) {
        const written = shell.stdout_file.writeStreaming(
            io_mod.getIo(),
            &.{},
            &.{bytes[accepted_bytes..]},
            1,
        ) catch |err| return recordPartialFrame(
            metrics,
            bytes[0..accepted_bytes],
            if (terminalHungUp(shell.stdout_file, err)) error.TerminalHungUp else err,
        );
        if (written == 0) return recordPartialFrame(metrics, bytes[0..accepted_bytes], error.NoProgress);
        accepted_bytes += written;
    }
    return recordCompleteFrame(metrics, bytes);
}

/// Whether a write to `file` failed with `err` because the terminal hung up,
/// as when its window closed: the write failed with EIO, and the descriptor
/// polls as hung up. Linux and macOS both report a pty whose other end closed
/// with POLLHUP. Once the hang-up ends the terminal's session, macOS revokes
/// the terminal, and the descriptor then polls POLLNVAL instead.
fn terminalHungUp(file: std.Io.File, err: anyerror) bool {
    if (comptime builtin.target.os.tag == .wasi) return false;
    if (err != error.InputOutput) return false;
    var fds = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    _ = std.posix.poll(&fds, 0) catch return false;
    return (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0;
}

fn recordPartialFrame(metrics: *Metrics, accepted: []const u8, err: anyerror) terminal_diff.FrameSinkWriteResult {
    record_tape.recordStdout(accepted);
    metrics.ansi_bytes += accepted.len;
    return .{ .partial = .{
        .accepted_bytes = accepted.len,
        .err = err,
    } };
}

fn recordCompleteFrame(metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
    record_tape.recordStdout(bytes);
    metrics.ansi_bytes += bytes.len;
    return .complete;
}

pub fn frameSinkFrom(ctx: *anyopaque, write_frame: *const fn (*anyopaque, *Metrics, []const u8) terminal_diff.FrameSinkWriteResult) terminal_diff.FrameSink {
    return .{ .ctx = ctx, .write_frame = write_frame };
}

test "writeFrameBytes writes the frame without feeding shadow" {
    const FakeShell = struct {
        stdout_file: std.Io.File,
        shadow_vt: ?*vt_emulator.Grid = null,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "frame-bytes.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer shadow.deinit();

    var shell = FakeShell{
        .stdout_file = file,
        .shadow_vt = &shadow,
    };
    var metrics: Metrics = .{};

    try std.testing.expect(writeFrameBytes(&shell, &metrics, "abc") == .complete);
    try std.testing.expectEqual(@as(u21, ' '), shadow.cellAt(1, 1).?.codepoint);
    try std.testing.expectEqual(@as(usize, 3), metrics.ansi_bytes);
}
