//! One line of text with a cursor, for forms that edit a field in place
//! instead of in the composer, such as the `/mcp` server form.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_bytes = 4096;

pub const LineInput = struct {
    text: std.ArrayList(u8) = .empty,
    /// A byte offset on a character boundary.
    cursor: usize = 0,

    pub fn deinit(self: *LineInput, alloc: Allocator) void {
        std.crypto.secureZero(u8, self.text.items);
        self.text.deinit(alloc);
        self.* = .{};
    }

    pub fn items(self: *const LineInput) []const u8 {
        return self.text.items;
    }

    /// Replaces the text and puts the cursor at its end.
    pub fn set(self: *LineInput, alloc: Allocator, value: []const u8) Allocator.Error!void {
        self.clear();
        try self.text.appendSlice(alloc, value[0..@min(value.len, max_bytes)]);
        self.cursor = self.text.items.len;
    }

    pub fn clear(self: *LineInput) void {
        std.crypto.secureZero(u8, self.text.items);
        self.text.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// Inserts a typed or pasted byte at the cursor; control bytes are dropped.
    pub fn insert(self: *LineInput, alloc: Allocator, byte: u8) Allocator.Error!void {
        if (byte < 0x20 or byte == 0x7f) return;
        if (self.text.items.len >= max_bytes) return;
        try self.text.insert(alloc, self.cursor, byte);
        self.cursor += 1;
    }

    pub fn deleteBack(self: *LineInput) void {
        if (self.cursor == 0) return;
        const start = self.previous(self.cursor);
        self.remove(start, self.cursor);
        self.cursor = start;
    }

    pub fn deleteForward(self: *LineInput) void {
        if (self.cursor >= self.text.items.len) return;
        self.remove(self.cursor, self.next(self.cursor));
    }

    pub fn left(self: *LineInput) void {
        self.cursor = self.previous(self.cursor);
    }

    pub fn right(self: *LineInput) void {
        self.cursor = self.next(self.cursor);
    }

    pub fn home(self: *LineInput) void {
        self.cursor = 0;
    }

    pub fn end(self: *LineInput) void {
        self.cursor = self.text.items.len;
    }

    fn remove(self: *LineInput, start: usize, stop: usize) void {
        const t = self.text.items;
        @memmove(t[start .. t.len - (stop - start)], t[stop..]);
        self.text.shrinkRetainingCapacity(t.len - (stop - start));
    }

    fn previous(self: *const LineInput, at: usize) usize {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (self.text.items[i] & 0xC0 != 0x80) break;
        }
        return i;
    }

    fn next(self: *const LineInput, at: usize) usize {
        var i = @min(at + 1, self.text.items.len);
        while (i < self.text.items.len and self.text.items[i] & 0xC0 == 0x80) i += 1;
        return i;
    }
};
