const std = @import("std");
const builtin = @import("builtin");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const pathing = @import("../workspace/pathing.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const permissions = @import("../permissions/permissions.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub const HostSandboxDefault = enum {
    none,
    allow_sandboxed,
    prompt,
};

/// What admission needs to bind a tool call to its execution authority.
/// spark always runs with full access, so admission never asks or denies:
/// it only resolves what the call will act on.
pub const Input = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    tool_registry: tool_dispatch.Registry,
    advertised_dynamic_tool_names: []const []const u8,
    mcp_runtime: tool_mcp_runtime.RuntimeCapabilities,
    context_limits: context_limits.Values = .{},
};

fn registeredTool(input: Input, name: []const u8) ?*const tool_dispatch.Tool {
    return input.tool_registry.lookup(name);
}

fn accessScope(input: Input) workspace_access.AccessScope {
    return input.access_scope orelse workspace_access.AccessScope.primaryOnly(input.workspace_root);
}

pub fn callUsesCommandAuthority(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected_action = tool.captured_command_action orelse return false;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected_action);
}

fn isRunCommandCall(input: Input, arena: Allocator, call: ToolCall) !bool {
    return callUsesCommandAuthority(input.tool_registry, arena, call);
}

fn registeredWebSearchTarget(input: Input, name: []const u8) ?[]const u8 {
    const spec = registeredTool(input, name) orelse return null;
    if (spec.executor_kind != .web_search) return null;
    return spec.name;
}

pub const FileMutationPreflight = union(enum) {
    allowed: file_mutation_contract.FileExecutionAuthorization,
    tool_failure: []const u8,
};

pub const FileMutationPreflightRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
};

pub const FileMutationPreparationRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
};

pub const PreparedFileMutationCall = struct {
    call_id: []u8,
    arguments_hash: types.ContentHash,
    workspace_root: []u8,
    input: file_mutation_contract.FileMutationInput,
    targets: file_mutation_contract.ResolvedFileMutationTargets,
    workspace_root_owned: bool = true,
    call_id_owned: bool = true,
    input_owned: bool = true,

    pub fn targetPath(self: PreparedFileMutationCall) []const u8 {
        return self.targets.canonical_target_path;
    }

    pub fn externalActionIdentity(
        self: PreparedFileMutationCall,
    ) ?FileMutationActionIdentity {
        if (self.targets.anchor.scope != .external) return null;
        return FileMutationActionIdentity.init(
            self.targets.canonical_target_path,
            self.input,
        );
    }

    pub fn deinit(self: *PreparedFileMutationCall, alloc: Allocator) void {
        if (self.input_owned) {
            self.input.deinit(alloc);
            self.input_owned = false;
        }
        self.targets.deinit(alloc);
        if (self.call_id_owned) {
            alloc.free(self.call_id);
            self.call_id_owned = false;
        }
        if (self.workspace_root_owned) {
            alloc.free(self.workspace_root);
            self.workspace_root_owned = false;
        }
    }

    fn takeInput(self: *PreparedFileMutationCall) file_mutation_contract.FileMutationInput {
        std.debug.assert(self.input_owned);
        self.input_owned = false;
        return self.input;
    }

    fn takeTargets(self: *PreparedFileMutationCall) file_mutation_contract.ResolvedFileMutationTargets {
        std.debug.assert(self.targets.owns_memory);
        const targets = self.targets;
        self.targets.relinquish();
        return targets;
    }
};

/// Canonical, provider-call-ID-independent identity for one external file
/// mutation request. The fixed-size value is safe to retain for one agent turn
/// without retaining decoded tool inputs or filesystem proof allocations.
pub const FileMutationActionIdentity = struct {
    kind: file_mutation_contract.Kind,
    target_hash: types.ContentHash,
    first_argument_hash: types.ContentHash,
    second_argument_hash: types.ContentHash,

    fn init(
        canonical_target_path: []const u8,
        input: file_mutation_contract.FileMutationInput,
    ) FileMutationActionIdentity {
        var identity: FileMutationActionIdentity = .{
            .kind = std.meta.activeTag(input),
            .target_hash = hashIdentityField(canonical_target_path),
            .first_argument_hash = undefined,
            .second_argument_hash = undefined,
        };
        switch (input) {
            .write => |write| {
                identity.first_argument_hash = hashIdentityField(write.content);
                identity.second_argument_hash = hashIdentityField(
                    "write-file-no-second-argument",
                );
            },
            .edit => |edit| {
                identity.first_argument_hash = hashIdentityField(edit.old_string);
                identity.second_argument_hash = hashIdentityField(edit.new_string);
            },
        }
        return identity;
    }

    pub fn eql(
        a: FileMutationActionIdentity,
        b: FileMutationActionIdentity,
    ) bool {
        return std.meta.eql(a, b);
    }
};

