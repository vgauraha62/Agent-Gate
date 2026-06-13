//! Coverage gap tests — exercises paths uncovered by existing unit tests.
//!
//! These tests live in a separate file (rather than inline in source files)
//! so the source files remain focused on per-function unit tests while
//! coverage-specific edge cases are collected here.
//!
//! Test step: zig build test-gaps

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const Agent = @import("agent.zig").Agent;
const PermissionSet = @import("agent.zig").PermissionSet;
const jwt = @import("auth/jwt.zig");
const config = @import("config.zig");
const parseEnvValue = @import("config.zig").parseEnvValue;

// ────────────────────────────────────────────────────────────────────────────
// C1 / H4: SecurityArena.alloc() alignment & remaining() (memory.zig)
// ────────────────────────────────────────────────────────────────────────────

test "SecurityArena remaining capacity" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    // After init, remaining should be full capacity
    try std.testing.expectEqual(@as(usize, 1024), arena.remaining());

    // After allocation, remaining decreases by aligned amount
    _ = try arena.alloc(100);
    try std.testing.expect(arena.remaining() < 1024);
    try std.testing.expectEqual(arena.buffer.len - arena.index, arena.remaining());

    // After reset, remaining returns to full
    arena.reset();
    try std.testing.expectEqual(@as(usize, 1024), arena.remaining());
}

test "SecurityArena alignment with non-aligned sizes" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 128);
    defer arena.deinit();

    // Start at index 0 (already 8-byte aligned).
    // Allocate 1 byte: index goes from 0 → 1 (no alignment needed)
    const slice1 = try arena.alloc(1);
    try std.testing.expect(slice1.len >= 1);
    try std.testing.expectEqual(@as(usize, 1), arena.index);

    // Allocate 3 bytes: index was 1, alignForward(1,8)=8, so start=8, end=11
    const slice2 = try arena.alloc(3);
    try std.testing.expect(slice2.len >= 3);
    try std.testing.expectEqual(@as(usize, 11), arena.index);

    // Allocate 7 bytes: index was 11, alignForward(11,8)=16, so start=16, end=23
    const slice3 = try arena.alloc(7);
    try std.testing.expect(slice3.len >= 7);
    try std.testing.expectEqual(@as(usize, 23), arena.index);

    // No overlap between slices
    try std.testing.expect(@intFromPtr(slice2.ptr) >= @intFromPtr(slice1.ptr) +% slice1.len);
    try std.testing.expect(@intFromPtr(slice3.ptr) >= @intFromPtr(slice2.ptr) +% slice2.len);
}

// ────────────────────────────────────────────────────────────────────────────
// H2: Secret.asBytesMut() (secret.zig)
// ────────────────────────────────────────────────────────────────────────────

test "Secret asBytesMut allows mutable access" {
    const gpa = std.testing.allocator;

    var secret = try Secret.init(gpa, "test-data");
    defer secret.deinit();

    const mut = secret.asBytesMut();
    mut[0] = 'X';

    try std.testing.expectEqualStrings("Xest-data", secret.asBytes());
}

// ────────────────────────────────────────────────────────────────────────────
// H3: PermissionSet.clear() (agent.zig)
// ────────────────────────────────────────────────────────────────────────────

test "PermissionSet set and clear" {
    var perms = PermissionSet{};

    // Set and clear a permission
    perms.set(.read_users);
    try std.testing.expect(perms.has(.read_users));

    perms.clear(.read_users);
    try std.testing.expect(!perms.has(.read_users));

    // Clearing a permission that was never set is a no-op
    perms.clear(.write_admin);
    try std.testing.expect(!perms.has(.write_admin));

    // Clear one permission while others remain
    perms.set(.read_users);
    perms.set(.write_users);
    perms.clear(.read_users);
    try std.testing.expect(!perms.has(.read_users));
    try std.testing.expect(perms.has(.write_users));
}

// ────────────────────────────────────────────────────────────────────────────
// C2: HMAC key > block size (jwt.zig)
// ────────────────────────────────────────────────────────────────────────────

test "HMAC-SHA256 with key > 64 bytes" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // 65-byte key forces the key-hashing path in hmacSha256 (block_size=64)
    const long_key = "a" ** 65;
    var secret = try Secret.init(gpa, long_key);
    defer secret.deinit();

    const token = try jwt.generateTestJWT(gpa, long_key, "agent-keytest", 3600);
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const valid = try parsed.verify(&secret, .{});
    try std.testing.expect(valid);
}

