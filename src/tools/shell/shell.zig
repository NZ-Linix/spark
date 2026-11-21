const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const builtin = @import("builtin");
const command_admission = @import("../../core/permissions/command_admission.zig");
const command_contract = @import("../../core/execution/command_contract.zig");
const command_environment = @import("../../core/execution/command_environment.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const managed_contract = @import("../../core/execution/managed_execution_contract.zig");
const mcp_call_bridge = @import("../../core/mcp_host/mcp_call_bridge.zig");
const io_mod = @import("../../core/shared/io.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const terminal_identity = @import("../../core/terminal/identity.zig");
const terminal_action_executor = @import("../../core/terminal/action_executor.zig");
const terminal_managed_observer = @import("../../core/terminal/managed_observer.zig");
const terminal_operation = @import("../../core/terminal/operation.zig");
const terminal_store = @import("../../core/terminal/store.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");
const shell_snapshot = @import("../../core/terminal/shell_snapshot.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const terminal_contracts = @import("../../core/terminal/contracts.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const result_commit = @import("../../core/tooling/result_commit.zig");
const result_store = @import("../../core/session/result_store.zig");
const types = @import("../../core/shared/types.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum {
    run,
    interact,
    stop,
};

const ShellKind = enum { executable };

pub const ShellInput = struct {
    kind: ShellKind,
    path: []const u8,
    clean_start: bool = false,
};

pub const Input = struct {
    action: Action,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    profile: ?command_environment.Profile = null,
    shell: ?ShellInput = null,
    tty: bool = false,
    yield_time_ms: u32 = managed_contract.default_yield_time_ms,
    timeout_ms: ?u64 = null,
    reload: bool = false,
    session_id: ?[]const u8 = null,
    chars: ?[]const u8 = null,
    force: bool = false,
};

pub const public_field_names = blk: {
    const field_names = @typeInfo(Input).@"struct".field_names;
    var names: [field_names.len][]const u8 = undefined;
    for (field_names, 0..) |field_name, index| names[index] = field_name;
    break :blk names;
};

pub const ActionFieldContract = struct {
    allowed: []const []const u8,
    required: []const []const u8,
    conflicts: []const tool_result_errors.TerminalActionFieldConflict = &.{},
};

pub fn actionFieldContract(action: Action) ActionFieldContract {
    return switch (action) {
        .run => .{
            .allowed = &.{ "action", "command", "cwd", "profile", "shell", "tty", "yield_time_ms", "timeout_ms", "reload" },
            .required = &.{ "action", "command" },
            .conflicts = &.{.{ "profile", "shell" }},
        },
        .interact => .{
            .allowed = &.{ "action", "session_id", "chars", "yield_time_ms" },
            .required = &.{ "action", "session_id" },
        },
        .stop => .{
            .allowed = &.{ "action", "session_id", "force" },
            .required = &.{ "action", "session_id" },
        },
    };
}

/// Names the action of a call that omits `action` when exactly one action
/// takes every field it sends and gets every field it requires. Fields that
/// decode treats as absent, null or the text "null", are ignored. When no
/// action fits, a second pass also ignores known fields set to an empty
/// value that the action does not take, which decode drops for that action;
/// a call that fits today keeps its action. A bare session_id fits both
/// interact and stop, so it names neither. The orchestrator adds the result
/// before the call is stored or admitted, so permission admission and decode
/// read the same arguments
/// (`tests/tla/shell_command/ShellContract.tla` AdmissionConsistency).
pub fn inferAction(object: std.json.ObjectMap) ?[]const u8 {
    if (object.get("action") != null) return null;
    return switch (fittingAction(object, .counted)) {
        .one => |action| @tagName(action),
        .several => null,
        .none => switch (fittingAction(object, .ignored_outside_action)) {
            .one => |action| @tagName(action),
            .several, .none => null,
        },
    };
}

const Fit = union(enum) { none, one: Action, several };

/// Whether an empty field the action does not take stops the action from
/// fitting (`counted`) or is skipped as decode would drop it.
const EmptyFields = enum { counted, ignored_outside_action };

fn fittingAction(object: std.json.ObjectMap, empty_fields: EmptyFields) Fit {
    var found: ?Action = null;
    for (std.enums.values(Action)) |action| {
        if (!fieldsFitAction(object, actionFieldContract(action), empty_fields)) continue;
        if (found != null) return .several;
        found = action;
    }
    return if (found) |action| .{ .one = action } else .none;
}

fn fieldsFitAction(object: std.json.ObjectMap, contract: ActionFieldContract, empty_fields: EmptyFields) bool {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (isAbsentValue(entry.value_ptr.*)) continue;
        if (containsFieldName(contract.allowed, entry.key_ptr.*)) continue;
        if (empty_fields == .ignored_outside_action and isDroppableOutsideAction(entry.key_ptr.*, entry.value_ptr.*)) continue;
        return false;
    }
    for (contract.required) |name| {
        if (std.mem.eql(u8, name, "action")) continue;
        const value = object.get(name) orelse return false;
        if (isAbsentValue(value)) return false;
    }
    return true;
}

fn isAbsentValue(value: std.json.Value) bool {
    return value == .null or
        (value == .string and tool_args.isNullPlaceholderText(value.string));
}

/// A known shell field with an empty value (`tool_args.isEmptyArgumentValue`)
/// means the same as leaving it out for an action that does not take it.
/// Unknown names still reach the field check, since they can carry intent
/// that dropping would lose.
fn isDroppableOutsideAction(name: []const u8, value: std.json.Value) bool {
    return containsFieldName(public_field_names[1..], name) and tool_args.isEmptyArgumentValue(value);
}

/// A run without a terminal uses the login shell and `profile`, which is
/// also what permission admission checks, and `shell` applies only with
/// tty=true. Some models send a `shell` that names the login shell anyway,
/// often beside `profile`; that `shell` changes nothing, so it is dropped
/// rather than rejected or reported as a conflict. It stays when it names
/// another shell, or when its clean_start asks for a clean start that
/// `profile` does not, since running then would not do what was asked.
fn elideLoginShellOnPlainRun(object: *std.json.ObjectMap, action: Action, login_shell: ?[]const u8) void {
    if (action != .run) return;
    const login = login_shell orelse return;
    if (object.get("tty")) |tty| if (tty != .bool or tty.bool) return;
    const profile: ?[]const u8 = if (object.get("profile")) |value| switch (value) {
        .string => |text| text,
        else => return,
    } else null;
    const shell = object.get("shell") orelse return;
    if (shell != .object) return;
    const kind = shell.object.get("kind") orelse return;
    const path = shell.object.get("path") orelse return;
    if (kind != .string or !std.mem.eql(u8, kind.string, "executable")) return;
    if (path != .string or !std.mem.eql(u8, path.string, login)) return;
    for (shell.object.keys()) |member| {
        if (!std.mem.eql(u8, member, "kind") and !std.mem.eql(u8, member, "path") and !std.mem.eql(u8, member, "clean_start")) return;
    }
    if (shell.object.get("clean_start")) |clean_start| {
        if (clean_start != .bool) return;
        if (clean_start.bool and !std.mem.eql(u8, profile orelse "user", "clean")) return;
    }
    debug_trace.logf(
        "shell",
        "run without tty ignored shell field: it names the login shell path=\"{f}\"",
        .{std.zig.fmtString(login)},
    );
    _ = object.orderedRemove("shell");
}

/// Drops the empty fields `isDroppableOutsideAction` describes for `action`.
fn elideEmptyFieldsOutsideAction(object: *std.json.ObjectMap, action: Action) void {
    const allowed = actionFieldContract(action).allowed;
    for (public_field_names[1..]) |field_name| {
        if (containsFieldName(allowed, field_name)) continue;
        const value = object.get(field_name) orelse continue;
        if (isDroppableOutsideAction(field_name, value)) _ = object.orderedRemove(field_name);
    }
}

fn containsFieldName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "inferAction names the one action a call's fields fit" {
    const cases = [_]struct { args: []const u8, action: ?[]const u8 }{
        .{ .args = "{\"command\":\"git status\"}", .action = "run" },
        .{ .args = "{\"command\":\"make\",\"cwd\":\"src\",\"yield_time_ms\":30000,\"timeout_ms\":600000}", .action = "run" },
        .{ .args = "{\"command\":\"python3\",\"tty\":true,\"session_id\":null,\"chars\":\"null\"}", .action = "run" },
        .{ .args = "{\"session_id\":\"shell-1\",\"chars\":\"y\\n\"}", .action = "interact" },
        .{ .args = "{\"session_id\":\"shell-1\",\"yield_time_ms\":5000}", .action = "interact" },
        .{ .args = "{\"session_id\":\"shell-1\",\"force\":true}", .action = "stop" },
        // Empty fields that only another action takes ask for nothing.
        .{ .args = "{\"command\":\"ls\",\"chars\":\"\",\"session_id\":\"\",\"force\":false,\"reload\":false}", .action = "run" },
        // A call that fits under the strict pass keeps that action.
        .{ .args = "{\"session_id\":\"shell-1\",\"chars\":\"\"}", .action = "interact" },
        .{ .args = "{\"session_id\":\"shell-1\",\"force\":false}", .action = "stop" },
        // Ignoring an empty command still leaves session_id fitting two actions.
        .{ .args = "{\"session_id\":\"shell-1\",\"command\":\"\"}", .action = null },
        // Unknown names and set values are never dropped.
        .{ .args = "{\"command\":\"ls\",\"note\":\"\"}", .action = null },
        .{ .args = "{\"command\":\"ls\",\"chars\":\"y\"}", .action = null },
        // A bare session_id could observe or stop the session.
        .{ .args = "{\"session_id\":\"shell-1\"}", .action = null },
        // A command beside a session could start one or write to one.
        .{ .args = "{\"command\":\"ls\",\"session_id\":\"shell-1\"}", .action = null },
        .{ .args = "{\"command\":\"ls\",\"force\":true}", .action = null },
        .{ .args = "{\"command\":\"ls\",\"note\":\"why\"}", .action = null },
        .{ .args = "{\"command\":null}", .action = null },
        .{ .args = "{}", .action = null },
        .{ .args = "{\"action\":\"run\",\"command\":\"ls\"}", .action = null },
        .{ .args = "{\"action\":null,\"command\":\"ls\"}", .action = null },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.args, .{});
        defer parsed.deinit();
        const inferred = inferAction(parsed.value.object);
        if (case.action) |expected| {
            try std.testing.expectEqualStrings(expected, inferred orelse return error.TestExpectedEqual);
        } else if (inferred) |unexpected| {
            std.debug.print("{s} inferred {s}\n", .{ case.args, unexpected });
            return error.TestUnexpectedResult;
        }
    }
}

const OwnedInput = struct {
    arena_state: std.heap.ArenaAllocator.State,
    value: Input,

    fn deinit(self: *OwnedInput, alloc: Allocator) void {
        self.arena_state.promote(alloc).deinit();
        self.* = undefined;
    }
};

/// Decodes one shell call's arguments. How each argument shape is decoded,
/// admitted, and shown in history is modeled in
/// `tests/tla/shell_command/ShellContract.tla`.
pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (try decode_input(ctx, args_json)) |input| return .{ .input = input };
    return .{ .failure = try request_correction(ctx.allocator, args_json, ctx.session_child_capability != null) };
}

