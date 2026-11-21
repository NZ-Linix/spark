//! The one way spark runs git itself: the `spark pr` and `spark issue` snapshot, the
//! agent's auto-run `git status`, `git diff` and `git log`, and the workspace
//! capture route into an spark-owned store. A repository's own
//! config can name programs: fsmonitor, hooks, a pager, diff drivers, filter
//! drivers and a signature verifier. Every invocation turns those off, while
//! the user's global and system config stay trusted, so a global Git LFS still
//! works. When spark cannot establish that, `prepare` refuses and git does not run.
//!
//! TLA+ model: `tests/tla/shell_command/GitAdmission.tla`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const indexer = @import("../indexer/indexer.zig");
const repo_path = @import("../shared/repo_path.zig");

const Allocator = std.mem.Allocator;

/// The oldest git these settings were checked against with planted programs
/// for every route: 2.25.1, 2.34.1 and 2.54.0. `core.fsmonitor` became a
/// boolean in git 2.36; older git runs the value as a hook command, and the
/// fixed PATH resolves `false` to the system `false`, which does nothing.
const minimum_major: u32 = 2;
const minimum_minor: u32 = 25;
/// The capture route needs `init --object-format` and `rev-parse
/// --show-object-format`, both from git 2.29.
const store_minimum_minor: u32 = 29;

const max_probe_output: usize = 4096;

pub const Refusal = enum {
    git_missing,
    git_version_unknown,
    git_too_old,
    repo_config_unavailable,
    /// `-c` splits at the first `=`, so such a driver cannot be blanked.
    unsupported_filter_name,
    /// git would use a different repository than the one whose config spark read.
    repository_mismatch,
    /// git could not list the hooks that config defines.
    hook_config_unavailable,
    /// `-c` splits at the first `=`, so such a hook cannot be turned off.
    unsupported_hook_name,
    /// The caller's deadline passed before git's own checks finished
    /// (`prepareWithin`).
    timed_out,
    /// The caller's cancel flag ended git's own checks (`prepareWithin`, `prepareStore`).
    cancelled,
};

pub const Ready = struct {
    /// Static path from `trustedExecutable`.
    executable: []const u8,
    /// Filter drivers defined by repository-scope config.
    filter_names: []const []const u8,
    /// Hooks that config defines with `hook.<name>.command` (git 2.54), as git reads config in this repository: its own, global and system config and their includes. Each command turns them off.
    hook_names: []const []const u8 = &.{},
    /// The git directory spark's discovery found for the directory, without
    /// running git; null when no repository holds it.
    git_dir: ?[]const u8 = null,
};

pub const Prepared = union(enum) {
    ready: Ready,
    refused: Refusal,
};

pub const Subcommand = enum { status, diff, log, branch, rev_parse };

/// Decides whether git may run in the absolute directory `cwd`: reads the
/// repository's config as data, checks the trusted git's version once per
/// process, and confirms git resolves the same repository spark read. All memory
/// belongs to `arena`.
pub fn prepare(arena: Allocator, cwd: []const u8) Allocator.Error!Prepared {
    return prepareWith(arena, cwd, unbounded_checks) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `runCaptured` has no deadline.
        error.TimeoutExpired => unreachable,
    };
}

/// `prepare` whose own git runs, the version check and `rev-parse`, stop at
/// `limits`' deadline and cancel flag, for a caller with one budget for all
/// its work. A check the deadline ends refuses with `timed_out`.
pub fn prepareWithin(arena: Allocator, cwd: []const u8, limits: Limits) Allocator.Error!Prepared {
    return prepareWith(arena, cwd, boundedChecks(&limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimeoutExpired => return refuse(stoppedBy(limits), cwd),
    };
}

pub const CheckError = Allocator.Error || error{TimeoutExpired};

/// Runs one of `prepare`'s own git checks, `argv` in `cwd`, in safe git's
/// environment. Returns its standard output when it exited 0, or null when
/// it could not start, failed, or printed more than `output_limit` bytes.
/// Memory belongs to `arena`.
pub const CheckRunner = struct {
    context: ?*const anyopaque = null,
    run: *const fn (
        context: ?*const anyopaque,
        arena: Allocator,
        argv: []const []const u8,
        cwd: []const u8,
        output_limit: usize,
    ) CheckError!?[]const u8,
};

const unbounded_checks: CheckRunner = .{ .run = runCheckUnbounded };

fn runCheckUnbounded(_: ?*const anyopaque, arena: Allocator, argv: []const []const u8, cwd: []const u8, output_limit: usize) CheckError!?[]const u8 {
    return runCaptured(arena, argv, cwd, output_limit);
}

/// Checks that stop at `limits`' deadline and its cancel flag, both of which
/// end them with `error.TimeoutExpired`. `limits` must outlive the runner.
fn boundedChecks(limits: *const Limits) CheckRunner {
    return .{ .context = limits, .run = runCheckBounded };
}

fn runCheckBounded(context: ?*const anyopaque, arena: Allocator, argv: []const []const u8, cwd: []const u8, output_limit: usize) CheckError!?[]const u8 {
    const limits: *const Limits = @ptrCast(@alignCast(context.?));
    var env = try environment(arena);
    var probe = limits.*;
    probe.max_stdout = output_limit;
    return switch (try runBounded(arena, argv, cwd, &env, null, null, probe)) {
        .ok => |stdout| stdout,
        .failed => |failure| switch (failure) {
            .timeout, .cancelled => error.TimeoutExpired,
            else => null,
        },
    };
}

/// `prepare` with `checks` running its git checks, so a caller can give them
/// a deadline. A check that returns `error.TimeoutExpired` ends it with no
/// decision, and git does not run; a timed-out version check is not cached.
pub fn prepareWith(arena: Allocator, cwd: []const u8, checks: CheckRunner) CheckError!Prepared {
    const filters = indexer.repoFilters(arena, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => return refuse(.repo_config_unavailable, cwd),
    };
    for (filters.names) |name| {
        if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null) return refuse(.unsupported_filter_name, cwd);
    }
    const executable = trustedExecutable() orelse return refuse(.git_missing, cwd);
    switch (try versionCheck(arena, executable, checks)) {
        .supported => {},
        .too_old => return refuse(.git_too_old, cwd),
        .unknown => return refuse(.git_version_unknown, cwd),
    }
    var ready: Ready = .{ .executable = executable, .filter_names = filters.names, .git_dir = filters.git_dir };
    if (!try sameRepository(arena, ready, cwd, filters.git_dir, checks)) return refuse(.repository_mismatch, cwd);
    // `core.hooksPath=/dev/null` does not reach hooks config defines, so list
    // them as git reads config here and turn each one off.
    const listing = try checks.run(checks.context, arena, &.{ executable, "--no-pager", "config", "-z", "--name-only", "--list" }, cwd, max_config_output) orelse return refuse(.hook_config_unavailable, cwd);
    ready.hook_names = switch (try parseHookNames(arena, listing)) {
        .names => |names| names,
        .unsupported => return refuse(.unsupported_hook_name, cwd),
    };
    return .{ .ready = ready };
}

fn refuse(reason: Refusal, cwd: []const u8) Prepared {
    debug_trace.logf("core", "safe git refused reason={s} cwd={s}", .{ @tagName(reason), cwd });
    return .{ .refused = reason };
}

/// The refusal for a check that `limits` ended: `cancelled` once its flag is
/// set, else `timed_out`.
fn stoppedBy(limits: Limits) Refusal {
    if (limits.cancel) |flag| if (flag.load(.acquire)) return .cancelled;
    return .timed_out;
}

/// Appends the trusted executable, the global options and `-c` overrides that
/// turn off repository programs, then `subcommand` with its own safety flags.
/// Callers append the remaining arguments. Formatted overrides are allocated
/// with `arena`; the other strings are static or borrowed from `ready`.
pub fn appendCommand(
    arena: Allocator,
    argv: *std.ArrayList([]const u8),
    ready: Ready,
    subcommand: Subcommand,
) Allocator.Error!void {
    try appendPrelude(arena, argv, ready);
    try argv.appendSlice(arena, switch (subcommand) {
        .status => &.{ "status", "--ignore-submodules=all" },
        .diff => &.{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .log => &.{ "log", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .branch => &.{"branch"},
        .rev_parse => &.{"rev-parse"},
    });
}

fn appendPrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: Ready) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "log.showSignature=false",
    });
    for (ready.filter_names) |name| {
        for ([_][]const u8{ "clean", "smudge", "process" }) |program| {
            try argv.append(arena, "-c");
            try argv.append(arena, try arena.print("filter.{s}.{s}=", .{ name, program }));
        }
    }
    try appendHooksOff(arena, argv, ready.hook_names);
}

