const std = @import("std");
const builtin = @import("builtin");
const command_policy = @import("command_policy.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const shared_theme = @import("../shared/theme.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const max_run_command_activity_bytes = 120;
const max_run_command_activity_source_bytes = max_run_command_activity_bytes * max_run_command_activity_bytes;
pub const max_run_command_reflow_bytes = max_run_command_activity_source_bytes;

pub const ToolActionInput = struct {
    tool_registry: tool_dispatch.Registry,
    call: ToolCall,
    workspace_root: []const u8 = "",
    display_target: ?[]const u8 = null,
    is_available_dynamic_mcp_tool: bool = false,
};

pub const SubagentActionState = union(enum) {
    identity,
    active,
    pending,
    completed,
    feedback: types.SteeringDelivery,
    stopped: []const u8,
};

pub const SubagentAction = struct {
    label: []u8,
    detail: []u8,

    pub fn deinit(self: SubagentAction, alloc: Allocator) void {
        alloc.free(self.label);
        alloc.free(self.detail);
    }
};

/// The caller owns the returned label and detail. Invalid requests have no projection.
pub fn subagentAction(
    alloc: Allocator,
    call: ToolCall,
    state: SubagentActionState,
) Allocator.Error!?SubagentAction {
    if (!std.mem.eql(u8, call.name, "subagent")) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const outer = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    const args = (try tool_args.unwrapRequest(scratch, outer)) orelse return null;
    const action = tool_args.optionalStringArg(args, "action") orelse return null;
    // Every other action says what it does to whom, with nothing to preview.
    if (action_words.get(action)) |words| {
        const named = namedAgent(args, action);
        // A call that concerns every subagent, a wait or a status that names
        // none, names them when its host listed them in the call's
        // `resolved_display_target`; without the list it says "subagents".
        const roster = if (words.target != null or named == null) call.resolved_display_target else null;
        const raw_target = roster orelse words.target orelse named orelse words.no_agent orelse return null;
        const target = try text_utils.encodeTerminalSafe(scratch, raw_target, if (roster != null) 96 else 64);
        const label = switch (state) {
            .active, .pending => try alloc.print("{s} {s}", .{ words.doing, target.bytes }),
            .stopped => |reason| if (std.mem.eql(u8, reason, "Failed"))
                try alloc.print("couldn't {s} {s}", .{ words.verb, target.bytes })
            else
                try alloc.print("{s} {s}", .{ reason, target.bytes }),
            .identity, .completed, .feedback => try alloc.print("{s} {s}", .{ words.done, target.bytes }),
        };
        errdefer alloc.free(label);
        return .{ .label = label, .detail = try alloc.dupe(u8, "") };
    }
    // Otherwise only a message names a subagent and carries text to preview.
    if (!std.mem.eql(u8, action, "message")) return null;
    const raw_name = tool_args.optionalStringArg(args, "agent") orelse return null;
    const raw_preview = tool_args.optionalStringArg(args, "message") orelse return null;
    const name = try text_utils.encodeTerminalSafe(scratch, raw_name, 64);
    const preview = try subagentPreview(scratch, raw_preview);
    const label = switch (state) {
        .identity => try alloc.dupe(u8, name.bytes),
        .active => try alloc.print("{s} working", .{name.bytes}),
        .pending => try alloc.print("{s} still running", .{name.bytes}),
        // The message returns before the subagent works on it; its reply
        // arrives later, as a report.
        .completed => try alloc.print("sent to {s}", .{name.bytes}),
        .feedback => |delivery| try alloc.print("{s} feedback {s}", .{ name.bytes, switch (delivery) {
            .queued => "queued",
            .applied => "applied",
            .not_applied => "not applied",
        } }),
        .stopped => |reason| if (std.mem.eql(u8, reason, "Failed"))
            try alloc.print("{s} failed", .{name.bytes})
        else if (std.mem.eql(u8, reason, "Busy"))
            try alloc.print("{s} busy; message not sent", .{name.bytes})
        else if (std.mem.eql(u8, reason, "Cancelled") or std.mem.eql(u8, reason, "Interrupted"))
            try alloc.print("{s} interrupted", .{name.bytes})
        else
            try alloc.print("{s} {s}", .{ reason, name.bytes }),
    };
    errdefer alloc.free(label);
    const detail = if (preview.len == 0)
        try alloc.dupe(u8, "")
    else
        try alloc.print("· {s}", .{preview});
    return .{ .label = label, .detail = detail };
}

/// How a subagent row words an action other than a message: what it names
/// always (`target`), or when the call names no agent (`no_agent`).
const ActionWords = struct {
    verb: []const u8,
    doing: []const u8,
    done: []const u8,
    target: ?[]const u8 = null,
    no_agent: ?[]const u8 = null,
};

const action_words = std.StaticStringMap(ActionWords).initComptime(.{
    .{ "close", ActionWords{ .verb = "close", .doing = "closing", .done = "closed" } },
    .{ "stop", ActionWords{ .verb = "stop", .doing = "stopping", .done = "stopped" } },
    .{ "status", ActionWords{ .verb = "check", .doing = "checking", .done = "checked", .no_agent = "subagents" } },
    // A wait takes every report, whatever agent it names.
    .{ "wait", ActionWords{ .verb = "wait for", .doing = "waiting for", .done = "waited for", .target = "subagents" } },
});

/// Which of its caller's subagents a `subagent` call concerns when it
/// concerns them all, so its row can name them: those working for a `wait`,
/// whose reports it waits for, and every open one for a `status` that names
/// none. Null for any other call.
pub const SubagentRoster = enum { working, open };

pub fn subagentRoster(alloc: Allocator, call: ToolCall) Allocator.Error!?SubagentRoster {
    if (!std.mem.eql(u8, call.name, "subagent")) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const outer = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    const args = (try tool_args.unwrapRequest(scratch, outer)) orelse return null;
    const action = tool_args.optionalStringArg(args, "action") orelse return null;
    if (std.mem.eql(u8, action, "wait")) return .working;
    if (std.mem.eql(u8, action, "status") and namedAgent(args, action) == null) return .open;
    return null;
}

/// The `agent` a `subagent` call of `action` names, or null. The decoder reads
/// an empty `agent` on a `status` or a `wait` as none, so such a call's row
/// reads as it does without the key. A `stop`, `close`, or `message` needs an
/// agent, so for those an empty one stays as written.
fn namedAgent(args: std.json.ObjectMap, action: []const u8) ?[]const u8 {
    const agent = tool_args.optionalStringArg(args, "agent") orelse return null;
    const optional = std.mem.eql(u8, action, "status") or std.mem.eql(u8, action, "wait");
    return if (agent.len == 0 and optional) null else agent;
}

/// The `agent` a `subagent` call names, read from its arguments while they
/// still stream in and may stop anywhere: the `request` object's, or the
/// call's own when it has no `request`. Null until that name is a complete
/// string, and for a name with an escape in it, which a row would show
/// wrongly; the finished call's row names it once its arguments parse. The
/// result is a slice of `json`.
pub fn subagentStreamedAgent(json: []const u8) ?[]const u8 {
    return streamedStringField(json, "agent", 1, 2);
}

/// The value a builtin call's row names, read from its arguments while they
/// still stream in: the top-level string its label kind names, such as a
/// read's `path` or a web search's `query`. Null until that value is a
/// complete string, for one with an escape in it, and for the kinds whose
/// value is not such a string: a shell call's `action` and `command`, and
/// what `toolbox` and `subagent` calls name, which have their own readers.
/// The result is a slice of `json`.
pub fn streamedLabelValue(kind: tool_dispatch.LabelArgKind, json: []const u8) ?[]const u8 {
    return switch (kind) {
        .none, .action, .command, .session_id, .open, .run, .search => null,
        .name, .path, .pattern, .url, .description, .source, .resource, .query, .server, .selector => streamedStringField(json, @tagName(kind), 1, 1),
    };
}

/// What a `toolbox` call does, read from its arguments while they still
/// stream in: the first of its own `run`, `search`, and `open` keys whose
/// value is a whole string, with no escape in it, as a JSON object with that
/// one key, so its row can read as the finished call's will. A search with
/// no words yet may list one server's tools, so it waits. Null until then.
/// The caller owns the result.
pub fn toolboxStreamedAction(alloc: std.mem.Allocator, json: []const u8) !?[]const u8 {
    for ([_][]const u8{ "run", "search", "open" }) |key| {
        const value = streamedStringField(json, key, 1, 1) orelse continue;
        if (std.mem.eql(u8, key, "search") and std.mem.trim(u8, value, " \t\r\n").len == 0) continue;
        return try std.mem.concat(alloc, u8, &.{ "{\"", key, "\":\"", value, "\"}" });
    }
    return null;
}

/// The value of `key` in `json` at a depth from `min_depth` to `max_depth`,
/// read while the JSON still streams in and may stop anywhere. Null until
/// that value is a complete string, and for one with an escape in it, which
/// a row would show wrongly. The result is a slice of `json`.
fn streamedStringField(json: []const u8, key: []const u8, min_depth: usize, max_depth: usize) ?[]const u8 {
    // Each open object or array, so a key is known from a value.
    var containers: [8]u8 = undefined;
    var depth: usize = 0;
    var expect_key = false;
    var after_key = false;
    var i: usize = 0;
    while (i < json.len) {
        const byte = json[i];
        switch (byte) {
            '{', '[' => {
                if (depth == containers.len) return null;
                containers[depth] = byte;
                depth += 1;
                expect_key = byte == '{';
                after_key = false;
                i += 1;
            },
            '}', ']' => {
                if (depth == 0) return null;
                depth -= 1;
                expect_key = false;
                after_key = false;
                i += 1;
            },
            ',' => {
                expect_key = depth > 0 and containers[depth - 1] == '{';
                after_key = false;
                i += 1;
            },
            '"' => {
                const start = i + 1;
                var end = start;
                var escaped = false;
                while (end < json.len and json[end] != '"') {
                    if (json[end] == '\\') {
                        escaped = true;
                        end += 1;
                    }
                    end += 1;
                }
                // The string is still streaming in.
                if (end >= json.len) return null;
                const text = json[start..end];
                i = end + 1;
                if (expect_key) {
                    expect_key = false;
                    after_key = !escaped and depth >= min_depth and depth <= max_depth and std.mem.eql(u8, text, key);
                } else {
                    if (after_key) return if (escaped or text.len == 0) null else text;
                    after_key = false;
                }
            },
            ':', ' ', '\t', '\n', '\r' => i += 1,
            else => {
                // A number or literal is no name.
                after_key = false;
                i += 1;
            },
        }
    }
    return null;
}

test "a streaming toolbox call names its action once its whole value arrives" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, action: ?[]const u8 }{
        .{ .json = "", .action = null },
        .{ .json = "{\"run\":\"glob", .action = null },
        .{ .json = "{\"run\":\"glob_files\"", .action = "{\"run\":\"glob_files\"}" },
        .{ .json = "{\"run\":\"mcp_fixture_echo\",\"arguments\":{\"te", .action = "{\"run\":\"mcp_fixture_echo\"}" },
        .{ .json = "{\"search\":\"list fi", .action = null },
        .{ .json = "{\"search\":\"list files\"", .action = "{\"search\":\"list files\"}" },
        // An empty search may list one server's tools, so it waits.
        .{ .json = "{\"search\":\"\",\"ser", .action = null },
        .{ .json = "{\"open\":\"fixture\",\"res", .action = "{\"open\":\"fixture\"}" },
        // Only the call's own keys count, not ones inside its arguments.
        .{ .json = "{\"arguments\":{\"run\":\"x\"},\"run\":\"gl", .action = null },
        .{ .json = "{\"run\":\"a\\u001b[2J\"", .action = null },
    };
    for (cases) |case| {
        const got = try toolboxStreamedAction(alloc, case.json);
        defer if (got) |bytes| alloc.free(bytes);
        if (case.action) |want| {
            try std.testing.expectEqualStrings(want, got orelse return error.TestExpectedEqual);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

/// The preview a subagent row shows for `raw`: runs of whitespace, line
/// breaks included, become one space, made terminal-safe and cut to 120
/// bytes. Caller owns the result.
pub fn subagentPreview(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var buffer: [124]u8 = undefined;
    var len: usize = 0;
    var pending_space = false;
    // Bound scanning even when a large request contains only whitespace.
    const source = raw[0..text_utils.utf8BackwardBoundary(raw, @min(raw.len, 16 * 1024))];
    for (source) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = len > 0;
            continue;
        }
        if (pending_space) {
            buffer[len] = ' ';
            len += 1;
            pending_space = false;
        }
        if (len == buffer.len) break;
        buffer[len] = byte;
        len += 1;
        if (len == buffer.len) break;
    }
    const encoded = try text_utils.encodeTerminalSafe(alloc, buffer[0..len], 120);
    return encoded.bytes;
}

