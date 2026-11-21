const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const command_environment = @import("../execution/command_environment.zig");

const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const tool_args = @import("../tooling/tool_args.zig");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const PermissionMode = types.PermissionMode;
pub const ToolPermissionDecision = types.ToolPermissionDecision;

pub const PermissionCallTarget = struct {
    role: []const u8,
    path: []u8,
};

pub const PermissionCallTargets = struct {
    items: []PermissionCallTarget,

    pub fn deinit(self: *PermissionCallTargets, alloc: std.mem.Allocator) void {
        for (self.items) |target| alloc.free(target.path);
        alloc.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

const ResolvedPermissionCallTarget = struct {
    role: []const u8,
    path: []const u8,
};


pub const PermissionTargetKind = enum {
    none,
    path_existing,
    path_optional_existing,
    path_create_parent,
    path_existing_parent,
    command_cwd,
    url,
};

pub const web_search_permission = "web_search";
pub const web_fetch_permission = "web_fetch";
pub const yolo_warning_text = "Full access enabled: spark permission checks disabled";

pub fn isWebSearchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_search_permission);
}

pub fn isWebFetchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_fetch_permission);
}

pub fn permissionModeLabel(mode: PermissionMode) []const u8 {
    return mode.label();
}

/// Human-readable name; permissionModeLabel retains the persisted and wire value.
pub fn permissionModeDisplayLabel(mode: PermissionMode) []const u8 {
    _ = mode;
    return "full access";
}

pub fn permissionDecisionFromIndex(index: u8) ToolPermissionDecision {
    return switch (index) {
        0 => .once,
        1 => .always,
        else => .deny,
    };
}

pub fn permissionTargetForCall(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    // A toolbox open or search is decided as the tool it replaced.
    if (call.toolbox_lookup) |lookup| return arena.dupe(u8, lookup.target);
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    if (std.mem.eql(u8, call.name, "install_skill")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const source = try tool_args.requiredStringArg(args, "source");
        if (tool_args.optionalStringArg(args, "skill")) |skill| {
            return arena.print("{s}#{s}", .{ source, skill });
        }
        return arena.dupe(u8, source);
    }

    if (isWebSearchToolName(call.name)) {
        return arena.dupe(u8, web_search_permission);
    }

    if (isWebFetchToolName(call.name)) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        return webFetchDomainTargetForUrl(arena, try tool_args.requiredStringArg(args, "url"));
    }

    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);

    return switch (target_kind) {
        .command_cwd => blk: {
            const command = try tool_args.requiredStringArg(args, "command");
            const cwd = try resolveCommandCwdFromArgs(arena, workspace_root, args);
            break :blk arena.print("{s}::{s}", .{ cwd, command });
        },
        .url => arena.dupe(u8, try tool_args.requiredStringArg(args, "url")),
        .path_optional_existing => blk: {
            const path_arg = tool_args.optionalStringArg(args, "path") orelse ".";
            break :blk if (path_arg.len == 0 or std.mem.eql(u8, path_arg, "."))
                arena.dupe(u8, workspace_root)
            else
                try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .path_create_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .create);
            break :blk std.Io.Dir.path.dirname(target_path) orelse target_path;
        },
        .path_existing_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
            break :blk std.Io.Dir.path.dirname(target_path) orelse target_path;
        },
        .path_existing => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            break :blk try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .none => try arena.dupe(u8, call.name),
    };
}

pub fn resolveCommandCwdForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
    const cwd = try resolveCommandCwdFromArgsInScope(scratch, scope, args);
    return alloc.dupe(u8, cwd);
}

fn resolveCommandCwdFromArgs(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, workspace_root);
    return pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, cwd_input);
}

fn resolveCommandCwdFromArgsInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, scope.primary_directory);
    return pathing.resolveWorkspaceOrExternalPath(arena, scope.primary_directory, cwd_input);
}