fn decode_input(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!?tool_dispatch.ToolInput {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    var raw = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        args_json,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (raw != .object) return null;
    const raw_action = raw.object.get("action") orelse return null;
    if (raw_action != .string) return null;
    const action = std.meta.stringToEnum(Action, raw_action.string) orelse
        return null;
    elideKnownNullFields(&raw.object);
    elideEmptyFieldsOutsideAction(&raw.object, action);
    var login_shell_buffer: [4096]u8 = undefined;
    elideLoginShellOnPlainRun(&raw.object, action, shell_resolver.configuredLoginShellInto(&login_shell_buffer));

    var correction_scratch: ActionFieldCorrectionScratch = .{};
    defer correction_scratch.deinit(ctx.allocator);
    if (try actionFieldCorrection(
        ctx.allocator,
        action,
        raw.object,
        &correction_scratch,
    ) != null) return null;
    normalizeCompositeArgument(arena, &raw, "shell") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var input = std.json.parseFromValueLeaky(Input, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    input.yield_time_ms = if (raw.object.get("yield_time_ms") == null)
        defaultYieldTime(action)
    else
        boundedYieldTime(action, input.yield_time_ms);
    if (argument_problem(input) != null) return null;
    const owned = try ctx.allocator.create(OwnedInput);
    owned.* = .{
        .arena_state = arena_state.state,
        .value = input,
    };
    arena_state.state = .init;
    return .{
        .ptr = owned,
        .deinit_fn = inputDeinit,
    };
}

fn defaultYieldTime(action: Action) u32 {
    return switch (action) {
        .run => managed_contract.default_yield_time_ms,
        .interact => managed_contract.default_wait_ceiling_ms,
        .stop => 0,
    };
}

/// A wait longer than the action allows is shortened to its limit rather
/// than refused: the call still runs, and a command that is still going
/// returns its session_id for the next interact.
fn boundedYieldTime(action: Action, requested_ms: u32) u32 {
    return switch (action) {
        .run => @min(requested_ms, managed_contract.max_yield_time_ms),
        .interact => @min(requested_ms, managed_contract.max_wait_ceiling_ms),
        .stop => requested_ms,
    };
}

fn effective_interact_yield_time(has_input: bool, requested_ms: u32) u32 {
    if (!has_input) {
        return @min(
            @max(requested_ms, managed_contract.default_wait_ceiling_ms),
            managed_contract.max_wait_ceiling_ms,
        );
    }
    return @min(requested_ms, managed_contract.max_yield_time_ms);
}

// Advisory only: none of these values enters the executable decode path.
fn request_correction(alloc: Allocator, args_json: []const u8, supports_tty: bool) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    if (args_json.len > 16 * 1024) {
        return correction_json(alloc, &.{"Arguments are too large to suggest a repair; submit the intended action with only its required fields."}, null);
    }
    const raw = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return correction_json(alloc, &.{"Shell arguments must be a JSON object."}, null),
    };
    if (raw != .object or raw.object.count() > 32) {
        return correction_json(alloc, &.{"Shell arguments must be one bounded object."}, null);
    }

    var problems: std.ArrayList([]const u8) = .empty;
    var repairable = true;
    var object = raw.object;
    // Outside a required vision step the orchestrator unwraps an exact
    // {"request":{...}} before decode, so a wrapper here usually has extra
    // top-level fields or a string body. Either way, suggest the flat call.
    if (raw.object.get("request")) |wrapper| {
        try problems.append(arena, "Put the action fields at the top level; shell takes no request wrapper.");
        var request = wrapper;
        // A wrapper written as JSON text is read like intake reads it, with
        // the same depth limit.
        tool_args.normalizeCompositeObjectValue(arena, &request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return correction_json(alloc, problems.items, null),
        };
        if (request != .object or request.object.count() > 32) {
            return correction_json(alloc, problems.items, null);
        }
        object = request.object;
        var outer = raw.object.iterator();
        while (outer.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.eql(u8, name, "request")) continue;
            if (object.contains(name)) {
                repairable = false;
            } else {
                try object.put(arena, name, entry.value_ptr.*);
            }
        }
    }
    elideKnownNullFields(&object);
    const action_value = object.get("action");
    const action: Action = if (action_value) |value| blk: {
        if (value == .string) {
            if (std.meta.stringToEnum(Action, value.string)) |action| break :blk action;
        }
        try problems.append(arena, "action must be run, interact, or stop; put the shell command in command.");
        return correction_json(alloc, problems.items, null);
    } else blk: {
        try problems.append(arena, "action is required.");
        const command = object.get("command") orelse return correction_json(alloc, problems.items, null);
        if (command != .string or object.contains("session_id") or object.contains("chars") or object.contains("force")) {
            return correction_json(alloc, problems.items, null);
        }
        try object.put(arena, "action", .{ .string = "run" });
        break :blk .run;
    };
    elideEmptyFieldsOutsideAction(&object, action);
    var login_shell_buffer: [4096]u8 = undefined;
    elideLoginShellOnPlainRun(&object, action, shell_resolver.configuredLoginShellInto(&login_shell_buffer));

    var scratch: ActionFieldCorrectionScratch = .{};
    if (try actionFieldCorrection(arena, action, object, &scratch)) |correction| {
        for (correction.invalid_fields) |name| {
            try problems.append(arena, try arena.print(
                "{s} is not accepted for {s}.",
                .{ text_utils.utf8PrefixByBytes(name, 64), @tagName(action) },
            ));
            // A non-null unknown field can express intent that cannot be reconstructed.
            if (object.get(name).? != .null) repairable = false;
            _ = object.orderedRemove(name);
        }
        for (correction.missing_fields) |name| {
            try problems.append(arena, try arena.print("{s} is required for {s}.", .{ name, @tagName(action) }));
            repairable = false;
        }
        for (correction.conflicts) |conflict| {
            try problems.append(arena, try arena.print("Choose either {s} or {s}.", .{ conflict[0], conflict[1] }));
            repairable = false;
        }
    }

    var canonical: std.json.ObjectMap = .empty;
    const input_info = @typeInfo(Input).@"struct";
    inline for (input_info.field_names, input_info.field_types) |field_name, field_type| {
        if (object.get(field_name)) |original| {
            var value = original;
            const T = if (@typeInfo(field_type) == .optional) @typeInfo(field_type).optional.child else field_type;
            const expected = comptime switch (@typeInfo(T)) {
                .int => "an integer",
                .bool => "a boolean",
                .pointer => "a string",
                .@"enum" => "an advertised value",
                else => "an object matching its schema",
            };
            var type_reported = false;
            if (comptime @typeInfo(T) == .int) {
                if (value == .string) {
                    try problems.append(arena, field_name ++ " must be an integer.");
                    type_reported = true;
                    if (std.fmt.parseInt(T, value.string, 10)) |number| {
                        value = if (std.math.cast(i64, number)) |integer|
                            .{ .integer = integer }
                        else
                            .{ .number_string = try arena.print("{d}", .{number}) };
                    } else |_| {
                        repairable = false;
                    }
                }
            }
            if (std.json.parseFromValueLeaky(field_type, arena, value, .{})) |_| {
                if (comptime T == ShellInput) {
                    var shell: std.json.ObjectMap = .empty;
                    inline for (@typeInfo(ShellInput).@"struct".field_names) |member_name| {
                        if (value.object.get(member_name)) |supplied| {
                            try shell.put(arena, member_name, supplied);
                        }
                    }
                    value = .{ .object = shell };
                }
            } else |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (!type_reported) try problems.append(arena, field_name ++ " must be " ++ expected ++ ".");
                repairable = false;
            }
            try canonical.put(arena, field_name, value);
        }
    }
    var candidate = std.json.parseFromValueLeaky(Input, arena, .{ .object = canonical }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return correction_json(alloc, problems.items, null),
    };
    candidate.yield_time_ms = boundedYieldTime(candidate.action, candidate.yield_time_ms);
    if (argument_problem(candidate)) |problem| {
        try problems.append(arena, problem);
        repairable = false;
    }
    if (!supports_tty and (canonical.contains("tty") or canonical.contains("shell") or canonical.contains("chars"))) {
        try problems.append(arena, "Interactive Shell fields require a saved session.");
        repairable = false;
    }
    if (problems.items.len == 0) {
        try problems.append(arena, "Submit one Shell action.");
    }
    return correction_json(alloc, problems.items, if (repairable) canonical else null);
}