pub fn subagentStatusLine(alloc: Allocator, call: ToolCall, output: []const u8) Allocator.Error!?[]u8 {
    if (!std.mem.eql(u8, call.name, "subagent")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    // A wait, or a status that names no agent, names the subagents its
    // result lists, so the row reads the same live and after a resume.
    if (try subagentRoster(alloc, call) != null) {
        if (try resultRoster(alloc, parsed.value.object)) |names| {
            defer alloc.free(names);
            var named = call;
            named.resolved_display_target = names;
            return formatSubagentPlainAction(alloc, named, .completed);
        }
    }
    if (tool_args.optionalStringArg(parsed.value.object, "delivery")) |value| {
        const delivery = std.meta.stringToEnum(types.SteeringDelivery, value) orelse return null;
        const ok = parsed.value.object.get("ok") orelse return null;
        if (ok != .bool or ok.bool != (delivery != .not_applied)) return null;
        return formatSubagentPlainAction(alloc, call, .{ .feedback = delivery });
    }
    const pending = parsed.value.object.get("pending") orelse return null;
    if (pending != .bool or !pending.bool) return null;
    const ok = parsed.value.object.get("ok") orelse return null;
    if (ok != .bool or !ok.bool) return null;
    return formatSubagentPlainAction(alloc, call, .pending);
}

/// The subagents a successful result lists in `subagents`, joined with ", ",
/// or null when it lists none. The caller owns the result.
fn resultRoster(alloc: Allocator, result: std.json.ObjectMap) Allocator.Error!?[]u8 {
    const ok = result.get("ok") orelse return null;
    if (ok != .bool or !ok.bool) return null;
    const listed = result.get("subagents") orelse return null;
    if (listed != .array or listed.array.items.len == 0) return null;
    const names = try alloc.alloc([]const u8, listed.array.items.len);
    defer alloc.free(names);
    for (listed.array.items, names) |name, *slot| {
        if (name != .string) return null;
        slot.* = name.string;
    }
    return try std.mem.join(alloc, ", ", names);
}

/// Only structured child terminal failures change the failure label.
pub fn subagentFailureLabel(alloc: Allocator, call: ToolCall, output: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.eql(u8, call.name, "subagent")) return "Failed";
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "Failed",
    };
    defer parsed.deinit();
    if (parsed.value != .object) return "Failed";
    const ok = parsed.value.object.get("ok") orelse return "Failed";
    if (ok != .bool or ok.bool) return "Failed";
    const code = tool_args.optionalStringArg(parsed.value.object, "error_code") orelse return "Failed";
    if (std.mem.eql(u8, code, "child_busy")) return "Busy";
    for ([_][]const u8{ "feedback_capacity", "operation_conflict", "override_after_create" }) |rejection| {
        if (std.mem.eql(u8, code, rejection)) return "Message not sent to";
    }
    return if (std.mem.eql(u8, code, "child_cancelled") or std.mem.eql(u8, code, "child_interrupted") or std.mem.eql(u8, code, "child_lost")) "Interrupted" else "Failed";
}

