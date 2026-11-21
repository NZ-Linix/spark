const std = @import("std");
const testing_allocator = @import("testing_allocator.zig");
const text_utils = @import("text_utils.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const recovery = @import("../recovery/recovery.zig");

pub const Layout = struct {
    rows: u16,
    cols: u16,
    content_bottom: u16,
    divider_top_row: u16,
    input_row: u16,
    divider_bottom_row: u16,
    hint_row: u16,
};

pub const Metrics = struct {
    ansi_bytes: usize = 0,
    full_redraws: usize = 0,
    debounced_resizes: usize = 0,
    footer_line_updates: usize = 0,
    stream_chunks: usize = 0,
};

pub const NoticeTone = enum {
    information,
    success,
    warning,
    @"error",
    cancelled,
    // Renders in the neutral body color so the line reads like a normal response.
    neutral,
};

pub const NoticeVisibility = enum {
    compact_and_full,
    full_only,
};

pub const SemanticNotice = struct {
    topic: []const u8,
    tone: NoticeTone,
    body: []const u8,
    visibility: NoticeVisibility = .compact_and_full,
    /// An optional dim line under the body, indented like a wrapped body row
    /// and without its own glyph.
    detail: []const u8 = "",
};

/// Status glyph leading every semantic notice, keyed by tone. Tool activity
/// owns "●"; notices deliberately use distinct git-style status glyphs so the
/// two channels never read as the same raw marker. The neutral marker "*"
/// avoids the middot, which the footer already uses as a separator.
pub fn noticeGlyph(tone: NoticeTone) []const u8 {
    return switch (tone) {
        .information => "i",
        .success => "✓",
        .warning => "!",
        .@"error" => "✗",
        .cancelled => "⊘",
        .neutral => "*",
    };
}

/// Returns a duplicate with owned topic, body, and detail bytes. The caller frees it
/// with `freeSemanticNotice` using the same allocator.
pub fn dupeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) std.mem.Allocator.Error!SemanticNotice {
    const topic = try alloc.dupe(u8, notice.topic);
    errdefer alloc.free(topic);
    const body = try alloc.dupe(u8, notice.body);
    errdefer alloc.free(body);
    return .{
        .topic = topic,
        .tone = notice.tone,
        .body = body,
        .visibility = notice.visibility,
        .detail = try alloc.dupe(u8, notice.detail),
    };
}

pub fn freeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) void {
    alloc.free(notice.topic);
    alloc.free(notice.body);
    alloc.free(notice.detail);
}

/// Converts legacy context-notice text into a semantic notice body while
/// preserving line structure. The caller owns the returned bytes.
pub fn renderContextNoticeBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var needs_separator = false;
    while (lines.next()) |line| {
        if (needs_separator) try body.writer.writeByte('\n');
        needs_separator = true;
        if (std.mem.eql(u8, line, "[context]")) continue;
        const legacy_prefix = "[context] ";
        try body.writer.writeAll(if (std.mem.startsWith(u8, line, legacy_prefix)) line[legacy_prefix.len..] else line);
    }
    return body.toOwnedSlice();
}

test "context notice body drops legacy markers from every line" {
    const body = try renderContextNoticeBody(
        std.testing.allocator,
        "[context] first\n[context] second\nalready semantic\n[context]\n",
    );
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("first\nsecond\nalready semantic\n\n", body);
}

pub const CredentialSource = enum {
    host_managed,
    configured,
};

pub const DirectCredentialLease = struct {
    secret_bytes: []const u8 = "",
    source: ?CredentialSource = null,
    account_id: ?[]const u8 = null,
    tenant_context: ?[]const u8 = null,
};

/// Borrowed authorization for one provider request. Host-managed requests
/// cannot carry credential or account bytes into the embedded runtime.
pub const CredentialLease = union(enum) {
    direct: DirectCredentialLease,
    host_managed,

    pub fn secret(self: CredentialLease) ?[]const u8 {
        return switch (self) {
            .direct => |direct| if (direct.secret_bytes.len > 0) direct.secret_bytes else null,
            .host_managed => null,
        };
    }

    pub fn credentialSource(self: CredentialLease) ?CredentialSource {
        return switch (self) {
            .direct => |direct| direct.source,
            .host_managed => .host_managed,
        };
    }

    pub fn accountId(self: CredentialLease) ?[]const u8 {
        return switch (self) {
            .direct => |direct| direct.account_id,
            .host_managed => null,
        };
    }

    pub fn tenant(self: CredentialLease) ?[]const u8 {
        return switch (self) {
            .direct => |direct| direct.tenant_context,
            .host_managed => null,
        };
    }
};

pub fn parseCredentialSource(text: []const u8) ?CredentialSource {
    const source = parseRuntimeCredentialSource(text) orelse return null;
    return if (source == .host_managed or source == .configured) null else source;
}

pub fn parseRuntimeCredentialSource(text: []const u8) ?CredentialSource {
    return std.meta.stringToEnum(CredentialSource, text);
}

pub const TurnPresentationOutcome = enum {
    completed,
    interrupted,
    failed,
    paused,
};

pub const TurnFinished = struct {
    turn_id: u64,
    outcome: TurnPresentationOutcome,
};

pub const ToolLifecycleId = struct {
    turn_id: u64,
    call_id: []const u8,
};

pub const ToolPresentationGroupId = struct {
    turn_id: u64,
    anchor_step_id: u64,
};

pub const ToolOutcomeKind = enum {
    completed,
    denied,
    cancelled,
    failed,
    deferred,
};

pub const ToolOutcome = struct {
    kind: ToolOutcomeKind,
    summary: []const u8,
};

pub const ToolLifecycleEvent = union(enum) {
    provisional: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        tool_name: ?[]const u8,
        activity_kind: ToolActivityKind,
    },
    authoritative_started: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        reconciles_provisional_call_id: ?[]const u8,
        tool_name: []const u8,
        activity_kind: ToolActivityKind,
        arguments_json: ?[]const u8 = null,
        place_after_current_transcript: bool = false,
        /// The call's `ToolCall.resolved_display_target`, for hosts that
        /// title a call when it starts. Borrowed for this push only; copies
        /// omit it.
        resolved_display_target: ?[]const u8 = null,
    },
    progress: struct {
        id: ToolLifecycleId,
        text: []const u8,
    },
    terminal: struct {
        id: ToolLifecycleId,
        outcome: ToolOutcome,
        result: ?[]const u8 = null,
        result_memory: ?ToolResultMemory = null,
        command_artifact_handle: ?[]const u8 = null,
    },
    turn_finished: TurnFinished,
};

pub const TurnPhase = enum {
    thinking,
    generating,
    running,
    waiting_for_subagent,
};

pub const TurnPhaseUpdate = struct {
    turn_id: u64,
    step_id: u64,
    phase: TurnPhase,
};

pub const StreamState = struct {
    active: bool = false,
    phase: TurnPhase = .thinking,
    phase_step_id: u64 = 0,
    chunks: usize = 0,
    read_count: usize = 0,
    list_count: usize = 0,
    write_count: usize = 0,
    edit_count: usize = 0,
    open_count: usize = 0,
    command_count: usize = 0,
    subagent_count: usize = 0,
    mcp_count: usize = 0,
    token_progress: TurnTokenProgress = .{},
    last_activity_kind: ?ToolActivityKind = null,
    /// When the turn started; 0 hides the elapsed counter and activity blink.
    /// Monotonic for the whole turn: phase and tool boundaries never reset it.
    turn_started_ms: i64 = 0,
    /// When the turn started waiting, on user input (approval or question)
    /// or on a compaction; 0 means not waiting. While set, the turn clock
    /// freezes at this instant; on resume the wait is excluded by shifting
    /// turn_started_ms forward.
    waiting_since_ms: i64 = 0,
};

pub const RouteRecoveryUnsafeReason = enum {
    assistant_output,
    tool_start,
};

pub const RouteRecoveryStatusTone = enum {
    /// The thinking row's own bullet and color, held still: a request that is
    /// on the wire again. Animating it belongs to the status line.
    live,
    warning,
    success,
    danger,
};

/// Whether a 5xx is a server failure a resend can outlive: every one, 529
/// (overloaded) and 520-524 (Cloudflare) included, except 501 Not
/// Implemented and 505 HTTP Version Not Supported, which say this request
/// can never work there.
pub fn isRetryableServerStatus(code: u16) bool {
    return code >= 500 and code <= 599 and code != 501 and code != 505;
}

pub const ModelRecoveryCause = enum {
    network_interrupted,
    /// The network path is provably down, so nothing was sent.
    connectivity_lost,
    response_interrupted,
    provider_stream_timeout,
    provider_unavailable,
    rate_limited,
    authentication,
    request_limit_reached,
    compaction_prepared,
};

pub const ModelRecoveryAction = enum {
    retrying_request,
    continuing_response,
    regenerating_tool,
    continuing_after_tool,
    reconciling_tool,
    // Checkpoints saved by older versions may name the next three; spark no
    // longer writes them, but they still parse.
    waiting_for_connectivity,
    checking_liveness,
    paused,
    /// The final reply finished before its turn was saved as done; recovery
    /// delivers that saved reply without another model request.
    delivering_response,
};

pub const ModelFailureDiagnostic = struct {
    pub const max_bytes: usize = 256;

    bytes: [max_bytes]u8 = @splat(0),
    len: u16 = 0,

    pub fn defaultTextForCause(cause: ModelRecoveryCause) []const u8 {
        return switch (cause) {
            .network_interrupted => "NetworkInterrupted",
            .connectivity_lost => "ConnectionUnavailable",
            .response_interrupted => "StreamInterrupted",
            .provider_stream_timeout => "gateway_stream_timeout",
            .provider_unavailable => "provider_error",
            .rate_limited => "HTTP 429",
            .authentication => "AuthenticationExpired",
            .request_limit_reached => "ProviderRequestLimitReached",
            .compaction_prepared => "CompactionPrepared",
        };
    }

    pub fn init(text: []const u8) ModelFailureDiagnostic {
        var diagnostic: ModelFailureDiagnostic = .{};
        if (text.len <= max_bytes) {
            @memcpy(diagnostic.bytes[0..text.len], text);
            diagnostic.len = @intCast(text.len);
            return diagnostic;
        }

        const marker = "...";
        const prefix = text_utils.utf8PrefixByBytes(text, max_bytes - marker.len);
        @memcpy(diagnostic.bytes[0..prefix.len], prefix);
        @memcpy(diagnostic.bytes[prefix.len .. prefix.len + marker.len], marker);
        diagnostic.len = @intCast(prefix.len + marker.len);
        return diagnostic;
    }

    pub fn view(self: *const ModelFailureDiagnostic) []const u8 {
        return self.bytes[0..self.len];
    }

    /// The diagnostic in plain words (`plainErrorText`). `buf` holds an error
    /// name split into words.
    pub fn humanText(self: *const ModelFailureDiagnostic, buf: []u8) []const u8 {
        return plainErrorText(self.view(), buf);
    }
};

