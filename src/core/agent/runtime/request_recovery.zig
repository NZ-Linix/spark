//! Carries out `src/core/recovery/` plans for one model request.
//!
//! The recovery module decides and this file acts. The turn loop reports what
//! happened to the request (`start`, `failed`, `responding`, `succeeded`,
//! `cancel`), and each report becomes one `recovery.step` call on the boot
//! clock. Its plan's status goes to the host, and its send tells the loop to
//! resend. Between sends `waitForSend` delivers `tick` every 100 ms, so a
//! jittered wait ends within a tick of its time, and polls the cancel flag
//! every 25 ms; in single-threaded builds each poll also gives the host its
//! cooperative pulse, which is where the host's Esc arrives. While a send is
//! on the wire, a ticker keeps the
//! retrying status counting: a thread in threaded builds, or the transport's
//! cooperative pulse in single-threaded ones.
//!
//! The module's state is not thread-safe, so every `step` call holds `mutex`.
//! Statuses are pushed under the same lock, so the host sees them in the order
//! the module produced them.
//!
//! On hosts that keep the module's record (`save_recovery_record`), every
//! `Plan.save` reaches the turn. A save that goes with a send travels in the
//! write before that send (`sendRecord`), so a turn's first write carries it;
//! a completed response clears it in the write that saves the response
//! (`responseRecord`); any other save is written at once. A launch reads the
//! newest one to resume the request (`tests/tla/recovery/Resume.tla`). Every
//! request that keeps a record registers for `closeActive`, which SIGHUP and
//! SIGTERM call from the closer thread, and a terminal that hangs up calls
//! from the main thread. One spark process runs main, its subagents and other
//! instances, and each can have a request in flight.
//!
//! The module retries every transient failure for as long as it lasts, and spark
//! adds no limit of its own: only Esc ends a request whose failures keep
//! coming.

const std = @import("std");
const atomic_value = @import("../../shared/atomic_value.zig");
const builtin = @import("builtin");
const recovery = @import("../../recovery/recovery.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_deps = @import("deps.zig");

pub const Failure = recovery.Failure;
pub const Send = recovery.Send;

/// The module expects `tick` at least once a second from `start` until
/// `finish`; a send on the wire ticks this often.
const tick_ms: u64 = 1_000;
/// How often a wait ticks. The module ends a wait at the first tick past its
/// jittered time, so a whole-second tick would round every wait up to a
/// whole second and every client would resend together.
const wait_tick_ms: u64 = 100;
/// How often a wait checks for Esc.
const cancel_poll_ms: u64 = 25;
/// How often a wait for a sign-in asks whether the store holds a new login.
const sign_in_check_ms: u64 = 1_000;
/// Tests run the ticker thread fast; the module still sees the virtual clock.
const ticker_interval_ns: i96 = if (builtin.is_test) 5 * std.time.ns_per_ms else tick_ms * std.time.ns_per_ms;
/// The virtual boot clock tests start at.
const test_epoch_ms: u64 = 1_000_000;

/// The module's failure kind for each of spark's transient causes, and null for
/// a cause that never reaches it. Every failure site in the turn loop reports
/// through this.
pub fn failureKind(cause: types.ModelRecoveryCause) ?Failure.Kind {
    return switch (cause) {
        // A path that is down sent nothing.
        .connectivity_lost => .offline,
        // A connection that broke after connecting may have sent the request.
        .network_interrupted, .response_interrupted, .provider_stream_timeout => .dropped,
        .provider_unavailable => .server,
        .rate_limited => .rate_limited,
        .authentication, .request_limit_reached, .compaction_prepared => null,
    };
}

/// The unreadable replies one request takes before its turn ends: a server
/// that sends one every time is broken, not having a bad moment.
const max_unreadable_replies = 3;

/// Whether the store now holds a login the waiting request can send, other
/// than the one the provider refused, as another spark process that signs in
/// saves.
const SignInRenewed = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque) bool,
};

