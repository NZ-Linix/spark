const std = @import("std");
const lex = @import("command_lex.zig");

const whitespace = " \t\r\n";

pub const Token = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

/// Returns true when a command grant should preserve the full command text.
pub fn command_requires_literal_pattern(token: []const u8) bool {
    return command_hides_base_token(token);
}

fn command_hides_base_token(token: []const u8) bool {
    return is_shell_command(token) or
        is_delegating_command(token) or
        is_privilege_prefix(token);
}

fn is_shell_command(token: []const u8) bool {
    return std.mem.eql(u8, token, "sh") or
        std.mem.eql(u8, token, "bash") or
        std.mem.eql(u8, token, "zsh") or
        std.mem.eql(u8, token, "dash") or
        std.mem.eql(u8, token, "ksh") or
        std.mem.eql(u8, token, "csh") or
        std.mem.eql(u8, token, "tcsh") or
        std.mem.eql(u8, token, "fish") or
        std.mem.eql(u8, token, "cmd") or
        std.mem.eql(u8, token, "powershell") or
        std.mem.eql(u8, token, "pwsh");
}

fn is_delegating_command(token: []const u8) bool {
    return std.mem.eql(u8, token, "env") or
        std.mem.eql(u8, token, "xargs") or
        std.mem.eql(u8, token, "nice") or
        std.mem.eql(u8, token, "stdbuf") or
        std.mem.eql(u8, token, "unbuffer") or
        std.mem.eql(u8, token, "nohup") or
        std.mem.eql(u8, token, "timeout") or
        std.mem.eql(u8, token, "time");
}

fn is_privilege_prefix(token: []const u8) bool {
    return std.mem.eql(u8, token, "sudo") or
        std.mem.eql(u8, token, "doas") or
        std.mem.eql(u8, token, "su");
}

fn is_safe_env_command(token: []const u8) bool {
    return std.mem.eql(u8, token, "env");
}

fn is_safe_priority_prefix(token: []const u8) bool {
    return std.mem.eql(u8, token, "nice");
}

fn is_safe_stdio_prefix(token: []const u8) bool {
    return std.mem.eql(u8, token, "stdbuf");
}

fn is_safe_passthrough_prefix(token: []const u8) bool {
    return std.mem.eql(u8, token, "unbuffer") or
        std.mem.eql(u8, token, "nohup") or
        std.mem.eql(u8, token, "time");
}

fn is_safe_timeout_prefix(token: []const u8) bool {
    return std.mem.eql(u8, token, "timeout");
}

/// Returns the first non-env command token when it is safe to identify.
pub fn base_command_token(command: []const u8) ?[]const u8 {
    if (std.mem.findScalar(u8, command, '\n') != null) return null;

    var cursor = skip_whitespace(command, 0);
    while (next_token(command, cursor)) |token| {
        if (is_env_assignment(token.text)) {
            if (!is_safe_env_assignment(token.text)) return null;
            cursor = word_end(command, token.start) orelse return null;
            continue;
        }

        if (command_hides_base_token(token.text)) return null;
        if (!is_accepted_command_identifier(token.text)) return null;
        return token.text;
    }
    return null;
}