pub fn permissionTargetsForCall(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (std.mem.eql(u8, call.name, "vision")) {
        const request = vision_contracts.parse_vision_request(
            scratch,
            call.arguments_json,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolArguments,
        };
        defer request.deinit(scratch);
        if (request.paths()) |paths| {
            const targets = try scratch.alloc(ResolvedPermissionCallTarget, paths.len);
            for (paths, 0..) |path, index| {
                const resolved = try pathing.resolveWorkspaceOrExternalPath(
                    scratch,
                    workspace_root,
                    path,
                );
                for (targets[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.path, resolved)) {
                        return error.InvalidToolArguments;
                    }
                }
                targets[index] = .{ .role = "image", .path = resolved };
            }
            return ownedPermissionCallTargets(alloc, targets);
        }
    }

    const target = try permissionTargetForCall(scratch, workspace_root, call, target_kind);
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetsForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (target_kind != .command_cwd) {
        return permissionTargetsForCall(alloc, scope.primary_directory, call, target_kind);
    }
    const target = try permissionTargetForCallInScope(alloc, scope, call, target_kind);
    defer alloc.free(@constCast(target));
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    if (target_kind != .command_cwd) {
        return permissionTargetForCall(arena, scope.primary_directory, call, target_kind);
    }
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const cwd = try resolveCommandCwdFromArgsInScope(arena, scope, args);
    return arena.print("{s}::{s}", .{ cwd, command });
}

/// Resolves the canonical requested path without requiring it to exist.
/// Callers must first establish that the tool's ordinary target contract is
/// an existing `path` argument.
pub fn missingPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const path_arg = try tool_args.requiredStringArg(args, "path");
    return resolveFileToolPath(
        arena,
        scope.primary_directory,
        call.name,
        path_arg,
        .create,
    );
}

/// Returns a normalized scope-checked identity for an existing-path request
/// whose filesystem lookup failed before the tool could report that failure.
/// This does not establish that the path exists or authorize execution.
pub fn unresolvedPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const raw = std.mem.trim(
        u8,
        try tool_args.requiredStringArg(args, "path"),
        " \t\r\n",
    );
    if (raw.len == 0 or raw.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(raw) or
        std.mem.findScalar(u8, raw, 0) != null or
        std.mem.startsWith(u8, raw, "~"))
    {
        return error.InvalidPath;
    }
    const resolved = if (std.Io.Dir.path.isAbsolute(raw))
        try std.Io.Dir.path.resolveAlloc(arena, &.{raw})
    else
        try std.Io.Dir.path.resolveAlloc(arena, &.{ scope.primary_directory, raw });
    if (!scope.contains(resolved)) return error.PathOutsideWorkspace;
    return resolved;
}

fn isTypedFileMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

const FileTargetEvaluationError = error{
    OutOfMemory,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

const FileTargetResolverError = @typeInfo(@typeInfo(@TypeOf(pathing.resolveFileMutationTargetBounded)).@"fn".return_type.?).error_union.error_set;

const FileTargetDraft = struct {
    kind: file_mutation_contract.PermissionTargetKind,
    disposition: file_mutation_contract.FileTargetDisposition,
    path_end: usize,
    expected_identity: ?file_mutation_contract.FileIdentity,
};

const FileTargetWalk = struct {
    anchor_identity: file_mutation_contract.FileIdentity,
    target_identity: ?file_mutation_contract.FileIdentity,
};

const FileTargetWalkResult = union(enum) {
    failure: file_mutation_contract.FileTargetResolutionFailure,
    ok: FileTargetWalk,
};

pub fn prepareFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPreparationResult {
    const mode: types.ResolveMode = switch (input) {
        .write => .create,
        .edit => .existing,
    };

    var primary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var secondary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var bounded_component_scratch: [file_mutation_contract.max_file_target_components]pathing.BoundedFileTargetComponent = undefined;
    const bounded = pathing.resolveFileMutationTargetBounded(
        workspace_root,
        input.path(),
        mode,
        &primary_path_scratch,
        &secondary_path_scratch,
        &bounded_component_scratch,
    ) catch |err| {
        const failure = normalizeFileTargetResolverError(err) catch |operational| return operational;
        return .{ .target_resolution_failure = failure };
    };

    if (!boundedResolutionValid(bounded)) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    const component_count = bounded.relative_components.len;
    const traversal_count = component_count - 1;
    const worst_case_item_count = @max(component_count, 2);
    const proof_charge = file_mutation_contract.proofCharge(
        bounded.canonical_target_path.len,
        component_count,
        traversal_count,
        worst_case_item_count,
    ) orelse return .{ .target_resolution_failure = .policy_proof_too_large };
    if (proof_charge > file_mutation_contract.max_file_target_proof_bytes) {
        return .{ .target_resolution_failure = .policy_proof_too_large };
    }

    var traversal_scratch: [file_mutation_contract.max_file_target_components]file_mutation_contract.TraversalDirectory = undefined;
    const traversal = traversal_scratch[0..traversal_count];
    const walk = switch (try walkFileTargetDirectories(bounded, mode, traversal)) {
        .failure => |failure| return .{ .target_resolution_failure = failure },
        .ok => |value| value,
    };

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const item_count = assembleFileTargetDrafts(bounded, walk, traversal, &draft_scratch);
    const drafts = draft_scratch[0..item_count];

    return .{ .prepared = try ownedResolvedFileTargets(
        alloc,
        bounded,
        walk.anchor_identity,
        traversal,
        drafts,
    ) };
}

/// Consumes a structurally validated target proof and projects policy-neutral
/// execution targets for YOLO admission.
pub fn authorizePreparedFileMutationTargets(
    alloc: std.mem.Allocator,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
) error{OutOfMemory}!file_mutation_contract.FileTargetPolicyResult {
    var resolved = prepared.*;
    prepared.relinquish();
    defer resolved.deinit(alloc);
    if (!resolved.proofValid()) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const drafts = draft_scratch[0..resolved.items.len];
    for (resolved.items, drafts) |item, *draft| {
        draft.* = .{
            .kind = item.kind,
            .disposition = item.disposition,
            .path_end = item.path_end,
            .expected_identity = item.expected_identity,
        };
    }

    return .{ .evaluated = try policyEvaluatedTargetsFromResolved(
        alloc,
        &resolved,
        drafts,
        false,
    ) };
}

pub fn evaluateFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
    _: types.PermissionMode,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .target_resolution_failure = failure },
        .prepared => |value| value,
    };
    return authorizePreparedFileMutationTargets(alloc, &prepared);
}

