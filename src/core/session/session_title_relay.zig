const std = @import("std");
const io = @import("../shared/io.zig");
const paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");
const http = @import("../../builtins/oauth_http.zig");
const Allocator = std.mem.Allocator;

pub const model = "z-ai/glm-5.3-flash";

pub const Route = struct {
    url: []u8,
    authorization: []u8,

    pub fn deinit(self: Route, alloc: Allocator) void {
        alloc.free(self.url);
        secret.zeroAndFree(alloc, self.authorization);
    }

    pub fn generate(self: Route, alloc: Allocator, excerpt: []const u8, cancel_flag: *std.atomic.Value(bool), deadline: std.Io.Clock.Timestamp) !?[]u8 {
        const payload = try std.json.Stringify.valueAlloc(alloc, .{ .prompt = excerpt }, .{});
        defer secret.zeroAndFree(alloc, payload);
        var response = try http.provider.execute(alloc, .{
            .method = .post_json,
            .url = self.url,
            .authorization = self.authorization,
            .payload = payload,
            .cancel_flag = cancel_flag,
            .deadline = deadline,
            .max_response_bytes = 1024,
        });
        defer response.deinit(alloc);
        if (response.disposition != .accepted) return null;
        const parsed = try std.json.parseFromSlice(struct { title: []const u8 }, alloc, response.body, .{});
        defer parsed.deinit();
        return try alloc.dupe(u8, parsed.value.title);
    }
};

pub fn load(alloc: Allocator) !?Route {
    if (comptime @import("builtin").target.os.tag == .wasi) return null;
    const root = (try paths.activeRoot(alloc, io.homeDir())) orelse return null;
    defer alloc.free(root);
    const io_ctx = io.getIo();
    var parent = std.Io.Dir.openDirAbsolute(io_ctx, std.Io.Dir.path.dirname(root) orelse "/", .{}) catch |err| return if (err == error.FileNotFound) null else err;
    defer parent.close(io_ctx);
    var dir = parent.openDir(io_ctx, std.Io.Dir.path.basename(root), .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) null else err;
    defer dir.close(io_ctx);
    return try readRoute(alloc, dir, "session-title-relay.json") orelse try readRoute(alloc, dir, "mobile-title-relay.json");
}

fn readRoute(alloc: Allocator, dir: std.Io.Dir, name: []const u8) !?Route {
    var file = io.openExistingRegularFile(dir, name, .read_only) catch |err| return if (err == error.FileNotFound) null else err;
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.UnsafeTitleRelayConfig;
    const bytes = try io.readFileToEnd(alloc, &file, 8192);
    defer secret.zeroAndFree(alloc, bytes);
    const parsed = try std.json.parseFromSlice(struct { relay: []const u8, token: []const u8 }, alloc, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const relay = std.mem.trimEnd(u8, parsed.value.relay, "/");
    const uri = std.Uri.parse(relay) catch return error.InvalidTitleRelay;
    const host = switch (uri.host orelse return error.InvalidTitleRelay) {
        .raw, .percent_encoded => |value| value,
    };
    const local = std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "localhost");
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !(local and std.ascii.eqlIgnoreCase(uri.scheme, "http"))) or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidTitleRelay;
    const token = parsed.value.token;
    if (token.len < 24 or token.len > 256) return error.InvalidTitleRelay;
    for (token) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidTitleRelay;
    const url = try alloc.print("{s}/api/session-title", .{relay});
    errdefer alloc.free(url);
    return .{ .url = url, .authorization = try alloc.print("Bearer {s}", .{token}) };
}
