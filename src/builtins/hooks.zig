//! First-party lifecycle hook providers.
//!
//! The Herdr provider reports semantic foreground state for interactive work.
//! Notification hooks live in `notifications` and keep sound policy outside
//! the Core hook harness.

const std = @import("std");
const hooks = @import("../core/hooks/hooks.zig");
const herdr = @import("hooks/herdr.zig");

pub const notifications = @import("hooks/notifications.zig");
pub const Client = herdr.Client;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Turns herdr on from the environment and reports the session and
        /// an idle pane. Later changes come from `reconcile`, so one agent's
        /// turn ending can't mark the pane idle while another works.
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.herdr.initFromEnv(app.alloc);
            if (!app.herdr.enabled) return;

            if (active_session_id) |session_id| {
                app.herdr.reportSession(session_id);
            }
            app.herdr.reportState(.idle, null);
            app.herdr.announce();
        }

        /// Reports the busiest agent's state when it changed: blocked over
        /// working, and working over idle. The main loop runs it after each
        /// pass, since it owns every agent's prompts.
        pub fn reconcile(app: *App) void {
            if (!app.herdr.enabled) return;
            const Report = struct { state: herdr.State, status: ?[]const u8 = null };
            const report: Report = switch (app.agentsBusiest()) {
                .needs_approval => .{ .state = .blocked, .status = attentionStatus(.permission) },
                .has_question => .{ .state = .blocked, .status = attentionStatus(.question) },
                .needs_you => .{ .state = .blocked, .status = attentionStatus(.route_recovery) },
                .working => .{ .state = .working },
                .idle => .{ .state = .idle },
            };
            app.herdr.reportStateIfChanged(report.state, report.status);
        }

        fn attentionStatus(kind: hooks.AttentionKind) []const u8 {
            return switch (kind) {
                .permission => "permission",
                .question => "question",
                .route_recovery => "recovery",
            };
        }
    };
}

const RecordingClient = struct {
    const Report = struct {
        state: herdr.State,
        status: ?[]const u8,
    };

    reports: [6]Report = undefined,
    report_count: usize = 0,
    enabled: bool = false,
    enable_on_init: bool = true,
    initialized: bool = false,
    announced: bool = false,
    session_id: ?[]const u8 = null,
    last: herdr.LastReport = .{},

    fn initFromEnv(self: *RecordingClient, _: std.mem.Allocator) void {
        self.initialized = true;
        self.enabled = self.enable_on_init;
    }

    fn reportSession(self: *RecordingClient, session_id: []const u8) void {
        self.session_id = session_id;
    }

    fn announce(self: *RecordingClient) void {
        self.announced = true;
    }

    fn reportState(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        _ = self.last.changed(state, status);
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }

    fn reportStateIfChanged(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        if (!self.last.changed(state, status)) return;
        self.reports[self.report_count] = .{ .state = state, .status = status };
        self.report_count += 1;
    }
};

fn expectReport(actual: RecordingClient.Report, state: herdr.State, status: ?[]const u8) !void {
    try std.testing.expectEqual(state, actual.state);
    if (status) |expected| {
        try std.testing.expectEqualStrings(expected, actual.status orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual.status == null);
    }
}
