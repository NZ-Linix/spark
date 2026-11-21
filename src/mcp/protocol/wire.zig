//! Wire format: MCP's JSON-RPC 2.0 messages.
//!
//! Decoding scans one message once with `std.json.Scanner` and returns slices
//! of the input: no allocation, no copies, no tree. Encoding streams through
//! `std.json.Stringify` into the caller's writer. spark already links both, so
//! this file adds only its own logic to the spark binary.
//!
//! Encoded messages never contain a CR or LF byte, so each is one stdio line.

const std = @import("std");

/// Ids the client allocates: integers from 1, never reused.
pub const RequestId = u64;

/// The largest id the client sends: 2^53 - 1, so servers that read JSON
/// numbers as doubles (JavaScript) see every id exactly.
pub const max_request_id: RequestId = (1 << 53) - 1;

/// Error codes the client handles or sends.
pub const code = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    pub const header_mismatch: i64 = -32020;
    pub const missing_required_client_capability: i64 = -32021;
    pub const unsupported_protocol_version: i64 = -32022;
    /// Resource not found from 2025-era servers; still accepted.
    pub const legacy_resource_not_found: i64 = -32002;
};

pub const Message = union(enum) {
    response: Response,
    notification: Notification,
    /// 2025 only: a request from the server, such as ping or elicitation/create.
    request: ServerRequest,
};

pub const Response = struct {
    /// The id when it is one the client could have issued: an integer, or a
    /// string of plain decimal digits (some servers echo ids as strings). Null
    /// when the id is null, absent, or anything else, so the response can't
    /// be matched to a request.
    id: ?RequestId,
    body: union(enum) {
        result: Result,
        failure: Failure,
    },
};

pub const ResultKind = enum { complete, input_required, unrecognized };

pub const Result = struct {
    /// The whole result object.
    raw: []const u8,
    /// A missing `resultType` means complete; an unknown one is unrecognized,
    /// which the caller treats as invalid.
    kind: ResultKind,
};

pub const Failure = struct {
    code: i64,
    /// The message as a JSON string literal, with its quotes and escapes.
    message: []const u8,
    /// Raw JSON, when present.
    data: ?[]const u8,
};

pub const Notification = struct {
    method: []const u8,
    params: ?[]const u8,
};

pub const ServerRequest = struct {
    /// The raw id, echoed unchanged in the answer.
    id: []const u8,
    method: []const u8,
    params: ?[]const u8,
};

pub const DecodeError = error{
    InvalidJson,
    TooDeep,
    NotAnObject,
    NotAnArray,
    NotJsonRpc2,
    DuplicateField,
    /// The fields don't describe exactly one kind of message.
    Ambiguous,
    InvalidId,
    /// Not a string, or written with escapes.
    InvalidMethod,
    InvalidParams,
    InvalidResult,
    InvalidErrorObject,
};

/// Scanner nesting stack. 512 bytes allow about 2,000 levels of nesting;
/// deeper input is `TooDeep`.
const scan_stack_bytes = 512;

const envelope_fields = [_][]const u8{ "jsonrpc", "id", "method", "params", "result", "error" };

/// Decodes one complete message. Returned slices point into `input`.
pub fn decode(input: []const u8) DecodeError!Message {
    var found: [envelope_fields.len]?[]const u8 = undefined;
    try objectFields(input, &envelope_fields, &found);
    const version, const id, const method, const params, const result, const failure = found;

    const is_2_0 = if (version) |v| std.mem.eql(u8, v, "\"2.0\"") else false;
    if (!is_2_0) return error.NotJsonRpc2;
    if (params) |p| if (p[0] != '{') return error.InvalidParams;

    if (method) |m| {
        if (result != null or failure != null) return error.Ambiguous;
        const name = plainString(m) orelse return error.InvalidMethod;
        const raw_id = id orelse return .{ .notification = .{ .method = name, .params = params } };
        if (!isRequestId(raw_id)) return error.InvalidId;
        return .{ .request = .{ .id = raw_id, .method = name, .params = params } };
    }

    if (params != null or (result == null) == (failure == null)) return error.Ambiguous;
    const response_id = try ownId(id);
    if (result) |r| {
        if (r[0] != '{') return error.InvalidResult;
        return .{ .response = .{ .id = response_id, .body = .{ .result = .{ .raw = r, .kind = try resultKind(r) } } } };
    }
    return .{ .response = .{ .id = response_id, .body = .{ .failure = try failureOf(failure.?) } } };
}