test "HMAC-SHA384 with key > 128 bytes" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // 129-byte key forces the key-hashing path in hmacSha384 (block_size=128)
    const long_key = "b" ** 129;
    var secret = try Secret.init(gpa, long_key);
    defer secret.deinit();

    const token = try jwt.generateTestJWT(gpa, long_key, "agent-keytest-384", 3600);
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const valid = try parsed.verify(&secret, .{});
    try std.testing.expect(valid);
}

// ────────────────────────────────────────────────────────────────────────────
// M6 unit: verifyTimeConstraints (jwt.zig)
// ────────────────────────────────────────────────────────────────────────────

test "verifyTimeConstraints: iat in past passes" {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .iat = now - 3600,
    };

    try jwt.verifyTimeConstraints(payload);
}

test "verifyTimeConstraints: iat in future fails" {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .iat = now + 3600,
    };

    try std.testing.expectError(error.TokenNotYetValid, jwt.verifyTimeConstraints(payload));
}

test "verifyTimeConstraints: nbf in past passes" {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .nbf = now - 3600,
    };

    try jwt.verifyTimeConstraints(payload);
}

test "verifyTimeConstraints: nbf in future fails" {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .nbf = now + 3600,
    };

    try std.testing.expectError(error.TokenNotYetValid, jwt.verifyTimeConstraints(payload));
}

// ────────────────────────────────────────────────────────────────────────────
// M6 unit: verifyAudience (jwt.zig)
// ────────────────────────────────────────────────────────────────────────────

test "verifyAudience: matching audience passes" {
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = "api-v1",
    };

    try jwt.verifyAudience(payload, "api-v1");
}

test "verifyAudience: mismatched audience fails" {
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = "api-v1",
    };

    try std.testing.expectError(error.InvalidAudience, jwt.verifyAudience(payload, "api-v2"));
}

test "verifyAudience: expected but token has none fails" {
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = null,
    };

    try std.testing.expectError(error.InvalidAudience, jwt.verifyAudience(payload, "api-v1"));
}

test "verifyAudience: no expected audience skips check" {
    const payload = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = null,
    };

    try jwt.verifyAudience(payload, null);

    const payload2 = jwt.Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = "some-audience",
    };
    try jwt.verifyAudience(payload2, null);
}

// ────────────────────────────────────────────────────────────────────────────
// M6 integration: full-pipeline aud/iat/nbf verification (jwt.zig)
// ────────────────────────────────────────────────────────────────────────────

test "JWT verify: token with aud, iat, nbf all valid passes" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "test-secret-key-for-full-claims-test";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    const now = @as(u64, @intCast(std.time.timestamp()));

    const token = try jwt.generateTokenWithClaims(gpa, secret_key, .{
        .subject = "agent-claims",
        .expires_at = now + 3600,
        .audience = "api-v1",
        .issued_at = now,
        .not_before = now,
    });
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const valid = try parsed.verify(&secret, .{ .expected_audience = "api-v1" });
    try std.testing.expect(valid);
}

test "JWT verify: audience mismatch fails" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "test-secret-key";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    const now = @as(u64, @intCast(std.time.timestamp()));

    const token = try jwt.generateTokenWithClaims(gpa, secret_key, .{
        .subject = "agent-aud-test",
        .expires_at = now + 3600,
        .audience = "api-v1",
    });
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const result = parsed.verify(&secret, .{ .expected_audience = "wrong-api" });
    try std.testing.expectError(error.InvalidAudience, result);
}

test "JWT verify: token with future nbf fails" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "test-secret-key";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    const now = @as(u64, @intCast(std.time.timestamp()));

    const token = try jwt.generateTokenWithClaims(gpa, secret_key, .{
        .subject = "agent-nbf-test",
        .expires_at = now + 3600,
        .not_before = now + 3600,
    });
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const result = parsed.verify(&secret, .{});
    try std.testing.expectError(error.TokenNotYetValid, result);
}

test "JWT verify: token with future iat fails" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "test-secret-key";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    const now = @as(u64, @intCast(std.time.timestamp()));

    const token = try jwt.generateTokenWithClaims(gpa, secret_key, .{
        .subject = "agent-iat-test",
        .expires_at = now + 3600,
        .issued_at = now + 3600,
    });
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const result = parsed.verify(&secret, .{});
    try std.testing.expectError(error.TokenNotYetValid, result);
}

