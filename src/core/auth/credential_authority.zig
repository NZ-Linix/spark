const std = @import("std");
const types = @import("../shared/types.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Identity = struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Derives a persistable, non-secret identity from the credential slot.
pub fn derive(
    source: types.CredentialSource,
    account_id: ?[]const u8,
) ?Identity {
    _ = account_id;
    var hash = Sha256.init(.{});
    hash.update("spark-credential-authority-v1\x00");
    hash.update(@tagName(source));
    hash.update("\x00slot\x00");
    var bytes: [Sha256.digest_length]u8 = undefined;
    hash.final(&bytes);
    return .{ .bytes = bytes };
}