fn walkFileTargetDirectories(
    bounded: pathing.BoundedFileTargetResolution,
    mode: types.ResolveMode,
    traversal: []file_mutation_contract.TraversalDirectory,
) FileTargetEvaluationError!FileTargetWalkResult {
    const zio = io_mod.getIo();
    var current_dir = std.Io.Dir.openDirAbsolute(
        zio,
        bounded.canonical_target_path[0..bounded.anchor_path_end],
        .{ .follow_symlinks = false },
    ) catch |err| {
        const failure = normalizeDirOpenError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    defer current_dir.close(zio);

    const anchor_stat = current_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
        const failure = normalizeStatFileError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    if (anchor_stat.kind != .directory) {
        return .{ .failure = .not_directory };
    }
    const anchor_identity = pathing.fileIdentity(
        try pathing.descriptorDevice(current_dir.handle),
        anchor_stat,
    );

    var missing_parent_seen = false;
    for (bounded.relative_components[0..traversal.len], 0..) |component, component_index| {
        const path_end = component.end;
        if (missing_parent_seen) {
            traversal[component_index] = .{
                .component_index = component_index,
                .path_end = path_end,
                .state = .{ .create = .{ .permission_target_index = undefined } },
            };
            continue;
        }

        const component_name = bounded.canonical_target_path[component.start..component.end];
        const next_dir = current_dir.openDir(zio, component_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .existing) {
                    return .{ .failure = .file_not_found };
                }
                missing_parent_seen = true;
                traversal[component_index] = .{
                    .component_index = component_index,
                    .path_end = path_end,
                    .state = .{ .create = .{ .permission_target_index = undefined } },
                };
                continue;
            },
            else => {
                const failure = normalizeDirOpenError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };

        const child_stat = next_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
            next_dir.close(zio);
            const failure = normalizeStatFileError(err) catch |operational| return operational;
            return .{ .failure = failure };
        };
        if (child_stat.kind != .directory) {
            next_dir.close(zio);
            return .{ .failure = .not_directory };
        }
        const child_device = pathing.descriptorDevice(next_dir.handle) catch |err| {
            next_dir.close(zio);
            return err;
        };
        const child_identity = pathing.fileIdentity(child_device, child_stat);
        traversal[component_index] = .{
            .component_index = component_index,
            .path_end = path_end,
            .state = .{ .existing = child_identity },
        };

        current_dir.close(zio);
        current_dir = next_dir;
    }

    const target_component = bounded.relative_components[bounded.relative_components.len - 1];
    const target_name = bounded.canonical_target_path[target_component.start..target_component.end];
    var target_identity: ?file_mutation_contract.FileIdentity = null;
    if (!missing_parent_seen) {
        const target_stat = current_dir.statFile(zio, target_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (mode == .existing) {
                return .{ .failure = .file_not_found };
            } else null,
            else => {
                const failure = normalizeStatFileError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };
        if (target_stat) |stat| {
            target_identity = pathing.fileIdentity(
                try pathing.directoryEntryDevice(current_dir, target_name),
                stat,
            );
        }
    }

    return .{ .ok = .{
        .anchor_identity = anchor_identity,
        .target_identity = target_identity,
    } };
}