/// Returns the command tail after peeling only safe analysis prefixes.
pub fn analysis_command_tail(command: []const u8) []const u8 {
    const original = command;
    var cursor = skip_whitespace(command, 0);
    var peeled = false;

    while (next_token(command, cursor)) |token| {
        if (is_env_assignment(token.text)) {
            if (!is_safe_env_assignment(token.text)) return original;
            cursor = word_end(command, token.start) orelse return original;
            peeled = true;
            continue;
        }

        if (is_safe_env_command(token.text)) {
            const env_arg = next_token(command, token.end) orelse return original;
            if (!is_env_assignment(env_arg.text) or !is_safe_env_assignment(env_arg.text)) return original;
            cursor = word_end(command, env_arg.start) orelse return original;
            peeled = true;
            continue;
        }

        if (is_safe_priority_prefix(token.text)) {
            cursor = skip_nice_args(command, token.end);
            peeled = true;
            continue;
        }
        if (is_safe_stdio_prefix(token.text)) {
            cursor = skip_stdbuf_args(command, token.end);
            peeled = true;
            continue;
        }
        if (is_safe_passthrough_prefix(token.text)) {
            cursor = token.end;
            peeled = true;
            continue;
        }
        if (is_safe_timeout_prefix(token.text)) {
            const duration = next_token(command, token.end) orelse return original;
            if (!is_timeout_duration(duration.text)) return original;
            cursor = duration.end;
            peeled = true;
            continue;
        }

        return command[token.start..];
    }

    return if (peeled) command[cursor..] else original;
}

/// Returns the deterministic final command segment for default sh list semantics.
pub fn terminal_exit_segment(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, whitespace);
    if (trimmed.len == 0) return null;

    var in_single = false;
    var in_double = false;
    var escaped = false;
    var segment_start: usize = 0;
    var i: usize = 0;

    while (i < command.len) : (i += 1) {
        const ch = command[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;

        switch (ch) {
            '&' => {
                if (i + 1 < command.len and command[i + 1] == '&') return null;
                return null;
            },
            '|' => {
                if (i + 1 < command.len and command[i + 1] == '|') return null;
                segment_start = i + 1;
            },
            ';', '\n' => segment_start = i + 1,
            else => {},
        }
    }

    if (in_single or in_double) return null;
    const segment = std.mem.trim(u8, command[segment_start..], whitespace);
    return if (segment.len == 0) null else segment;
}

pub fn skip_whitespace(input: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < input.len and is_whitespace(input[cursor])) : (cursor += 1) {}
    return cursor;
}

pub fn next_token(input: []const u8, start: usize) ?Token {
    const token_start = skip_whitespace(input, start);
    if (token_start >= input.len) return null;
    var token_end = token_start;
    while (token_end < input.len and !is_whitespace(input[token_end])) : (token_end += 1) {}
    return .{ .text = input[token_start..token_end], .start = token_start, .end = token_end };
}

/// Where the shell word that starts at `start` ends, reading quotes,
/// backslash escapes, and `$(...)`, `${...}`, and backquoted substitutions
/// as the shell does, or null when one is never closed or the input ends in
/// a backslash. `next_token` splits only on whitespace, so for `CI='x ls' rm`
/// or `X=$(date +%s) rm` it would stop inside the value.
pub fn word_end(input: []const u8, start: usize) ?usize {
    return shellTextEnd(input, start, .word, 0);
}

/// What ends the text `shellTextEnd` reads.
const ShellText = enum { word, double_quote, command, parameter, backquote };

/// How deeply quotes and substitutions may nest before `word_end` gives up.
const max_shell_nesting = 32;