/// The id of a line `decode` refused that is shaped like a response: an
/// object with no `method` and an id the client could have issued. The
/// request it names fails with it.
pub fn responseId(input: []const u8) ?RequestId {
    var found: [envelope_fields.len]?[]const u8 = undefined;
    objectFields(input, &envelope_fields, &found) catch return null;
    if (found[2] != null) return null;
    return ownId(found[1]) catch null;
}

/// Finds the fields listed in `names` in the JSON object `object` and stores
/// each raw value, a slice of `object`, at the same index in `out`. A key is
/// the name it spells once decoded, as `std.json` reads it: `"is\u0045rror"`
/// is `isError`. Other fields are skipped. A wanted field that appears twice,
/// however each is spelled, is an error, so a message can't say two things at
/// once.
pub fn objectFields(object: []const u8, names: []const []const u8, out: []?[]const u8) DecodeError!void {
    std.debug.assert(names.len == out.len);
    @memset(out, null);
    var stack: [scan_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), object);
    defer scanner.deinit();

    if ((try nextToken(&scanner)) != .object_begin) return error.NotAnObject;
    while (true) {
        const before = scanner.cursor;
        var token = try nextToken(&scanner);
        if (token == .object_end) break;
        // A key with escapes arrives in pieces; the last piece is a string.
        var escaped = false;
        const key = while (true) : (token = try nextToken(&scanner)) switch (token) {
            .string => |piece| break piece,
            else => escaped = true,
        };
        // The key as written, quotes included: the first quote after the last value and the comma.
        const key_token = if (escaped) object[std.mem.findScalarPos(u8, object, before, '"') orelse return error.InvalidJson .. scanner.cursor] else key;
        _ = scanner.peekNextTokenType() catch return error.InvalidJson;
        const start = scanner.cursor;
        try skip(&scanner);
        for (names, out) |name, *slot| {
            if (if (escaped) !spells(key_token, name) else !std.mem.eql(u8, key, name)) continue;
            if (slot.* != null) return error.DuplicateField;
            slot.* = object[start..scanner.cursor];
        }
    }
    if ((try nextToken(&scanner)) != .end_of_document) return error.InvalidJson;
}

/// Walks the elements of a JSON array, each as a raw slice of the input.
/// Holds its own scanner stack, so it must stay in place between `init` and
/// the last `next`.
pub const Elements = struct {
    array: []const u8,
    stack: [scan_stack_bytes]u8,
    fba: std.heap.FixedBufferAllocator,
    scanner: std.json.Scanner,

    pub fn init(e: *Elements, array: []const u8) DecodeError!void {
        e.array = array;
        e.fba = .init(&e.stack);
        e.scanner = .initCompleteInput(e.fba.allocator(), array);
        if ((try nextToken(&e.scanner)) != .array_begin) return error.NotAnArray;
    }

    /// The next element, or null after the last one once the whole input
    /// has been checked.
    pub fn next(e: *Elements) DecodeError!?[]const u8 {
        if ((e.scanner.peekNextTokenType() catch return error.InvalidJson) == .array_end) {
            _ = try nextToken(&e.scanner);
            if ((try nextToken(&e.scanner)) != .end_of_document) return error.InvalidJson;
            return null;
        }
        const start = e.scanner.cursor;
        try skip(&e.scanner);
        return e.array[start..e.scanner.cursor];
    }
};

