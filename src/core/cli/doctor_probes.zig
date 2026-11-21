//! spark doctor's network and process checks, under one deadline.
//!
//! The provider catalog request runs as a `std.Io` task and writes only its
//! own slot, then sets `done` with release. Each MCP server is checked by its
//! own `spark mcp show NAME --json` child, so one process makes one connect, and
//! at most `serverCap()` of them run at a time; the rest wait in a queue that
//! `wait` starts from as slots free. In a repository, `gh repo view --json
//! url` runs as one more child, outside that cap. Each child runs in its own
//! process group. One `std.Io` task per child reads its pipe to the end,
//! reaps it, and then kills whatever the child left in its group.
//!
//! `wait` stops and joins all of it before it returns. At the deadline, or
//! when an ending signal arrives, it notes which probes finished in time,
//! cancels the catalog request and awaits it, kills every child still running
//! together with every process it started (also those in groups of their
//! own, such as the stdio servers an `spark mcp show` child starts), and joins
//! every waiter. The signal handler only records the signal; doctor's own
//! thread does the stopping and then ends by the signal. The caller reads
//! each result once, and a probe that finished after the deadline counts as
//! not finished (`tests/tla/doctor/Doctor.tla` NoTornReport,
//! NoChildAfterExit, NoTaskAfterReport, NoStartAfterSignalSeen, Reports).
//!
//! Probes are allocated with `std.heap.c_allocator` and left to the process
//! exit, which follows the report.
const std = @import("std");
const builtin = @import("builtin");
const model_catalog = @import("../gateway/model_catalog.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_runtime = @import("../mcp_host/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const process_tree = @import("../execution/process_tree.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const child_status = @import("doctor_child_status.zig");

const Allocator = std.mem.Allocator;
const Check = doctor_runtime.Check;
const CheckStatus = doctor_runtime.CheckStatus;
const ServerResult = output_contracts.McpServerResult;
const ChildStatusReader = child_status.ChildStatusReader;
const appendCheck = doctor_runtime.appendCheckOwnedFix;

const default_deadline_ms: i64 = 5_000;
const max_test_deadline_ms: i64 = 60_000;
/// After the deadline kills the children still running, how long their
/// waiters get to reap them before `wait` cancels the ones still blocked.
const reap_grace_ms: i64 = 1_000;
/// How long the stops of the checks still running get, all together, to
/// land before doctor looks at what each one started.
const stop_land_ms: i64 = 100;
/// How often `wait` looks at the done flags and the stop signal, and starts
/// queued MCP server checks.
const poll_ms: u64 = 5;
/// The fewest and the most MCP server checks that run at once.
const min_server_checks: usize = 4;
const max_server_checks: usize = 16;
/// The most of the limit a queued MCP server check must have left to start,
/// and the part of a shorter limit it needs instead (`checkShareMs`).
const max_check_share_ms: i64 = 1_000;
const check_share_divisor: i64 = 4;
/// gh's exit code for a command that needs a sign-in (`gh help exit-codes`).
const gh_auth_required: u8 = 4;

/// The one deadline for every probe. `SPARK_TEST_DOCTOR_DEADLINE_MS` shortens it
/// for tests; 0 ends it at once, so a test sees every check the limit cuts.
pub fn deadlineMs() i64 {
    return parseDeadlineMs(io_mod.getenv("SPARK_TEST_DOCTOR_DEADLINE_MS"));
}

fn parseDeadlineMs(raw: ?[]const u8) i64 {
    const value = std.fmt.parseInt(i64, raw orelse return default_deadline_ms, 10) catch return default_deadline_ms;
    if (value < 0 or value > max_test_deadline_ms) return default_deadline_ms;
    return value;
}

pub const CatalogOutcome = union(enum) {
    loaded: struct {
        has_model: bool,
    },
    failed: model_catalog.FailureCategory,
};

pub const CatalogProbe = struct {
    provider: gateway_provider.CliModelCatalogProvider,
    access: credentials.CatalogAccess,
    endpoint: []const u8,
    model: []const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// Whether the request finished by the deadline, as `wait` saw it. A
    /// result that came later is dropped.
    in_time: bool = false,
    /// Why no task could run the request; the probe is then done at once.
    start_error: ?anyerror = null,
    outcome: CatalogOutcome = .{ .failed = .runtime },
    task: ?std.Io.Future(void) = null,

    fn run(self: *CatalogProbe) void {
        const result = self.provider.fetch(std.heap.c_allocator, .{
            .access = self.access,
            .endpoint = self.endpoint,
            .cancel_flag = &self.cancel,
        });
        self.outcome = switch (result) {
            .loaded => |loaded| .{ .loaded = .{
                .has_model = contains(loaded.ids.items, self.model),
            } },
            .failure => |failed| .{ .failed = failed.failure.category },
        };
        self.done.store(true, .release);
    }

    /// Starts the request as a `std.Io` task, which `wait` awaits or
    /// cancels. `self` and everything it borrows must outlive `wait`.
    pub fn start(self: *CatalogProbe) void {
        self.task = io_mod.getIo().concurrent(run, .{self}) catch |err| {
            debug_trace.logf("doctor", "provider check could not start err={s}", .{@errorName(err)});
            self.start_error = err;
            self.done.store(true, .release);
            return;
        };
    }

    /// At the deadline: notes whether the request finished in time, and if
    /// not, cancels it. Either way, joins its task.
    fn finish(self: *CatalogProbe, io: std.Io) void {
        self.in_time = self.done.load(.acquire);
        var task = self.task orelse return;
        self.task = null;
        if (self.in_time) return task.await(io);
        // The fetch polls the flag; the Io cancel also ends a read or a
        // connect that is blocked.
        self.cancel.store(true, .release);
        task.cancel(io);
        debug_trace.logf("doctor", "provider check did not finish by the deadline; its late result is dropped", .{});
    }
};

fn contains(ids: []const []u8, model: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, model)) return true;
    return false;
}