fn assembleFileTargetDrafts(
    bounded: pathing.BoundedFileTargetResolution,
    walk: FileTargetWalk,
    traversal: []file_mutation_contract.TraversalDirectory,
    drafts: []FileTargetDraft,
) usize {
    var item_count: usize = 0;
    drafts[item_count] = .{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = bounded.canonical_target_path.len,
        .expected_identity = walk.target_identity,
    };
    item_count += 1;

    if (traversal.len == 0) {
        drafts[item_count] = .{
            .kind = .parent,
            .disposition = .existing_parent,
            .path_end = bounded.anchor_path_end,
            .expected_identity = walk.anchor_identity,
        };
    } else {
        const parent_index = traversal.len - 1;
        drafts[item_count] = switch (traversal[parent_index].state) {
            .existing => |identity| .{
                .kind = .parent,
                .disposition = .existing_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = identity,
            },
            .create => .{
                .kind = .parent,
                .disposition = .create_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = null,
            },
        };
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => traversal[parent_index].state.create.permission_target_index = item_count,
        }
    }
    item_count += 1;

    var parent_index = if (traversal.len > 1) traversal.len - 1 else 0;
    while (parent_index > 0) {
        parent_index -= 1;
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => {
                traversal[parent_index].state.create.permission_target_index = item_count;
                drafts[item_count] = .{
                    .kind = .parent,
                    .disposition = .create_parent,
                    .path_end = traversal[parent_index].path_end,
                    .expected_identity = null,
                };
                item_count += 1;
            },
        }
    }
    return item_count;
}

fn ownedResolvedFileTargets(
    alloc: std.mem.Allocator,
    bounded: pathing.BoundedFileTargetResolution,
    anchor_identity: file_mutation_contract.FileIdentity,
    traversal: []const file_mutation_contract.TraversalDirectory,
    drafts: []const FileTargetDraft,
) error{OutOfMemory}!file_mutation_contract.ResolvedFileMutationTargets {
    const canonical_target_path = try alloc.dupe(u8, bounded.canonical_target_path);
    errdefer alloc.free(canonical_target_path);
    const relative_components = try alloc.alloc(file_mutation_contract.PathSpan, bounded.relative_components.len);
    errdefer alloc.free(relative_components);
    const traversal_directories = try alloc.alloc(file_mutation_contract.TraversalDirectory, traversal.len);
    errdefer alloc.free(traversal_directories);
    const items = try alloc.alloc(file_mutation_contract.ResolvedPermissionTarget, drafts.len);
    errdefer alloc.free(items);

    for (bounded.relative_components, relative_components) |source, *destination| {
        destination.* = .{ .start = source.start, .end = source.end };
    }
    @memcpy(traversal_directories, traversal);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
        };
    }

    return .{
        .canonical_target_path = canonical_target_path,
        .anchor = .{
            .scope = if (bounded.anchor_is_external) .external else .workspace,
            .path_end = bounded.anchor_path_end,
            .identity = anchor_identity,
            .relative_components = relative_components,
        },
        .traversal_directories = traversal_directories,
        .items = items,
    };
}

fn policyEvaluatedTargetsFromResolved(
    alloc: std.mem.Allocator,
    resolved: *file_mutation_contract.ResolvedFileMutationTargets,
    drafts: []const FileTargetDraft,
    prompt_required: bool,
) error{OutOfMemory}!file_mutation_contract.PolicyEvaluatedFileTargets {
    const items = try alloc.alloc(file_mutation_contract.EvaluatedPermissionTarget, drafts.len);
    errdefer alloc.free(items);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
        };
    }

    alloc.free(@constCast(resolved.items));
    const evaluated: file_mutation_contract.PolicyEvaluatedFileTargets = .{
        .canonical_target_path = resolved.canonical_target_path,
        .anchor = resolved.anchor,
        .traversal_directories = resolved.traversal_directories,
        .items = items,
        .prompt_required = prompt_required,
    };
    resolved.relinquish();
    return evaluated;
}

