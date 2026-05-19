//! Ultra-fast tamper-evident audit logger with zero heap allocations.
//!
//! Features:
//! - Ring buffer with power-of-two masking (O(1) operations)
//! - SHA-256 hash chain for integrity
//! - Ed25519 checkpoint signing every 128 entries
//! - No heap allocations in hot path (log() method)

const std = @import("std");
const crypto = std.crypto;

const types = @import("types.zig");
const LogEntry = types.LogEntry;
const Checkpoint = types.Checkpoint;
const Decision = types.Decision;
const truncateHash = types.truncateHash;
const fullHash = types.fullHash;

const crypto_audit = @import("crypto.zig");
const AuditSigner = crypto_audit.AuditSigner;

const config = @import("../config.zig");

// Backward compatibility alias
pub const AuditLogger = AuditLog;

pub const BUFFER_SIZE = 1024;  // Power of two for fast masking
pub const BUFFER_MASK = BUFFER_SIZE - 1;  // 0x3FF
pub const CHECKPOINT_INTERVAL = 128;

/// Ultra-fast audit log with zero heap allocations in hot path
pub const AuditLog = struct {
    // Ring buffer (pre-allocated at compile time)
    buffer: [BUFFER_SIZE]LogEntry = undefined,
    write_index: u32 = 0,       // Current write position (0-1023)
    sequence: u64 = 0,          // Monotonic counter (never wraps)
    latest_hash: [16]u8,        // Truncated hash of most recent entry

    // Checkpoint management
    checkpoints: [8]Checkpoint = undefined,
    checkpoint_count: u32 = 0,

    // Signing (optional - can be set later)
    signer: ?*AuditSigner = null,
    signer_initialized: bool = false,

    /// Zero hash for initial entry
    const ZERO_HASH: [16]u8 = [_]u8{0} ** 16;
    const ZERO_HASH_32: [32]u8 = [_]u8{0} ** 32;

    /// Initialize empty audit log (zero allocation)
    /// Accepts optional audit config for buffer size and timeout settings.
    /// Note: Internal buffer size is compile-time constant (BUFFER_SIZE = 1024).
    /// The config's buffer_size is used for validation/reference only.
    pub fn init(cfg: *const config.AuditConfig) AuditLog {
        _ = cfg; // Reserved for future use with dynamic buffer sizes
        return AuditLog{
            .buffer = undefined,
            .write_index = 0,
            .sequence = 0,
            .latest_hash = ZERO_HASH,
            .checkpoints = undefined,
            .checkpoint_count = 0,
            .signer = null,
            .signer_initialized = false,
        };
    }

    /// Fast inline index masking (no modulo!)
    inline fn maskIndex(idx: u32) u32 {
        return idx & BUFFER_MASK;
    }

/// Compute hash of a single entry (includes previous hash for chain)
fn computeEntryHash(entry: *const LogEntry, previous_hash: [16]u8) [16]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});

    // Hash core data (94 bytes before hash fields)
    hasher.update(std.mem.asBytes(&entry.sequence));
    hasher.update(std.mem.asBytes(&entry.timestamp_us));
    hasher.update(&entry.agent_id);
    hasher.update(&entry.path_hash);
    hasher.update(std.mem.asBytes(&entry.decision));
    hasher.update(std.mem.asBytes(&entry.policy_id));

    // Include previous hash to create chain
    hasher.update(&previous_hash);

    var full_hash: [32]u8 = undefined;
    hasher.final(&full_hash);

    // Return truncated to 16 bytes
    var truncated: [16]u8 = undefined;
    @memcpy(&truncated, full_hash[0..16]);
    return truncated;
}

/// Compute full 32-byte hash for checkpoint signing
fn computeCheckpointHash(entry: *const LogEntry) [32]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});

    hasher.update(std.mem.asBytes(&entry.sequence));
    hasher.update(std.mem.asBytes(&entry.timestamp_us));
    hasher.update(&entry.agent_id);
    hasher.update(&entry.path_hash);
    hasher.update(std.mem.asBytes(&entry.decision));
    hasher.update(std.mem.asBytes(&entry.policy_id));
    hasher.update(&entry.previous_hash);
    hasher.update(&entry.current_hash);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

