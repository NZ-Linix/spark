const std = @import("std");

/// Encodes untrusted dynamic metadata once at its final model-markup boundary; source-owned instruction bodies remain raw within their own limits.
pub fn writeScalar(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < value.len) {
        if (std.mem.startsWith(u8, value[index..], "\xc2\x85")) {
            try writer.writeAll("&#x85;");
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, value[index..], "\xe2\x80\xa8")) {
            try writer.writeAll("&#x2028;");
            index += 3;
            continue;
        }
        if (std.mem.startsWith(u8, value[index..], "\xe2\x80\xa9")) {
            try writer.writeAll("&#x2029;");
            index += 3;
            continue;
        }

        const byte = value[index];
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            0x00...0x1f, 0x7f => try writer.print("&#x{x:0>2};", .{byte}),
            else => try writer.writeByte(byte),
        }
        index += 1;
    }
}

test "writeScalar preserves safe ASCII Unicode and empty input" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeScalar(&out.writer, "safe value /._-' cafe\xcc\x81 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e");
    try writeScalar(&out.writer, "");

    try std.testing.expectEqualStrings("safe value /._-' cafe\xcc\x81 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", out.written());
}

/// `value` as a `{f}` format argument, written as `writeScalar` writes it,
/// without allocating. A message that quotes a name the model gave uses it,
/// so a control character in the name stays visible text in the message.
pub fn scalar(value: []const u8) Scalar {
    return .{ .value = value };
}

pub const Scalar = struct {
    value: []const u8,

    pub fn format(self: Scalar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeScalar(writer, self.value);
    }
};

pub fn scalarAlloc(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeScalar(&encoded.writer, value);
    return try encoded.toOwnedSlice();
}

pub fn writeJsonScalar(alloc: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try scalarAlloc(alloc, value);
    defer alloc.free(encoded);
    try std.json.Stringify.value(encoded, .{}, writer);
}

/// `value` as it was before `writeScalar` encoded it, for text that leaves
/// the model's context, such as `spark mcp call list` output. Decodes only the
/// entities `writeScalar` writes; any other `&` stays as it is. The result can
/// hold control bytes, so a caller that shows it encodes it for its own
/// output. Caller owns the result.
pub fn decodeScalarAlloc(alloc: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '&') {
            if (decodeEntity(value[index..])) |entity| {
                try out.appendSlice(alloc, entity.text);
                index += entity.len;
                continue;
            }
        }
        try out.append(alloc, value[index]);
        index += 1;
    }
    return out.toOwnedSlice(alloc);
}

const DecodedEntity = struct {
    /// The decoded text: one byte, or a two- or three-byte UTF-8 sequence.
    text: []const u8,
    /// How much of the encoded text the entity took.
    len: usize,
};

fn decodeEntity(text: []const u8) ?DecodedEntity {
    const named = [_]struct { entity: []const u8, text: []const u8 }{
        .{ .entity = "&amp;", .text = "&" },
        .{ .entity = "&lt;", .text = "<" },
        .{ .entity = "&gt;", .text = ">" },
        .{ .entity = "&quot;", .text = "\"" },
    };
    for (named) |item| {
        if (std.mem.startsWith(u8, text, item.entity)) return .{ .text = item.text, .len = item.entity.len };
    }
    if (!std.mem.startsWith(u8, text, "&#x")) return null;
    const end = std.mem.findScalar(u8, text[0..@min(text.len, 9)], ';') orelse return null;
    const digits = text[3..end];
    const decoded: []const u8 = if (std.mem.eql(u8, digits, "85"))
        "\xc2\x85"
    else if (std.mem.eql(u8, digits, "2028"))
        "\xe2\x80\xa8"
    else if (std.mem.eql(u8, digits, "2029"))
        "\xe2\x80\xa9"
    else if (digits.len == 2) blk: {
        const code = std.fmt.parseInt(u8, digits, 16) catch return null;
        if (code > 0x1f and code != 0x7f) return null;
        break :blk control_bytes[code .. code + 1];
    } else return null;
    return .{ .text = decoded, .len = end + 1 };
}

/// The ASCII byte values, so a decoded control byte can be a slice of static
/// memory.
const control_bytes: [0x80]u8 = blk: {
    var bytes: [0x80]u8 = undefined;
    for (&bytes, 0..) |*byte, value| byte.* = @intCast(value);
    break :blk bytes;
};

/// The names of the blocks spark adds to the conversation: the folder rules it
/// delivers and their reminders (`scoped-rules-reminder`, D93), a changed
/// runtime context (D94), and the short note an older spark saved for a named
/// skill's turn (D95). Their writers take the names from here, so every
/// carried block is escaped.
pub const scoped_rules_tag = "scoped-rules";
pub const context_update_tag = "spark-context-update";
pub const skill_used_tag = "spark-skill-used";
const carried_tags = [_][]const u8{ scoped_rules_tag, context_update_tag, skill_used_tag };
/// What a carried tag starts with in text spark escaped.
const escaped_open = "&lt;";

/// Whether `text[at..]` opens or closes a carried block, in any case. A name
/// only has to start with a carried one, so `<scoped-rules-reminder` counts.
fn carriedTagAt(text: []const u8, at: usize) bool {
    if (text[at] != '<') return false;
    return carriedNameAt(text, if (at + 1 < text.len and text[at + 1] == '/') at + 2 else at + 1);
}

fn carriedNameAt(text: []const u8, name_start: usize) bool {
    for (carried_tags) |tag| {
        if (text.len -| name_start >= tag.len and std.ascii.eqlIgnoreCase(text[name_start..][0..tag.len], tag)) return true;
    }
    return false;
}

pub fn hasCarriedTag(text: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, text, from, '<')) |at| {
        from = at + 1;
        if (carriedTagAt(text, at)) return true;
    }
    return false;
}

/// Writes `text` with every opening or closing carried tag starting `&lt;`
/// instead of `<`, so only spark opens those blocks. Text that spark did not write
/// goes through here before it joins the conversation: tool output, the
/// bodies of instruction files, and a named skill's text.
pub fn writeCarriedEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var copied: usize = 0;
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, text, from, '<')) |at| {
        from = at + 1;
        if (!carriedTagAt(text, at)) continue;
        try writer.writeAll(text[copied..at]);
        try writer.writeAll(escaped_open);
        copied = at + 1;
    }
    try writer.writeAll(text[copied..]);
}

/// `text` as `writeCarriedEscaped` writes it, in `arena`, or `text` itself
/// when it has no carried tag.
pub fn escapeCarried(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!hasCarriedTag(text)) return text;
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, text.len + 16);
    writeCarriedEscaped(&out.writer, text) catch return error.OutOfMemory;
    return out.written();
}

/// `text` with each escaped carried tag starting `<` again, in `alloc`, or
/// null when it has none: what a file holds where tool output showed `text`.
/// Caller owns the result.
pub fn unescapeCarried(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var copied: usize = 0;
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, escaped_open)) |at| {
        from = at + escaped_open.len;
        const name_start = if (from < text.len and text[from] == '/') from + 1 else from;
        if (!carriedNameAt(text, name_start)) continue;
        try out.appendSlice(alloc, text[copied..at]);
        try out.append(alloc, '<');
        copied = from;
    }
    if (copied == 0) return null;
    try out.appendSlice(alloc, text[copied..]);
    return try out.toOwnedSlice(alloc);
}