/// `appendPrelude` for spark's own capture reads, which never fetch: a
/// repository whose config names a promisor remote cannot make them start a
/// transport. git before 2.45 ignores `GIT_NO_LAZY_FETCH` (`blockLazyFetch`),
/// and `protocol.allow=never` makes any fetch fail before it starts one.
fn appendCapturePrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: Ready) Allocator.Error!void {
    try appendPrelude(arena, argv, ready);
    try argv.appendSlice(arena, &.{ "-c", "protocol.allow=never" });
}

/// Turns off lazy fetch in `base`, for spark's own capture reads and store
/// commands.
fn blockLazyFetch(base: *std.process.Environ.Map) Allocator.Error!void {
    try base.put("GIT_NO_LAZY_FETCH", "1");
}

/// The child environment for every safe git call: a fixed PATH and locale, no
/// prompts, pagers or optional locks, and only the variables that locate the
/// user's own git config. Nothing else from spark's environment, such as
/// `GIT_DIR` or `GIT_CONFIG_PARAMETERS`, reaches git.
pub fn environment(alloc: Allocator) Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("LC_ALL", "C");
    try map.put("LANG", "C");
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_PAGER", "cat");
    try map.put("PAGER", "cat");
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM" }) |key| {
        if (io_mod.getenv(key)) |value| try map.put(key, value);
    }
    return map;
}

/// The first git found at a fixed system location. git from PATH is never
/// used, because PATH can include directories a repository controls.
fn trustedExecutable() ?[]const u8 {
    const candidates = switch (builtin.target.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
        },
        else => &[_][]const u8{
            "/usr/bin/git",
            "/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/opt/local/bin/git",
            "/run/current-system/sw/bin/git",
        },
    };
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file) return candidate;
    }
    return null;
}

const VersionCheck = enum { supported, too_old, unknown };

var version_lock: std.Io.Mutex = .init;
var cached_version: ?struct { executable: []const u8, output: [64]u8, len: usize } = null;

/// Runs `git --version` once per executable and process. A failed probe is not
/// cached, so a transient spawn failure does not disable git for the session.
fn versionCheck(arena: Allocator, executable: []const u8, checks: CheckRunner) CheckError!VersionCheck {
    return versionCheckAtLeast(arena, executable, minimum_minor, checks);
}

/// `versionCheck` against `min_minor`. The cache keeps git's own output, so
/// routes with different minimums share one probe.
fn versionCheckAtLeast(arena: Allocator, executable: []const u8, min_minor: u32, checks: CheckRunner) CheckError!VersionCheck {
    const io = io_mod.getIo();
    version_lock.lockUncancelable(io);
    defer version_lock.unlock(io);
    if (cached_version) |*cached| {
        if (std.mem.eql(u8, cached.executable, executable)) return classifyVersionAtLeast(cached.output[0..cached.len], min_minor);
    }
    const output = try checks.run(checks.context, arena, &.{ executable, "--version" }, "/", max_probe_output) orelse return .unknown;
    var entry: @TypeOf(cached_version.?) = .{ .executable = executable, .output = undefined, .len = @min(output.len, 64) };
    @memcpy(entry.output[0..entry.len], output[0..entry.len]);
    cached_version = entry;
    return classifyVersionAtLeast(output, min_minor);
}

fn classifyVersionAtLeast(output: []const u8, min_minor: u32) VersionCheck {
    const prefix = "git version ";
    if (!std.mem.startsWith(u8, output, prefix)) return .unknown;
    var parts = std.mem.splitScalar(u8, output[prefix.len..], '.');
    const major = leadingNumber(parts.next() orelse "") orelse return .unknown;
    const minor = leadingNumber(parts.next() orelse "") orelse return .unknown;
    if (major != minimum_major) return if (major > minimum_major) .supported else .too_old;
    return if (minor >= min_minor) .supported else .too_old;
}

fn leadingNumber(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseUnsigned(u32, text[0..end], 10) catch null;
}

/// Confirms git resolves the repository whose config spark read. git accepts a
/// git directory used as the workspace, and spark's discovery does not, so
/// without this check git could run with config spark never read. `rev-parse`
/// reads config but runs none of the programs above.
fn sameRepository(arena: Allocator, ready: Ready, cwd: []const u8, expected: ?[]const u8, checks: CheckRunner) CheckError!bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .rev_parse);
    try argv.append(arena, "--absolute-git-dir");
    const output = try checks.run(checks.context, arena, argv.items, cwd, max_probe_output);
    const expected_dir = expected orelse return output == null;
    const reported = std.mem.trimEnd(u8, output orelse return false, "\r\n");
    const expected_real = io_mod.realpathAlloc(arena, expected_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const reported_real = io_mod.realpathAlloc(arena, reported) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.mem.eql(u8, expected_real, reported_real);
}

/// Standard output of a successful run, or null when git could not start or
/// failed. Memory belongs to `arena`.
fn runCaptured(arena: Allocator, argv: []const []const u8, cwd: []const u8, output_limit: usize) Allocator.Error!?[]const u8 {
    var env = try environment(arena);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

// Workspace capture route. Captures write objects only into an spark-owned bare
// store whose config spark created; the user's repository config is never read
// there. `GIT_DIR`, the capture index and the work tree are set explicitly, so
// git does not discover the user's `.git`. Every command is typed: there is no
// pass-through of arbitrary arguments. Global and system config stay trusted,
// so a worktree `.gitattributes` can still select a filter they define.

/// Bounds for one capture git command. `deadline`, when set, replaces
/// `timeout_ms`, so a whole capture can share one budget.
pub const Limits = struct {
    timeout_ms: i64 = 2000,
    deadline: ?std.Io.Clock.Timestamp = null,
    max_stdout: usize = 64 * 1024 * 1024,
    /// A flag that ends the run as `cancelled` once set: git does not start,
    /// or a running git's process group is ended within `cancel_poll_ms`.
    /// It works apart from `std.Io` cancellation, whose request is spent by
    /// the first cancelation point that sees it, so a helper that swallowed
    /// it cannot leave git running to its deadline.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// How often a running git with a `Limits.cancel` flag looks at it.
const cancel_poll_ms: i64 = 20;

fn cancelRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.acquire);
}

