//! Multi round-trip requests (2026): reading an `input_required` result,
//! checking its input requests against the client's capabilities, and
//! writing a retry's `inputResponses` and `requestState`. Keys and the state
//! stay raw JSON tokens, copied exactly as the server wrote them, so the
//! retry answers exactly the keys it was asked and echoes the state byte for
//! byte. Pure.

const std = @import("std");
const wire = @import("wire.zig");

/// Input requests in one round.
pub const max_requests = 16;

pub const Kind = enum { elicitation, sampling, roots };

pub const Request = struct {
    /// The key as the server wrote it: a JSON string token.
    key: []const u8,
    kind: Kind,
    /// The request object, `method` and `params`.
    raw: []const u8,
    params: ?[]const u8,
};

pub const Round = struct {
    requests: [max_requests]Request = undefined,
    count: u8 = 0,
    /// The requestState as the server wrote it: a JSON string token.
    state: ?[]const u8 = null,

    pub fn slice(r: *const Round) []const Request {
        return r.requests[0..r.count];
    }
};

/// Reads an `input_required` result (the raw `result` object) into `round`;
/// its slices point into `result`. Malformed: neither field, a
/// requestState that isn't a string, inputRequests that isn't an object, a
/// request whose method isn't elicitation, sampling, or roots, a key written
/// twice, or more than `max_requests`.
pub fn parse(result: []const u8, round: *Round) error{Malformed}!void {
    round.* = .{};
    var found: [2]?[]const u8 = undefined;
    wire.objectFields(result, &.{ "inputRequests", "requestState" }, &found) catch return error.Malformed;
    if (found[1]) |state| {
        if (state[0] != '"') return error.Malformed;
        round.state = state;
    }
    if (found[0]) |requests| {
        var fields: wire.Fields = undefined;
        fields.init(requests) catch return error.Malformed;
        while (fields.next() catch return error.Malformed) |field| {
            if (round.count == max_requests) return error.Malformed;
            for (round.slice()) |other| if (wire.sameString(other.key, field.key)) return error.Malformed;
            var parts: [2]?[]const u8 = undefined;
            wire.objectFields(field.value, &.{ "method", "params" }, &parts) catch return error.Malformed;
            const method = wire.plainString(parts[0] orelse return error.Malformed) orelse return error.Malformed;
            const kind: Kind = if (std.mem.eql(u8, method, "elicitation/create"))
                .elicitation
            else if (std.mem.eql(u8, method, "sampling/createMessage"))
                .sampling
            else if (std.mem.eql(u8, method, "roots/list"))
                .roots
            else
                return error.Malformed;
            round.requests[round.count] = .{ .key = field.key, .kind = kind, .raw = field.value, .params = parts[1] };
            round.count += 1;
        }
    }
    if (round.count == 0 and round.state == null) return error.Malformed;
}

/// Whether `capabilities` (the client's, a JSON object) declares what
/// `request` needs. URL-mode elicitation needs `elicitation.url`; form mode,
/// the default, needs `elicitation.form`, or an `elicitation` with neither,
/// which means form.
pub fn supported(capabilities: []const u8, request: Request) bool {
    var caps: [3]?[]const u8 = undefined;
    wire.objectFields(capabilities, &.{ "elicitation", "sampling", "roots" }, &caps) catch return false;
    switch (request.kind) {
        .sampling => return caps[1] != null,
        .roots => return caps[2] != null,
        .elicitation => {
            const elicitation = caps[0] orelse return false;
            var mode: [1]?[]const u8 = undefined;
            wire.objectFields(request.params orelse "{}", &.{"mode"}, &mode) catch return false;
            const url = if (mode[0]) |m| std.mem.eql(u8, m, "\"url\"") else false;
            var sub: [2]?[]const u8 = undefined;
            wire.objectFields(elicitation, &.{ "form", "url" }, &sub) catch return false;
            return if (url) sub[1] != null else sub[0] != null or sub[1] == null;
        },
    }
}

/// Whether the client declared what every request in `round` needs.
pub fn allSupported(capabilities: []const u8, round: *const Round) bool {
    for (round.slice()) |r| if (!supported(capabilities, r)) return false;
    return true;
}

/// A retry's additions: one answer per input request, raw JSON in the order
/// of `requests`, and the requestState to echo, if any.
pub const Retry = struct {
    requests: []const Request = &.{},
    values: []const []const u8 = &.{},
    state: ?[]const u8 = null,
};

/// Writes `inputResponses`, under each request's own key token, and
/// `requestState`, each only when there is one.
pub fn writeRetry(w: *wire.Writer, retry: Retry) wire.EncodeError!void {
    std.debug.assert(retry.requests.len == retry.values.len);
    if (retry.requests.len > 0) {
        try w.field("inputResponses");
        try w.json.beginObject();
        for (retry.requests, retry.values) |r, value| {
            try w.json.objectFieldRaw(r.key);
            try w.raw(value);
        }
        try w.json.endObject();
    }
    if (retry.state) |state| {
        try w.field("requestState");
        try w.raw(state);
    }
}

const testing = std.testing;

test "reads input requests and the requestState exactly as written" {
    var round: Round = .{};
    const result =
        \\{"resultType":"input_required","inputRequests":{"gh\u00e9":{"method":"elicitation/create","params":{"message":"m"}},
        \\"roots":{"method":"roots/list"}},"requestState":"a\"b\\c"}
    ;
    try parse(result, &round);
    try testing.expectEqual(@as(u8, 2), round.count);
    try testing.expectEqualStrings("\"gh\\u00e9\"", round.requests[0].key);
    try testing.expectEqual(Kind.elicitation, round.requests[0].kind);
    try testing.expectEqual(Kind.roots, round.requests[1].kind);
    try testing.expectEqual(@as(?[]const u8, null), round.requests[1].params);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", round.state.?);
}
