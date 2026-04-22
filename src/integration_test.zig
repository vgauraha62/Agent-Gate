//! Integration tests for Day 2 components.
//!
//! Tests SecurityArena, Secret, and Agent working together.

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const Agent = @import("agent.zig").Agent;
const PermissionSet = @import("agent.zig").PermissionSet;

test "Integration: Arena holds multiple agents" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Create agents using arena allocator
    const agent_allocator = arena.allocator();

    // Simulate storing agent data in arena
    const id1 = try agent_allocator.alloc(u8, 32);
    @memcpy(id1, &[_]u8{1} ** 32);

    const id2 = try agent_allocator.alloc(u8, 32);
    @memcpy(id2, &[_]u8{2} ** 32);

    try std.testing.expectEqual(@as(usize, 64), id1.len + id2.len);
}

test "Integration: Secret in arena lifecycle" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    // Create secret with arena allocator
    var secret = try Secret.init(arena.allocator(), "arena-secret");
    defer secret.deinit();

    try std.testing.expectEqualSlices(u8, "arena-secret", secret.asBytes());

    // Reset arena - memory is zeroed for security
    // Note: This invalidates the secret's memory since it was allocated from arena
    arena.reset();

    // After reset, secret memory is zeroed (security behavior)
    // Verify that secret is now zeroed, not that it retained its value
    const bytes = secret.asBytes();
    for (bytes) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "Integration: Full lifecycle alloc-use-reset-dealloc" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();

    const alloc = arena.allocator();

    // Allocate multiple objects
    const data1 = try alloc.alloc(u8, 100);
    const data2 = try alloc.alloc(u8, 50);

    // Initialize with pattern
    @memset(data1, 0xAA);
    @memset(data2, 0xBB);

    // Verify
    try std.testing.expectEqual(@as(u8, 0xAA), data1[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), data2[0]);

    // Reset arena
    arena.reset();

    // Allocate again - should reuse space
    const data3 = try alloc.alloc(u8, 200);
    try std.testing.expect(data3.len >= 200);
}

test "Integration: no memory leaks across components" {
    const alloc = std.testing.allocator;

    // Arena
    var arena = try SecurityArena.init(alloc, 512);
    _ = try arena.alloc(100);
    arena.deinit();

    // Secret
    var secret = try Secret.init(alloc, "test-secret");
    secret.deinit();

    // Agent
    const id = [_]u8{0xFF} ** 32;
    _ = Agent.init(id, 12345, PermissionSet{});

    // std.testing.allocator will fail test if leaks detected
}

test "Integration: Multiple secrets with arena reset" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();

    const alloc = arena.allocator();

    // Create secret before reset
    var secret1 = try Secret.init(alloc, "before-reset");
    defer secret1.deinit();

    // Reset arena - this zeroes all memory for security
    arena.reset();

    // Secret1 memory is now zeroed (security behavior, not a bug)
    const bytes1 = secret1.asBytes();
    for (bytes1) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    // Create secret after reset
    var secret2 = try Secret.init(alloc, "after-reset");
    defer secret2.deinit();

    // Only secret2 should have valid data
    try std.testing.expectEqualSlices(u8, "after-reset", secret2.asBytes());
}

test "Integration: Agent permissions with arena" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    const alloc = arena.allocator();

    // Store agent metadata in arena
    const permissions_slice = try alloc.alloc(PermissionSet, 1);
    permissions_slice[0] = PermissionSet{};
    permissions_slice[0].set(.read_users);
    permissions_slice[0].set(.write_users);

    // Verify permissions
    try std.testing.expect(permissions_slice[0].has(.read_users));
    try std.testing.expect(permissions_slice[0].has(.write_users));
    try std.testing.expect(!permissions_slice[0].has(.read_admin));
}

test "Integration: Stress test - many alloc-reset cycles" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 512);
    defer arena.deinit();

    var cycle: usize = 0;
    while (cycle < 100) : (cycle += 1) {
        const alloc = arena.allocator();

        // Allocate varying sizes
        const size = (cycle % 50) + 1;
        const data = try alloc.alloc(u8, size);
        @memset(data, @intCast(cycle % 256));

        // Reset every other cycle
        if (cycle % 2 == 1) {
            arena.reset();
        }
    }
}

test "Integration: Secret zeroize survives arena reset" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    var secret = try Secret.init(arena.allocator(), "sensitive-data");

    // Verify initial value
    try std.testing.expectEqualSlices(u8, "sensitive-data", secret.asBytes());

    // Zeroize the secret
    secret.zeroize();

    // Verify zeroed
    for (secret.asBytes()) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    // Reset arena
    arena.reset();

    // Secret memory should still be zeroed
    for (secret.asBytes()) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    secret.deinit();
}