/// Re-arms a `std.Io` cancel request that `err` consumed, so the next
/// cancelation point still sees it. Call once for each `error.Canceled` a
/// helper swallows instead of returning.
fn keepCancel(io: std.Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

const max_capture_stderr: usize = 1024 * 1024;

pub const Failure = enum {
    spawn_failed,
    input_failed,
    read_failed,
    timeout,
    cancelled,
    output_too_large,
    exited_nonzero,
    terminated,
    /// git exited 0 but dropped a path it would not record.
    path_rejected,
    /// Config defines a hook for the store that spark cannot turn off, or the store's hooks could not be listed.
    hooks_refused,
};

pub const Outcome = union(enum) {
    /// Standard output, owned by the arena.
    ok: []const u8,
    failed: Failure,
};

/// The trusted git, checked without reading any repository. Distinct from
/// `Ready` so a store handle cannot reach a route that must blank the
/// repository's own filters.
pub const StoreReady = struct {
    /// Static path from `trustedExecutable`.
    executable: []const u8,
    /// Names of hooks that global or system config defines with
    /// `hook.<name>.command`; each store command turns them off.
    hook_names: []const []const u8 = &.{},
};

/// Most bytes a `git config --name-only --list` reply may have.
const max_config_output: usize = 1 << 20;

/// Hook names that config defines with `hook.<name>.command`, read from
/// `git config -z --name-only --list` output, each once; `unsupported` when
/// a name holds `=`, which `-c` cannot turn off.
const HookNames = union(enum) { names: []const []const u8, unsupported };

fn parseHookNames(arena: Allocator, listing: []const u8) Allocator.Error!HookNames {
    var names: std.ArrayList([]const u8) = .empty;
    var keys = std.mem.splitScalar(u8, listing, 0);
    while (keys.next()) |key| {
        if (!std.mem.startsWith(u8, key, "hook.") or !std.mem.endsWith(u8, key, ".command")) continue;
        // `hook.command` (a `[hook]` section) and `hook..command` (`[hook ""]`)
        // both define a hook whose name is empty, which git still runs.
        const name = if (key.len < "hook.".len + ".command".len) "" else key["hook.".len .. key.len - ".command".len];
        if (std.mem.findScalar(u8, name, '=') != null) return .unsupported;
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try names.append(arena, name);
    }
    return .{ .names = names.items };
}

/// Appends `-c hook.<name>.enabled=false` for each of `names`.
fn appendHooksOff(arena: Allocator, argv: *std.ArrayList([]const u8), names: []const []const u8) Allocator.Error!void {
    for (names) |name| {
        try argv.append(arena, "-c");
        try argv.append(arena, try arena.print("hook.{s}.enabled=false", .{name}));
    }
}

const StoreHooks = union(enum) { names: []const []const u8, failed: Failure };

/// The hooks config defines for `store`, listed in the store's own context
/// (`base` already names its GIT_DIR, index and worktree), so a global
/// `includeIf "gitdir:"` that applies to the store applies here too; joined
/// with `ready.hook_names`.
fn storeHookNames(arena: Allocator, ready: StoreReady, store: Store, base: *std.process.Environ.Map, limits: Limits) Allocator.Error!StoreHooks {
    const argv = [_][]const u8{ ready.executable, "--no-pager", "-c", "core.fsmonitor=false", "config", "-z", "--name-only", "--list" };
    const listing = switch (try runBounded(arena, &argv, store.work_tree, base, null, null, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return .{ .failed = switch (failure) {
            .timeout, .cancelled => failure,
            else => .hooks_refused,
        } },
    };
    const found = switch (try parseHookNames(arena, listing)) {
        .names => |names| names,
        .unsupported => return .{ .failed = .hooks_refused },
    };
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(arena, ready.hook_names);
    for (found) |name| {
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try names.append(arena, name);
    }
    return .{ .names = names.items };
}

pub const PreparedStore = union(enum) {
    ready: StoreReady,
    refused: Refusal,
};

pub const ObjectFormat = enum { sha1, sha256 };

/// Content conversion settings copied from the user's repository, so the
/// store records the same tree the user's git would. Null leaves global
/// config in charge.
pub const Conversions = struct {
    file_mode: ?bool = null,
    symlinks: ?bool = null,
    autocrlf: ?enum { true, false, input } = null,
    eol: ?enum { lf, crlf, native } = null,
};

/// Absolute paths for one capture. `scratch_dir` must exist and be private.
pub const Store = struct {
    git_dir: []const u8,
    index_file: []const u8,
    work_tree: []const u8,
    scratch_dir: []const u8,
    conversions: Conversions = .{},
};

/// The kind of an index entry, as git writes it in octal.
pub const EntryMode = enum {
    file,
    executable,
    symlink,
    gitlink,

    fn text(mode: EntryMode) []const u8 {
        return switch (mode) {
            .file => "100644",
            .executable => "100755",
            .symlink => "120000",
            .gitlink => "160000",
        };
    }

    fn parse(octal: []const u8) ?EntryMode {
        for ([_]EntryMode{ .file, .executable, .symlink, .gitlink }) |mode| {
            if (std.mem.eql(u8, octal, mode.text())) return mode;
        }
        return null;
    }
};

pub const IndexEntry = struct {
    mode: EntryMode,
    oid: []const u8,
    path: []const u8,
};

/// One entry of `ls-files -z --stage -v`, as the capture reads it.
pub const StagedEntry = struct {
    path: []const u8,
    mode: EntryMode,
    oid: []const u8,
    assume_unchanged: bool,
    skip_worktree: bool,
};

/// Parses `ls-files -z --stage -v`: `<tag> <mode> <oid> <stage>\t<path>`.
/// Unmerged paths appear once per stage and collapse to one entry. Entries
/// borrow `listing`; the list belongs to `arena`.
pub fn parseStageListing(arena: Allocator, listing: []const u8) error{ OutOfMemory, Malformed }![]const StagedEntry {
    var entries: std.ArrayList(StagedEntry) = .empty;
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.findScalar(u8, record, '\t') orelse return error.Malformed;
        var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
        const tag = fields.next() orelse return error.Malformed;
        const mode_text = fields.next() orelse return error.Malformed;
        const oid = fields.next() orelse return error.Malformed;
        _ = fields.next() orelse return error.Malformed;
        if (tag.len != 1 or fields.next() != null) return error.Malformed;
        const path = record[tab + 1 ..];
        if (path.len == 0) return error.Malformed;
        if (entries.items.len > 0 and std.mem.eql(u8, entries.items[entries.items.len - 1].path, path)) continue;
        try entries.append(arena, .{
            .path = path,
            .mode = EntryMode.parse(mode_text) orelse return error.Malformed,
            .oid = oid,
            .assume_unchanged = std.ascii.isLower(tag[0]),
            .skip_worktree = std.ascii.toUpper(tag[0]) == 'S',
        });
    }
    return entries.items;
}

pub const StoreCommand = union(enum) {
    /// Loads a tree into the capture index; null empties it.
    read_tree: ?[]const u8,
    /// Adds, refreshes or removes these worktree paths in the capture index.
    /// A path still on disk is kept: `--remove` only drops missing files.
    add_remove: []const []const u8,
    /// Drops these paths from the capture index even when they exist on disk,
    /// such as an untracked file that became ignored.
    force_remove: []const []const u8,
    /// Clears one flag in the capture index only. git applies just the first
    /// of `--no-assume-unchanged` and `--no-skip-worktree` to each path, so
    /// each flag is its own command.
    clear_flag: struct { flag: enum { assume_unchanged, skip_worktree }, paths: []const []const u8 },
    /// Sets entries to the given mode and object without reading the worktree.
    index_info: []const IndexEntry,
    write_tree,
    commit_tree: struct { tree: []const u8, parent: ?[]const u8, message: []const u8, unix_seconds: i64 },
    /// Compare-and-swap; a null `old` requires that the ref does not exist.
    update_ref: struct { ref: []const u8, new: []const u8, old: ?[]const u8 },
    /// `ls-files -z --stage -v` of the capture index: the same format as
    /// `Listing.tracked`, so inherited flags show.
    list_index,
    /// The object a capture ref names, or empty output when it does not exist.
    resolve_ref: []const u8,
    /// Every object `tree` reaches that no tree of the `except` commits
    /// reaches, one ID per line, `tree` included.
    list_objects: struct { tree: []const u8, except: []const []const u8 },
    /// Writes these objects into one new pack in the store, read from the
    /// store or its alternates, so the store holds each one itself. At least
    /// one object: git writes an empty pack for none.
    pack_objects: []const []const u8,
    /// Every capture ref, one `<ref> <object> <unix seconds>` line each; the
    /// time is the newest capture's.
    list_refs,
    /// Deletes a capture ref only while it still names `old`, so a capture
    /// that just moved it keeps it.
    delete_ref: struct { ref: []const u8, old: []const u8 },
    /// Packs every object the refs reach into one pack, the ones the store
    /// reads through its alternates included, drops every other pack, and
    /// prunes every unreachable loose object at once: `repack -a -d` and then
    /// `prune --expire=now`. Not `git gc`, whose repack always passes `-l`
    /// and so drops the copies of objects the alternates also hold, which
    /// captures keep so they never depend on the user's objects. Capture
    /// commits link only to earlier captures, so no user history comes in.
    /// Only for a caller that holds every capture lock of the store, so no
    /// capture has written objects it has not yet named. Prefer `gc_locked`:
    /// a prune that outlives its caller, such as one a killed spark left, can
    /// still be running when the next capture writes objects.
    gc,
    /// `gc`, but the prune keeps every loose object modified at or after
    /// `locked_unix`, the second the caller took every capture lock of the
    /// store: `prune --expire=@<locked_unix - 1>`. Objects a capture writes
    /// after that, even while a prune its killed caller left is still
    /// running, are never deleted. Unreachable objects from before go at once.
    gc_locked: struct { locked_unix: i64 },
    /// Packs every object of the store into one new pack, reachable or not,
    /// with the ones refs reach through the alternates, then drops the old
    /// packs and the loose objects: `repack -a -d -k` without `-l`. Deletes
    /// no object the new pack lacks and prunes nothing. Captures keep the
    /// objects they wrote loose, and with `-l` or `--unpacked` git leaves an
    /// object some alternate pack also holds out of the store's pack, so
    /// whether its loose file survived would depend on git's version.
    repack,
};

pub const Listing = enum {
    /// `ls-files -z --stage -v`: lowercase tags mark assume-unchanged, `S`
    /// marks skip-worktree.
    tracked,
    untracked,
};

pub const StoreError = Allocator.Error || error{InvalidArgument};

const capture_ref_prefix = "refs/spark/sessions/";
const capture_identity_name = "spark capture";
const capture_identity_email = "capture@spark.invalid";
/// Whether git runs in its own process group spark can signal. WASI and
/// freestanding builds, such as the libfx WebAssembly core, have no processes.
const has_process_groups = switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};
/// The capture route's PATH: the system directories plus the fixed places
/// `trustedExecutable` already trusts for git itself. A filter that global or
/// system config names by bare command, such as Homebrew's `git-lfs`, then
/// resolves; the store's own config names none.
const capture_path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/run/current-system/sw/bin";

