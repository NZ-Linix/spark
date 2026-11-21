const std = @import("std");

pub const Handle = i32;

pub const TerminalKind = enum {
    success,
    failure,
    aborted,
};

pub const Terminal = struct {
    handle: Handle,
    kind: TerminalKind,
};

pub const Phase = union(enum) {
    idle,
    request_pending: Handle,
    awaiting_response: Handle,
    streaming: Handle,
    terminal: Terminal,
    shutdown,
};

pub const Event = union(enum) {
    open: Handle,
    take_request,
    start: Handle,
    push: Handle,
    finish: Handle,
    consumed: Handle,
    fail: Handle,
    close: Handle,
    cancel,
    shutdown,
};

pub const Action = enum {
    applied,
    stale,
    no_request,
    unavailable,
    shutting_down,
};

pub const StaleReason = enum {
    no_active_fetch,
    handle_mismatch,
    phase_mismatch,
    terminal,
    shutdown,
};

pub const Decision = struct {
    phase: Phase,
    action: Action,
    stale_reason: ?StaleReason = null,
};

pub fn decide(phase: Phase, event: Event) Decision {
    return switch (event) {
        .open => |handle| switch (phase) {
            .idle => .{
                .phase = .{ .request_pending = handle },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .unavailable },
        },
        .take_request => switch (phase) {
            .request_pending => |handle| .{
                .phase = .{ .awaiting_response = handle },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .no_request },
        },
        .start => |handle| switch (phase) {
            .awaiting_response => |active| if (active == handle)
                .{ .phase = .{ .streaming = handle }, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .push => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .finish => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .success } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .consumed => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            .terminal => |terminal| if (terminal.handle == handle and terminal.kind == .success)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .fail => |handle| switch (phase) {
            .awaiting_response, .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .failure } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .close => |handle| switch (phase) {
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            .terminal => |terminal| if (terminal.handle == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .cancel => switch (phase) {
            .idle => .{ .phase = .idle, .action = .no_request },
            .request_pending, .awaiting_response, .streaming => |handle| .{
                .phase = .{ .terminal = .{ .handle = handle, .kind = .aborted } },
                .action = .applied,
            },
            .terminal => |terminal| if (terminal.kind == .success)
                .{
                    .phase = .{ .terminal = .{ .handle = terminal.handle, .kind = .aborted } },
                    .action = .applied,
                }
            else
                .{ .phase = phase, .action = .no_request },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
        },
        .shutdown => switch (phase) {
            .shutdown => .{ .phase = .shutdown, .action = .no_request },
            else => .{ .phase = .shutdown, .action = .applied },
        },
    };
}

/// Keeps one exact logical-consumption identity independently of the HTTP phase.
/// Explicit cancellation revokes it even after close or shutdown; EOF does not grant it.
pub fn consumed_after(phase: Phase, last_consumed_handle: ?Handle, event: Event) ?Handle {
    return switch (event) {
        .consumed => |handle| if (decide(phase, event).action == .applied) handle else last_consumed_handle,
        .cancel => null,
        else => last_consumed_handle,
    };
}

pub const Disposition = enum(i32) {
    retired = 0,
    active = 1,
    consumed = 2,
};

/// Call with phase and consumption identity from the same synchronized observation.
pub fn disposition(phase: Phase, last_consumed_handle: ?Handle, handle: Handle) Disposition {
    if (last_consumed_handle == handle) return .consumed;
    return if (is_active(phase, handle)) .active else .retired;
}

pub fn is_active(phase: Phase, handle: Handle) bool {
    return switch (phase) {
        .request_pending, .awaiting_response, .streaming => |active| active == handle,
        else => false,
    };
}

fn stale(phase: Phase, handle: Handle) Decision {
    return .{
        .phase = phase,
        .action = .stale,
        .stale_reason = switch (phase) {
            .idle => .no_active_fetch,
            .shutdown => .shutdown,
            .terminal => |terminal| if (terminal.handle == handle) .terminal else .handle_mismatch,
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .phase_mismatch
            else
                .handle_mismatch,
        },
    };
}

fn expectDecision(expected: Decision, actual: Decision) !void {
    try std.testing.expectEqualDeep(expected, actual);
}

test "N-API fetch state applies matching lifecycle transitions" {
    const handle: Handle = 7;
    const opened = decide(.idle, .{ .open = handle });
    try expectDecision(.{
        .phase = .{ .request_pending = handle },
        .action = .applied,
    }, opened);

    const taken = decide(opened.phase, .take_request);
    try expectDecision(.{
        .phase = .{ .awaiting_response = handle },
        .action = .applied,
    }, taken);

    const started = decide(taken.phase, .{ .start = handle });
    try expectDecision(.{
        .phase = .{ .streaming = handle },
        .action = .applied,
    }, started);
    try std.testing.expect(is_active(started.phase, handle));

    const pushed = decide(started.phase, .{ .push = handle });
    try expectDecision(.{
        .phase = .{ .streaming = handle },
        .action = .applied,
    }, pushed);

    const finished = decide(pushed.phase, .{ .finish = handle });
    try expectDecision(.{
        .phase = .{ .terminal = .{ .handle = handle, .kind = .success } },
        .action = .applied,
    }, finished);
    try std.testing.expect(!is_active(finished.phase, handle));

    const closed = decide(finished.phase, .{ .close = handle });
    try expectDecision(.{ .phase = .idle, .action = .applied }, closed);
}

const ConsumptionTrace = struct {
    phase: Phase = .idle,
    last_consumed_handle: ?Handle = null,

    fn apply(self: *@This(), event: Event) Decision {
        const decision = decide(self.phase, event);
        self.last_consumed_handle = consumed_after(self.phase, self.last_consumed_handle, event);
        self.phase = decision.phase;
        return decision;
    }
};