/// The caller owns the returned plain subagent row.
pub fn formatSubagentPlainAction(alloc: Allocator, call: ToolCall, state: SubagentActionState) Allocator.Error!?[]u8 {
    const action = try subagentAction(alloc, call, state) orelse return null;
    defer action.deinit(alloc);
    return try alloc.print("{s}{s}{s}", .{ action.label, if (action.detail.len == 0) "" else " ", action.detail });
}

pub const RunCommandActivity = struct {
    detail: []const u8,
    compatibility_tool: ?*const tool_dispatch.Tool,
};

pub fn isProviderSearchAlias(name: []const u8) bool {
    return std.mem.eql(u8, name, "exa_search") or
        std.mem.eql(u8, name, "perplexity_search") or
        std.mem.eql(u8, name, "parallel_search");
}

fn projectRunCommandActivitySource(
    command: []const u8,
    workspace_root_input: []const u8,
    storage: []u8,
) []const u8 {
    const display_command = stripNoopCurrentDirectoryPrefix(command);
    var workspace_root_end = workspace_root_input.len;
    while (workspace_root_end > 1 and workspace_root_input[workspace_root_end - 1] == '/') {
        workspace_root_end -= 1;
    }
    const workspace_root = workspace_root_input[0..workspace_root_end];
    const can_abbreviate_workspace = workspace_root.len > 1 and workspace_root[0] == '/';
    const source_limit = @min(display_command.len, max_run_command_activity_source_bytes);
    var source_index: usize = 0;
    var projected_len: usize = 0;
    var line_boundary_pending = false;

    while (source_index < source_limit) {
        const byte = display_command[source_index];
        if (byte == '\r' or byte == '\n') {
            line_boundary_pending = true;
            source_index += 1;
            continue;
        }
        if (line_boundary_pending and (byte == ' ' or byte == '\t')) {
            source_index += 1;
            continue;
        }
        if (line_boundary_pending) {
            line_boundary_pending = false;
            if (projected_len > 0) {
                storage[projected_len] = ' ';
                projected_len += 1;
                if (projected_len == storage.len) break;
            }
        }

        if (can_abbreviate_workspace and
            workspace_root.len <= source_limit - source_index and
            workspaceRootMatchesAt(display_command, workspace_root, source_index))
        {
            storage[projected_len] = '.';
            projected_len += 1;
            if (projected_len == storage.len) break;
            source_index += workspace_root.len;
            continue;
        }

        storage[projected_len] = byte;
        projected_len += 1;
        if (projected_len == storage.len) break;
        source_index += 1;
    }

    return storage[0..projected_len];
}

