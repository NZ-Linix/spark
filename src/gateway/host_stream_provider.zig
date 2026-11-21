const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes = 1024 * 1024;
const cooperative_pulse_interval_ms = 50;

pub const Transport = struct {
    context: ?*anyopaque,
    open_fn: *const fn (?*anyopaque, []const u8, []const u8, []const u8, []const u8) anyerror!i32,
    status_fn: *const fn (?*anyopaque, i32, *u16) i32,
    next_fn: *const fn (?*anyopaque, i32, []u8) i32,
    close_fn: *const fn (?*anyopaque, i32) void,
    // Optional logical-completion signal, independent of HTTP EOF or close.
    consumed_fn: ?*const fn (?*anyopaque, i32) void = null,
    // Optional: an opened response's Retry-After in whole seconds, or -1 when
    // it has none. Read once its status is ready; a host without it leaves
    // waits on spark's own backoff.
    retry_after_fn: ?*const fn (?*anyopaque, i32) i32 = null,

    fn open(self: Transport, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
        return self.open_fn(self.context, method, url, headers, body);
    }

    fn status(self: Transport, handle: i32, status_out: *u16) i32 {
        return self.status_fn(self.context, handle, status_out);
    }

    fn next(self: Transport, handle: i32, out: []u8) i32 {
        return self.next_fn(self.context, handle, out);
    }

    pub fn close(self: Transport, handle: i32) void {
        self.close_fn(self.context, handle);
    }

    fn consumed(self: Transport, handle: i32) void {
        if (self.consumed_fn) |notify| notify(self.context, handle);
    }
};

/// The HTTP status a host reported, or null when `code` is outside 100 to 599.
/// A host can report any `u16`, and `std.http.Status` cannot hold most of them.
pub fn httpStatus(code: u16) ?std.http.Status {
    if (code < 100 or code > 599) return null;
    return @fromBackingInt(@intCast(code));
}

pub const OpenedPost = struct {
    handle: i32,
    status: std.http.Status,
    retry_after_seconds: ?u64 = null,
};

/// Admits the request, sends one POST through the host and waits for its HTTP
/// status. On success the caller owns `handle` and must close it with
/// `transport.close`; on error the handle is already closed. Headers reach the
/// host as a JSON list of `{name, value}` objects.
pub fn openPost(
    alloc: Allocator,
    transport: Transport,
    request: stream_provider.ModelRequest,
    endpoint: []const u8,
    headers: []const std.http.Header,
    payload: []const u8,
) !OpenedPost {
    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    try std.json.Stringify.value(headers, .{}, &headers_json.writer);

    try request.admission.admit();
    request.delivery.markPossiblySent();
    const handle = try transport.open("POST", endpoint, headers_json.writer.buffered(), payload);
    if (handle < 0) return error.HostStreamFailed;
    errdefer transport.close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (deadlineExpired(request.deadline)) return error.Timeout;
        const status_result = transport.status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return error.Cancelled;
        if (status_result < 0) return error.HostStreamFailed;
        try pulse(request.cooperative_pulse);
    }
    const http_status = httpStatus(status_code) orelse return error.HostStreamFailed;
    const retry_after: ?u64 = if (transport.retry_after_fn) |read| blk: {
        const seconds = read(transport.context, handle);
        break :blk if (seconds < 0) null else @intCast(seconds);
    } else null;
    return .{ .handle = handle, .status = http_status, .retry_after_seconds = retry_after };
}

/// Reads a non-success response body, bounded. The caller owns the bytes.
pub fn readErrorBody(
    alloc: Allocator,
    transport: Transport,
    handle: i32,
    request: stream_provider.ModelRequest,
) ![]u8 {
    return readBody(alloc, transport, handle, max_error_body_bytes, request.cancel_flag, request.deadline, request.cooperative_pulse);
}

pub const ReadFailure = error{ Timeout, Cancelled, HostStreamFailed };

/// Names why a `HostStreamReader` stopped with `error.ReadFailed`.
pub fn readFailure(reader: *const HostStreamReader, cancel_flag: *std.atomic.Value(bool)) ReadFailure {
    if (reader.timed_out) return error.Timeout;
    if (cancel_flag.load(.seq_cst) or reader.aborted) return error.Cancelled;
    return error.HostStreamFailed;
}

/// Tells the host a response was consumed in full, once the completion is valid
/// and uncancelled, so it may release the response before the stream closes.
pub fn signalConsumed(
    transport: Transport,
    handle: i32,
    request: stream_provider.ModelRequest,
    completion: @import("../core/shared/types.zig").ModelCompletion,
) void {
    const types = @import("../core/shared/types.zig");
    if (transport.consumed_fn != null and
        !request.cancel_flag.load(.seq_cst) and
        types.classifyProviderCompletion(completion) == .completed and
        types.authoritativeToolAdmission(completion) == .admitted and
        completion.provider_failure_cause == null)
    {
        transport.consumed(handle);
    }
}