/// Walks the fields of a JSON object: each key as its raw token, quotes and
/// escapes included, and its raw value, both slices of the input. Holds its
/// own scanner stack, so it must stay in place between `init` and the last
/// `next`.
pub const Fields = struct {
    object: []const u8,
    stack: [scan_stack_bytes]u8,
    fba: std.heap.FixedBufferAllocator,
    scanner: std.json.Scanner,

    pub const Field = struct { key: []const u8, value: []const u8 };

    pub fn init(f: *Fields, object: []const u8) DecodeError!void {
        f.object = object;
        f.fba = .init(&f.stack);
        f.scanner = .initCompleteInput(f.fba.allocator(), object);
        if ((try nextToken(&f.scanner)) != .object_begin) return error.NotAnObject;
    }

    /// The next field, or null after the last one once the whole input has
    /// been checked.
    pub fn next(f: *Fields) DecodeError!?Field {
        const before = f.scanner.cursor;
        var token = try nextToken(&f.scanner);
        if (token == .object_end) {
            if ((try nextToken(&f.scanner)) != .end_of_document) return error.InvalidJson;
            return null;
        }
        // A key with escapes arrives in pieces; the last piece is a string.
        while (token != .string) token = try nextToken(&f.scanner);
        const key_end = f.scanner.cursor;
        const quote = std.mem.findScalarPos(u8, f.object, before, '"') orelse return error.InvalidJson;
        _ = f.scanner.peekNextTokenType() catch return error.InvalidJson;
        const start = f.scanner.cursor;
        try skip(&f.scanner);
        return .{ .key = f.object[quote..key_end], .value = f.object[start..f.scanner.cursor] };
    }
};

/// Whether the JSON array `array` holds the string `needle`. A string written
/// with escapes never matches, and other elements are skipped.
pub fn arrayHasString(array: []const u8, needle: []const u8) DecodeError!bool {
    var elements: Elements = undefined;
    try elements.init(array);
    var found = false;
    while (try elements.next()) |value| {
        if (value.len == needle.len + 2 and value[0] == '"' and std.mem.eql(u8, value[1 .. value.len - 1], needle)) found = true;
    }
    return found;
}

/// Whether two JSON string tokens, quotes included, spell the same string
/// once decoded: `"caf\u00e9"` and `"café"`, `"a\/b"` and `"a/b"`, and a
/// surrogate pair and the character in UTF-8 are one string each. This is
/// JSON's equality, which is `std.json`'s. It decodes both tokens as it goes
/// and allocates nothing. A token that is not a string, or holds an escape or
/// UTF-8 that is not valid, matches only a token with the same bytes. Tokens
/// that reach here have been through the scanner, which refuses invalid ones.
pub fn sameString(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (!isStringToken(a) or !isStringToken(b)) return false;
    var x: Decoder = .{ .raw = a[1 .. a.len - 1] };
    var y: Decoder = .{ .raw = b[1 .. b.len - 1] };
    return sameDecoded(&x, &y);
}

/// How many code points the string token `token`, quotes included, holds once
/// decoded: an escape is one, and a surrogate pair written as two escapes is
/// one. Null for a token that is not a string, or that holds an escape or
/// UTF-8 that is not valid. It uses the decoder of `sameString`.
pub fn codePointCount(token: []const u8) ?usize {
    if (!isStringToken(token)) return null;
    var d: Decoder = .{ .raw = token[1 .. token.len - 1] };
    var count: usize = 0;
    while (d.next() catch return null) |_| count += 1;
    return count;
}

/// Whether the string token `token`, quotes included, spells `name`, which is
/// already decoded.
fn spells(token: []const u8, name: []const u8) bool {
    if (!isStringToken(token)) return false;
    var x: Decoder = .{ .raw = token[1 .. token.len - 1] };
    var y: Decoder = .{ .raw = name, .literal = true };
    return sameDecoded(&x, &y);
}

fn isStringToken(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"';
}

fn sameDecoded(x: *Decoder, y: *Decoder) bool {
    while (true) {
        const p = x.next() catch return false;
        const q = y.next() catch return false;
        if (p == null or q == null) return p == null and q == null;
        if (p.? != q.?) return false;
    }
}

