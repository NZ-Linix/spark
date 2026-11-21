//! How much of its notes the model has written, counted from the reply as it
//! streams in. The request asks for one line per tool call, starting with
//! its ID (`T12:`, or `T3–T7:` for calls that share a line), then the
//! sections Rules, Facts, Decisions, Status and Open, and Earlier when a
//! compaction folds the one before it (`ledger.writeRequest`). Each call
//! noted and each section begun is one step of the count, read with the
//! notes reader's own line rules (`ledger.lineStart`). Only the start of each
//! line is read, so a chunk can end anywhere, even inside an ID.

const std = @import("std");
const ledger = @import("ledger.zig");

const Allocator = std.mem.Allocator;

/// Receives every chunk of a reply as it arrives.
pub const TextSink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, chunk: []const u8) void,

    pub fn write(self: TextSink, chunk: []const u8) void {
        self.write_fn(self.context, chunk);
    }
};

/// Receives the count, from 1 to 99, each time it goes up. It never sees
/// 100: the notes are not done until spark has read and saved them.
pub const Sink = struct {
    context: *anyopaque,
    written_fn: *const fn (context: *anyopaque, percent: u8) void,
};

/// The sections every request asks for, and Earlier.
const section_count = @typeInfo(ledger.Section).@"enum".field_names.len;

/// The start of a line kept to read it. A tool ID range with its tool's name,
/// or a section heading, with Markdown around them, fits.
const line_start_bytes = 64;

/// The highest count before the notes are saved.
pub const most_before_saved = 99;

pub const Counter = struct {
    sink: ?Sink = null,
    /// Tool calls the whole compaction notes, in every part.
    total_tools: usize = 0,
    /// Sections the last part writes.
    total_sections: usize = section_count - 1,
    /// Calls noted in the parts before this one.
    tools_before: usize = 0,
    /// This part's calls are numbered from here, one after another.
    first_tool: usize = 0,
    /// Which of this part's calls a line has noted. Borrowed from the part.
    covered: []bool = &.{},
    covered_count: usize = 0,
    /// Only the last part's sections count: each part writes them.
    sections_count: bool = false,
    seen: [section_count]bool = @splat(false),
    seen_count: usize = 0,
    line: [line_start_bytes]u8 = undefined,
    line_len: usize = 0,
    /// The line's start was read; the rest of the line is skipped.
    line_read: bool = false,
    reported: u8 = 0,

    /// Sets what the compaction notes: `tools` calls across all its parts,
    /// and Earlier too when it folds the compaction before it.
    pub fn begin(self: *Counter, tools: usize, folds: bool) void {
        self.total_tools = tools;
        self.total_sections = if (folds) section_count else section_count - 1;
    }

    /// Starts a part whose `count` calls are numbered from `first_tool`.
    /// `covered` must hold `count` flags and outlive the part; `endPart`
    /// gives it back.
    pub fn startPart(self: *Counter, covered: []bool, first_tool: usize, last: bool) void {
        @memset(covered, false);
        self.covered = covered;
        self.covered_count = 0;
        self.first_tool = first_tool;
        self.sections_count = last;
        self.seen = @splat(false);
        self.seen_count = 0;
        // A part can number more calls than the turns showed before it was
        // prepared; the count never goes down for it.
        self.total_tools = @max(self.total_tools, self.tools_before + covered.len);
        self.endLine();
    }

    pub fn endPart(self: *Counter) void {
        self.tools_before += self.covered.len;
        self.covered = &.{};
        self.covered_count = 0;
        self.endLine();
    }

    pub fn textSink(self: *Counter) TextSink {
        return .{ .context = self, .write_fn = writeChunk };
    }

    fn writeChunk(context: *anyopaque, chunk: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.feed(chunk);
    }

    /// Reads one chunk of a reply and reports the count when it went up.
    pub fn feed(self: *Counter, chunk: []const u8) void {
        for (chunk) |byte| {
            if (byte == '\n') {
                self.endLine();
                continue;
            }
            if (self.line_read) continue;
            self.line[self.line_len] = byte;
            self.line_len += 1;
            if (self.line_len == self.line.len) {
                self.readLine(true);
            } else if (byte == ':') {
                self.readLine(false);
            }
        }
        const now = self.percent();
        if (now <= self.reported) return;
        self.reported = now;
        if (self.sink) |sink| sink.written_fn(sink.context, now);
    }

    /// The share of the notes written so far, from 0 to 99.
    pub fn percent(self: *const Counter) u8 {
        const total = self.total_tools + self.total_sections;
        if (total == 0) return 0;
        const done = self.tools_before + self.covered_count + self.seen_count;
        return @intCast(@min(most_before_saved, done * 100 / total));
    }

    fn endLine(self: *Counter) void {
        if (!self.line_read and self.line_len > 0) self.readLine(true);
        self.line_len = 0;
        self.line_read = false;
    }

    /// Reads the line's start when it names calls or begins a section. A `:`
    /// can end an ID or a heading, so the line is tried there too; a line
    /// that names nothing is given up once it ends or fills the buffer.
    fn readLine(self: *Counter, last_try: bool) void {
        var buffer: [line_start_bytes]u8 = undefined;
        var arena: std.heap.FixedBufferAllocator = .init(&buffer);
        const start = ledger.lineStart(arena.allocator(), self.line[0..self.line_len]) catch null;
        if (start == null and !last_try) return;
        self.line_read = true;
        switch (start orelse return) {
            .tools => |tools| self.cover(tools.first, tools.last),
            .section => |section| self.see(section),
        }
    }

    fn see(self: *Counter, section: ledger.Section) void {
        // Only the last part's sections count, and Earlier only in a fold.
        if (!self.sections_count) return;
        if (section == .earlier and self.total_sections < section_count) return;
        const index = @backingInt(section);
        if (self.seen[index]) return;
        self.seen[index] = true;
        self.seen_count += 1;
    }

    fn cover(self: *Counter, first: usize, last: usize) void {
        const len = self.covered.len;
        if (len == 0 or last < self.first_tool) return;
        const from = @max(first, self.first_tool) - self.first_tool;
        if (from >= len) return;
        const to = @min(last - self.first_tool, len - 1);
        for (self.covered[from .. to + 1]) |*flag| {
            if (flag.*) continue;
            flag.* = true;
            self.covered_count += 1;
        }
    }
};