/// Reads shell text from `start` until what ends `text`: whitespace for a
/// word, or the character that closes a quote or substitution, which it
/// reads past. Returns null when the text is never closed.
fn shellTextEnd(input: []const u8, start: usize, text: ShellText, depth: usize) ?usize {
    if (depth > max_shell_nesting) return null;
    // Parentheses inside `$(...)`, as in `$((1 + 2))` or a subshell.
    var parens: usize = 0;
    var i = start;
    while (i < input.len) {
        const ch = input[i];
        switch (text) {
            .word => if (is_whitespace(ch)) return i,
            .double_quote => if (ch == '"') return i + 1,
            .parameter => if (ch == '}') return i + 1,
            .backquote => if (ch == '`') return i + 1,
            .command => if (ch == ')') {
                if (parens == 0) return i + 1;
                parens -= 1;
            } else if (ch == '(') {
                parens += 1;
            },
        }
        if (ch == '\\') {
            if (i + 1 >= input.len) return null;
            i += 2;
            continue;
        }
        // A backquoted command is read as literal text up to its end.
        if (text == .backquote) {
            i += 1;
            continue;
        }
        const next: u8 = if (i + 1 < input.len) input[i + 1] else 0;
        if (ch == '\'' and text != .double_quote) {
            i = (std.mem.findScalarPos(u8, input, i + 1, '\'') orelse return null) + 1;
        } else if (ch == '$' and next == '\'' and text != .double_quote) {
            i = ansiCQuoteEnd(input, i + 2) orelse return null;
        } else if (ch == '$' and next == '(') {
            i = shellTextEnd(input, i + 2, .command, depth + 1) orelse return null;
        } else if (ch == '$' and next == '{') {
            i = shellTextEnd(input, i + 2, .parameter, depth + 1) orelse return null;
        } else if (ch == '`') {
            i = shellTextEnd(input, i + 1, .backquote, depth + 1) orelse return null;
        } else if (ch == '"') {
            i = shellTextEnd(input, i + 1, .double_quote, depth + 1) orelse return null;
        } else {
            i += 1;
        }
    }
    return if (text == .word) i else null;
}

/// Where a `$'...'` quote whose text starts at `start` ends. A backslash
/// escapes the next character, so `\'` does not end it.
fn ansiCQuoteEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\') {
            i += 1;
        } else if (input[i] == '\'') {
            return i + 1;
        }
    }
    return null;
}

fn is_whitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

pub fn is_env_assignment(token: []const u8) bool {
    const eq = std.mem.findScalar(u8, token, '=') orelse return false;
    if (eq == 0) return false;
    return is_env_name(token[0..eq]);
}

fn is_env_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!is_ascii_upper(name[0]) and name[0] != '_') return false;
    for (name[1..]) |ch| {
        if (!is_ascii_upper(ch) and !is_ascii_digit(ch) and ch != '_') return false;
    }
    return true;
}

fn is_safe_env_assignment(token: []const u8) bool {
    return lex.is_safe_env_assignment(token);
}

fn is_accepted_command_identifier(token: []const u8) bool {
    if (std.mem.eql(u8, token, "[")) return true;
    if (token.len == 0) return false;

    var saw_letter = false;
    var prev_hyphen = false;
    for (token, 0..) |ch, i| {
        if (is_ascii_lower(ch)) {
            saw_letter = true;
            prev_hyphen = false;
            continue;
        }
        if (is_ascii_digit(ch)) {
            prev_hyphen = false;
            continue;
        }
        if (ch == '-') {
            if (i == 0 or i + 1 == token.len or prev_hyphen) return false;
            prev_hyphen = true;
            continue;
        }
        return false;
    }
    return saw_letter and !prev_hyphen;
}

fn skip_nice_args(command: []const u8, start: usize) usize {
    const first = next_token(command, start) orelse return start;
    if (std.mem.eql(u8, first.text, "-n")) {
        const value = next_token(command, first.end) orelse return start;
        return value.end;
    }
    if (first.text.len > 1 and first.text[0] == '-' and is_ascii_digit(first.text[1])) return first.end;
    return start;
}

fn skip_stdbuf_args(command: []const u8, start: usize) usize {
    var cursor = start;
    while (next_token(command, cursor)) |token| {
        if (!std.mem.startsWith(u8, token.text, "-")) break;
        cursor = token.end;
    }
    return cursor;
}

fn is_timeout_duration(token: []const u8) bool {
    if (token.len == 0 or !is_ascii_digit(token[0])) return false;
    var saw_digit = false;
    var saw_dot = false;
    for (token, 0..) |ch, i| {
        if (is_ascii_digit(ch)) {
            saw_digit = true;
            continue;
        }
        if (ch == '.' and !saw_dot and i + 1 < token.len) {
            saw_dot = true;
            continue;
        }
        if (i + 1 == token.len and (ch == 's' or ch == 'm' or ch == 'h' or ch == 'd')) {
            return saw_digit;
        }
        return false;
    }
    return saw_digit;
}

