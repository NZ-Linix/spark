const std = @import("std");
const types = @import("../shared/types.zig");

const configured_provider = @import("configured_provider.zig");

pub const ProviderId = union(enum) {
    /// No provider chosen yet: nothing can answer until one is added with /provider.
    none,
    configured: struct {
        bytes: [configured_provider.max_id_bytes]u8 = @splat(0),
        len: u8,
        binding: ?[32]u8 = null,
    },

    /// Borrows the inline name.
    pub fn label(self: *const ProviderId) []const u8 {
        return switch (self.*) {
            .none => "none",
            .configured => |*value| value.bytes[0..value.len],
        };
    }

    pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ProviderId {
        const value = try std.json.innerParse(std.json.Value, alloc, source, options);
        return parse_saved(value) catch return error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !ProviderId {
        return parse_saved(value) catch return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: ProviderId, writer: anytype) !void {
        if (self == .configured) {
            const binding = self.configured.binding orelse return error.WriteFailed;
            const encoded = std.fmt.bytesToHex(binding, .lower);
            try writer.write(.{ .name = self.label(), .binding = encoded[0..] });
        } else try writer.write(self.label());
    }

    pub fn eql(self: ProviderId, other: ProviderId) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        if (self != .configured) return true;
        return std.mem.eql(
            u8,
            self.configured.bytes[0..self.configured.len],
            other.configured.bytes[0..other.configured.len],
        );
    }

    /// A name from a flag or settings that has no definition is unknown; a
    /// saved session's bound name whose definition is gone was removed.
    pub fn bind(self: ProviderId, registry: configured_provider.Registry) error{ UnknownConfiguredProvider, ConfiguredProviderChanged, ConfiguredProviderRemoved }!ProviderId {
        if (self != .configured) return self;
        const definition = registry.get(self.label()) orelse
            return if (self.configured.binding != null) error.ConfiguredProviderRemoved else error.UnknownConfiguredProvider;
        const binding = definition.binding_identity();
        if (self.configured.binding) |expected| {
            if (!std.mem.eql(u8, &binding, &expected)) return error.ConfiguredProviderChanged;
        }
        var bound = self;
        bound.configured.binding = binding;
        return bound;
    }

    pub fn same_authority(self: ProviderId, other: ProviderId) bool {
        if (!self.eql(other)) return false;
        if (self != .configured) return true;
        const first = self.configured.binding orelse return false;
        const second = other.configured.binding orelse return false;
        return std.mem.eql(u8, &first, &second);
    }
};

/// Name-only key for provider-keyed stores whose lookups never inspect
/// binding identity. Narrower than ProviderId so bounded maps copy less.
pub const NameKey = struct {
    bytes: [configured_provider.max_id_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn fromProvider(provider: ProviderId) NameKey {
        var key: NameKey = .{};
        const name = provider.label();
        key.len = @intCast(name.len);
        @memcpy(key.bytes[0..name.len], name);
        return key;
    }

    pub fn label(self: *const NameKey) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eqlName(self: *const NameKey, name: []const u8) bool {
        return self.len == name.len and std.mem.eql(u8, self.bytes[0..self.len], name);
    }

    pub fn eqlProvider(self: *const NameKey, provider: ProviderId) bool {
        return self.eqlName(provider.label());
    }
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

/// Names spark's removed built-in providers had. A saved session or setting that
/// names one reads as `none`, so it still opens and asks for a provider.
const removed_builtins = [_][]const u8{ "gateway", "vercel", "codex", "grok" };

pub fn isRemovedBuiltin(value: []const u8) bool {
    return removedBuiltin(value);
}

fn removedBuiltin(value: []const u8) bool {
    for (removed_builtins) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

pub fn parse(value: []const u8) ?ProviderId {
    if (removedBuiltin(value) or std.ascii.eqlIgnoreCase(value, "none")) return null;
    configured_provider.validate_id(value) catch return null;
    var result: ProviderId = .{ .configured = .{ .len = @intCast(value.len) } };
    @memcpy(result.configured.bytes[0..value.len], value);
    return result;
}

pub fn parse_saved(value: std.json.Value) error{InvalidProviderBinding}!ProviderId {
    if (value == .string) {
        if (removedBuiltin(value.string) or std.mem.eql(u8, value.string, "none")) return .none;
        return error.InvalidProviderBinding;
    }
    if (value != .object or value.object.count() != 2) return error.InvalidProviderBinding;
    const name = value.object.get("name") orelse return error.InvalidProviderBinding;
    const encoded = value.object.get("binding") orelse return error.InvalidProviderBinding;
    if (name != .string or encoded != .string or encoded.string.len != 64) return error.InvalidProviderBinding;
    var provider = parse(name.string) orelse return error.InvalidProviderBinding;
    var binding: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&binding, encoded.string) catch return error.InvalidProviderBinding;
    provider.configured.binding = binding;
    return provider;
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    if (selected == .host_managed) return true;
    return switch (provider) {
        .none => false,
        .configured => selected == .configured,
    };
}
