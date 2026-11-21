const std = @import("std");
const builtin = @import("builtin");

/// `std.atomic.Value(T)` for any target. Zig refuses atomics wider than the
/// target supports, such as 64-bit values on wasm32 or 32-bit x86, so those
/// targets get the same API backed by something they can do:
///
/// - WASM builds run single-threaded, so a plain value is sound there.
/// - Threaded 32-bit targets guard each value with a lock from a small
///   striped table, picked by the value's address, the way libatomic does.
///   The lock lives outside the value so `load` can take a const pointer.
pub fn Value(comptime T: type) type {
    if (!needsFallback(T)) return std.atomic.Value(T);
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub fn load(self: *const Self, comptime _: std.lang.AtomicOrder) T {
            const lock = stripe.acquire(self);
            defer stripe.release(lock);
            return self.raw;
        }

        pub fn store(self: *Self, value: T, comptime _: std.lang.AtomicOrder) void {
            const lock = stripe.acquire(self);
            defer stripe.release(lock);
            self.raw = value;
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime _: std.lang.AtomicOrder) T {
            const lock = stripe.acquire(self);
            defer stripe.release(lock);
            const previous = self.raw;
            self.raw +%= operand;
            return previous;
        }

        pub fn cmpxchgWeak(
            self: *Self,
            expected: T,
            new: T,
            comptime _: std.lang.AtomicOrder,
            comptime _: std.lang.AtomicOrder,
        ) ?T {
            const lock = stripe.acquire(self);
            defer stripe.release(lock);
            if (self.raw != expected) return self.raw;
            self.raw = new;
            return null;
        }
    };
}

/// `@atomicLoad`, `@atomicStore`, and `@cmpxchgWeak` on a plain `*T` field,
/// for state that cannot be wrapped in `Value`, with the same fallback.
pub fn load(comptime T: type, ptr: *const T, comptime order: std.lang.AtomicOrder) T {
    if (comptime !needsFallback(T)) return @atomicLoad(T, ptr, order);
    const lock = stripe.acquire(ptr);
    defer stripe.release(lock);
    return ptr.*;
}

pub fn store(comptime T: type, ptr: *T, value: T, comptime order: std.lang.AtomicOrder) void {
    if (comptime !needsFallback(T)) return @atomicStore(T, ptr, value, order);
    const lock = stripe.acquire(ptr);
    defer stripe.release(lock);
    ptr.* = value;
}

pub fn cmpxchgWeak(
    comptime T: type,
    ptr: *T,
    expected: T,
    new: T,
    comptime success: std.lang.AtomicOrder,
    comptime failure: std.lang.AtomicOrder,
) ?T {
    if (comptime !needsFallback(T)) return @cmpxchgWeak(T, ptr, expected, new, success, failure);
    const lock = stripe.acquire(ptr);
    defer stripe.release(lock);
    if (ptr.* != expected) return ptr.*;
    ptr.* = new;
    return null;
}

fn needsFallback(comptime T: type) bool {
    return @bitSizeOf(T) > @bitSizeOf(usize);
}

const single_threaded = builtin.single_threaded or builtin.target.os.tag == .wasi;

const stripe = struct {
    /// Enough stripes that unrelated values rarely share a lock; each
    /// critical section is a few instructions, so contention stays brief.
    const count = 64;
    var locks: [count]std.atomic.Value(u32) = @splat(.init(0));

    fn acquire(ptr: *const anyopaque) ?*std.atomic.Value(u32) {
        if (single_threaded) return null;
        const lock = &locks[(@intFromPtr(ptr) >> 3) % count];
        while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        return lock;
    }

    fn release(lock: ?*std.atomic.Value(u32)) void {
        if (lock) |held| held.store(0, .release);
    }
};

test "the replacement matches the atomic API it stands in for" {
    var value: Value(u64) = .init(5);
    try std.testing.expectEqual(@as(u64, 5), value.load(.acquire));
    value.store(7, .release);
    try std.testing.expectEqual(@as(u64, 7), value.fetchAdd(2, .monotonic));
    try std.testing.expectEqual(@as(u64, 9), value.load(.acquire));
    try std.testing.expectEqual(@as(?u64, 9), value.cmpxchgWeak(1, 3, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(?u64, null), value.cmpxchgWeak(9, 3, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(u64, 3), value.load(.acquire));
}

test "threads adding to one 64-bit value lose no update" {
    if (single_threaded) return error.SkipZigTest;
    const per_thread = 10_000;
    const thread_count = 4;
    const Adder = struct {
        fn run(target: *Value(u64)) void {
            for (0..per_thread) |_| _ = target.fetchAdd(1, .monotonic);
        }
    };
    var value: Value(u64) = .init(0);
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Adder.run, .{&value});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u64, per_thread * thread_count), value.load(.acquire));
}
