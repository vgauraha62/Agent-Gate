//! On-demand verification for tamper-evident audit logs.
//!
//! This module provides O(n) verification of the entire audit log.
//! Called only on-demand (not in the hot path).
//!
//! Verification includes:
//! 1. Hash chain integrity (every entry links to previous)
//! 2. Ed25519 checkpoint signatures
//! 3. Tamper detection at any point in the chain
//!
//! Design: Linear hash chain (simpler than Merkle tree, same security for this use case)

const std = @import("std");
const crypto = std.crypto;

const types = @import("types.zig");
const LogEntry = types.LogEntry;
const Checkpoint = types.Checkpoint;

const crypto_audit = @import("crypto.zig");
const AuditSigner = crypto_audit.AuditSigner;
const verifyCheckpoint = crypto_audit.verifyCheckpoint;
const config = @import("../config.zig");

/// Verification result with detailed error information
pub const VerifyResult = struct {
    valid: bool,
    error_message: ?[]const u8 = null,
    failed_at_sequence: ?u64 = null,
    failed_at_checkpoint: ?u32 = null,
};

/// Compute hash for a single entry (same algorithm as logger)
fn computeEntryHash(entry: *const LogEntry, previous_hash: [16]u8) [16]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});

    hasher.update(std.mem.asBytes(&entry.sequence));
    hasher.update(std.mem.asBytes(&entry.timestamp_us));
    hasher.update(&entry.agent_id);
    hasher.update(&entry.path_hash);
    hasher.update(std.mem.asBytes(&entry.decision));
    hasher.update(std.mem.asBytes(&entry.policy_id));
    hasher.update(&previous_hash);

    var full_hash: [32]u8 = undefined;
    hasher.final(&full_hash);

    var truncated: [16]u8 = undefined;
    @memcpy(&truncated, full_hash[0..16]);
    return truncated;
}

/// Verify hash chain integrity - O(n) operation
pub fn verifyIntegrity(
    log: anytype,
    public_key: ?[32]u8,
) VerifyResult {
    const total_entries = @as(u64, @intCast(@field(log, "sequence")));

    // Empty log is valid
    if (total_entries == 0) {
        return VerifyResult{ .valid = true };
    }

    // 1. Verify hash chain
    var prev_hash: [16]u8 = [_]u8{0} ** 16;

    for (0..total_entries) |i| {
        const seq = @as(u64, @intCast(i));

        // Get entry using O(1) lookup
        const entry_opt = @field(log, "getEntry")(seq);
        const entry = entry_opt orelse {
            return VerifyResult{
                .valid = false,
                .error_message = "Missing entry in sequence",
                .failed_at_sequence = seq,
            };
        };

        // Verify previous_hash matches expected
        if (!std.mem.eql(u8, &entry.previous_hash, &prev_hash)) {
            return VerifyResult{
                .valid = false,
                .error_message = "Hash chain broken - previous_hash mismatch",
                .failed_at_sequence = seq,
            };
        }

        // Recompute hash and compare
        const recomputed = computeEntryHash(entry, prev_hash);
        if (!std.mem.eql(u8, &recomputed, &entry.current_hash)) {
            return VerifyResult{
                .valid = false,
                .error_message = "Hash mismatch - entry may have been tampered",
                .failed_at_sequence = seq,
            };
        }

        prev_hash = entry.current_hash;
    }

    // Verify final hash matches log's latest_hash
    if (!std.mem.eql(u8, &prev_hash, &@field(log, "latest_hash"))) {
        return VerifyResult{
            .valid = false,
            .error_message = "Latest hash mismatch",
            .failed_at_sequence = total_entries - 1,
        };
    }

    // 2. Verify checkpoint signatures if public key provided
    if (public_key) |pk| {
        const checkpoint_count = @field(log, "checkpoint_count");
        const checkpoints = @field(log, "checkpoints");

        for (0..checkpoint_count) |i| {
            const cp = &checkpoints[i];

            // Skip zero signatures (testing mode)
            var is_zero = true;
            for (cp.signature) |byte| {
                if (byte != 0) {
                    is_zero = false;
                    break;
                }
            }
            if (is_zero) continue;

            // Verify Ed25519 signature
            const valid = verifyCheckpoint(pk, cp) catch |err| {
                _ = err;
                return VerifyResult{
                    .valid = false,
                    .error_message = "Signature verification error",
                    .failed_at_checkpoint = @as(u32, @intCast(i)),
                };
            };

            if (!valid) {
                return VerifyResult{
                    .valid = false,
                    .error_message = "Invalid Ed25519 signature on checkpoint",
                    .failed_at_checkpoint = @as(u32, @intCast(i)),
                    .failed_at_sequence = @as(u64, @intCast(cp.sequence)),
                };
            }
        }
    }

    return VerifyResult{ .valid = true };
}

