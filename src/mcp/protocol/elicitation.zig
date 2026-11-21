//! Elicitation, both eras: reading an `elicitation/create` request into
//! a form or a URL, the defaults a host pre-fills, and reading the
//! host's answer, whose form content is checked against the schema before
//! anything is sent. Keys, enum values, and defaults
//! stay the server's raw JSON tokens. An answer's key or choice matches one
//! by the string the two tokens spell, not by their bytes (`wire.sameString`):
//! the host writes the answer back with `std.json`, which drops escapes the
//! server used. Nothing here allocates. Pure.

const std = @import("std");
const wire = @import("wire.zig");
const mrtr = @import("mrtr.zig");
const discovery = @import("../auth/discovery.zig");
const core = @import("../core/elicitation.zig");

pub const Mode = core.Mode;
pub const Action = core.Action;

/// Properties in one form.
pub const max_fields = 32;

/// `choice` is a single-select enum, `choices` a multi-select one.
pub const Kind = enum { string, number, integer, boolean, choice, choices };
/// An unknown format is shown but not checked.
pub const Format = enum { none, email, uri, date, date_time };

pub const Field = struct {
    /// The property's key as the server wrote it: a JSON string token.
    key: []const u8,
    kind: Kind,
    required: bool = false,
    /// Raw JSON string tokens, for the host to show.
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// The raw JSON default, for the host to pre-fill.
    default: ?[]const u8 = null,
    format: Format = .none,
    /// Bounds: the value for numbers, the length in code points for
    /// strings, the number of items for `choices`.
    min: ?f64 = null,
    max: ?f64 = null,
    /// The raw array of a choice's options: `enum`, `oneOf`, or `anyOf`.
    options: ?[]const u8 = null,
};

pub const Form = struct {
    fields: [max_fields]Field = undefined,
    count: u8 = 0,

    pub fn slice(f: *const Form) []const Field {
        return f.fields[0..f.count];
    }
};

pub const Request = struct {
    mode: Mode,
    /// A raw JSON string token.
    message: []const u8,
    /// URL mode: the URL, written without escapes.
    url: []const u8 = "",
    /// Its host, for the host to highlight.
    host: []const u8 = "",
    /// The host has a Punycode label or non-ASCII bytes: warn.
    suspicious: bool = false,
    /// 2025 URL mode: a raw JSON string token.
    elicitation_id: ?[]const u8 = null,
};

/// A request the client can't show. 2025 answers it -32602; a 2026
/// round with one ends its call `malformed`.
pub const Error = error{Unreadable};

/// Reads `params` into a request, and a form's fields into `form`, whose
/// slices point into `params`. Unreadable: no string `message`, a mode other
/// than form or url, a form whose `requestedSchema` isn't a flat object of
/// the spec's primitive properties, a `required` name with no property, more
/// than `max_fields` properties, or a URL that isn't HTTPS or HTTP to a
/// loopback host.
pub fn parse(params: []const u8, form: *Form) Error!Request {
    form.count = 0;
    var f: [5]?[]const u8 = undefined;
    wire.objectFields(params, &.{ "mode", "message", "requestedSchema", "url", "elicitationId" }, &f) catch return error.Unreadable;
    const message = f[1] orelse return error.Unreadable;
    if (message[0] != '"') return error.Unreadable;
    const mode: Mode = if (f[0]) |m|
        (if (isString(m, "form")) .form else if (isString(m, "url")) .url else return error.Unreadable)
    else
        .form;
    if (mode == .form) {
        try readSchema(f[2] orelse return error.Unreadable, form);
        return .{ .mode = .form, .message = message };
    }
    const url = wire.plainString(f[3] orelse return error.Unreadable) orelse return error.Unreadable;
    const u = discovery.parseUrl(url) orelse return error.Unreadable;
    if (!discovery.secureOrLoopback(url)) return error.Unreadable;
    if (f[4]) |id| if (id[0] != '"') return error.Unreadable;
    return .{ .mode = .url, .message = message, .url = url, .host = u.host, .suspicious = suspicious(u.host), .elicitation_id = f[4] };
}

/// The modes `capabilities` (the client's, a JSON object) declares, read as
/// `protocol/mrtr.zig` reads them.
pub fn declared(capabilities: []const u8) core.Config {
    return .{
        .form = mrtr.supported(capabilities, .{ .key = "", .kind = .elicitation, .raw = "", .params = "{}" }),
        .url = mrtr.supported(capabilities, .{ .key = "", .kind = .elicitation, .raw = "", .params = "{\"mode\":\"url\"}" }),
    };
}

fn isString(raw: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, wire.plainString(raw) orelse return false, value);
}