fn boundedResolutionValid(resolution: pathing.BoundedFileTargetResolution) bool {
    if (resolution.canonical_target_path.len == 0) return false;
    if (!std.Io.Dir.path.isAbsolute(resolution.canonical_target_path)) return false;
    if (resolution.anchor_path_end == 0 or resolution.anchor_path_end > resolution.canonical_target_path.len) return false;
    if (resolution.relative_components.len == 0) return false;
    if (resolution.relative_components.len > file_mutation_contract.max_file_target_components) return false;

    var expected_start = if (resolution.anchor_path_end == 1)
        resolution.anchor_path_end
    else
        resolution.anchor_path_end + 1;
    for (resolution.relative_components) |component| {
        if (component.start != expected_start) return false;
        if (component.end <= component.start or component.end > resolution.canonical_target_path.len) return false;
        expected_start = component.end + 1;
    }
    return resolution.relative_components[resolution.relative_components.len - 1].end == resolution.canonical_target_path.len;
}

fn normalizeFileTargetResolverError(err: FileTargetResolverError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.PathOutsideWorkspace => .path_outside_workspace,
        error.FileNotFound => .file_not_found,
        error.HomeNotSet => .home_not_set,
        error.InvalidPath => .invalid_path,
        error.WorkspaceUnavailable => .workspace_unavailable,
        error.TooManyPathComponents => .too_many_path_components,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.NotLink, error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.OperationUnsupported, error.UnsupportedReparsePointType => .unsupported_path_operation,
        error.NoDevice,
        error.NetworkNotFound,
        error.UnrecognizedVolume,
        error.InputOutput,
        error.FileSystem,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileBusy,
        error.PipeBusy,
        error.FileLocksUnsupported,
        error.WouldBlock,
        error.AntivirusInterference,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeDirOpenError(err: std.Io.Dir.OpenError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.NotDir => .not_directory,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.SymLinkLoop => .symlink_loop,
        error.NoDevice, error.NetworkNotFound => .filesystem_unavailable,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeStatFileError(err: std.Io.Dir.StatFileError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.PipeBusy,
        error.NoDevice,
        error.NetworkNotFound,
        error.AntivirusInterference,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileLocksUnsupported,
        error.FileBusy,
        error.WouldBlock,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn ownedPermissionCallTargets(
    alloc: std.mem.Allocator,
    source: []const ResolvedPermissionCallTarget,
) !PermissionCallTargets {
    const items = try alloc.alloc(PermissionCallTarget, source.len);
    errdefer alloc.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |target| alloc.free(target.path);
    }

    for (source, 0..) |target, index| {
        items[index] = .{
            .role = target.role,
            .path = try alloc.dupe(u8, target.path),
        };
        initialized += 1;
    }
    return .{ .items = items };
}

pub fn resolveFileToolPath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    path_arg: []const u8,
    mode: types.ResolveMode,
) ![]const u8 {
    if (!allowsExternalPath(tool_name)) {
        return pathing.resolveWorkspacePath(arena, workspace_root, path_arg, mode);
    }

    return switch (mode) {
        .existing => pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, path_arg),
        .create => pathing.resolveWorkspaceOrExternalCreatePath(arena, workspace_root, path_arg),
    };
}

const external_path_tools = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "write_file",
    "edit_file",
};

pub fn allowsExternalPath(tool_name: []const u8) bool {
    for (external_path_tools) |eligible| {
        if (std.mem.eql(u8, tool_name, eligible)) return true;
    }
    return false;
}

test "allowsExternalPath preserves the exact eligible tool set" {
    const expected = [_][]const u8{
        "read_file",
        "glob_files",
        "grep_files",
        "write_file",
        "edit_file",
    };

    try std.testing.expectEqual(expected.len, external_path_tools.len);
    for (expected, external_path_tools) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
        try std.testing.expect(allowsExternalPath(expected_name));
    }
    try std.testing.expect(!allowsExternalPath("run_command"));
    try std.testing.expect(!allowsExternalPath("missing_tool"));
}

pub fn isFilesystemMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

pub fn displayTargetForPolicy(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]u8 {
    return switch (target_kind) {
        .command_cwd => displayCommandTarget(alloc, workspace_root, target_path),
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => displayPathTarget(alloc, workspace_root, target_path),
        else => alloc.dupe(u8, target_path),
    };
}

pub fn webFetchDomainTargetForUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return error.InvalidToolArguments;
    const authority_start = scheme_end + "://".len;
    const authority_end = authorityEnd(url, authority_start);
    if (authority_end == authority_start) return error.InvalidToolArguments;

    const authority = url[authority_start..authority_end];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.InvalidToolArguments;
    const host = hostFromAuthority(authority) orelse return error.InvalidToolArguments;
    return canonicalWebFetchDomainPattern(alloc, host);
}