fn stripNoopCurrentDirectoryPrefix(command: []const u8) []const u8 {
    const prefix = "cd . &&";
    if (!std.mem.startsWith(u8, command, prefix)) return command;
    if (command.len == prefix.len or !std.ascii.isWhitespace(command[prefix.len])) return command;

    const remainder = std.mem.trimStart(u8, command[prefix.len..], " \t\r\n");
    return if (remainder.len > 0) remainder else command;
}

fn workspaceRootMatchesAt(command: []const u8, workspace_root: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, command[index..], workspace_root)) return false;
    if (index > 0 and isPathTokenByte(command[index - 1])) return false;

    const next_index = index + workspace_root.len;
    if (next_index == command.len) return true;
    return command[next_index] == '/' or !isPathTokenByte(command[next_index]);
}

fn containsUnresolvedAbsolutePath(command: []const u8) bool {
    for (command, 0..) |byte, index| {
        if (byte != '/' or (index > 0 and isPathTokenByte(command[index - 1]))) continue;
        const suffix = command[index..];
        if (std.mem.startsWith(u8, suffix, "/dev/null") and
            (suffix.len == "/dev/null".len or !isPathTokenByte(suffix["/dev/null".len])))
        {
            continue;
        }
        return true;
    }
    return false;
}

fn isPathTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatRunCommandPermissionLabel(
    alloc: Allocator,
    command: []const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const encoded = try text_utils.encodeTerminalSafe(
        scratch,
        command,
        max_run_command_activity_bytes,
    );
    const suffix = try commandApprovalLabelSuffix(scratch, "shell", command);
    return alloc.print("shell.run {s}{s}", .{ encoded.bytes, suffix });
}

