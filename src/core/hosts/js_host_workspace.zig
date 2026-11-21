const std = @import("std");
const command_contract = @import("../execution/command_contract.zig");
const context_contract = @import("../workspace/context_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;

const max_info_bytes: usize = 4 * 1024;
pub const max_command_bytes: usize = 64 * 1024;
const max_output_bytes: usize = 64 * 1024;
pub const min_timeout_ms: u32 = 1;
pub const max_timeout_ms: u32 = 30_000;
/// Largest instruction file prefix one host read copies into spark. Matches the
/// SDK's `workspaceInstructionFileLimit`.
const max_instruction_file_bytes: usize = 1024 * 1024;
const max_instruction_path_bytes: usize = 4 * 1024;
const instruction_file_name = "AGENTS.md";

const ResultRecord = extern struct {
    exit_code: i32,
    stdout_offset: u32,
    stdout_copied: u32,
    stdout_total: u32,
    stderr_offset: u32,
    stderr_copied: u32,
    stderr_total: u32,
    flags: u32,
};

const ReadRecord = extern struct {
    total_bytes: u32,
    copied_bytes: u32,
};

comptime {
    std.debug.assert(@sizeOf(ResultRecord) == 32);
    std.debug.assert(@sizeOf(ReadRecord) == 8);
}

extern "spark" fn spark_workspace_available() i32;
extern "spark" fn spark_workspace_info(out_ptr: [*]u8, out_cap: usize) i32;
extern "spark" fn spark_workspace_exec(
    command_ptr: [*]const u8,
    command_len: usize,
    timeout_ms: u32,
    output_ptr: [*]u8,
    output_cap: usize,
    result_ptr: *ResultRecord,
) i32;
/// Copies up to `out_cap` bytes of one instruction file. Status codes: 0
/// copied, -1 host failure, -2 no instruction file access, -3 aborted,
/// -4 rejected path, -5 deadline, -6 missing, -7 invalid UTF-8.
extern "spark" fn spark_workspace_read_file(
    path_ptr: [*]const u8,
    path_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
    result_ptr: *ReadRecord,
) i32;

const ImportedHost = struct {
    fn workspaceAvailable() i32 {
        return spark_workspace_available();
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        return spark_workspace_info(out_ptr, out_cap);
    }

    fn workspaceExec(
        command_ptr: [*]const u8,
        command_len: usize,
        timeout_ms: u32,
        output_ptr: [*]u8,
        output_cap: usize,
        result_ptr: *ResultRecord,
    ) i32 {
        return spark_workspace_exec(
            command_ptr,
            command_len,
            timeout_ms,
            output_ptr,
            output_cap,
            result_ptr,
        );
    }

    fn workspaceReadFile(
        path_ptr: [*]const u8,
        path_len: usize,
        out_ptr: [*]u8,
        out_cap: usize,
        result_ptr: *ReadRecord,
    ) i32 {
        return spark_workspace_read_file(path_ptr, path_len, out_ptr, out_cap, result_ptr);
    }
};

pub const ExecuteError = Allocator.Error || error{
    InvalidWorkspaceInput,
    InvalidWorkspaceResult,
    WriteFailed,
    WorkspaceDeadline,
    WorkspaceHostFailure,
    WorkspaceUnavailable,
};

pub const Executor = struct {
    execute_fn: *const fn (
        Allocator,
        []const u8,
        []const u8,
        u32,
    ) ExecuteError!command_contract.RunCommandResult,

    pub fn execute(
        self: Executor,
        alloc: Allocator,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: u32,
    ) ExecuteError!command_contract.RunCommandResult {
        return self.execute_fn(alloc, command, cwd, timeout_ms);
    }
};

pub const Permission = enum {
    allow_sandboxed,
    prompt,
};

const PathSpan = struct {
    offset: u16,
    len: u16,
};

pub const Info = struct {
    storage: [max_info_bytes]u8 = undefined,
    root_span: PathSpan,
    cwd_span: PathSpan,
    home_span: PathSpan,
    git_available: bool,
    ephemeral: bool,
    permission: Permission,
    instruction_files: bool,

    pub fn root(self: *const Info) []const u8 {
        return self.path(self.root_span);
    }

    pub fn cwd(self: *const Info) []const u8 {
        return self.path(self.cwd_span);
    }

    pub fn home(self: *const Info) []const u8 {
        return self.path(self.home_span);
    }

    fn path(self: *const Info, span: PathSpan) []const u8 {
        const start: usize = span.offset;
        return self.storage[start .. start + span.len];
    }
};

const JsonInfo = struct {
    version: u32,
    root: []const u8,
    cwd: []const u8,
    home: []const u8,
    git: bool,
    ephemeral: bool,
    permission: []const u8,
    instruction_files: bool = false,
};

pub fn Adapter(comptime Host: type) type {
    return struct {
        pub fn executor() Executor {
            return .{ .execute_fn = executeForProvider };
        }

        fn executeForProvider(
            alloc: Allocator,
            command: []const u8,
            cwd: []const u8,
            timeout_ms: u32,
        ) ExecuteError!command_contract.RunCommandResult {
            return execute(alloc, command, cwd, timeout_ms);
        }

        pub fn loadInfo(alloc: Allocator) !Info {
            return switch (Host.workspaceAvailable()) {
                0 => error.WorkspaceUnavailable,
                1 => loadAvailableInfo(alloc),
                else => error.InvalidContract,
            };
        }

        fn loadAvailableInfo(alloc: Allocator) !Info {
            var buffer: [max_info_bytes]u8 = undefined;
            const result = Host.workspaceInfo(&buffer, buffer.len);
            if (result < 0) return switch (result) {
                -1 => error.WorkspaceHostFailure,
                -2 => error.WorkspaceUnavailable,
                -3 => error.WorkspaceInfoTooSmall,
                -4 => error.InvalidContract,
                else => error.InvalidContract,
            };
            const len: usize = @intCast(result);
            if (len > buffer.len) return error.InvalidContract;

            const parsed = json_decode.parseFromSlice(JsonInfo, alloc, buffer[0..len], .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidContract,
            };
            defer parsed.deinit();
            const value = parsed.value;
            if (value.version != 1 or value.git or !value.ephemeral) return error.InvalidContract;
            if (!validAbsolutePath(value.root) or
                !validAbsolutePath(value.cwd) or
                !validAbsolutePath(value.home) or
                !std.mem.eql(u8, value.root, value.cwd)) return error.InvalidContract;
            const permission: Permission = if (std.mem.eql(u8, value.permission, "allow-sandboxed"))
                .allow_sandboxed
            else if (std.mem.eql(u8, value.permission, "prompt"))
                .prompt
            else
                return error.InvalidContract;

            var info = Info{
                .root_span = undefined,
                .cwd_span = undefined,
                .home_span = undefined,
                .git_available = false,
                .ephemeral = true,
                .permission = permission,
                .instruction_files = value.instruction_files,
            };
            var offset: usize = 0;
            info.root_span = copyPath(&info.storage, &offset, value.root) orelse return error.InvalidContract;
            info.cwd_span = copyPath(&info.storage, &offset, value.cwd) orelse return error.InvalidContract;
            info.home_span = copyPath(&info.storage, &offset, value.home) orelse return error.InvalidContract;
            return info;
        }

        pub fn execute(
            alloc: Allocator,
            command: []const u8,
            cwd: []const u8,
            timeout_ms: u32,
        ) ExecuteError!command_contract.RunCommandResult {
            if (command.len > max_command_bytes or
                !std.unicode.utf8ValidateSlice(command) or
                std.mem.findScalar(u8, command, 0) != null or
                timeout_ms < min_timeout_ms or
                timeout_ms > max_timeout_ms) return error.InvalidWorkspaceInput;

            const output = try alloc.alloc(u8, max_output_bytes);
            defer alloc.free(output);
            var record: ResultRecord = undefined;
            const started_ms = io_mod.milliTimestamp();
            const status = Host.workspaceExec(
                command.ptr,
                command.len,
                timeout_ms,
                output.ptr,
                output.len,
                &record,
            );
            const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
            if (status != 0) return switch (status) {
                -1 => error.WorkspaceHostFailure,
                -2 => error.WorkspaceUnavailable,
                -3 => .{
                    .output = "",
                    .cancelled = true,
                    .command_result = .{
                        .command = command,
                        .cwd = cwd,
                        .duration_ms = duration_ms,
                    },
                },
                -4 => error.InvalidWorkspaceInput,
                -5 => error.WorkspaceDeadline,
                else => error.InvalidWorkspaceResult,
            };

            const stdout = try checkedOutputSlice(
                output,
                record.stdout_offset,
                record.stdout_copied,
            );
            const stderr = try checkedOutputSlice(
                output,
                record.stderr_offset,
                record.stderr_copied,
            );
            if (rangesOverlap(
                record.stdout_offset,
                record.stdout_copied,
                record.stderr_offset,
                record.stderr_copied,
            ) or !std.unicode.utf8ValidateSlice(stdout) or
                !std.unicode.utf8ValidateSlice(stderr) or
                record.stdout_total < record.stdout_copied or
                record.stderr_total < record.stderr_copied or
                record.flags & ~@as(u32, 1) != 0) return error.InvalidWorkspaceResult;

            const truncated = record.flags & 1 != 0;
            const copied_total = @as(u64, record.stdout_copied) + record.stderr_copied;
            const output_total = @as(u64, record.stdout_total) + record.stderr_total;
            if ((!truncated and output_total != copied_total) or
                (truncated and output_total <= copied_total)) return error.InvalidWorkspaceResult;

            var formatted = try command_contract.formatCommandResult(alloc, .{
                .command = command,
                .cwd = cwd,
                .status = .{ .exit_code = record.exit_code },
                .stdout_display = stdout,
                .stderr_display = stderr,
                .stdout_bytes = record.stdout_total,
                .stderr_bytes = record.stderr_total,
                .duration_ms = duration_ms,
            });
            var metadata = formatted.command_result.?;
            metadata.truncated = truncated;
            formatted.command_result = metadata;
            return formatted;
        }

        /// Reads one AGENTS.md through the host. Returns null when it is
        /// missing; returned bytes are owned by the caller through `alloc`.
        fn readInstructionFile(
            alloc: Allocator,
            path: []const u8,
            max_bytes: usize,
        ) context_contract.InstructionFileError!?context_contract.InstructionFile {
            if (path.len > max_instruction_path_bytes or
                !validAbsolutePath(path) or
                !std.mem.eql(u8, std.Io.Dir.path.basename(path), instruction_file_name)) return error.UnsafePath;

            const buffer = try alloc.alloc(u8, @min(max_bytes, max_instruction_file_bytes));
            errdefer alloc.free(buffer);
            var record: ReadRecord = undefined;
            const status = Host.workspaceReadFile(path.ptr, path.len, buffer.ptr, buffer.len, &record);
            switch (status) {
                0 => {},
                -6 => {
                    alloc.free(buffer);
                    return null;
                },
                -2 => return error.HostUnreadable,
                -4 => return error.UnsafePath,
                else => {
                    // Abort, deadline, host failure, and invalid UTF-8 all read as unreadable.
                    debug_trace.logf("workspace", "instruction_read_failed status={d} path=\"{f}\"", .{ status, std.zig.fmtString(path) });
                    return error.Unreadable;
                },
            }
            const expected_bytes = @min(@as(u64, record.total_bytes), buffer.len);
            if (record.copied_bytes != expected_bytes) return error.Unreadable;
            return .{
                .bytes = try alloc.realloc(buffer, record.copied_bytes),
                .total_bytes = record.total_bytes,
            };
        }
    };
}

pub fn HostRuntime(comptime Host: type) type {
    return struct {
        workspace_info: ?Info = null,

        pub fn init(alloc: Allocator) !@This() {
            return .{ .workspace_info = try Adapter(Host).loadInfo(alloc) };
        }

        pub fn available(self: *const @This()) bool {
            return self.workspace_info != null;
        }

        pub fn info(self: *const @This()) ?*const Info {
            return if (self.workspace_info) |*metadata| metadata else null;
        }

        pub fn executor(self: *const @This()) ?Executor {
            if (!self.available()) return null;
            return Adapter(Host).executor();
        }

        /// Where the context provider reads AGENTS.md. A `.host` value borrows
        /// `home` from this runtime, which must outlive it.
        pub fn instructionFiles(self: *const @This()) context_contract.InstructionFiles {
            const metadata = self.info() orelse return .none;
            if (!metadata.instruction_files) return .host_unreadable;
            return .{ .host = .{
                .home = metadata.home(),
                .reader = .{
                    .read_fn = Adapter(Host).readInstructionFile,
                    .max_read_bytes = max_instruction_file_bytes,
                },
            } };
        }
    };
}

pub const Runtime = HostRuntime(ImportedHost);

fn checkedOutputSlice(output: []const u8, offset_raw: u32, len_raw: u32) ![]const u8 {
    const offset: usize = offset_raw;
    const len: usize = len_raw;
    if (offset > output.len or len > output.len - offset) return error.InvalidWorkspaceResult;
    return output[offset .. offset + len];
}

fn rangesOverlap(a_offset: u32, a_len: u32, b_offset: u32, b_len: u32) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = @as(u64, a_offset) + a_len;
    const b_end = @as(u64, b_offset) + b_len;
    return @as(u64, a_offset) < b_end and @as(u64, b_offset) < a_end;
}