// Tests

const testing = std.testing;

const Reports = struct {
    values: [128]u8 = undefined,
    len: usize = 0,

    fn sink(self: *Reports) Sink {
        return .{ .context = self, .written_fn = record };
    }

    fn record(context: *anyopaque, value: u8) void {
        const self: *Reports = @ptrCast(@alignCast(context));
        if (self.len < self.values.len) self.values[self.len] = value;
        self.len += 1;
    }
};

/// A counter for one part of `tools` calls numbered from `first`.
fn onePart(covered: []bool, first: usize, folds: bool) Counter {
    var counter: Counter = .{};
    counter.begin(covered.len, folds);
    counter.startPart(covered, first, true);
    return counter;
}

const sample_notes =
    \\Turn 1
    \\In between: Ran the build and found the missing semicolon.
    \\T1: ran the build; it stopped at src/a.zig:4
    \\T2–T3: read src/a.zig twice
    \\
    \\Turn 2
    \\In between: none
    \\- **T4**: fixed the semicolon
    \\
    \\Rules:
    \\none
    \\
    \\## Facts
    \\F1 (T1): the build fails on a missing semicolon
    \\
    \\Decisions:
    \\none
    \\
    \\Status:
    \\S1 (T4): fixed
    \\
    \\Open:
    \\none
;

test "each tool call noted and each section begun is one step" {
    var covered: [4]bool = undefined;
    var counter = onePart(&covered, 1, false);
    var reports: Reports = .{};
    counter.sink = reports.sink();
    // Nothing yet: the model is still reading.
    try testing.expectEqual(@as(u8, 0), counter.percent());
    counter.feed("Turn 1\nIn between: Ran the build.\nT1: ran the build\n");
    // 1 of 4 calls and 5 sections.
    try testing.expectEqual(@as(u8, 11), counter.percent());
    counter.feed("T2\u{2013}T3: read src/a.zig twice\n");
    try testing.expectEqual(@as(u8, 33), counter.percent());
    counter.feed("- **T4**: fixed it\n\nRules:\nnone\n\n## Facts\nF1 (T1): x\n");
    try testing.expectEqual(@as(u8, 66), counter.percent());
    counter.feed("Decisions:\nnone\n\nStatus:\nS1: y\n\nOpen:\nnone");
    // Everything is written, but the notes are not saved yet.
    try testing.expectEqual(@as(u8, 99), counter.percent());
    try testing.expectEqualSlices(u8, &.{ 11, 33, 66, 99 }, reports.values[0..reports.len]);
}