fn hashIdentityField(value: []const u8) types.ContentHash {
    var digest: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return digest;
}

pub const FileMutationPreparation = union(enum) {
    prepared: PreparedFileMutationCall,
    tool_failure: []const u8,
    /// The name matches the file-mutation contract but the registered tool is
    /// a host-supplied executor (e.g. an embedder's own `write_file`), so the
    /// builtin mutation contract does not apply and the caller must fall back
    /// to ordinary dispatch.
    not_file_mutation,
};

const FileMutationDecodeResult = union(enum) {
    input: file_mutation_contract.FileMutationInput,
    failure: []const u8,
    /// Registered, but executed by the host rather than the builtin file
    /// mutation implementation.
    not_file_mutation,
};

var file_mutation_decode_count: usize = 0;
var file_mutation_resolution_count: usize = 0;

fn decodeFileMutationInput(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !FileMutationDecodeResult {
    const tool = registry.lookup(call.name) orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool is not registered",
        ),
    };
    const kind: file_mutation_contract.Kind = switch (tool.executor_kind) {
        .write_file => .write,
        .edit_file => .edit,
        // A host tool may reuse the reserved names; it is not the builtin
        // mutation, so the contract steps aside instead of failing the call.
        .host => return .not_file_mutation,
        else => return .{ .failure = try arena.dupe(
            u8,
            "unsupported file mutation tool",
        ) },
    };
    const take_input = tool.take_file_mutation_input_fn orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool registration is missing canonical input ownership",
        ),
    };

    if (builtin.is_test) file_mutation_decode_count += 1;
    const decode_ctx = tool_dispatch.DispatchContext{ .allocator = arena };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |tool_input| blk: {
            var tool_input_owned = true;
            defer if (tool_input_owned) tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    break :blk .{ .failure = reason };
                }
            }
            var input = take_input(tool_input, arena);
            tool_input_owned = false;
            if (std.meta.activeTag(input) != kind) {
                input.deinit(arena);
                break :blk .{ .failure = try arena.dupe(
                    u8,
                    "file mutation tool registration returned mismatched input kind",
                ) };
            }
            break :blk .{ .input = input };
        },
    };
}

pub fn prepareFileMutationCall(
    alloc: Allocator,
    call: ToolCall,
    request: FileMutationPreparationRequest,
) !FileMutationPreparation {
    var input = switch (try decodeFileMutationInput(
        alloc,
        request.tool_registry,
        call,
    )) {
        .failure => |reason| return .{ .tool_failure = reason },
        .not_file_mutation => return .not_file_mutation,
        .input => |value| value,
    };
    var input_owned = true;
    defer if (input_owned) input.deinit(alloc);

    if (builtin.is_test) file_mutation_resolution_count += 1;
    var targets = switch (try permissions.prepareFileMutationTargets(
        alloc,
        request.workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .tool_failure = try alloc.print(
            "file mutation target resolution failed: {s}",
            .{@tagName(failure)},
        ) },
        .prepared => |value| value,
    };
    errdefer targets.deinit(alloc);

    const workspace_root = try alloc.dupe(u8, request.workspace_root);
    errdefer alloc.free(workspace_root);
    const call_id = try alloc.dupe(u8, call.id);
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    input_owned = false;
    return .{ .prepared = .{
        .call_id = call_id,
        .arguments_hash = arguments_hasher.finalResult(),
        .workspace_root = workspace_root,
        .input = input,
        .targets = targets,
    } };
}

