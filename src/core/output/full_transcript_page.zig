const std = @import("std");

pub const max_source_entries: usize = 256;

pub const Anchor = union(enum) {
    tail,
    entry_index: usize,
    /// A page of an older compaction cycle the transcript reads from the
    /// session log: `back` cycles before the held entries (1 is the newest),
    /// around one of that cycle's entries. `maxInt` is its last entry.
    archive: Archive,
};

pub const Archive = struct {
    back: u32,
    entry_index: usize,
};

pub const Request = struct {
    content_revision: u64,
    cols: u16,
    anchor: Anchor,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: SourceRange) usize {
        return self.end - self.start;
    }
};

pub fn sourceRange(request: Request, total_entries: usize) SourceRange {
    if (total_entries <= max_source_entries) {
        return .{ .start = 0, .end = total_entries };
    }

    const latest_start = total_entries - max_source_entries;
    const requested_index = switch (request.anchor) {
        .tail => return .{ .start = latest_start, .end = total_entries },
        .entry_index => |index| index,
        .archive => |archive| archive.entry_index,
    };
    const anchor_index = @min(requested_index, total_entries - 1);
    const start = @min(anchor_index -| max_source_entries / 2, latest_start);
    return .{ .start = start, .end = start + max_source_entries };
}

pub fn sameRequest(lhs: Request, rhs: Request) bool {
    return lhs.content_revision == rhs.content_revision and
        lhs.cols == rhs.cols and
        std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn sameSurface(lhs: Request, rhs: Request) bool {
    return lhs.cols == rhs.cols and std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn previousAnchor(range: SourceRange) ?Anchor {
    if (range.start == 0) return null;
    return .{ .entry_index = range.start - 1 };
}

pub fn nextAnchor(range: SourceRange, total_entries: usize) ?Anchor {
    if (range.end >= total_entries) return null;
    return .{ .entry_index = range.end };
}

test "full transcript page range stays bounded at the tail" {
    const request = Request{
        .content_revision = 41,
        .cols = 80,
        .anchor = .tail,
    };
    const range = sourceRange(request, 10_000);

    try std.testing.expectEqual(@as(usize, 10_000), range.end);
    try std.testing.expectEqual(max_source_entries, range.len());
}