/// Plain words for an error name spark shows people: the phrase for a name it
/// knows, else the name split into lowercase words, so `InvalidModelReply`
/// reads "invalid model reply". Text that is not an error name, such as a
/// provider's own message, passes through unchanged. Raw names stay in trace
/// logs. `buf` holds a split name; one too long for it is cut short.
pub fn plainErrorText(raw: []const u8, buf: []u8) []const u8 {
    const pairs = .{
        .{ "ReadFailed", "connection dropped" },
        .{ "WriteFailed", "connection dropped" },
        .{ "EndOfStream", "connection closed" },
        .{ "HttpConnectionClosing", "connection closed" },
        .{ "ConnectionResetByPeer", "connection reset" },
        .{ "ConnectionRefused", "connection refused" },
        .{ "ConnectionTimedOut", "connection timed out" },
        .{ "ConnectionSetupTimedOut", "connection took too long to open" },
        .{ "TlsInitializationFailed", "couldn't make a secure connection" },
        .{ "CertificateBundleLoadFailure", "couldn't load trusted certificates" },
        .{ "Timeout", "timed out" },
        .{ "StreamStalled", "stream stalled" },
        .{ "UnknownHostName", "cannot resolve host" },
        .{ "NameServerFailure", "DNS lookup failed" },
        .{ "NetworkUnreachable", "network unreachable" },
        .{ "NetworkDown", "network is down" },
        .{ "HostUnreachable", "host unreachable" },
        .{ "NetworkInterrupted", "network interrupted" },
        .{ "StreamInterrupted", "stream interrupted" },
        .{ "InvalidGatewaySseEvent", "unreadable reply" },
        .{ "InvalidOpenAICodexSseEvent", "unreadable reply" },
        .{ "InvalidXaiGrokSseEvent", "unreadable reply" },
        .{ "MalformedGatewaySseEvent", "unreadable reply" },
        .{ "MalformedOpenAICodexSseEvent", "unreadable reply" },
        .{ "MalformedXaiGrokSseEvent", "unreadable reply" },
        .{ "MalformedChatCompletionsChunk", "unreadable reply" },
        .{ "InvalidResponsesEvent", "unreadable reply" },
        .{ "MalformedResponsesEvent", "unreadable reply" },
        .{ "MalformedMessagesEvent", "unreadable reply" },
        .{ "ResponsesEventTooLarge", "reply too large to read" },
        .{ "InvalidProviderFinishReason", "unreadable reply" },
        .{ "GatewaySseEventTooLarge", "reply too large to read" },
        .{ "OpenAICodexSseEventTooLarge", "reply too large to read" },
        .{ "XaiGrokSseEventTooLarge", "reply too large to read" },
        // Storage faults read as spark says them on startup and in ACP.
        .{ "AccessDenied", "permission denied" },
        .{ "ReadOnlyFileSystem", "the disk is read-only" },
        .{ "NoSpaceLeft", "the disk is full" },
        .{ "FileTooBig", "a file-size limit was reached" },
        .{ "InputOutput", "a disk read or write failed" },
        // A write to spark's own stdout or stderr, which a command reports in
        // place of `WriteFailed` (`cli_surface.runIfRequested`).
        .{ "OutputWriteFailed", "couldn't write the output" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, raw, pair[0])) return pair[1];
    }
    if (!isErrorName(raw)) return raw;
    var len: usize = 0;
    for (raw, 0..) |c, i| {
        const starts_word = i > 0 and std.ascii.isUpper(c) and
            (std.ascii.isLower(raw[i - 1]) or (i + 1 < raw.len and std.ascii.isLower(raw[i + 1])));
        if (starts_word) {
            if (len >= buf.len) break;
            buf[len] = ' ';
            len += 1;
        }
        if (len >= buf.len) break;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    return buf[0..len];
}

/// A Zig error name, as `@errorName` gives it: one ASCII word that starts
/// with a capital and has a lowercase letter.
fn isErrorName(raw: []const u8) bool {
    if (raw.len == 0 or !std.ascii.isUpper(raw[0])) return false;
    var lower = false;
    for (raw) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
        lower = lower or std.ascii.isLower(c);
    }
    return lower;
}

pub const RouteRecoveryStatus = struct {
    pub const label_max_bytes: usize = 512;

    pub const Kind = enum {
        // The recovery module's status kinds (`src/core/recovery/recovery.zig`
        // `Status.Kind`). Its `clear` reaches hosts as the
        // `clear_route_recovery_status` event instead of a status.
        waiting,
        retrying,
        need_user,
        /// The request succeeded after the module showed a status. It
        /// carries only the attempt that succeeded. Hosts that report a
        /// result show it; the TUI clears its status line.
        recovered,
        /// The request ended on an error after the module showed a status,
        /// with no terminal status of spark's own. It carries only the last
        /// attempt; the error reaches the host its usual way. Hosts that
        /// report a result show it; the TUI clears its status line.
        failed,
        // Terminal outcomes spark reports itself.
        terminal_provider_error,
        unsafe_assistant_output,
        unsafe_tool_start,
        content_filter,
    };

    kind: Kind,
    /// Set with `need_user`: the prompt the module asks spark to show.
    need: ?recovery.Status.Need = null,
    /// The module's wording, shared by every host. Empty for `recovered` and
    /// for terminal outcomes.
    text: recovery.Text = .{},
    /// A form of `text` that fits 46 columns; empty when `text` already does.
    short: recovery.Text = .{},
    /// Sends of the request so far, including the first.
    attempt: usize = 0,
    cause: ?ModelRecoveryCause = null,
    diagnostic: ?ModelFailureDiagnostic = null,

    /// Null for `clear`, which hosts receive as the clear event.
    pub fn fromRecovery(status: recovery.Status, attempt: usize) ?RouteRecoveryStatus {
        const kind: Kind = switch (status.kind) {
            .clear => return null,
            .waiting => .waiting,
            .retrying => .retrying,
            .need_user => .need_user,
        };
        return .{
            .kind = kind,
            .need = status.need,
            .text = status.text,
            .short = status.short,
            .attempt = attempt,
        };
    }

    /// A status the recovery module produced, as opposed to one spark composed.
    pub fn fromModule(self: RouteRecoveryStatus) bool {
        return switch (self.kind) {
            .waiting, .retrying, .need_user => true,
            .recovered,
            .failed,
            .terminal_provider_error,
            .unsafe_assistant_output,
            .unsafe_tool_start,
            .content_filter,
            => false,
        };
    }

    /// What `spark ask --json` reports as `recovery` and ACP as
    /// `_meta.spark.modelResponseRecovery`. Every key is one word, so both
    /// spell them the same way, and `need` keeps the module's snake_case
    /// tags.
    pub const Report = struct {
        state: ReportedState,
        attempt: usize,
        need: ?recovery.Status.Need = null,
        /// Omitted when the status has no wording: `recovered` and
        /// `failed` report only the attempt.
        message: ?[]const u8 = null,

        pub fn writeJson(self: Report, writer: *std.Io.Writer) !void {
            try writer.writeAll("{\"state\":");
            try std.json.Stringify.value(@tagName(self.state), .{}, writer);
            try writer.print(",\"attempt\":{d}", .{self.attempt});
            if (self.need) |need| {
                try writer.writeAll(",\"need\":");
                try std.json.Stringify.value(@tagName(need), .{}, writer);
            }
            if (self.message) |message| {
                try writer.writeAll(",\"message\":");
                try std.json.Stringify.value(message, .{}, writer);
            }
            try writer.writeByte('}');
        }
    };

    /// This status as hosts report it. The message lives in `buf`.
    pub fn report(self: RouteRecoveryStatus, buf: []u8) Report {
        const message = self.label(buf);
        return .{
            .state = self.reportedState(),
            .attempt = self.attempt,
            .need = self.need,
            .message = if (message.len == 0) null else message,
        };
    }

    /// The `state` that `spark ask --json` and ACP report, written as its tag.
    pub const ReportedState = enum {
        waiting,
        retrying,
        need_user,
        recovered,
        /// spark's terminal outcomes.
        failed,
        /// A request an earlier spark process was running when it stopped, as
        /// its saved recovery checkpoint reports it. No live status maps
        /// here: ACP reports it on session load.
        interrupted,
    };

    fn reportedState(self: RouteRecoveryStatus) ReportedState {
        return switch (self.kind) {
            .waiting => .waiting,
            .retrying => .retrying,
            .need_user => .need_user,
            .recovered => .recovered,
            .failed,
            .terminal_provider_error,
            .unsafe_assistant_output,
            .unsafe_tool_start,
            .content_filter,
            => .failed,
        };
    }

    /// Waiting and "needs you" rows warn; a resend shows the thinking row's
    /// live style, so a request back on the wire never reads as an alarm.
    pub fn tone(self: RouteRecoveryStatus) RouteRecoveryStatusTone {
        return switch (self.kind) {
            .retrying => .live,
            .waiting, .need_user => .warning,
            .recovered => .success,
            .failed,
            .terminal_provider_error,
            .unsafe_assistant_output,
            .unsafe_tool_start,
            .content_filter,
            => .danger,
        };
    }

    /// The module's `text` when set; otherwise spark's own wording for a
    /// terminal outcome. The result lives in `buf`.
    pub fn label(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        if (self.text.len > 0) {
            const len = @min(self.text.len, buf.len);
            @memcpy(buf[0..len], self.text.bytes[0..len]);
            return buf[0..len];
        }
        return switch (self.kind) {
            .waiting, .retrying, .need_user, .recovered, .failed => "",
            .terminal_provider_error => self.terminalLabel(buf),
            .unsafe_assistant_output => self.fixedFailureLabel(
                buf,
                "Response interrupted",
                "partial output preserved",
            ),
            .unsafe_tool_start => self.fixedFailureLabel(
                buf,
                "Tool state needs review",
                "context preserved",
            ),
            .content_filter => self.fixedFailureLabel(buf, "blocked", "content filter"),
        };
    }

    fn fixedFailureLabel(
        self: RouteRecoveryStatus,
        buf: []u8,
        cause: []const u8,
        action: []const u8,
    ) []const u8 {
        if (self.diagnostic) |diagnostic| {
            var words: [ModelFailureDiagnostic.max_bytes]u8 = undefined;
            return std.mem.print(
                buf,
                "⚠ {s} · {s} · {s}",
                .{ cause, diagnostic.humanText(&words), action },
            ) catch "⚠ Model response failed";
        }
        return std.mem.print(buf, "⚠ {s} · {s}", .{ cause, action }) catch "⚠ Model response failed";
    }

    fn causeDisplayName(cause: ModelRecoveryCause) []const u8 {
        return switch (cause) {
            .network_interrupted => "Network interrupted",
            .connectivity_lost => "Connection lost",
            .response_interrupted => "Response ended early",
            .provider_stream_timeout => "Gateway stream timed out",
            .provider_unavailable => "Provider unavailable",
            .rate_limited => "Rate limited",
            .authentication => "Authentication expired",
            .request_limit_reached => "Provider request limit reached",
            .compaction_prepared => "Saved compaction",
        };
    }

    fn terminalLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        const name = if (self.cause) |cause| causeDisplayName(cause) else "Provider unavailable";
        const plural: []const u8 = if (self.attempt == 1) "" else "s";
        if (self.diagnostic) |diagnostic| {
            var words: [ModelFailureDiagnostic.max_bytes]u8 = undefined;
            return std.mem.print(
                buf,
                "⚠ {s} · {s} · stopped after {d} attempt{s}",
                .{ name, diagnostic.humanText(&words), self.attempt, plural },
            ) catch "⚠ Model response recovery ended";
        }
        return std.mem.print(
            buf,
            "⚠ {s} · stopped after {d} attempt{s}",
            .{ name, self.attempt, plural },
        ) catch "⚠ Model response recovery ended";
    }
};

/// Tests build module status text with this. A string longer than
/// `recovery.Text` holds fails to compile.
pub fn testRecoveryText(comptime value: []const u8) recovery.Text {
    if (value.len > recovery.Text.capacity) {
        @compileError("recovery text is longer than recovery.Text.capacity: " ++ value);
    }
    var text: recovery.Text = .{};
    @memcpy(text.bytes[0..value.len], value);
    text.len = value.len;
    return text;
}

pub const ChatRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const FinalToolIdentity = enum {
    valid,
    absent,
    empty,
    wrong_type,
};

pub const ToolExecutionProvenance = enum {
    spark_local,
    provider_executed,
};

pub const ProviderResultIdentityFailure = enum {
    absent,
    empty,
    wrong_type,
    unmatched,
    ambiguous,
    missing_result,
    incomplete_streamed_input,
    invalid_tool_input,
    conflicting_tool_name,
    malformed_provider_executed,
    provenance_contradiction,
    malformed_preliminary,
    duplicate_result,
};

pub const ToolArgumentIntegrity = enum {
    valid,
    malformed_json,
    non_object_json,

    pub fn classifySerialized(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .malformed_json,
        };
        defer parsed.deinit();
        return .valid;
    }

    pub fn classifyFunctionInput(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        const integrity = try classifySerialized(alloc, serialized);
        if (integrity != .valid) return integrity;
        // A complete JSON root is nonempty; only an object can start with '{'.
        return if (std.mem.trimStart(u8, serialized, " \t\r\n")[0] == '{') .valid else .non_object_json;
    }
};

/// Explains why raw function arguments were `malformed_json`, captured before
/// spark replaces them with `{}`. It carries positions only: rejected argument
/// bytes never leave the parse step.
pub const ToolArgumentDiagnostic = struct {
    pub const Failure = enum {
        /// The input ended before the JSON value was complete.
        truncated,
        /// The scanner rejected the input at `error_offset`.
        syntax_error,
        /// The syntax was complete, but the parsed value was refused, such as
        /// an object that repeats a key.
        rejected_value,
    };

    failure: Failure,
    input_bytes: usize,
    /// Byte offset where scanning stopped; null when no single byte is at fault.
    error_offset: ?usize,

    /// Diagnoses raw input that failed `ToolArgumentIntegrity` classification.
    /// `scratch` backs only the scanner's nesting stack, released before return.
    pub fn diagnose(scratch: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!ToolArgumentDiagnostic {
        var scanner = std.json.Scanner.initCompleteInput(scratch, raw);
        defer scanner.deinit();
        var position: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&position);
        while (true) {
            const token = scanner.next() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // Complete input cannot underrun; treat it as the same missing tail.
                error.UnexpectedEndOfInput, error.BufferUnderrun => .{
                    .failure = .truncated,
                    .input_bytes = raw.len,
                    .error_offset = raw.len,
                },
                error.SyntaxError => .{
                    .failure = .syntax_error,
                    .input_bytes = raw.len,
                    .error_offset = @min(raw.len, std.math.cast(usize, position.getByteOffset()) orelse raw.len),
                },
            };
            if (token == .end_of_document) return .{
                .failure = .rejected_value,
                .input_bytes = raw.len,
                .error_offset = null,
            };
        }
    }
};

