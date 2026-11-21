// In-memory records of recent tool invocations. Used by /trace so the report
// shows which tools the model invoked, with bounded args/results for normal
// tools, without forcing a persistent trace log. web_fetch is compact-only
// because its prompt and fetched content are sensitive.
//
// The rings keep text as it was recorded, cut so that no part of a secret is
// kept (`text_utils.secretSafePrefixLen` and `secretSafeSuffixStart`), and
// `/trace` masks it when it writes the trace, so recording a call runs no
// mask.
//
// Two rings hold them. The window keeps the last calls of every outcome, so a
// busy agent or a few subagents move a failure out of it within minutes. The
// failure ring keeps only calls that did not succeed, with larger head and
// tail cuts of their arguments and results, so a failure stays in the report
// however many calls succeed after it.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_result_display = @import("../tooling/tool_result_display.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const max_name_len: usize = 64;
pub const max_args_len: usize = 1200;
pub const max_result_len: usize = 2000;
pub const ring_capacity: usize = 64;
/// Longest provider call ID kept; longer IDs keep their first bytes.
pub const max_call_id_len: usize = 128;
pub const failure_ring_capacity: usize = 32;
/// Bytes kept of a failed call's arguments, and separately of its result,
/// split between the first and the last bytes.
pub const max_failure_field_len: usize = 8 * 1024;
pub const max_dir_len: usize = 1024;

pub const ToolCallOutcome = enum(u8) {
    succeeded,
    rejected,
    command_failed,
    tool_failed,
    runtime_failed,
};

pub const ToolCallMetric = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: ToolCallOutcome = .succeeded,
    subagent_id: u64 = 0,
    name_buf: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    call_id_buf: [max_call_id_len]u8 = @splat(0),
    call_id_len: u8 = 0,
    args_buf: [max_args_len]u8 = @splat(0),
    args_len: u16 = 0,
    args_total_bytes: u32 = 0,
    result_buf: [max_result_len]u8 = @splat(0),
    result_len: u16 = 0,
    result_total_bytes: u32 = 0,

    pub fn name(self: *const ToolCallMetric) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn callId(self: *const ToolCallMetric) []const u8 {
        return self.call_id_buf[0..self.call_id_len];
    }

    pub fn args(self: *const ToolCallMetric) []const u8 {
        return self.args_buf[0..self.args_len];
    }

    pub fn result(self: *const ToolCallMetric) []const u8 {
        return self.result_buf[0..self.result_len];
    }

    pub fn setName(self: *ToolCallMetric, value: []const u8) void {
        const n = @min(value.len, max_name_len);
        @memcpy(self.name_buf[0..n], value[0..n]);
        self.name_len = @intCast(n);
    }

    fn setCallId(self: *ToolCallMetric, value: []const u8) void {
        const n = utf8PrefixLen(value, max_call_id_len);
        @memcpy(self.call_id_buf[0..n], value[0..n]);
        self.call_id_len = @intCast(n);
    }

    /// Keeps the first bytes that fit, without part of a secret the cut
    /// splits (`text_utils.secretSafePrefixLen`).
    pub fn setArgs(self: *ToolCallMetric, value: []const u8) void {
        self.args_total_bytes = @intCast(@min(value.len, std.math.maxInt(u32)));
        const n = text_utils.secretSafePrefixLen(value, max_args_len);
        @memcpy(self.args_buf[0..n], value[0..n]);
        self.args_len = @intCast(n);
    }

    /// Keeps the first bytes that fit, without part of a secret the cut
    /// splits (`text_utils.secretSafePrefixLen`).
    pub fn setResult(self: *ToolCallMetric, value: []const u8) void {
        const normalized = tool_result_display.contentForDisplay(value);
        self.result_total_bytes = @intCast(@min(normalized.len, std.math.maxInt(u32)));
        const n = text_utils.secretSafePrefixLen(normalized, max_result_len);
        @memcpy(self.result_buf[0..n], normalized[0..n]);
        self.result_len = @intCast(n);
    }

    pub fn setPayloadsForName(self: *ToolCallMetric, tool_name: []const u8, arguments_json: []const u8, model_output: []const u8) void {
        if (omitsPayloadsForName(tool_name)) {
            self.clearPayloads();
            return;
        }
        self.setArgs(arguments_json);
        self.setResult(model_output);
    }

    fn clearPayloads(self: *ToolCallMetric) void {
        @memset(&self.args_buf, 0);
        self.args_len = 0;
        self.args_total_bytes = 0;
        @memset(&self.result_buf, 0);
        self.result_len = 0;
        self.result_total_bytes = 0;
    }
};