/// One child process, in its own process group, whose exit doctor reads
/// after reaping it.
pub const ProcessProbe = struct {
    name: []const u8,
    /// What `spawn` runs. A queued check keeps it until a slot frees.
    argv: []const []const u8 = &.{},
    child: std.process.Child = undefined,
    /// Taken at spawn, before the waiter can reap the child. It is also the
    /// id of the child's process group.
    pid: std.posix.pid_t = 0,
    spawn_error: ?anyerror = null,
    /// Never started, because too little of the limit was left to start
    /// it, the limit came while it waited for a slot, or a signal came first.
    not_started: bool = false,
    /// Never started for the first of those reasons, before the limit itself
    /// was reached.
    start_cutoff: bool = false,
    /// Killed at the deadline or at an ending signal, so it did not finish
    /// in time.
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    /// Reads the child's stdout as it arrives. Null when doctor needs only
    /// the exit status, and then the child's stdout goes nowhere.
    status: ?*ChildStatusReader = null,
    /// The SIGSTOP `stopTrees` sent has landed. Doctor's own thread only.
    stop_landed: bool = false,
    /// When `spawn` started it, and, once `wait` has stopped it, how long it
    /// had run by then. Doctor's own thread only.
    started_at: i64 = 0,
    stopped_after_ms: i64 = 0,

    /// A check of `argv` that has not started. The caller adds it to the
    /// list `wait` stops before it spawns it.
    fn create(alloc: Allocator, name: []const u8, argv: []const []const u8, status: ?*ChildStatusReader) !*ProcessProbe {
        const probe = try alloc.create(ProcessProbe);
        probe.* = .{ .name = name, .argv = argv, .status = status };
        return probe;
    }

    /// Spawns `argv` in a new process group, with `environ_map` or doctor's
    /// own environment, then reads its stdout to the end and reaps it in a
    /// task of `waiters`. Its stderr, and its stdout when it has no status
    /// reader, go nowhere and are never read. A spawn that fails, or a child
    /// no task can wait for, is done at once with `spawn_error` set.
    fn spawn(self: *ProcessProbe, waiters: *std.Io.Group, environ_map: ?*const std.process.Environ.Map) void {
        // Before the first child exists, so a signal never ends doctor while
        // a child it started is left running.
        installStopHandler();
        debug_trace.logf("doctor", "starting check {s}", .{self.name});
        const io = io_mod.getIo();
        self.started_at = io_mod.milliTimestamp();
        self.child = std.process.spawn(io, .{
            .argv = self.argv,
            .environ_map = environ_map,
            .stdin = .ignore,
            .stdout = if (self.status != null) .pipe else .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            self.spawn_error = err;
            self.done.store(true, .release);
            return;
        };
        self.pid = self.child.id.?;
        waiters.concurrent(io, waitForExit, .{self}) catch |err| {
            // Nothing would read or reap it, so it stops now.
            debug_trace.logf("doctor", "check {s} has no task to wait for it err={s}; killing it with what it started", .{ self.name, @errorName(err) });
            stopTrees(&.{self});
            self.child.kill(io);
            self.spawn_error = err;
            self.done.store(true, .release);
        };
    }

    fn waitForExit(self: *ProcessProbe) void {
        const io = io_mod.getIo();
        if (self.child.stdout) |file| {
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = file.readStreaming(io, &.{&chunk}) catch |err| {
                    if (err == error.Canceled) debug_trace.logf("doctor", "check {s}: stopped reading its output, which a process outside its group held open", .{self.name});
                    break;
                };
                // A read into a buffer with room returns 0 only at the end.
                if (n == 0) break;
                if (self.status) |reader| reader.feed(chunk[0..n]);
            }
        }
        if (self.status) |reader| reader.end();
        // `wait` cancels this task only after it killed the child, so the
        // reap ends at once; it must not be cut short, or the child stays a
        // zombie.
        const protection = io.swapCancelProtection(.blocked);
        self.term = self.child.wait(io) catch null;
        _ = io.swapCancelProtection(protection);
        // Whatever the child started in its group goes with it. The group id
        // stays taken while any member lives, so this reaches only them.
        std.posix.kill(-self.pid, .KILL) catch {};
        self.done.store(true, .release);
    }
};

