//! Best-effort lifecycle reporter for the herdr agent multiplexer.
//!
//! Each report uses a short-lived Unix socket. Failures and reply timeouts are
//! ignored so the integration cannot block or terminate an spark session.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");

pub const State = enum { idle, working, blocked };

// herdr protocol limits custom status to 32 bytes.
const custom_status_max = 32;
/// Maximum wait for herdr's one-line reply.
/// How long spark waits for herdr's reply to a request.
const response_wait_ms: i64 = 250;

// Third-party reporters use the `custom:` source prefix.
const source = "custom:spark";
const agent_name = "spark";

const Request = union(enum) {
    report: struct { state: State, custom_status: ?[]const u8 },
    session: []const u8,
    /// null clears the pane label.
    pane_rename: ?[]const u8,
    /// null clears the agent name.
    agent_rename: ?[]const u8,
    clear_authority,
};

/// The last state reported and its status, so a caller that reports on every
/// main-loop pass sends only changes.
pub const LastReport = struct {
    state: ?State = null,
    status_buf: [custom_status_max]u8 = undefined,
    status_len: ?usize = null,

    /// Records `state` and `status`, already clamped, and returns whether
    /// they differ from the last record.
    pub fn changed(self: *LastReport, state: State, status: ?[]const u8) bool {
        const last_status: ?[]const u8 = if (self.status_len) |len| self.status_buf[0..len] else null;
        const same_status = if (status) |value|
            last_status != null and std.mem.eql(u8, value, last_status.?)
        else
            last_status == null;
        if (self.state == state and same_status) return false;
        self.state = state;
        if (status) |value| {
            @memcpy(self.status_buf[0..value.len], value);
            self.status_len = value.len;
        } else self.status_len = null;
        return true;
    }
};

pub const Client = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    alloc: ?std.mem.Allocator = null,
    socket_path: []u8 = &.{},
    pane_id: []u8 = &.{},
    next_id: u64 = 1,
    /// Guarded by `mutex`.
    last_report: LastReport = .{},

    pub fn shouldEnable(
        spark_herdr: ?[]const u8,
        socket_path: ?[]const u8,
        pane_id: ?[]const u8,
    ) bool {
        if (spark_herdr) |val| {
            if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false"))
                return false;
        }
        const path = socket_path orelse return false;
        const pane = pane_id orelse return false;
        return path.len > 0 and pane.len > 0;
    }

    pub fn initFromEnv(self: *Client, alloc: std.mem.Allocator) void {
        const socket_path = io_mod.getenv("HERDR_SOCKET_PATH");
        const pane_id = io_mod.getenv("HERDR_PANE_ID");
        if (!shouldEnable(io_mod.getenv("SPARK_HERDR"), socket_path, pane_id)) {
            debug_trace.logf("herdr", "disabled socket={s} pane={s} spark_herdr={s}", .{
                socket_path orelse "(unset)",
                pane_id orelse "(unset)",
                io_mod.getenv("SPARK_HERDR") orelse "(unset)",
            });
            return;
        }

        const path_copy = alloc.dupe(u8, socket_path.?) catch return;
        const pane_copy = alloc.dupe(u8, pane_id.?) catch {
            alloc.free(path_copy);
            return;
        };
        self.alloc = alloc;
        self.socket_path = path_copy;
        self.pane_id = pane_copy;
        self.enabled = true;
        debug_trace.logf("herdr", "enabled socket={s} pane_id={s}", .{ path_copy, pane_copy });
    }

    pub fn deinit(self: *Client) void {
        // Clear herdr's pane before freeing paths so exit does not leave a
        // stale idle "spark" label behind.
        self.release();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.alloc) |alloc| {
            if (self.socket_path.len > 0) alloc.free(self.socket_path);
            if (self.pane_id.len > 0) alloc.free(self.pane_id);
        }
        self.socket_path = &.{};
        self.pane_id = &.{};
        self.alloc = null;
        self.enabled = false;
    }

    /// Report a semantic lifecycle state. `custom_status` is a short (<=32 byte)
    /// activity label shown in herdr's UI; pass null to omit it.
    pub fn reportState(self: *Client, state: State, custom_status: ?[]const u8) void {
        self.sendReport(state, clampStatus(custom_status), false);
    }

    /// Like `reportState`, but sends nothing when `state` and `custom_status`
    /// match the last report. A report that fails to send still counts, so
    /// a caller on every main-loop pass does not retry an absent herdr.
    pub fn reportStateIfChanged(self: *Client, state: State, custom_status: ?[]const u8) void {
        self.sendReport(state, clampStatus(custom_status), true);
    }

    fn sendReport(self: *Client, state: State, status: ?[]const u8, only_changes: bool) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.last_report.changed(state, status) and only_changes) return;
        const request: Request = .{ .report = .{ .state = state, .custom_status = status } };
        self.sendLocked(request) catch |err| {
            debug_trace.logf("herdr", "send failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
        };
    }

    /// Report spark's session id so herdr can associate the pane with a resumable
    /// session. Does not affect herdr's semantic state.
    pub fn reportSession(self: *Client, session_id: []const u8) void {
        if (session_id.len == 0) return;
        self.send(.{ .session = session_id });
    }

    /// Name the pane/agent so herdr lists spark even while idle. Best-effort;
    /// called once at startup after the first state report.
    pub fn announce(self: *Client) void {
        self.sendAll(&.{
            .{ .pane_rename = agent_name },
            .{ .agent_rename = agent_name },
        });
    }

    /// Remove spark from the pane on exit: drop the reported agent and clear the
    /// label/name. Without this the pane keeps showing "spark" after spark is gone.
    pub fn release(self: *Client) void {
        self.sendAll(&.{
            .{ .agent_rename = null },
            .clear_authority,
            .{ .pane_rename = null },
        });
    }

    fn send(self: *Client, request: Request) void {
        self.sendAll(&.{request});
    }

    fn sendAll(self: *Client, requests: []const Request) void {
        if (comptime host_target.is_wasm) return;
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (requests) |request| {
            self.sendLocked(request) catch |err| {
                debug_trace.logf(
                    "herdr",
                    "send failed kind={s} err={s}",
                    .{ @tagName(request), @errorName(err) },
                );
            };
        }
    }

    fn sendLocked(self: *Client, request: Request) !void {
        const io = io_mod.getIo();
        var stream = try self.connectLocked();
        defer stream.close(io);

        var buffer: [1024]u8 = undefined;
        var stream_writer = stream.writer(io, &buffer);
        const w = &stream_writer.interface;
        const id = self.takeIdLocked();
        switch (request) {
            .report => |r| try writeReportAgent(w, id, self.pane_id, r.state, r.custom_status),
            .session => |session_id| try writeReportAgentSession(w, id, self.pane_id, session_id),
            .pane_rename => |label| try writeRename(w, id, "pane.rename", "pane_id", self.pane_id, "label", label),
            .agent_rename => |name| try writeRename(w, id, "agent.rename", "target", self.pane_id, "name", name),
            .clear_authority => try writeClearAuthority(w, id, self.pane_id),
        }
        try w.flush();
        drainResponse(stream.socket.handle);
        debug_trace.logf("herdr", "sent {s} pane_id={s}", .{ @tagName(request), self.pane_id });
    }

    fn connectLocked(self: *Client) !std.Io.net.Stream {
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        return address.connect(io_mod.getIo());
    }

    fn takeIdLocked(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

fn clampStatus(custom_status: ?[]const u8) ?[]const u8 {
    const status = custom_status orelse return null;
    if (status.len == 0) return null;
    return status[0..@min(status.len, custom_status_max)];
}

/// Wait briefly for herdr's single-line response before closing. herdr applies
/// each request as it reads it; waiting serializes rapid-fire reports so a
/// later one cannot race ahead of an earlier one. The wait polls the socket
/// against a deadline and reads only what has arrived, so a herdr that never
/// answers costs `response_wait_ms` and nothing more. A receive timeout on the
/// socket would make `std.Io`'s reader panic on the EAGAIN it returns.
fn drainResponse(socket: std.posix.socket_t) void {
    const deadline = io_mod.milliTimestamp() + response_wait_ms;
    var buffer: [512]u8 = undefined;
    while (true) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return;
        var fds = [_]std.posix.pollfd{.{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(remaining)) catch return;
        if (ready == 0) return;
        const count = std.posix.read(socket, &buffer) catch return;
        if (count == 0) return;
        if (std.mem.findScalar(u8, buffer[0..count], '\n') != null) return;
    }
}

/// herdr's JSON-RPC requires the request id to be a string, not a number.
fn writeId(w: *std.Io.Writer, id: u64) !void {
    try w.writeAll("{\"id\":\"");
    try w.print("{d}", .{id});
    try w.writeAll("\"");
}

fn writeReportAgent(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    state: State,
    custom_status: ?[]const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"state\":");
    try jsonrpc.writeJsonStr(@tagName(state), w);
    if (custom_status) |status| {
        try w.writeAll(",\"custom_status\":");
        try jsonrpc.writeJsonStr(status, w);
    }
    try w.writeAll("}}\n");
}