fn correction_json(
    alloc: Allocator,
    problems: []const []const u8,
    candidate: ?std.json.ObjectMap,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(.{ .@"error" = .{
        .code = "invalid_shell_request",
        .executed = false,
        .problems = problems,
        .instruction = if (candidate != null) @as(?[]const u8, "Call shell once using retry_with exactly.") else null,
        .retry_with = if (candidate) |object| @as(?std.json.Value, .{ .object = object }) else null,
    } }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn argument_problem(input: Input) ?[]const u8 {
    switch (input.action) {
        .run => {
            const command = input.command orelse return "command is required for run.";
            if (command.len == 0 or command.len > terminal_contracts.max_command_bytes) return "command must contain 1-65536 bytes.";
            if (input.timeout_ms == 0) return "timeout_ms must be at least 1; choose the intended deadline.";
            if (input.profile != null and input.shell != null) return "Choose either profile or shell.";
            if (!input.tty and input.shell != null) return "shell applies only with tty=true; remove shell for an ordinary command, or set tty=true for an interactive terminal.";
        },
        .interact => {
            if (input.chars) |chars| {
                if (chars.len > terminal_contracts.max_write_bytes) return "chars exceed 65536 bytes.";
            }
        },
        .stop => {},
    }
    return null;
}

fn normalizeCompositeArgument(
    alloc: Allocator,
    root: *std.json.Value,
    field_name: []const u8,
) !void {
    const value = root.object.getPtr(field_name) orelse return;
    try tool_args.normalizeCompositeObjectValue(alloc, value);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *OwnedInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn elideKnownNullFields(object: *std.json.ObjectMap) void {
    for (public_field_names[1..]) |field_name| {
        const value = object.get(field_name) orelse continue;
        if (value == .null or
            (value == .string and tool_args.isNullPlaceholderText(value.string)))
        {
            _ = object.orderedRemove(field_name);
        }
    }
}

const ActionFieldCorrectionScratch = struct {
    invalid_fields: std.ArrayList([]const u8) = .empty,
    missing_fields: [public_field_names.len][]const u8 = undefined,
    conflicts: [public_field_names.len]tool_result_errors.TerminalActionFieldConflict = undefined,

    fn deinit(self: *ActionFieldCorrectionScratch, alloc: Allocator) void {
        self.invalid_fields.deinit(alloc);
        self.* = undefined;
    }
};

fn actionFieldCorrection(
    alloc: Allocator,
    action: Action,
    object: std.json.ObjectMap,
    scratch: *ActionFieldCorrectionScratch,
) Allocator.Error!?tool_result_errors.TerminalActionFieldCorrection {
    const field_contract = actionFieldContract(action);
    try scratch.invalid_fields.ensureTotalCapacity(alloc, object.count());
    var fields = object.iterator();
    while (fields.next()) |entry| {
        var allowed = false;
        for (field_contract.allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) scratch.invalid_fields.appendAssumeCapacity(entry.key_ptr.*);
    }
    sort_utils.sort(
        []const u8,
        scratch.invalid_fields.items,
        {},
        struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan,
    );
    var missing_count: usize = 0;
    for (field_contract.required) |name| {
        if (object.get(name) != null) continue;
        scratch.missing_fields[missing_count] = name;
        missing_count += 1;
    }
    var conflict_count: usize = 0;
    for (field_contract.conflicts) |conflict| {
        if (object.get(conflict[0]) == null or object.get(conflict[1]) == null) continue;
        scratch.conflicts[conflict_count] = conflict;
        conflict_count += 1;
    }
    if (scratch.invalid_fields.items.len == 0 and
        missing_count == 0 and
        conflict_count == 0)
    {
        return null;
    }
    return .{
        .action = @tagName(action),
        .invalid_fields = scratch.invalid_fields.items,
        .missing_fields = scratch.missing_fields[0..missing_count],
        .allowed_fields = field_contract.allowed,
        .conflicts = scratch.conflicts[0..conflict_count],
    };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(OwnedInput).value;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    return switch (input.action) {
        .run => validateRun(ctx, arena, input),
        .interact => validateInteract(ctx, input),
        .stop => null,
    };
}

fn validateInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    if (argument_problem(input)) |problem| return try ctx.allocator.dupe(u8, problem);
    return null;
}

fn validateRun(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    if (argument_problem(input)) |problem| return try ctx.allocator.dupe(u8, problem);
    _ = resolveCwd(arena, ctx, input.cwd) catch |err| {
        return try ctx.allocator.print(
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        );
    };
    if (!input.tty) {
        _ = commandEnvironment(arena, ctx, input.profile) catch |err| {
            return try ctx.allocator.print(
                "shell run profile is invalid: {s}",
                .{@errorName(err)},
            );
        };
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => callRun(ctx, input),
        .interact => callInteract(ctx, input),
        .stop => callStop(ctx, input),
    };
}

fn callRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (input.tty) {
        return callTtyRun(ctx, input);
    }
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const execution_authority = ctx.execution_authority orelse return unavailable(ctx);
    const authority = switch (execution_authority) {
        .run_command => |value| value,
        else => return unavailable(ctx),
    };
    const command = input.command orelse return unavailable(ctx);
    // Admission never lets a remembered grant authorize a reload, so the
    // command runs under the startup files its approval was given for.
    if (input.reload) shell_snapshot.processOwner().markDirty(.agent_reload);
    var request_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(request_arena_state);
    const request_arena = request_arena_state.allocator();
    const cwd = resolveCwd(request_arena, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try ctx.allocator.print(
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    const environment = commandEnvironment(
        request_arena,
        ctx,
        input.profile,
    ) catch |err| {
        return .{ .failure = try ctx.allocator.print(
            "shell run profile is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    var execution_id_buffer: [64]u8 = undefined;
    const execution_id = runtime.generatedId(&execution_id_buffer) catch |err|
        return runtimeFailure(ctx, err);
    // While this call runs, its command can reach the session's MCP tools
    // with `spark mcp call`, as this agent (`mcp_call_bridge.zig`).
    const bridge_registration: ?*mcp_call_bridge.Registration = if (comptime mcp_call_bridge.supported) registration: {
        const capability = ctx.mcp_call_capability orelse break :registration null;
        break :registration mcp_call_bridge.register(capability) catch |err| {
            debug_trace.logf("mcp-call", "shell call not registered with the bridge err={s}", .{@errorName(err)});
            break :registration null;
        };
    } else null;
    defer if (comptime mcp_call_bridge.supported) if (bridge_registration) |registration| mcp_call_bridge.unregister(registration);
    var prepared = runtime.startCaptured(ctx.allocator, .{
        .execution_id = execution_id,
        .command = command,
        .cwd = cwd,
        .environment = environment,
        .authority = authority,
        .extra_environment = if (bridge_registration) |registration| registration.environment() else &.{},
        .yield_hold = if (bridge_registration) |registration| &registration.hold else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .timeout_ms = if (input.timeout_ms) |value|
            std.math.cast(usize, value) orelse return unavailable(ctx)
        else
            ctx.command_timeout_ms,
        .command_artifact_dir = ctx.command_artifact_dir,
        .replay_capability = ctx.session_child_capability,
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .yield_time_ms = input.yield_time_ms,
        .cancel_flag = ctx.cancel_flag,
        .tool_yield_flag = ctx.tool_yield_flag,
    }) catch |err| {
        if (err == error.Cancelled and
            ctx.cancel_flag != null and
            ctx.cancel_flag.?.load(.seq_cst))
        {
            return error.Cancelled;
        }
        return runtimeFailure(ctx, err);
    };
    defer prepared.deinit(ctx.allocator);
    const result = try finishPrepared(withoutSteeringYield(ctx, input.yield_time_ms), runtime, &prepared, .run);
    return attachSnapshotNotice(ctx.allocator, result) catch |err| {
        result.deinit(ctx.allocator);
        return err;
    };
}

/// Adds the pending shell snapshot fallback notice to a JSON run result, so
/// the model and ACP clients learn once that startup files run per command.
fn attachSnapshotNotice(
    alloc: Allocator,
    result: tool_dispatch.ToolResult,
) Allocator.Error!tool_dispatch.ToolResult {
    const body = switch (result) {
        .success, .failure => |value| value,
        .rich => return result,
    };
    if (body.len == 0 or body[body.len - 1] != '}') return result;
    const notice = (try shell_snapshot.processOwner().takeResultNotice(alloc)) orelse return result;
    defer alloc.free(notice);
    const updated = (try withJsonStringField(alloc, body, "notice", notice)).?;
    alloc.free(body);
    return switch (result) {
        .success => .{ .success = updated },
        .failure => .{ .failure = updated },
        .rich => unreachable,
    };
}

/// Returns a copy of the JSON object `body` with the string field `name`,
/// a plain key, set to `value` at its end, or null when `body` does not end
/// in `}`. The caller owns the copy; `body` is left as it is.
fn withJsonStringField(
    alloc: Allocator,
    body: []const u8,
    comptime name: []const u8,
    value: []const u8,
) Allocator.Error!?[]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(body[0 .. body.len - 1]) catch return error.OutOfMemory;
    out.writer.writeAll(",\"" ++ name ++ "\":") catch return error.OutOfMemory;
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('}') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const steering_notice = "New steering arrived, so this call returned while the command keeps running. " ++
    "Read the steering first. The session stays yours: use interact with this session_id to follow it, or stop to end it.";

fn steerYieldRequested(ctx: tool_dispatch.DispatchContext) bool {
    const flag = ctx.tool_yield_flag orelse return false;
    return flag.load(.seq_cst);
}

/// Adds `steering_notice` to a JSON result of a command that returned
/// running for steering. Frees `body` only when it returns the new one.
fn attachSteeringNotice(alloc: Allocator, body: []u8) Allocator.Error![]u8 {
    const updated = (try withJsonStringField(alloc, body, "steering_notice", steering_notice)) orelse return body;
    alloc.free(body);
    return updated;
}

/// `attachSteeringNotice` for a result of `prepared` when its command still
/// runs and steering asked it to yield. When `started_here` is set, the
/// call started the command, so steering moved a command of this turn to
/// the background: it is marked as detached by steering in this call's
/// turn, and an explicit cancel of that turn stops it
/// (`stopSteeringDetached`). An `interact` poll passes false, so a command
/// the model left in the background itself, or one from an earlier turn,
/// keeps running. On failure it gives up the result's delivery, and the
/// caller still owns `body`.
fn noteSteeringYield(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    body: []u8,
    started_here: bool,
) Allocator.Error![]u8 {
    if (prepared.snapshot.state != .running or !steerYieldRequested(ctx)) return body;
    const updated = attachSteeringNotice(ctx.allocator, body) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        return err;
    };
    if (!started_here) return updated;
    if (ctx.output_chunk_lifecycle_id) |lifecycle_id| {
        runtime.markSteeringDetached(prepared.snapshot.execution_id, lifecycle_id.turn_id);
    }
    return updated;
}

/// A call that asked to return at once (`yield_time_ms` 0) never waited, so
/// steering did not move its command to the background: its result gets no
/// steering notice, and a cancel of the turn leaves the command running.
fn withoutSteeringYield(ctx: tool_dispatch.DispatchContext, yield_time_ms: u32) tool_dispatch.DispatchContext {
    var result = ctx;
    if (yield_time_ms == 0) result.tool_yield_flag = null;
    return result;
}

/// Stops every command that steering moved to the background during turn
/// `turn_id`, after an explicit cancel of that turn, the way the `stop`
/// action does: gracefully first, then by force if the command still runs.
/// Commands the model left in the background itself and those of other
/// turns keep running. `ctx` must not carry the cancelled turn's cancel
/// flag, or the stop itself would be cancelled. It runs after the turn is
/// reported, and its last trace line says it is done.
///
/// Up to `max_parallel_detached_stops` stops run at once, as tasks of one
/// `std.Io.Group` that this call awaits, so the 2 s waits of stubborn tty
/// commands overlap. Their graceful closes do not: the terminal client runs
/// every write, resize, signal and close in one admission order, so each
/// tty command that ignores SIGTERM still adds its 800 ms close, and each
/// further group of `max_parallel_detached_stops` adds another 2 s wait.
/// Two such commands take about 3.5 s, 12 about 14 s, and 20 about 23 s.
/// A stop the busy terminal client refuses runs again
/// (`max_busy_terminal_attempts`), which can add up to about 3.1 s for
/// each command.
pub fn stopSteeringDetached(
    ctx: tool_dispatch.DispatchContext,
    turn_id: u64,
) Allocator.Error!void {
    const runtime = ctx.managed_executions orelse return;
    const ids = try runtime.takeSteeringDetached(ctx.allocator, turn_id);
    defer {
        for (ids) |id| ctx.allocator.free(id);
        ctx.allocator.free(ids);
    }
    var queue: DetachedStopQueue = .{ .ctx = ctx, .ids = ids, .turn_id = turn_id };
    const io = io_mod.getIo();
    var group: std.Io.Group = .init;
    for (0..@min(ids.len, max_parallel_detached_stops)) |_| group.async(io, DetachedStopQueue.run, .{&queue});
    group.await(io) catch |err| debug_trace.logf(
        "shell",
        "steering-detached command stops awaited after cancel turn_id={d} err={s}",
        .{ turn_id, @errorName(err) },
    );
    debug_trace.logf(
        "shell",
        "steering-detached command stops done turn_id={d} count={d}",
        .{ turn_id, ids.len },
    );
}

/// Each running stop holds one terminal client request at a time. The
/// client runs at most 32 requests at once for all agents and refuses the
/// rest, so one cancel uses at most this many and leaves room for the others.
const max_parallel_detached_stops = 8;

/// The commands of one `stopSteeringDetached`. Its tasks take them one by
/// one, in list order, until none is left.
const DetachedStopQueue = struct {
    ctx: tool_dispatch.DispatchContext,
    ids: []const []const u8,
    turn_id: u64,
    next: std.atomic.Value(usize) = .init(0),

    /// Stops the next commands until none is left. Each stop gets its own
    /// arena over `ctx.lifecycle_allocator`, which is thread-safe; the
    /// caller's allocator may be an arena that only its own thread may use.
    fn run(self: *DetachedStopQueue) void {
        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.ids.len) return;
            const session_id = self.ids[index];
            var arena = std.heap.ArenaAllocator.init(self.ctx.lifecycle_allocator);
            defer arena.deinit();
            var ctx = self.ctx;
            ctx.allocator = arena.allocator();
            stopOneSteeringDetached(ctx, session_id, self.turn_id) catch |err| {
                debug_trace.logf(
                    "shell",
                    "steering-detached command stop failed session_id={s} turn_id={d} err={s} dropped=background_command_stop",
                    .{ session_id, self.turn_id, @errorName(err) },
                );
            };
        }
    }
};

/// Stops `session_id`, a command steering moved to the background in turn
/// `turn_id`: gracefully, then by force if it still runs.
fn stopOneSteeringDetached(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    turn_id: u64,
) Allocator.Error!void {
    debug_trace.logf(
        "shell",
        "stopping steering-detached command session_id={s} turn_id={d} reason=turn_cancelled",
        .{ session_id, turn_id },
    );
    var cause: DetachedStopCause = .{};
    switch (try stopDetachedOnce(ctx, session_id, false, &cause)) {
        .ended => return,
        .not_ended => debug_trace.logf(
            "shell",
            "graceful stop did not end steering-detached command session_id={s} turn_id={d} failure={s} next=force",
            .{ session_id, turn_id, cause.text() },
        ),
        .refused => debug_trace.logf(
            "shell",
            "graceful stop of steering-detached command never ran session_id={s} turn_id={d} reason=terminal_busy next=force",
            .{ session_id, turn_id },
        ),
    }
    cause = .{};
    switch (try stopDetachedOnce(ctx, session_id, true, &cause)) {
        .ended => {},
        .not_ended => debug_trace.logf(
            "shell",
            "steering-detached command stop failed session_id={s} turn_id={d} failure={s}",
            .{ session_id, turn_id, cause.text() },
        ),
        .refused => debug_trace.logf(
            "shell",
            "steering-detached command stop failed session_id={s} turn_id={d} reason=terminal_busy",
            .{ session_id, turn_id },
        ),
    }
}

/// What one `stopDetachedOnce` did: the command ended, the stop ran and
/// left it running or failed, or the busy terminal client refused every run.
const DetachedStopOutcome = enum { ended, not_ended, refused };

/// Why a stop did not end its command: the failure code or error name, or
/// `none` when the stop gave no reason.
const DetachedStopCause = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    fn set(self: *DetachedStopCause, reason: []const u8) void {
        self.len = @min(reason.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], reason[0..self.len]);
    }

    fn text(self: *const DetachedStopCause) []const u8 {
        return if (self.len == 0) "none" else self.buffer[0..self.len];
    }
};

/// How many times a terminal request at a turn's end, such as a
/// steering-detached stop or a lease release, runs while the terminal
/// client refuses it as busy, and the first wait between two runs, which
/// doubles each time: 50, 100, 200, 400 and 800 ms, about 1.5 s for one
/// request. A command whose graceful and forced stops are both refused
/// every time takes about 3.1 s.
const max_busy_terminal_attempts = 6;
const busy_terminal_first_backoff_ms = 50;

/// Runs the `stop` action on `session_id` and reports what it did. The
/// terminal client runs at most 32 requests for all agents and refuses the
/// rest with a retryable failure; such a stop runs again after a short
/// wait, up to `max_busy_terminal_attempts` times, so a busy client does
/// not leave the command running after the cancel. When the command does
/// not end, `cause` says why.
fn stopDetachedOnce(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    force: bool,
    cause: *DetachedStopCause,
) Allocator.Error!DetachedStopOutcome {
    const force_name = if (force) "true" else "false";
    var backoff_ms: u64 = busy_terminal_first_backoff_ms;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        const result = callStop(ctx, .{
            .action = .stop,
            .session_id = session_id,
            .force = force,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf(
                    "shell",
                    "steering-detached command stop errored session_id={s} force={s} err={s}",
                    .{ session_id, force_name, @errorName(err) },
                );
                cause.set(@errorName(err));
                return .not_ended;
            },
        };
        defer result.deinit(ctx.allocator);
        const ended = switch (result) {
            .success => true,
            .failure, .rich => false,
        };
        var code_buffer: [64]u8 = undefined;
        const failure = stopFailure(ctx.allocator, result, &code_buffer);
        if (!ended and failure.busy) {
            if (attempt == max_busy_terminal_attempts) {
                debug_trace.logf(
                    "shell",
                    "steering-detached command stop gave up session_id={s} force={s} attempts={d} reason=terminal_busy dropped=background_command_stop",
                    .{ session_id, force_name, attempt },
                );
                return .refused;
            }
            debug_trace.logf(
                "shell",
                "steering-detached command stop refused session_id={s} force={s} attempt={d} reason=terminal_busy retry_in_ms={d}",
                .{ session_id, force_name, attempt, backoff_ms },
            );
            io_mod.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms *= 2;
            continue;
        }
        if (ended) {
            debug_trace.logf(
                "shell",
                "stopped steering-detached command session_id={s} force={s} ended=true",
                .{ session_id, force_name },
            );
            return .ended;
        }
        debug_trace.logf(
            "shell",
            "stopped steering-detached command session_id={s} force={s} ended=false failure={s}",
            .{ session_id, force_name, failure.code },
        );
        cause.set(failure.code);
        return .not_ended;
    }
}