/// Kills each check in `probes` that is still running, with everything it
/// started, in three steps over all of them: every check's group is
/// stopped, so none starts anything more; doctor waits, `stop_land_ms` in
/// all, until each stop has landed or the check has exited, since kill(2)
/// only queues a SIGSTOP and a check still running could start a server
/// after doctor looked; then each tree is walked and killed. Their waiters
/// then reap them.
fn stopTrees(probes: []const *ProcessProbe) void {
    for (probes) |p| if (!p.done.load(.acquire) and p.pid != 0) std.posix.kill(-p.pid, .STOP) catch {};
    const limit = io_mod.milliTimestamp() + stop_land_ms;
    while (true) {
        var waiting = false;
        for (probes) |p| {
            if (p.stop_landed or p.pid == 0) continue;
            // A check that has exited can start nothing, so it counts as stopped.
            if (p.done.load(.acquire) or (process_tree.processIsStopped(std.heap.c_allocator, p.pid) catch false)) {
                p.stop_landed = true;
            } else {
                waiting = true;
            }
        }
        if (!waiting or io_mod.milliTimestamp() >= limit) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    for (probes) |p| {
        if (p.done.load(.acquire) or p.pid == 0) continue;
        if (!p.stop_landed) debug_trace.logf("doctor", "check {s} did not stop within {d} ms; killing it with what it started anyway", .{ p.name, stop_land_ms });
        killTree(p.pid);
    }
}

/// Kills the process group of `pid`, which `stopTrees` has stopped, and
/// every process `pid` started outside it, such as the stdio MCP servers an
/// `spark mcp show` child starts in groups of their own, and their helper. A
/// group kill alone would leave a server the child had started but not yet
/// told its helper about. A child that started nothing is only killed. Any
/// other tree is stopped and killed whole, and a process the kill skipped is
/// resumed (`process_tree.Tracker`). Only for a child not yet reaped, so its
/// id cannot have been reused.
fn killTree(pid: std.posix.pid_t) void {
    var tree = process_tree.Tracker.init(std.heap.c_allocator) catch return killGroup(pid);
    defer tree.deinit();
    tree.refresh(pid) catch |err| debug_trace.logf("doctor", "check {d}: could not list the processes it started err={s}", .{ pid, @errorName(err) });
    const outside_group = tree.processes.items.len > 0;
    if (outside_group) {
        tree.stopAll();
        // Anything a stop that had not landed yet let it start.
        tree.refresh(pid) catch {};
    }
    // The group goes first, so the pass below, which resumes what it
    // stopped and did not kill, cannot let the child run again.
    killGroup(pid);
    if (!outside_group) return;
    const outside = tree.signalOutsideProcessGroupChecked(.KILL, pid);
    if (outside.incomplete) debug_trace.logf("doctor", "check {d}: some processes it started outside its group could not be killed", .{pid});
}

fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
}

/// The signals that end doctor early. Each child is in its own group, so the
/// terminal's Ctrl-C reaches only doctor, which then stops the children.
const ending_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };
/// The first ending signal, or 0. The handler only records it. Doctor's own
/// thread looks at it after each child it starts and in `wait`, stops every
/// check, and then ends by it with the handler removed.
var stop_signal: std.atomic.Value(@typeInfo(std.posix.SIG).@"enum".tag_type) = .init(0);
var previous_actions: [ending_signals.len]std.posix.Sigaction = undefined;
var handles_ending_signals = false;

/// Only doctor's own thread calls this, before it starts a child.
fn installStopHandler() void {
    if (handles_ending_signals or builtin.is_test) return;
    handles_ending_signals = true;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = recordStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (ending_signals, &previous_actions) |sig, *previous| {
        std.posix.sigaction(sig, &action, previous);
        // A signal doctor was started to ignore stays ignored.
        if (previous.handler.handler == std.posix.SIG.IGN) std.posix.sigaction(sig, previous, null);
    }
}

fn restoreSignalActions() void {
    if (!handles_ending_signals) return;
    handles_ending_signals = false;
    for (ending_signals, previous_actions) |sig, previous| std.posix.sigaction(sig, &previous, null);
}

/// Async-signal-safe: one atomic compare-and-swap, on whichever thread the
/// signal reached.
fn recordStopSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = stop_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
}

/// Whether an ending signal reached doctor while its handler was in place.
pub fn stopRequested() bool {
    return stop_signal.load(.seq_cst) != 0;
}