/// Identifies the server and catalog offered to one model step.
pub const McpToolBinding = struct {
    runtime_generation: u64,
    connection_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,
    authority_id: u64 = 0,
    definition_digest: [32]u8 = @splat(0),

    /// Transport renewal may change epochs without changing the advertised action.
    pub fn sameDefinition(self: McpToolBinding, other: McpToolBinding) bool {
        return self.runtime_generation == other.runtime_generation and
            self.authority_id == other.authority_id and
            std.mem.eql(u8, &self.definition_digest, &other.definition_digest);
    }
};

/// A `toolbox` open or search as the tool it replaced: `skill` with the
/// skill's name, `mcp_select_tool` with the MCP tool or server, or
/// `capability_search` with `*`.
pub const ToolboxLookup = struct {
    permission: []const u8,
    target: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    argument_integrity: ToolArgumentIntegrity = .valid,
    /// Set when spark rejected the raw arguments as `malformed_json`. Copies keep
    /// it; durable and provider encodings omit it.
    argument_diagnostic: ?ToolArgumentDiagnostic = null,
    provisional_id: ?[]const u8 = null,
    provider_result: ?[]const u8 = null,
    final_identity: FinalToolIdentity = .valid,
    provenance: ToolExecutionProvenance = .spark_local,
    /// What this action works on, resolved from earlier results, such as the
    /// command whose saved output a `read_tool_result` call reads. Borrowed
    /// only for this action. Copies and durable/provider encodings omit it.
    resolved_display_target: ?[]const u8 = null,
    /// The tool the model called when this is the call a `toolbox {run}`
    /// carries: spark prepares, admits, and runs this call, and its result goes
    /// back under that name. Borrowed only for this action. Copies and
    /// durable/provider encodings omit it.
    carried_by: ?[]const u8 = null,
    /// What this call stands for when it is a `toolbox` open or search, set
    /// before admission so the permission rules and a subagent's profile
    /// decide it as the tool it replaced. Borrowed only for this action.
    /// Copies and durable/provider encodings omit it.
    toolbox_lookup: ?ToolboxLookup = null,

    /// The name the model called, which this call's result goes back under.
    pub fn calledName(self: ToolCall) []const u8 {
        return self.carried_by orelse self.name;
    }
};

/// The prefix of every MCP tool name spark gives the model, which
/// `src/core/mcp/tool_names.zig` builds.
pub const mcp_tool_prefix = "mcp_";

/// Whether `name` has the shape of an MCP tool name spark gives the model.
pub fn isMcpToolName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, mcp_tool_prefix);
}

pub const WebSearchProgress = union(enum) {
    query_started: []const u8,
    results_received: struct {
        query: []const u8,
        result_count: usize,
    },
};

pub const WebSearchCompletion = struct {
    searches: u32,
    duration_ms: u64,
};

pub const WebFetchProgress = union(enum) {
    fetching: []const u8,
    converting: []const u8,
};

pub const WebFetchArtifactState = enum {
    none,
    stored,
    unavailable,
};

pub const WebFetchCompletion = struct {
    pub const max_url_len: usize = 192;

    url_buf: [max_url_len]u8 = @splat(0),
    url_len: u8 = 0,
    bytes: u64 = 0,
    status: u16 = 0,
    duration_ms: u64 = 0,
    cache_hit: bool = false,
    artifact_state: WebFetchArtifactState = .none,

    pub fn setUrl(self: *WebFetchCompletion, url_value: []const u8) void {
        const n = @min(url_value.len, max_url_len);
        if (n > 0) @memcpy(self.url_buf[0..n], url_value[0..n]);
        self.url_len = @intCast(n);
    }

    pub fn url(self: *const WebFetchCompletion) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

pub const SubagentStatus = struct {
    session_title: ?[]const u8 = null,
    model: []const u8,
    effort: ReasoningEffort,
    input_tokens: u64,
    context_window: ?u32,
};

pub const SubagentStatusRenderer = struct {
    ctx: *anyopaque,
    render_fn: *const fn (*anyopaque, buf: []u8, SubagentStatus) []const u8,

    pub fn render(self: SubagentStatusRenderer, buf: []u8, status: SubagentStatus) []const u8 {
        return self.render_fn(self.ctx, buf, status);
    }
};

pub const PersistedToolStatus = enum {
    success,
    failure,
};

pub const FileEvidenceAction = enum {
    read,
    write,
    edit,
    delete,
    rename,
    copy,
    search,
    list,
    unknown,
};

pub const CommittedFilePresentationKind = enum {
    added,
    edited,
};

pub const CommittedFilePresentationLineKind = enum {
    context,
    addition,
    deletion,
    elision,
    notice,
};

pub const CommittedFilePresentationLine = struct {
    kind: CommittedFilePresentationLineKind,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
};

pub const CommittedFilePresentation = struct {
    path: []const u8,
    kind: CommittedFilePresentationKind,
    lines: []const CommittedFilePresentationLine,
    additions: usize,
    deletions: usize,
    truncated: bool,
    previous_content: ?[]const u8 = null,
    after_content: ?[]const u8 = null,
    lifecycle_id: ?ToolLifecycleId = null,
    /// Content-addressed artifact handle holding the previous/after content
    /// pack in the session result store. When present, the durable record
    /// omits the inline contents and readers load them through the handle.
    /// In-memory live-turn presentations keep contents inline and leave this
    /// null; only the persistence projection sets it.
    content_handle: ?[]const u8 = null,
    /// The rows of the full diff, captured when the edit commits: changed
    /// lines, their bounded context, and elision rows whose text is already
    /// rendered. A presentation with rows carries no file snapshots, so it
    /// costs the size of the change rather than the size of the file. Records
    /// saved before rows existed carry snapshots or a handle instead.
    review_lines: ?[]const CommittedFilePresentationLine = null,

    /// Writes every field as `std.json` would, except `review_lines` when it
    /// is null, so a presentation without rows encodes as it did before they
    /// existed and older spark versions, which reject unknown fields, still read it.
    pub fn jsonStringify(self: CommittedFilePresentation, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(CommittedFilePresentation).@"struct".field_names) |field_name| {
            const optional = comptime std.mem.eql(u8, field_name, "review_lines");
            if (!optional or self.review_lines != null) {
                try writer.objectField(field_name);
                try writer.write(@field(self, field_name));
            }
        }
        try writer.endObject();
    }
};

/// Rejects competing or wrongly typed durable content authorities. A
/// preview-only presentation may have no review rows, inline snapshots, or
/// handle; otherwise exactly one of them supplies the full diff.
pub fn committedFilePresentationContentSourceValid(
    presentation: CommittedFilePresentation,
) bool {
    if (presentation.review_lines != null) {
        return presentation.previous_content == null and
            presentation.after_content == null and
            presentation.content_handle == null;
    }
    const handle = presentation.content_handle orelse return true;
    return presentation.previous_content == null and
        presentation.after_content == null and
        std.mem.startsWith(u8, handle, "diff-") and
        std.mem.endsWith(u8, handle, ".json");
}

pub const PersistedToolResult = struct {
    tool_images: []ToolImage = &.{},
    tool_image_handle: ?[]u8 = null,
    tool_call_id: []u8,
    tool_name: []u8,
    status: PersistedToolStatus,
    output: []u8,
    output_handle: ?[]u8 = null,
    preview: ?[]u8 = null,
    output_bytes: usize,
    stored_output_bytes: usize,
    truncated: bool = false,
    provider_native: bool = false,
    review_feedback: bool = false,
    created_at_ms: i64 = 0,
    permission_feedback: [][]u8 = &.{},
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
    terminal_action_presentation: ?TerminalActionPresentation = null,
};

pub const CommandOutputReplayDescriptor = struct {
    handle: []const u8,
    framed_bytes: usize,
};

pub const CommandOutputReplay = union(enum) {
    available: CommandOutputReplayDescriptor,
    unavailable,
};

pub const CancelledCommandPresentation = struct {
    output_replay: ?CommandOutputReplay = null,
    command_artifact_handle: ?[]const u8 = null,
};

pub const CommandProcessPresentation = union(enum) {
    exit_code: i64,
    signal: u32,
    timed_out,
    output_capture_failed,
};

pub const TerminalReturnPresentation = union(enum) {
    started,
    condition_met,
    safety_ceiling,
    cancelled,
    exited: i32,
    signal: u32,
};

pub const TerminalFailurePresentation = enum {
    invalid_request,
    path_outside_workspace,
    unsupported_host,
    shell_unavailable,
    pty_unavailable,
    startup_failed,
    process_identity_unavailable,
    session_lost,
    session_not_found,
    invalid_lifecycle,
    authority_denied,
    authority_retired,
    lease_conflict,
    cursor_gap,
    screen_unavailable,
    protocol_incompatible,
    capacity_exceeded,
    cancelled,

    pub fn detail(self: TerminalFailurePresentation) []const u8 {
        return switch (self) {
            .invalid_request => "invalid request",
            .path_outside_workspace => "path is outside the workspace",
            .unsupported_host => "terminal host is unavailable",
            .shell_unavailable => "terminal shell is unavailable",
            .pty_unavailable => "terminal PTY is unavailable",
            .startup_failed => "terminal startup failed",
            .process_identity_unavailable => "terminal process identity is unavailable",
            .session_lost => "terminal session was lost",
            .session_not_found => "terminal session not found",
            .invalid_lifecycle => "terminal session is in an invalid lifecycle state",
            .authority_denied => "terminal authority denied",
            .authority_retired => "saved terminal authority is from an older spark version; start a new terminal",
            .lease_conflict => "terminal control lease conflict",
            .cursor_gap => "terminal output cursor gap",
            .screen_unavailable => "terminal screen is unavailable",
            .protocol_incompatible => "terminal protocol is incompatible",
            .capacity_exceeded => "terminal capacity exceeded",
            .cancelled => "terminal action was cancelled",
        };
    }
};

pub const TerminalActionPresentation = union(enum) {
    returned: TerminalReturnPresentation,
    failed: TerminalFailurePresentation,

    pub fn outcomeKind(self: TerminalActionPresentation) ToolOutcomeKind {
        return switch (self) {
            .returned => |returned| switch (returned) {
                .started, .condition_met, .safety_ceiling => .completed,
                .cancelled => .cancelled,
                .exited => |code| if (code == 0) .completed else .failed,
                .signal => .failed,
            },
            .failed => |failed| if (failed == .cancelled)
                .cancelled
            else
                .failed,
        };
    }
};

pub const deferred_tool_result_output = "Not executed";
pub const context_deferred_tool_result_output = "Scoped project instructions were added before execution. Review them and reissue this tool call if it is still appropriate.";
pub const context_deferred_tool_status_label = "Reading project instructions before continuing:";

pub fn isContextDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        std.mem.eql(u8, result.output, context_deferred_tool_result_output);
}

pub fn isDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        (std.mem.eql(u8, result.output, deferred_tool_result_output) or
            std.mem.eql(u8, result.output, context_deferred_tool_result_output));
}

pub const ToolResultMemory = struct {
    /// Host review feedback is retained for the agent, not security evidence.
    review_feedback: bool = false,
    tool_images: []const ToolImage = &.{},
    tool_image_handle: ?[]const u8 = null,
    output_handle: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    output_bytes: usize = 0,
    stored_output_bytes: usize = 0,
    truncated: bool = false,
    model_view_covers_full_file: ?bool = null,
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
    terminal_action_presentation: ?TerminalActionPresentation = null,
    /// Set on a running shell result whose wait ended when its command
    /// crossed the quiet limit (`src/core/execution/quiet_notice.zig`), for
    /// the note spark relays to a subagent's parent. Only the tool's end event
    /// reads it; the session never saves it.
    quiet_crossing: ?QuietCrossing = null,
};

/// A shell command that crossed the quiet limit during a wait: its command
/// line and how long it had printed nothing. Each quiet spell crosses once
/// (`tests/tla/subagent/QuietRelay.tla`).
pub const QuietCrossing = struct {
    command: []const u8,
    quiet_ms: u64,
};

pub const ToolExecutionStep = struct {
    assistant: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    tool_results: []PersistedToolResult = &.{},
    provider_replay: ?ProviderReplay = null,
};

pub const PersistedSteering = struct {
    text: []u8,
    assistant_prefix: ?[]u8 = null,
    after_tool_step_count: usize,
};