pub fn isAdvertisedDynamicMcpName(registry: tool_dispatch.Registry, name: []const u8, advertised: []const []const u8) bool {
    if (registry.lookup(name) != null) return false;
    for (advertised) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) return true;
    }
    return false;
}

/// Returns a borrowed static label when the call is a captured command.
pub fn runCommandCompletedActionLabel(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object or !isCapturedCommandCall(registry, call, parsed.value.object)) return null;
    const command = tool_args.optionalStringArg(parsed.value.object, "command") orelse return null;
    return if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched|
        matched.tool.completed_action_label
    else
        "Ran";
}

pub fn formatRunCommandActivity(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) !?RunCommandActivity {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const detail = (try formatRunCommandDetailBounded(
        alloc,
        command,
        workspace_root,
        max_run_command_activity_bytes,
    )) orelse return null;
    return .{
        .detail = detail,
        .compatibility_tool = if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched| matched.tool else null,
    };
}

/// Formats a session launch command with the live terminal display target
/// projection's 120-byte budget, for replayed history where the live session
/// rows no longer exist. Returns null when `workspace_root` is empty and the
/// command contains an unresolved absolute path, matching the historical
/// command display guard; the caller falls back to the raw session id.
/// The caller owns the returned allocation.
pub fn formatHistoricalTerminalDisplayTarget(
    alloc: Allocator,
    command: []const u8,
    workspace_root: []const u8,
) !?[]u8 {
    return formatRunCommandDetailBounded(alloc, command, workspace_root, max_run_command_activity_bytes);
}

pub fn formatRunCommandDetailBounded(
    alloc: Allocator,
    command: []const u8,
    workspace_root: []const u8,
    max_encoded_bytes: usize,
) !?[]u8 {
    if (max_encoded_bytes == 0) return try alloc.dupe(u8, "");
    if (workspace_root.len == 0 and containsUnresolvedAbsolutePath(command)) return null;

    const effective_max = @min(max_encoded_bytes, max_run_command_activity_source_bytes - 1);
    const projected_storage = try alloc.alloc(u8, effective_max + 1);
    defer alloc.free(projected_storage);
    const projected = projectRunCommandActivitySource(command, workspace_root, projected_storage);
    const encoded = try text_utils.encodeTerminalSafe(alloc, projected, effective_max);
    return encoded.bytes;
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalDisplayTargetFromRows(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
    rows: []const terminal_ui_projection.Row,
    max_encoded_bytes: usize,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        rows,
        max_encoded_bytes,
    ));
}