/// Ends doctor by the signal `wait` returned, as the signal would have ended
/// it without doctor's handler, which `wait` has removed. Returns only when
/// what doctor found in place lets the process go on.
pub fn endBySignal(sig: std.posix.SIG) void {
    _ = std.c.raise(sig);
}

/// `spark mcp show` and the other `spark mcp` commands read a name that starts
/// with "-" as an option, and take no "--" before a name, so such a server
/// gets no child and no command in its fix.
fn readsAsOption(name: []const u8) bool {
    return name.len > 0 and name[0] == '-';
}

/// How many MCP server checks run at once on this machine (`serverCapFor`).
pub fn serverCap() usize {
    return serverCapFor(std.Thread.getCpuCount() catch min_server_checks);
}

/// One check for each of `cpus` CPUs, between `min_server_checks` and
/// `max_server_checks`, so many servers do not starve each other of the one
/// deadline.
fn serverCapFor(cpus: usize) usize {
    return std.math.clamp(cpus, min_server_checks, max_server_checks);
}

/// How much of a `limit_ms` limit must be left for a queued check to start:
/// `max_check_share_ms`, or a quarter (`check_share_divisor`) of a shorter
/// limit, so a short test limit still starts checks.
fn checkShareMs(limit_ms: i64) i64 {
    return @min(max_check_share_ms, @divTrunc(limit_ms, check_share_divisor));
}

/// Why checks still queued were never started: too little of the limit was
/// left to start one, the limit came while every slot was taken, or an
/// ending signal came.
const DropReason = enum { cutoff, limit, signal };

/// The MCP server checks, one for each idle server in config order. At most
/// `cap` of them run at a time; the ones from `next` on wait for a slot.
pub const ServerChecks = struct {
    probes: []const *ProcessProbe = &.{},
    next: usize = 0,
    cap: usize = 1,
    /// The last moment a queued check may start: the deadline less the
    /// check's share of the limit (`checkShareMs`).
    last_start: i64 = std.math.maxInt(i64),

    /// Starts the queued checks in order while fewer than `cap` run. Before
    /// each start it looks, in this order, at `last_start`, past which it
    /// drops the rest, so a check the limit cuts has had at least its share
    /// of it; then at an ending signal and the deadline. Doctor's own thread
    /// only.
    pub fn startMore(self: *ServerChecks, waiters: *std.Io.Group, deadline: i64) void {
        while (self.next < self.probes.len and self.running() < self.cap) {
            if (io_mod.milliTimestamp() >= self.last_start) return self.dropQueued(.cutoff);
            if (stopRequested() or io_mod.milliTimestamp() >= deadline) return;
            self.probes[self.next].spawn(waiters, null);
            self.next += 1;
        }
    }

    /// The checks started that have not ended. A check holds its slot until
    /// its waiter has reaped it.
    fn running(self: *const ServerChecks) usize {
        var count: usize = 0;
        for (self.probes[0..self.next]) |p| {
            if (!p.done.load(.acquire)) count += 1;
        }
        return count;
    }

    /// The checks still queued are never started. Each gets a trace line
    /// that names it and says why.
    fn dropQueued(self: *ServerChecks, reason: DropReason) void {
        const why = switch (reason) {
            .cutoff => "too little of doctor's limit was left to start it",
            .limit => "doctor's limit came while it waited for a slot",
            .signal => "doctor got a signal first",
        };
        for (self.probes[self.next..]) |p| {
            debug_trace.logf("doctor", "check {s} was never started, since {s}; dropping it", .{ p.name, why });
            p.start_cutoff = reason == .cutoff;
            p.not_started = true;
            p.done.store(true, .release);
        }
        self.next = self.probes.len;
    }
};

/// Queues one `spark mcp show NAME --json` check for each idle server, appends
/// each to `processes`, and starts the first ones up to `cap`, as
/// `ServerChecks.startMore` allows under `deadline`, which ends a limit of
/// `limit_ms`; `wait` starts the rest. An unapproved, rejected, or disabled
/// server is never idle, so it never gets a check. A queued check is in
/// `processes` before it can start, so `wait` always reaches it.
pub fn startServerChildren(
    alloc: Allocator,
    waiters: *std.Io.Group,
    processes: *std.ArrayList(*ProcessProbe),
    statuses: []const mcp_runtime.Status,
    self_exe: []const u8,
    deadline: i64,
    limit_ms: i64,
    cap: usize,
) !ServerChecks {
    const first = processes.items.len;
    for (statuses) |status| {
        if (status.state != .idle or readsAsOption(status.name)) continue;
        try processes.ensureUnusedCapacity(alloc, 1);
        const name = try alloc.dupe(u8, status.name);
        const argv = try alloc.dupe([]const u8, &.{ self_exe, "mcp", "show", name, "--json" });
        const reader = try alloc.create(ChildStatusReader);
        reader.init();
        processes.appendAssumeCapacity(try ProcessProbe.create(alloc, name, argv, reader));
    }
    // A copy, since gh's append may move the list.
    var servers: ServerChecks = .{
        .probes = try alloc.dupe(*ProcessProbe, processes.items[first..]),
        .cap = @max(1, cap),
        .last_start = deadline - checkShareMs(limit_ms),
    };
    servers.startMore(waiters, deadline);
    return servers;
}