/// The code points of the inside of a JSON string token, one at a time. With
/// `literal` set the bytes are a decoded string, and no byte is an escape.
const Decoder = struct {
    raw: []const u8,
    at: usize = 0,
    literal: bool = false,

    const Invalid = error{Invalid};

    /// The next code point, or null at the end. A surrogate pair written as
    /// two escapes is one code point, and a lone surrogate is invalid.
    fn next(d: *Decoder) Invalid!?u21 {
        if (d.at >= d.raw.len) return null;
        const c = d.raw[d.at];
        if (c != '\\' or d.literal) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch return error.Invalid;
            if (d.at + n > d.raw.len) return error.Invalid;
            const bytes = d.raw[d.at..][0..n];
            // Each decoder refuses an overlong form; the three-byte one also refuses an encoded surrogate half.
            const code_point: u21 = switch (n) {
                1 => c,
                2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return error.Invalid,
                3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return error.Invalid,
                4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return error.Invalid,
                else => return error.Invalid,
            };
            d.at += n;
            return code_point;
        }
        if (d.at + 1 >= d.raw.len) return error.Invalid;
        const escape = d.raw[d.at + 1];
        d.at += 2;
        switch (escape) {
            '"' => return '"',
            '\\' => return '\\',
            '/' => return '/',
            'b' => return 0x08,
            'f' => return 0x0c,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'u' => {},
            else => return error.Invalid,
        }
        const unit = try d.hex4();
        if (unit >= 0xdc00 and unit <= 0xdfff) return error.Invalid;
        if (unit < 0xd800 or unit > 0xdbff) return unit;
        // A high surrogate needs a low one, written as the next escape.
        if (d.at + 1 >= d.raw.len or d.raw[d.at] != '\\' or d.raw[d.at + 1] != 'u') return error.Invalid;
        d.at += 2;
        const low = try d.hex4();
        if (low < 0xdc00 or low > 0xdfff) return error.Invalid;
        return 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
    }

    /// Four hex digits, in either case, and nothing else: no sign.
    fn hex4(d: *Decoder) Invalid!u16 {
        if (d.at + 4 > d.raw.len) return error.Invalid;
        var unit: u16 = 0;
        for (d.raw[d.at..][0..4]) |digit| unit = unit * 16 + (std.fmt.charToDigit(digit, 16) catch return error.Invalid);
        d.at += 4;
        return unit;
    }
};

fn nextToken(scanner: *std.json.Scanner) DecodeError!std.json.Token {
    return scanner.next() catch |err| switch (err) {
        error.OutOfMemory => error.TooDeep,
        else => error.InvalidJson,
    };
}

fn skip(scanner: *std.json.Scanner) DecodeError!void {
    scanner.skipValue() catch |err| return switch (err) {
        error.OutOfMemory => error.TooDeep,
        else => error.InvalidJson,
    };
}

/// The contents of a raw JSON string written without escapes, or null for
/// anything else.
pub fn plainString(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    const contents = raw[1 .. raw.len - 1];
    if (std.mem.findScalar(u8, contents, '\\') != null) return null;
    return contents;
}

/// A JSON string token's contents, unescaped: the token's own bytes when it has
/// no escapes, else a copy in `a`. Null when `raw` isn't a string.
pub fn decodeString(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (plainString(raw)) |s| return s;
    if (raw.len < 2 or raw[0] != '"') return null;
    var scanner: std.json.Scanner = .initCompleteInput(a, raw);
    defer scanner.deinit();
    const token = scanner.nextAlloc(a, .alloc_always) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (token) {
        .allocated_string => |s| s,
        else => null,
    };
}

/// JSON-RPC ids are strings or integers, never null.
fn isRequestId(raw: []const u8) bool {
    if (raw[0] == '"') return true;
    if (raw[0] != '-' and !std.ascii.isDigit(raw[0])) return false;
    return std.mem.findAny(u8, raw, ".eE") == null;
}

fn ownId(raw: ?[]const u8) DecodeError!?RequestId {
    const value = raw orelse return null;
    return switch (value[0]) {
        '"' => decimal(value[1 .. value.len - 1]),
        '0'...'9' => decimal(value),
        '-', 'n' => null,
        else => error.InvalidId,
    };
}

/// Plain decimal digits without a leading zero, as the client writes its ids.
/// A raw JSON integer that is non-negative and fits in 64 bits, or null.
pub fn decimal(digits: []const u8) ?RequestId {
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    var value: RequestId = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = std.math.mul(RequestId, value, 10) catch return null;
        value = std.math.add(RequestId, value, c - '0') catch return null;
    }
    return value;
}