/// What a failed stop says about itself: its error code, or "none", and
/// whether the terminal client refused it because it was busy, which is the
/// only failure a stop runs again for. A cloned terminal failure
/// (`{"failure":{...}}`) is busy when `StructuredError.isBusyRefusal` says
/// so. A shell failure (`{"error":{...}}`) is busy when it is the
/// retryable `TerminalCapacityExceeded`, which the tty observer gives only
/// for such a refusal.
const StopFailure = struct { busy: bool, code: []const u8 };

/// `code_buffer` holds the returned code.
fn stopFailure(alloc: Allocator, result: tool_dispatch.ToolResult, code_buffer: *[64]u8) StopFailure {
    const none: StopFailure = .{ .busy = false, .code = "none" };
    const body = switch (result) {
        .failure => |body| body,
        .success, .rich => return none,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return none;
    defer parsed.deinit();
    if (parsed.value != .object) return none;
    for ([_][]const u8{ "failure", "error" }) |key| {
        const inner = parsed.value.object.get(key) orelse continue;
        if (inner != .object) continue;
        const code_value = inner.object.get("code") orelse continue;
        if (code_value != .string or code_value.string.len > code_buffer.len) continue;
        const code = code_buffer[0..code_value.string.len];
        @memcpy(code, code_value.string);
        const retryable = if (inner.object.get("retryable")) |value| value == .bool and value.bool else false;
        const busy = if (std.mem.eql(u8, key, "failure")) busy: {
            const terminal_code = std.meta.stringToEnum(terminal_contracts.StructuredErrorCode, code) orelse break :busy false;
            const action_value = inner.object.get("action") orelse break :busy false;
            if (action_value != .string) break :busy false;
            const action = std.meta.stringToEnum(terminal_contracts.Action, action_value.string) orelse break :busy false;
            const failure: terminal_contracts.StructuredError = .{ .action = action, .code = terminal_code, .retryable = retryable };
            break :busy failure.isBusyRefusal();
        } else retryable and std.mem.eql(u8, code, @errorName(error.TerminalCapacityExceeded));
        return .{ .busy = busy, .code = code };
    }
    return none;
}

fn callInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    switch (ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err)) {
        .indexed => {},
        .ended_with_owner => return terminalEndedWithOwner(ctx, session_id),
    }
    const chars = input.chars orelse "";
    const yield_time_ms = effective_interact_yield_time(chars.len != 0, input.yield_time_ms);
    if (runtime.isTombstone(session_id)) {
        if (chars.len != 0) return runtimeFailure(ctx, error.ExecutionTerminal);
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .command);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        return callTtyInteract(ctx, input, yield_time_ms);
    }
    if (chars.len != 0) return runtimeFailure(ctx, error.InvalidBackend);
    var prepared = runtime.waitOrYield(
        ctx.allocator,
        session_id,
        yield_time_ms,
        ctx.cancel_flag,
        ctx.tool_yield_flag,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(withoutSteeringYield(ctx, yield_time_ms), runtime, &prepared, .command);
}