/// One field of a kept failure: its first and last bytes, each cut on a
/// UTF-8 boundary without part of a secret a cut splits, and how many bytes
/// the value had in all.
pub const KeptText = struct {
    buf: [max_failure_field_len]u8 = @splat(0),
    head_len: u16 = 0,
    tail_len: u16 = 0,
    total_bytes: u32 = 0,

    pub fn head(self: *const KeptText) []const u8 {
        return self.buf[0..self.head_len];
    }

    pub fn tail(self: *const KeptText) []const u8 {
        return self.buf[self.head_len..][0..self.tail_len];
    }

    /// Bytes between the head and the tail that were not kept.
    pub fn omittedBytes(self: *const KeptText) u32 {
        return self.total_bytes - self.head_len - self.tail_len;
    }

    pub fn set(self: *KeptText, value: []const u8) void {
        const kept = value[0..@min(value.len, std.math.maxInt(u32))];
        const cut = headTailCut(kept, max_failure_field_len);
        @memcpy(self.buf[0..cut.head_len], kept[0..cut.head_len]);
        @memcpy(self.buf[cut.head_len..][0..cut.tail_len], kept[kept.len - cut.tail_len ..]);
        self.head_len = @intCast(cut.head_len);
        self.tail_len = @intCast(cut.tail_len);
        self.total_bytes = @intCast(kept.len);
    }

    fn clear(self: *KeptText) void {
        self.head_len = 0;
        self.tail_len = 0;
        self.total_bytes = 0;
    }
};

/// A call that did not succeed, kept apart from the window.
pub const FailedToolCall = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: ToolCallOutcome = .rejected,
    subagent_id: u64 = 0,
    name_buf: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    call_id_buf: [max_call_id_len]u8 = @splat(0),
    call_id_len: u8 = 0,
    dir_buf: [max_dir_len]u8 = @splat(0),
    dir_len: u16 = 0,
    /// See `ToolCallRecord.reads_startup_files`.
    reads_startup_files: bool = false,
    args: KeptText = .{},
    result: KeptText = .{},

    pub fn name(self: *const FailedToolCall) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn callId(self: *const FailedToolCall) []const u8 {
        return self.call_id_buf[0..self.call_id_len];
    }

    /// The folder the tool ran against: where a shell command starts when
    /// it names no `cwd`. Empty when the call never reached a tool.
    pub fn dir(self: *const FailedToolCall) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }
};

const HeadTailCut = struct {
    head_len: usize,
    tail_len: usize,
};

/// Splits `value` into a head and a tail that fit `budget` bytes together,
/// each cut on a UTF-8 boundary and so that neither keeps part of a secret a
/// cut splits, which `maskSecrets` would not find when `/trace` writes them.
/// A value that fits stays whole in the head.
fn headTailCut(value: []const u8, budget: usize) HeadTailCut {
    if (value.len <= budget) return .{ .head_len = value.len, .tail_len = 0 };
    const head_len = text_utils.secretSafePrefixLen(value, budget / 2);
    const tail_start = text_utils.secretSafeSuffixStart(value, value.len - utf8SuffixLen(value, budget - head_len));
    return .{ .head_len = head_len, .tail_len = value.len - tail_start };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Length of the longest prefix of `value` no longer than `limit` that does
/// not end inside a UTF-8 sequence. Bytes that are not UTF-8 are cut as is.
fn utf8PrefixLen(value: []const u8, limit: usize) usize {
    if (value.len <= limit) return value.len;
    var end = limit;
    var steps: usize = 0;
    while (end > 0 and steps < 3 and isContinuationByte(value[end])) : (steps += 1) end -= 1;
    return if (isContinuationByte(value[end])) limit else end;
}

/// Length of the longest suffix of `value` no longer than `limit` that does
/// not start inside a UTF-8 sequence.
fn utf8SuffixLen(value: []const u8, limit: usize) usize {
    if (value.len <= limit) return value.len;
    var start = value.len - limit;
    var steps: usize = 0;
    while (start < value.len and steps < 3 and isContinuationByte(value[start])) : (steps += 1) start += 1;
    if (start < value.len and isContinuationByte(value[start])) return limit;
    return value.len - start;
}

pub const ToolCallRecord = struct {
    name: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
    outcome: ToolCallOutcome,
    started_at_ms: i64,
    subagent_id: u64 = 0,
    /// The provider's ID for the call, the `call_id` of its session-log records.
    call_id: []const u8 = "",
    /// The folder the tool ran against; see `FailedToolCall.dir`.
    dir: []const u8 = "",
    /// Whether the call is a shell run whose command ran with the startup
    /// files the shell snapshot holds. The caller decides it from the resolved
    /// command, as admission does, so the trace names redefined commands only
    /// for such a run.
    reads_startup_files: bool = false,
};

pub fn omitsPayloadsForName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch");
}