/// Starts `gh repo view --json url` in the workspace, which doctor runs in,
/// unless an ending signal came first, and appends it to `processes`. gh
/// then reads the repository's remotes, the host, the active account,
/// `GH_HOST`, and `GH_REPO` itself, as it does for `spark pr` and `spark issue`.
/// It gets the environment those get, with prompts and the update check
/// turned off, so it never waits on a person or writes its update state.
pub fn startGh(alloc: Allocator, waiters: *std.Io.Group, processes: *std.ArrayList(*ProcessProbe)) !?*ProcessProbe {
    if (stopRequested()) {
        debug_trace.logf("doctor", "check gh was never started, since doctor got a signal first", .{});
        return null;
    }
    try processes.ensureUnusedCapacity(alloc, 1);
    const probe = try ProcessProbe.create(alloc, "gh", &.{ "gh", "repo", "view", "--json", "url" }, null);
    processes.appendAssumeCapacity(probe);
    var environ = io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            probe.spawn_error = err;
            probe.done.store(true, .release);
            return probe;
        },
    };
    defer environ.deinit();
    try environ.put("GH_PROMPT_DISABLED", "1");
    try environ.put("GH_NO_UPDATE_NOTIFIER", "1");
    probe.spawn(waiters, &environ);
    return probe;
}

fn allDone(catalog: ?*CatalogProbe, processes: []const *ProcessProbe) bool {
    if (catalog) |c| if (!c.done.load(.acquire)) return false;
    for (processes) |p| if (!p.done.load(.acquire)) return false;
    return true;
}

/// Waits until every probe is done, the deadline passes, or an ending signal
/// arrives, starting queued server checks as slots free, then stops and
/// joins everything doctor started, so nothing runs after it returns. It
/// notes which probes finished in time, marks the checks still queued as
/// never started, cancels and awaits a catalog request still out, kills
/// every child still running with what it started, gives the waiters a
/// short grace to reap them, and then cancels and joins the waiters. It then
/// removes the signal handler and returns the signal that arrived, if one
/// did, for `endBySignal`.
pub fn wait(deadline: i64, catalog: ?*CatalogProbe, processes: []const *ProcessProbe, waiters: *std.Io.Group, servers: ?*ServerChecks) ?std.posix.SIG {
    const io = io_mod.getIo();
    while (true) {
        if (servers) |queue| queue.startMore(waiters, deadline);
        if (io_mod.milliTimestamp() >= deadline or allDone(catalog, processes) or stopRequested()) break;
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    if (servers) |queue| queue.dropQueued(if (stopRequested()) .signal else .limit);
    const why = if (stopRequested()) "before doctor got a signal" else "by the deadline";
    if (catalog) |c| c.finish(io);
    const stopped_at = io_mod.milliTimestamp();
    for (processes) |p| if (!p.done.load(.acquire) and p.pid != 0) {
        debug_trace.logf("doctor", "check {s} did not finish {s}; killing it with what it started and dropping its late result", .{ p.name, why });
        p.stopped_after_ms = stopped_at - p.started_at;
        p.stopped.store(true, .release);
    };
    stopTrees(processes);
    const reap_deadline = io_mod.milliTimestamp() + reap_grace_ms;
    while (io_mod.milliTimestamp() < reap_deadline and !allDone(null, processes)) {
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    for (processes) |p| if (!p.done.load(.acquire)) {
        debug_trace.logf("doctor", "check {s} was not reaped within the grace; cancelling its waiter", .{p.name});
    };
    waiters.cancel(io);
    // A signal from here on takes the action doctor found in place.
    restoreSignalActions();
    const raw = stop_signal.load(.seq_cst);
    if (raw == 0) return null;
    return @fromBackingInt(raw);
}

/// The network checks doctor waits on, for its wait notice.
pub const Waiting = struct {
    /// The provider whose model list doctor asked for, if it asked.
    provider: ?model_provider.ProviderId = null,
    /// The MCP server checks started or queued.
    mcp_servers: usize = 0,
    gh: enum { not_checked, checking } = .not_checked,
};

/// The line doctor writes to a terminal's stderr while it waits on the
/// network checks it started, such as `checking AI Gateway, 3 MCP servers,
/// and gh (up to 5 s)...`, or null when it started none. The caller owns it.
pub fn waitNotice(alloc: Allocator, waiting: Waiting, deadline_ms: i64) Allocator.Error!?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var server_text: ?[]u8 = null;
    defer if (server_text) |text| alloc.free(text);
    if (waiting.provider) |id| try parts.append(alloc, providerLabel(id));
    if (waiting.mcp_servers > 0) {
        server_text = try alloc.print("{d} MCP server{s}", .{ waiting.mcp_servers, if (waiting.mcp_servers == 1) "" else "s" });
        try parts.append(alloc, server_text.?);
    }
    if (waiting.gh == .checking) try parts.append(alloc, "gh");
    const limit = seconds(deadline_ms);
    const p = parts.items;
    return switch (p.len) {
        0 => null,
        1 => try alloc.print("checking {s} (up to {d} s)...\n", .{ p[0], limit }),
        2 => try alloc.print("checking {s} and {s} (up to {d} s)...\n", .{ p[0], p[1], limit }),
        else => try alloc.print("checking {s}, {s}, and {s} (up to {d} s)...\n", .{ p[0], p[1], p[2], limit }),
    };
}

fn providerLabel(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .none => "the provider",
        .configured => "the configured provider",
    };
}

