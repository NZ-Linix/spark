const std = @import("std");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

pub const Source = types.CredentialSource;

pub const AuthMode = enum {
    local,
    host_managed,
};

pub const AuthModeError = error{InvalidAuthMode};

pub fn parseAuthMode(value: ?[]const u8) AuthModeError!AuthMode {
    const raw = value orelse return .local;
    if (std.mem.eql(u8, raw, "local")) return .local;
    if (std.mem.eql(u8, raw, "host-managed")) return .host_managed;
    return error.InvalidAuthMode;
}

/// A borrowed authorization decision for one model-catalog request. A
/// configured provider sends its own key with each request, so a catalog
/// request is either public or managed by the host.
pub const CatalogAccess = union(enum) {
    public_only,
    host_managed,

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => null,
            .host_managed => .host_managed,
        };
    }
};

pub fn catalogAccessFor(source: ?Source) CatalogAccess {
    return if (source == .host_managed) .host_managed else .public_only;
}

pub const missing_credential_message = "spark has no model provider. Start spark and run /provider to add an OpenAI-compatible endpoint.";
pub const missing_interactive_credential_message = "spark needs a model provider. Run /provider to add an OpenAI-compatible endpoint.";
pub const host_managed_auth_message = "Authentication is managed by the host.";

pub const Credential = struct {
    token: []u8,
    source: Source,

    pub fn clone(self: Credential, alloc: std.mem.Allocator) !Credential {
        return .{ .token = try alloc.dupe(u8, self.token), .source = self.source };
    }

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        self.* = undefined;
    }
};

pub const LoadFailure = struct {
    source: Source,
    err: anyerror,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    failure: ?LoadFailure = null,
};

/// The credential a configured provider's definition names: none, an
/// environment variable, or a key saved with it. `.none` has no credential.
pub fn resolveForProvider(alloc: std.mem.Allocator, provider: model_provider.ProviderId) !Resolution {
    if (provider != .configured) return .{};
    var registry = try @import("../config/config_runtime.zig").loadConfiguredProviders(alloc);
    defer registry.deinit(alloc);
    const bound = try provider.bind(registry);
    const definition = registry.get(bound.label()).?;
    return switch (definition.auth) {
        // The HTTP adapter reads/renews this account at send time; never cache its OAuth token in an agent.
        .none, .chatgpt_plan => .{ .credential = .{ .token = try alloc.dupe(u8, ""), .source = .configured } },
        .bearer => |env| .{ .credential = try loadEnvCredential(alloc, env) },
        .key => |key| .{ .credential = .{ .token = try alloc.dupe(u8, key), .source = .configured } },
    };
}

fn loadEnvCredential(alloc: std.mem.Allocator, name: []const u8) !?Credential {
    const raw = io_mod.getenv(name) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return .{ .token = try alloc.dupe(u8, raw), .source = .configured };
}

/// Whether a rejected credential from `source` can be renewed for one more
/// send. No source can: a configured key stays what its settings say.
pub fn sourceRefreshable(_: Source) bool {
    return false;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .host_managed => "host managed",
        .configured => "configured provider",
    };
}