fn is_ascii_lower(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn is_ascii_upper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn is_ascii_digit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

test "literal pattern predicate covers delegated and privileged commands" {
    try std.testing.expect(command_requires_literal_pattern("bash"));
    try std.testing.expect(command_requires_literal_pattern("cmd"));
    try std.testing.expect(command_requires_literal_pattern("env"));
    try std.testing.expect(command_requires_literal_pattern("nice"));
    try std.testing.expect(command_requires_literal_pattern("sudo"));
    try std.testing.expect(command_requires_literal_pattern("doas"));
    try std.testing.expect(command_requires_literal_pattern("su"));
    try std.testing.expect(!command_requires_literal_pattern("grep"));
}

/// Pieces of generated commands: the wrappers and environment assignments
/// the classifier peels, and the quotes, escapes, and substitutions that move
/// a word boundary that a split on whitespace cannot see.
const fuzz_fragments = [_][]const u8{
    " ",    "\t",   "\n",   "ls",    "rm",   "grep",   "git",  "find",
    "-rf",  "x",    "[",    "CI=",   "CI=1", "TERM=",  "FOO=", "env",
    "nice", "-n",   "5",    "-5",    "time", "stdbuf", "-oL",  "timeout",
    "10s",  "sudo", "bash", "nohup", "'",    "\"",     "\\",   "\\ ",
    "|",    "&&",   "&",    ";",     ">",    "=",      "-",    "\u{e9}",
    "$(",   ")",    "${",   "}",     "`",    "$'",
};

fn writeFuzzCommand(smith: *std.testing.Smith, out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..smith.valueRangeAtMost(u8, 0, 16)) |_| {
        if (smith.boolWeighted(7, 1)) {
            try out.writeAll(fuzz_fragments[smith.index(fuzz_fragments.len)]);
            continue;
        }
        var raw: [4]u8 = undefined;
        try out.writeAll(raw[0..smith.slice(&raw)]);
    }
}

fn isWithin(outer: []const u8, inner: []const u8) bool {
    const start = @intFromPtr(inner.ptr);
    return start >= @intFromPtr(outer.ptr) and start + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

fn fuzzClassification(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeFuzzCommand(smith, &writer) catch |err| switch (err) {
        // A full buffer ends the command early, which is still a command.
        error.WriteFailed => {},
    };
    const command = writer.buffered();

    const tail = analysis_command_tail(command);
    try std.testing.expect(isWithin(command, tail));
    try std.testing.expectEqual(@intFromPtr(command.ptr) + command.len, @intFromPtr(tail.ptr) + tail.len);
    if (terminal_exit_segment(command)) |segment| {
        try std.testing.expect(isWithin(command, segment) and segment.len > 0);
        try std.testing.expectEqualStrings(std.mem.trim(u8, segment, whitespace), segment);
    }

    const base = base_command_token(command) orelse return;
    try std.testing.expect(isWithin(command, base));
    try std.testing.expect(std.mem.findAny(u8, base, whitespace) == null);
    // The base command is the first word the shell runs after the
    // environment assignments. Callers look for shell operators before they
    // ask for it, so only a simple command, with no operators, is compared.
    // The lexer reads `$` and backquotes literally, so a command with a
    // substitution is left to the `word_end` tests.
    if (std.mem.findAny(u8, command, "$`") != null) return;
    var argv = lex.tokenize_argv(std.testing.allocator, command) catch return;
    defer argv.deinit(std.testing.allocator);
    for (argv.tokens) |token| {
        if (!token.quoted and std.mem.findNone(u8, token.raw, "&|;<>(){}") == null) return;
    }
    for (argv.tokens) |token| {
        if (is_env_assignment(token.value)) continue;
        try std.testing.expectEqualStrings(token.value, base);
        return;
    }
    // Every word the shell reads is an assignment, so no command runs.
    return error.TestBaseCommandMissing;
}