test "host statuses outside 100 to 599 are not HTTP statuses" {
    for ([_]u16{ 0, 99, 600, 1023, 1024, 65535 }) |code| {
        try std.testing.expectEqual(@as(?std.http.Status, null), httpStatus(code));
    }
    try std.testing.expectEqual(@as(?std.http.Status, .@"continue"), httpStatus(100));
    try std.testing.expectEqual(@as(?std.http.Status, .ok), httpStatus(200));
    try std.testing.expectEqual(@as(u16, 599), @backingInt(httpStatus(599).?));
}

fn pulse(value: ?stream_provider.CooperativePulse) !void {
    if (value) |callback| try callback.pulse();
}

pub fn deadlineExpired(deadline: ?std.Io.Clock.Timestamp) bool {
    const value = deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, value);
}

/// Reads a response body whole, failing once it exceeds `max_bytes`. The
/// caller owns the bytes.
fn readBody(
    alloc: Allocator,
    transport: Transport,
    handle: i32,
    max_bytes: usize,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    cooperative_pulse: ?stream_provider.CooperativePulse,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (deadlineExpired(deadline)) return error.Timeout;
        const count = transport.next(handle, &chunk);
        if (count == -3) {
            try pulse(cooperative_pulse);
            continue;
        }
        if (count == -2) return error.Cancelled;
        if (count < 0) return error.HostStreamFailed;
        if (count == 0) break;
        const len: usize = @intCast(count);
        if (len > max_bytes - out.items.len) return error.HostStreamFailed;
        try out.appendSlice(alloc, chunk[0..len]);
    }
    return out.toOwnedSlice(alloc);
}

/// Adapts one open host response into a `std.Io.Reader` that honors the
/// request's cancellation, deadline and cooperative pulses.
pub const HostStreamReader = struct {
    transport: Transport = undefined,
    handle: i32 = -1,
    cancel_flag: *std.atomic.Value(bool) = undefined,
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?stream_provider.CooperativePulse = null,
    last_cooperative_pulse: ?std.Io.Clock.Timestamp = null,
    aborted: bool = false,
    timed_out: bool = false,
    buffer: [16 * 1024]u8 = undefined,
    interface: std.Io.Reader = undefined,

    pub fn init(
        self: *@This(),
        transport: Transport,
        handle: i32,
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        cooperative_pulse: ?stream_provider.CooperativePulse,
    ) void {
        self.* = .{
            .transport = transport,
            .handle = handle,
            .cancel_flag = cancel_flag,
            .deadline = deadline,
            .cooperative_pulse = cooperative_pulse,
            .last_cooperative_pulse = if (cooperative_pulse != null)
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            else
                null,
        };
        self.interface = .{ .vtable = &.{ .stream = streamReader, .readVec = readVec }, .buffer = &self.buffer, .seek = 0, .end = 0 };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
        for (data) |dest| if (dest.len > 0) return self.readHost(dest);
        const dest = reader.buffer[reader.end..];
        if (dest.len == 0) return 0;
        const count = try self.readHost(dest);
        reader.end += count;
        return 0;
    }

    fn abortRead(self: *@This()) std.Io.Reader.Error {
        self.aborted = true;
        return error.ReadFailed;
    }

    fn abortDeadline(self: *@This()) std.Io.Reader.Error {
        self.timed_out = true;
        return error.ReadFailed;
    }

    fn pulseAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        self.last_cooperative_pulse = now;
        try pulse(self.cooperative_pulse);
    }

    fn pulseIfDueAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        const last_pulse = self.last_cooperative_pulse orelse return;
        const elapsed_ms = last_pulse.durationTo(now).raw.toMilliseconds();
        if (elapsed_ms < cooperative_pulse_interval_ms) return;
        try self.pulseAt(now);
    }

    fn readHost(self: *@This(), dest: []u8) std.Io.Reader.Error!usize {
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            if (deadlineExpired(self.deadline)) return self.abortDeadline();
            if (self.cooperative_pulse != null) {
                self.pulseIfDueAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
            }
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            const count = self.transport.next(self.handle, dest);
            if (count == -3) {
                if (self.cooperative_pulse != null) {
                    self.pulseAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
                }
                continue;
            }
            if (count == -2) return self.abortRead();
            if (count < 0) return error.ReadFailed;
            if (count == 0) return error.EndOfStream;
            return @intCast(count);
        }
    }

    fn streamReader(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = readVec(reader, &data) catch |err| return err;
        writer.advance(count);
        return count;
    }
};
