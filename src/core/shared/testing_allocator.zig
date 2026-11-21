//! Allocator for tests that depend on a repeatable allocation sequence.

const std = @import("std");

/// `std.testing.allocator` without in-place resizing.
///
/// `std.heap.SafeAllocator` never reuses memory, so whether a small allocation
/// grows in place depends on how full its bucket is, which differs between
/// otherwise identical runs. Refusing every resize makes each growth allocate,
/// copy, and free, so the allocation sequence depends only on the code under
/// test. Use it as the backing allocator for
/// `std.testing.checkAllAllocationFailures` and for allocation-count
/// comparisons.
pub const no_resize: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}