fn readSchema(schema: []const u8, form: *Form) Error!void {
    var s: [3]?[]const u8 = undefined;
    wire.objectFields(schema, &.{ "type", "properties", "required" }, &s) catch return error.Unreadable;
    if (!isString(s[0] orelse return error.Unreadable, "object")) return error.Unreadable;
    var properties: wire.Fields = undefined;
    properties.init(s[1] orelse return error.Unreadable) catch return error.Unreadable;
    while (properties.next() catch return error.Unreadable) |p| {
        if (form.count == max_fields) return error.Unreadable;
        for (form.slice()) |other| if (wire.sameString(other.key, p.key)) return error.Unreadable;
        form.fields[form.count] = try readField(p.key, p.value);
        form.count += 1;
    }
    if (s[2]) |required| {
        var names: wire.Elements = undefined;
        names.init(required) catch return error.Unreadable;
        while (names.next() catch return error.Unreadable) |name| {
            const field = for (form.fields[0..form.count]) |*field| {
                if (wire.sameString(field.key, name)) break field;
            } else return error.Unreadable;
            field.required = true;
        }
    }
}

const property_fields = [_][]const u8{ "type", "title", "description", "default", "enum", "oneOf", "format", "minLength", "maxLength", "minimum", "maximum", "items", "minItems", "maxItems" };

fn readField(key: []const u8, schema: []const u8) Error!Field {
    var p: [property_fields.len]?[]const u8 = undefined;
    wire.objectFields(schema, &property_fields, &p) catch return error.Unreadable;
    var field: Field = .{ .key = key, .kind = .string, .title = p[1], .description = p[2], .default = p[3] };
    if (field.title) |t| if (t[0] != '"') return error.Unreadable;
    if (field.description) |d| if (d[0] != '"') return error.Unreadable;
    const t = wire.plainString(p[0] orelse return error.Unreadable) orelse return error.Unreadable;
    if (std.mem.eql(u8, t, "string")) {
        if (p[4] orelse p[5]) |options| {
            field.kind = .choice;
            field.options = try readOptions(options, p[4] != null);
        } else {
            field.format = if (p[6]) |format| readFormat(format) else .none;
            field.min = try bound(p[7], true);
            field.max = try bound(p[8], true);
        }
    } else if (std.mem.eql(u8, t, "number") or std.mem.eql(u8, t, "integer")) {
        field.kind = if (t[0] == 'n') .number else .integer;
        field.min = try bound(p[9], false);
        field.max = try bound(p[10], false);
    } else if (std.mem.eql(u8, t, "boolean")) {
        field.kind = .boolean;
    } else if (std.mem.eql(u8, t, "array")) {
        var items: [3]?[]const u8 = undefined;
        wire.objectFields(p[11] orelse return error.Unreadable, &.{ "type", "enum", "anyOf" }, &items) catch return error.Unreadable;
        if (items[1] != null and !isString(items[0] orelse return error.Unreadable, "string")) return error.Unreadable;
        field.kind = .choices;
        field.options = try readOptions(items[1] orelse items[2] orelse return error.Unreadable, items[1] != null);
        field.min = try bound(p[12], true);
        field.max = try bound(p[13], true);
    } else return error.Unreadable;
    return field;
}

/// A non-empty array of strings (`enum`) or of objects with a string
/// `const` and an optional string `title` (`oneOf`, `anyOf`).
fn readOptions(options: []const u8, plain: bool) Error![]const u8 {
    var elements: wire.Elements = undefined;
    elements.init(options) catch return error.Unreadable;
    var count: usize = 0;
    while (elements.next() catch return error.Unreadable) |e| : (count += 1) {
        if (plain) {
            if (e[0] != '"') return error.Unreadable;
            continue;
        }
        var o: [2]?[]const u8 = undefined;
        wire.objectFields(e, &.{ "const", "title" }, &o) catch return error.Unreadable;
        if ((o[0] orelse return error.Unreadable)[0] != '"') return error.Unreadable;
        if (o[1]) |title| if (title[0] != '"') return error.Unreadable;
    }
    if (count == 0) return error.Unreadable;
    return options;
}

fn readFormat(raw: []const u8) Format {
    const name = wire.plainString(raw) orelse return .none;
    if (std.mem.eql(u8, name, "date-time")) return .date_time;
    return std.meta.stringToEnum(Format, name) orelse .none;
}

/// A number, or for lengths and counts a non-negative integer.
fn bound(raw: ?[]const u8, count: bool) Error!?f64 {
    const value = raw orelse return null;
    const x = std.fmt.parseFloat(f64, value) catch return error.Unreadable;
    if (!std.math.isFinite(x) or (count and (x < 0 or @trunc(x) != x))) return error.Unreadable;
    return x;
}