var mutex: std.Io.Mutex = .init;
// All-zero so the rings land in .bss instead of initialized data in the
// binary. At-rest slots are never observed: snapshots are bounded by their
// `stored` counts and records overwrite whole slots.
var ring: [ring_capacity]ToolCallMetric = std.mem.zeroes([ring_capacity]ToolCallMetric);
var head: usize = 0;
var stored: usize = 0;
var failures: [failure_ring_capacity]FailedToolCall = std.mem.zeroes([failure_ring_capacity]FailedToolCall);
var failures_head: usize = 0;
var failures_stored: usize = 0;

/// Session-wide totals, reset on session transitions via
/// `diagnostics.resetSession()`. Unlike the ring, these never evict: the
/// /trace report must answer "did anything fail all session" even after the
/// window slides.
pub const LifetimeStats = struct {
    total_calls: u64 = 0,
    outcome_counts: [@typeInfo(ToolCallOutcome).@"enum".field_names.len]u64 = @splat(0),
    total_duration_ms: u64 = 0,

    pub fn countFor(self: *const LifetimeStats, outcome: ToolCallOutcome) u64 {
        return self.outcome_counts[@backingInt(outcome)];
    }

    /// Calls this session that did not succeed.
    pub fn failureCount(self: *const LifetimeStats) u64 {
        return self.total_calls - self.countFor(.succeeded);
    }
};

var lifetime: LifetimeStats = .{};

pub fn record(call: ToolCallMetric) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    recordLocked(call);
}

fn recordLocked(call: ToolCallMetric) void {
    var stored_call = call;
    if (omitsPayloadsForName(stored_call.name())) stored_call.clearPayloads();

    ring[head] = stored_call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;

    lifetime.total_calls += 1;
    lifetime.outcome_counts[@backingInt(stored_call.outcome)] += 1;
    lifetime.total_duration_ms += stored_call.duration_ms;
}

/// Writes a failed call into the failure ring from its whole arguments and
/// output. The slot is filled in place: a kept failure is about 17 KiB.
fn recordFailureLocked(input: ToolCallRecord, duration_ms: u32) void {
    const slot = &failures[failures_head];
    failures_head = (failures_head + 1) % failure_ring_capacity;
    if (failures_stored < failure_ring_capacity) failures_stored += 1;

    slot.started_at_ms = input.started_at_ms;
    slot.duration_ms = duration_ms;
    slot.outcome = input.outcome;
    slot.subagent_id = input.subagent_id;
    const name_len = @min(input.name.len, max_name_len);
    @memcpy(slot.name_buf[0..name_len], input.name[0..name_len]);
    slot.name_len = @intCast(name_len);
    const call_id_len = utf8PrefixLen(input.call_id, max_call_id_len);
    @memcpy(slot.call_id_buf[0..call_id_len], input.call_id[0..call_id_len]);
    slot.call_id_len = @intCast(call_id_len);
    const dir_len = utf8PrefixLen(input.dir, max_dir_len);
    @memcpy(slot.dir_buf[0..dir_len], input.dir[0..dir_len]);
    slot.dir_len = @intCast(dir_len);
    slot.reads_startup_files = input.reads_startup_files;
    if (omitsPayloadsForName(input.name)) {
        slot.args.clear();
        slot.result.clear();
    } else {
        slot.args.set(input.arguments_json);
        slot.result.set(tool_result_display.contentForDisplay(input.model_output));
    }
}

pub fn lifetimeStats() LifetimeStats {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return lifetime;
}

pub fn recordResult(input: ToolCallRecord) void {
    const now_ms = io_mod.milliTimestamp();
    const elapsed = if (now_ms > input.started_at_ms) now_ms - input.started_at_ms else 0;
    var metric: ToolCallMetric = .{
        .started_at_ms = input.started_at_ms,
        .duration_ms = @intCast(@min(@as(i64, elapsed), std.math.maxInt(u32))),
        .outcome = input.outcome,
        .subagent_id = input.subagent_id,
    };
    metric.setName(input.name);
    metric.setCallId(input.call_id);
    metric.setPayloadsForName(input.name, input.arguments_json, input.model_output);

    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    // One lock for both rings, so a snapshot never sees a failure in the
    // window that the failure ring does not hold yet.
    recordLocked(metric);
    if (input.outcome != .succeeded) recordFailureLocked(input, metric.duration_ms);
}

pub fn snapshot(out: []ToolCallMetric) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (head + ring_capacity - n + i) % ring_capacity;
        out[i] = ring[idx];
    }
    return n;
}