fn callStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    switch (ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err)) {
        .indexed => {},
        .ended_with_owner => return terminalEndedWithOwner(ctx, session_id),
    }
    if (runtime.isTombstone(session_id)) {
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .stop);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        refreshTtyExecution(ctx, runtime, session_id, "") catch |err|
            return runtimeFailure(ctx, err);
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        return callTtyStop(ctx, input);
    }
    var prepared = runtime.stop(
        ctx.allocator,
        session_id,
        input.force,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

const ParsedTerminalExecution = struct {
    result: terminal_contracts.OwnedResult,

    fn deinit(self: *ParsedTerminalExecution, alloc: Allocator) void {
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

fn callTtyRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const owner = ctx.session_child_capability orelse return unavailable(ctx);
    const durable_session_id = ctx.terminal_owner_session_id orelse return unavailable(ctx);
    const command = input.command orelse return unavailable(ctx);
    const cwd = resolveCwd(ctx.allocator, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    defer ctx.allocator.free(@constCast(cwd));
    var shell_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(shell_arena_state);
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    const shell = ttyShell(shell_arena_state.allocator(), input, configured) catch |err|
        return runtimeFailure(ctx, err);
    const environment = shell_resolver.environmentForShellSpec(
        shell_arena_state.allocator(),
        configured,
        shell,
    ) catch |err| return runtimeFailure(ctx, err);
    requireTtyShellAuthority(ctx, .{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = environment,
        .execution_mode = .tty,
    }) catch |err| return runtimeFailure(ctx, err);
    runtime.reserveTtyCapacity() catch |err| return runtimeFailure(ctx, err);
    var capacity_reserved = true;
    defer if (capacity_reserved) runtime.releaseTtyCapacity();
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return unavailable(ctx);
    var persistence = terminal_operation.prepareStartPersistence(ctx.allocator, .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .cwd = cwd,
        .transport_role = ctx.terminal_transport_role,
        .backend = .native,
        .actor = .agent,
        .controls = .full(),
        .lifetime = .session,
    }) catch |err| return runtimeFailure(ctx, err);
    defer persistence.deinit();
    // With a steering yield flag, the start returns once the command runs
    // and a separate wait, which steering can end, waits for its exit.
    // Cancelling the start itself would end the command.
    const split_wait = ctx.tool_yield_flag != null and input.yield_time_ms != 0;
    const request = terminal_contracts.ActionRequest{ .start = .{
        .cwd = cwd,
        .command = command,
        .shell = shell,
        .backend = .native,
        .return_when = if (input.yield_time_ms == 0 or split_wait) .started else .exit,
        .wait_ceiling_ms = @max(@as(u64, 1), input.yield_time_ms),
        .timeout_ms = input.timeout_ms,
        .persistence = persistence.view(),
    } };
    var executed = executeTerminal(ctx, request) catch |err|
        return runtimeFailure(ctx, err);
    defer executed.deinit(ctx.allocator);
    const started = switch (executed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, executed.result.view()),
        .success => |success| switch (success) {
            .start => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    var session_owned = true;
    defer if (session_owned) closeTtyBestEffort(ctx, started.session.session_id);
    var initial_state = terminal_managed_observer.snapshotState(started.session, started.outcome);
    if (split_wait and initial_state == .running) {
        switch (try waitTtyExitOrYield(ctx, started.session.session_id, input.yield_time_ms)) {
            .state => |state| initial_state = state,
            .failure => |failure| return failure,
        }
    }
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        started.session.session_id,
        initial_state,
        null,
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    finalizeCompletedTty(ctx, started.session.session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.registerTty(ctx.allocator, .{
        .execution_id = started.session.session_id,
        .command = command,
        .cwd = cwd,
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = observed.state == .running,
        .capacity_reserved = true,
        .replay_capability = ctx.session_child_capability,
    }) catch |err| return runtimeFailure(ctx, err);
    capacity_reserved = false;
    session_owned = false;
    defer prepared.deinit(ctx.allocator);
    _ = owner;
    return finishPrepared(withoutSteeringYield(ctx, input.yield_time_ms), runtime, &prepared, .run);
}

fn callTtyInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
    yield_time_ms: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    if (runtime.isTombstone(session_id)) {
        return runtimeFailure(ctx, error.ExecutionTerminal);
    }
    var state: managed_execution.SnapshotState = .running;
    var accepted_bytes: ?u32 = null;
    const chars = input.chars orelse "";
    if (chars.len != 0) {
        if (runtime.backendFor(session_id) != .tty) {
            return runtimeFailure(ctx, error.InvalidBackend);
        }
        var ready = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
            .session_id = session_id,
            .return_when = .started,
            .safety_ceiling_ms = 20_000,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer ready.deinit(ctx.allocator);
        const ready_result = switch (ready.result.view()) {
            .failure => return cloneTerminalFailure(ctx, ready.result.view()),
            .success => |success| switch (success) {
                .wait => |value| value,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        if (ready_result.session.lifecycle != .running) {
            return runtimeFailure(ctx, error.TerminalNotReady);
        }

        var acquired = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .acquire,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer acquired.deinit(ctx.allocator);
        switch (acquired.result.view()) {
            .failure => return cloneTerminalFailure(ctx, acquired.result.view()),
            .success => |success| switch (success) {
                .write => {},
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        }
        var release_needed = true;
        defer if (release_needed) releaseTtyLease(ctx, session_id);

        var used = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .payload = .{ .text = chars },
            .lease = .use,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer used.deinit(ctx.allocator);
        accepted_bytes = switch (used.result.view()) {
            .failure => return cloneTerminalFailure(ctx, used.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.accepted_bytes,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };

        var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .release,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer released.deinit(ctx.allocator);
        const facts = switch (released.result.view()) {
            .failure => return cloneTerminalFailure(ctx, released.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.session,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        release_needed = false;
        state = terminal_managed_observer.snapshotState(facts, null);
    }
    const waiter_id = runtime.reserveExternalWait(session_id) catch |err|
        return runtimeFailure(ctx, err);
    defer runtime.releaseExternalWait(session_id, waiter_id);
    if (state == .running and yield_time_ms != 0) {
        switch (try waitTtyExitOrYield(ctx, session_id, yield_time_ms)) {
            .state => |waited_state| state = waited_state,
            .failure => |failure| return failure,
        }
    }
    if (accepted_bytes != null and yield_time_ms == 0) {
        io_mod.sleep(100 * std.time.ns_per_ms);
    }
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        state,
        runtime.ttyCursorFor(session_id),
    ) catch |err|
        return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    if (runtime.externalWaitPreempted(session_id, waiter_id)) {
        return runtimeFailure(ctx, error.WaitPreempted);
    }
    finalizeCompletedTty(ctx, session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    const finish_ctx = withoutSteeringYield(ctx, yield_time_ms);
    return if (accepted_bytes) |count|
        finishPreparedWithAccepted(finish_ctx, runtime, &prepared, count)
    else
        finishPrepared(finish_ctx, runtime, &prepared, .command);
}

fn callTtyStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    runtime.preemptWait(session_id);
    var signaled = executeAuthorizedTerminal(ctx, session_id, .{ .signal = .{
        .session_id = session_id,
        .signal = if (input.force) .kill else .terminate,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer signaled.deinit(ctx.allocator);
    switch (signaled.result.view()) {
        .failure => return cloneTerminalFailure(ctx, signaled.result.view()),
        .success => |success| switch (success) {
            .signal => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }

    var stopped_status: ?command_contract.CommandStatus = null;
    var waited = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = 2_000,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer waited.deinit(ctx.allocator);
    const wait_result = switch (waited.result.view()) {
        .failure => return cloneTerminalFailure(ctx, waited.result.view()),
        .success => |success| switch (success) {
            .wait => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    stopped_status = statusFromOutcome(wait_result.outcome);
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        terminal_managed_observer.snapshotState(wait_result.session, wait_result.outcome),
        runtime.ttyCursorFor(session_id),
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);

    var closed = executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = if (input.force) .force else .graceful,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, closed.result.view()),
        .success => |success| switch (success) {
            .close => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = .{ .stopped = stopped_status },
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn ttyShell(
    alloc: Allocator,
    input: Input,
    configured_login_shell: ?[]const u8,
) !terminal_contracts.ShellSpec {
    if (input.shell) |shell| return .{ .executable = .{
        .path = shell.path,
        .clean_start = shell.clean_start,
    } };
    return shell_resolver.profileShell(
        alloc,
        configured_login_shell,
        input.profile orelse .user,
    );
}

fn requireTtyShellAuthority(
    ctx: tool_dispatch.DispatchContext,
    command_ctx: command_admission.CommandContext,
) !void {
    const execution_authority = ctx.execution_authority orelse
        return error.CommandAuthorityContextMismatch;
    const command_authority = switch (execution_authority) {
        .run_command => |value| value,
        .ordinary, .file_mutation, .vision_paths => return error.CommandAuthorityContextMismatch,
    };
    const shell_allowed = switch (command_authority) {
        .shell_allowed => |value| value,
        .direct_only => return error.CommandAdmissionChanged,
    };
    if (!shell_allowed.fingerprint.matches(command_ctx)) {
        return error.CommandAuthorityContextMismatch;
    }
}

fn executeTerminal(
    ctx: tool_dispatch.DispatchContext,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    return .{ .result = try terminal_action_executor.execute(.{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .runtime = ctx.terminal_client orelse return error.TerminalUnavailable,
        .cancel_flag = ctx.cancel_flag,
    }, request) };
}

fn executeAuthorizedTerminal(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    var authority = try reloadTerminalAuthority(ctx, session_id);
    defer authority.deinit();
    const authorized: terminal_contracts.ActionRequest = switch (request) {
        .read => |value| .{ .read = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .write => |value| .{ .write = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .wait => |value| .{ .wait = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .signal => |value| .{ .signal = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .close => |value| .{ .close = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .screen => |value| .{ .screen = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .start, .inspect, .list, .resize => return error.InvalidTerminalRequest,
    };
    return executeTerminal(ctx, authorized);
}

const TtyWaitOutcome = union(enum) {
    state: managed_execution.SnapshotState,
    failure: tool_dispatch.ToolResult,
};

/// Waits up to `ceiling_ms` for tty session `session_id` to exit. Steering
/// (`ctx.tool_yield_flag`) ends the wait early with the session still
/// running; only the wait is cancelled, never the session.
fn waitTtyExitOrYield(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    ceiling_ms: u32,
) tool_dispatch.DispatchError!TtyWaitOutcome {
    var authority = reloadTerminalAuthority(ctx, session_id) catch |err|
        return .{ .failure = try runtimeFailure(ctx, err) };
    defer authority.deinit();
    var waited: ParsedTerminalExecution = .{ .result = terminal_action_executor.execute(.{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .runtime = ctx.terminal_client orelse return .{ .failure = try unavailable(ctx) },
        .cancel_flag = ctx.cancel_flag,
        .yield_flag = ctx.tool_yield_flag,
        .yield_grace_ms = managed_execution.steerYieldGraceMs(),
    }, .{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = ceiling_ms,
        .authority = authority.view(),
    } }) catch |err| return .{ .failure = try runtimeFailure(ctx, err) } };
    defer waited.deinit(ctx.allocator);
    switch (waited.result.view()) {
        .failure => |failure| {
            const user_cancelled = if (ctx.cancel_flag) |flag| flag.load(.seq_cst) else false;
            if (failure.code == .cancelled and !user_cancelled and steerYieldRequested(ctx)) {
                debug_trace.logf("shell", "tty wait yielded for steering session={s}", .{session_id});
                return .{ .state = .running };
            }
            return .{ .failure = try cloneTerminalFailure(ctx, waited.result.view()) };
        },
        .success => |success| switch (success) {
            .wait => |value| return .{ .state = terminal_managed_observer.snapshotState(value.session, value.outcome) },
            else => return .{ .failure = try runtimeFailure(ctx, error.InvalidTerminalResult) },
        },
    }
}

fn reloadTerminalAuthority(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !terminal_operation.OwnedAuthorityClaim {
    const owner = ctx.session_child_capability orelse return error.TerminalAuthorityUnavailable;
    const durable_session_id = ctx.terminal_owner_session_id orelse
        return error.TerminalAuthorityUnavailable;
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return error.TerminalAuthorityUnavailable;
    return terminal_store.reloadOwnerAuthorityClaim(ctx.allocator, owner, .{
        .terminal_session_id = session_id,
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .actor = .agent,
    });
}

fn cloneTerminalFailure(
    ctx: tool_dispatch.DispatchContext,
    result: terminal_contracts.Result,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (result == .success) return runtimeFailure(ctx, error.InvalidTerminalResult);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    std.json.Stringify.value(result, .{}, &out.writer) catch
        return error.OutOfMemory;
    return .{ .failure = try out.toOwnedSlice() };
}

fn statusFromOutcome(
    outcome: terminal_contracts.ReturnOutcome,
) ?command_contract.CommandStatus {
    return switch (outcome) {
        .exited => |code| .{ .exit_code = code },
        .signal => |signal| .{ .signal = signal },
        .started, .condition_met, .safety_ceiling, .cancelled => null,
    };
}

fn releaseTtyLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = null,
    } }) catch |err| {
        debug_trace.logf(
            "shell",
            "TTY write lease release failed session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    released.deinit(ctx.allocator);
}

/// Releases the agent's write lease on `session_id` at a turn's end. A
/// release the busy terminal client refuses runs again after a short wait,
/// up to `max_busy_terminal_attempts` times, as a steered stop does.
pub fn releaseAgentWriteLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !void {
    var backoff_ms: u64 = busy_terminal_first_backoff_ms;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        var released = try executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .release,
            .authority = null,
        } });
        defer released.deinit(ctx.allocator);
        switch (released.result.view()) {
            .success => |success| switch (success) {
                .write => return,
                else => return error.InvalidTerminalLeaseCleanupResult,
            },
            .failure => |failure| switch (failure.code) {
                .session_not_found, .lease_conflict => return,
                // Only a busy refusal goes away when the release runs again.
                else => if (!failure.isBusyRefusal()) return error.TerminalLeaseCleanupFailed,
            },
        }
        if (attempt == max_busy_terminal_attempts) {
            debug_trace.logf(
                "shell",
                "terminal lease release gave up session_id={s} attempts={d} reason=terminal_busy dropped=agent_write_lease_release",
                .{ session_id, attempt },
            );
            return error.TerminalLeaseCleanupFailed;
        }
        debug_trace.logf(
            "shell",
            "terminal lease release refused session_id={s} attempt={d} reason=terminal_busy retry_in_ms={d}",
            .{ session_id, attempt, backoff_ms },
        );
        io_mod.sleep(backoff_ms * std.time.ns_per_ms);
        backoff_ms *= 2;
    }
}

fn finalizeCompletedTty(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) !void {
    switch (state) {
        .completed => {},
        .running, .stopped, .lost => return,
    }
    var closed = try executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = .graceful,
        .authority = null,
    } });
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return error.TerminalCloseFailed,
        .success => |success| switch (success) {
            .close => {},
            else => return error.InvalidTerminalResult,
        },
    }
}

fn closeTtyBestEffort(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    // The close ignores `cancel_flag`. A user cancel is when this cleanup
    // matters most, and with the flag set the executor would cancel the
    // close too and leave the command running.
    // A close the busy terminal client refuses runs again after a short
    // wait, up to `max_busy_terminal_attempts` times, as a steered stop does.
    var close_ctx = ctx;
    close_ctx.cancel_flag = null;
    var backoff_ms: u64 = busy_terminal_first_backoff_ms;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        var closed = executeAuthorizedTerminal(close_ctx, session_id, .{ .close = .{
            .session_id = session_id,
            .policy = .force,
            .authority = null,
        } }) catch |err| {
            debug_trace.logf(
                "shell",
                "unpublished TTY cleanup failed session_id={s} err={s} dropped=unpublished_tty_close",
                .{ session_id, @errorName(err) },
            );
            return;
        };
        defer closed.deinit(ctx.allocator);
        const failure = switch (closed.result.view()) {
            .success => return,
            .failure => |failure| failure,
        };
        // The terminal is already gone, so nothing is left to close.
        if (failure.code == .session_not_found) return;
        if (!failure.isBusyRefusal()) {
            debug_trace.logf(
                "shell",
                "unpublished TTY cleanup failed session_id={s} code={s} dropped=unpublished_tty_close",
                .{ session_id, @tagName(failure.code) },
            );
            return;
        }
        if (attempt == max_busy_terminal_attempts) {
            debug_trace.logf(
                "shell",
                "unpublished TTY cleanup gave up session_id={s} attempts={d} reason=terminal_busy dropped=unpublished_tty_close",
                .{ session_id, attempt },
            );
            return;
        }
        debug_trace.logf(
            "shell",
            "unpublished TTY cleanup refused session_id={s} attempt={d} reason=terminal_busy retry_in_ms={d}",
            .{ session_id, attempt, backoff_ms },
        );
        io_mod.sleep(backoff_ms * std.time.ns_per_ms);
        backoff_ms *= 2;
    }
}

fn finishPreparedWithAccepted(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    accepted_bytes: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        accepted_bytes,
        ctx.max_tool_result_bytes,
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    errdefer ctx.allocator.free(body);
    body = try noteSteeringYield(ctx, runtime, prepared, body, false);
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch
        return runtimeFailure(ctx, error.ResultCommitFailed);
    return .{ .success = body };
}

fn ensureOwnedTtyIndexed(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
) !terminal_managed_observer.SyncOutcome {
    if (runtime.stateFor(session_id) != null) return .indexed;
    const observer = ttyObserverContext(ctx, runtime) orelse return .indexed;
    return terminal_managed_observer.syncOwned(observer, session_id);
}

/// Terminals end with the spark process that starts them and are never
/// reattached, so the agent is told to start a new one.
fn terminalEndedWithOwner(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    std.json.Stringify.value(.{ .@"error" = .{
        .tool = "shell",
        .code = tool_result_errors.terminal_ended_error_code,
        .session_id = session_id,
        .message = "This terminal ended when the spark process that started it exited. It cannot be resumed. Start a new terminal with shell action run and tty true.",
        .retryable = false,
    } }, .{}, &out.writer) catch return error.OutOfMemory;
    return .{ .failure = try out.toOwnedSlice() };
}

fn refreshTtyExecution(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    command: []const u8,
) !void {
    return terminal_managed_observer.refresh(
        ttyObserverContext(ctx, runtime) orelse
            return error.TerminalAuthorityUnavailable,
        session_id,
        command,
    );
}

fn ttyObserverContext(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
) ?terminal_managed_observer.Context {
    return .{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .terminal_client = ctx.terminal_client orelse return null,
        .managed_runtime = runtime,
        .owner = ctx.session_child_capability orelse return null,
        .durable_session_id = ctx.terminal_owner_session_id orelse return null,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .max_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = ctx.cancel_flag,
    };
}

fn finishTerminalTtyStop(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    finalizeCompletedTty(ctx, session_id, state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = state,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn finishPrepared(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    /// `run` is the result of the call that started the command, `command`
    /// a later observation of it, and `stop` the result of a stop.
    action: enum { run, command, stop },
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        null,
        ctx.max_tool_result_bytes,
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result is unavailable") };
    };
    errdefer ctx.allocator.free(body);
    switch (action) {
        .run, .command => body = try noteSteeringYield(ctx, runtime, prepared, body, action == .run),
        .stop => {},
    }
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result commit failed") };
    };
    const failed = switch (action) {
        .run, .command => snapshotFailed(prepared.snapshot),
        .stop => stop_result_failed(prepared.snapshot.state),
    };
    return if (failed)
        .{ .failure = body }
    else
        .{ .success = body };
}

fn publishSnapshotMetadata(
    ctx: tool_dispatch.DispatchContext,
    snapshot: managed_execution.Snapshot,
) !void {
    if (ctx.command_result_json_sink == null and
        ctx.tool_result_memory_sink == null) return;
    const status: ?command_contract.CommandStatus = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => return publishQuietCrossing(ctx, snapshot),
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const timed_out = if (snapshot.error_name) |name|
        std.mem.eql(u8, name, "TimeoutExpired")
    else
        false;
    var memory = types.ToolResultMemory{
        .output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .stored_output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .truncated = snapshot.output_truncated,
    };
    if (ctx.tool_result_memory_sink != null) {
        if (snapshot.output_file) |handle| {
            memory.command_output_replay = .{ .available = .{
                .handle = try ctx.allocator.dupe(u8, handle),
                .framed_bytes = snapshot.output_framed_bytes,
            } };
        }
    }
    errdefer if (memory.command_output_replay) |replay| switch (replay) {
        .available => |descriptor| ctx.allocator.free(@constCast(descriptor.handle)),
        .unavailable => {},
    };
    const completed = switch (snapshot.state) {
        .completed => true,
        .running, .stopped, .lost => false,
    };
    if (timed_out) {
        memory.command_process_presentation = .timed_out;
    } else if (completed) {
        if (projection.signal) |signal| {
            memory.command_process_presentation = .{ .signal = signal };
        } else if (projection.exit_code) |exit_code| {
            if (exit_code != 0) {
                memory.command_process_presentation = .{ .exit_code = exit_code };
            }
        }
    }
    if (ctx.command_result_json_sink != null) {
        const command_result = command_contract.CommandResult{
            .command = snapshot.command,
            .cwd = snapshot.cwd,
            .exit_code = projection.exit_code,
            .signal = projection.signal,
            .timed_out = timed_out,
            .termination_indeterminate = projection.termination_indeterminate,
            .output_incomplete = snapshot.output_incomplete,
            .duration_ms = snapshot.duration_ms,
            .stdout_bytes = snapshot.stdout_bytes,
            .stderr_bytes = snapshot.stderr_bytes,
            .truncated = snapshot.output_truncated,
            .output_file = snapshot.output_file,
        };
        const command_result_json = try command_result.toJson(ctx.allocator);
        tool_dispatch.reportCommandResultJson(ctx, command_result_json);
    }
    if (ctx.tool_result_memory_sink != null) {
        tool_dispatch.reportToolResultMemory(ctx, memory);
    }
}

/// A running result carries metadata only when its wait ended at the quiet
/// crossing: the command and its quiet time, for the note spark relays to a
/// subagent's parent (`noteChildQuiet` in `src/core/subagent/tool_host.zig`).
fn publishQuietCrossing(
    ctx: tool_dispatch.DispatchContext,
    snapshot: managed_execution.Snapshot,
) !void {
    if (!snapshot.quiet_crossed or ctx.tool_result_memory_sink == null) return;
    const command = try ctx.allocator.dupe(u8, snapshot.command);
    debug_trace.eventf("shell", "quiet_crossing", .{}, "session={s} quiet_ms={d}", .{ snapshot.execution_id, snapshot.quiet_ms orelse 0 });
    tool_dispatch.reportToolResultMemory(ctx, .{ .quiet_crossing = .{
        .command = command,
        .quiet_ms = snapshot.quiet_ms orelse 0,
    } });
}

fn handoffPreparedDelivery(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    reservation_id: u64,
) !void {
    if (ctx.result_commit_sink == null) {
        return runtime.commitReservation(reservation_id);
    }
    tool_dispatch.reportResultCommit(ctx, result_commit.Token{
        .context = runtime,
        .identity = reservation_id,
        .commit_fn = commitManagedDelivery,
        .cancel_fn = cancelManagedDelivery,
    });
}

fn commitManagedDelivery(raw: *anyopaque, reservation_id: u64) !void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    return runtime.commitReservation(reservation_id);
}

fn cancelManagedDelivery(raw: *anyopaque, reservation_id: u64) void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    runtime.cancelReservation(reservation_id) catch |err| {
        debug_trace.logf(
            "shell",
            "managed delivery cancellation failed reservation={d} err={s}",
            .{ reservation_id, @errorName(err) },
        );
    };
}

fn formatSnapshot(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
) ![]u8 {
    return formatSnapshotWithLimit(
        alloc,
        snapshot,
        accepted_bytes,
        tool_result_limits.default_max_tool_result_bytes,
    );
}

fn formatSnapshotWithLimit(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    max_bytes: usize,
) ![]u8 {
    const inline_max_bytes = @min(
        max_bytes,
        result_store.large_result_threshold_bytes,
    );
    if (try formatModelSafeSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        snapshot.output_delta,
        snapshot.output_truncated,
        inline_max_bytes,
    )) |full| {
        if (full.len <= inline_max_bytes) return full;
        alloc.free(full);
    }

    var minimum: usize = 0;
    var maximum: usize = @min(snapshot.output_delta.len, inline_max_bytes);
    var best: ?[]u8 = null;
    errdefer if (best) |value| alloc.free(value);
    while (minimum <= maximum) {
        const content_budget = minimum + (maximum - minimum) / 2;
        const marker = "\n... bytes omitted; use full_output_handle for exact output ...\n";
        var projected_writer: std.Io.Writer.Allocating = .init(alloc);
        defer projected_writer.deinit();
        try text_utils.writeHeadTailBounded(
            &projected_writer.writer,
            snapshot.output_delta,
            content_budget,
            marker,
            .up,
        );
        const projected = try projected_writer.toOwnedSlice();
        defer alloc.free(projected);
        const candidate = (try formatModelSafeSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            projected,
            true,
            inline_max_bytes,
        )) orelse {
            if (content_budget == 0) break;
            maximum = content_budget - 1;
            continue;
        };
        if (candidate.len <= inline_max_bytes) {
            if (best) |value| alloc.free(value);
            best = candidate;
            minimum = content_budget + 1;
        } else {
            alloc.free(candidate);
            if (content_budget == 0) break;
            maximum = content_budget - 1;
        }
    }
    if (best) |value| return value;
    return formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        "",
        true,
        false,
    );
}

fn formatModelSafeSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
    max_encoded_bytes: usize,
) !?[]u8 {
    if (text_utils.isModelSafeText(output_delta)) {
        return try formatSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            output_delta,
            output_truncated,
            false,
        );
    }
    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        output_delta,
        max_encoded_bytes,
    );
    defer encoded.deinit(alloc);
    if (encoded.truncated) return null;
    return try formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        encoded.bytes,
        output_truncated,
        true,
    );
}