/// A Punycode label or any non-ASCII byte.
fn suspicious(host: []const u8) bool {
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len >= 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--")) return true;
    }
    for (host) |byte| if (byte >= 0x80) return true;
    return false;
}

pub const Option = struct {
    /// A raw JSON string token: what an answer holds.
    value: []const u8,
    title: ?[]const u8,
};

/// Walks a choice's options. Stays in place between `init` and the last `next`.
pub const Options = struct {
    elements: wire.Elements,

    pub fn init(o: *Options, field: *const Field) wire.DecodeError!void {
        try o.elements.init(field.options.?); // read by `parse`
    }

    pub fn next(o: *Options) ?Option {
        const e = (o.elements.next() catch return null) orelse return null;
        if (e[0] == '"') return .{ .value = e, .title = null };
        var f: [2]?[]const u8 = undefined;
        wire.objectFields(e, &.{ "const", "title" }, &f) catch return null;
        return .{ .value = f[0].?, .title = f[1] };
    }
};

/// The form's defaults as content, `{}` when it has none: what the host
/// pre-fills.
pub fn writeDefaults(form: *const Form, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeByte('{');
    var first = true;
    for (form.slice()) |f| if (f.default) |d| {
        if (!first) try out.writeByte(',');
        first = false;
        try out.writeAll(f.key);
        try out.writeByte(':');
        try out.writeAll(d);
    };
    try out.writeByte('}');
}

/// The host's answer: an action, and content exactly when a form is
/// accepted.
pub const Answer = struct { action: Action, content: ?[]const u8 = null };

pub const AnswerError = error{
    /// Not an answer: no known action, or content where it doesn't belong
    /// or none where it does.
    InvalidAnswer,
    /// Form content that fails the schema.
    InvalidContent,
};

/// Checks an answer to a request in `mode`, with `form` its fields: content
/// exactly with a form accept, holding only the schema's keys, each once,
/// every required one, and values of the right type within their bounds,
/// formats, and options.
pub fn check(mode: Mode, form: *const Form, answer: Answer) AnswerError!void {
    if ((answer.action == .accept and mode == .form) != (answer.content != null)) return error.InvalidAnswer;
    if (answer.content) |content| if (!validContent(form, content)) return error.InvalidContent;
}

/// Reads and checks an answer the host wrote as JSON (2026's input responses).
pub fn readAnswer(mode: Mode, form: *const Form, raw: []const u8) AnswerError!Answer {
    var f: [2]?[]const u8 = undefined;
    wire.objectFields(raw, &.{ "action", "content" }, &f) catch return error.InvalidAnswer;
    const name = wire.plainString(f[0] orelse return error.InvalidAnswer) orelse return error.InvalidAnswer;
    const answer: Answer = .{ .action = std.meta.stringToEnum(Action, name) orelse return error.InvalidAnswer, .content = f[1] };
    try check(mode, form, answer);
    return answer;
}

/// Writes an answer as JSON: `{"action":...}` and the content, if any.
pub fn writeAnswer(out: *std.Io.Writer, answer: Answer) std.Io.Writer.Error!void {
    try out.print("{{\"action\":\"{s}\"", .{@tagName(answer.action)});
    if (answer.content) |content| {
        try out.writeAll(",\"content\":");
        try out.writeAll(content);
    }
    try out.writeByte('}');
}

fn validContent(form: *const Form, content: []const u8) bool {
    var fields: wire.Fields = undefined;
    fields.init(content) catch return false;
    var seen: u32 = 0;
    while (fields.next() catch return false) |c| {
        const i = for (form.slice(), 0..) |f, i| {
            if (wire.sameString(f.key, c.key)) break i;
        } else return false;
        const bit = @as(u32, 1) << @intCast(i);
        if (seen & bit != 0 or !validValue(&form.fields[i], c.value)) return false;
        seen |= bit;
    }
    for (form.slice(), 0..) |f, i| {
        if (f.required and seen & (@as(u32, 1) << @intCast(i)) == 0) return false;
    }
    return true;
}

fn validValue(f: *const Field, value: []const u8) bool {
    switch (f.kind) {
        .boolean => return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false"),
        .number, .integer => {
            if (value[0] != '-' and !std.ascii.isDigit(value[0])) return false;
            const x = std.fmt.parseFloat(f64, value) catch return false;
            if (f.kind == .integer and @trunc(x) != x) return false;
            return within(x, f.min, f.max);
        },
        .string => return value[0] == '"' and within(@floatFromInt(wire.codePointCount(value) orelse return false), f.min, f.max) and validFormat(f.format, value),
        .choice => return isOption(f, value),
        .choices => {
            var items: wire.Elements = undefined;
            items.init(value) catch return false;
            var count: usize = 0;
            while (items.next() catch return false) |item| : (count += 1) {
                if (!isOption(f, item)) return false;
            }
            return within(@floatFromInt(count), f.min, f.max);
        },
    }
}