/// An instruction file a context note delivered: its absolute path and a
/// stamp of the file's metadata when spark delivered it. A stamp is never 0; 0
/// means spark could not read it, so the stamp matches no file (D93).
pub const ContextNoteSource = struct {
    path: []const u8,
    stamp: u64,
};

/// A system note spark added to the turn after its latest message, saved at the
/// tool step boundary where the turn took it (D93). Owns `text`, `sources`,
/// and each source path, so a later turn can count an unchanged file as
/// delivered without reading the text.
pub const PersistedContextNote = struct {
    text: []u8,
    after_tool_step_count: usize,
    sources: []ContextNoteSource = &.{},
};

/// What a model call was for: the turn's own request, or a compaction the
/// turn ran. A record with a purpose this spark doesn't know is left out when
/// read, as one written by a newer spark can be.
pub const ModelCallPurpose = enum { turn, compaction };

/// How a model call ended.
pub const ModelCallOutcome = enum { completed, failed, cancelled };

/// One settled model call, shown in Ctrl+O where it happened and never sent
/// to the model. A turn's records sit at a tool step boundary, as context
/// notes do: the calls made for step `after_tool_step_count`, which a
/// replay places with that step: failed attempts before its text, the call
/// that wrote it after (`tests/tla/full_detail/FullDetailOrder.tla`
/// ReplayMatchesSaved). Strings come from the provider and are checked
/// before they are saved or shown (`validModelCallText`).
pub const ModelCallRecord = struct {
    /// When the call settled, in Unix milliseconds.
    at_ms: i64,
    elapsed_ms: u64 = 0,
    purpose: ModelCallPurpose = .turn,
    outcome: ModelCallOutcome = .completed,
    provider: []const u8,
    model: []const u8,
    served_by: ?[]const u8 = null,
    /// The gateway's generation id, or the provider's response id.
    generation_id: ?[]const u8 = null,
    /// The finish reason's name for a completed call.
    finish: ?[]const u8 = null,
    /// The failure kind's name for a failed call.
    failure: ?[]const u8 = null,
    retry_after_s: ?u32 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    after_tool_step_count: usize = 0,
    /// How many of the turn's steering messages came before the call at
    /// its boundary, so a message delivered after it, at the same boundary,
    /// is saved after it.
    after_steering_count: usize = 0,
};

pub const model_call_text_max_bytes = 256;

