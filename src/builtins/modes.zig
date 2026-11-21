const std = @import("std");

const builtin_tools = @import("tools.zig");
const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const ToolPolicy = mode_contract.ToolPolicy;
pub const default_mode_id = "full-access";

/// The only mode. ACP lists it so clients see what spark runs with.
pub const all = [_]ModeSpec{
    .{ .id = "full-access", .name = "Full access", .description = "Run every action without spark permission checks", .permission_mode = .yolo },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}
