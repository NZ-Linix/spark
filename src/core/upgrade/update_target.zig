const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_manifest_bytes: usize = 4096;
pub const max_version_bytes: usize = 32;
pub const max_revision_bytes: usize = 64;
const min_revision_bytes: usize = 7;

pub const Channel = enum {
    stable,
    dev,

    pub fn parse(raw: []const u8) ?Channel {
        if (std.ascii.eqlIgnoreCase(raw, "stable")) return .stable;
        if (std.ascii.eqlIgnoreCase(raw, "dev")) return .dev;
        return null;
    }

    pub fn label(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const CurrentBuild = struct {
    channel: Channel,
    version: []const u8,
    revision: []const u8,
};

pub const Target = union(Channel) {
    stable: Stable,
    dev: Dev,

    pub const Stable = struct {
        version: []u8,
        artifact_ref: []u8,
    };

    pub const Dev = struct {
        version: []u8,
        revision: []u8,
        artifact_ref: []u8,
    };

    pub fn initStable(alloc: Allocator, raw_version: []const u8) !Target {
        const trimmed = std.mem.trim(u8, raw_version, " \t\r\n");
        const normalized_version = normalizeVersion(trimmed);
        if (!isValidVersion(normalized_version)) return error.InvalidVersion;

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const artifact_ref = try alloc.dupe(u8, trimmed);
        return .{ .stable = .{
            .version = owned_version,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn parseDevManifest(alloc: Allocator, bytes: []const u8) !Target {
        if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
            return error.InvalidManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidManifest;

        const version_value = parsed.value.object.get("version") orelse
            return error.InvalidManifest;
        const revision_value = parsed.value.object.get("commit") orelse
            return error.InvalidManifest;
        if (version_value != .string or revision_value != .string) {
            return error.InvalidManifest;
        }

        const normalized_version = normalizeVersion(version_value.string);
        const manifest_revision = revision_value.string;
        if (!isValidVersion(normalized_version) or !isValidRevision(manifest_revision)) {
            return error.InvalidManifest;
        }

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const owned_revision = try alloc.dupe(u8, manifest_revision);
        errdefer alloc.free(owned_revision);
        const artifact_ref = try alloc.print("dev/{s}", .{manifest_revision});
        return .{ .dev = .{
            .version = owned_version,
            .revision = owned_revision,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn deinit(self: *Target, alloc: Allocator) void {
        switch (self.*) {
            .stable => |stable| {
                alloc.free(stable.version);
                alloc.free(stable.artifact_ref);
            },
            .dev => |dev| {
                alloc.free(dev.version);
                alloc.free(dev.revision);
                alloc.free(dev.artifact_ref);
            },
        }
        self.* = undefined;
    }

    pub fn channel(self: Target) Channel {
        return std.meta.activeTag(self);
    }

    pub fn version(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.version,
            .dev => |dev| dev.version,
        };
    }

    pub fn revision(self: Target) ?[]const u8 {
        return switch (self) {
            .stable => null,
            .dev => |dev| dev.revision,
        };
    }

    pub fn artifactRef(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.artifact_ref,
            .dev => |dev| dev.artifact_ref,
        };
    }

    pub fn shouldInstall(self: Target, current: CurrentBuild) bool {
        if (self.channel() != current.channel) return true;
        return switch (self) {
            .stable => |stable| compareVersions(stable.version, current.version) == .gt,
            .dev => |dev| !revisionsEqual(dev.revision, current.revision),
        };
    }

    pub fn writeDisplayLabel(self: Target, out: []u8) ![]const u8 {
        return switch (self) {
            .stable => |stable| std.mem.print(out, "{s}", .{stable.version}),
            .dev => |dev| std.mem.print(out, "dev {s}", .{shortRevision(dev.revision)}),
        };
    }
};

pub fn normalizeVersion(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == 'v') return raw[1..];
    return raw;
}

pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const av = parseVersionParts(a);
    const bv = parseVersionParts(b);
    for (av, bv) |x, y| if (x != y) return std.math.order(x, y);
    return .eq;
}

/// A stable version: major, minor, and patch, plus an optional fourth part
/// for a second release on the same day, such as `26.11.21.1`.
pub fn isValidVersion(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > max_version_bytes) return false;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, raw, '.');
    while (parts.next()) |part| {
        if (count == 4 or part.len == 0) return false;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return false;
        _ = std.fmt.parseUnsigned(u32, part, 10) catch return false;
        count += 1;
    }
    return count >= 3;
}

pub fn isValidRevision(raw: []const u8) bool {
    if (raw.len < min_revision_bytes or raw.len > max_revision_bytes) return false;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Major, minor, patch, and the optional fourth part, which is 0 when absent.
/// A suffix such as `-d` or `+build` is ignored, so a local `26.11.19-d`
/// build counts as release 26.11.19.
fn parseVersionParts(raw: []const u8) [4]u32 {
    var values = [_]u32{ 0, 0, 0, 0 };
    const normalized = normalizeVersion(raw);
    const core = normalized[0 .. std.mem.findAny(u8, normalized, "-+") orelse normalized.len];
    var parts = std.mem.splitScalar(u8, core, '.');
    for (&values) |*value| {
        const part = parts.next() orelse break;
        value.* = std.fmt.parseUnsigned(u32, part, 10) catch 0;
    }
    return values;
}

pub fn revisionsEqual(full: []const u8, current: []const u8) bool {
    if (std.mem.eql(u8, current, "unknown")) return false;
    const common_len = @min(full.len, current.len);
    if (common_len < min_revision_bytes) return false;
    return std.ascii.eqlIgnoreCase(full[0..common_len], current[0..common_len]);
}

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

test "a fourth version part orders a second release after the first" {
    try std.testing.expect(isValidVersion("26.11.21"));
    try std.testing.expect(isValidVersion("26.11.21.1"));
    try std.testing.expect(!isValidVersion("26.11"));
    try std.testing.expect(!isValidVersion("26.11.21.1.2"));
    try std.testing.expect(!isValidVersion("26.11.21."));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("26.11.21.1", "26.11.21"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("v26.11.21.2", "26.11.21.1-d"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("26.11.21.1", "26.11.22"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("26.11.21.0", "26.11.21"));
}

test "channel parsing accepts only stable and dev" {
    try std.testing.expectEqual(Channel.stable, Channel.parse("stable").?);
    try std.testing.expectEqual(Channel.dev, Channel.parse("DEV").?);
    try std.testing.expect(Channel.parse("nightly") == null);
}