/// The provider and model checks from the catalog slot, read after `wait`:
/// a request that had not finished by the deadline is a provider that could
/// not be reached. The credential counts as accepted only when the provider
/// answered for it; a public list says nothing about it.
pub fn catalogChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    probe: *const CatalogProbe,
    provider: model_provider.ProviderId,
    deadline_ms: i64,
) !void {
    const label = providerLabel(provider);
    const login = doctor_runtime.providerFix(provider);
    if (probe.start_error) |err| {
        try appendCheck(checks, alloc, "provider", .fail, try alloc.print("spark could not start the check of {s} ({s})", .{ label, @errorName(err) }), try alloc.dupe(u8, "run spark doctor again"));
        return;
    }
    if (!probe.in_time) {
        try appendCheck(checks, alloc, "provider", .fail, try alloc.print("could not reach {s} in {d} s", .{ label, seconds(deadline_ms) }), try alloc.dupe(u8, "check the network connection, then run spark doctor again"));
        return;
    }
    switch (probe.outcome) {
        .failed => |category| switch (category) {
            .authentication => try appendCheck(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, login)),
            .rate_limited => try appendCheck(checks, alloc, "provider", .warn, try alloc.print("{s} rate-limited the check, so the credential is not confirmed", .{label}), try alloc.dupe(u8, "run spark doctor again in a minute")),
            .malformed_response => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("{s} sent a model list spark cannot read", .{label}), try alloc.dupe(u8, "run spark doctor again later")),
            .resource_exhausted => try appendCheck(checks, alloc, "provider", .fail, try alloc.dupe(u8, "spark ran out of memory reading the model list"), try alloc.dupe(u8, "close other programs, then run spark doctor again")),
            // The provider answered, but with an error status.
            .gateway_unavailable, .http_status => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("{s} answered the check with an error", .{label}), try alloc.dupe(u8, "run spark doctor again later")),
            .cancellation, .transport, .runtime => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("could not reach {s}", .{label}), try alloc.dupe(u8, "check the network connection, then run spark doctor again")),
        },
        .loaded => |loaded| {
            try appendCheck(checks, alloc, "auth", .ok, try alloc.print("{s} accepted the credential", .{label}), null);
            if (loaded.has_model) {
                try appendCheck(checks, alloc, "model", .ok, try alloc.print("{s} is available", .{probe.model}), null);
            } else {
                try appendCheck(checks, alloc, "model", .fail, try alloc.print("{s} is not an available model", .{probe.model}), try alloc.dupe(u8, "spark models"));
            }
        },
    }
}

fn seconds(ms: i64) i64 {
    return @max(1, @divCeil(ms, 1000));
}

/// One line for each MCP server checked by a child, read after `wait`, and
/// what doctor found for each in `results`.
pub fn serverChildChecks(
    checks: *std.ArrayList(Check),
    results: *std.ArrayList(ServerResult),
    alloc: Allocator,
    children: []const *ProcessProbe,
    deadline_ms: i64,
) !void {
    for (children) |c| {
        try results.ensureUnusedCapacity(alloc, 1);
        const found = try serverChildCheck(checks, alloc, c, deadline_ms);
        results.appendAssumeCapacity(.{ .name = c.name, .connection = found.connection, .authentication = found.authentication });
    }
}

const Found = struct {
    connection: ServerResult.Connection,
    authentication: ServerResult.Authentication = .not_checked,
};

/// `spark mcp VERB NAME` with NAME quoted for a shell, so a name from a config
/// file is always one argument and never a command of its own. The caller
/// owns it.
fn mcpCommand(alloc: Allocator, verb: []const u8, name: []const u8) Allocator.Error![]u8 {
    const quoted = try command_lex.quoteWord(alloc, name);
    defer alloc.free(quoted);
    return alloc.print("spark mcp {s} {s}", .{ verb, quoted });
}