fn elapsedMs(started_ms: i64, ended_ms: i64) u64 {
    return @intCast(@max(ended_ms - started_ms, 0));
}

fn copyPath(storage: *[max_info_bytes]u8, offset: *usize, path: []const u8) ?PathSpan {
    if (path.len > storage.len - offset.*) return null;
    const start = offset.*;
    @memcpy(storage[start .. start + path.len], path);
    offset.* += path.len;
    return .{ .offset = @intCast(start), .len = @intCast(path.len) };
}

fn validAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or !std.unicode.utf8ValidateSlice(path)) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

const valid_info_json =
    "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow-sandboxed\"}";

const FakeInfoHost = struct {
    var available_result: i32 = 1;
    var info_result: ?i32 = null;
    var info_json: []const u8 = valid_info_json;

    fn workspaceAvailable() i32 {
        return available_result;
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        if (info_result) |result| return result;
        if (info_json.len > out_cap) return -3;
        @memcpy(out_ptr[0..info_json.len], info_json);
        return @intCast(info_json.len);
    }

    fn workspaceExec(
        _: [*]const u8,
        _: usize,
        _: u32,
        _: [*]u8,
        _: usize,
        _: *ResultRecord,
    ) i32 {
        return -2;
    }

    fn workspaceReadFile(_: [*]const u8, _: usize, _: [*]u8, _: usize, _: *ReadRecord) i32 {
        return -2;
    }
};