var input_counter: std.atomic.Value(u32) = .init(0);

pub fn prepareStore(arena: Allocator, limits: Limits) Allocator.Error!PreparedStore {
    var base = try environment(arena);
    return prepareStoreWith(arena, limits, &base);
}

fn prepareStoreWith(arena: Allocator, limits: Limits, base: *std.process.Environ.Map) Allocator.Error!PreparedStore {
    try blockLazyFetch(base);
    const executable = trustedExecutable() orelse return .{ .refused = refuse(.git_missing, "store").refused };
    const version = versionCheckAtLeast(arena, executable, store_minimum_minor, boundedChecks(&limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimeoutExpired => return .{ .refused = refuse(stoppedBy(limits), "store").refused },
    };
    switch (version) {
        .supported => {},
        .too_old => return .{ .refused = refuse(.git_too_old, "store").refused },
        .unknown => return .{ .refused = refuse(.git_version_unknown, "store").refused },
    }
    // git 2.54 lets config define hooks of its own, which
    // `core.hooksPath=/dev/null` does not turn off, so list them here and turn
    // each one off in every store command.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ executable, "--no-pager", "-c", "core.fsmonitor=false", "config", "-z", "--name-only", "--list" });
    const hook_names: []const []const u8 = switch (try runBounded(arena, argv.items, "/", base, null, null, limits)) {
        .ok => |stdout| switch (try parseHookNames(arena, stdout)) {
            .names => |names| names,
            .unsupported => return .{ .refused = refuse(.unsupported_hook_name, "store").refused },
        },
        .failed => |failure| switch (failure) {
            .timeout => return .{ .refused = refuse(.timed_out, "store").refused },
            .cancelled => return .{ .refused = refuse(.cancelled, "store").refused },
            else => return .{ .refused = refuse(.hook_config_unavailable, "store").refused },
        },
    };
    return .{ .ready = .{ .executable = executable, .hook_names = hook_names } };
}

/// Creates the bare store without templates, so it has no hooks, in the
/// object format of the repository whose objects it borrows.
pub fn initStore(arena: Allocator, ready: StoreReady, git_dir: []const u8, format: ObjectFormat, limits: Limits) StoreError!Outcome {
    var base = try environment(arena);
    return initStoreWith(arena, ready, git_dir, format, limits, &base);
}

fn initStoreWith(
    arena: Allocator,
    ready: StoreReady,
    git_dir: []const u8,
    format: ObjectFormat,
    limits: Limits,
    base: *std.process.Environ.Map,
) StoreError!Outcome {
    try blockLazyFetch(base);
    if (!std.Io.Dir.path.isAbsolute(git_dir)) return error.InvalidArgument;
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStorePrelude(arena, &argv, ready, .{});
    try argv.appendSlice(arena, &.{ "init", "-q", "--bare", "--template=", switch (format) {
        .sha1 => "--object-format=sha1",
        .sha256 => "--object-format=sha256",
    }, git_dir });
    return runBounded(arena, argv.items, "/", base, null, null, limits);
}

/// Runs one typed command against the capture store. Memory belongs to
/// `arena`.
pub fn runStore(arena: Allocator, ready: StoreReady, store: Store, command: StoreCommand, limits: Limits) StoreError!Outcome {
    var base = try environment(arena);
    return runStoreWith(arena, ready, store, command, limits, &base, capture_path);
}

fn runStoreWith(
    arena: Allocator,
    ready: StoreReady,
    store: Store,
    command: StoreCommand,
    limits: Limits,
    base: *std.process.Environ.Map,
    route_path: []const u8,
) StoreError!Outcome {
    try blockLazyFetch(base);
    for ([_][]const u8{ store.git_dir, store.index_file, store.work_tree, store.scratch_dir }) |dir| {
        if (!std.Io.Dir.path.isAbsolute(dir)) return error.InvalidArgument;
    }
    if (comptime builtin.target.os.tag != .windows) try base.put("PATH", route_path);
    try base.put("GIT_DIR", store.git_dir);
    try base.put("GIT_INDEX_FILE", store.index_file);
    try base.put("GIT_WORK_TREE", store.work_tree);
    try base.put("GIT_AUTHOR_NAME", capture_identity_name);
    try base.put("GIT_AUTHOR_EMAIL", capture_identity_email);
    try base.put("GIT_COMMITTER_NAME", capture_identity_name);
    try base.put("GIT_COMMITTER_EMAIL", capture_identity_email);
    var argv: std.ArrayList([]const u8) = .empty;
    var input: std.ArrayList(u8) = .empty;
    var has_input = false;
    var reads_paths = false;
    switch (command) {
        .read_tree => |tree| {
            try argv.append(arena, "read-tree");
            if (tree) |oid| {
                try validateOid(oid);
                try argv.append(arena, oid);
            } else try argv.append(arena, "--empty");
        },
        .add_remove, .force_remove, .clear_flag => {
            const paths = switch (command) {
                .add_remove, .force_remove => |value| value,
                .clear_flag => |value| value.paths,
                else => unreachable,
            };
            try argv.appendSlice(arena, switch (command) {
                .add_remove => &.{ "update-index", "--add", "--remove", "-z", "--stdin" },
                .force_remove => &.{ "update-index", "--force-remove", "-z", "--stdin" },
                .clear_flag => |value| switch (value.flag) {
                    .assume_unchanged => &.{ "update-index", "--no-assume-unchanged", "-z", "--stdin" },
                    .skip_worktree => &.{ "update-index", "--no-skip-worktree", "-z", "--stdin" },
                },
                else => unreachable,
            });
            for (paths) |path| {
                if (!repo_path.isValid(path)) return error.InvalidArgument;
                try input.appendSlice(arena, path);
                try input.append(arena, 0);
            }
            has_input = true;
            reads_paths = true;
        },
        .index_info => |entries| {
            try argv.appendSlice(arena, &.{ "update-index", "-z", "--index-info" });
            for (entries) |entry| {
                try validateOid(entry.oid);
                if (!repo_path.isValid(entry.path)) return error.InvalidArgument;
                try input.print(arena, "{s} {s}\t{s}\x00", .{ entry.mode.text(), entry.oid, entry.path });
            }
            has_input = true;
            reads_paths = true;
        },
        .write_tree => try argv.append(arena, "write-tree"),
        .commit_tree => |commit| {
            try validateOid(commit.tree);
            if (commit.message.len == 0 or std.mem.findScalar(u8, commit.message, 0) != null) return error.InvalidArgument;
            try argv.appendSlice(arena, &.{ "commit-tree", commit.tree });
            if (commit.parent) |parent| {
                try validateOid(parent);
                try argv.appendSlice(arena, &.{ "-p", parent });
            }
            // The `@` form: git rejects a bare small number as an ambiguous date.
            const date = try arena.print("@{d} +0000", .{commit.unix_seconds});
            try base.put("GIT_AUTHOR_DATE", date);
            try base.put("GIT_COMMITTER_DATE", date);
            try input.appendSlice(arena, commit.message);
            has_input = true;
        },
        .update_ref => |update| {
            try validateRef(update.ref);
            try validateOid(update.new);
            const old = update.old orelse zeroOid(update.new.len);
            try validateOid(old);
            if (old.len != update.new.len) return error.InvalidArgument;
            try argv.appendSlice(arena, &.{ "update-ref", "--no-deref", update.ref, update.new, old });
        },
        .list_index => try argv.appendSlice(arena, &.{ "ls-files", "-z", "--stage", "-v" }),
        .resolve_ref => |ref| {
            try validateRef(ref);
            // `for-each-ref` prints nothing for a missing ref and still exits 0.
            try argv.appendSlice(arena, &.{ "for-each-ref", "--format=%(objectname)", ref });
        },
        .list_objects => |list| {
            try validateOid(list.tree);
            try argv.appendSlice(arena, &.{ "rev-list", "--objects", "--no-object-names", "--stdin" });
            // A negative commit is never walked when the positive tip is a
            // tree, so its tree is named instead. Each one is a `^` line:
            // `--stdin` takes `--not` only since git 2.42, and the store
            // route supports git back to 2.29.
            try input.print(arena, "{s}\n", .{list.tree});
            for (list.except) |commit| {
                try validateOid(commit);
                try input.print(arena, "^{s}^{{tree}}\n", .{commit});
            }
            has_input = true;
        },
        .pack_objects => |objects| {
            if (objects.len == 0) return error.InvalidArgument;
            // No `--local`, so objects the alternates hold are copied too.
            // `--window=0` skips the delta search: deltas whose base is in
            // the pack are still reused, the rest are written whole.
            try argv.appendSlice(arena, &.{ "pack-objects", "-q", "--window=0", try std.Io.Dir.path.join(arena, &.{ store.git_dir, "objects", "pack", "pack" }) });
            for (objects) |oid| {
                try validateOid(oid);
                try input.print(arena, "{s}\n", .{oid});
            }
            has_input = true;
        },
        .list_refs => try argv.appendSlice(arena, &.{ "for-each-ref", "--format=%(refname) %(objectname) %(committerdate:unix)", capture_ref_prefix }),
        .delete_ref => |delete| {
            try validateRef(delete.ref);
            try validateOid(delete.old);
            try argv.appendSlice(arena, &.{ "update-ref", "--no-deref", "-d", delete.ref, delete.old });
        },
        // No `-l`; `-n` skips the server info a bare store never serves, and
        // no bitmap is written. The prune follows below.
        .gc, .gc_locked => try argv.appendSlice(arena, &.{ "repack", "-a", "-d", "-q", "-n", "--no-write-bitmap-index" }),
        // `-k` packs unreachable objects too, loose ones included.
        .repack => try argv.appendSlice(arena, &.{ "repack", "-a", "-d", "-k", "-q", "-n", "--no-write-bitmap-index" }),
    }
    // Config can define hooks for this store alone, such as through a global
    // `includeIf "gitdir:"`, so they are listed in the store's own context.
    var store_ready = ready;
    store_ready.hook_names = switch (try storeHookNames(arena, ready, store, base, limits)) {
        .names => |names| names,
        .failed => |failure| return .{ .failed = failure },
    };
    var full_argv: std.ArrayList([]const u8) = .empty;
    try appendStorePrelude(arena, &full_argv, store_ready, store.conversions);
    try full_argv.appendSlice(arena, argv.items);
    const outcome = try runBoundedWithStderr(arena, full_argv.items, store.work_tree, base, if (has_input) input.items else null, store.scratch_dir, limits);
    // `update-index` reports a path it refuses (an HFS or NTFS spelling of
    // `.git`, for example) and still exits 0. A capture missing an admitted
    // path must not look complete.
    if (reads_paths and outcome.result == .ok and std.mem.find(u8, outcome.stderr, "Ignoring path") != null) {
        debug_trace.logf("core", "capture git rejected a path command={s} stderr={s}", .{
            @tagName(command),
            outcome.stderr[0..@min(outcome.stderr.len, 512)],
        });
        return .{ .failed = .path_rejected };
    }
    // `repack -a -d` keeps unreachable loose objects; the prune deletes them,
    // and the temporary files of a pack a killed git left, up to its expiry.
    const prune_expire: ?[]const u8 = switch (command) {
        .gc => "--expire=now",
        // git prunes an object whose modification second is at or before
        // the expiry, so the second before the locks keeps every later one.
        .gc_locked => |gc| try arena.print("--expire=@{d}", .{gc.locked_unix - 1}),
        else => null,
    };
    if (prune_expire != null and outcome.result == .ok) {
        argv.clearRetainingCapacity();
        try appendStorePrelude(arena, &argv, ready, store.conversions);
        try argv.appendSlice(arena, &.{ "prune", prune_expire.? });
        return (try runBoundedWithStderr(arena, argv.items, store.work_tree, base, null, store.scratch_dir, limits)).result;
    }
    return outcome.result;
}

/// Lists the whole user's repository containing `cwd` with the same prelude
/// as the agent's read-only git, as the fallback when the native indexer
/// refuses a format. Paths are relative to the worktree root. `ready` must
/// come from `prepare` for this `cwd`. git neither enters nor lists
/// `skip_folder`, a worktree-relative folder, when one is given.
pub fn listRepository(arena: Allocator, ready: Ready, cwd: []const u8, listing: Listing, skip_folder: ?[]const u8, limits: Limits) Allocator.Error!Outcome {
    var base = try environment(arena);
    return listRepositoryWith(arena, ready, cwd, listing, skip_folder, limits, &base);
}

fn listRepositoryWith(
    arena: Allocator,
    ready: Ready,
    cwd: []const u8,
    listing: Listing,
    skip_folder: ?[]const u8,
    limits: Limits,
    base: *std.process.Environ.Map,
) Allocator.Error!Outcome {
    try blockLazyFetch(base);
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &argv, ready);
    try argv.appendSlice(arena, switch (listing) {
        .tracked => &.{ "ls-files", "-z", "--full-name", "--stage", "-v", "--", ":/" },
        .untracked => &.{ "ls-files", "-z", "--full-name", "--others", "--exclude-standard", "--", ":/" },
    });
    if (skip_folder) |folder| try argv.append(arena, try arena.print(":(top,literal,exclude){s}", .{folder}));
    return runBounded(arena, argv.items, cwd, base, null, null, limits);
}