// zsh parses a whole command before it runs any of it. bash, sh, and dash
// parse and run a command one line at a time, so other lines may have run.
const zsh_parse_retry_guidance = "The shell could not parse this command (unmatched quote or syntax error), so nothing executed. Rewrite the command with corrected quoting or escaping and submit the full corrected command instead of rerunning the same text.";
const line_shell_parse_retry_guidance = "The shell could not parse this command (unmatched quote or syntax error). This shell runs a command line by line, so other lines may already have run. Check the output, then submit a corrected command instead of rerunning the same text, without repeating side effects that already happened.";
const usage_error_retry_guidance = "The command exited with a usage error (missing or invalid arguments). Rebuild the command with the required arguments explicitly set, then submit the corrected command instead of rerunning it unchanged.";

// `whole_output` is true when `output` holds everything the command printed:
// no earlier observation delivered part of it and none was cut off.
fn failureRetryGuidance(exit_code: ?i64, output: []const u8, whole_output: bool) ?[]const u8 {
    const code = exit_code orelse return null;
    if (code == 0) return null;
    if (shellParseRetryGuidance(output, whole_output)) |guidance| return guidance;
    if (hasUsageBannerOutput(output)) return usage_error_retry_guidance;
    return null;
}

const ShellFamily = enum { zsh, line_by_line };