test "workspace info is unavailable when the host adapter is absent" {
    FakeInfoHost.available_result = 0;
    defer FakeInfoHost.available_result = 1;

    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
}

const FakeExecHost = struct {
    var status: i32 = 0;
    var stdout: []const u8 = "";
    var stderr: []const u8 = "";
    var stdout_total: u32 = 0;
    var stderr_total: u32 = 0;
    var exit_code: i32 = 0;
    var flags: u32 = 0;
    var record_override: ?ResultRecord = null;
    var calls: usize = 0;

    fn workspaceExec(
        _: [*]const u8,
        _: usize,
        _: u32,
        output_ptr: [*]u8,
        output_cap: usize,
        result_ptr: *ResultRecord,
    ) i32 {
        calls += 1;
        if (status != 0) return status;
        if (stdout.len + stderr.len > output_cap) return -4;
        @memcpy(output_ptr[0..stdout.len], stdout);
        @memcpy(output_ptr[stdout.len .. stdout.len + stderr.len], stderr);
        result_ptr.* = record_override orelse .{
            .exit_code = exit_code,
            .stdout_offset = 0,
            .stdout_copied = @intCast(stdout.len),
            .stdout_total = if (stdout_total == 0) @intCast(stdout.len) else stdout_total,
            .stderr_offset = @intCast(stdout.len),
            .stderr_copied = @intCast(stderr.len),
            .stderr_total = if (stderr_total == 0) @intCast(stderr.len) else stderr_total,
            .flags = flags,
        };
        return 0;
    }

    fn reset() void {
        status = 0;
        stdout = "";
        stderr = "";
        stdout_total = 0;
        stderr_total = 0;
        exit_code = 0;
        flags = 0;
        record_override = null;
        calls = 0;
    }
};

const FakeReadHost = struct {
    var status: i32 = 0;
    var content: []const u8 = "";
    var total_bytes: ?u32 = null;
    var copied_override: ?u32 = null;
    var calls: usize = 0;
    var last_out_cap: usize = 0;

    fn workspaceReadFile(_: [*]const u8, _: usize, out_ptr: [*]u8, out_cap: usize, result_ptr: *ReadRecord) i32 {
        calls += 1;
        last_out_cap = out_cap;
        if (status != 0) return status;
        const copied = @min(content.len, out_cap);
        @memcpy(out_ptr[0..copied], content[0..copied]);
        result_ptr.* = .{
            .total_bytes = total_bytes orelse @intCast(content.len),
            .copied_bytes = copied_override orelse @intCast(copied),
        };
        return 0;
    }

    fn reset() void {
        status = 0;
        content = "";
        total_bytes = null;
        copied_override = null;
        calls = 0;
        last_out_cap = 0;
    }
};