fn serverChildCheck(checks: *std.ArrayList(Check), alloc: Allocator, c: *const ProcessProbe, deadline_ms: i64) !Found {
    const failed: Found = .{ .connection = .failed };
    const timed_out: Found = .{ .connection = .timed_out };
    if (c.not_started) {
        const detail = if (c.start_cutoff)
            try alloc.print("{s} was not checked: too little of doctor's {d} s limit was left to start it", .{ c.name, seconds(deadline_ms) })
        else
            try alloc.print("{s} was not checked: doctor reached its {d} s limit before it could start the check", .{ c.name, seconds(deadline_ms) });
        try appendCheck(checks, alloc, "mcp", .fail, detail, try mcpCommand(alloc, "show", c.name));
        return timed_out;
    }
    if (c.stopped.load(.acquire)) {
        // Its own time, which a check started late in the limit had less of.
        const tenths = @divTrunc(c.stopped_after_ms + 50, 100);
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} did not answer in {d}.{d} s, when doctor's {d} s limit ended", .{ c.name, @divTrunc(tenths, 10), @mod(tenths, 10), seconds(deadline_ms) }), try mcpCommand(alloc, "show", c.name));
        return timed_out;
    }
    if (c.spawn_error) |err| {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: spark could not start a check ({s})", .{ c.name, @errorName(err) }), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    const term = c.term orelse {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: spark lost its check", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    };
    if (term != .exited) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s}: spark crashed while checking it ({f})", .{ c.name, term }), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    const parsed = c.status.?.result() catch {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s}: spark could not read its check", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    };
    if (std.mem.eql(u8, parsed.status, "ready")) {
        try appendCheck(checks, alloc, "mcp", .ok, try alloc.print("{s} ready, {d} tool{s}", .{ c.name, parsed.tools, if (parsed.tools == 1) "" else "s" }), null);
        return .{ .connection = .ready, .authentication = .ok };
    }
    if (std.mem.eql(u8, parsed.status, "needs_login")) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} needs sign-in", .{c.name}), try mcpCommand(alloc, "login", c.name));
        return .{ .connection = .failed, .authentication = .needs_login };
    }
    if (std.mem.eql(u8, parsed.status, "connecting") or std.mem.eql(u8, parsed.status, "retrying") or std.mem.eql(u8, parsed.status, "not_started")) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} {s}: {s}", .{ c.name, parsed.status, parsed.err orelse "no detail" }), try mcpCommand(alloc, "show", c.name));
    return failed;
}

/// Lines for servers that get no child, as the doctor process's own runtime
/// reads them without starting any.
pub fn serverStatusChecks(checks: *std.ArrayList(Check), alloc: Allocator, statuses: []const mcp_runtime.Status) !void {
    for (statuses) |s| {
        const status, const detail = (try statusLine(alloc, s)) orelse continue;
        const fix = statusFix(alloc, s) catch |err| {
            alloc.free(detail);
            return err;
        };
        try appendCheck(checks, alloc, "mcp", status, detail, fix);
    }
}

/// The status and detail of a server that gets no child, or null when it
/// gets one or needs no line. The caller owns the detail.
fn statusLine(alloc: Allocator, s: mcp_runtime.Status) Allocator.Error!?struct { CheckStatus, []u8 } {
    return switch (s.state) {
        .idle => if (readsAsOption(s.name)) .{ .warn, try alloc.print("{s} was not checked: spark mcp show reads a name that starts with \"-\" as an option", .{s.name}) } else null,
        .waiting_for_approval => .{ .warn, try alloc.print("{s} is waiting for approval", .{s.name}) },
        .missing_env, .invalid_env => .{ .fail, try alloc.print("{s} needs {s}", .{ s.name, s.missing orelse "an environment variable" }) },
        .unsupported => .{ .warn, try alloc.print("{s} uses a transport spark does not support", .{s.name}) },
        .failed => .{ .fail, try alloc.print("{s} failed: {s}", .{ s.name, s.last_error orelse "no detail" }) },
        .connecting, .ready, .retrying, .rejected, .disabled => null,
    };
}

/// The fix on a server's status line. Every `spark mcp` command reads a name
/// that starts with "-" as an option and takes no "--" before it, so such a
/// server, whatever its state, can only be renamed in the file it comes
/// from; that is decided before the state is. The caller owns it.
fn statusFix(alloc: Allocator, s: mcp_runtime.Status) Allocator.Error![]u8 {
    if (readsAsOption(s.name)) return alloc.print("rename the server in {s} so its name does not start with \"-\"", .{configFile(s.source)});
    return switch (s.state) {
        .waiting_for_approval => mcpCommand(alloc, "approve", s.name),
        .missing_env, .invalid_env => {
            const variable = if (s.missing) |name| try command_lex.quoteWord(alloc, name) else try alloc.dupe(u8, "the variable");
            defer alloc.free(variable);
            return alloc.print("set {s}, then run spark doctor again", .{variable});
        },
        .unsupported => {
            const quoted = try command_lex.quoteWord(alloc, s.name);
            defer alloc.free(quoted);
            return alloc.print("give {s} a stdio command or an HTTP URL, or run spark mcp remove {s}", .{ quoted, quoted });
        },
        .idle, .failed, .connecting, .ready, .retrying, .rejected, .disabled => mcpCommand(alloc, "show", s.name),
    };
}