/// What a capture needs to know about the user's repository, read through
/// the agent's read-only prelude: git reads config as data and runs nothing.
pub const RepositoryFacts = struct {
    /// Absolute paths as git resolves them from the directory it ran in.
    work_tree: []const u8,
    git_dir: []const u8,
    common_dir: []const u8,
    /// HEAD's commit, or null in an unborn repository.
    head: ?[]const u8,
    object_format: ObjectFormat,
    sparse_index: bool,
    split_index: bool,
    /// The repository's own conversion settings, so the store records the
    /// same tree; null where the repository leaves the setting unset.
    conversions: Conversions,
    /// Path comparisons git makes without case, or on precomposed Unicode.
    ignore_case: bool = false,
    precompose_unicode: bool = false,
};

/// Why `repositoryFacts` could not read the repository.
pub const FactsFailure = enum {
    /// git could not start.
    spawn_failed,
    /// A git run passed its deadline.
    timeout,
    /// The caller's task was cancelled during a git run.
    cancelled,
    /// `rev-parse` could not report the repository's paths and format.
    paths_unreadable,
    /// git answered, but not in the shape spark asked for.
    unexpected_output,
    /// HEAD names a broken ref or something other than a commit.
    head_unreadable,
    /// `config --list` failed.
    config_unreadable,
};

pub const FactsResult = union(enum) {
    ok: RepositoryFacts,
    failed: FactsFailure,
};

/// Reads `RepositoryFacts` for the repository at `cwd`, or why git could not.
/// `ready` must come from `prepare` for this `cwd`.
pub fn repositoryFacts(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits) Allocator.Error!FactsResult {
    var base = try environment(arena);
    return repositoryFactsWith(arena, ready, cwd, limits, &base);
}

/// The most path bytes one `pathsInTree` run puts on git's command line, well
/// under every system's argument limit (macOS allows 1 MiB for arguments and
/// environment together).
const max_tree_query_bytes: usize = 64 * 1024;

/// Which of `paths` the tree of commit `head` holds, read with `ls-tree`
/// through the read-only route, in batches that keep each command line under
/// `max_tree_query_bytes`; null when git could not answer. Paths match
/// literally, never as patterns. Memory belongs to `arena`.
pub fn pathsInTree(arena: Allocator, ready: Ready, cwd: []const u8, head: []const u8, paths: []const []const u8, limits: Limits) Allocator.Error!?[]const []const u8 {
    if (paths.len == 0) return &.{};
    var base = try environment(arena);
    try blockLazyFetch(&base);
    var found: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < paths.len) {
        var argv: std.ArrayList([]const u8) = .empty;
        try appendCapturePrelude(arena, &argv, ready);
        try argv.appendSlice(arena, &.{ "--literal-pathspecs", "ls-tree", "-r", "-z", "--name-only", "--full-tree", head, "--" });
        var bytes: usize = 0;
        while (start < paths.len) {
            const path = paths[start];
            const next = bytes + path.len + 1;
            if (bytes > 0 and next > max_tree_query_bytes) break;
            try argv.append(arena, path);
            bytes = next;
            start += 1;
        }
        const listing = switch (try runBounded(arena, argv.items, cwd, &base, null, null, limits)) {
            .ok => |stdout| stdout,
            .failed => return null,
        };
        var names = std.mem.splitScalar(u8, listing, 0);
        while (names.next()) |name| if (name.len > 0) try found.append(arena, name);
    }
    return found.items;
}

/// The failure kinds every git run shares; `otherwise` names the step that
/// failed for the rest.
fn factsFailure(failure: Failure, otherwise: FactsFailure) FactsResult {
    return .{ .failed = switch (failure) {
        .spawn_failed => .spawn_failed,
        .timeout => .timeout,
        .cancelled => .cancelled,
        .input_failed, .read_failed, .output_too_large, .exited_nonzero, .terminated, .path_rejected, .hooks_refused => otherwise,
    } };
}

