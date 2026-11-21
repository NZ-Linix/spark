//! The record of one settled model request, which Ctrl+O shows where it
//! happened (`types.ModelCallRecord`). Pure: the caller says when the
//! request started and when it settled.

const std = @import("std");
const types = @import("../../shared/types.zig");
const agent_stream_provider = @import("../stream_provider.zig");

/// Takes each settled request's record from a caller that makes model
/// requests outside the turn loop, such as compaction. The record borrows
/// its strings for the call; a sink that keeps it copies it.
pub const Sink = struct {
    context: *anyopaque,
    record_fn: *const fn (context: *anyopaque, record: types.ModelCallRecord) void,
    /// Who the requests go to, as the record names it.
    provider: []const u8,

    pub fn record(self: Sink, value: types.ModelCallRecord) void {
        self.record_fn(self.context, value);
    }
};

/// The record of a request that settled with a result, borrowing its
/// strings. Provider text that `types.validModelCallText` refuses is left
/// out, so a record never fails its own checks when saved or replayed. A
/// stop asked for while it streamed (`stop_requested`) makes what came so
/// far a cancelled call.
pub fn ofResult(
    provider: []const u8,
    model: []const u8,
    purpose: types.ModelCallPurpose,
    started_ms: i64,
    settled_ms: i64,
    result: *const agent_stream_provider.Result,
    stop_requested: bool,
) types.ModelCallRecord {
    var record: types.ModelCallRecord = .{
        .at_ms = settled_ms,
        .elapsed_ms = elapsed(started_ms, settled_ms),
        .purpose = purpose,
        .provider = provider,
        .model = model,
    };
    switch (result.*) {
        .completed => |*completed| {
            const completion = completed.completion;
            record.generation_id = checked(completion.generation_id);
            record.served_by = checked(completion.resolved_provider);
            if (completion.finish_reason) |reason| record.finish = @tagName(reason);
            record.input_tokens = completion.usage.input_tokens;
            record.output_tokens = completion.usage.output_tokens;
            if (stop_requested) record.outcome = .cancelled;
        },
        .failed => |*failure| {
            record.outcome = .failed;
            record.failure = @tagName(failure.kind);
            if (failure.retry_after_seconds) |seconds| record.retry_after_s = std.math.cast(u32, seconds);
        },
    }
    return record;
}

/// The record of a request that ended in an error instead of a result:
/// cancelled when it was stopped, failed otherwise.
pub fn ofError(
    provider: []const u8,
    model: []const u8,
    purpose: types.ModelCallPurpose,
    started_ms: i64,
    settled_ms: i64,
    cancelled: bool,
    err: anyerror,
) types.ModelCallRecord {
    return .{
        .at_ms = settled_ms,
        .elapsed_ms = elapsed(started_ms, settled_ms),
        .purpose = purpose,
        .outcome = if (cancelled) .cancelled else .failed,
        .provider = provider,
        .model = model,
        .failure = if (cancelled) null else @errorName(err),
    };
}

/// A clock that steps back never makes a negative duration.
fn elapsed(started_ms: i64, settled_ms: i64) u64 {
    return @intCast(@max(settled_ms - started_ms, 0));
}

fn checked(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (types.validModelCallText(value)) value else null;
}
