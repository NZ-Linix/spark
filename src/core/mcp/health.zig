//! What spark knows of a configured MCP server: its config, as `spark status`
//! and `spark doctor` inspect it, and the status the model catalog gives it.

const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");

const Allocator = std.mem.Allocator;

pub const ConnectionState = enum {
    disconnected,
    disabled,
    connecting,
    ready,
    failed,
};

pub const AuthenticationState = enum {
    none,
    configured,
    authenticated,
    required,
};

/// The single status of a configured server, from its connection and
/// authentication.
pub const Status = enum {
    disabled,
    connecting,
    ready,
    needs_auth,
    failed,
    unavailable,
    on_demand,
};

/// Classifies one server from its connection and authentication axes.
/// Precedence is deliberate: a disabled server needs enabling, not auth;
/// a server with a pending auth challenge needs auth regardless of how the
/// connection attempt ended; only then does the connection axis apply.
pub fn classify(
    connection: ConnectionState,
    authentication: AuthenticationState,
    deferred: bool,
) Status {
    if (connection == .disabled) return .disabled;
    if (authentication == .required) return .needs_auth;
    return switch (connection) {
        .disabled => unreachable,
        .connecting => .connecting,
        .ready => .ready,
        .failed => .failed,
        .disconnected => if (deferred) .on_demand else .unavailable,
    };
}

pub const ConfigurationIssue = struct {
    message: []u8,

    pub fn deinit(self: *ConfigurationIssue, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const ConfiguredServerSnapshot = struct {
    configured_name: []u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
    required: bool,
    transport: mcp_contract.McpTransport,

    pub fn deinit(self: *ConfiguredServerSnapshot, alloc: Allocator) void {
        alloc.free(self.configured_name);
        self.* = undefined;
    }
};

pub const LocalConfigSnapshot = struct {
    servers: []ConfiguredServerSnapshot,
    configuration_issues: []ConfigurationIssue,

    pub fn deinit(self: *LocalConfigSnapshot, alloc: Allocator) void {
        for (self.servers) |*server| server.deinit(alloc);
        alloc.free(self.servers);
        for (self.configuration_issues) |*issue| issue.deinit(alloc);
        alloc.free(self.configuration_issues);
        self.* = undefined;
    }
};

pub const LocalConfigInspection = struct {
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear,
    snapshot: LocalConfigSnapshot,
    inspection_error: ?[]const u8 = null,

    pub fn deinit(self: *LocalConfigInspection, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub const InspectLocalConfigFn = *const fn (
    Allocator,
    []const u8,
) error{OutOfMemory}!LocalConfigInspection;

pub fn inspectLocalConfigUnavailable(
    alloc: Allocator,
    _: []const u8,
) error{OutOfMemory}!LocalConfigInspection {
    const servers = try alloc.alloc(ConfiguredServerSnapshot, 0);
    errdefer alloc.free(servers);
    return .{ .snapshot = .{
        .servers = servers,
        .configuration_issues = try alloc.alloc(ConfigurationIssue, 0),
    } };
}