/// Whether `text` may be saved and shown in a call record: short, valid
/// UTF-8, and free of control characters, so provider text cannot move the
/// cursor or forge a line.
pub fn validModelCallText(text: []const u8) bool {
    if (text.len == 0 or text.len > model_call_text_max_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

/// Caller owns the copy; free it with `freeModelCallRecords`.
pub fn dupeModelCallRecords(alloc: std.mem.Allocator, records: []const ModelCallRecord) ![]ModelCallRecord {
    const copies = try alloc.alloc(ModelCallRecord, records.len);
    var done: usize = 0;
    errdefer {
        for (copies[0..done]) |copy| freeModelCallRecordStrings(alloc, copy);
        alloc.free(copies);
    }
    for (records, copies) |record, *copy| {
        copy.* = try dupeModelCallRecord(alloc, record);
        done += 1;
    }
    return copies;
}

/// Caller owns the copy's strings; free them with `freeModelCallRecordStrings`.
pub fn dupeModelCallRecord(alloc: std.mem.Allocator, record: ModelCallRecord) !ModelCallRecord {
    var copy = record;
    copy.provider = try alloc.dupe(u8, record.provider);
    errdefer alloc.free(copy.provider);
    copy.model = try alloc.dupe(u8, record.model);
    errdefer alloc.free(copy.model);
    copy.served_by = try dupeOptionalText(alloc, record.served_by);
    errdefer if (copy.served_by) |text| alloc.free(text);
    copy.generation_id = try dupeOptionalText(alloc, record.generation_id);
    errdefer if (copy.generation_id) |text| alloc.free(text);
    copy.finish = try dupeOptionalText(alloc, record.finish);
    errdefer if (copy.finish) |text| alloc.free(text);
    copy.failure = try dupeOptionalText(alloc, record.failure);
    return copy;
}

fn dupeOptionalText(alloc: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try alloc.dupe(u8, value) else null;
}

pub fn freeModelCallRecordStrings(alloc: std.mem.Allocator, record: ModelCallRecord) void {
    alloc.free(record.provider);
    alloc.free(record.model);
    inline for (.{ record.served_by, record.generation_id, record.finish, record.failure }) |text| {
        if (text) |value| alloc.free(value);
    }
}

pub fn freeModelCallRecords(alloc: std.mem.Allocator, records: []const ModelCallRecord) void {
    for (records) |record| freeModelCallRecordStrings(alloc, record);
    alloc.free(records);
}

/// How a call a command made through `spark mcp call` ended.
pub const BridgeCallOutcome = enum {
    completed,
    failed,
    cancelled,

    pub fn toolOutcome(self: BridgeCallOutcome) ToolOutcomeKind {
        return switch (self) {
            .completed => .completed,
            .failed => .failed,
            .cancelled => .cancelled,
        };
    }
};

/// A call a command made through `spark mcp call`, which the TUI showed as a
/// row in its shell call's group. The session keeps it so a resume shows
/// that row again: the tool's name and how the call ended, never its
/// arguments or its result. Display data, never sent to the model.
pub const BridgeCallRecord = struct {
    /// The shell call whose command made the call.
    call_id: []const u8,
    /// The bridge's id for the call.
    request_id: []const u8,
    tool: []const u8,
    outcome: BridgeCallOutcome,
};

/// Whether a record may be saved and shown: each string short, valid UTF-8
/// and free of control characters, as a model call record's are
/// (`validModelCallText`).
pub fn validBridgeCallRecord(record: BridgeCallRecord) bool {
    inline for (.{ record.call_id, record.request_id, record.tool }) |text| {
        if (!validModelCallText(text)) return false;
    }
    return true;
}

/// Caller owns the copy's strings; free them with `freeBridgeCallRecordStrings`.
pub fn dupeBridgeCallRecord(alloc: std.mem.Allocator, record: BridgeCallRecord) !BridgeCallRecord {
    const call_id = try alloc.dupe(u8, record.call_id);
    errdefer alloc.free(call_id);
    const request_id = try alloc.dupe(u8, record.request_id);
    errdefer alloc.free(request_id);
    return .{ .call_id = call_id, .request_id = request_id, .tool = try alloc.dupe(u8, record.tool), .outcome = record.outcome };
}

pub fn freeBridgeCallRecordStrings(alloc: std.mem.Allocator, record: BridgeCallRecord) void {
    alloc.free(record.call_id);
    alloc.free(record.request_id);
    alloc.free(record.tool);
}

/// Caller owns the copy; free it with `freeBridgeCallRecords`.
pub fn dupeBridgeCallRecords(alloc: std.mem.Allocator, records: []const BridgeCallRecord) ![]BridgeCallRecord {
    const copies = try alloc.alloc(BridgeCallRecord, records.len);
    var done: usize = 0;
    errdefer {
        for (copies[0..done]) |copy| freeBridgeCallRecordStrings(alloc, copy);
        alloc.free(copies);
    }
    for (records, copies) |record, *copy| {
        copy.* = try dupeBridgeCallRecord(alloc, record);
        done += 1;
    }
    return copies;
}

pub fn freeBridgeCallRecords(alloc: std.mem.Allocator, records: []const BridgeCallRecord) void {
    for (records) |record| freeBridgeCallRecordStrings(alloc, record);
    alloc.free(records);
}

pub const SteeringDelivery = enum(u8) { queued, applied, not_applied };

pub const FileEvidence = struct {
    path: []u8,
    new_path: ?[]u8 = null,
    tool_call_id: []u8,
    tool_name: []u8,
    action: FileEvidenceAction = .unknown,
    status: PersistedToolStatus = .success,
    model_view_covers_full_file: bool = false,
    stale: bool = false,
};

pub const ExecutionMemory = struct {
    tool_steps: []ToolExecutionStep = &.{},
    files: []FileEvidence = &.{},
    /// User guidance consumed between model steps, with its chronological tool boundary.
    steering: []PersistedSteering = &.{},
    /// Context notes the turn took, in order. At one boundary they come
    /// before that boundary's steering.
    context_notes: []PersistedContextNote = &.{},
    /// The runtime context, one system message text each, that this turn
    /// captured for the session and sent ahead of the history. Only the turn
    /// that captured it saves it; later turns send the newest saved copy
    /// unchanged (D94).
    runtime_context: ?[][]u8 = null,
    turn_summary: ?TurnSummary = null,
    /// The turn's settled model calls, in order, for Ctrl+O. Display data:
    /// never part of what the model is sent.
    model_calls: []ModelCallRecord = &.{},
    /// The calls the turn's commands made through `spark mcp call`, in the
    /// order they ended, each naming its shell call. Only a resumed turn
    /// holds them, for the rows its replay shows; display data, never part
    /// of what the model is sent.
    bridge_calls: []BridgeCallRecord = &.{},

    pub fn isEmpty(self: ExecutionMemory) bool {
        return self.tool_steps.len == 0 and self.files.len == 0 and self.steering.len == 0 and self.context_notes.len == 0;
    }
};

/// Image bytes returned by a tool; never a grant to read a user file.
pub const ToolImage = struct {
    /// Owned encoded bytes; empty only when a valid source_ref is present, or
    /// when the session dropped the image (`droppedFromSession`).
    data: []u8,
    mime_type: []u8,
    /// Owned opaque host reference, never filesystem or network authority.
    source_ref: ?[]u8 = null,
    /// The image's name in a libfx host's store, the lowercase hex SHA-256
    /// of its decoded bytes, when the host stored them before it sent the
    /// result. Writers that name stored images write this instead of `data`.
    name: ?[64]u8 = null,

    /// Whether the session no longer holds this image: a libfx session with
    /// an image store keeps only its newest images, and an older one keeps
    /// its name, without its bytes.
    pub fn droppedFromSession(self: ToolImage) bool {
        return self.data.len == 0 and self.name != null;
    }
};

pub fn freeToolImages(alloc: std.mem.Allocator, images: []const ToolImage) void {
    for (images) |image| {
        alloc.free(image.data);
        alloc.free(image.mime_type);
        if (image.source_ref) |source_ref| alloc.free(source_ref);
    }
    alloc.free(images);
}

pub fn dupeToolImages(alloc: std.mem.Allocator, images: []const ToolImage) ![]ToolImage {
    const copies = try alloc.alloc(ToolImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (copies[0..initialized]) |image| {
            alloc.free(image.data);
            alloc.free(image.mime_type);
            if (image.source_ref) |source_ref| alloc.free(source_ref);
        }
        alloc.free(copies);
    }
    for (images, 0..) |image, index| {
        const data = try alloc.dupe(u8, image.data);
        errdefer alloc.free(data);
        const mime_type = try alloc.dupe(u8, image.mime_type);
        errdefer alloc.free(mime_type);
        copies[index] = .{
            .data = data,
            .mime_type = mime_type,
            .source_ref = if (image.source_ref) |source_ref| try alloc.dupe(u8, source_ref) else null,
            .name = image.name,
        };
        initialized += 1;
    }
    return copies;
}

/// Deep-copies every slice-bearing field of a ToolResultMemory so the caller's
/// copy is independent of the source's backing allocations. Use when the
/// source memory is owned by a shorter-lived scope (for example a parallel
/// tool attempt whose run result is deinitialized after assembly).
pub fn dupeToolResultMemory(alloc: std.mem.Allocator, memory: ToolResultMemory) !ToolResultMemory {
    const tool_images = try dupeToolImages(alloc, memory.tool_images);
    errdefer freeToolImages(alloc, tool_images);
    const tool_image_handle = if (memory.tool_image_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (tool_image_handle) |handle| alloc.free(handle);
    const output_handle = if (memory.output_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    const committed_file_presentation = if (memory.committed_file_presentation) |presentation|
        try dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    const quiet_crossing: ?QuietCrossing = if (memory.quiet_crossing) |crossing|
        .{ .command = try alloc.dupe(u8, crossing.command), .quiet_ms = crossing.quiet_ms }
    else
        null;
    return .{
        .review_feedback = memory.review_feedback,
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
        .quiet_crossing = quiet_crossing,
    };
}

/// Frees the slice-bearing fields of a ToolResultMemory owned by the caller,
/// as produced by dupeToolResultMemory.
pub fn freeToolResultMemory(alloc: std.mem.Allocator, memory: ToolResultMemory) void {
    freeToolImages(alloc, memory.tool_images);
    if (memory.tool_image_handle) |handle| alloc.free(handle);
    if (memory.output_handle) |handle| alloc.free(handle);
    if (memory.preview) |value| alloc.free(value);
    if (memory.committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    if (memory.command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    if (memory.quiet_crossing) |crossing| alloc.free(crossing.command);
}

/// A cut in the active context, not a second persisted history.
pub const ContextHistoryCut = struct {
    turns: usize = 0,
    tool_steps: usize = 0,
    steering: usize = 0,
};

pub const ImageAttachment = struct {
    id: usize = 0,
    path: []u8,
    media_type: []u8,
    snapshot_path: ?[]u8 = null,
    snapshot_sha256: ?[]u8 = null,
    /// Owned decoded image bytes for sessions without a filesystem snapshot
    /// backend (libfx kernel sessions on native and wasm). When set, the
    /// attachment loads from memory instead of `snapshot_path`, and durable
    /// serializers embed the bytes so checkpoint/restore round-trips them.
    inline_data: ?[]u8 = null,
    /// Owned opaque host reference, never filesystem or network authority.
    source_ref: ?[]u8 = null,
    /// Owned path of the v2 session's blob that holds these bytes (D89),
    /// which the model's note names so its tools can open the image. An
    /// image saved as a blob keeps only this handle: readers load its bytes
    /// from the blob when they need them, checked against its digest. The
    /// session store owns the file: spark never writes or deletes through this
    /// path.
    blob_path: ?[]u8 = null,

    /// Whether the session no longer holds this image: a libfx session with
    /// an image store keeps only its newest images, and an older one keeps
    /// its digest, which names it in the host's store, without its bytes.
    pub fn droppedFromSession(self: ImageAttachment) bool {
        return self.inline_data == null and self.snapshot_path == null and self.blob_path == null and self.snapshot_sha256 != null;
    }
};

/// Who wrote a message an agent receives. A model frames each message by its
/// author, and only the user's words carry the user's authority.
pub const MessageAuthor = enum {
    /// The person at spark: typed on the agent's screen, or sent by an ACP client.
    user,
    /// The agent that started this one, as its subagent.
    parent,
    /// One of this agent's own subagents, reporting or messaging it. The
    /// sender frames the text, as `subagent/reports.zig` does.
    child,
};

pub const UserTurn = struct {
    text: []u8,
    images: []ImageAttachment = &.{},
    /// Durable join key for manager-owned child work. This is metadata only;
    /// model projections continue to use `text` and `images` exclusively.
    work_id: ?[]u8 = null,
    /// Who wrote the message that opened the turn. Only the user's counts as
    /// a request of the user's, for the reviewer and every later turn.
    author: MessageAuthor = .user,
    /// When the message was sent, in Unix milliseconds, as a saved session's
    /// line holding it says; 0 when unknown. For display only: nothing saves
    /// it, and the model never sees it.
    sent_at_ms: i64 = 0,
};

/// Borrows both strings; use dupeProviderReplay/freeProviderReplay for ownership.
pub const ProviderReplay = struct {
    pub const max_bytes: usize = 4 * 1024 * 1024;
    /// Joins distinct provider messages in assistant content. Replayed text
    /// spans exclude it, so each message returns to its provider unchanged.
    pub const message_separator = "\n\n";
    source: @import("../config/model_provider.zig").ProviderSelection,
    parts_json: []const u8,

    pub fn matches(self: ProviderReplay, source: @import("../config/model_provider.zig").ProviderSelection) bool {
        return self.source.provider.same_authority(source.provider) and std.mem.eql(u8, self.source.model, source.model);
    }
};

pub fn dupeProviderReplay(alloc: std.mem.Allocator, value: ProviderReplay) !ProviderReplay {
    const model = try alloc.dupe(u8, value.source.model);
    errdefer alloc.free(model);
    const parts = try alloc.dupe(u8, value.parts_json);
    return .{ .source = .{ .provider = value.source.provider, .model = model }, .parts_json = parts };
}

pub fn freeProviderReplay(alloc: std.mem.Allocator, value: ProviderReplay) void {
    alloc.free(value.source.model);
    alloc.free(value.parts_json);
}

pub const ChatMessage = struct {
    role: ChatRole,
    content: ?[]const u8 = null,
    images: []const ImageAttachment = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    provider_replay: ?ProviderReplay = null,
    tool_result_status: ?PersistedToolStatus = null,
    tool_result_memory: ?ToolResultMemory = null,
    /// When a tool result was made: when the turn took it, or the time its
    /// saved result recorded. Every rebuild of the turn's execution keeps it
    /// (`execution_memory.buildNormalChatExecutionMemory`), so a rebuilt turn
    /// encodes the same bytes each time. Null stamps the result when it is
    /// rebuilt (`tests/tla/session/TurnStream.tla` StampIsBirth).
    tool_result_created_at_ms: ?i64 = null,
    permission_feedback: bool = false,
    /// Checkpoint steering text has already had its envelope removed.
    restored_steering: bool = false,
    /// A message spark sent the model on its own, as plain user text: a prompt
    /// to a turn that stopped without a final answer, a tool's notice, or a
    /// Stop hook's message to continue. A save of the turn keeps it in the
    /// steering list inside a marker (`recovery_prompt.saved`), and a
    /// restored one comes back with this flag and the bare text.
    recovery_prompt: bool = false,
    /// A `.system` message spark added after the conversation started, which
    /// only the messages lane carries (D93). Plain text content only.
    context_note: bool = false,
    /// The instruction files a context note delivers. Borrowed; never sent
    /// to a provider.
    context_note_sources: []const ContextNoteSource = &.{},
    // Source provenance for compaction, never permission authority.
    context_origin: enum { ordinary, user_turn, handoff } = .ordinary,
    standalone_response: bool = false,
    /// Ends a stable run of system instructions that a provider may cache on
    /// its own. Set only by `appendStablePromptContext` in
    /// `src/core/agent/runtime/orchestrator.zig`. The Gateway request writer
    /// turns it into an explicit cache marker when the request asks for
    /// prompt caching and the model honors such markers, and ignores it
    /// otherwise.
    cache_breakpoint: bool = false,
};

/// Returns a caller-owned shallow projection only when incompatible replay exists.
pub fn projectProviderReplay(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    source: @import("../config/model_provider.zig").ProviderSelection,
) !?[]ChatMessage {
    var projected: ?[]ChatMessage = null;
    errdefer if (projected) |owned| alloc.free(owned);
    for (messages, 0..) |message, index| {
        const replay = message.provider_replay orelse continue;
        if (replay.matches(source)) continue;
        if (projected == null) projected = try alloc.dupe(ChatMessage, messages);
        projected.?[index].provider_replay = null;
    }
    return projected;
}

pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,

    /// Adds each count `other` reports, saturating at the maximum. A count
    /// neither side reports stays null.
    pub fn add(self: *Usage, other: Usage) void {
        inline for (@typeInfo(Usage).@"struct".field_names) |name| {
            if (@field(other, name)) |amount| {
                @field(self, name) = std.math.add(u64, @field(self, name) orelse 0, amount) catch std.math.maxInt(u64);
            }
        }
    }
};

/// Absolute per-turn token totals. Input covers only user-submitted prompt text
/// and stays estimated; output may become exact from provider usage.
pub const TurnTokenProgress = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    input_exact: bool = true,
    output_exact: bool = true,
};

pub const ToolUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    web_search_requests: u32 = 0,
};

pub const TurnSummary = struct {
    started_at_ms: i64 = 0,
    completed_at_ms: i64 = 0,
    thinking_duration_ms: u64 = 0,
    turn_duration_ms: u64 = 0,
    token_progress: TurnTokenProgress = .{},
};

pub const ProviderFinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    provider_error,
    other,

    pub fn parse_unified(raw: []const u8) ?ProviderFinishReason {
        if (std.mem.eql(u8, raw, "stop")) return .stop;
        if (std.mem.eql(u8, raw, "length")) return .length;
        if (std.mem.eql(u8, raw, "content-filter")) return .content_filter;
        if (std.mem.eql(u8, raw, "tool-calls")) return .tool_calls;
        if (std.mem.eql(u8, raw, "error")) return .provider_error;
        if (std.mem.eql(u8, raw, "other")) return .other;
        return null;
    }

    pub fn parse_legacy(raw: []const u8) ?ProviderFinishReason {
        if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
        return parse_unified(raw);
    }

    pub fn label(self: ProviderFinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .content_filter => "content-filter",
            .tool_calls => "tool-calls",
            .provider_error => "error",
            .other => "other",
        };
    }
};

/// The provider's own finish reason behind the unified one, such as Gemini's
/// `UNEXPECTED_TOOL_CALL` behind `other`. Kept inline so a completion owns no
/// more memory: a byte outside printable ASCII becomes `?`, and the copy stops
/// at `capacity` bytes. Empty when the provider sent none.
pub const ProviderFinishRaw = struct {
    pub const capacity = 48;

    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(raw: []const u8) ProviderFinishRaw {
        var result: ProviderFinishRaw = .{};
        const kept = raw[0..@min(raw.len, capacity)];
        for (kept, result.bytes[0..kept.len]) |byte, *out| {
            out.* = if (byte >= 0x21 and byte <= 0x7e) byte else '?';
        }
        result.len = @intCast(kept.len);
        return result;
    }

    pub fn slice(self: *const ProviderFinishRaw) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Gemini's stop reason for a function call it could not write, which the AI
/// SDK reports as the finish `error`.
pub const malformed_function_call_reason = "MALFORMED_FUNCTION_CALL";

/// Whether a reply ended because the provider could not read the model's tool
/// call. The reply's calls never ran, and the same request can fail the same
/// way, so spark gives the model feedback instead of a plain resend.
pub fn isMalformedToolCallFinish(
    finish_reason: ?ProviderFinishReason,
    finish_reason_raw: ProviderFinishRaw,
) bool {
    const reason = finish_reason orelse return false;
    return reason == .provider_error and
        std.mem.eql(u8, finish_reason_raw.slice(), malformed_function_call_reason);
}

fn fuzzProviderFinishRaw(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [256]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    const raw = ProviderFinishRaw.init(input);
    const kept = raw.slice();
    try std.testing.expectEqual(@min(input.len, ProviderFinishRaw.capacity), kept.len);
    for (kept, input[0..kept.len]) |byte, source| {
        try std.testing.expect(byte >= 0x21 and byte <= 0x7e);
        try std.testing.expectEqual(if (source >= 0x21 and source <= 0x7e) source else '?', byte);
    }
    // Only the exact reason marks a malformed tool call: a longer one cut to
    // the capacity, or one whose unprintable bytes became '?', does not.
    try std.testing.expectEqual(
        std.mem.eql(u8, input, malformed_function_call_reason),
        isMalformedToolCallFinish(.provider_error, raw),
    );
    try std.testing.expect(!isMalformedToolCallFinish(.other, raw));
}

pub const ProviderFailureCause = enum {
    gateway_stream_timeout,
    non_retryable,
    rate_limited,
    /// A provider error whose error event gave neither a code nor a usable
    /// HTTP status, so spark cannot tell whether a resend can succeed.
    uncoded_error,
    /// A stream that finished with an error that no error event explained.
    unexplained_error_finish,
};

pub const ProviderServiceTier = enum {
    standard,
    flex,
    priority,
    ultrafast,

    pub fn parse(raw: []const u8) ?ProviderServiceTier {
        if (std.mem.eql(u8, raw, "default") or std.mem.eql(u8, raw, "standard")) return .standard;
        if (std.mem.eql(u8, raw, "priority") or std.mem.eql(u8, raw, "fast")) return .priority;
        if (std.mem.eql(u8, raw, "flex")) return .flex;
        if (std.mem.eql(u8, raw, "ultrafast")) return .ultrafast;
        return null;
    }
};

pub const ModelCompletion = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    generation_id: ?[]const u8 = null,
    /// Owned gateway provider slug that actually served the request (the
    /// gateway's routing finalProvider/resolvedProvider). Null when the
    /// provider did not report routing metadata.
    resolved_provider: ?[]const u8 = null,
    /// Gateway-applied service tier. Null when the provider did not confirm it.
    service_tier: ?ProviderServiceTier = null,
    /// Gateway generation or resolved-model metadata was malformed or conflicting.
    generation_metadata_invalid: bool = false,
    /// An earlier delivery may have billed outside this generation identity.
    delivery_ambiguous: bool = false,
    provider_result_identity_failure: ?ProviderResultIdentityFailure = null,
    provider_failure_cause: ?ProviderFailureCause = null,
    provider_failure_detail: ?[]const u8 = null,
    /// Provider-owned opaque response items for the next stateless request in this turn.
    provider_state_json: ?[]const u8 = null,
    finish_reason: ?ProviderFinishReason = null,
    /// The provider's own reason for `finish_reason`, for notices and traces.
    finish_reason_raw: ProviderFinishRaw = .{},
    usage: Usage = .{},
};

pub fn validGatewayGenerationId(id: []const u8) bool {
    if (id.len != 30 or !std.mem.startsWith(u8, id, "gen_")) return false;
    for (id[4..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

/// Team identifiers reach the gateway as a query value, so reject anything that
/// would need percent-encoding rather than build a malformed URL. Accepts both
/// the `team_` id form and the slug form.
pub fn validGatewayTeam(team: []const u8) bool {
    if (team.len == 0 or team.len > 128) return false;
    for (team) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// The name spark shows for a Vercel team: the slug when it is a valid team
/// name, else the id when it is, else none. A saved login's slug is not
/// checked when it loads, so the refused-login notice, the status view's team
/// (`displayTeam` in `auth_runtime.zig`), and the usage label name a team
/// through here.
pub fn displayGatewayTeam(slug: ?[]const u8, id: ?[]const u8) ?[]const u8 {
    if (slug) |value| if (validGatewayTeam(value)) return value;
    if (id) |value| if (validGatewayTeam(value)) return value;
    return null;
}

fn fuzzDisplayGatewayTeam(_: void, smith: *std.testing.Smith) anyerror!void {
    var slug_buffer: [192]u8 = undefined;
    const slug_len: usize = @intCast(smith.slice(&slug_buffer));
    var id_buffer: [192]u8 = undefined;
    const id_len: usize = @intCast(smith.slice(&id_buffer));
    const slug = slug_buffer[0..slug_len];
    const id = id_buffer[0..id_len];
    const shown = displayGatewayTeam(slug, id) orelse {
        try std.testing.expect(!validGatewayTeam(slug) and !validGatewayTeam(id));
        return;
    };
    try std.testing.expect(validGatewayTeam(shown));
    try std.testing.expect(shown.ptr == slug.ptr or shown.ptr == id.ptr);
    for (shown) |byte| try std.testing.expect(byte >= 0x21 and byte <= 0x7e);
}

pub fn validCredentialAccountId(account_id: []const u8) bool {
    if (account_id.len == 0 or account_id.len > 1024) return false;
    for (account_id) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

pub const ProviderCompletionDisposition = enum {
    completed,
    length_limited,
    interrupted,
    provider_failure,
    invalid_completion,
};

pub fn allToolCallsProviderExecuted(tool_calls: []const ToolCall) bool {
    if (tool_calls.len == 0) return false;
    for (tool_calls) |call| {
        if (call.provenance != .provider_executed) return false;
    }
    return true;
}

pub fn classifyProviderCompletion(completion: ModelCompletion) ProviderCompletionDisposition {
    const finish_reason = completion.finish_reason orelse return .interrupted;
    return switch (finish_reason) {
        .provider_error, .content_filter => .provider_failure,
        .length => .length_limited,
        .tool_calls => if (completion.tool_calls.len > 0) .completed else .invalid_completion,
        .stop => if (completion.tool_calls.len == 0 or allToolCallsProviderExecuted(completion.tool_calls)) .completed else .invalid_completion,
        .other => if (completion.tool_calls.len == 0) .completed else .invalid_completion,
    };
}

pub const ConversationIdentity = struct {
    pub const max_bytes: usize = 256;
    pub const Failure = enum { empty, too_long, invalid_utf8 };

    pub fn invalidReason(value: []const u8) ?Failure {
        if (value.len == 0) return .empty;
        if (value.len > max_bytes) return .too_long;
        if (!std.unicode.utf8ValidateSlice(value)) return .invalid_utf8;
        return null;
    }
};

pub const AuthoritativeToolAdmission = union(enum) {
    admitted,
    reject_malformed_identity: FinalToolIdentity,
    reject_unstorable_identity: struct {
        field: enum { id, name, provisional_id },
        reason: ConversationIdentity.Failure,
    },
    reject_malformed_provider_result: ProviderResultIdentityFailure,
    reject_malformed_provider_arguments,
    reject_duplicate_identity,
};

pub fn authoritativeToolAdmission(completion: ModelCompletion) AuthoritativeToolAdmission {
    if (completion.provider_result_identity_failure) |failure| {
        return .{ .reject_malformed_provider_result = failure };
    }

    for (completion.tool_calls) |call| {
        const final_identity = if (call.final_identity == .valid and std.mem.trim(u8, call.id, " \t\r\n").len == 0)
            FinalToolIdentity.empty
        else
            call.final_identity;
        if (final_identity != .valid) {
            return if (call.provenance == .provider_executed)
                .{ .reject_malformed_provider_result = switch (final_identity) {
                    .absent => .absent,
                    .empty => .empty,
                    .wrong_type => .wrong_type,
                    .valid => unreachable,
                } }
            else
                .{ .reject_malformed_identity = final_identity };
        }
    }

    for (completion.tool_calls, 0..) |call, i| {
        for (completion.tool_calls[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, call.id)) return .reject_duplicate_identity;
        }
    }

    for (completion.tool_calls) |call| {
        if (ConversationIdentity.invalidReason(call.id)) |reason| {
            return .{ .reject_unstorable_identity = .{ .field = .id, .reason = reason } };
        }
        if (ConversationIdentity.invalidReason(call.name)) |reason| {
            return .{ .reject_unstorable_identity = .{ .field = .name, .reason = reason } };
        }
        if (call.provisional_id) |id| {
            if (ConversationIdentity.invalidReason(id)) |reason| {
                return .{ .reject_unstorable_identity = .{ .field = .provisional_id, .reason = reason } };
            }
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and
            call.argument_integrity == .malformed_json)
        {
            return .reject_malformed_provider_arguments;
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and call.provider_result == null) {
            return .{ .reject_malformed_provider_result = .missing_result };
        }
    }

    return .admitted;
}

pub const ConversationLanguage = struct {
    pub const max_len: usize = 24;

    bytes: [max_len]u8 = @splat(0),
    len: u8 = 0,

    pub fn default() ConversationLanguage {
        return literal("und");
    }

    pub fn literal(comptime tag: []const u8) ConversationLanguage {
        if (tag.len == 0 or tag.len > max_len) @compileError("invalid conversation language literal");

        var value: ConversationLanguage = .{};
        value.len = @intCast(tag.len);
        @memcpy(value.bytes[0..tag.len], tag);
        return value;
    }

    pub fn fromSlice(tag: []const u8) !ConversationLanguage {
        const trimmed = std.mem.trim(u8, tag, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_len) return error.InvalidConversationLanguage;

        var value: ConversationLanguage = .{};
        value.len = @intCast(trimmed.len);
        @memcpy(value.bytes[0..trimmed.len], trimmed);
        return value;
    }

    pub fn view(self: *const ConversationLanguage) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const AssistantHistoryTurn = struct {
    user: UserTurn,
    assistant: []u8,
    execution: ExecutionMemory = .{},
    provider_replay: ?ProviderReplay = null,
};

/// What a turn write does with the recovery module's record for the model
/// request in flight (`src/core/recovery/recovery.zig` `Record`): leave it,
/// save these bytes, or clear it because the request's response is complete.
/// A model request a previous spark process left unfinished, which a turn
/// resumes: the record its turn saved last, if any, and whether it was
/// interrupted more than a day ago.
pub const RecoveryResume = struct {
    record: ?[32]u8 = null,
    stale: bool = false,
};

pub const RecoveryRecordWrite = union(enum) {
    keep,
    save: [32]u8,
    clear,
};

pub const InterruptedTerminalReason = enum {
    cancelled,
    failed,
};

pub const CancellationOrigin = enum {
    turn,
    compaction,
};

pub const InterruptedHistoryTurn = struct {
    user: UserTurn,
    assistant: ?[]u8 = null,
    tool_call: ?ToolCall = null,
    completed_tool_names: [][]u8 = &.{},
    execution: ExecutionMemory = .{},
    cancelled_command: ?CancelledCommandPresentation = null,
    terminal_reason: InterruptedTerminalReason = .cancelled,
    cancellation_origin: CancellationOrigin = .turn,
    /// spark stopped before the turn ended, by a crash or a closed window,
    /// rather than the turn failing or being cancelled. Only a session's
    /// replay sets it, and nothing saves it.
    stopped_by_exit: bool = false,
};

pub const CompactedSummaryHistoryTurn = struct {
    summary: []u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// Legacy compacted root text retained for storage compatibility. It is
    /// model context only and never permission authority.
    root_user_messages: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    root_user_messages_complete: bool = true,
    /// Legacy compacted feedback retained for storage compatibility. It is not
    /// permission authority.
    permission_feedback: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    permission_feedback_complete: bool = true,
};

pub const HistoryTurn = union(enum) {
    compacted_summary: CompactedSummaryHistoryTurn,
    assistant: AssistantHistoryTurn,
    interrupted: InterruptedHistoryTurn,
};

pub fn setHistoryTurnSummary(turn: *HistoryTurn, summary: TurnSummary) void {
    switch (turn.*) {
        .assistant => |*entry| entry.execution.turn_summary = summary,
        .interrupted => |*entry| entry.execution.turn_summary = summary,
        .compacted_summary => {},
    }
}

pub fn historyTurnSummary(turn: HistoryTurn) ?TurnSummary {
    return switch (turn) {
        .assistant => |entry| entry.execution.turn_summary,
        .interrupted => |entry| entry.execution.turn_summary,
        .compacted_summary => null,
    };
}

pub const FinishedPromptProjection = enum {
    history_default,
    assistant_text,
};

pub const SnapshotFileOwnership = struct {
    /// Shared lifetime for snapshot files after worker completion. Copies must
    /// retain/release; accepted history transfers deletion responsibility.
    ctx: *anyopaque,
    retain_fn: *const fn (*anyopaque) void,
    release_fn: *const fn (*anyopaque) void,
    transfer_fn: *const fn (*anyopaque) void,

    pub fn retain(self: SnapshotFileOwnership) void {
        self.retain_fn(self.ctx);
    }

    pub fn release(self: SnapshotFileOwnership) void {
        self.release_fn(self.ctx);
    }

    pub fn transfer(self: SnapshotFileOwnership) void {
        self.transfer_fn(self.ctx);
    }
};

pub const FinishedPrompt = struct {
    turn: HistoryTurn,
    /// Owned display-only text; never serialized as conversation history.
    presentation_text: ?[]const u8 = null,
    summary: ?TurnSummary = null,
    terminal_projection: FinishedPromptProjection = .history_default,
    terminal_outcome: ?TurnPresentationOutcome = null,
    snapshot_file_ownership: ?SnapshotFileOwnership = null,
    /// The workspace capture token of this turn (D98), set by the app as
    /// the turn's end capture is taken, so the commit writes only this
    /// turn's captures however late it runs; 0 when it has none.
    capture_turn: u64 = 0,
};

/// spark always runs with full access. The retired `ask` and `auto` still
/// parse so older settings and flags keep loading.
pub const PermissionMode = enum {
    yolo,

    pub fn parse(raw: []const u8) ?PermissionMode {
        if (std.ascii.eqlIgnoreCase(raw, "full-access") or
            std.ascii.eqlIgnoreCase(raw, "full access") or
            std.ascii.eqlIgnoreCase(raw, "yolo") or
            std.ascii.eqlIgnoreCase(raw, "ask") or
            std.ascii.eqlIgnoreCase(raw, "auto")) return .yolo;
        return null;
    }

    pub fn label(self: PermissionMode) []const u8 {
        _ = self;
        return "full-access";
    }
};

pub const ContentHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const ToolChoice = enum {
    auto,
    none,
    required,

    pub fn label(self: ToolChoice) []const u8 {
        return @tagName(self);
    }

    pub fn parse(raw: []const u8) ?ToolChoice {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        return null;
    }
};

pub const ReasoningEffort = union(enum) {
    auto,
    named: Name,

    pub const max_name_bytes = 64;
    pub const max_options = 16;

    pub const Name = struct {
        bytes: [max_name_bytes]u8,
        len: u8,

        fn parse(raw: []const u8) ?Name {
            if (raw.len == 0 or raw.len > max_name_bytes) return null;
            for (raw) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return null;
            }

            var name = Name{
                .bytes = @as([max_name_bytes]u8, @splat(0)),
                .len = @intCast(raw.len),
            };
            @memcpy(name.bytes[0..raw.len], raw);
            return name;
        }

        fn literal(comptime raw: []const u8) Name {
            const parsed = comptime Name.parse(raw);
            if (parsed) |name| return name;
            @compileError("invalid reasoning effort literal: " ++ raw);
        }

        fn view(self: *const Name) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn literal(comptime raw: []const u8) ReasoningEffort {
        return .{ .named = Name.literal(raw) };
    }

    pub fn label(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "auto",
            .named => |*name| name.view(),
        };
    }

    pub fn displayLabel(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "default",
            .named => self.label(),
        };
    }

    pub fn gatewayValue(self: *const ReasoningEffort) ?[]const u8 {
        return switch (self.*) {
            .auto => null,
            .named => self.label(),
        };
    }

    pub fn parse(raw: []const u8) ?ReasoningEffort {
        if (std.ascii.eqlIgnoreCase(raw, "auto") or
            std.ascii.eqlIgnoreCase(raw, "adaptive") or
            std.ascii.eqlIgnoreCase(raw, "default")) return .auto;
        return .{ .named = Name.parse(raw) orelse return null };
    }

    pub fn parseDisplayLabel(raw: []const u8) ?ReasoningEffort {
        return parse(raw);
    }

    pub fn eql(a: ReasoningEffort, b: ReasoningEffort) bool {
        return switch (a) {
            .auto => b == .auto,
            .named => |a_name| switch (b) {
                .auto => false,
                .named => |b_name| std.mem.eql(u8, a_name.view(), b_name.view()),
            },
        };
    }

    pub fn isDefault(self: ReasoningEffort) bool {
        return self == .auto;
    }
};

pub const ToolPermissionDenialReason = enum {
    user_denied,
    policy_denied,
    permission_required,
};

pub const ToolPermissionDecision = enum {
    once,
    always,
    deny,
    policy_denied,
    permission_required,

    pub fn isDenied(self: ToolPermissionDecision) bool {
        return switch (self) {
            .deny, .policy_denied, .permission_required => true,
            .once, .always => false,
        };
    }

    pub fn denialReason(self: ToolPermissionDecision) ?ToolPermissionDenialReason {
        return switch (self) {
            .deny => .user_denied,
            .policy_denied => .policy_denied,
            .permission_required => .permission_required,
            .once, .always => null,
        };
    }
};

pub const ToolActivityKind = enum {
    read,
    list,
    write,
    edit,
    open,
    command,
    subagent,
    ask,
    /// A call to an MCP server's tool.
    mcp,
};

pub const QuestionOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const QuestionBatchEntry = struct {
    question: []const u8,
    /// The question and the option descriptions are Markdown and may have
    /// several lines, as `ask_user_question` sends them. Other prompts show
    /// their text as written.
    markdown: bool = false,
    options: []const QuestionOption,
    /// Submission prompts return JSON {"value": string} or {"option": index},
    /// keeping typed text distinct from action labels such as Decline.
    submission: enum { none, input, choice } = .none,
};

/// One persisted answer from an interactive question batch. The strings are
/// borrowed from the short-lived arena that decodes the completed tool result.
pub const QuestionAnswer = struct {
    question: []const u8,
    answer: []const u8,
};

pub const ResolveMode = enum {
    existing,
    create,
};

pub fn freeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) void {
    switch (turn) {
        .compacted_summary => |entry| {
            alloc.free(entry.summary);
            freeCompletedToolNames(alloc, entry.root_user_messages);
            freePermissionFeedback(alloc, entry.permission_feedback);
        },
        .assistant => |entry| {
            freeUserTurn(alloc, entry.user);
            alloc.free(entry.assistant);
            if (entry.provider_replay) |replay| freeProviderReplay(alloc, replay);
            freeExecutionMemory(alloc, entry.execution);
        },
        .interrupted => |entry| {
            freeUserTurn(alloc, entry.user);
            if (entry.assistant) |assistant| alloc.free(assistant);
            if (entry.tool_call) |tool_call| freeToolCall(alloc, tool_call);
            freeCompletedToolNames(alloc, entry.completed_tool_names);
            freeExecutionMemory(alloc, entry.execution);
            if (entry.cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            }
        },
    }
}

pub fn freeHistoryTurnSlice(alloc: std.mem.Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| {
        freeHistoryTurn(alloc, turn);
    }
    alloc.free(turns);
}

pub fn freeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) void {
    freeHistoryTurn(alloc, finished.turn);
    if (finished.presentation_text) |text| alloc.free(text);
    if (finished.snapshot_file_ownership) |ownership| ownership.release();
}

pub fn dupeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) !HistoryTurn {
    return switch (turn) {
        .compacted_summary => |entry| blk: {
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const root_user_messages = try dupeCompletedToolNames(
                alloc,
                entry.root_user_messages,
            );
            errdefer freeCompletedToolNames(alloc, root_user_messages);
            const permission_feedback = try dupePermissionFeedback(
                alloc,
                entry.permission_feedback,
            );
            break :blk .{ .compacted_summary = .{
                .summary = summary,
                .removed_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
                .root_user_messages = root_user_messages,
                .root_user_messages_complete = entry.root_user_messages_complete,
                .permission_feedback = permission_feedback,
                .permission_feedback_complete = entry.permission_feedback_complete,
            } };
        },
        .assistant => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = try alloc.dupe(u8, entry.assistant);
            errdefer alloc.free(assistant);

            const execution = try dupeExecutionMemory(alloc, entry.execution);
            errdefer freeExecutionMemory(alloc, execution);
            const replay = if (entry.provider_replay) |value| try dupeProviderReplay(alloc, value) else null;
            break :blk .{ .assistant = .{
                .user = user,
                .assistant = assistant,
                .execution = execution,
                .provider_replay = replay,
            } };
        },
        .interrupted => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);

            const tool_call = if (entry.tool_call) |call| try dupeToolCall(alloc, call) else null;
            errdefer if (tool_call) |call| freeToolCall(alloc, call);

            const completed_tool_names = try dupeCompletedToolNames(alloc, entry.completed_tool_names);
            errdefer freeCompletedToolNames(alloc, completed_tool_names);

            const cancelled_command = if (entry.cancelled_command) |presentation|
                try dupeCancelledCommandPresentation(alloc, presentation)
            else
                null;
            errdefer if (cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            };

            const execution = try dupeExecutionMemory(alloc, entry.execution);

            break :blk .{ .interrupted = .{
                .user = user,
                .assistant = assistant,
                .tool_call = tool_call,
                .completed_tool_names = completed_tool_names,
                .execution = execution,
                .cancelled_command = cancelled_command,
                .terminal_reason = entry.terminal_reason,
                .cancellation_origin = entry.cancellation_origin,
                .stopped_by_exit = entry.stopped_by_exit,
            } };
        },
    };
}