test "JWT verify: token with all fields and no expected aud passes" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "test-secret-key";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    const now = @as(u64, @intCast(std.time.timestamp()));

    const token = try jwt.generateTokenWithClaims(gpa, secret_key, .{
        .subject = "agent-all-fields",
        .expires_at = now + 3600,
        .audience = "api-v1",
        .issued_at = now,
        .not_before = now,
    });
    defer gpa.free(token);

    var parsed = try jwt.JWT.parse(token, &arena);
    const valid = try parsed.verify(&secret, .{});
    try std.testing.expect(valid);
}

// ────────────────────────────────────────────────────────────────────────────
// M4: parseExternalPolicy enum parsing (config.zig)
// ────────────────────────────────────────────────────────────────────────────

test "Config parseExternalPolicy variants" {
    const strict = try parseEnvValue(config.ExternalPolicy, "strict");
    try std.testing.expect(strict == .strict);

    const permissive = try parseEnvValue(config.ExternalPolicy, "permissive");
    try std.testing.expect(permissive == .permissive);
}

// ────────────────────────────────────────────────────────────────────────────
// M5: Config.validate() timeout rejection (config.zig)
// ────────────────────────────────────────────────────────────────────────────

test "Config validate rejects audit_timeout >= request_timeout" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "valid-secret-key-32-bytes-exactly!!";
    cfg.audit.audit_timeout_ms = 5000;
    cfg.request.request_timeout_ms = 3000;

    try std.testing.expectError(error.AuditTimeoutExceedsRequestTimeout, cfg.validate());
}

// ────────────────────────────────────────────────────────────────────────────
// M3: AuditLog.checkpointCount() (audit/logger.zig)
// ────────────────────────────────────────────────────────────────────────────

test "AuditLog: checkpointCount public method" {
    const audit_logger = @import("audit/logger.zig");
    const audit_crypto = @import("audit/crypto.zig");
    const AuditLog = audit_logger.AuditLog;
    const AuditSigner = audit_crypto.AuditSigner;

    var log = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(u32, 0), log.checkpointCount());

    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xBB} ** 32;
    for (0..129) |i| {
        log.log(agent_id, "/api/test", .allow, @as(u8, @intCast(i)));
    }

    try std.testing.expect(log.checkpointCount() >= 1);
}

// ────────────────────────────────────────────────────────────────────────────
// M1: AuditLog checkpoint rotation (1024+ entries)
// ────────────────────────────────────────────────────────────────────────────

test "AuditLog: checkpoint rotation after 1024 entries" {
    const audit_logger = @import("audit/logger.zig");
    const audit_crypto = @import("audit/crypto.zig");
    const AuditLog = audit_logger.AuditLog;
    const AuditSigner = audit_crypto.AuditSigner;

    // Use large buffer so wrapping doesn't interfere with retrieval
    var log = try AuditLog.init(&config.AuditConfig{ .buffer_size = 2048 }, std.testing.allocator);
    defer log.deinit();

    var signer = AuditSigner.generate();
    log.enableSigning(&signer);

    const agent_id = [_]u8{0xCC} ** 32;

    // Write 1025 entries (triggers checkpoint rotation at 1024)
    for (0..1025) |i| {
        log.log(agent_id, "/api/test", .allow, @as(u8, @truncate(i)));
    }

    // At least 8 checkpoints should exist (1025/128 = 8.007 → 8 checkpoints)
    try std.testing.expect(log.checkpointCount() >= 8);

    // Entries should still be retrievable
    const entry = log.getEntry(0);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 0), entry.?.sequence);
}

// ────────────────────────────────────────────────────────────────────────────
// H1: Config.load() from file
// Note: Uses file I/O which is tricky in the Zig 0.15 test runner.
// If this test fails with a filesystem error on your platform, skip it.
// ────────────────────────────────────────────────────────────────────────────

test "Config.load from JSON file" {
    const tmp_path = "/tmp/agent_gate_gap_test_config.json";

    // Write JSON config
    {
        const file = std.fs.cwd().createFile(tmp_path, .{ .read = true }) catch |err| {
            // Skip test if we can't create temp file (e.g., read-only FS)
            std.debug.print("SKIP: couldn't create temp file: {}\n", .{err});
            return;
        };
        defer file.close();
        try file.writeAll(
            \\{"server":{"host":"127.0.0.1","port":9999}}
        );
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Use an arena so Config.load's file-buffer allocation is freed at end
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try config.Config.load(tmp_path, arena.allocator());

    try std.testing.expectEqual(@as(u16, 9999), cfg.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.server.host);
}
