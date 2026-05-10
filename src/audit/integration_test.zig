//! Integration tests for tamper-evident audit logging system.
//!
//! These tests verify the complete audit logging pipeline:
//! - Log entries with hash chain
//! - Checkpoint creation and signing
//! - Tamper detection (any entry modification invalidates chain)
//! - Verification of intact and tampered logs

const std = @import("std");
const audit_logger = @import("audit/logger.zig");
const audit_crypto = @import("audit/crypto.zig");
const audit_verify = @import("audit/verify.zig");

const AuditLog = audit_logger.AuditLog;
const AuditSigner = audit_crypto.AuditSigner;
const verifyIntegrity = audit_verify.verifyIntegrity;
const quickVerify = audit_verify.quickVerify;
const Decision = @import("audit/types.zig").Decision;

test "Integration: Full audit pipeline" {
    // 1. Generate Ed25519 keypair for signing
    var signer = AuditSigner.generate();
    const public_key = signer.publicKey();

    // 2. Initialize audit log with signer
    var log = AuditLog.init();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xAB} ** 32;

    // 3. Log some entries
    log.log(agent_id, "/api/users", .allow, 1);
    log.log(agent_id, "/api/admin", .deny, 2);
    log.log(agent_id, "/api/health", .allow, 1);

    try std.testing.expectEqual(@as(u64, 3), log.entryCount());

    // 4. Verify intact log passes
    const result = verifyIntegrity(&log, public_key);
    try std.testing.expect(result.valid);
}

test "Integration: Tamper detection - modify entry data" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xCD} ** 32;

    // Log some entries
    for (0..10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Verify initially valid
    var result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);

    // Tamper with an entry (change decision from allow to deny)
    var entry = log.getEntry(5).?;
    entry.decision = if (entry.decision == 1) 0 else 1;
    _ = entry;

    // Verification should now fail
    result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.failed_at_sequence != null);
}

test "Integration: Tamper detection - modify hash" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xEF} ** 32;

    for (0..10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Verify initially valid
    var result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);

    // Tamper with the current_hash of entry 3
    // This will cause entry 4's previous_hash to not match
    var entry = log.getEntry(3).?;
    entry.current_hash[0] = entry.current_hash[0] ^ 0xFF;
    _ = entry;

    // Verification should fail
    result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(!result.valid);
}

test "Integration: Checkpoint signing every 128 entries" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0x12} ** 32;

    // Write exactly 128 entries - checkpoint at 128
    for (0..128) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Should have one checkpoint
    try std.testing.expectEqual(@as(u32, 1), log.checkpoint_count);

    // Verify with checkpoint
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);

    // Wrong key should fail
    var wrong_signer = AuditSigner.generate();
    const wrong_result = verifyIntegrity(&log, wrong_signer.publicKey());
    try std.testing.expect(!wrong_result.valid);
}

test "Integration: Quick verify without signatures" {
    var log = AuditLog.init();
    // No signer - testing quickVerify path

    const agent_id = [_]u8{0x34} ** 32;

    for (0..50) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Quick verify should pass
    try std.testing.expect(quickVerify(&log));

    // Tamper and quick verify should fail
    var entry = log.getEntry(25).?;
    entry.agent_id[0] = entry.agent_id[0] ^ 0x01;
    _ = entry;

    try std.testing.expect(!quickVerify(&log));
}

test "Integration: Ring buffer wrap preserves integrity" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0x56} ** 32;
    const BUFFER_SIZE = audit_logger.BUFFER_SIZE;

    // Write more than buffer size
    for (0..BUFFER_SIZE + 100) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Should have entries
    try std.testing.expect(log.entryCount() > BUFFER_SIZE);

    // Verify integrity still passes (old entries overwritten correctly)
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);
}

test "Integration: Hash chain continuity after wrap" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0x78} ** 32;
    const BUFFER_SIZE = audit_logger.BUFFER_SIZE;

    // Write enough to cause wrap
    for (0..BUFFER_SIZE + 50) |i| {
        log.log(agent_id, "/api/test", @as(Decision, if (i % 2 == 0) .allow else .deny), @as(u8, @intCast(i % 3)));
    }

    // Verify entries within buffer are accessible and valid
    const oldest_readable = @as(u64, @intCast(BUFFER_SIZE + 50)) - BUFFER_SIZE;
    const entry = log.getEntry(oldest_readable);
    try std.testing.expect(entry != null);

    // Full verification should pass
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);
}

test "Integration: Multiple checkpoints maintained" {
    var log = AuditLog.init();
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0x9A} ** 32;
    const CHECKPOINT_INTERVAL = audit_logger.CHECKPOINT_INTERVAL;

    // Write enough for multiple checkpoints (256 entries = 2 checkpoints)
    for (0..256) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Should have 2 checkpoints
    try std.testing.expect(log.checkpoint_count >= 2);

    // Verify with all checkpoints
    const result = verifyIntegrity(&log, signer.publicKey());
    try std.testing.expect(result.valid);

    // Get latest checkpoint
    const latest_cp = log.latestCheckpoint();
    try std.testing.expect(latest_cp != null);
    try std.testing.expectEqual(@as(u64, 255), latest_cp.?.sequence);
}

test "Integration: Public key export for auditors" {
    var signer = AuditSigner.generate();
    const public_key = signer.publicKey();

    // Public key should be 32 bytes
    try std.testing.expectEqual(@as(usize, 32), public_key.len);

    // Verify can be exported
    var log = AuditLog.init();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xBC} ** 32;
    log.log(agent_id, "/api/test", .allow, 1);

    const exported_key = log.publicKey();
    try std.testing.expect(exported_key != null);
    try std.testing.expectEqualSlices(u8, &public_key, &exported_key.?);
}

test "Integration: Empty log verification" {
    const log = AuditLog.init();

    // Empty log should pass verification
    const result = verifyIntegrity(&log, null);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u64, 0), log.entryCount());
}

test "Integration: logCompat backward compatibility" {
    var log = AuditLog.init();
    // No signer - using backward-compatible API

    // Use the string-based API for backward compatibility
    log.logCompat("agent-123", "/api/users", "GET", "allow", "1");

    try std.testing.expectEqual(@as(u64, 1), log.entryCount());

    const entry = log.getEntry(0);
    try std.testing.expect(entry != null);
}