pub fn dupeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) !CancelledCommandPresentation {
    const output_replay = if (presentation.output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    return .{
        .output_replay = output_replay,
        .command_artifact_handle = if (presentation.command_artifact_handle) |handle|
            try alloc.dupe(u8, handle)
        else
            null,
    };
}

pub fn freeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) void {
    if (presentation.output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    if (presentation.command_artifact_handle) |handle| alloc.free(@constCast(handle));
}

pub fn dupeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) !FinishedPrompt {
    const turn = try dupeHistoryTurn(alloc, finished.turn);
    errdefer freeHistoryTurn(alloc, turn);
    const presentation_text = if (finished.presentation_text) |text| try alloc.dupe(u8, text) else null;
    if (finished.snapshot_file_ownership) |ownership| ownership.retain();
    return .{
        .turn = turn,
        .presentation_text = presentation_text,
        .summary = finished.summary,
        .terminal_projection = finished.terminal_projection,
        .terminal_outcome = finished.terminal_outcome,
        .snapshot_file_ownership = finished.snapshot_file_ownership,
        .capture_turn = finished.capture_turn,
    };
}

pub fn dupeCompletedToolNames(alloc: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, items.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i]);
        }
    }

    for (items, 0..) |item, i| {
        copy[i] = try alloc.dupe(u8, item);
        copied += 1;
    }
    return copy;
}