fn repositoryFactsWith(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits, base: *std.process.Environ.Map) Allocator.Error!FactsResult {
    try blockLazyFetch(base);
    const unexpected: FactsResult = .{ .failed = .unexpected_output };
    // One line per option, in order. `--git-common-dir` may be relative to
    // `cwd`; the other two are absolute.
    var paths_argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &paths_argv, ready);
    try paths_argv.append(arena, "rev-parse");
    try paths_argv.appendSlice(arena, &.{ "--show-object-format", "--show-toplevel", "--absolute-git-dir", "--git-common-dir" });
    const paths_output = switch (try runBounded(arena, paths_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return factsFailure(failure, .paths_unreadable),
    };
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, paths_output, "\n"), '\n');
    const format_output = lines.next() orelse return unexpected;
    const work_tree = lines.next() orelse return unexpected;
    const git_dir = lines.next() orelse return unexpected;
    const common_raw = lines.next() orelse return unexpected;
    if (lines.next() != null or !std.Io.Dir.path.isAbsolute(work_tree) or !std.Io.Dir.path.isAbsolute(git_dir)) return unexpected;
    const common_dir = if (std.Io.Dir.path.isAbsolute(common_raw)) common_raw else try std.Io.Dir.path.resolve(arena, &.{ cwd, common_raw });
    const object_format: ObjectFormat = if (std.mem.eql(u8, format_output, "sha1"))
        .sha1
    else if (std.mem.eql(u8, format_output, "sha256"))
        .sha256
    else
        return unexpected;

    // `--verify -q` exits 1 with no output in an unborn repository, but also
    // when HEAD names a broken ref or an object that is not a commit, so a
    // failure counts as unborn only after `headIsUnborn` confirms it.
    var head_argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &head_argv, ready);
    try head_argv.append(arena, "rev-parse");
    try head_argv.appendSlice(arena, &.{ "--verify", "-q", "HEAD^{commit}" });
    const head: ?[]const u8 = switch (try runBounded(arena, head_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => |failure| if (failure != .exited_nonzero)
            return factsFailure(failure, .head_unreadable)
        else switch (try headIsUnborn(arena, ready, cwd, limits, base)) {
            .unborn => null,
            .born_or_broken => return .{ .failed = .head_unreadable },
            .failed => |check_failure| return factsFailure(check_failure, .head_unreadable),
        },
    };
    if (head) |oid| validateOid(oid) catch return unexpected;

    var config_argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &config_argv, ready);
    try config_argv.appendSlice(arena, &.{ "config", "-z", "--list" });
    const config = switch (try runBounded(arena, config_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return factsFailure(failure, .config_unreadable),
    };
    var facts: RepositoryFacts = .{
        .work_tree = work_tree,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .head = head,
        .object_format = object_format,
        .sparse_index = false,
        .split_index = false,
        .conversions = .{},
    };
    // Later values win, as in git. `--list` reports keys in lowercase.
    var entries = std.mem.splitScalar(u8, config, 0);
    while (entries.next()) |entry| {
        const newline = std.mem.findScalar(u8, entry, '\n');
        const key = if (newline) |at| entry[0..at] else entry;
        // A key with no `=` has no value line; git reads it as true.
        const value: ?[]const u8 = if (newline) |at| entry[at + 1 ..] else null;
        if (std.mem.eql(u8, key, "index.sparse")) {
            facts.sparse_index = indexer.parseConfigBool(value) orelse facts.sparse_index;
        } else if (std.mem.eql(u8, key, "core.splitindex")) {
            facts.split_index = indexer.parseConfigBool(value) orelse facts.split_index;
        } else if (std.mem.eql(u8, key, "core.ignorecase")) {
            facts.ignore_case = indexer.parseConfigBool(value) orelse facts.ignore_case;
        } else if (std.mem.eql(u8, key, "core.precomposeunicode")) {
            facts.precompose_unicode = indexer.parseConfigBool(value) orelse facts.precompose_unicode;
        } else if (std.mem.eql(u8, key, "core.filemode")) {
            facts.conversions.file_mode = indexer.parseConfigBool(value) orelse facts.conversions.file_mode;
        } else if (std.mem.eql(u8, key, "core.symlinks")) {
            facts.conversions.symlinks = indexer.parseConfigBool(value) orelse facts.conversions.symlinks;
        } else if (std.mem.eql(u8, key, "core.autocrlf")) {
            if (value != null and std.ascii.eqlIgnoreCase(value.?, "input")) {
                facts.conversions.autocrlf = .input;
            } else if (indexer.parseConfigBool(value)) |enabled| {
                facts.conversions.autocrlf = if (enabled) .true else .false;
            }
        } else if (std.mem.eql(u8, key, "core.eol")) {
            const eol = value orelse continue;
            if (std.ascii.eqlIgnoreCase(eol, "lf")) facts.conversions.eol = .lf else if (std.ascii.eqlIgnoreCase(eol, "crlf")) facts.conversions.eol = .crlf else if (std.ascii.eqlIgnoreCase(eol, "native")) facts.conversions.eol = .native;
        }
    }
    return .{ .ok = facts };
}

/// Whether HEAD is a symbolic ref to a branch that does not exist yet, the
/// only state a capture records as unborn. A detached HEAD, a HEAD that names
/// something other than a branch, and a branch that exists but does not
/// resolve to a commit are all unreadable. `symbolic-ref` itself fails when
/// the branch file is corrupt, so the `rev-parse` below fails only for a
/// missing branch.
///
/// Only a git run that exits nonzero answers the question. Any other run
/// failure, such as a timeout or cancellation, is `failed`, so the caller
/// reports why git could not answer rather than an unreadable HEAD.
fn headIsUnborn(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits, base: *std.process.Environ.Map) Allocator.Error!HeadCheck {
    var symbolic_argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &symbolic_argv, ready);
    try symbolic_argv.appendSlice(arena, &.{ "symbolic-ref", "-q", "HEAD" });
    const ref = switch (try runBounded(arena, symbolic_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => |failure| return if (failure == .exited_nonzero) .born_or_broken else .{ .failed = failure },
    };
    // The ref starts with `refs/`, so git cannot read it as an option.
    if (!std.mem.startsWith(u8, ref, "refs/heads/") or ref.len == "refs/heads/".len) return .born_or_broken;
    if (std.mem.findAny(u8, ref, "\n\r\x00") != null) return .born_or_broken;
    var verify_argv: std.ArrayList([]const u8) = .empty;
    try appendCapturePrelude(arena, &verify_argv, ready);
    try verify_argv.append(arena, "rev-parse");
    try verify_argv.appendSlice(arena, &.{ "--verify", "-q", ref });
    return switch (try runBounded(arena, verify_argv.items, cwd, base, null, null, limits)) {
        .ok => .born_or_broken,
        .failed => |failure| if (failure == .exited_nonzero) .unborn else .{ .failed = failure },
    };
}

const HeadCheck = union(enum) {
    unborn,
    born_or_broken,
    failed: Failure,
};

fn appendStorePrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: StoreReady, conversions: Conversions) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
        "--no-replace-objects",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        // Store commands never fetch: git before 2.45 ignores GIT_NO_LAZY_FETCH,
        // and protocol.allow=never makes any fetch fail before it starts a
        // transport.
        "-c",
        "protocol.allow=never",
        "-c",
        "core.logAllRefUpdates=false",
        "-c",
        "core.splitIndex=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "index.sparse=false",
        "-c",
        "gc.auto=0",
        "-c",
        "maintenance.auto=false",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "log.showSignature=false",
    });
    try appendHooksOff(arena, argv, ready.hook_names);
    if (conversions.file_mode) |value| try argv.appendSlice(arena, &.{ "-c", if (value) "core.fileMode=true" else "core.fileMode=false" });
    if (conversions.symlinks) |value| try argv.appendSlice(arena, &.{ "-c", if (value) "core.symlinks=true" else "core.symlinks=false" });
    if (conversions.autocrlf) |value| try argv.appendSlice(arena, &.{ "-c", switch (value) {
        .true => "core.autocrlf=true",
        .false => "core.autocrlf=false",
        .input => "core.autocrlf=input",
    } });
    if (conversions.eol) |value| try argv.appendSlice(arena, &.{ "-c", switch (value) {
        .lf => "core.eol=lf",
        .crlf => "core.eol=crlf",
        .native => "core.eol=native",
    } });
}

