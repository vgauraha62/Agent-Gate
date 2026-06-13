//! Secret - Zeroizing container for sensitive data.
//!
//! Securely stores sensitive data and zeroes memory before deallocation
//! to prevent secrets from persisting in memory.

const std = @import("std");

/// Container for sensitive data that zeroes memory on deinit.
pub const Secret = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new secret with a copy of the provided data.
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Self {
        const bytes = try allocator.dupe(u8, data);
        return Self{
            .bytes = bytes,
            .allocator = allocator,
        };
    }

    /// Get the secret bytes as a const slice.
    pub fn asBytes(self: *const Self) []const u8 {
        return self.bytes;
    }

    /// Get mutable access to the secret bytes.
    /// Use with caution - this bypasses immutability protection.
    pub fn asBytesMut(self: *Self) []u8 {
        return self.bytes;
    }

    /// Zeroize the secret memory. Call before deinit for extra security.
    pub fn zeroize(self: *Self) void {
        if (self.bytes.len > 0) {
            @memset(self.bytes, 0);
            // Prevent optimizer from removing the zeroization
            std.mem.doNotOptimizeAway(self.bytes);
        }
    }

    /// Deinitialize and zeroize the secret.
    pub fn deinit(self: *Self) void {
        self.zeroize();
        self.allocator.free(self.bytes);
    }
};

test "Secret basic usage" {
    const gpa = std.testing.allocator;

    var secret = try Secret.init(gpa, "super-secret-key");
    defer secret.deinit();

    const bytes = secret.asBytes();
    try std.testing.expectEqualSlices(u8, "super-secret-key", bytes);
}

test "Secret zeroization" {
    const gpa = std.testing.allocator;

    var secret = try Secret.init(gpa, "my-secret");

    // Verify initial value
    try std.testing.expectEqualSlices(u8, "my-secret", secret.asBytes());

    // Zeroize
    secret.zeroize();

    // Verify memory is zeroed
    const bytes = secret.asBytes();
    for (bytes) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    secret.deinit();
}

test "Secret empty secret" {
    const gpa = std.testing.allocator;

    var secret = try Secret.init(gpa, "");
    defer secret.deinit();

    try std.testing.expectEqual(@as(usize, 0), secret.asBytes().len);
}

test "Secret no memory leaks" {
    const gpa = std.testing.allocator;

    // Multiple secrets, verify isolation
    var secret1 = try Secret.init(gpa, "secret-1");
    var secret2 = try Secret.init(gpa, "secret-2");

    try std.testing.expect(!std.mem.eql(u8, secret1.asBytes(), secret2.asBytes()));

    secret1.deinit();
    secret2.deinit();
}

test "Secret with binary data" {
    const gpa = std.testing.allocator;

    const binary_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42 };
    var secret = try Secret.init(gpa, &binary_data);
    defer secret.deinit();

    try std.testing.expectEqualSlices(u8, &binary_data, secret.asBytes());
}


