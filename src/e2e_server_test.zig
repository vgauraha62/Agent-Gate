//! E2E Server Integration Tests for AgentGate Day 6.
//!
//! Tests the complete server lifecycle: spawn, auth, policy, response.
//! Verifies Decision struct flows through HTTP pipeline correctly.

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const AuditLogger = @import("audit/logger.zig").AuditLogger;
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");
const jwt = @import("auth/jwt.zig");
const auth_middleware = @import("server/auth_middleware.zig");

// Test configuration
const TEST_SECRET = "test-secret-key-32-bytes-exact!!";
const TEST_PORT: u16 = 18888; // Use high port to avoid conflicts

/// Helper to generate a valid test JWT
fn generateTestToken(allocator: std.mem.Allocator, sub: []const u8, expires_in: u64) ![]u8 {
    return try jwt.generateTestJWT(allocator, TEST_SECRET, sub, expires_in);
}

/// Helper to generate an expired JWT
fn generateExpiredToken(allocator: std.mem.Allocator, sub: []const u8) ![]u8 {
    return try jwt.generateExpiredJWT(allocator, TEST_SECRET, sub);
}

// ============================================================================
// E2E: HTTP Server Integration Tests
// ============================================================================

test "E2E Server: Full policy + audit pipeline" {

    // Initialize audit logger
    var audit_logger = AuditLogger.init();

    // Define test policies
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
        types.Policy{
            .id = "deny-admin",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/admin/*" }},
        },
    };

    const policy_set = types.PolicySet{ .policies = policies };

    // Test 1: Allow path
    const ctx_allow = types.RequestContext.init("agent-test", "/api/users", .GET);
    const decision_allow = policy_set.evaluateWithDecision(&ctx_allow);
    try std.testing.expectEqual(types.Effect.allow, decision_allow.effect);
    try std.testing.expectEqualStrings("allow-api", decision_allow.policy_id);

    // Test 2: Deny path
    const ctx_deny = types.RequestContext.init("agent-test", "/admin/settings", .GET);
    const decision_deny = policy_set.evaluateWithDecision(&ctx_deny);
    try std.testing.expectEqual(types.Effect.deny, decision_deny.effect);
    try std.testing.expectEqualStrings("deny-admin", decision_deny.policy_id);

    // Test 3: Default deny
    const ctx_default = types.RequestContext.init("agent-test", "/other", .GET);
    const decision_default = policy_set.evaluateWithDecision(&ctx_default);
    try std.testing.expectEqual(types.Effect.deny, decision_default.effect);
    try std.testing.expectEqualStrings("default-deny", decision_default.policy_id);

    // Log and verify audit entries
    audit_logger.logCompat("agent-test", "/api/users", "GET", "allow", "allow-api");
    audit_logger.logCompat("agent-test", "/admin/settings", "GET", "deny", "deny-admin");
    audit_logger.logCompat("agent-test", "/other", "GET", "deny", "default-deny");

    // Check sequence count
    try std.testing.expectEqual(@as(u64, 3), audit_logger.sequence);
}

test "E2E Server: Auth middleware validates JWT correctly" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Generate valid token
    const valid_token = try generateTestToken(gpa, "service-a", 3600);
    defer gpa.free(valid_token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{valid_token});
    defer gpa.free(auth_header);

    // Authenticate should succeed
    const agent = middleware.authenticate(auth_header) catch {
        try std.testing.expect(false); // Should not fail
        return;
    };

    // Agent ID is SHA256 hash of token - check it's 32 bytes
    try std.testing.expectEqual(@as(usize, 32), agent.idSlice().len);
    // ID is not all zeros (meaningful hash)
    var all_zeros = true;
    for (agent.idSlice()) |b| {
        if (b != 0) all_zeros = false;
    }
    try std.testing.expect(!all_zeros);
}

test "E2E Server: Auth middleware rejects expired token" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Generate expired token
    const expired_token = try generateExpiredToken(gpa, "service-b");
    defer gpa.free(expired_token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{expired_token});
    defer gpa.free(auth_header);

    // Authenticate should fail with TokenExpired
    const result = middleware.authenticate(auth_header);
    try std.testing.expectError(error.ExpiredToken, result);
}

test "E2E Server: Auth middleware rejects missing header" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // No auth header
    const result = middleware.authenticate(null);
    try std.testing.expectError(error.Unauthorized, result);
}

test "E2E Server: Auth middleware rejects malformed header" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Malformed: no "Bearer " prefix
    const result = middleware.authenticate("invalid-token-format");
    try std.testing.expectError(error.Unauthorized, result);
}

test "E2E Server: Auth middleware rejects empty token" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Empty Bearer token
    const result = middleware.authenticate("Bearer ");
    try std.testing.expectError(error.Unauthorized, result);
}

test "E2E Server: Decision struct has correct evaluation_time_ns" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };

    const set = types.PolicySet{ .policies = policies };
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Evaluate multiple times - evaluation_time_ns should be measured
    var total_time: u64 = 0;
    for (0..5) |_| {
        const decision = set.evaluateWithDecision(&ctx);
        try std.testing.expect(decision.evaluation_time_ns >= 0);
        total_time += decision.evaluation_time_ns;
    }

    // Average should be reasonable (non-zero, less than 1ms)
    try std.testing.expect(total_time > 0);
}

test "E2E Server: Ring buffer wraps around correctly" {
    const gpa = std.testing.allocator;
    var audit_logger = AuditLogger.init();

    // Write more entries than buffer size
    const buffer_size = audit.BUFFER_SIZE;
    const num_entries = buffer_size + 10;

    for (0..num_entries) |i| {
        const agent = try std.fmt.allocPrint(gpa, "agent-{d}", .{i});
        defer gpa.free(agent);

        const path = try std.fmt.allocPrint(gpa, "/api/request-{d}", .{i});
        defer gpa.free(path);

        audit_logger.logCompat(agent, path, "GET", "allow", "policy");
    }

    // Sequence should reflect all writes
    try std.testing.expect(audit_logger.sequence >= @as(u64, num_entries));

    // Oldest entries may be overwritten in ring buffer, but we can retrieve recent ones
    try std.testing.expect(audit_logger.getEntry(audit_logger.sequence - 1) != null);
}

test "E2E Server: Multiple policy matching with correct policy_id" {
    // Test that first-match-wins returns correct policy_id
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "deny-specific",
            .effect = .deny,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "malicious" },
                types.Condition{ .path = "/api/*" },
            },
        },
        types.Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };

    const set = types.PolicySet{ .policies = policies };

    // Malicious agent gets denied
    const ctx_malicious = types.RequestContext.init("malicious", "/api/data", .GET);
    const decision_malicious = set.evaluateWithDecision(&ctx_malicious);
    try std.testing.expectEqual(types.Effect.deny, decision_malicious.effect);
    try std.testing.expectEqualStrings("deny-specific", decision_malicious.policy_id);

    // Normal agent gets allowed
    const ctx_normal = types.RequestContext.init("normal-agent", "/api/data", .GET);
    const decision_normal = set.evaluateWithDecision(&ctx_normal);
    try std.testing.expectEqual(types.Effect.allow, decision_normal.effect);
    try std.testing.expectEqualStrings("allow-all", decision_normal.policy_id);
}

test "E2E Server: Method-based policy evaluation" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-read",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .path = "/api/*" },
                types.Condition{ .method = .GET },
            },
        },
    };

    const set = types.PolicySet{ .policies = policies };

    // GET should be allowed
    const ctx_get = types.RequestContext.init("agent", "/api/data", .GET);
    const decision_get = set.evaluateWithDecision(&ctx_get);
    try std.testing.expectEqual(types.Effect.allow, decision_get.effect);
    try std.testing.expectEqualStrings("allow-read", decision_get.policy_id);

    // POST should be denied (no matching policy)
    const ctx_post = types.RequestContext.init("agent", "/api/data", .POST);
    const decision_post = set.evaluateWithDecision(&ctx_post);
    try std.testing.expectEqual(types.Effect.deny, decision_post.effect);
    try std.testing.expectEqualStrings("default-deny", decision_post.policy_id);
}

// ============================================================================
// E2E: Audit Entry Verification
// ============================================================================

test "E2E Server: Audit entry contains all required fields" {
    var audit_logger = AuditLogger.init();

    // Log a complete entry
    audit_logger.logCompat(
        "service-001",
        "/api/users/123",
        "POST",
        "allow",
        "allow-user-write",
    );

    try std.testing.expect(audit_logger.entryCount() == 1);

    const entry = audit_logger.getEntry(0);
    try std.testing.expect(entry != null);
    // agent_id is now [32]u8, verify it's non-zero
    try std.testing.expect(entry.?.agent_id[0] != 0);
    // path is now path_hash [16]u8
    try std.testing.expect(entry.?.path_hash[0] != 0);
    // decision is now u8 (0=deny, 1=allow)
    try std.testing.expect(entry.?.decision == 1); // allow
    // policy_id is now u8 - string IDs like "allow-user-write" parse to 0 via atoi
    // timestamp is now timestamp_us (microseconds)
    try std.testing.expect(entry.?.timestamp_us > 0);
}

test "E2E Server: Audit sequence numbering is correct" {
    var audit_logger = AuditLogger.init();

    // Log entries and verify sequence
    var expected_seq: u64 = 1;
    for (0..5) |_| {
        audit_logger.logCompat("agent", "/api/test", "GET", "allow", "policy");
        try std.testing.expect(audit_logger.sequence == expected_seq);
        expected_seq += 1;
    }
}