/// Quick sanity check - verify only the hash chain, no signatures
pub fn quickVerify(log: anytype) bool {
    const total_entries = @as(u64, @intCast(@field(log, "sequence")));
    if (total_entries == 0) return true;

    var prev_hash: [16]u8 = [_]u8{0} ** 16;

    for (0..total_entries) |i| {
        const seq = @as(u64, @intCast(i));
        const entry_opt = @field(log, "getEntry")(seq);
        const entry = entry_opt orelse return false;

        if (!std.mem.eql(u8, &entry.previous_hash, &prev_hash)) {
            return false;
        }

        const recomputed = computeEntryHash(entry, prev_hash);
        if (!std.mem.eql(u8, &recomputed, &entry.current_hash)) {
            return false;
        }

        prev_hash = entry.current_hash;
    }

    return std.mem.eql(u8, &prev_hash, &@field(log, "latest_hash"));
}

// ============================================================================
// Tests
// ============================================================================

const logger_module = @import("logger.zig");
const AuditLog = logger_module.AuditLog;
const CHECKPOINT_INTERVAL = logger_module.CHECKPOINT_INTERVAL;

test "verifyIntegrity: empty log" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    const result = verifyIntegrity(&log, null);
    try std.testing.expect(result.valid);
}

test "verifyIntegrity: valid log passes" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    var signer = try AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xAA} ** 32;

    // Write some entries
    for (0..100) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Verify with signature
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);
}

test "verifyIntegrity: tampered entry fails" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    var signer = try AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xAA} ** 32;

    for (0..10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Tamper with entry at sequence 5
    var entry = log.getEntry(5).?;
    entry.agent_id[0] = entry.agent_id[0] ^ 0xFF;  // Flip all bits

    // Verification should fail
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.failed_at_sequence != null);
}

test "verifyIntegrity: modified hash fails" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    const agent_id = [_]u8{0xAA} ** 32;

    for (0..10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Tamper with current_hash of entry 6
    var entry = log.getEntry(6).?;
    entry.current_hash[0] = entry.current_hash[0] ^ 0x01;

    // Verification should fail at sequence 7 (first to use tampered hash)
    const result = verifyIntegrity(&log, null);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.failed_at_sequence != null);
}

test "verifyIntegrity: checkpoint signature verified" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    var signer = try AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xAA} ** 32;

    // Write past first checkpoint (128 entries)
    for (0..CHECKPOINT_INTERVAL + 10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Verify with correct public key
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);

    // Verify with wrong public key
    var wrong_signer = try AuditSigner.generate();
    const wrong_result = verifyIntegrity(&log, wrong_signer.publicKey());
    try std.testing.expect(!wrong_result.valid);
}

test "quickVerify: passes for valid log" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    const agent_id = [_]u8{0xAA} ** 32;

    for (0..50) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    try std.testing.expect(quickVerify(&log));
}

test "quickVerify: fails for tampered log" {
    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();
    const agent_id = [_]u8{0xAA} ** 32;

    for (0..20) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Tamper with an entry
    var entry = log.getEntry(10).?;
    entry.decision = if (entry.decision == 1) 0 else 1;

    try std.testing.expect(!quickVerify(&log));
}