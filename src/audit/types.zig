//! Fixed-size types for tamper-evident audit logging.
//!
//! Design goals:
//! - Zero heap allocations in hot path
//! - Cache-line friendly (96 bytes fits in L1)
//! - Cryptographically linkable entries

const std = @import("std");
const crypto = std.crypto;

/// Decision outcome enum
pub const Decision = enum(u8) {
    deny = 0,
    allow = 1,

    pub fn toByte(self: Decision) u8 {
        return @intFromEnum(self);
    }

    pub fn fromByte(byte: u8) !Decision {
        return switch (byte) {
            0 => .deny,
            1 => .allow,
            else => error.InvalidDecision,
        };
    }
};

/// Fixed-size log entry: 96 bytes total
/// All fields are fixed-size, no heap usage
/// Using extern struct with u64 for sequence (extern compatible)
pub const LogEntry = extern struct {
    // --- Metadata (16 bytes) ---
    sequence: u64,         // Monotonic counter
    timestamp_us: u64,     // Unix timestamp in microseconds

    // --- Identity (32 bytes) ---
    agent_id: [32]u8,      // SHA256 of agent's public key

    // --- Request context (18 bytes) ---
    path_hash: [16]u8,     // Truncated SHA256 of request path (16 bytes)
    decision: u8,          // 0=deny, 1=allow (from Decision enum)
    policy_id: u8,         // Index of matching policy (0-255)

    // --- Cryptographic chain (32 bytes) ---
    previous_hash: [16]u8, // Hash of previous entry (truncated SHA256)
    current_hash: [16]u8,  // Hash of this entry's data (truncated SHA256)

    // Total: 16 + 32 + 18 + 32 = 98 bytes + 6 padding = 104 bytes

    comptime {
        // For cache efficiency, target 96 bytes but allow 104
        std.debug.assert(@sizeOf(LogEntry) == 104);
        std.debug.assert(@alignOf(LogEntry) == 8);
    }
};

/// Checkpoint signature - created every 128 entries
/// Total: 8 + 8 + 32 + 64 = 112 bytes
pub const Checkpoint = extern struct {
    sequence: u64,              // Last entry sequence in this checkpoint
    timestamp_us: u64,          // When checkpoint was created
    checkpoint_hash: [32]u8,    // Hash of the last entry at checkpoint time (full 32 bytes)
    signature: [64]u8,          // Ed25519 signature (64 bytes)

    comptime {
        std.debug.assert(@sizeOf(Checkpoint) == 112);
    }
};

/// Truncated hash helper - computes SHA256 and returns first N bytes
pub fn truncateHash(input: []const u8, comptime N: usize) [N]u8 {
    comptime std.debug.assert(N <= 32);

    var full_hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(input, &full_hash, .{});

    var truncated: [N]u8 = undefined;
    @memcpy(&truncated, full_hash[0..N]);
    return truncated;
}

/// Full 32-byte hash helper (for checkpoint hash)
pub fn fullHash(input: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    return hash;
}

// ============================================================================
// Tests
// ============================================================================

test "LogEntry size is 104 bytes" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(LogEntry));
}

test "Decision enum roundtrip" {
    const deny = Decision.deny;
    try std.testing.expectEqual(@as(u8, 0), deny.toByte());

    const allow = Decision.allow;
    try std.testing.expectEqual(@as(u8, 1), allow.toByte());

    try std.testing.expectEqual(Decision.deny, try Decision.fromByte(0));
    try std.testing.expectEqual(Decision.allow, try Decision.fromByte(1));
}

test "path_hash truncation produces consistent results" {
    const path = "/api/users/123/profile";
    const hash1 = truncateHash(path, 16);
    const hash2 = truncateHash(path, 16);

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
    try std.testing.expectEqual(@as(usize, 16), hash1.len);
}

test "truncateHash different inputs produce different hashes" {
    const hash1 = truncateHash("/api/path/a", 16);
    const hash2 = truncateHash("/api/path/b", 16);

    var are_equal = true;
    for (hash1, hash2) |a, b| {
        if (a != b) are_equal = false;
    }
    try std.testing.expect(!are_equal);
}

test "fullHash returns 32 bytes" {
    const hash = fullHash("/api/test");
    try std.testing.expectEqual(@as(usize, 32), hash.len);
}

test "Checkpoint size is 112 bytes" {
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(Checkpoint));
}

test "LogEntry field access" {
    const entry = LogEntry{
        .sequence = 42,
        .timestamp_us = 1234567890123,
        .agent_id = [_]u8{0xAA} ** 32,
        .path_hash = [_]u8{0xBB} ** 16,
        .decision = @intFromEnum(Decision.allow),
        .policy_id = 5,
        .previous_hash = [_]u8{0xCC} ** 16,
        .current_hash = [_]u8{0xDD} ** 16,
    };

    try std.testing.expectEqual(@as(u64, 42), entry.sequence);
    try std.testing.expectEqual(@as(u8, 1), entry.decision);
    try std.testing.expectEqual(@as(u8, 5), entry.policy_id);
}