fn shellParseRetryGuidance(output: []const u8, whole_output: bool) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const family = shellErrorFamily(trimmed) orelse continue;
        // zsh's `[` and `test` builtins report a bad expression at run time as
        // `parse error: condition expected`, and the command keeps running.
        // zsh prints the same text for a `[[` test missing an operand, which
        // fails to parse, so that error gets no guidance either.
        if (text_utils.containsIgnoreCase(trimmed, "condition expected")) continue;
        // bash 5.2 reports an unclosed quote with only this line; older
        // versions follow it with `syntax error: unexpected end of file`.
        if (!(text_utils.containsIgnoreCase(trimmed, "unmatched") or
            text_utils.containsIgnoreCase(trimmed, "unexpected EOF while looking for matching") or
            text_utils.containsIgnoreCase(trimmed, "syntax error") or
            text_utils.containsIgnoreCase(trimmed, "parse error") or
            text_utils.containsIgnoreCase(trimmed, "unterminated quoted string"))) continue;
        switch (family) {
            // zsh checks a whole command before running any of it, so a parse
            // error in the command itself is its only output. Any other output
            // means something ran, such as part of the command, a startup file,
            // or an exit hook, and the error may have come from an `eval` there.
            // Output delivered by an earlier observation counts too. Give no
            // guidance then rather than claim that nothing executed.
            .zsh => if (whole_output and std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), trimmed)) return zsh_parse_retry_guidance,
            .line_by_line => return line_shell_parse_retry_guidance,
        }
    }
    return null;
}

// Shell error prefixes may carry an absolute argv[0] path (spark spawns the
// resolved login shell as /bin/bash, /bin/zsh, ...), so match the basename
// of the token before the first colon rather than a raw line prefix.
// Snapshot and terminal runs pass the command to `eval`, so zsh names the
// source `(eval)`, as it does for an `eval` inside the command. Under the
// snapshot, bash names the script it sources from `/dev/fd/0`
// (`snapshotScript` in shell_resolver.zig), followed by `eval:`. Anchoring
// bash to that path keeps the `eval` errors of a script the command runs out.
// bash 3.2 evaluates the snapshot script instead of sourcing it
// (`snapshotInvocation`), so it names the shell, which the basename match
// covers.
fn shellErrorFamily(line: []const u8) ?ShellFamily {
    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    const token = line[0..colon];
    if (token.len == 0 or std.mem.findScalar(u8, token, ' ') != null) return null;
    if (std.mem.eql(u8, token, "(eval)")) return .zsh;
    if (std.mem.eql(u8, token, "/dev/fd/0") and std.mem.startsWith(u8, line[colon + 1 ..], " eval:")) return .line_by_line;
    const base = if (std.mem.findLast(u8, token, "/")) |slash| token[slash + 1 ..] else token;
    if (std.mem.eql(u8, base, "zsh")) return .zsh;
    const line_shells = [_][]const u8{ "bash", "sh", "dash" };
    for (line_shells) |name| {
        if (std.mem.eql(u8, base, name)) return .line_by_line;
    }
    return null;
}

fn hasUsageBannerOutput(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var scanned: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (scanned >= 4) return false;
        scanned += 1;
        if (std.ascii.startsWithIgnoreCase(trimmed, "usage:")) return true;
    }
    return false;
}

/// The shell result the model reads, which every later request of the
/// session sends again. It holds only the fields that say something: one that
/// is null or false is left out, so a command that printed nothing reads
/// `{"state":"completed","exit_code":0,"duration_ms":12,"output_delta":""}`.
/// `backend` and `persistence` come with the `session_id` of a session the
/// model can still use, and otherwise only when they are not the default
/// `captured` and `process`, such as a command that ran on a terminal.
/// `output_terminal_safe` marks output whose unsafe bytes were written as
/// escapes (`escaped`). A running captured command also says how long it has
/// run (`running_ms`) and printed nothing (`quiet_ms`), and once that quiet
/// time reaches the limit, `quiet_notice` asks the model to check it
/// (`src/core/execution/quiet_notice.zig`).
fn formatSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
    escaped: bool,
) ![]u8 {
    const status = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => null,
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const retry_guidance: ?[]const u8 = if (snapshot.output_incomplete)
        "Command output is incomplete. Inspect external state and available output before retrying; do not blindly rerun a command that may have changed state."
    else switch (snapshot.state) {
        .lost => "Execution status is indeterminate. Inspect external state before retrying; do not blindly rerun a command that may have changed state.",
        .completed => failureRetryGuidance(
            projection.exit_code,
            snapshot.output_delta,
            snapshot.stdout_bytes +| snapshot.stderr_bytes == snapshot.output_delta.len,
        ),
        .running, .stopped => null,
    };
    var notice_buffer: [quiet_notice_max_bytes]u8 = undefined;
    const notice: ?[]const u8 = if (snapshot.quiet_notice)
        quietNoticeText(&notice_buffer, snapshot.quiet_ms orelse 0)
    else
        null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const retained = snapshot.retained;
    try std.json.Stringify.value(.{
        .session_id = if (retained) snapshot.execution_id else null,
        .state = snapshotStateName(snapshot.state),
        .backend = if (retained or snapshot.backend != .captured) @tagName(snapshot.backend) else null,
        .persistence = if (retained or snapshot.persistence != .process) @tagName(snapshot.persistence) else null,
        .output_truncated = presentFlag(output_truncated),
        .output_incomplete = presentFlag(snapshot.output_incomplete),
        .output_terminal_safe = presentFlag(escaped),
        .full_output_handle = snapshot.output_file,
        .exit_code = projection.exit_code,
        .signal = projection.signal,
        .termination_indeterminate = presentFlag(projection.termination_indeterminate),
        .duration_ms = snapshot.duration_ms,
        .running_ms = snapshot.running_ms,
        .quiet_ms = snapshot.quiet_ms,
        .quiet_notice = notice,
        .accepted_bytes = accepted_bytes,
        .@"error" = snapshot.error_name,
        .retry_guidance = retry_guidance,
        .output_delta = output_delta,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    return try out.toOwnedSlice();
}

const quiet_notice_max_bytes = 192;

comptime {
    // The longest notice, for the largest quiet time, fits the buffer.
    std.debug.assert(quiet_notice_max_bytes >= "No output for 18446744073709551615 min. ".len + quiet_notice_check.len);
}

/// The check a running command's result asks for once it has printed nothing
/// for the quiet limit. spark never stops the command: it may have hung, or it
/// may be a server or watcher at rest.
fn quietNoticeText(buffer: *[quiet_notice_max_bytes]u8, quiet_ms: u64) []const u8 {
    const minutes = quiet_ms / std.time.ms_per_min;
    const text = if (minutes > 0)
        std.mem.print(buffer, "No output for {d} min. " ++ quiet_notice_check, .{minutes})
    else
        std.mem.print(buffer, "No output for {d} s. " ++ quiet_notice_check, .{quiet_ms / std.time.ms_per_s});
    // The buffer fits every notice (see the comptime check above); the check
    // alone stands in if it ever does not.
    return text catch quiet_notice_check;
}

const quiet_notice_check = "Check whether this command is still working or has hung; a server or watcher can stay quiet while it works.";

/// A flag the result writes only when it is set.
fn presentFlag(value: bool) ?bool {
    return if (value) true else null;
}

fn snapshotStateName(state: managed_execution.SnapshotState) []const u8 {
    return switch (state) {
        .running => "running",
        .completed => "completed",
        .stopped => "stopped",
        .lost => "lost",
    };
}

fn snapshotFailed(snapshot: managed_execution.Snapshot) bool {
    if (snapshot.output_incomplete) return true;
    return switch (snapshot.state) {
        .running => false,
        .completed => |status| switch (status) {
            .exit_code => |code| code != 0,
            .signal, .indeterminate => true,
            .finished => false,
        },
        .stopped, .lost => true,
    };
}

fn stop_result_failed(state: managed_execution.SnapshotState) bool {
    return switch (state) {
        .lost => true,
        .stopped => |status| if (status) |value| switch (value) {
            .indeterminate => true,
            .exit_code, .signal, .finished => false,
        } else false,
        .running, .completed => false,
    };
}

fn runtimeFailure(
    ctx: tool_dispatch.DispatchContext,
    err: anyerror,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    // A busy terminal client refuses a request without running it, so the
    // same request can run again later.
    const retryable = err == error.TerminalCapacityExceeded;
    return .{ .failure = try ctx.allocator.print(
        "{{\"error\":{{\"tool\":\"shell\",\"code\":\"{s}\",\"retryable\":{s}}}}}",
        .{ @errorName(err), if (retryable) "true" else "false" },
    ) };
}

fn unavailable(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "{\"error\":{\"tool\":\"shell\",\"code\":\"unavailable\",\"retryable\":false}}",
    ) };
}

fn resolveCwd(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    requested: ?[]const u8,
) ![]const u8 {
    const primary = workspace_access.AccessScope.primaryDirectoryOf(ctx.access_scope, ctx.workspace_root);
    const value = requested orelse return arena.dupe(u8, primary);
    if (std.mem.eql(u8, value, ".")) {
        return arena.dupe(u8, primary);
    }
    return pathing.resolveWorkspaceOrExternalPath(
        arena,
        primary,
        value,
    );
}

fn commandEnvironment(
    alloc: Allocator,
    ctx: tool_dispatch.DispatchContext,
    profile: ?command_environment.Profile,
) !command_environment.Environment {
    if (ctx.captured_command_host == .workspace_clean) {
        if (profile != null) return error.InvalidWorkspaceInput;
        return .workspace_clean;
    }
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    return shell_resolver.environment(alloc, configured, profile);
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return input.action == .run and !input.tty;
}

pub fn isProcessLocal(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => !input.tty,
        .interact => input.chars == null or input.chars.?.len == 0,
        .stop => true,
    };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .interact => input.chars == null or input.chars.?.len == 0,
        .run, .stop => false,
    };
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = std.meta.stringToEnum(
        Action,
        tool_args.optionalStringArg(args, "action") orelse return null,
    ) orelse return null;
    return switch (action) {
        .run => .{
            .activity_kind = .command,
            .action_label = "Running",
            .completed_action_label = "Ran",
            .label_arg_kind = .command,
            .label_arg_default = "command",
        },
        .interact => if (tool_args.optionalStringArg(args, "chars")) |chars|
            if (chars.len == 0)
                sessionPresentation("Waiting for", "Observed")
            else
                sessionPresentation("Sending input to", "Sent input to")
        else
            sessionPresentation("Waiting for", "Observed"),
        .stop => sessionPresentation("Stopping", "Stopped"),
    };
}