/// Copies the newest kept failures into `out`, oldest first.
pub fn snapshotFailures(out: []FailedToolCall) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(failures_stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (failures_head + failure_ring_capacity - n + i) % failure_ring_capacity;
        out[i] = failures[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    failures_head = 0;
    failures_stored = 0;
    lifetime = .{};
}

pub fn resetForTest() void {
    reset();
}

test "tool call ring keeps last N records in chronological order" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 3) : (i += 1) {
        var call: ToolCallMetric = .{ .duration_ms = i };
        call.setName("read_file");
        call.setArgs("{}");
        call.setResult("ok");
        record(call);
    }

    var buf: [ring_capacity]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(ring_capacity, n);
    try std.testing.expectEqual(@as(u32, 3), buf[0].duration_ms);
    try std.testing.expectEqual(@as(u32, ring_capacity + 3 - 1), buf[ring_capacity - 1].duration_ms);
}

fn recordTestCall(
    tool_name: []const u8,
    outcome: ToolCallOutcome,
    call_id: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
) void {
    recordResult(.{
        .name = tool_name,
        .arguments_json = arguments_json,
        .model_output = model_output,
        .outcome = outcome,
        .started_at_ms = io_mod.milliTimestamp(),
        .call_id = call_id,
        .dir = "/Users/example/project",
    });
}

fn snapshotFailuresForTest() ![]FailedToolCall {
    const out = try std.testing.allocator.alloc(FailedToolCall, failure_ring_capacity);
    return out[0..snapshotFailures(out)];
}

fn freeFailuresForTest(kept: []FailedToolCall) void {
    std.testing.allocator.free(kept.ptr[0..failure_ring_capacity]);
}

fn expectCutLaws(value: []const u8, budget: usize, valid_utf8: bool) !void {
    const cut = headTailCut(value, budget);
    if (value.len <= budget) {
        try std.testing.expectEqual(value.len, cut.head_len);
        try std.testing.expectEqual(@as(usize, 0), cut.tail_len);
        return;
    }
    try std.testing.expect(cut.head_len + cut.tail_len <= budget);
    try std.testing.expect(cut.head_len <= budget / 2);
    if (valid_utf8) {
        try std.testing.expect(std.unicode.utf8ValidateSlice(value[0..cut.head_len]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(value[value.len - cut.tail_len ..]));
        // A valid cut loses at most three bytes on each side.
        try std.testing.expect(cut.head_len + 3 >= budget / 2);
        try std.testing.expect(cut.head_len + cut.tail_len + 3 >= budget);
    }
}

fn fuzzTraceCuts(_: void, smith: *std.testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const value = buffer[0..len];
    const budget = smith.valueRangeAtMost(u16, 0, 600);
    try expectCutLaws(value, budget, std.unicode.utf8ValidateSlice(value));

    var kept: KeptText = .{};
    kept.set(value);
    try std.testing.expect(std.mem.startsWith(u8, value, kept.head()));
    try std.testing.expect(std.mem.endsWith(u8, value, kept.tail()));
    try std.testing.expectEqual(@as(u32, @intCast(len)), kept.total_bytes);
}

/// Whether each thread's calls appear in the order it made them; IDs are
/// `t<thread>-<seq>`.
fn idsAscendPerThread(comptime T: type, calls: []const T) bool {
    var last: [8]?usize = @splat(null);
    for (calls) |call| {
        const id = call.callId();
        const dash = std.mem.findScalar(u8, id, '-') orelse return false;
        const thread_index = std.fmt.parseInt(usize, id[1..dash], 10) catch return false;
        const seq = std.fmt.parseInt(usize, id[dash + 1 ..], 10) catch return false;
        if (thread_index >= last.len) return false;
        if (last[thread_index]) |previous| if (seq <= previous) return false;
        last[thread_index] = seq;
    }
    return true;
}

/// A `max_failure_field_len + 200` byte value of `word ` cycles, with
/// `planted` at `planted_start` after a space, and ` done` at the end.
fn fillKeptValue(value_buf: []u8, planted: []const u8, planted_start: usize) []const u8 {
    const value = value_buf[0 .. max_failure_field_len + 200];
    for (value, 0..) |*byte, index| byte.* = "word "[index % "word ".len];
    if (planted_start > 0) value[planted_start - 1] = ' ';
    @memcpy(value[planted_start..][0..planted.len], planted);
    @memcpy(value[value.len - " done".len ..], " done");
    return value;
}

fn expectKeptTextKeepsNoToken(arena: std.mem.Allocator, kept: KeptText, value: []const u8) !void {
    try std.testing.expect(kept.head().len + kept.tail().len <= max_failure_field_len);
    try std.testing.expectEqual(@as(u32, @intCast(value.len)), kept.total_bytes);
    try std.testing.expectEqual(
        @as(u32, @intCast(value.len - kept.head().len - kept.tail().len)),
        kept.omittedBytes(),
    );
    const masked_head = try text_utils.maskSecrets(arena, kept.head());
    try std.testing.expect(std.mem.find(u8, masked_head, "AAAAAA") == null);
    const masked_tail = try text_utils.maskSecrets(arena, kept.tail());
    try std.testing.expect(std.mem.find(u8, masked_tail, "AAAAAA") == null);
}