fn within(x: f64, min: ?f64, max: ?f64) bool {
    return (min == null or x >= min.?) and (max == null or x <= max.?);
}

fn isOption(f: *const Field, value: []const u8) bool {
    if (value[0] != '"') return false;
    var options: Options = undefined;
    options.init(f) catch return false;
    while (options.next()) |o| if (wire.sameString(o.value, value)) return true;
    return false;
}

/// Structural checks of the spec's four formats, on strings written
/// without escapes.
fn validFormat(format: Format, raw: []const u8) bool {
    if (format == .none) return true;
    const s = wire.plainString(raw) orelse return false;
    return switch (format) {
        .none => true,
        .email => email(s),
        .uri => uri(s),
        .date => date(s),
        .date_time => s.len > 10 and (s[10] == 'T' or s[10] == 't') and date(s[0..10]) and time(s[11..]),
    };
}

fn email(s: []const u8) bool {
    const at = std.mem.findScalar(u8, s, '@') orelse return false;
    return at > 0 and at + 1 < s.len and std.mem.findScalarPos(u8, s, at + 1, '@') == null and std.mem.findAny(u8, s, " \t") == null;
}

fn uri(s: []const u8) bool {
    const colon = std.mem.findScalar(u8, s, ':') orelse return false;
    if (colon == 0 or colon + 1 == s.len or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    return std.mem.findAny(u8, s, " \t") == null;
}

/// YYYY-MM-DD, a real day.
fn date(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    const y = digits(s[0..4]) orelse return false;
    const m = digits(s[5..7]) orelse return false;
    const d = digits(s[8..10]) orelse return false;
    if (m < 1 or m > 12 or d < 1) return false;
    const leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
    const days = [12]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d <= days[m - 1];
}

/// HH:MM:SS, an optional fraction, and Z or an offset (RFC 3339).
fn time(s: []const u8) bool {
    if (s.len < 9 or s[2] != ':' or s[5] != ':') return false;
    if ((digits(s[0..2]) orelse 99) > 23 or (digits(s[3..5]) orelse 99) > 59 or (digits(s[6..8]) orelse 99) > 60) return false;
    var rest = s[8..];
    if (rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 1) return false;
        rest = rest[i..];
    }
    if (rest.len == 1) return rest[0] == 'Z' or rest[0] == 'z';
    return rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':' and
        (digits(rest[1..3]) orelse 99) <= 23 and (digits(rest[4..6]) orelse 99) <= 59;
}

fn digits(s: []const u8) ?u32 {
    var x: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        x = x * 10 + (c - '0');
    }
    return x;
}

// ---- tests ----

const testing = std.testing;