pub fn freeCompletedToolNames(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

pub fn dupeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) !ExecutionMemory {
    const tool_steps = try dupeToolExecutionSteps(alloc, memory.tool_steps);
    errdefer freeToolExecutionSteps(alloc, tool_steps);
    const files = try dupeFileEvidenceSlice(alloc, memory.files);
    errdefer freeFileEvidenceSlice(alloc, files);
    const steering = try dupePersistedSteering(alloc, memory.steering);
    errdefer freePersistedSteering(alloc, steering);
    const context_notes = try dupePersistedContextNotes(alloc, memory.context_notes);
    errdefer freePersistedContextNotes(alloc, context_notes);
    const runtime_context = if (memory.runtime_context) |texts| try dupeRuntimeContext(alloc, texts) else null;
    errdefer if (runtime_context) |texts| freeRuntimeContext(alloc, texts);
    const model_calls = try dupeModelCallRecords(alloc, memory.model_calls);
    errdefer freeModelCallRecords(alloc, model_calls);
    const bridge_calls = try dupeBridgeCallRecords(alloc, memory.bridge_calls);
    return .{
        .tool_steps = tool_steps,
        .files = files,
        .steering = steering,
        .context_notes = context_notes,
        .runtime_context = runtime_context,
        .turn_summary = memory.turn_summary,
        .model_calls = model_calls,
        .bridge_calls = bridge_calls,
    };
}

pub fn freeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) void {
    freeBridgeCallRecords(alloc, memory.bridge_calls);
    freeModelCallRecords(alloc, memory.model_calls);
    freeToolExecutionSteps(alloc, memory.tool_steps);
    freeFileEvidenceSlice(alloc, memory.files);
    freePersistedSteering(alloc, memory.steering);
    freePersistedContextNotes(alloc, memory.context_notes);
    if (memory.runtime_context) |texts| freeRuntimeContext(alloc, texts);
}

/// Caller owns the result; free it with `freeRuntimeContext`.
pub fn dupeRuntimeContext(alloc: std.mem.Allocator, texts: []const []const u8) ![][]u8 {
    const copies = try alloc.alloc([]u8, texts.len);
    var initialized: usize = 0;
    errdefer {
        for (copies[0..initialized]) |text| alloc.free(text);
        alloc.free(copies);
    }
    for (texts, copies) |text, *copy| {
        copy.* = try alloc.dupe(u8, text);
        initialized += 1;
    }
    return copies;
}

pub fn freeRuntimeContext(alloc: std.mem.Allocator, texts: []const []u8) void {
    for (texts) |text| alloc.free(text);
    alloc.free(texts);
}

/// Caller owns the result; free it with `freePersistedContextNotes`.
fn dupePersistedContextNotes(
    alloc: std.mem.Allocator,
    notes: []const PersistedContextNote,
) ![]PersistedContextNote {
    if (notes.len == 0) return &.{};
    const copy = try alloc.alloc(PersistedContextNote, notes.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |item| freePersistedContextNote(alloc, item);
    for (notes, copy) |item, *dest| {
        const text = try alloc.dupe(u8, item.text);
        errdefer alloc.free(text);
        dest.* = .{
            .text = text,
            .after_tool_step_count = item.after_tool_step_count,
            .sources = try dupeNoteSources(alloc, item.sources),
        };
        copied += 1;
    }
    return copy;
}

/// Caller owns the result; free it with `freeNoteSources`.
pub fn dupeNoteSources(alloc: std.mem.Allocator, sources: []const ContextNoteSource) ![]ContextNoteSource {
    if (sources.len == 0) return &.{};
    const copy = try alloc.alloc(ContextNoteSource, sources.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |source| alloc.free(source.path);
    for (sources, copy) |source, *dest| {
        dest.* = .{ .path = try alloc.dupe(u8, source.path), .stamp = source.stamp };
        copied += 1;
    }
    return copy;
}

pub fn freeNoteSources(alloc: std.mem.Allocator, sources: []const ContextNoteSource) void {
    for (sources) |source| alloc.free(source.path);
    if (sources.len > 0) alloc.free(sources);
}

pub fn freePersistedContextNotes(alloc: std.mem.Allocator, notes: []PersistedContextNote) void {
    for (notes) |item| freePersistedContextNote(alloc, item);
    if (notes.len > 0) alloc.free(notes);
}

pub fn freePersistedContextNote(alloc: std.mem.Allocator, note: PersistedContextNote) void {
    alloc.free(note.text);
    freeNoteSources(alloc, note.sources);
}

pub fn dupePersistedSteering(
    alloc: std.mem.Allocator,
    steering: []const PersistedSteering,
) ![]PersistedSteering {
    if (steering.len == 0) return &.{};
    const copy = try alloc.alloc(PersistedSteering, steering.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    };
    for (steering, copy) |item, *dest| {
        const text = try alloc.dupe(u8, item.text);
        errdefer alloc.free(text);
        const assistant_prefix = if (item.assistant_prefix) |prefix|
            try alloc.dupe(u8, prefix)
        else
            null;
        errdefer if (assistant_prefix) |prefix| alloc.free(prefix);
        dest.* = .{
            .text = text,
            .assistant_prefix = assistant_prefix,
            .after_tool_step_count = item.after_tool_step_count,
        };
        copied += 1;
    }
    return copy;
}

pub fn freePersistedSteering(alloc: std.mem.Allocator, steering: []PersistedSteering) void {
    for (steering) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    }
    if (steering.len > 0) alloc.free(steering);
}

pub fn dupeToolExecutionSteps(alloc: std.mem.Allocator, steps: []const ToolExecutionStep) ![]ToolExecutionStep {
    if (steps.len == 0) return &.{};

    const copy = try alloc.alloc(ToolExecutionStep, steps.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolExecutionStep(alloc, copy[i]);
    }

    for (steps, 0..) |step, i| {
        copy[i] = try dupeToolExecutionStep(alloc, step);
        copied += 1;
    }
    return copy;
}

pub fn freeToolExecutionSteps(alloc: std.mem.Allocator, steps: []ToolExecutionStep) void {
    for (steps) |step| freeToolExecutionStep(alloc, step);
    if (steps.len > 0) alloc.free(steps);
}

fn dupeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) !ToolExecutionStep {
    const assistant = if (step.assistant) |text| try alloc.dupe(u8, text) else null;
    errdefer if (assistant) |text| alloc.free(text);
    const tool_calls = try dupeToolCallSlice(alloc, step.tool_calls);
    errdefer freeToolCallSlice(alloc, tool_calls);
    const tool_results = try dupePersistedToolResults(alloc, step.tool_results);
    errdefer freePersistedToolResults(alloc, tool_results);
    const replay = if (step.provider_replay) |value| try dupeProviderReplay(alloc, value) else null;

    return .{
        .assistant = assistant,
        .provider_replay = replay,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
    };
}