/// The file a server's config comes from, as spark names it to the user. Only
/// an ACP client gives `acp` servers, and doctor never runs under one.
fn configFile(source: mcp_contract.ConfigSource) []const u8 {
    return switch (source) {
        .workspace => ".mcp.json",
        .profile, .acp => profile_paths.displayText("~/.spark/mcp.json"),
    };
}

/// The gh line, read after `wait`, from how `gh repo view --json url` ended:
/// 0 when gh can use this repository, `gh_auth_required` when it needs a
/// sign-in. gh's output is never read, since it can hold remote URLs and
/// tokens; only its exit status is traced. Null `probe`: a signal ended the
/// checks before gh started, and doctor does not report.
pub fn ghCheck(checks: *std.ArrayList(Check), alloc: Allocator, probe: ?*const ProcessProbe, deadline_ms: i64) !void {
    const p = probe orelse return;
    const see_why = "run gh repo view to see why";
    if (p.spawn_error) |err| {
        const why = "spark pr --create and spark issue --create need it";
        if (err == error.FileNotFound) {
            return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI not found on PATH; {s}", .{why}), try alloc.dupe(u8, "install gh from https://cli.github.com"));
        }
        return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI could not start ({s}); {s}", .{ @errorName(err), why }), try alloc.dupe(u8, "gh --version"));
    }
    if (p.stopped.load(.acquire)) {
        return appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh repo view did not answer in {d} s", .{seconds(deadline_ms)}), try alloc.dupe(u8, see_why));
    }
    const term = p.term orelse return appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh repo view gave no result"), try alloc.dupe(u8, see_why));
    debug_trace.logf("doctor", "gh repo view ended {f}", .{term});
    switch (term) {
        .exited => |code| switch (code) {
            0 => try appendCheck(checks, alloc, "gh", .ok, try alloc.dupe(u8, "gh can use this repository"), null),
            gh_auth_required => try appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh is not signed in for this repository"), try alloc.dupe(u8, "gh auth login")),
            else => try appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh could not use this repository"), try alloc.dupe(u8, see_why)),
        },
        else => try appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh repo view ended early ({f})", .{term}), try alloc.dupe(u8, see_why)),
    }
}

fn freeChecks(alloc: Allocator, checks: *std.ArrayList(Check)) void {
    for (checks.items) |*entry| entry.deinit(alloc);
    checks.deinit(alloc);
}

/// Gives `reader` one whole child answer, as `waitForExit` does.
fn answer(reader: *ChildStatusReader, bytes: []const u8) void {
    reader.init();
    reader.feed(bytes);
    reader.end();
}

test "catalog checks cover every outcome the slot can hold after wait" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{
        .provider = undefined,
        .access = .public_only,
        .endpoint = "",
        .model = "m/one",
    };
    const Case = struct { done: bool, outcome: CatalogOutcome, want: []const struct { []const u8, CheckStatus } };
    const cases = [_]Case{
        // A late result counts as no answer, whatever it says.
        .{ .done = false, .outcome = .{ .loaded = .{ .has_model = true } }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .authentication }, .want = &.{.{ "auth", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .rate_limited }, .want = &.{.{ "provider", .warn }} },
        .{ .done = true, .outcome = .{ .failed = .transport }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .resource_exhausted }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true } }, .want = &.{ .{ "auth", .ok }, .{ "model", .ok } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = false } }, .want = &.{ .{ "auth", .ok }, .{ "model", .fail } } },
    };
    for (cases) |case| {
        probe.in_time = case.done;
        probe.outcome = case.outcome;
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try catalogChecks(&checks, alloc, &probe, .none, 5_000);
        try std.testing.expectEqual(case.want.len, checks.items.len);
        for (case.want, checks.items) |want, got| {
            try std.testing.expectEqualStrings(want[0], got.name);
            try std.testing.expectEqual(want[1], got.status);
            try std.testing.expectEqual(got.status != .ok, got.fix != null);
        }
    }
}

/// Sends the doctor trace lines a test writes to `trace.log` in `tmp`.
fn startTraceForTest(alloc: Allocator, tmp: std.testing.TmpDir) !void {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, path, "doctor");
}

/// Ends the tracing `startTraceForTest` began and returns what it wrote.
/// The caller owns it.
fn readTraceForTest(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    debug_trace.shutdown();
    return tmp.dir.readFileAlloc(io_mod.getIo(), "trace.log", alloc, .limited(1 << 20));
}

/// The entries in `dir`, for tests.
fn entryCount(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |_| count += 1;
    return count;
}
