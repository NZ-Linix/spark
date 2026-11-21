const std = @import("std");
const credentials = @import("credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const oauth_transport = @import("oauth_transport.zig");
const host = @import("../hosts/host.zig");

const Allocator = std.mem.Allocator;

/// What `Runtime.selectForProvider` did with the provider's credential.
pub const ProviderCredentialSelection = union(enum) {
    selected,
    unchanged,
    /// The provider names no credential spark can read, or none is chosen.
    missing,
    failed: credentials.LoadFailure,
};

/// Borrowed from the runtime until its next adoption or deinit.
pub const PromptCredential = struct {
    api_key: ?[]const u8,
    source: credentials.Source,
};

/// The credential the session sends. A configured provider's credential comes
/// from its definition: an inline key, an environment variable, or none.
pub const Runtime = struct {
    mode: credentials.AuthMode = .local,
    credential: ?credentials.Credential = null,
    failure: ?credentials.LoadFailure = null,
    /// The provider `credential` was loaded for.
    loaded_for: model_provider.ProviderId = .none,
    /// The HTTP transport OAuth flows such as MCP sign-in use.
    oauth: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secrets: host.SecretStore = host.unavailable_secret_store,

    pub fn initWithMode(mode: credentials.AuthMode) Runtime {
        return .{ .mode = mode };
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        if (self.credential) |*credential| credential.deinit(alloc);
        self.* = .{ .mode = self.mode, .oauth = self.oauth, .secrets = self.secrets };
    }

    pub fn oauthTransport(self: *const Runtime) oauth_transport.Provider {
        return self.oauth;
    }

    pub fn secretStore(self: *const Runtime) host.SecretStore {
        return self.secrets;
    }

    pub fn isHostManaged(self: *const Runtime) bool {
        return self.mode == .host_managed;
    }

    pub fn authMode(self: *const Runtime) credentials.AuthMode {
        return self.mode;
    }

    /// Borrowed until the next adoption or deinit; empty when there is none.
    pub fn apiKey(self: *const Runtime) []const u8 {
        const credential = self.credential orelse return "";
        return credential.token;
    }

    /// The key a prompt sends and where it came from. A host-managed session
    /// sends no key. Null when there is no credential.
    pub fn promptCredential(self: *const Runtime) ?PromptCredential {
        if (self.mode == .host_managed) return .{ .api_key = null, .source = .host_managed };
        const credential = self.credential orelse return null;
        return .{ .api_key = credential.token, .source = credential.source };
    }

    pub fn credentialSource(self: *const Runtime) ?credentials.Source {
        if (self.mode == .host_managed) return .host_managed;
        const credential = self.credential orelse return null;
        return credential.source;
    }

    pub fn modelCatalogAccess(self: *const Runtime) credentials.CatalogAccess {
        return credentials.catalogAccessFor(self.credentialSource());
    }

    pub fn credentialFailure(self: *const Runtime) ?credentials.LoadFailure {
        return self.failure;
    }

    pub fn recordCredentialFailure(self: *Runtime, failure: ?credentials.LoadFailure) void {
        self.failure = failure;
    }

    /// Takes ownership of `credential`, replacing the one held.
    pub fn adoptCredential(self: *Runtime, alloc: Allocator, credential: credentials.Credential) void {
        if (self.credential) |*held| held.deinit(alloc);
        self.credential = credential;
        self.failure = null;
    }

    pub fn clearCredential(self: *Runtime, alloc: Allocator) void {
        if (self.credential) |*held| held.deinit(alloc);
        self.credential = null;
        self.loaded_for = .none;
    }

    /// Loads `provider`'s credential and holds it. A host-managed session keeps
    /// the host's authority.
    pub fn selectForProvider(self: *Runtime, alloc: Allocator, provider: model_provider.ProviderId) Allocator.Error!ProviderCredentialSelection {
        if (self.mode == .host_managed) return .unchanged;
        const prepared = prepareCredential(alloc, provider) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const failure: credentials.LoadFailure = .{ .source = .configured, .err = err };
            self.clearCredential(alloc);
            self.failure = failure;
            return .{ .failed = failure };
        };
        const credential = prepared orelse {
            self.clearCredential(alloc);
            return .missing;
        };
        self.adoptCredential(alloc, credential);
        self.loaded_for = provider;
        return .selected;
    }
};

/// A provider's refusal of the credential, without its detail.
pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason = .http_unauthorized,
    http_status: ?std.http.Status = null,

    pub const FailureReason = enum { http_unauthorized };

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{ .source = source orelse return null, .http_status = status };
    }

    /// The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{s} authentication failed", .{credentials.sourceLabel(self.source)});
        if (self.http_status) |status| try out.writer.print(" · HTTP {d}", .{@backingInt(status)});
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| try writer.print(",\"http_status\":{d}", .{@backingInt(status)});
        try writer.writeByte('}');
    }
};

/// `provider`'s credential, or null when it has none spark can read. The
/// caller owns the result.
pub fn prepareCredential(alloc: Allocator, provider: model_provider.ProviderId) !?credentials.Credential {
    const resolution = try credentials.resolveForProvider(alloc, provider);
    if (resolution.failure) |failure| {
        debug_trace.logf("auth", "provider credential unavailable source={t} err={s}", .{ failure.source, @errorName(failure.err) });
        return failure.err;
    }
    return resolution.credential;
}

/// One line saying why `provider` cannot answer yet.
pub fn missingCredentialText(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .none => credentials.missing_interactive_credential_message,
        .configured => "This provider's API key is unavailable. Check its settings and environment variable, or run /provider.",
    };
}
