//! Reading lines under a size limit: newline-delimited for the stdio reader,
//! and CR, LF, or CRLF for the SSE reader.

const std = @import("std");

pub const Line = struct {
    /// The line without its newline and one trailing CR. Valid until
    /// the next read into the same buffer.
    bytes: []const u8,
    /// Longer than the limit: `bytes` is its start, and the rest is still
    /// unread, so a caller that stops never waits for a newline that may not
    /// come. `skipRest` reads past it.
    too_long: bool,
    /// The stream ended without a newline after this line.
    at_end: bool,
};

/// Reads the next line into `line`, which is cleared first.
pub fn read(reader: *std.Io.Reader, line: *std.Io.Writer.Allocating, limit: usize) error{ReadFailed}!Line {
    line.clearRetainingCapacity();
    if (reader.streamDelimiterLimit(&line.writer, '\n', .limited(limit))) |_| {} else |err| switch (err) {
        error.StreamTooLong => return .{ .bytes = line.written(), .too_long = true, .at_end = false },
        error.ReadFailed, error.WriteFailed => return error.ReadFailed,
    }
    const at_end = if (reader.discardDelimiterInclusive('\n')) |_| false else |err| switch (err) {
        error.EndOfStream => true,
        error.ReadFailed => return error.ReadFailed,
    };
    var bytes = line.written();
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\r') bytes.len -= 1;
    return .{ .bytes = bytes, .too_long = false, .at_end = at_end };
}

/// The lines of an event stream, which the SSE standard lets end at CR, LF,
/// or CRLF. A line ends at its CR at once, and a LF right after it is skipped when
/// it comes, so an event that ends with bare CRs is read without waiting
/// for a LF that may never come.
pub const SseLines = struct {
    /// The last line ended at a CR, so a LF that comes next ends it too.
    after_cr: bool = false,

    /// Reads the next line onto the end of `buf`. One past `limit`, for
    /// `buf` as a whole, is `too_long`, and the stream is then of no further
    /// use. `counter.grow(held)` runs before `buf` grows to `held` bytes, a
    /// read's worth at a time, so its owner can count them.
    pub fn read(s: *SseLines, reader: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), limit: usize, counter: anytype) !Line {
        const mark = buf.items.len;
        while (true) {
            const buffered = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return .{ .bytes = buf.items[mark..], .too_long = false, .at_end = true },
                error.ReadFailed => return error.ReadFailed,
            };
            const skip: usize = @intFromBool(s.after_cr and buffered[0] == '\n');
            s.after_cr = false;
            const rest = buffered[skip..];
            const end = std.mem.findAny(u8, rest, "\r\n");
            const part = rest[0 .. end orelse rest.len];
            if (buf.items.len + part.len > limit) return .{ .bytes = buf.items[mark..], .too_long = true, .at_end = false };
            try counter.grow(buf.items.len + part.len);
            try buf.appendSlice(gpa, part);
            reader.toss(skip + part.len);
            if (end) |i| {
                s.after_cr = rest[i] == '\r';
                reader.toss(1);
                return .{ .bytes = buf.items[mark..], .too_long = false, .at_end = false };
            }
        }
    }
};

/// Reads past the rest of an over-long line. Returns true at the end of the stream.
pub fn skipRest(reader: *std.Io.Reader) error{ReadFailed}!bool {
    _ = reader.discardDelimiterInclusive('\n') catch |err| return switch (err) {
        error.EndOfStream => true,
        error.ReadFailed => error.ReadFailed,
    };
    return false;
}

const testing = std.testing;

/// Counts nothing, for the tests.
const NoCount = struct {
    pub fn grow(_: *NoCount, _: usize) error{}!void {}
};