fn writeReportAgentSession(
    w: *std.Io.Writer,
    id: u64,
    pane_id: []const u8,
    session_id: []const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"agent_session_id\":");
    try jsonrpc.writeJsonStr(session_id, w);
    try w.writeAll("}}\n");
}

fn writeRename(
    w: *std.Io.Writer,
    id: u64,
    method: []const u8,
    target_key: []const u8,
    target: []const u8,
    value_key: []const u8,
    value: ?[]const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":");
    try jsonrpc.writeJsonStr(method, w);
    try w.writeAll(",\"params\":{");
    try jsonrpc.writeJsonStr(target_key, w);
    try w.writeAll(":");
    try jsonrpc.writeJsonStr(target, w);
    try w.writeAll(",");
    try jsonrpc.writeJsonStr(value_key, w);
    try w.writeAll(":");
    if (value) |v| try jsonrpc.writeJsonStr(v, w) else try w.writeAll("null");
    try w.writeAll("}}\n");
}

fn writeClearAuthority(w: *std.Io.Writer, id: u64, pane_id: []const u8) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.clear_agent_authority\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll("}}\n");
}

test "waiting for herdr's reply ends at its line, at a close, or at the deadline" {
    if (comptime host_target.is_wasm) return;
    var handles: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(handles[0]);
    const peer: std.Io.File = .{ .handle = handles[1], .flags = .{ .nonblocking = false } };

    // A reply that has arrived ends the wait at once.
    try peer.writeStreamingAll(io_mod.getIo(), "{\"id\":\"1\",\"result\":{}}\n");
    var started = io_mod.milliTimestamp();
    drainResponse(handles[0]);
    try std.testing.expect(io_mod.milliTimestamp() - started < response_wait_ms);

    // A herdr that never answers costs the deadline, and returns.
    started = io_mod.milliTimestamp();
    drainResponse(handles[0]);
    try std.testing.expect(io_mod.milliTimestamp() - started >= response_wait_ms - 10);

    // A herdr that hangs up ends it too.
    _ = std.c.close(handles[1]);
    started = io_mod.milliTimestamp();
    drainResponse(handles[0]);
    try std.testing.expect(io_mod.milliTimestamp() - started < response_wait_ms);
}
