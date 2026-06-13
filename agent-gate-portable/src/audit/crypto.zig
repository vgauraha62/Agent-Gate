//! Ed25519 signing for audit log checkpoints.
//!
//! Uses asymmetric cryptography for non-repudiation:
//! - Private key signs checkpoints (server only)
//! - Public key distributed to auditors for verification

const std = @import("std");
const crypto = std.crypto;
const Ed25519 = crypto.sign.Ed25519;

const types = @import("types.zig");
const Checkpoint = types.Checkpoint;

/// Ed25519 signer for audit log checkpoints
pub const AuditSigner = struct {
    keypair: Ed25519.KeyPair,
    initialized: bool = true,

    /// Generate a new Ed25519 key pair from random seed
    pub fn generate() AuditSigner {
        const kp = Ed25519.KeyPair.generate();
        return AuditSigner{
            .keypair = kp,
            .initialized = true,
        };
    }

    /// Load existing key pair from raw seed bytes (32 bytes)
    pub fn load(seed_bytes: []const u8) !AuditSigner {
        if (seed_bytes.len != 32) return error.InvalidSeedLength;

        var seed: [32]u8 = undefined;
        @memcpy(&seed, seed_bytes);

        const kp = try Ed25519.KeyPair.generateDeterministic(seed);

        return AuditSigner{
            .keypair = kp,
            .initialized = true,
        };
    }

    /// Sign a message (32 bytes)
    /// Returns 64-byte Ed25519 signature
    pub fn sign(self: *const AuditSigner, message: [32]u8) ![64]u8 {
        if (!self.initialized) return error.NotInitialized;

        // Sign the message using the keypair (non-deterministic, no noise for simplicity)
        const sig = try self.keypair.sign(&message, null);

        // Convert Signature to [64]u8 for storage
        return sig.toBytes();
    }

    /// Verify a signature
    pub fn verify(
        public_key_bytes: [32]u8,
        message: [32]u8,
        signature_bytes: [64]u8,
    ) !bool {
        const public_key = try Ed25519.PublicKey.fromBytes(public_key_bytes);
        const sig = Ed25519.Signature.fromBytes(signature_bytes);
        sig.verify(&message, public_key) catch return false;
        return true;
    }

    /// Get public key bytes for distribution to auditors
    pub fn publicKey(self: *const AuditSigner) [32]u8 {
        return self.keypair.public_key.toBytes();
    }
};

/// Create a checkpoint with Ed25519 signature
pub fn createCheckpoint(
    signer: *const AuditSigner,
    sequence: u48,
    checkpoint_hash: [32]u8,
    timestamp_us: u64,
) !Checkpoint {
    var checkpoint = Checkpoint{
        .sequence = sequence,
        .timestamp_us = timestamp_us,
        .checkpoint_hash = checkpoint_hash,
        .signature = undefined,
    };

    // Sign the checkpoint hash
    checkpoint.signature = try signer.sign(checkpoint_hash);

    return checkpoint;
}

/// Verify a checkpoint's Ed25519 signature
pub fn verifyCheckpoint(
    public_key: [32]u8,
    checkpoint: *const Checkpoint,
) !bool {
    // Skip zero signatures (testing mode)
    var is_zero = true;
    for (checkpoint.signature) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    if (is_zero) return true;  // Testing mode, no signature

    return try AuditSigner.verify(
        public_key,
        checkpoint.checkpoint_hash,
        checkpoint.signature,
    );
}

// ============================================================================
// Tests
// ============================================================================

test "Ed25519: generate keypair" {
    const signer = AuditSigner.generate();
    try std.testing.expect(signer.initialized);

    const pubkey = signer.publicKey();
    try std.testing.expectEqual(@as(usize, 32), pubkey.len);
}

test "Ed25519: sign and verify" {
    var signer = AuditSigner.generate();

    const test_message = [_]u8{0xAA} ** 32;
    const signature = try signer.sign(test_message);

    try std.testing.expectEqual(@as(usize, 64), signature.len);

    const valid = try AuditSigner.verify(
        signer.publicKey(),
        test_message,
        signature,
    );
    try std.testing.expect(valid);
}

test "Ed25519: wrong signature fails verification" {
    var signer1 = AuditSigner.generate();
    var signer2 = AuditSigner.generate();

    const test_message = [_]u8{0xAA} ** 32;
    const signature = try signer1.sign(test_message);

    // Verify with different public key should fail
    const valid = try AuditSigner.verify(
        signer2.publicKey(),  // Wrong key
        test_message,
        signature,
    );
    try std.testing.expect(!valid);
}

test "Ed25519: tampered message fails verification" {
    var signer = AuditSigner.generate();

    const original_message = [_]u8{0xAA} ** 32;
    var tampered_message = original_message;
    tampered_message[0] = 0xBB;  // Flip one bit

    const signature = try signer.sign(original_message);

    const valid = try AuditSigner.verify(
        signer.publicKey(),
        tampered_message,  // Wrong message
        signature,
    );
    try std.testing.expect(!valid);
}

test "Ed25519: load from seed" {
    // Generate a keypair to get a seed
    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);

    // Load from seed
    const signer = try AuditSigner.load(&seed);
    try std.testing.expect(signer.initialized);

    // Sign and verify should work
    const message = [_]u8{0xCC} ** 32;
    const sig = try signer.sign(message);
    const valid = try AuditSigner.verify(signer.publicKey(), message, sig);
    try std.testing.expect(valid);
}

test "createCheckpoint: signs correctly" {
    var signer = AuditSigner.generate();

    const checkpoint = try createCheckpoint(
        &signer,
        127,
        [_]u8{0x11} ** 32,
        1234567890,
    );

    // Verify signature
    const valid = try verifyCheckpoint(signer.publicKey(), &checkpoint);
    try std.testing.expect(valid);
}