pub const RequestRecovery = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    /// Set by the host when the user answers a request that waits for them,
    /// for example with Enter. Null on hosts that cannot ask the user, which
    /// end the turn instead (`canAskUser`).
    continue_flag: ?*std.atomic.Value(bool) = null,
    /// Set by the same host when the sign-in it opened for this request
    /// closes without a new login (`recovery.Event.sign_in_closed`).
    sign_in_closed_flag: ?*std.atomic.Value(bool) = null,
    /// Set by spark while the request waits for a sign-in. Asked about once a
    /// second; a new login answers the wait as the user's continue does.
    sign_in_renewed: ?SignInRenewed = null,
    /// Off in tests unless a test exercises the thread itself.
    ticker_enabled: bool = !builtin.is_test,
    /// Replies this request could not read. Touched only by the request's
    /// own thread.
    unreadable_replies: u8 = 0,
    /// Links the request into `registry` while it is registered. Guarded by
    /// `registry_mutex`, not `mutex`.
    registry_node: std.DoublyLinkedList.Node = .{},
    registered: bool = false,

    mutex: std.Io.Mutex = .init,
    // Everything below is guarded by `mutex`.
    state: recovery.State = .{},
    /// Sends the module asked for, including the first: its attempt count.
    attempts: u16 = 0,
    /// How the latest send goes out.
    send: Send = .{},
    /// The host showed a status for this request, so a success reports
    /// `recovered`.
    recovery_shown: bool = false,
    /// `responding` was delivered for the current send.
    responded: bool = false,
    /// The host's status line holds a module status right now.
    host_showing: bool = false,
    ticker: ?std.Thread = null,
    ticker_stop: bool = false,
    ticker_wake: std.Io.Condition = .init,
    /// Single-threaded builds tick from the transport's cooperative pulse.
    inner_pulse: ?agent_stream_provider.CooperativePulse = null,
    /// The module's newest save, and whether it reached the turn.
    record: ?recovery.Record = null,
    record_written: bool = false,
    /// A record on disk says a send is or was in flight; a completed
    /// response or the request's end clears it.
    record_live: bool = false,
    /// `closeActive` saved the record marked clean: spark is exiting, and
    /// nothing after that may replace it.
    closed: bool = false,
    next_beat_ms: u64 = 0,
    /// Tests run on this virtual boot clock, so a 30-second wait takes no
    /// real time.
    virtual_now_ms: atomic_value.Value(u64) = .init(test_epoch_ms),

    pub fn init(
        deps: *const runtime_deps.AgentRuntimeDeps,
        cancel_flag: *std.atomic.Value(bool),
        trace_ctx: debug_trace.TraceContext,
    ) RequestRecovery {
        return .{ .deps = deps, .cancel_flag = cancel_flag, .trace_ctx = trace_ctx };
    }

    /// Every exit of the request ends here, so a module status the host still
    /// shows is cleared and a retry warning never outlives its request
    /// (`tests/tla/recovery/Recovery.tla` StatusHonest).
    pub fn deinit(self: *RequestRecovery) void {
        unregister(self);
        self.endSend();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearShownLocked();
    }

    pub const Resume = types.RecoveryResume;

    /// A new request, or one resumed. `fast` is the request's Fast
    /// selection, which makes "retrying without Fast" a real option.
    /// Returns the first send, or null when the module asks the user first;
    /// the caller then writes the turn and calls `waitForSend`.
    pub fn start(self: *RequestRecovery, fast: bool, resumed: ?Resume) !?Send {
        if (self.deps.begin_route_recovery_request) |begin| begin(self.deps.ctx);
        if (self.deps.save_recovery_record != null) register(self);
        const from = resumed orelse Resume{};
        return self.event(.{ .start = .{ .fast = fast, .resume_from = from.record, .stale = from.stale } });
    }

    /// The record for the write just before a send: the module's save for
    /// that send, until it is written. `.keep` on hosts that keep no record.
    pub fn sendRecord(self: *RequestRecovery) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed or self.deps.save_recovery_record == null or self.record_written) return .keep;
        const record = self.record orelse return .keep;
        self.record_written = true;
        self.record_live = true;
        return .{ .save = record };
    }

    /// The record for the write that saves a response: a complete response
    /// clears it there, before its pieces reach the turn, so a death after
    /// that is not a death with a send in flight
    /// (`tests/tla/recovery/Resume.tla` NoFalseCrashQuestion).
    pub fn responseRecord(self: *RequestRecovery, complete: bool) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!complete or self.closed or !self.record_live) return .keep;
        self.record_live = false;
        return .clear;
    }

    /// Writes a save the module made with a send now, for providers whose
    /// sends have no write before them.
    pub fn flushRecord(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.writeRecordLocked();
    }

    /// SIGHUP, SIGTERM, or a terminal that hangs up: delivers `closing` to
    /// every registered request and writes the clean record each returns, so
    /// the next launch resumes them without counting a death
    /// (`tests/tla/recovery/Resume.tla` NoFalseCrashQuestion). Main, its
    /// subagents and other instances can each have a request in flight.
    /// Waits at most `close_wait_ms` for each lock. Returns how many records
    /// were written.
    pub fn closeActive() usize {
        const io = io_mod.getIo();
        if (!lockWithin(&registry_mutex, close_wait_ms)) {
            debug_trace.logf("recovery", "closing skipped every request reason=registry_busy", .{});
            return 0;
        }
        defer registry_mutex.unlock(io);
        var written: usize = 0;
        var node = registry.first;
        while (node) |current| : (node = current.next) {
            const request: *RequestRecovery = @fieldParentPtr("registry_node", current);
            if (request.close()) written += 1;
        }
        return written;
    }

    /// Closes this request for `closeActive`. Returns whether its clean
    /// record was written.
    fn close(self: *RequestRecovery) bool {
        const io = io_mod.getIo();
        if (!lockWithin(&self.mutex, close_wait_ms)) {
            // Its record stays as it was, so the next launch counts a death.
            debug_trace.eventf("recovery", "closing_skipped", self.trace_ctx, "reason=request_busy", .{});
            return false;
        }
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        _ = self.stepLocked(.closing) catch |err| {
            debug_trace.logf("recovery", "closing status publication failed err={s}", .{@errorName(err)});
        };
        const written = self.record_written;
        self.closed = true;
        debug_trace.eventf("recovery", "closed", self.trace_ctx, "record_written={}", .{written});
        return written;
    }

    /// Reports a failed send. Returns the send the module asks for at once,
    /// which only compaction and a sign-in failure the user already answered
    /// do. Any other kind makes the module wait or ask the user; the caller
    /// then calls `waitForSend`.
    pub fn failed(self: *RequestRecovery, failure: Failure) !?Send {
        // An answer given before this failure answers nothing, except a
        // sign-in that finished while a resend for one was on the wire: the
        // module keeps that one and resends at once with the new login. It
        // ignores the continue in every other phase.
        if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
            _ = try self.deliverAnswer(.user_continue, "failed_send");
        };
        // The send that failed was the saved login's try, so a sign-in that
        // closed while it was on the wire leaves nothing more to try.
        if (self.sign_in_closed_flag) |flag| if (flag.swap(false, .seq_cst)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event=sign_in_closed origin=failed_send reason=the_failed_send_tried_the_saved_login", .{});
        };
        return self.event(.{ .failed = failure });
    }

    /// Whether the host can answer a request that needs the user. Hosts that
    /// cannot keep spark's own handling and end the turn.
    pub fn canAskUser(self: *const RequestRecovery) bool {
        return self.continue_flag != null;
    }

    /// The user answered a request that waits for them, other than through
    /// the continue flag, for example with a picker choice. Returns the
    /// module's send.
    pub fn userContinue(self: *RequestRecovery) !?Send {
        return self.deliverAnswer(.user_continue, "host");
    }

    /// Waits for the module's next send, delivering `tick` every
    /// `wait_tick_ms`, `user_continue` when the continue flag is set or
    /// `sign_in_renewed` finds a new login, and `sign_in_closed` when the
    /// sign-in closed flag is set. Returns null when the cancel flag is set;
    /// the caller then runs its cancel path, which calls `cancel`.
    pub fn waitForSend(self: *RequestRecovery) !?Send {
        var next_tick_ms = self.nowMs() +| wait_tick_ms;
        var next_sign_in_check_ms = self.nowMs() +| sign_in_check_ms;
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return null;
            if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.deliverAnswer(.user_continue, "wait")) |send| return send;
            };
            if (self.sign_in_closed_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.deliverAnswer(.sign_in_closed, "wait")) |send| return send;
            };
            const now_ms = self.nowMs();
            if (self.sign_in_renewed) |renewed| if (now_ms >= next_sign_in_check_ms) {
                next_sign_in_check_ms = now_ms +| sign_in_check_ms;
                if (renewed.check(renewed.ctx)) {
                    if (try self.deliverAnswer(.user_continue, "stored_sign_in")) |send| return send;
                }
            };
            if (now_ms < next_tick_ms) {
                self.sleepMs(@min(cancel_poll_ms, next_tick_ms - now_ms));
                continue;
            }
            next_tick_ms = now_ms +| wait_tick_ms;
            if (try self.event(.tick)) |send| return send;
        }
    }

    /// The first output of the current send arrived. Called from the
    /// transport's event callback, which cannot fail, so publication errors
    /// are traced. The check and the step share one hold of `mutex`, because
    /// `stepLocked` resets `responded` for each new send.
    pub fn responding(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.responded) return;
        self.responded = true;
        _ = self.stepLocked(.responding) catch |err| {
            debug_trace.logf("recovery", "responding status publication failed err={s}", .{@errorName(err)});
        };
    }

    /// The response arrived complete. After a request that showed a status,
    /// hosts that report a result get a `recovered` status, which carries
    /// only the attempt that succeeded.
    pub fn succeeded(self: *RequestRecovery) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = try self.stepLocked(.succeeded);
        if (!self.recovery_shown) return;
        self.recovery_shown = false;
        self.host_showing = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .recovered,
            .attempt = self.attempts,
        });
    }

    /// Esc or quitting: ends the request and clears its status.
    pub fn cancel(self: *RequestRecovery) !void {
        _ = try self.event(.user_cancel);
    }

    /// spark's own terminal status replaces the module's on the host. Terminal
    /// failures keep spark's handling and wording in this change. The terminal
    /// status is the request's result, so nothing reports over it.
    pub fn replaceStatus(self: *RequestRecovery, status: types.RouteRecoveryStatus) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.host_showing = false;
        self.recovery_shown = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, status);
    }

    /// The request ended on an error with no success, cancel, or terminal
    /// status of spark's own, for example an HTTP error after a retry or a
    /// resend that never reached the transport. After the host showed a
    /// status, hosts that report a result get `failed`, which also clears the
    /// TUI's status line; otherwise a module status still shown is cleared.
    pub fn endWithError(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.recovery_shown) return self.clearShownLocked();
        self.recovery_shown = false;
        self.host_showing = false;
        self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .failed,
            .attempt = self.attempts,
        }) catch |err| {
            debug_trace.logf("recovery", "failed status publication failed err={s}", .{@errorName(err)});
        };
    }

    fn clearShownLocked(self: *RequestRecovery) void {
        if (!self.host_showing) return;
        self.host_showing = false;
        self.deps.push_event(self.deps.ctx, .clear_route_recovery_status) catch |err| {
            debug_trace.logf("recovery", "stale status clear failed err={s}", .{@errorName(err)});
        };
    }

    /// Sends so far, including the first.
    /// Counts a reply this request could not read, and says whether it is
    /// the last one: past `max_unreadable_replies` the turn ends with the
    /// error instead of another resend.
    pub fn unreadableReplyEndsRequest(self: *RequestRecovery) bool {
        self.unreadable_replies +|= 1;
        return self.unreadable_replies >= max_unreadable_replies;
    }

    pub fn attempt(self: *RequestRecovery) u16 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.attempts;
    }

    /// Starts the ticker that keeps the retrying status counting while a
    /// send is on the wire.
    ///
    /// Why calling the host from this second thread is safe. The ticker only
    /// steps `tick` under `mutex`, and while a send is out `tick` can only
    /// refresh the `retrying` status the turn loop already published for it
    /// (`recovery.zig` `onTick`, phase `sending`): no clear, no send. Until
    /// `endSend`, every other route status for the request also comes from
    /// this file under `mutex` (`responding`'s clear), and spark's terminal
    /// statuses go through `replaceStatus` only after the stream returns.
    /// The turn loop keeps calling the host's other callbacks meanwhile, and
    /// each host takes a status from another thread safely:
    ///
    /// - TUI (`app_callbacks.agentPushRouteRecoveryStatus`): copies the event
    ///   with `std.heap.c_allocator` and queues it under `worker_mutex`.
    /// - ACP (`AcpContext.sendModelRecoveryStatus`): formats into a local
    ///   writer and writes one frame under `jsonrpc.Writer.mutex`; libfx's
    ///   writer callback queues under its own mutex. The allocator is the
    ///   server loop's (`processAllocator()` for `spark acp`, `c_allocator` for
    ///   libfx, and `state.alloc` for subagent children), never an arena, and
    ///   the loop thread already shares it with the prompt thread.
    /// - `spark ask` (`pushRouteRecoveryStatus`): writes only its two recovery
    ///   fields. During a send their only other writer is the clear from
    ///   `responding`, under `mutex`, and the result reads them after the
    ///   ticker is joined. It prints only when the kind changes, which a
    ///   `retrying` refresh never does.
    /// - Subagent children and the default deps drop the status.
    ///
    /// Single-threaded builds, such as wasm, tick from the transport's
    /// cooperative pulse on the turn loop's own thread instead.
    pub fn beginSend(self: *RequestRecovery) void {
        if (comptime builtin.single_threaded) {
            self.next_beat_ms = self.nowMs() +| tick_ms;
            return;
        }
        if (!self.ticker_enabled or self.ticker != null) return;
        self.ticker_stop = false;
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch |err| {
            // The status then refreshes at the next event instead.
            debug_trace.logf("recovery", "status ticker unavailable err={s}", .{@errorName(err)});
            return;
        };
    }

    pub fn endSend(self: *RequestRecovery) void {
        const thread = self.ticker orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.ticker_stop = true;
        self.ticker_wake.signal(io);
        self.mutex.unlock(io);
        thread.join();
        self.ticker = null;
    }

    /// Single-threaded builds have no ticker thread, so the transport's
    /// cooperative pulse delivers the in-flight `tick` instead. Threaded
    /// builds get `inner` back unchanged.
    pub fn cooperativePulse(
        self: *RequestRecovery,
        inner: ?agent_stream_provider.CooperativePulse,
    ) ?agent_stream_provider.CooperativePulse {
        if (comptime !builtin.single_threaded) return inner;
        self.inner_pulse = inner;
        return .{ .ctx = self, .run = pulseBeat };
    }

    fn pulseBeat(raw: *anyopaque) anyerror!void {
        const self: *RequestRecovery = @ptrCast(@alignCast(raw));
        const now_ms = self.nowMs();
        if (now_ms >= self.next_beat_ms) {
            self.next_beat_ms = now_ms +| tick_ms;
            _ = self.event(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
        if (self.inner_pulse) |inner| try inner.pulse();
    }

    fn tickerMain(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.ticker_stop) {
            self.ticker_wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(ticker_interval_ns),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (self.ticker_stop) return;
            _ = self.stepLocked(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
    }

    fn event(self: *RequestRecovery, value: recovery.Event) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stepLocked(value);
    }

    /// Steps the module with a user's answer, and traces the answer when
    /// the module has no use for it, since that drops what the user did: an
    /// Enter while nothing waits for them, or a closed sign-in while no wait
    /// is for one. `origin` names where the answer was read.
    fn deliverAnswer(self: *RequestRecovery, value: recovery.Event, origin: []const u8) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!recovery.usesAnswer(&self.state, value)) {
            debug_trace.eventf("recovery", "answer_dropped", self.trace_ctx, "event={s} origin={s} reason=nothing_waits_for_it", .{ @tagName(value), origin });
        }
        return self.stepLocked(value);
    }

    /// Steps the module and carries out its plan in field order. Returns
    /// the plan's send, which the caller carries out.
    fn stepLocked(self: *RequestRecovery, value: recovery.Event) !?Send {
        // spark is exiting with the clean record saved; nothing replaces it.
        if (self.closed) return null;
        const now_ms = self.nowMs();
        const plan = recovery.step(&self.state, value, now_ms);
        if (plan.send) |send| {
            self.attempts +|= 1;
            self.send = send;
            self.responded = false;
        }
        if (plan.send != null or plan.status != null or plan.finish != null) {
            debug_trace.eventf("recovery", "step", self.trace_ctx, "event={s} now_ms={d} attempt={d} send={s} no_fast={} status={s} finish={s}", .{
                @tagName(value),
                now_ms,
                self.attempts,
                if (plan.send != null) "true" else "false",
                self.send.no_fast,
                if (plan.status) |status| @tagName(status.kind) else "none",
                if (plan.finish) |finish| @tagName(finish) else "none",
            });
        }
        if (plan.save) |record| {
            self.record = record;
            self.record_written = false;
            // A save with a send travels in the write before that send.
            if (plan.send == null) self.writeRecordLocked();
        }
        if (plan.status) |status| try self.showLocked(status);
        if (plan.finish) |finish| switch (finish) {
            // A response that never reached `responseRecord` clears here.
            .succeeded => if (self.record_live) {
                _ = self.saveLocked(.clear);
            },
            // The turn ends cancelled, which ends its record too.
            .cancelled => self.recovery_shown = false,
        };
        return plan.send;
    }

    /// Writes the newest save if the turn is on disk; otherwise it waits for
    /// the turn's first write.
    fn writeRecordLocked(self: *RequestRecovery) void {
        if (self.record_written) return;
        const record = self.record orelse return;
        if (self.saveLocked(.{ .save = record })) {
            self.record_written = true;
            self.record_live = true;
        }
    }

    fn saveLocked(self: *RequestRecovery, write: types.RecoveryRecordWrite) bool {
        const save = self.deps.save_recovery_record orelse return false;
        const written = save(self.deps.ctx, write) catch |err| {
            debug_trace.logf("recovery", "record {s} failed err={s}", .{ @tagName(write), @errorName(err) });
            return false;
        };
        if (written and write == .clear) self.record_live = false;
        return written;
    }

    fn showLocked(self: *RequestRecovery, status: recovery.Status) !void {
        if (types.RouteRecoveryStatus.fromRecovery(status, self.attempts)) |shown| {
            self.recovery_shown = true;
            self.host_showing = true;
            try self.deps.push_route_recovery_status(self.deps.ctx, shown);
        } else {
            self.host_showing = false;
            try self.deps.push_event(self.deps.ctx, .clear_route_recovery_status);
        }
    }

    fn nowMs(self: *RequestRecovery) u64 {
        if (comptime builtin.is_test) return self.virtual_now_ms.load(.seq_cst);
        const ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .boot).raw.toNanoseconds();
        return if (ns <= 0) 0 else @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn sleepMs(self: *RequestRecovery, ms: u64) void {
        if (comptime builtin.is_test) {
            _ = self.virtual_now_ms.fetchAdd(ms, .seq_cst);
            return;
        }
        // A single-threaded host, such as the browser SDK, delivers Esc only
        // through the cooperative pulse, so a wait that never pulsed ended
        // before the cancel could arrive.
        if (comptime builtin.single_threaded) {
            if (self.inner_pulse) |inner| inner.pulse() catch |err| {
                debug_trace.logf("recovery", "wait pulse failed err={s}", .{@errorName(err)});
            };
        }
        io_mod.getIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
    }
};