/// Log an entry - ZERO ALLOCATIONS, CONSTANT TIME
    /// All parameters are fixed-size types, no heap involvement
    pub fn log(
        self: *AuditLog,
        agent_id: [32]u8,
        path: []const u8,
        decision: Decision,
        policy_id: u8,
    ) void {
        // Get current index
        const idx = maskIndex(self.write_index);

        // Compute path hash (16 bytes - done inline)
        const path_hash = truncateHash(path, 16);

        // Build entry with current state
        var entry = LogEntry{
            .sequence = self.sequence,
            .timestamp_us = @intCast(std.time.timestamp() * 1_000_000),
            .agent_id = agent_id,
            .path_hash = path_hash,
            .decision = @intFromEnum(decision),
            .policy_id = policy_id,
            .previous_hash = self.latest_hash,
            .current_hash = undefined,
        };

        // Compute current hash (includes previous hash)
        entry.current_hash = computeEntryHash(&entry, self.latest_hash);

        // Write to buffer (atomic-free - caller handles concurrency)
        self.buffer[idx] = entry;

        // Update state
        self.write_index = maskIndex(self.write_index + 1);
        self.latest_hash = entry.current_hash;
        self.sequence += 1;

        // Checkpoint signing every 128 entries
        if (self.sequence % CHECKPOINT_INTERVAL == 0) {
            self.createCheckpoint();
        }
    }

    /// Backward-compatible log method (for existing code using string params)
    /// Note: This internally converts strings to fixed-size fields
    pub fn logCompat(
        self: *AuditLog,
        agent_id_str: []const u8,
        path: []const u8,
        method: []const u8,  // Kept for API compatibility
        decision_str: []const u8,
        policy_id_str: []const u8,
    ) void {
        _ = method; // Kept for API compatibility, path_hash covers intent

        // Convert agent_id string to [32]u8 hash
        var agent_id: [32]u8 = undefined;
        const hash = truncateHash(agent_id_str, 32);
        @memcpy(&agent_id, &hash);

        // Convert decision string to enum
        const decision: Decision = if (std.mem.eql(u8, decision_str, "allow")) .allow else .deny;

        // Convert policy_id string to u8 (simple atoi)
        const policy_id: u8 = @intCast(std.fmt.parseUnsigned(u8, policy_id_str, 10) catch 0);

        // Call the main log method
        self.log(agent_id, path, decision, policy_id);
    }

    /// Create and sign a checkpoint (called every 128 entries)
    fn createCheckpoint(self: *AuditLog) void {
        // Get the last written entry (handle wrap-around)
        const last_idx = if (self.write_index == 0)
            BUFFER_MASK
        else
            maskIndex(self.write_index - 1);
        const last_entry = self.buffer[last_idx];

        // Compute full 32-byte hash for checkpoint
        const checkpoint_hash = computeCheckpointHash(&last_entry);

        // Create checkpoint
        var checkpoint = Checkpoint{
            .sequence = self.sequence - 1,
            .timestamp_us = @intCast(std.time.timestamp() * 1_000_000),
            .checkpoint_hash = checkpoint_hash,
            .signature = undefined,
        };

        // Sign with Ed25519 if signer is configured
        if (self.signer) |signer| {
            checkpoint.signature = signer.sign(checkpoint_hash) catch {
                // On signature failure, fill with zeros (testing mode)
                @memset(&checkpoint.signature, 0);
                return;
            };
        } else {
            // No signer configured - testing mode
            @memset(&checkpoint.signature, 0);
        }

        // Store checkpoint
        if (self.checkpoint_count < self.checkpoints.len) {
            self.checkpoints[self.checkpoint_count] = checkpoint;
            self.checkpoint_count += 1;
        } else {
            // Shift older checkpoints (rare - only after 8*128=1024 entries)
            for (1..self.checkpoints.len) |i| {
                self.checkpoints[i - 1] = self.checkpoints[i];
            }
            self.checkpoints[self.checkpoints.len - 1] = checkpoint;
        }
    }

    /// Enable Ed25519 signing
    pub fn enableSigning(self: *AuditLog, signer: *AuditSigner) void {
        self.signer = signer;
        self.signer_initialized = true;
    }

    /// Retrieve entry by sequence number (O(1))
    pub fn getEntry(self: *const AuditLog, sequence: u64) ?LogEntry {
        if (sequence >= self.sequence) return null;

        // For entries before wrap-around, direct index works
        if (sequence < BUFFER_SIZE) {
            const entry = self.buffer[@as(usize, @intCast(sequence))];
            if (entry.sequence != sequence) return null;
            return entry;
        }

        // After wrap-around, use modulo (wrapping is now part of sequence)
        const wrapped_idx = @as(u32, @intCast(sequence)) & BUFFER_MASK;
        const entry = self.buffer[wrapped_idx];
        if (entry.sequence != sequence) return null;
        return entry;
    }

    /// Get total entries written
    pub fn entryCount(self: *const AuditLog) u64 {
        return self.sequence;
    }

    /// Get checkpoint count
    pub fn checkpointCount(self: *const AuditLog) u32 {
        return self.checkpoint_count;
    }

    /// Get latest checkpoint
    pub fn latestCheckpoint(self: *const AuditLog) ?*const Checkpoint {
        if (self.checkpoint_count == 0) return null;
        return &self.checkpoints[self.checkpoint_count - 1];
    }

    /// Get latest public key from signer
    pub fn publicKey(self: *const AuditLog) ?[32]u8 {
        if (self.signer) |signer| {
            return signer.publicKey();
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AuditLog: init zero allocation" {
    const log = AuditLog.init();
    try std.testing.expectEqual(@as(u48, 0), log.sequence);
    try std.testing.expectEqual(@as(u32, 0), log.write_index);
}

test "AuditLog: log entry" {
    var log = AuditLog.init();

    const agent_id = [_]u8{0xAA} ** 32;

    // Log one entry
    log.log(agent_id, "/api/test", .allow, 1);

    try std.testing.expectEqual(@as(u48, 1), log.sequence);
    try std.testing.expect(log.latest_hash[0] != 0);  // Hash should be non-zero
}

test "AuditLog: hash chain continuity" {
    var log = AuditLog.init();

    const agent_id = [_]u8{0xAA} ** 32;

    log.log(agent_id, "/api/first", .allow, 1);
    const first_hash = log.latest_hash;

    log.log(agent_id, "/api/second", .deny, 2);

    // Get first entry and verify its hash matches what second entry uses
    const first_entry = log.getEntry(0);
    try std.testing.expect(first_entry != null);
    try std.testing.expectEqualSlices(u8, &first_entry.?.current_hash, &first_hash);
}

test "AuditLog: ring buffer wrap-around" {
    var log = AuditLog.init();
    const agent_id = [_]u8{0xAA} ** 32;

    // Write more than BUFFER_SIZE entries
    for (0..BUFFER_SIZE + 10) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    // Sequence continues increasing
    try std.testing.expect(log.sequence > BUFFER_SIZE);

    // Any entry within the buffer window should be retrievable
    // Test entry at sequence BUFFER_SIZE + 5
    const test_seq = BUFFER_SIZE + 5;
    const entry = log.getEntry(test_seq);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(test_seq, entry.?.sequence);
}

test "AuditLog: checkpoint creation at interval" {
    var log = AuditLog.init();

    // Signer for checkpoints
    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xAA} ** 32;

    // Write 129 entries (checkpoint at 128)
    for (0..129) |i| {
        log.log(agent_id, "/api/test", .allow, @as(u8, @intCast(i)));
    }

    // Should have at least one checkpoint
    try std.testing.expect(log.checkpoint_count >= 1);
}

test "AuditLog: getEntry O(1)" {
    var log = AuditLog.init();
    const agent_id = [_]u8{0xAA} ** 32;

    // Add some entries
    for (0..10) |i| {
        log.log(agent_id, "/api/test", .allow, @as(u8, @intCast(i)));
    }

    // All entries should be retrievable
    for (0..10) |i| {
        const entry = log.getEntry(@as(u48, @intCast(i)));
        try std.testing.expect(entry != null);
        try std.testing.expectEqual(@as(u48, @intCast(i)), entry.?.sequence);
    }
}

test "AuditLog: entryCount accurate" {
    var log = AuditLog.init();
    const agent_id = [_]u8{0xAA} ** 32;

    for (0..50) |_| {
        log.log(agent_id, "/api/test", .allow, 1);
    }

    try std.testing.expectEqual(@as(u48, 50), log.entryCount());
}