fn resultKind(result: []const u8) DecodeError!ResultKind {
    var found: [1]?[]const u8 = undefined;
    try objectFields(result, &.{"resultType"}, &found);
    const value = found[0] orelse return .complete;
    if (std.mem.eql(u8, value, "\"complete\"")) return .complete;
    if (std.mem.eql(u8, value, "\"input_required\"")) return .input_required;
    return .unrecognized;
}

fn failureOf(raw: []const u8) DecodeError!Failure {
    var found: [3]?[]const u8 = undefined;
    objectFields(raw, &.{ "code", "message", "data" }, &found) catch |err| return switch (err) {
        error.NotAnObject => error.InvalidErrorObject,
        else => err,
    };
    const code_raw = found[0] orelse return error.InvalidErrorObject;
    const message = found[1] orelse return error.InvalidErrorObject;
    if (message[0] != '"') return error.InvalidErrorObject;
    // Error codes are integers; the scanner has already checked the syntax.
    const value = std.fmt.parseInt(i64, code_raw, 10) catch return error.InvalidErrorObject;
    return .{ .code = value, .message = message, .data = found[2] };
}

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

/// Per-request `_meta`.
pub const Meta = struct {
    /// 2026-07-28 fields, required together on every request. Null on 2025 requests.
    modern: ?Modern = null,
    /// Opts the request into progress notifications. The client uses the request id.
    progress_token: ?RequestId = null,

    pub const Modern = struct {
        protocol_version: []const u8,
        /// A JSON object; `{}` declares no capabilities.
        client_capabilities: []const u8,
        client_info: ?Implementation = null,
    };
};

pub const EncodeError = std.Io.Writer.Error || error{InvalidRawJson};

/// Streams one message. Start it with `request`, `notification`, or
/// `result`, add fields with `field` followed by `string`, `int`, or `raw`,
/// and close it with `end`. Does not write the newline or flush.
pub const Writer = struct {
    json: std.json.Stringify,

    /// `id` is at most `max_request_id`.
    pub fn request(out: *std.Io.Writer, id: RequestId, method: []const u8, meta: Meta) EncodeError!Writer {
        var w = try envelope(out);
        try w.json.objectField("id");
        try w.int(@intCast(id));
        try w.openParams(method, meta);
        return w;
    }

    /// A notification has no id.
    pub fn notification(out: *std.Io.Writer, method: []const u8, meta: Meta) EncodeError!Writer {
        var w = try envelope(out);
        try w.openParams(method, meta);
        return w;
    }

    /// 2025 only: answers a server request, echoing its raw id.
    pub fn result(out: *std.Io.Writer, server_id: []const u8) EncodeError!Writer {
        return reply(out, server_id, "result");
    }

    pub fn field(w: *Writer, name: []const u8) EncodeError!void {
        try w.json.objectField(name);
    }

    pub fn string(w: *Writer, value: []const u8) EncodeError!void {
        try w.json.write(value);
    }

    pub fn int(w: *Writer, value: i64) EncodeError!void {
        try w.json.write(value);
    }

    /// Writes one already-encoded JSON value after checking it is exactly one
    /// valid value. CR and LF can only be whitespace in valid JSON, so they
    /// become spaces.
    pub fn raw(w: *Writer, value: []const u8) EncodeError!void {
        try validate(value);
        try w.json.beginWriteRaw();
        defer w.json.endWriteRaw();
        var rest = value;
        while (std.mem.findAny(u8, rest, "\r\n")) |index| {
            try w.json.writer.writeAll(rest[0..index]);
            try w.json.writer.writeByte(' ');
            rest = rest[index + 1 ..];
        }
        try w.json.writer.writeAll(rest);
    }

    /// Closes `params` (or `result`) and the message.
    pub fn end(w: *Writer) EncodeError!void {
        try w.json.endObject();
        try w.json.endObject();
    }

    /// Opens an answer to a server request: the envelope, its id, and `member`.
    fn reply(out: *std.Io.Writer, server_id: []const u8, member: []const u8) EncodeError!Writer {
        var w = try envelope(out);
        try w.json.objectField("id");
        try w.raw(server_id);
        try w.json.objectField(member);
        try w.json.beginObject();
        return w;
    }

    fn envelope(out: *std.Io.Writer) EncodeError!Writer {
        var w: Writer = .{ .json = .{ .writer = out } };
        try w.json.beginObject();
        try w.json.objectField("jsonrpc");
        try w.json.write("2.0");
        return w;
    }

    fn openParams(w: *Writer, method: []const u8, meta: Meta) EncodeError!void {
        try w.json.objectField("method");
        try w.json.write(method);
        try w.json.objectField("params");
        try w.json.beginObject();
        if (meta.modern == null and meta.progress_token == null) return;
        try w.json.objectField("_meta");
        try w.json.beginObject();
        if (meta.progress_token) |token| {
            try w.json.objectField("progressToken");
            try w.int(@intCast(token));
        }
        if (meta.modern) |modern| {
            try w.json.objectField("io.modelcontextprotocol/protocolVersion");
            try w.json.write(modern.protocol_version);
            try w.json.objectField("io.modelcontextprotocol/clientCapabilities");
            try w.raw(modern.client_capabilities);
            if (modern.client_info) |info| {
                try w.json.objectField("io.modelcontextprotocol/clientInfo");
                try w.json.write(info);
            }
        }
        try w.json.endObject();
    }
};