pub fn preflightPreparedFileMutation(
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    defer prepared.deinit(arena);

    const expected_kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    if (std.meta.activeTag(prepared.input) != expected_kind or
        !std.mem.eql(u8, prepared.call_id, call.id) or
        !std.mem.eql(u8, prepared.workspace_root, request.workspace_root))
    {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    if (!std.mem.eql(u8, &prepared.arguments_hash, &arguments_hasher.finalResult())) {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }

    var input = prepared.takeInput();
    var input_owned = true;
    defer if (input_owned) input.deinit(arena);
    var targets = prepared.takeTargets();

    const policy_targets = switch (try permissions.authorizePreparedFileMutationTargets(arena, &targets)) {
        .target_resolution_failure => |failure| {
            return .{ .tool_failure = try arena.print(
                "file mutation target resolution failed: {s}",
                .{@tagName(failure)},
            ) };
        },
        .policy_denied => return .{ .tool_failure = "file mutation target could not be authorized" },
        .evaluated => |evaluated| evaluated,
    };
    input_owned = false;
    return .{ .allowed = .{
        .input = input,
        .policy_targets = policy_targets,
        .edit_failure_detail = .file_lines,
    } };
}

pub fn preflightFileMutation(
    arena: Allocator,
    call: ToolCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = request.tool_registry,
        .workspace_root = request.workspace_root,
    })) {
        .tool_failure => |reason| return .{ .tool_failure = reason },
        // The preflight contract only exists for the builtin file mutations;
        // a host tool that reused the name cannot be preflighted through it.
        .not_file_mutation => return .{ .tool_failure = "file mutation preflight is unavailable for host tools" },
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    return preflightPreparedFileMutation(arena, call, &prepared, request);
}

pub fn requestPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !command_admission.PermissionOutcome {
    if (file_mutation_contract.isToolName(call.name) and
        // A host tool that reuses a reserved name executes through the host
        // executor, not the builtin file mutation, so it follows the ordinary
        // registered-tool path. A missing registry entry keeps the contract's
        // own failure handling.
        (input.tool_registry.lookup(call.name) == null or
            input.tool_registry.lookup(call.name).?.executor_kind != .host))
    {
        return fileMutationOutcome(try preflightFileMutation(arena, call, .{
            .tool_registry = input.tool_registry,
            .workspace_root = input.workspace_root,
            .access_scope = input.access_scope,
        }));
    }
    const is_mcp_tool = isAvailableDynamicTool(input, call.name);
    const command_call = try isRunCommandCall(input, arena, call);
    if (registeredTool(input, call.name) == null and !is_mcp_tool and !command_call) {
        return ordinaryPermissionOutcome(.once);
    }
    var targets = permissionTargetsForCall(input, arena, call) catch |err| {
        if (try permissionTargetResolutionFailureMessage(arena, call, err)) |failure| {
            return .{ .tool_failure = failure };
        }
        return err;
    };
    defer targets.deinit(arena);
    const vision_path_authority = visionPathExecutionAuthority(
        arena,
        call,
        targets.items,
    ) catch |err| switch (err) {
        error.InvalidToolArguments => return .{
            .tool_failure = "Vision paths must reference regular files.",
        },
        else => return err,
    };
    return bindVisionPathExecutionAuthority(
        try permissionOutcomeForDecision(input, arena, call, .once, .yolo),
        vision_path_authority,
    );
}

/// Binds the exact child action to the current live authority again. The
/// refreshed authority must match what the action was prepared under.
pub fn revalidateLiveActionPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
) !command_admission.PermissionOutcome {
    return switch (authority) {
        .ordinary, .file_mutation => try requestPermissionOutcome(input, arena, call),
        .run_command => |expected| blk: {
            const outcome = try requestPermissionOutcome(input, arena, call);
            if (!outcome.decision.isDenied()) {
                const actual = switch (outcome.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .run_command => |value| value,
                    .ordinary, .file_mutation, .vision_paths => break :blk invalidLiveActionOutcome(),
                };
                if (!commandAuthorityFingerprint(expected).eql(
                    commandAuthorityFingerprint(actual),
                )) break :blk invalidLiveActionOutcome();
            }
            break :blk outcome;
        },
        .vision_paths => |expected| blk: {
            const canonical_call = try canonicalVisionPathCall(arena, call, expected);
            const refreshed = try requestPermissionOutcome(input, arena, canonical_call);
            if (!refreshed.decision.isDenied()) {
                const actual = switch (refreshed.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .vision_paths => |value| value,
                    .ordinary, .run_command, .file_mutation => break :blk invalidLiveActionOutcome(),
                };
                if (!visionPathAuthoritiesEqual(expected, actual)) {
                    break :blk invalidLiveActionOutcome();
                }
            }
            break :blk refreshed;
        },
    };
}