/// Whether `text` is an object ID of `format`: lowercase hex of its length.
pub fn isOid(text: []const u8, format: ObjectFormat) bool {
    const len: usize = switch (format) {
        .sha1 => 40,
        .sha256 => 64,
    };
    if (text.len != len) return false;
    for (text) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn validateOid(oid: []const u8) error{InvalidArgument}!void {
    if (!isOid(oid, .sha1) and !isOid(oid, .sha256)) return error.InvalidArgument;
}

/// `refs/spark/sessions/<session>/<worktree>`, each segment
/// `[A-Za-z0-9_-]{1,128}`. Exactly two segments: a one-segment ref would block
/// every worktree ref of that session, which git stores below it.
fn validateRef(ref: []const u8) error{InvalidArgument}!void {
    if (!std.mem.startsWith(u8, ref, capture_ref_prefix)) return error.InvalidArgument;
    var segments = std.mem.splitScalar(u8, ref[capture_ref_prefix.len..], '/');
    var count: usize = 0;
    while (segments.next()) |name| : (count += 1) {
        if (count == 2 or name.len == 0 or name.len > 128) return error.InvalidArgument;
        for (name) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return error.InvalidArgument,
        };
    }
    if (count != 2) return error.InvalidArgument;
}

fn zeroOid(len: usize) []const u8 {
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    return zeros[0..len];
}

fn runBounded(
    arena: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    input: ?[]const u8,
    scratch_dir: ?[]const u8,
    limits: Limits,
) Allocator.Error!Outcome {
    return (try runBoundedWithStderr(arena, argv, cwd, env, input, scratch_dir, limits)).result;
}

const BoundedRun = struct {
    result: Outcome,
    /// Buffered standard error, owned by the arena; empty on early failure.
    stderr: []const u8 = "",
};

/// Runs `argv` in its own process group with a deadline, bounded output and
/// optional input. On every early return the whole group gets SIGTERM, so a
/// slow filter git started dies with it and git removes its index lock.
fn runBoundedWithStderr(
    arena: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    input: ?[]const u8,
    scratch_dir: ?[]const u8,
    limits: Limits,
) Allocator.Error!BoundedRun {
    const io = io_mod.getIo();
    // A capture that already spent its shared budget, or was cancelled,
    // starts nothing.
    if (limits.deadline) |at| {
        if (at.compare(.lte, .now(io, at.clock))) return .{ .result = .{ .failed = .timeout } };
    }
    if (cancelRequested(limits.cancel)) return .{ .result = .{ .failed = .cancelled } };
    var input_file: ?std.Io.File = null;
    var input_path: ?[]const u8 = null;
    defer {
        if (input_file) |file| file.close(io);
        if (input_path) |path| std.Io.Dir.deleteFileAbsolute(io, path) catch |err| keepCancel(io, err);
    }
    if (input) |bytes| {
        const dir = scratch_dir orelse return .{ .result = .{ .failed = .input_failed } };
        const name = try arena.print("safe-git-input-{d}-{d}", .{ io_mod.nanoTimestamp(), input_counter.fetchAdd(1, .monotonic) });
        const path = try std.Io.Dir.path.join(arena, &.{ dir, name });
        writeInput(io, path, bytes) catch |err| return inputFailed(io, err);
        input_path = path;
        input_file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| return inputFailed(io, err);
        // Once open, the name is no longer needed; drop it so a crash leaves
        // no file naming the captured paths.
        if (comptime has_process_groups) {
            std.Io.Dir.deleteFileAbsolute(io, path) catch |err| keepCancel(io, err);
            input_path = null;
        }
    }

    var options: std.process.SpawnOptions = .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = if (input_file) |file| .{ .file = file } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    };
    if (comptime has_process_groups) options.pgid = 0;
    var child = std.process.spawn(io, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .result = .{ .failed = .spawn_failed } },
    };
    var finished = false;
    defer {
        if (!finished) terminateGroup(&child);
        child.kill(io);
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline: std.Io.Clock.Timestamp = limits.deadline orelse
        .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(limits.timeout_ms) });
    // With a cancel flag, each wait ends by `cancel_poll_ms` to look at it.
    while (true) {
        if (cancelRequested(limits.cancel)) return .{ .result = .{ .failed = .cancelled } };
        const wait_until: std.Io.Clock.Timestamp = if (limits.cancel == null) deadline else blk: {
            const poll = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = deadline.clock, .raw = .fromMilliseconds(cancel_poll_ms) });
            break :blk if (poll.compare(.lt, deadline)) poll else deadline;
        };
        reader.fill(64, .{ .deadline = wait_until }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (deadline.compare(.lte, .now(io, deadline.clock))) return .{ .result = .{ .failed = .timeout } };
                continue;
            },
            error.Canceled => {
                io.recancel();
                return .{ .result = .{ .failed = .cancelled } };
            },
            else => return .{ .result = .{ .failed = .read_failed } },
        };
        if (reader.reader(0).buffered().len > limits.max_stdout) return .{ .result = .{ .failed = .output_too_large } };
        if (reader.reader(1).buffered().len > max_capture_stderr) return .{ .result = .{ .failed = .output_too_large } };
    }
    reader.checkAnyError() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {
            io.recancel();
            return .{ .result = .{ .failed = .cancelled } };
        },
        else => return .{ .result = .{ .failed = .read_failed } },
    };
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return .{ .result = .{ .failed = .cancelled } };
        },
        else => return .{ .result = .{ .failed = .read_failed } },
    };
    finished = true;
    const stdout = try reader.toOwnedSlice(0);
    const stderr = try reader.toOwnedSlice(1);
    switch (term) {
        .exited => |code| if (code == 0) return .{ .result = .{ .ok = stdout }, .stderr = stderr },
        else => {},
    }
    debug_trace.logf("core", "capture git failed command={s} term={t} stderr={s}", .{
        if (argv.len > 0) argv[argv.len - 1] else "",
        term,
        stderr[0..@min(stderr.len, 512)],
    });
    return .{ .result = .{ .failed = if (term == .exited) .exited_nonzero else .terminated }, .stderr = stderr };
}

/// `input_failed`, or `cancelled` when a cancel request ended the write.
fn inputFailed(io: std.Io, err: anyerror) BoundedRun {
    if (err != error.Canceled) return .{ .result = .{ .failed = .input_failed } };
    io.recancel();
    return .{ .result = .{ .failed = .cancelled } };
}

fn writeInput(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch |err| keepCancel(io, err);
    try file.writeStreamingAll(io, bytes);
}

/// Sends SIGTERM to the child's process group, which includes any filter git
/// started, then SIGCONT: the group runs in the background of spark's terminal,
/// so a member stopped by reading it would otherwise never act on SIGTERM and
/// `child.kill` would wait for it forever.
fn terminateGroup(child: *std.process.Child) void {
    // A block, not an early return: the signal names do not exist on hosts
    // without process groups, such as WASI, and Zig checks code after a
    // comptime return.
    if (comptime has_process_groups) {
        const pid = child.id orelse return;
        for ([_]std.posix.SIG{ .TERM, .CONT }) |signal| {
            std.posix.kill(-pid, signal) catch |err| switch (err) {
                error.ProcessNotFound => return,
                else => debug_trace.logf("core", "capture git group signal failed sig={t} err={s}", .{ signal, @errorName(err) }),
            };
        }
    }
}