fn terminalDisplayTargetSessionId(
    scratch: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) ?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    const args = tool_args.parseToolArgsObject(
        scratch,
        call.arguments_json,
    ) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return tool_args.optionalStringArg(args, "session_id");
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalSessionTargetFromRows(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    rows: []const terminal_ui_projection.Row,
    max_encoded_bytes: usize,
) ![]const u8 {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.session_id, session_id)) continue;
        if (row.label.len == 0 or std.mem.eql(u8, row.label, session_id)) break;
        return try formatTerminalDisplayTarget(
            alloc,
            workspace_root,
            row.label,
            max_encoded_bytes,
        );
    }

    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        session_id,
        max_encoded_bytes -| "session ".len,
    );
    defer encoded.deinit(alloc);
    return try alloc.print("session {s}", .{encoded.bytes});
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTarget(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    managed_executions: ?*managed_execution.Runtime,
    call: ToolCall,
) !?[]const u8 {
    return resolveTerminalDisplayTargetBounded(
        alloc,
        registry,
        workspace_root,
        terminal_client,
        managed_executions,
        call,
        max_run_command_activity_bytes,
    );
}

/// Resolves the session launch command at a caller-chosen storage bound. The
/// status line keeps the compact activity bound; the transcript stores the
/// reflow-bound variant so group projection can reclip to the live width.
/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTargetBounded(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    managed_executions: ?*managed_execution.Runtime,
    call: ToolCall,
    max_encoded_bytes: usize,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer mem_utils.deinit_arena(scratch_state);
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    if (managed_executions) |executions| {
        if (try executions.captured_command_alloc(alloc, session_id)) |command| {
            defer alloc.free(command);
            if (command.len != 0) return try formatTerminalDisplayTarget(alloc, workspace_root, command, max_encoded_bytes);
        }
    }
    const runtime = terminal_client orelse return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        &.{},
        max_encoded_bytes,
    ));
    var snapshot = try runtime.terminalProjection(std.heap.c_allocator);
    defer snapshot.deinit();
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        snapshot.rows,
        max_encoded_bytes,
    ));
}

