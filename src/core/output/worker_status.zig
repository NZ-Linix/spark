const std = @import("std");
const activity_runtime = @import("activity_runtime.zig");
const types = @import("../shared/types.zig");

/// The warning sign before a waiting or "needs you" status.
const warning_sign = "⚠ ";
/// The thinking row's bullet, before a request that is on the wire again.
const live_bullet = "• ";
const label_capacity = types.RouteRecoveryStatus.label_max_bytes + @max(warning_sign.len, live_bullet.len);

/// The status row for a route recovery status. A recovery-module status shows
/// its `text`, or its `short` form when the row is narrower than `text`,
/// behind the sign its tone calls for. The module refreshes its own countdown
/// once a second, so the row never computes time itself.
const RouteRecoveryStatus = struct {
    status: types.RouteRecoveryStatus,
    label: [label_capacity]u8 = undefined,
    label_len: usize = 0,
    short: [label_capacity]u8 = undefined,
    short_len: usize = 0,

    fn init(status: types.RouteRecoveryStatus) RouteRecoveryStatus {
        var result = RouteRecoveryStatus{ .status = status };
        if (status.fromModule()) {
            const sign = switch (status.tone()) {
                .live => live_bullet,
                .warning, .success, .danger => warning_sign,
            };
            result.label_len = signed(&result.label, sign, status.text.slice());
            if (status.short.len > 0) result.short_len = signed(&result.short, sign, status.short.slice());
        } else {
            const label = status.label(&result.label);
            store_label(result.label[0..], &result.label_len, label);
        }
        return result;
    }

    fn signed(buf: *[label_capacity]u8, sign: []const u8, text: []const u8) usize {
        @memcpy(buf[0..sign.len], sign);
        const len = @min(text.len, buf.len - sign.len);
        @memcpy(buf[sign.len..][0..len], text[0..len]);
        return sign.len + len;
    }

    fn projection(self: *const RouteRecoveryStatus) activity_runtime.ActivityProjection {
        return .{ .turn_thinking = .{
            .label = self.label[0..self.label_len],
            .short_label = if (self.short_len > 0) self.short[0..self.short_len] else null,
            .tone = switch (self.status.tone()) {
                .live => .live,
                .warning => .warning,
                .success => .success,
                .danger => .danger,
            },
        } };
    }
};

const ApiStatus = struct {
    label: [512]u8 = undefined,
    label_len: usize = 0,
    tone: activity_runtime.ActivityProjection.Tone = .danger,

    fn init(label: []const u8, tone: activity_runtime.ActivityProjection.Tone) ApiStatus {
        var result = ApiStatus{ .tone = tone };
        store_label(result.label[0..], &result.label_len, label);
        return result;
    }

    fn projection(self: *const ApiStatus) activity_runtime.ActivityProjection {
        return .{ .turn_thinking = .{
            .label = self.label[0..self.label_len],
            .tone = self.tone,
        } };
    }
};

pub const State = union(enum) {
    none,
    route_recovery: RouteRecoveryStatus,
    api: ApiStatus,

    pub fn projection(self: *const State) ?activity_runtime.ActivityProjection {
        return switch (self.*) {
            .none => null,
            .route_recovery => |*status| status.projection(),
            .api => |*status| status.projection(),
        };
    }

    pub fn set_route_recovery(self: *State, status: types.RouteRecoveryStatus) void {
        self.* = .{ .route_recovery = RouteRecoveryStatus.init(status) };
    }

    pub fn set_api(
        self: *State,
        label: []const u8,
        tone: activity_runtime.ActivityProjection.Tone,
    ) void {
        self.* = .{ .api = ApiStatus.init(label, tone) };
    }

    /// Whether the status shown is a request waiting for the user, which one
    /// Esc ends and Enter on an empty composer continues.
    pub fn waitsForUser(self: *const State) bool {
        return switch (self.*) {
            .route_recovery => |*status| status.status.kind == .need_user,
            .none, .api => false,
        };
    }

    /// Whether the status shown is a request waiting for the user to sign in.
    pub fn waitsForSignIn(self: *const State) bool {
        return switch (self.*) {
            .route_recovery => |*status| status.status.kind == .need_user and
                if (status.status.need) |need| need == .sign_in else false,
            .none, .api => false,
        };
    }

    pub fn clear_route_recovery(self: *State) bool {
        return switch (self.*) {
            .route_recovery => blk: {
                self.* = .none;
                break :blk true;
            },
            .none, .api => false,
        };
    }

    pub fn clear(self: *State) bool {
        return switch (self.*) {
            .none => false,
            .route_recovery, .api => blk: {
                self.* = .none;
                break :blk true;
            },
        };
    }

    pub fn reset(self: *State) void {
        self.* = .none;
    }
};

fn store_label(buffer: []u8, len: *usize, label: []const u8) void {
    if (label.ptr != buffer.ptr) {
        const copied_len = @min(label.len, buffer.len);
        @memcpy(buffer[0..copied_len], label[0..copied_len]);
        len.* = copied_len;
        return;
    }
    len.* = label.len;
}

const testText = types.testRecoveryText;

fn expectLabel(state: *const State, label: []const u8, short: ?[]const u8, tone: activity_runtime.ActivityProjection.Tone) !void {
    switch (state.projection().?) {
        .turn_thinking => |projection| {
            try std.testing.expectEqualStrings(label, projection.label);
            if (short) |expected| {
                try std.testing.expectEqualStrings(expected, projection.short_label.?);
            } else {
                try std.testing.expect(projection.short_label == null);
            }
            try std.testing.expectEqual(tone, projection.tone);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}