/// 2025 only: answers a server request with an error. From -32000 to -32099,
/// only the spec's defined codes (-32020 to -32022) are sent: the legacy
/// range is not used at all, and the rest is reserved for the spec.
pub fn writeFailure(out: *std.Io.Writer, server_id: []const u8, failure_code: i64, message: []const u8) EncodeError!void {
    std.debug.assert(failure_code > -32000 or failure_code < -32099 or
        (failure_code >= code.unsupported_protocol_version and failure_code <= code.header_mismatch));
    var w = try Writer.reply(out, server_id, "error");
    try w.field("code");
    try w.int(failure_code);
    try w.field("message");
    try w.string(message);
    try w.end();
}

fn validate(value: []const u8) error{InvalidRawJson}!void {
    var stack: [scan_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), value);
    defer scanner.deinit();
    scanner.skipValue() catch return error.InvalidRawJson;
    const last = scanner.next() catch return error.InvalidRawJson;
    if (last != .end_of_document) return error.InvalidRawJson;
}

const testing = std.testing;

/// The raw value found for a name, or a failure that says nothing was found, instead of a crash on `.?`.
fn expectRaw(want: []const u8, got: ?[]const u8) !void {
    try testing.expectEqualStrings(want, got orelse "(the name was not found)");
}

fn within(input: []const u8, part: []const u8) bool {
    const start = @intFromPtr(input.ptr);
    const at = @intFromPtr(part.ptr);
    return at >= start and at + part.len <= start + input.len;
}

test "decodes results with numeric, string, and foreign ids" {
    const numeric = try decode(
        \\{"jsonrpc":"2.0","id":7,"result":{"tools":[],"resultType":"complete"}}
    );
    try testing.expectEqual(@as(?RequestId, 7), numeric.response.id);
    try testing.expectEqual(ResultKind.complete, numeric.response.body.result.kind);
    try testing.expectEqualStrings("{\"tools\":[],\"resultType\":\"complete\"}", numeric.response.body.result.raw);

    const stringly = try decode(" {\"result\":{},\"id\":\"12\",\"jsonrpc\":\"2.0\"} ");
    try testing.expectEqual(@as(?RequestId, 12), stringly.response.id);

    for ([_][]const u8{ "\"abc\"", "\"012\"", "\"1_0\"", "-3", "null", "1.5", "99999999999999999999" }) |foreign| {
        var buffer: [96]u8 = undefined;
        const input = try std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{foreign});
        try testing.expectEqual(@as(?RequestId, null), (try decode(input)).response.id);
    }
    try testing.expectEqual(@as(?RequestId, null), (try decode("{\"jsonrpc\":\"2.0\",\"result\":{}}")).response.id);
}