fn commandAuthorityFingerprint(
    authority: command_admission.CommandExecutionAuthority,
) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

fn canonicalVisionPathCall(
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.VisionPathExecutionAuthority,
) !ToolCall {
    var request = try vision_contracts.parse_vision_request(arena, call.arguments_json);
    defer request.deinit(arena);
    const paths = request.paths() orelse return error.InvalidToolArguments;
    if (paths.len != authority.targets.len) return error.InvalidToolArguments;

    const canonical_paths = try arena.alloc([]const u8, authority.targets.len);
    for (authority.targets, canonical_paths) |target, *canonical_path| {
        canonical_path.* = target.canonical_path;
    }

    var arguments: std.Io.Writer.Allocating = .init(arena);
    defer arguments.deinit();
    try arguments.writer.writeAll("{\"paths\":");
    try std.json.Stringify.value(canonical_paths, .{}, &arguments.writer);
    try arguments.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(request.focus, .{}, &arguments.writer);
    try arguments.writer.writeByte('}');
    return .{
        .id = call.id,
        .name = call.name,
        .arguments_json = try arguments.toOwnedSlice(),
    };
}

fn visionPathAuthoritiesEqual(
    expected: command_admission.VisionPathExecutionAuthority,
    actual: command_admission.VisionPathExecutionAuthority,
) bool {
    if (expected.targets.len != actual.targets.len) return false;
    for (expected.targets, actual.targets) |expected_target, actual_target| {
        if (!std.mem.eql(
            u8,
            expected_target.canonical_path,
            actual_target.canonical_path,
        ) or !std.meta.eql(expected_target.identity, actual_target.identity)) {
            return false;
        }
    }
    return true;
}

fn invalidLiveActionOutcome() command_admission.PermissionOutcome {
    return .{
        .decision = .policy_denied,
        .denial_reason = .policy_denied,
        .tool_failure = "live authority no longer matches the prepared action",
    };
}

pub fn requestPreparedFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
) !command_admission.PermissionOutcome {
    return fileMutationOutcome(try preflightPreparedFileMutation(arena, call, prepared, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    }));
}

fn fileMutationOutcome(preflight: FileMutationPreflight) command_admission.PermissionOutcome {
    return switch (preflight) {
        .tool_failure => |reason| .{ .tool_failure = reason },
        .allowed => |authorization| .{
            .decision = .once,
            .execution_authority = .{ .file_mutation = authorization },
        },
    };
}

fn ordinaryPermissionOutcome(decision: ToolPermissionDecision) command_admission.PermissionOutcome {
    return .{
        .decision = decision,
        .execution_authority = if (decision.isDenied()) null else .ordinary,
    };
}

fn visionPathExecutionAuthority(
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
) !?command_admission.VisionPathExecutionAuthority {
    if (!std.mem.eql(u8, call.name, "vision") or
        targets.len == 0 or
        !std.mem.eql(u8, targets[0].role, "image"))
    {
        return null;
    }
    const execution_targets = try arena.alloc(
        command_admission.VisionPathExecutionTarget,
        targets.len,
    );
    for (targets, execution_targets) |target, *execution_target| {
        if (!std.mem.eql(u8, target.role, "image")) {
            return error.InvalidToolArguments;
        }
        var source = image_attachments.openVisionRegularFile(target.path) catch
            return error.InvalidToolArguments;
        defer source.close();
        execution_target.* = .{
            .canonical_path = try arena.dupe(u8, target.path),
            .identity = source.identity,
        };
    }
    return .{ .targets = execution_targets };
}

fn visionPathPermissionTargets(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        authority.targets.len,
    );
    for (authority.targets, targets) |execution_target, *target| {
        target.* = .{
            .role = "image",
            .path = @constCast(execution_target.canonical_path),
        };
    }
    return targets;
}

fn bindVisionPathExecutionAuthority(
    outcome: command_admission.PermissionOutcome,
    vision_authority: ?command_admission.VisionPathExecutionAuthority,
) !command_admission.PermissionOutcome {
    const authority = vision_authority orelse return outcome;
    var bound = outcome;
    if (bound.execution_authority) |execution_authority| {
        switch (execution_authority) {
            .ordinary => bound.execution_authority = .{ .vision_paths = authority },
            .run_command, .file_mutation, .vision_paths => {},
        }
    }
    return bound;
}

