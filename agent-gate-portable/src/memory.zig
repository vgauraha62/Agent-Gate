//! SecurityArena - Custom arena allocator for request-scoped memory.
//!
//! Provides fast bump allocation with reset capability. All allocations
//! are freed together on deinit or reset.

const std = @import("std");

/// Arena allocator for request-scoped memory management.
/// Uses a fixed buffer with bump allocation for O(1) allocs.
pub const SecurityArena = struct {
    buffer: []u8,
    index: usize,
    backing_allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new arena with the given capacity.
    /// The buffer is allocated on the heap using the provided allocator.
    pub fn init(arena_alloc: std.mem.Allocator, capacity: usize) !Self {
        const buffer = try arena_alloc.alloc(u8, capacity);
        return Self{
            .buffer = buffer,
            .index = 0,
            .backing_allocator = arena_alloc,
        };
    }

    /// Allocate memory from the arena.
    /// Returns error.OutOfMemory if the arena is exhausted.
    /// The returned slice may be larger than `size` due to 8-byte alignment padding.
    pub fn alloc(self: *Self, size: usize) ![]u8 {
        // Align the current position first, then bump
        const start = std.mem.alignForward(usize, self.index, 8);
        const end = start + size;
        if (end > self.buffer.len) {
            return error.OutOfMemory;
        }
        self.index = end;
        return self.buffer[start..end];
    }

    /// Reset the arena to its initial state.
    /// All prior allocations become invalid. Memory is zeroed for security.
    pub fn reset(self: *Self) void {
        // Zero out used portion for security
        @memset(self.buffer[0..self.index], 0);
        std.mem.doNotOptimizeAway(self.buffer[0..self.index]);
        self.index = 0;
    }

    /// Deinitialize the arena and free all memory.
    pub fn deinit(self: *Self) void {
        // Zero out before freeing
        @memset(self.buffer[0..self.index], 0);
        std.mem.doNotOptimizeAway(self.buffer[0..self.index]);
        self.backing_allocator.free(self.buffer);
        self.index = 0;
    }

    /// Get remaining capacity in bytes.
    pub fn remaining(self: *const Self) usize {
        return self.buffer.len - self.index;
    }

    /// Get allocator interface for use with std APIs.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ptr: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Convert Alignment enum to actual byte alignment (1 << byte_shift)
        const alignment: usize = @as(usize, 1) << @intFromEnum(ptr_align);

        // Align the current index to the required alignment
        const aligned_index = std.mem.alignForward(usize, self.index, alignment);

        if (aligned_index + len > self.buffer.len) {
            return null;
        }

        const start = aligned_index;
        self.index = aligned_index + len;
        return self.buffer.ptr + start;
    }

    fn resizeFn(
        ptr: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        _ = ptr;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        // Arena doesn't support resizing
        return false;
    }

    fn freeFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, _: usize) void {
        _ = ptr;
        _ = buf;
        _ = buf_align;
        // Arena frees everything at once on deinit/reset
    }

    fn remapFn(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = self;
        // Arena doesn't support remapping
        return null;
    }
};

test "SecurityArena basic allocation" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    // Allocate some memory
    const slice1 = try arena.alloc(100);
    try std.testing.expect(slice1.len >= 100);

    const slice2 = try arena.alloc(50);
    try std.testing.expect(slice2.len >= 50);

    // Slices should be contiguous
    try std.testing.expect(@intFromPtr(slice2.ptr) > @intFromPtr(slice1.ptr));
}

test "SecurityArena reset allows reuse" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 256);
    defer arena.deinit();

    // Fill the arena
    _ = try arena.alloc(200);

    // Reset
    arena.reset();

    // Should be able to allocate again
    const slice = try arena.alloc(100);
    try std.testing.expect(slice.len >= 100);
}

test "SecurityArena out of memory" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 64);
    defer arena.deinit();

    // Try to allocate more than capacity
    const result = arena.alloc(128);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "SecurityArena zero size allocation" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 64);
    defer arena.deinit();

    // Zero-size allocation should succeed
    const slice = try arena.alloc(0);
    try std.testing.expect(slice.len == 0);
}

test "SecurityArena no memory leaks" {
    const gpa = std.testing.allocator;

    // Multiple alloc-reset cycles
    var arena = try SecurityArena.init(gpa, 1024);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try arena.alloc(50);
        arena.reset();
    }

    arena.deinit();
    // GPA will report leaks if any
}
