//! The subscription plans Spark can sign in to: what each one is called, the
//! provider IDs its accounts use, and where its model requests go. Each plan
//! keeps its accounts' OAuth credentials in its own private folder in the
//! Spark profile; only the account's catalog snapshot is in settings.
const std = @import("std");

pub const Kind = enum {
    chatgpt,
    claude,
    antigravity,

    pub const all = [_]Kind{ .chatgpt, .claude, .antigravity };

    /// The prefix of the provider IDs of this plan's accounts.
    pub fn idPrefix(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "chatgpt-plan-",
            .claude => "claude-plan-",
            .antigravity => "antigravity-plan-",
        };
    }

    /// The `auth.type` of the account's connection in settings.
    pub fn authType(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "chatgpt-plan",
            .claude => "claude-plan",
            .antigravity => "antigravity-plan",
        };
    }

    /// The private folder in the Spark profile that holds the plan's accounts.
    pub fn storeName(self: Kind) []const u8 {
        return self.authType();
    }

    /// What the plan's accounts are called in pickers: `Claude (Work)`.
    pub fn product(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "Codex",
            .claude => "Claude",
            .antigravity => "Antigravity",
        };
    }

    /// The service the person signs in to.
    pub fn service(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "ChatGPT",
            .claude => "Claude",
            .antigravity => "Google",
        };
    }

    /// The base URL the account's connection is saved with.
    pub fn baseUrl(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "https://api.openai.com/v1",
            .claude => "https://api.anthropic.com/v1",
            .antigravity => "https://daily-cloudcode-pa.googleapis.com",
        };
    }

    /// The protocol name of the account's connection.
    pub fn protocolName(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "openai-responses",
            .claude => "anthropic-messages",
            .antigravity => "gemini-code-assist",
        };
    }

    /// Where the person reviews the plan's usage.
    pub fn usageUrl(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "https://chatgpt.com/settings/usage",
            .claude => "https://claude.ai/settings/usage",
            .antigravity => "https://antigravity.google/",
        };
    }

    /// The command-line word for the plan: `spark provider claude-account`.
    pub fn accountCommand(self: Kind) []const u8 {
        return switch (self) {
            .chatgpt => "chatgpt-account",
            .claude => "claude-account",
            .antigravity => "antigravity-account",
        };
    }

    pub fn fromAuthType(name: []const u8) ?Kind {
        for (all) |kind| if (std.mem.eql(u8, kind.authType(), name)) return kind;
        return null;
    }

    pub fn fromAccountCommand(name: []const u8) ?Kind {
        for (all) |kind| if (std.mem.eql(u8, kind.accountCommand(), name)) return kind;
        return null;
    }

    /// An account ID of this plan: its prefix and 32 lowercase hex digits.
    pub fn isId(self: Kind, id: []const u8) bool {
        const prefix = self.idPrefix();
        if (!std.mem.startsWith(u8, id, prefix) or id.len != prefix.len + 32) return false;
        for (id[prefix.len..]) |c| if (std.mem.findScalar(u8, "0123456789abcdef", c) == null) return false;
        return true;
    }

    /// The plan an ID is reserved for, by its prefix alone.
    pub fn reserving(id: []const u8) ?Kind {
        for (all) |kind| if (std.mem.startsWith(u8, id, kind.idPrefix())) return kind;
        return null;
    }

    pub fn ofId(id: []const u8) ?Kind {
        const kind = reserving(id) orelse return null;
        return if (kind.isId(id)) kind else null;
    }
};

test "plan IDs belong to one plan by prefix and shape" {
    try std.testing.expectEqual(Kind.claude, Kind.ofId("claude-plan-0123456789abcdef0123456789abcdef").?);
    try std.testing.expectEqual(Kind.antigravity, Kind.ofId("antigravity-plan-0123456789abcdef0123456789abcdef").?);
    try std.testing.expect(Kind.ofId("claude-plan-0123") == null);
    try std.testing.expectEqual(Kind.claude, Kind.reserving("claude-plan-x").?);
    try std.testing.expect(Kind.reserving("claude") == null);
    try std.testing.expectEqual(Kind.antigravity, Kind.fromAccountCommand("antigravity-account").?);
}