fn permissionOutcomeForDecision(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    if (!try isRunCommandCall(input, arena, call)) {
        return ordinaryPermissionOutcome(decision);
    }
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return shellPermissionOutcome(command_ctx, decision, source);
}

fn shellPermissionOutcome(
    command_ctx: command_admission.CommandContext,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    return .{
        .decision = decision,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = source,
        } } },
    };
}

pub fn runCommandContext(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !command_admission.CommandContext {
    if (!try isRunCommandCall(input, arena, call)) return error.NotRunCommand;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const execution_mode: command_admission.CommandExecutionMode =
        if (tool_args.optionalBoolArg(args, "tty") orelse false) .tty else .captured;
    const tool = registeredTool(input, call.name) orelse return error.NotRunCommand;
    const cwd = switch (tool.captured_command_host) {
        .workspace_clean => try arena.dupe(u8, input.workspace_root),
        .native => blk: {
            const cwd_arg = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
            break :blk if (std.mem.eql(u8, cwd_arg, "."))
                try arena.dupe(u8, input.workspace_root)
            else
                try pathing.resolveWorkspaceOrExternalPath(arena, input.workspace_root, cwd_arg);
        },
    };
    const environment_value: command_environment.Environment = switch (tool.captured_command_host) {
        .workspace_clean => .workspace_clean,
        .native => try nativeCommandEnvironment(arena, args, execution_mode),
    };
    return .{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = environment_value,
        .execution_mode = execution_mode,
    };
}

fn nativeCommandEnvironment(
    arena: Allocator,
    args: std.json.ObjectMap,
    execution_mode: command_admission.CommandExecutionMode,
) !command_environment.Environment {
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    if (execution_mode == .tty) {
        if (try explicitTtyShell(arena, args)) |shell| {
            return shell_resolver.environmentForShellSpec(arena, configured, shell);
        }
    }
    const profile_raw = tool_args.nullablePlaceholderStringArg(args, "profile");
    const profile: ?command_environment.Profile = if (profile_raw) |raw|
        std.meta.stringToEnum(command_environment.Profile, raw) orelse
            return error.InvalidCommandProfile
    else
        null;
    return shell_resolver.environment(arena, configured, profile);
}

fn explicitTtyShell(
    arena: Allocator,
    args: std.json.ObjectMap,
) !?terminal_contracts.ShellSpec {
    var value = args.get("shell") orelse return null;
    if (value == .null or
        (value == .string and tool_args.isNullPlaceholderText(value.string)))
    {
        return null;
    }
    try tool_args.normalizeCompositeObjectValue(arena, &value);
    if (value != .object) return error.InvalidToolArguments;
    const kind = try tool_args.requiredStringArg(value.object, "kind");
    if (!std.mem.eql(u8, kind, "executable")) return error.InvalidToolArguments;
    return .{ .executable = .{
        .path = try tool_args.requiredStringArg(value.object, "path"),
        .clean_start = tool_args.optionalBoolArg(value.object, "clean_start") orelse false,
    } };
}

fn commandPermissionIdentityForContext(
    arena: Allocator,
    command: command_admission.CommandContext,
) ![]const u8 {
    return switch (command.execution_mode) {
        .captured => command_environment.permissionCommandIdentity(
            arena,
            command.environment,
            command.command,
        ),
        .tty => command_environment.ttyPermissionCommandIdentity(
            arena,
            command.environment,
            command.command,
        ),
    };
}

pub fn permissionTargetResolutionFailureMessage(
    arena: Allocator,
    call: ToolCall,
    err: anyerror,
) !?[]const u8 {
    const reason: ?[]const u8 = switch (err) {
        error.FileNotFound => "Path not found",
        error.NotDir => "Path is not a directory",
        error.AccessDenied, error.PermissionDenied => "Access denied for path",
        error.PathOutsideWorkspace => "Path is outside the workspace",
        error.SymLinkLoop,
        error.NameTooLong,
        error.BadPathName,
        error.InputOutput,
        error.HomeNotSet,
        error.InvalidPath,
        error.WorkspaceUnavailable,
        => null,
        else => return null,
    };
    const path_arg = try targetPathForFailureMessage(arena, call);
    if (reason) |text| {
        return if (path_arg) |path|
            try arena.print("{s}: {s}", .{ text, path })
        else
            try arena.dupe(u8, text);
    }
    return if (path_arg) |path|
        try arena.print("Cannot resolve path \"{s}\": {s}", .{ path, @errorName(err) })
    else
        try arena.print("Cannot resolve tool target path: {s}", .{@errorName(err)});
}

/// Best-effort extraction of the path the caller asked for, so the failure
/// names the exact argument the model can correct. Falls back to no path when
/// the arguments do not carry one; the base message still applies. File tools
/// resolve their `path` argument, command tools resolve `cwd`; each prefers
/// its own key so a stray extra key cannot misname the argument that failed.
fn targetPathForFailureMessage(arena: Allocator, call: ToolCall) !?[]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const is_file_tool = permissions.allowsExternalPath(call.name);
    const primary_key: []const u8 = if (is_file_tool) "path" else "cwd";
    const secondary_key: []const u8 = if (is_file_tool) "cwd" else "path";
    if (tool_args.optionalStringArg(args, primary_key)) |primary| {
        if (primary.len > 0) return primary;
    }
    if (tool_args.optionalStringArg(args, secondary_key)) |secondary| {
        if (secondary.len > 0) return secondary;
    }
    return null;
}