const close_wait_ms: u64 = 1_000;

fn lockWithin(mutex: *std.Io.Mutex, ms: u64) bool {
    var waited_ms: u64 = 0;
    while (!mutex.tryLock()) {
        if (waited_ms >= ms) return false;
        io_mod.getIo().sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 5;
    }
    return true;
}

/// The requests `closeActive` closes: every running request that keeps a
/// record, in every agent of the process. Each links itself through its own
/// `registry_node`, so registering never allocates.
var registry_mutex: std.Io.Mutex = .init;
var registry: std.DoublyLinkedList = .{};

fn register(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (request.registered) return;
    registry.append(&request.registry_node);
    request.registered = true;
}

/// Removes only `request`, so a request that ends never takes another
/// agent's out of `closeActive`'s reach.
fn unregister(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (!request.registered) return;
    registry.remove(&request.registry_node);
    request.registry_node = .{};
    request.registered = false;
}

// Tests.

const support = @import("tests/support.zig");

fn statusTexts(fake: *const support.FakeAgentRuntimeDeps, buf: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (fake.route_recovery_statuses.items) |*status| {
        if (count == buf.len) break;
        buf[count] = status.text.slice();
        count += 1;
    }
    return buf[0..count];
}

test "a transient failure waits with the module's status, then resends" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);

    _ = try request.failed(.{ .kind = .dropped });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, waiting.kind);
    try std.testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1", waiting.text.slice());
    try std.testing.expectEqual(@as(usize, 1), waiting.attempt);

    const send = (try request.waitForSend()).?;
    try std.testing.expectEqual(Send{}, send);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, retrying.kind);
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Connection lost · retrying · attempt 2"));
}

const StoredSignInProbe = struct {
    found_after: usize,
    checks: usize = 0,

    fn check(raw: *anyopaque) bool {
        const self: *StoredSignInProbe = @ptrCast(@alignCast(raw));
        self.checks += 1;
        return self.checks > self.found_after;
    }
};

fn recordingFake() support.FakeAgentRuntimeDeps {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    fake.enable_recovery_record = true;
    return fake;
}