fn freeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    if (step.provider_replay) |replay| freeProviderReplay(alloc, replay);
    freeToolCallSlice(alloc, step.tool_calls);
    freePersistedToolResults(alloc, step.tool_results);
}

pub fn dupeToolCallSlice(alloc: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    if (calls.len == 0) return &.{};

    const copy = try alloc.alloc(ToolCall, calls.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolCall(alloc, copy[i]);
    }

    for (calls, 0..) |call, i| {
        copy[i] = try dupeToolCall(alloc, call);
        copied += 1;
    }
    return copy;
}

pub fn freeToolCallSlice(alloc: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| freeToolCall(alloc, call);
    if (calls.len > 0) alloc.free(calls);
}

pub fn dupePersistedToolResults(alloc: std.mem.Allocator, results: []const PersistedToolResult) ![]PersistedToolResult {
    if (results.len == 0) return &.{};

    const copy = try alloc.alloc(PersistedToolResult, results.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freePersistedToolResult(alloc, copy[i]);
    }

    for (results, 0..) |result, i| {
        copy[i] = try dupePersistedToolResult(alloc, result);
        copied += 1;
    }
    return copy;
}

pub fn freePersistedToolResults(alloc: std.mem.Allocator, results: []PersistedToolResult) void {
    for (results) |result| freePersistedToolResult(alloc, result);
    if (results.len > 0) alloc.free(results);
}

/// Copies `lines` and every line's text. Caller owns the result; release it
/// with `freeCommittedFilePresentationLines`.
pub fn dupeCommittedFilePresentationLines(
    alloc: std.mem.Allocator,
    lines: []const CommittedFilePresentationLine,
) ![]CommittedFilePresentationLine {
    const copy = try alloc.alloc(CommittedFilePresentationLine, lines.len);
    errdefer alloc.free(copy);
    var copied_lines: usize = 0;
    errdefer {
        for (copy[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (lines, 0..) |line, index| {
        copy[index] = .{
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    return copy;
}

pub fn freeCommittedFilePresentationLines(
    alloc: std.mem.Allocator,
    lines: []const CommittedFilePresentationLine,
) void {
    for (lines) |line| alloc.free(@constCast(line.text));
    if (lines.len > 0) alloc.free(@constCast(lines));
}

pub fn dupeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) !CommittedFilePresentation {
    const path = try alloc.dupe(u8, presentation.path);
    errdefer alloc.free(path);
    const lines = try dupeCommittedFilePresentationLines(alloc, presentation.lines);
    errdefer freeCommittedFilePresentationLines(alloc, lines);
    const previous_content = if (presentation.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (presentation.after_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?ToolLifecycleId = if (presentation.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try alloc.dupe(u8, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    const content_handle = if (presentation.content_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (content_handle) |handle| alloc.free(handle);
    const review_lines = if (presentation.review_lines) |rows|
        try dupeCommittedFilePresentationLines(alloc, rows)
    else
        null;
    return .{
        .path = path,
        .kind = presentation.kind,
        .lines = lines,
        .additions = presentation.additions,
        .deletions = presentation.deletions,
        .truncated = presentation.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
        .content_handle = content_handle,
        .review_lines = review_lines,
    };
}

pub fn freeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) void {
    alloc.free(@constCast(presentation.path));
    freeCommittedFilePresentationLines(alloc, presentation.lines);
    if (presentation.previous_content) |content| alloc.free(@constCast(content));
    if (presentation.after_content) |content| alloc.free(@constCast(content));
    if (presentation.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    if (presentation.content_handle) |handle| alloc.free(@constCast(handle));
    if (presentation.review_lines) |rows| freeCommittedFilePresentationLines(alloc, rows);
}

fn dupePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) !PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, result.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, result.tool_name);
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, result.output);
    errdefer alloc.free(output);
    const output_handle = if (result.output_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (result.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| alloc.free(text);
    const permission_feedback = try dupePermissionFeedback(alloc, result.permission_feedback);
    errdefer freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (result.committed_file_presentation) |presentation|
        try dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    const command_output_replay = if (result.command_output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    const tool_image_handle = if (result.tool_image_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (tool_image_handle) |handle| alloc.free(handle);
    const tool_images = try dupeToolImages(alloc, result.tool_images);
    return .{
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = result.status,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = result.output_bytes,
        .stored_output_bytes = result.stored_output_bytes,
        .truncated = result.truncated,
        .provider_native = result.provider_native,
        .review_feedback = result.review_feedback,
        .created_at_ms = result.created_at_ms,
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = result.command_process_presentation,
        .terminal_action_presentation = result.terminal_action_presentation,
    };
}

pub fn freePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    freeToolImages(alloc, result.tool_images);
    if (result.tool_image_handle) |handle| alloc.free(handle);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
}

pub fn dupeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) !CommandOutputReplay {
    return switch (replay) {
        .available => |descriptor| .{ .available = .{
            .handle = try alloc.dupe(u8, descriptor.handle),
            .framed_bytes = descriptor.framed_bytes,
        } },
        .unavailable => .unavailable,
    };
}

pub fn freeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) void {
    switch (replay) {
        .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
        .unavailable => {},
    }
}

pub fn dupePermissionFeedback(
    alloc: std.mem.Allocator,
    feedback: []const []const u8,
) ![][]u8 {
    if (feedback.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, feedback.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |text| alloc.free(text);
    }
    for (feedback, 0..) |text, i| {
        copy[i] = try alloc.dupe(u8, text);
        copied += 1;
    }
    return copy;
}

pub fn freePermissionFeedback(alloc: std.mem.Allocator, feedback: [][]u8) void {
    for (feedback) |text| alloc.free(text);
    if (feedback.len > 0) alloc.free(feedback);
}

pub fn dupeFileEvidenceSlice(alloc: std.mem.Allocator, files: []const FileEvidence) ![]FileEvidence {
    if (files.len == 0) return &.{};

    const copy = try alloc.alloc(FileEvidence, files.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeFileEvidence(alloc, copy[i]);
    }

    for (files, 0..) |file, i| {
        copy[i] = try dupeFileEvidence(alloc, file);
        copied += 1;
    }
    return copy;
}

pub fn freeFileEvidenceSlice(alloc: std.mem.Allocator, files: []FileEvidence) void {
    for (files) |file| freeFileEvidence(alloc, file);
    if (files.len > 0) alloc.free(files);
}

fn dupeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) !FileEvidence {
    const path = try alloc.dupe(u8, file.path);
    errdefer alloc.free(path);
    const new_path = if (file.new_path) |value| try alloc.dupe(u8, value) else null;
    errdefer if (new_path) |value| alloc.free(value);
    const tool_call_id = try alloc.dupe(u8, file.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, file.tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = file.action,
        .status = file.status,
        .model_view_covers_full_file = file.model_view_covers_full_file,
        .stale = file.stale,
    };
}

/// Frees one entry's owned strings, not its containing slice.
pub fn freeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

pub fn dupeToolCall(alloc: std.mem.Allocator, call: ToolCall) !ToolCall {
    const id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, call.arguments_json);
    errdefer alloc.free(arguments_json);
    const provisional_id = if (call.provisional_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (provisional_id) |value| alloc.free(value);
    const provider_result = if (call.provider_result) |result| try alloc.dupe(u8, result) else null;
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = call.argument_integrity,
        .argument_diagnostic = call.argument_diagnostic,
        .provisional_id = provisional_id,
        .provider_result = provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

pub fn freeToolCall(alloc: std.mem.Allocator, call: ToolCall) void {
    alloc.free(call.id);
    alloc.free(call.name);
    alloc.free(call.arguments_json);
    if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
    if (call.provider_result) |provider_result| alloc.free(provider_result);
}

fn fuzzToolArgumentDiagnostic(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    if (try ToolArgumentIntegrity.classifyFunctionInput(std.testing.allocator, input) != .malformed_json) return;
    const diagnostic = try ToolArgumentDiagnostic.diagnose(std.testing.allocator, input);
    try std.testing.expectEqual(input.len, diagnostic.input_bytes);
    if (diagnostic.error_offset) |offset| try std.testing.expect(offset <= input.len);
    try std.testing.expectEqual(diagnostic.failure == .rejected_value, diagnostic.error_offset == null);
}

pub fn freeUserTurn(alloc: std.mem.Allocator, user: UserTurn) void {
    alloc.free(user.text);
    freeImageAttachmentSlice(alloc, user.images);
    if (user.work_id) |work_id| alloc.free(work_id);
}

pub fn dupeUserTurn(alloc: std.mem.Allocator, user: UserTurn) !UserTurn {
    const text = try alloc.dupe(u8, user.text);
    errdefer alloc.free(text);

    const images = try dupeImageAttachmentSlice(alloc, user.images);
    errdefer freeImageAttachmentSlice(alloc, images);

    const work_id = if (user.work_id) |value| try alloc.dupe(u8, value) else null;

    return .{
        .text = text,
        .images = images,
        .work_id = work_id,
        .author = user.author,
        .sent_at_ms = user.sent_at_ms,
    };
}

pub fn dupeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []const ImageAttachment) ![]ImageAttachment {
    if (attachments.len == 0) return &.{};

    const copy = try alloc.alloc(ImageAttachment, attachments.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            freeImageAttachment(alloc, copy[i]);
        }
    }

    for (attachments, 0..) |attachment, i| {
        copy[i] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    return copy;
}

/// A copy of `attachment` that owns every field it has; free it with
/// `freeImageAttachment`.
pub fn dupeImageAttachment(alloc: std.mem.Allocator, attachment: ImageAttachment) !ImageAttachment {
    const path = try alloc.dupe(u8, attachment.path);
    errdefer alloc.free(path);

    const media_type = try alloc.dupe(u8, attachment.media_type);
    errdefer alloc.free(media_type);

    const snapshot_path = if (attachment.snapshot_path) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (snapshot_path) |value| alloc.free(value);

    const snapshot_sha256 = if (attachment.snapshot_sha256) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (snapshot_sha256) |value| alloc.free(value);

    const inline_data = if (attachment.inline_data) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (inline_data) |value| alloc.free(value);
    const source_ref = if (attachment.source_ref) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (source_ref) |value| alloc.free(value);
    const blob_path = if (attachment.blob_path) |value|
        try alloc.dupe(u8, value)
    else
        null;
    return .{
        .id = attachment.id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = snapshot_sha256,
        .inline_data = inline_data,
        .source_ref = source_ref,
        .blob_path = blob_path,
    };
}

/// Frees the owned fields in one attachment; caller owns any containing storage.
pub fn freeImageAttachment(alloc: std.mem.Allocator, attachment: ImageAttachment) void {
    alloc.free(attachment.path);
    alloc.free(attachment.media_type);
    if (attachment.snapshot_path) |path| alloc.free(path);
    if (attachment.snapshot_sha256) |sha256| alloc.free(sha256);
    if (attachment.inline_data) |data| alloc.free(data);
    if (attachment.source_ref) |source_ref| alloc.free(source_ref);
    if (attachment.blob_path) |path| alloc.free(path);
}

pub fn freeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []ImageAttachment) void {
    if (attachments.len == 0) return;
    for (attachments) |attachment| freeImageAttachment(alloc, attachment);
    alloc.free(attachments);
}

fn dupeThenFreeContextNotes(alloc: std.mem.Allocator, notes: []const PersistedContextNote) !void {
    freePersistedContextNotes(alloc, try dupePersistedContextNotes(alloc, notes));
}