fn sessionPresentation(
    action_label: []const u8,
    completed_action_label: []const u8,
) tool_dispatch.CallPresentation {
    return .{
        .activity_kind = .command,
        .action_label = action_label,
        .completed_action_label = completed_action_label,
        .label_arg_kind = .session_id,
        .label_arg_default = "shell execution",
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn check_request_correction_allocations(alloc: Allocator, args_json: []const u8) !void {
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .failure => |failure| alloc.free(failure),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

/// Decodes arguments a test expects to decode, printing the failure text
/// when they do not.
fn decodeOrFail(ctx: tool_dispatch.DispatchContext, args_json: []const u8) !tool_dispatch.ToolInput {
    return switch (try decode(ctx, args_json)) {
        .input => |input| input,
        .failure => |failure| {
            defer ctx.allocator.free(failure);
            std.debug.print("{s}\n", .{failure});
            return error.TestUnexpectedResult;
        },
    };
}

/// The setup the steering cancel tests share: the managed runtime, the
/// shell tool, a clean command environment, and a steering wait that never
/// ends, as when the user types while a command runs.
const SteeringCancelTest = struct {
    alloc: Allocator,
    runtime: managed_execution.Runtime,
    environment_arena: std.heap.ArenaAllocator,
    environment: command_environment.Environment,
    yield_flag: std.atomic.Value(bool),

    const Started = struct { id: []u8, notice: bool };

    const registry = tool_dispatch.Registry{ .tools = &.{tool_dispatch.Tool{
        .name = "shell",
        .description = "shell",
        .model_schema = .{ .name = "shell", .description = "shell" },
        .executor_kind = .terminal,
        .activity_kind = .command,
        .requires_approval = true,
        .decode = decode,
        .validate = validate,
        .call = call,
        .captured_command_action = "run",
        .captured_command_fn = isCapturedCommand,
        .process_local_fn = isProcessLocal,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    }} };

    fn init(self: *SteeringCancelTest, alloc: Allocator) !void {
        self.* = .{
            .alloc = alloc,
            .runtime = managed_execution.Runtime.init(alloc),
            .environment_arena = std.heap.ArenaAllocator.init(alloc),
            .environment = undefined,
            .yield_flag = .init(true),
        };
        errdefer self.deinit();
        self.environment = try commandEnvironment(
            self.environment_arena.allocator(),
            .{ .allocator = alloc, .workspace_root = "/tmp" },
            .clean,
        );
    }

    fn deinit(self: *SteeringCancelTest) void {
        self.environment_arena.deinit();
        self.runtime.deinit();
    }

    /// Dispatches one shell call with `arguments` in turn `turn_id` while
    /// steering waits. Its result must show the command running. Returns
    /// the command's session id, which the caller frees, and whether the
    /// result got the steering notice.
    fn dispatch(
        self: *SteeringCancelTest,
        command: []const u8,
        arguments: []const u8,
        turn_id: u64,
    ) !Started {
        const authority = command_admission.CommandExecutionAuthority{ .shell_allowed = .{
            .fingerprint = .init(.{
                .command = command,
                .resolved_cwd = "/tmp",
                .target_os = @import("builtin").target.os.tag,
                .environment = self.environment,
            }),
            .source = .yolo,
        } };
        const result = try tool_dispatch.dispatchAuthorizedToolCall(.{
            .allocator = self.alloc,
            .workspace_root = "/tmp",
            .tool_call_id = "steered-call",
            .managed_executions = &self.runtime,
            .execution_authority = .{ .run_command = authority },
            .max_command_output_bytes = 4096,
            .tool_yield_flag = &self.yield_flag,
            .output_chunk_lifecycle_id = .{ .turn_id = turn_id, .call_id = "steered-call" },
        }, registry, .{ .id = "steered-call", .name = "shell", .arguments_json = arguments });
        defer result.deinit(self.alloc);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, result.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("running", parsed.value.object.get("state").?.string);
        return .{
            .id = try self.alloc.dupe(u8, parsed.value.object.get("session_id").?.string),
            .notice = parsed.value.object.get("steering_notice") != null,
        };
    }

    /// Starts `command` in turn `turn_id` with a `run` that waits up to
    /// `yield_time_ms`.
    fn run(self: *SteeringCancelTest, command: []const u8, yield_time_ms: u32, turn_id: u64) !Started {
        const arguments = try self.alloc.print(
            "{{\"action\":\"run\",\"command\":\"{s}\",\"cwd\":\"/tmp\",\"profile\":\"clean\",\"yield_time_ms\":{d}}}",
            .{ command, yield_time_ms },
        );
        defer self.alloc.free(arguments);
        return self.dispatch(command, arguments, turn_id);
    }

    /// Waits on the output of `started`, which runs `command`, with an
    /// `interact` poll in turn `turn_id`.
    fn poll(self: *SteeringCancelTest, command: []const u8, started: Started, turn_id: u64) !Started {
        const arguments = try self.alloc.print(
            "{{\"action\":\"interact\",\"session_id\":\"{s}\",\"yield_time_ms\":30000}}",
            .{started.id},
        );
        defer self.alloc.free(arguments);
        return self.dispatch(command, arguments, turn_id);
    }

    /// What an explicit cancel of turn `turn_id` does.
    fn cancelTurn(self: *SteeringCancelTest, turn_id: u64) !void {
        try stopSteeringDetached(.{ .allocator = self.alloc, .managed_executions = &self.runtime }, turn_id);
    }

    fn state(self: *SteeringCancelTest, started: Started) ?managed_execution.SnapshotState {
        return self.runtime.stateFor(started.id);
    }
};

/// The steering cancel setup with a real terminal: the shell tool runs tty
/// commands through an in-process terminal client in a private profile.
const TtySteeringCancelTest = struct {
    const owner_session_id = "steered-stop-owner";
    const shell_path = "/bin/bash";
    const terminal_client = @import("../../core/terminal/client.zig");
    const session_child_store = @import("../../core/session/session_child_store.zig");

    alloc: Allocator,
    tmp: std.testing.TmpDir,
    home: []u8,
    capability: session_child_store.SessionChildCapability,
    client: terminal_client.Runtime,
    runtime: managed_execution.Runtime,
    yield_flag: std.atomic.Value(bool),

    fn init(self: *TtySteeringCancelTest) !void {
        const host = @import("../../core/hosts/host.zig");
        if (comptime !host.terminalSupportForOs(builtin.target.os.tag).isSupported()) {
            return error.SkipZigTest;
        }
        const alloc = std.testing.allocator;
        self.alloc = alloc;
        self.yield_flag = .init(true);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        errdefer alloc.free(self.home);
        var root = io_mod.VerifiedDir{ .dir = try self.tmp.dir.openDir(
            std.testing.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) };
        defer root.close();
        var spark_dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, ".spark");
        defer spark_dir.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&spark_dir, "sessions");
        defer sessions.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&sessions, owner_session_id);
        defer owner.close();
        const session_path = try std.Io.Dir.path.join(alloc, &.{ self.home, ".spark", "sessions", owner_session_id });
        defer alloc.free(session_path);
        self.capability = try session_child_store.SessionChildCapability.initForTesting(
            alloc,
            owner.dir,
            session_path,
            .writable,
            .{},
        );
        errdefer self.capability.deinit();
        self.client = terminal_client.Runtime.init(@import("process_provider.zig").provider);
        self.client.profile_home = self.home;
        self.runtime = managed_execution.Runtime.init(alloc);
    }

    fn deinit(self: *TtySteeringCancelTest) void {
        self.client.closeOwnedTerminals();
        self.client.joinExitDrainForTest(10_000);
        self.client.deinit();
        self.runtime.deinit();
        self.capability.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
    }

    /// The context of a call outside any turn, as the cancel uses.
    fn context(self: *TtySteeringCancelTest) tool_dispatch.DispatchContext {
        return .{
            .allocator = self.alloc,
            .lifecycle_allocator = self.alloc,
            .workspace_root = self.home,
            .managed_executions = &self.runtime,
            .terminal_client = &self.client,
            .session_child_capability = &self.capability,
            .terminal_owner_session_id = owner_session_id,
            .max_command_output_bytes = 4096,
        };
    }

    /// Runs `command` in a tty in turn `turn_id` while steering waits, and
    /// returns its session id, which the caller frees.
    fn run(self: *TtySteeringCancelTest, command: []const u8, turn_id: u64) ![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var login_shell_buffer: [4096]u8 = undefined;
        const environment = try shell_resolver.environmentForShellSpec(
            arena,
            shell_resolver.configuredLoginShellInto(&login_shell_buffer),
            .{ .executable = .{ .path = shell_path, .clean_start = true } },
        );
        const authority = command_admission.CommandExecutionAuthority{ .shell_allowed = .{
            .fingerprint = .init(.{
                .command = command,
                .resolved_cwd = self.home,
                .target_os = builtin.target.os.tag,
                .environment = environment,
                .execution_mode = .tty,
            }),
            .source = .yolo,
        } };
        const arguments = try arena.print(
            "{{\"action\":\"run\",\"tty\":true,\"command\":\"{s}\",\"shell\":{{\"kind\":\"executable\",\"path\":\"{s}\",\"clean_start\":true}},\"yield_time_ms\":30000}}",
            .{ command, shell_path },
        );
        var ctx = self.context();
        ctx.tool_call_id = "steered-tty-call";
        ctx.execution_authority = .{ .run_command = authority };
        ctx.tool_yield_flag = &self.yield_flag;
        ctx.output_chunk_lifecycle_id = .{ .turn_id = turn_id, .call_id = "steered-tty-call" };
        const result = try tool_dispatch.dispatchAuthorizedToolCall(
            ctx,
            SteeringCancelTest.registry,
            .{ .id = "steered-tty-call", .name = "shell", .arguments_json = arguments },
        );
        defer result.deinit(self.alloc);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, result.body, .{});
        defer parsed.deinit();
        std.testing.expectEqualStrings("running", parsed.value.object.get("state").?.string) catch |err| {
            std.debug.print("tty run result: {s}\n", .{result.body});
            return err;
        };
        try std.testing.expect(parsed.value.object.get("steering_notice") != null);
        return self.alloc.dupe(u8, parsed.value.object.get("session_id").?.string);
    }

    /// Admits waits for the exit of `session_id` until the client has
    /// refused them for 200 ms, so every request slot is taken and not only
    /// the intake queue. Returns how many it admitted.
    fn fill(self: *TtySteeringCancelTest, session_id: []const u8, out: []terminal_contracts.CorrelationId) !usize {
        var authority = try reloadTerminalAuthority(self.context(), session_id);
        defer authority.deinit();
        var count: usize = 0;
        var refused_since_ms: ?i64 = null;
        while (count < out.len) {
            const correlation_id = self.client.nextCorrelationId();
            self.client.admit(self.alloc, correlation_id, .{ .wait = .{
                .session_id = session_id,
                .return_when = .exit,
                .safety_ceiling_ms = 30_000,
                .authority = authority.view(),
            } }) catch |err| switch (err) {
                error.QueueFull => {
                    const now_ms = io_mod.milliTimestamp();
                    const since_ms = refused_since_ms orelse now_ms;
                    if (now_ms - since_ms >= 200) return count;
                    refused_since_ms = since_ms;
                    io_mod.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            refused_since_ms = null;
            out[count] = correlation_id;
            count += 1;
        }
        return error.TestUnexpectedResult;
    }

    /// Waits `delay_ms`, then cancels the waits `fill` admitted and takes
    /// their completions, which frees their slots.
    fn release(self: *TtySteeringCancelTest, ids: []const terminal_contracts.CorrelationId, delay_ms: u64) void {
        io_mod.sleep(delay_ms * std.time.ns_per_ms);
        for (ids) |id| _ = self.client.cancel(id);
        const deadline_ms = io_mod.milliTimestamp() + 10_000;
        for (ids) |id| while (io_mod.milliTimestamp() < deadline_ms) {
            if (self.client.takeCompletionFor(id)) |completion_value| {
                var completion = completion_value;
                completion.deinit();
                break;
            }
            io_mod.sleep(5 * std.time.ns_per_ms);
        };
    }
};

fn timedOutSnapshotCapture(_: shell_snapshot.CaptureRequest) shell_snapshot.CaptureOutcome {
    return .{ .failed = .timed_out };
}