pub fn canonicalWebFetchDomainPattern(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const host_raw = if (std.mem.startsWith(u8, raw, "domain:")) raw["domain:".len..] else raw;
    if (std.mem.find(u8, host_raw, "://") != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '/') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '*') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '?') != null) return error.InvalidToolArguments;

    const host = stripOneRootDot(host_raw);
    if (!isCanonicalizableWebFetchHost(host)) return error.InvalidToolArguments;

    const target = try alloc.alloc(u8, "domain:".len + host.len);
    errdefer alloc.free(target);
    @memcpy(target[0.."domain:".len], "domain:");
    for (host, 0..) |char, index| {
        target["domain:".len + index] = std.ascii.toLower(char);
    }
    return target;
}

pub fn isCanonicalWebFetchDomainPattern(pattern: []const u8) bool {
    if (!std.mem.startsWith(u8, pattern, "domain:")) return false;
    const host = pattern["domain:".len..];
    if (!isCanonicalizableWebFetchHost(host)) return false;
    if (std.mem.endsWith(u8, host, ".")) return false;
    for (host) |char| {
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
    }
    return true;
}

fn stripOneRootDot(host: []const u8) []const u8 {
    if (host.len > 1 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

fn isCanonicalizableWebFetchHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[') return isCanonicalizableWebFetchIpv6Literal(host);
    if (std.mem.findScalar(u8, host, ':') != null) return false;
    var label_len: usize = 0;
    for (host) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (char == '*' or char == '?' or char == '/' or char == '\\') return false;
        if (char == '.') {
            if (label_len == 0) return false;
            label_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
        label_len += 1;
    }
    return label_len > 0;
}

fn isCanonicalizableWebFetchIpv6Literal(host: []const u8) bool {
    if (host.len < 3 or host[host.len - 1] != ']') return false;
    const inner = host[1 .. host.len - 1];
    if (std.mem.findScalar(u8, inner, '%') != null) return false;
    for (inner) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
        if (!std.ascii.isHex(char) and char != ':' and char != '.') return false;
    }
    _ = std.Io.net.Ip6Address.parse(inner, 0) catch return false;
    return true;
}

fn authorityEnd(url: []const u8, start: usize) usize {
    var index = start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn hostFromAuthority(authority: []const u8) ?[]const u8 {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const end = std.mem.findScalar(u8, authority, ']') orelse return null;
        if (end == 1) return null;
        if (end + 1 < authority.len and authority[end + 1] != ':') return null;
        return authority[0 .. end + 1];
    }

    const colon = std.mem.findScalarLast(u8, authority, ':') orelse authority.len;
    if (colon == 0) return null;
    return authority[0..colon];
}

fn displayPathTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(target_path) and pathing.pathInside(workspace_root, target_path)) {
        const relative = std.Io.Dir.path.relativeAlloc(alloc, "/", null, workspace_root, target_path) catch return alloc.dupe(u8, target_path);
        if (relative.len == 0) {
            alloc.free(relative);
            return alloc.dupe(u8, ".");
        }
        return relative;
    }
    return alloc.dupe(u8, target_path);
}

fn displayCommandTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    const separator = std.mem.find(u8, target_path, "::") orelse return alloc.dupe(u8, target_path);
    const cwd = target_path[0..separator];
    const command = command_environment.commandFromPermissionIdentity(
        target_path[separator + 2 ..],
    );

    const display_cwd = try (if (std.mem.eql(u8, cwd, workspace_root))
        alloc.dupe(u8, ".")
    else if (std.Io.Dir.path.isAbsolute(cwd) and pathing.pathInside(workspace_root, cwd))
        (std.Io.Dir.path.relativeAlloc(alloc, "/", null, workspace_root, cwd) catch alloc.dupe(u8, cwd))
    else
        alloc.dupe(u8, cwd));
    defer alloc.free(display_cwd);

    return alloc.print("{s}::{s}", .{ display_cwd, command });
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn testWriteMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .write = .{
        .path = @constCast(path),
        .content = @constCast("x"),
    } };
}

fn testEditMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .edit = .{
        .path = @constCast(path),
        .old_string = @constCast("a"),
        .new_string = @constCast("b"),
    } };
}

fn checkFileTargetPreparationAllocationFailures(alloc: std.mem.Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace,
        testWriteMutationInput("existing/nested/file.txt"),
    )) {
        .target_resolution_failure => return error.TestUnexpectedResult,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}