test "git version check requires 2.25 and reads vendor suffixes" {
    const cases = [_]struct { output: []const u8, expected: VersionCheck }{
        .{ .output = "git version 2.50.1 (Apple Git-155)\n", .expected = .supported },
        .{ .output = "git version 2.36.0\n", .expected = .supported },
        .{ .output = "git version 2.34.1\n", .expected = .supported },
        .{ .output = "git version 2.25.0\n", .expected = .supported },
        .{ .output = "git version 2.39.3.windows.1\n", .expected = .supported },
        .{ .output = "git version 3.0.0\n", .expected = .supported },
        .{ .output = "git version 2.24.4\n", .expected = .too_old },
        .{ .output = "git version 1.9.5\n", .expected = .too_old },
        .{ .output = "hub version 2.14\n", .expected = .unknown },
        .{ .output = "git version x.y\n", .expected = .unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, classifyVersionAtLeast(case.output, minimum_minor));
    // The capture route needs 2.29.
    try std.testing.expectEqual(VersionCheck.too_old, classifyVersionAtLeast("git version 2.28.0\n", store_minimum_minor));
    try std.testing.expectEqual(VersionCheck.supported, classifyVersionAtLeast("git version 2.29.0\n", store_minimum_minor));
}

/// A real repository with a sentinel program that appends to a log whenever
/// git runs it. Setup and control runs use plain git; helper runs use the
/// helper's environment. Both are isolated from the developer's git config.
/// There is no pager route here: git never pages when its output is not a
/// terminal, and spark always pipes it, so `--no-pager` and `GIT_PAGER=cat` are
/// covered by the argv and environment tests above.
const SentinelRepo = struct {
    arena: Allocator,
    git: []const u8,
    root: []const u8,
    repo: []const u8,
    home: []const u8,
    log: []const u8,
    sentinel: []const u8,

    const Mode = union(enum) {
        plain,
        /// The helper's environment, optionally reading this system config.
        safe: ?[]const u8,
    };

    fn init(arena: Allocator, dir: std.Io.Dir) !SentinelRepo {
        const git = trustedExecutable() orelse return error.SkipZigTest;
        if (try versionCheck(arena, git, unbounded_checks) != .supported) return error.SkipZigTest;
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const self: SentinelRepo = .{
            .arena = arena,
            .git = git,
            .root = root,
            .repo = try std.Io.Dir.path.join(arena, &.{ root, "repo" }),
            .home = try std.Io.Dir.path.join(arena, &.{ root, "home" }),
            .log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
        };
        try dir.createDirPath(std.testing.io, "home");
        try dir.createDirPath(std.testing.io, "repo");
        try self.writeExecutable(self.sentinel);
        try self.plain(self.repo, &.{ "init", "-q", "--template=", "-b", "main" });
        try self.write("repo/a.txt", "one\n");
        try self.plain(self.repo, &.{ "add", "a.txt" });
        try self.commit(self.repo);
        return self;
    }

    fn path(self: SentinelRepo, sub_path: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    fn writeExecutable(self: SentinelRepo, absolute: []const u8) !void {
        const script = try self.arena.print("#!/bin/sh\necho ran >> '{s}'\ncat\n", .{self.log});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    }

    fn write(self: SentinelRepo, sub_path: []const u8, data: []const u8) !void {
        const absolute = try self.path(sub_path);
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn commit(self: SentinelRepo, cwd: []const u8) !void {
        try self.plain(cwd, &.{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "fixture" });
    }

    fn childEnvironment(self: SentinelRepo, mode: Mode) !std.process.Environ.Map {
        var env = switch (mode) {
            .plain => blk: {
                var plain_env = std.process.Environ.Map.init(self.arena);
                try plain_env.put("PATH", "/usr/bin:/bin");
                try plain_env.put("LC_ALL", "C");
                break :blk plain_env;
            },
            .safe => try environment(self.arena),
        };
        try env.put("HOME", self.home);
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".gitconfig" }));
        const system: ?[]const u8 = switch (mode) {
            .plain => null,
            .safe => |value| value,
        };
        if (system) |config_path| {
            try env.put("GIT_CONFIG_SYSTEM", config_path);
            try env.put("GIT_CONFIG_NOSYSTEM", "0");
        } else try env.put("GIT_CONFIG_NOSYSTEM", "1");
        return env;
    }

    fn run(self: SentinelRepo, cwd: []const u8, argv: []const []const u8, mode: Mode) !std.process.RunResult {
        var env = try self.childEnvironment(mode);
        return std.process.run(self.arena, std.testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
    }

    fn plainArgv(self: SentinelRepo, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, self.git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    fn plainOutput(self: SentinelRepo, cwd: []const u8, args: []const []const u8) ![]const u8 {
        const result = try self.run(cwd, try self.plainArgv(args), .plain);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git {s} failed: {s}\n", .{ args[0], result.stderr });
        return error.FixtureGitFailed;
    }

    fn plain(self: SentinelRepo, cwd: []const u8, args: []const []const u8) !void {
        _ = try self.plainOutput(cwd, args);
    }

    fn runs(self: SentinelRepo) !usize {
        var file = std.Io.Dir.openFileAbsolute(std.testing.io, self.log, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        const data = try io_mod.readFileToEnd(self.arena, &file, 1 << 16);
        file.close(std.testing.io);
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, self.log);
        return std.mem.count(u8, data, "ran\n");
    }

    fn ready(self: SentinelRepo, cwd: []const u8) !Ready {
        return switch (try prepare(self.arena, cwd)) {
            .ready => |value| value,
            .refused => |reason| {
                std.debug.print("safe git refused: {s}\n", .{@tagName(reason)});
                return error.TestUnexpectedRefusal;
            },
        };
    }

    fn helperArgv(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try appendCommand(self.arena, &argv, try self.ready(cwd), subcommand);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs `subcommand` through the helper, then `control` through plain
    /// git. The helper must never run the sentinel; the control must, or the
    /// fixture does not exercise the route. The helper runs first because it
    /// never refreshes the index, which would hide the change from the control.
    fn expectBlocked(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8, control: []const []const u8) !void {
        _ = try self.run(cwd, try self.helperArgv(cwd, subcommand, args), .{ .safe = null });
        try std.testing.expectEqual(@as(usize, 0), try self.runs());
        _ = try self.run(cwd, try self.plainArgv(control), .plain);
        try std.testing.expect(try self.runs() > 0);
    }
};

/// A capture store beside a `SentinelRepo`, with alternates into its objects.
const StoreFixture = struct {
    /// The capture route's PATH; a test may put a fixture folder first.
    path: []const u8 = capture_path,
    repo: SentinelRepo,
    ready: StoreReady,
    store: Store,

    fn init(repo: SentinelRepo) !StoreFixture {
        return initFormat(repo, .sha1, "repo");
    }

    fn initFormat(repo: SentinelRepo, format: ObjectFormat, work_tree: []const u8) !StoreFixture {
        var env = try repo.childEnvironment(.{ .safe = null });
        const ready = switch (try prepareStoreWith(repo.arena, .{}, &env)) {
            .ready => |value| value,
            .refused => return error.SkipZigTest,
        };
        const store: Store = .{
            .git_dir = try repo.path("store.git"),
            .index_file = try repo.path("capture-index"),
            .work_tree = try repo.path(work_tree),
            .scratch_dir = try repo.path("scratch"),
        };
        try std.Io.Dir.cwd().createDirPath(std.testing.io, store.scratch_dir);
        _ = try expectOk(try initStoreWith(repo.arena, ready, store.git_dir, format, .{}, &env));
        try repo.write("store.git/objects/info/alternates", try repo.arena.print("{s}\n", .{try repo.path(try repo.arena.print("{s}/.git/objects", .{work_tree}))}));
        return .{ .repo = repo, .ready = ready, .store = store };
    }

    fn run(self: StoreFixture, command: StoreCommand, mode: SentinelRepo.Mode, limits: Limits) !Outcome {
        var env = try self.repo.childEnvironment(mode);
        return runStoreWith(self.repo.arena, self.ready, self.store, command, limits, &env, self.path);
    }

    fn ok(self: StoreFixture, command: StoreCommand) ![]const u8 {
        return expectOk(try self.run(command, .{ .safe = null }, .{}));
    }

    fn storeOutput(self: StoreFixture, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.repo.arena, &.{ "--git-dir", self.store.git_dir });
        try argv.appendSlice(self.repo.arena, args);
        return self.repo.plainOutput(self.repo.root, argv.items);
    }
};

fn expectOk(outcome: Outcome) ![]const u8 {
    return switch (outcome) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => |failure| {
            std.debug.print("capture git failed: {s}\n", .{@tagName(failure)});
            return error.TestUnexpectedFailure;
        },
    };
}

fn expectFailure(expected: Failure, outcome: Outcome) !void {
    switch (outcome) {
        .ok => return error.TestExpectedFailure,
        .failed => |failure| try std.testing.expectEqual(expected, failure),
    }
}

fn readFixtureFile(repo: SentinelRepo, sub_path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, try repo.path(sub_path), .{});
    defer file.close(std.testing.io);
    return io_mod.readFileToEnd(repo.arena, &file, 1 << 24);
}

fn expectFacts(result: FactsResult) !RepositoryFacts {
    return switch (result) {
        .ok => |facts| facts,
        .failed => |failure| {
            std.debug.print("repository facts failed: {s}\n", .{@tagName(failure)});
            return error.TestUnexpectedFailure;
        },
    };
}

fn fuzzGitOutput(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    _ = classifyVersionAtLeast(bytes, minimum_minor);
    const entries = parseStageListing(arena, bytes) catch return;
    // What parses writes back as git would, and parses to the same entries.
    var again: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        try std.testing.expect(entry.path.len > 0 and std.mem.findScalar(u8, entry.path, 0) == null);
        const tag: u8 = if (entry.skip_worktree) 'S' else 'H';
        try again.print(arena, "{c} {s} {s} 0\t{s}\x00", .{ if (entry.assume_unchanged) std.ascii.toLower(tag) else tag, entry.mode.text(), entry.oid, entry.path });
    }
    const reparsed = try parseStageListing(arena, again.items);
    try std.testing.expectEqual(entries.len, reparsed.len);
    for (entries, reparsed) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.oid, b.oid);
        try std.testing.expectEqual(a.mode, b.mode);
        try std.testing.expectEqual(a.assume_unchanged, b.assume_unchanged);
        try std.testing.expectEqual(a.skip_worktree, b.skip_worktree);
    }
}