fn permissionTargetsForCall(input: Input, arena: Allocator, call: ToolCall) !permissions.PermissionCallTargets {
    if (call.toolbox_lookup) |lookup| {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, lookup.target) };
        return .{ .items = items };
    }
    if (isAvailableDynamicTool(input, call.name)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    if (registeredWebSearchTarget(input, call.name)) |target_name| {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try arena.dupe(u8, target_name),
        };
        return .{ .items = items };
    }
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try commandPermissionTarget(input, arena, call),
        };
        return .{ .items = items };
    }
    // A host tool that reuses a reserved file-mutation name has no typed
    // mutation target; its permission target is its own name.
    if (tool.executor_kind == .host) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    var permission_call = call;
    if (std.mem.eql(u8, permission_call.name, "shell")) {
        permission_call.name = "shell";
    }
    return permissions.permissionTargetsForCallInScope(
        arena,
        accessScope(input),
        permission_call,
        tool.permission_target_kind,
    );
}

fn commandPermissionTarget(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]u8 {
    const context = try runCommandContext(input, arena, call);
    const identity = try commandPermissionIdentityForContext(
        arena,
        context,
    );
    return arena.print(
        "{s}::{s}",
        .{ context.resolved_cwd, identity },
    );
}

pub fn permissionTargetForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    if (isAvailableDynamicTool(input, call.name)) return arena.dupe(u8, call.name);
    if (registeredWebSearchTarget(input, call.name)) |target_name| return arena.dupe(u8, target_name);
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        return commandPermissionTarget(input, arena, call);
    }
    // A host tool that reuses a reserved file-mutation name has no typed
    // mutation target; its permission target is its own name.
    if (tool.executor_kind == .host) return arena.dupe(u8, call.name);
    return permissions.permissionTargetForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

/// Resolves the target used only for inherited live-authority checks. A
/// missing existing-path target still needs an authority decision before the
/// tool itself can return its ordinary structured failure.
pub fn permissionTargetForLiveAuthority(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]const u8 {
    return permissionTargetForCall(input, arena, call) catch |err| {
        if (!recoverableExistingPathResolutionFailure(err)) return err;
        const tool = registeredTool(input, call.name) orelse return err;
        if (tool.permission_target_kind != .path_existing) {
            return err;
        }
        return permissions.missingPathTargetForCallInScope(
            arena,
            accessScope(input),
            call,
        ) catch |fallback_err| {
            if (!recoverableExistingPathResolutionFailure(fallback_err)) {
                return fallback_err;
            }
            return permissions.unresolvedPathTargetForCallInScope(
                arena,
                accessScope(input),
                call,
            );
        };
    };
}

fn recoverableExistingPathResolutionFailure(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        error.PermissionDenied,
        => true,
        else => false,
    };
}

fn isAvailableDynamicTool(input: Input, name: []const u8) bool {
    return tool_mcp_runtime.isAvailableDynamicTool(.{
        .is_registered_tool = registeredTool(input, name) != null,
        .advertised_dynamic_tool_names = input.advertised_dynamic_tool_names,
        .runtime = input.mcp_runtime,
    }, name);
}