/// Returns the completed-action label a terminal-session call (interact,
/// stop) will use on its settled status line, or null when the call does not
/// present a session target. Borrows registry storage; no free needed.
pub fn terminalSessionCompletedActionLabel(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const args = tool_args.parseToolArgsObject(scratch_state.allocator(), call.arguments_json) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return presentation.completed_action_label;
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn formatTerminalDisplayTarget(
    alloc: Allocator,
    workspace_root: []const u8,
    raw: []const u8,
    max_encoded_bytes: usize,
) ![]u8 {
    if (max_encoded_bytes == 0) return try alloc.dupe(u8, "");
    const effective_max = @min(max_encoded_bytes, max_run_command_activity_source_bytes - 1);
    const projected_storage = try alloc.alloc(u8, effective_max + 1);
    defer alloc.free(projected_storage);
    const projected = projectRunCommandActivitySource(
        raw,
        workspace_root,
        projected_storage,
    );
    const encoded = try text_utils.encodeTerminalSafe(
        alloc,
        projected,
        effective_max,
    );
    return encoded.bytes;
}

/// The action label of an MCP tool's row while it runs, and once it ran.
pub const mcp_running_label = "Running MCP";
pub const mcp_ran_label = "Ran MCP";

/// A tool row's status line: a bold label, then the value in tool text.
pub fn formatToolActionValue(alloc: Allocator, label: []const u8, value: []const u8) Allocator.Error![]u8 {
    return alloc.print("● {s}\x1b[0m {s}{s}\x1b[0m", .{ label, shared_theme.current().tool_stdout_style, value });
}

/// The label of the row a call made through `spark mcp call` ends with.
pub fn bridgeCallRowLabel(outcome: types.BridgeCallOutcome) []const u8 {
    return switch (outcome) {
        .completed => mcp_ran_label,
        .cancelled => "Cancelled",
        .failed => "Failed",
    };
}

/// The status line of a call made through `spark mcp call` once it ended, the
/// same live and when a resume shows the row again.
pub fn bridgeCallRowSummary(alloc: Allocator, tool: []const u8, outcome: types.BridgeCallOutcome) Allocator.Error![]u8 {
    return formatToolActionValue(alloc, bridgeCallRowLabel(outcome), tool);
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPlainAction(alloc: Allocator, input: ToolActionInput) ![]const u8 {
    const call = input.call;
    if (input.tool_registry.lookup(call.name) != null) {
        if (try formatSubagentPlainAction(alloc, call, .active)) |line| return line;
    }
    if (file_mutation_contract.isToolName(call.name)) {
        const spec = input.tool_registry.lookup(call.name) orelse
            return alloc.print("Working: {f}", .{text_utils.terminalSafe(call.name)});
        return alloc.print(
            "{s} {f}",
            .{ spec.action_label, text_utils.terminalSafe(input.display_target orelse spec.label_arg_default) },
        );
    }

    if (try formatRunCommandActivity(alloc, input.tool_registry, input.workspace_root, call)) |activity| {
        defer alloc.free(activity.detail);
        const action_label = if (activity.compatibility_tool) |tool| tool.action_label else "Running";
        return alloc.print("{s} {f}", .{ action_label, text_utils.terminalSafe(activity.detail) });
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    const spec = input.tool_registry.lookup(call.name) orelse {
        if (isProviderSearchAlias(call.name)) {
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
                return alloc.print("Searching web", .{});
            };
            return alloc.print("Searching {f}", .{text_utils.terminalSafe(try formatWebSearchActionDetail(scratch, args))});
        }
        if (input.is_available_dynamic_mcp_tool) return alloc.print("MCP: {f}", .{text_utils.terminalSafe(call.name)});
        return alloc.print("Working: {f}", .{text_utils.terminalSafe(call.name)});
    };
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return alloc.print("Working: {f}", .{text_utils.terminalSafe(call.name)});
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (spec.executor_kind == .web_search) {
        return alloc.print("{s} {f}", .{ presentation.action_label, text_utils.terminalSafe(try formatWebSearchActionDetail(scratch, args)) });
    }
    const value = input.display_target orelse
        call.resolved_display_target orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    // The value is what the model asked for, such as a toolbox open's target,
    // so a control sequence in it is written as visible text.
    return alloc.print("{s} {f}", .{ presentation.action_label, text_utils.terminalSafe(value) });
}

/// Names an earlier call in the row of a later call that reads its saved
/// output: the command it ran, the path or URL it read, or the name of an MCP
/// tool. Returns null when the call has none of these, or when its command
/// cannot be described, so a label never fails the turn that shows it. The
/// text is terminal-safe. The caller owns the returned allocation.
pub fn savedOutputSourceLabel(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) Allocator.Error!?[]const u8 {
    const command_activity = formatRunCommandActivity(alloc, registry, workspace_root, call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (command_activity) |activity| return activity.detail;
    const spec = registry.lookup(call.name) orelse {
        if (isProviderSearchAlias(call.name)) return null;
        return try encodeSourceLabel(alloc, call.name);
    };
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const args = tool_args.parseToolArgsObject(scratch_state.allocator(), call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    switch (presentation.label_arg_kind) {
        .path, .url => {},
        else => return null,
    }
    const value = tool_dispatch.presentationLabelValue(presentation, args) orelse return null;
    return try encodeSourceLabel(alloc, value);
}

fn encodeSourceLabel(alloc: Allocator, raw: []const u8) ![]const u8 {
    const encoded = try text_utils.encodeTerminalSafe(alloc, raw, max_run_command_activity_bytes);
    return encoded.bytes;
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPermissionLabel(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    if (try runCommandCompatibilitySource(scratch, registry, call)) |source| {
        return alloc.print("{s} {s}", .{ source.tool.name, source.command });
    }
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return try alloc.dupe(u8, call.name);
    };
    if (isCapturedCommandCall(registry, call, args)) {
        const command = tool_args.optionalStringArg(args, "command") orelse
            return try alloc.dupe(u8, call.name);
        return formatRunCommandPermissionLabel(alloc, command);
    }
    const spec = registry.lookup(call.name) orelse return try alloc.dupe(u8, call.name);
    if (file_mutation_contract.isToolName(call.name)) {
        return alloc.print(
            "{s} {s}",
            .{ call.name, spec.label_arg_default },
        );
    }
    const value = tool_dispatch.toolLabelValue(spec.*, args) orelse return try alloc.dupe(u8, call.name);

    if (spec.label_arg_kind == .command) {
        const suffix = try commandApprovalLabelSuffix(scratch, call.name, value);
        if (tool_args.optionalStringArg(args, "cwd")) |cwd| {
            return alloc.print("{s} {s} @ {s}{s}", .{ call.name, value, cwd, suffix });
        }
        return alloc.print("{s} {s}{s}", .{ call.name, value, suffix });
    }

    return alloc.print("{s} {s}", .{ call.name, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchActionDetail(alloc: Allocator, args: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var label_buf: [160]u8 = undefined;
    const query = tool_args.optionalStringArg(args, "query") orelse "web";
    try out.writer.writeAll(text_utils.clippedLabel(&label_buf, query, 120));
    try appendWebSearchDomains(&out.writer, "allowed", args.get("allowed_domains"));
    try appendWebSearchDomains(&out.writer, "blocked", args.get("blocked_domains"));
    return try out.toOwnedSlice();
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchProgressPlain(alloc: Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| alloc.print(
            "Searching {s}",
            .{text_utils.clippedLabel(&query_buf, query, 120)},
        ),
        .results_received => |entry| alloc.print(
            "Found {d} result{s} for {s}",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebFetchProgressPlain(alloc: Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| alloc.print("Fetching {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
        .converting => |url| alloc.print("Converting {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
    };
}

fn appendWebSearchDomains(writer: *std.Io.Writer, label: []const u8, value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array or array.array.items.len == 0) return;
    try writer.print(" | {s}: ", .{label});
    var domain_buf: [64]u8 = undefined;
    const shown = @min(array.array.items.len, 3);
    for (array.array.items[0..shown], 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        if (item != .string) {
            try writer.writeAll("?");
            continue;
        }
        try writer.writeAll(text_utils.clippedLabel(&domain_buf, item.string, 48));
    }
    if (array.array.items.len > shown) try writer.print(" +{d}", .{array.array.items.len - shown});
}

fn commandApprovalLabelSuffix(alloc: Allocator, tool_name: []const u8, command: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, tool_name, "run_command") and
        !std.mem.eql(u8, tool_name, "terminal") and
        !std.mem.eql(u8, tool_name, "shell")) return "";
    const risk = command_policy.command_risk_note_for(command);
    const safer = command_policy.command_safer_alternative_for(command);
    if (risk == null and safer == null) return "";
    const risk_text = if (risk) |note| stripNotePrefix(note) else null;
    if (risk_text) |note| {
        if (safer) |alternative| {
            return alloc.print(" (risk: {s}; {s})", .{ note, alternative });
        }
        return alloc.print(" (risk: {s})", .{note});
    }
    if (safer) |alternative| {
        return alloc.print(" ({s})", .{alternative});
    }
    return "";
}

fn stripNotePrefix(note: []const u8) []const u8 {
    const prefix = "note: ";
    if (std.mem.startsWith(u8, note, prefix)) return note[prefix.len..];
    return note;
}

const RunCommandCompatibilitySource = struct {
    tool: *const tool_dispatch.Tool,
    command: []const u8,
};

fn runCommandCompatibilitySource(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?RunCommandCompatibilitySource {
    const args = tool_args.parseToolArgsObject(alloc, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const matched = (try tool_dispatch.matchRunCommandCompatibility(registry, command)) orelse return null;
    return .{ .tool = matched.tool, .command = command };
}

fn isCapturedCommandCall(
    registry: tool_dispatch.Registry,
    call: ToolCall,
    args: std.json.ObjectMap,
) bool {
    // Historical sessions retain their original tool name. Presentation may
    // interpret those records, but execution remains unavailable because the
    // registry no longer contains a `run_command` tool.
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected = tool.captured_command_action orelse return false;
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected);
}

fn matchesTestSkillInstall(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "npx skills add ");
}

fn executeTestSkillInstall(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "installed") };
}

const test_install_skill = blk: {
    var tool = test_builtin_tools.install_skill;
    tool.name = "install_skill";
    tool.model_schema.name = "install_skill";
    tool.executor_kind = .install_skill;
    tool.activity_kind = .write;
    tool.requires_approval = true;
    tool.action_label = "Installing skill";
    tool.completed_action_label = "Installed skill";
    tool.label_arg_kind = .source;
    tool.label_arg_default = "skill";
    tool.run_command_compatibility = .{
        .matches = matchesTestSkillInstall,
        .execute = executeTestSkillInstall,
    };
    break :blk tool;
};

const test_web_search = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "web_search";
    tool.model_schema.name = "web_search";
    tool.executor_kind = .web_search;
    tool.action_label = "Searching";
    tool.completed_action_label = "Searched";
    tool.label_arg_kind = .query;
    tool.label_arg_default = "web";
    break :blk tool;
};

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_web_search,
    test_builtin_tools.shell,
    test_install_skill,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_presentation_tool = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "custom_presentation";
    tool.action_label = "Inspecting";
    tool.label_arg_kind = .name;
    tool.label_arg_default = "custom fallback";
    break :blk tool;
};
const custom_presentation_registry = tool_dispatch.Registry{ .tools = &.{custom_presentation_tool} };

fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, needle) != null);
}