test "reads the spec's form and URL examples" {
    var form: Form = .{};
    const simple = try parse(
        \\{"mode":"form","message":"Please provide your GitHub username","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
    , &form);
    try testing.expectEqual(Mode.form, simple.mode);
    try testing.expectEqual(@as(u8, 1), form.count);
    try testing.expectEqualStrings("\"name\"", form.fields[0].key);
    try testing.expect(form.fields[0].required);

    // No mode means form.
    _ = try parse(
        \\{"message":"m","requestedSchema":{"type":"object","properties":{"name":{"type":"string","description":"Your full name"},"email":{"type":"string","format":"email"},"age":{"type":"number","minimum":18}},"required":["name","email"]}}
    , &form);
    try testing.expectEqual(@as(u8, 3), form.count);
    try testing.expectEqual(Format.email, form.fields[1].format);
    try testing.expectEqual(@as(?f64, 18), form.fields[2].min);

    const url = try parse(
        \\{"mode":"url","url":"https://mcp.example.com/ui/set_api_key","message":"Please provide your API key to continue.","elicitationId":"550e8400"}
    , &form);
    try testing.expectEqual(Mode.url, url.mode);
    try testing.expectEqualStrings("mcp.example.com", url.host);
    try testing.expectEqualStrings("\"550e8400\"", url.elicitation_id.?);
    try testing.expect(!url.suspicious);
}

/// A JSON string the server writes with an escape, and the bytes the host
/// sends for the same value: `runtime.zig` parses spark's answer with `std.json`
/// and writes it back, which spells a value out without escapes.
const EscapeCase = struct { name: []const u8, written: []const u8, sent: []const u8 };
const escape_cases = [_]EscapeCase{
    .{ .name = "\\u00e9 (non-ASCII)", .written = "\"caf\\u00e9\"", .sent = "\"café\"" },
    .{ .name = "\\u00E9 (capital hex digit)", .written = "\"caf\\u00E9\"", .sent = "\"café\"" },
    .{ .name = "\\/ (escaped slash)", .written = "\"a\\/b\"", .sent = "\"a/b\"" },
    .{ .name = "\\u0041 (escaped ASCII letter)", .written = "\"\\u0041\"", .sent = "\"A\"" },
    .{ .name = "\\u000a (escaped newline)", .written = "\"a\\u000ab\"", .sent = "\"a\\nb\"" },
    .{ .name = "\\\" (escaped quote)", .written = "\"say \\\"hi\\\"\"", .sent = "\"say \\\"hi\\\"\"" },
    .{ .name = "\\\\ (escaped backslash)", .written = "\"a\\\\b\"", .sent = "\"a\\\\b\"" },
    .{ .name = "surrogate pair", .written = "\"\\ud83d\\ude00\"", .sent = "\"😀\"" },
    .{ .name = "no escape", .written = "\"plain\"", .sent = "\"plain\"" },
};

/// What the host writes for the string token `written`: parsed and written
/// back, as `elicitAnswer` and `inputValues` in `runtime.zig` do.
fn hostWrites(arena: std.mem.Allocator, written: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, written, .{ .parse_numbers = false });
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

/// Whether the engine accepts `content` for a form built from `schema`.
fn accepts(arena: std.mem.Allocator, properties: []const u8, content: []const u8) !bool {
    const params = try arena.print("{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{s}}}}}", .{properties});
    var form: Form = .{};
    const request = try parse(params, &form);
    check(request.mode, &form, .{ .action = .accept, .content = content }) catch return false;
    return true;
}

/// Every case the engine refuses, named, so a failure lists them all. The test fails when the text is not empty,
/// and `expectEqualStrings` prints it.
fn expectAllAccepted(comptime what: []const u8, comptime shape: fn (std.mem.Allocator, EscapeCase, []const u8) anyerror!bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var refused: std.ArrayList(u8) = .empty;
    for (escape_cases) |c| {
        const sent = try hostWrites(arena, c.written);
        try testing.expectEqualStrings(c.sent, sent); // the table says what the host writes
        if (!try shape(arena, c, sent)) {
            try refused.print(arena, "refused a valid {s}: written {s}, sent {s}, escape {s}\n", .{ what, c.written, sent, c.name });
        }
    }
    try testing.expectEqualStrings("", refused.items);
}

fn keyIsAccepted(arena: std.mem.Allocator, c: EscapeCase, sent: []const u8) anyerror!bool {
    const properties = try arena.print("{{{s}:{{\"type\":\"boolean\"}}}}", .{c.written});
    return accepts(arena, properties, try arena.print("{{{s}:true}}", .{sent}));
}

fn enumValueIsAccepted(arena: std.mem.Allocator, c: EscapeCase, sent: []const u8) anyerror!bool {
    const properties = try arena.print("{{\"c\":{{\"type\":\"string\",\"enum\":[{s},\"other\"]}}}}", .{c.written});
    return accepts(arena, properties, try arena.print("{{\"c\":{s}}}", .{sent}));
}

fn oneOfConstIsAccepted(arena: std.mem.Allocator, c: EscapeCase, sent: []const u8) anyerror!bool {
    const properties = try arena.print("{{\"c\":{{\"type\":\"string\",\"oneOf\":[{{\"const\":{s},\"title\":\"T\"}}]}}}}", .{c.written});
    return accepts(arena, properties, try arena.print("{{\"c\":{s}}}", .{sent}));
}

fn multiSelectValueIsAccepted(arena: std.mem.Allocator, c: EscapeCase, sent: []const u8) anyerror!bool {
    const properties = try arena.print("{{\"c\":{{\"type\":\"array\",\"items\":{{\"type\":\"string\",\"enum\":[{s},\"other\"]}}}}}}", .{c.written});
    return accepts(arena, properties, try arena.print("{{\"c\":[{s}]}}", .{sent}));
}

/// A form whose properties are `properties`, as the server's text.
fn formOf(arena: std.mem.Allocator, properties: []const u8, required: ?[]const u8) ![]const u8 {
    return arena.print(
        "{{\"message\":\"m\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{s}{s}}}}}",
        .{ properties, if (required) |r| try arena.print(",\"required\":{s}", .{r}) else "" },
    );
}
