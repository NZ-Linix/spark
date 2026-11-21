//! The flags that shape an agent run, one set for every command that runs the
//! agent: `spark ask`, `spark pr`, `spark issue`, and `spark acp`. Each command documents
//! them in `src/builtins/commands.zig` and parses them here, so a flag means
//! the same thing everywhere.

const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Flag = enum {
    permission_mode,
    full_access,
    yolo,
    provider,
    model,
    effort,
    fast,
    no_fast,
    ultrafast,
    no_ultrafast,
};

/// The shared flag a command's own flag id names, or null for a flag only
/// that command has. Command flag enums use the same field names.
pub fn fromId(id: anytype) ?Flag {
    return std.meta.stringToEnum(Flag, @tagName(id));
}

pub const Overrides = struct {
    permission: ?types.PermissionMode = null,
    provider: ?model_provider.ProviderId = null,
    /// Owned.
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast: ?bool = null,
    ultrafast: ?bool = null,

    pub fn deinit(self: *Overrides, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        self.* = .{};
    }

    /// Applies one flag; a later flag replaces an earlier one. `value` is the
    /// flag's argument, or empty for a switch. Fails with
    /// `InvalidAgentRunValue` for a value the flag can't take.
    pub fn apply(self: *Overrides, alloc: Allocator, flag: Flag, value: []const u8) !void {
        switch (flag) {
            .permission_mode => self.permission = types.PermissionMode.parse(value) orelse return error.InvalidAgentRunValue,
            .full_access, .yolo => self.permission = .yolo,
            .provider => self.provider = model_provider.parse(value) orelse return error.InvalidAgentRunValue,
            .model => {
                const model = std.mem.trim(u8, value, " \t\r\n");
                if (model.len == 0) return error.InvalidAgentRunValue;
                const owned = try alloc.dupe(u8, model);
                if (self.model) |old| alloc.free(old);
                self.model = owned;
            },
            .effort => self.effort = types.ReasoningEffort.parse(value) orelse return error.InvalidAgentRunValue,
            // Fast and Ultra are separate service tiers, so asking for one
            // turns the other off.
            .fast => {
                self.fast = true;
                self.ultrafast = false;
            },
            .no_fast => self.fast = false,
            .ultrafast => {
                self.ultrafast = true;
                self.fast = false;
            },
            .no_ultrafast => self.ultrafast = false,
        }
    }
};
