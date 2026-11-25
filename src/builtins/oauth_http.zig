//! The native HTTP transport OAuth flows use, such as MCP sign-in and the
//! Slack install.

const std = @import("std");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const gateway_client = @import("../gateway/client.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const oauth_request_timeout_ms = oauth_transport.default_request_timeout_ms;
const oauth_response_max_bytes: usize = 64 * 1024;

pub const provider = oauth_transport.Provider{
    .execute_fn = executeOAuthRequest,
};

fn executeOAuthRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const deadline = request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_request_timeout_ms),
    });
    var operation = OAuthHttpOperation{
        .alloc = alloc,
        .request = request,
    };
    return gateway_client.runBoundedHttpOperation(
        oauth_transport.Response,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

const OAuthHttpOperation = struct {
    alloc: Allocator,
    request: oauth_transport.Request,

    pub fn run(self: *@This()) !oauth_transport.Response {
        const max_bytes = self.request.max_response_bytes orelse oauth_response_max_bytes;
        const response_buffer = try self.alloc.alloc(u8, max_bytes + 1);
        defer secret.zeroAndFree(self.alloc, response_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);

        const result = gateway_client.fetchOnOpenJob(.{
            .location = .{ .url = self.request.url },
            .method = switch (self.request.method) {
                .get => .GET,
                .post_form, .post_json => .POST,
            },
            .payload = self.request.payload,
            .headers = .{
                .content_type = switch (self.request.method) {
                    .get => .default,
                    .post_form => .{ .override = "application/x-www-form-urlencoded" },
                    .post_json => .{ .override = "application/json" },
                },
                .user_agent = .{ .override = self.request.user_agent orelse gateway_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.request.authorization) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .extra_headers = self.request.extra_headers,
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OAuthResponseTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_bytes) return error.OAuthResponseTooLarge;

        return .{
            .disposition = if (result.status == .ok) .accepted else .rejected,
            .body = try self.alloc.dupe(u8, body),
            .status = @backingInt(result.status),
        };
    }
};
