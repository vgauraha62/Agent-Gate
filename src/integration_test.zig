//! Integration tests for AgentGate core components and full request flow.
//!
//! Tests SecurityArena, Secret, Agent lifecycle (Day 2) and full
//! Auth → Policy → Audit request flow (Day 12).

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const Agent = @import("agent.zig").Agent;
const PermissionSet = @import("agent.zig").PermissionSet;

const jwt = @import("auth/jwt.zig");
const auth_middleware = @import("server/auth_middleware.zig");
const types = @import("policy/types.zig");
const config = @import("config.zig");
const AuditLogger = @import("audit/logger.zig").AuditLogger;

const TEST_SECRET = "test-secret-key-for-integration-tests-!!";

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

// ============================================================================
// Day 12: Full Request-Flow Integration Tests (Auth → Policy → Audit)
// ============================================================================
//
// U1 — Valid path: Correctly signed, non-expired JWT with appropriate
// permissions allows a request. Simulates the full request lifecycle.
//
// U2 — Error paths: Invalid/malicious tokens are rejected with the correct
// HTTP-equivalent status code (401 for auth failures, 403 for policy denies).

/// Test helper: generate a valid Bearer token for the given subject.
fn generateBearerToken(allocator: std.mem.Allocator, sub: []const u8, expires_in: u64) ![]u8 {
    const token = try jwt.generateTestJWT(allocator, TEST_SECRET, sub, expires_in);
    defer allocator.free(token);
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

/// Test helper: generate an expired Bearer token.
fn generateExpiredBearerToken(allocator: std.mem.Allocator, sub: []const u8) ![]u8 {
    const token = try jwt.generateExpiredJWT(allocator, TEST_SECRET, sub);
    defer allocator.free(token);
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

// ---------------------------------------------------------------------------
// U1: Valid Path
// ---------------------------------------------------------------------------

test "U1: Valid JWT + allowed path → allow decision" {
    const gpa = std.testing.allocator;

    // Set up auth middleware
    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Set up policy: allow /api/* for any agent
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };
    const policy_set = types.PolicySet{ .policies = policies };

    // Generate valid JWT and authenticate
    const bearer = try generateBearerToken(gpa, "agent-alpha", 3600);
    defer gpa.free(bearer);

    const agent = try middleware.authenticate(bearer);
    _ = agent;

    // Evaluate policy for an allowed path
    const ctx = types.RequestContext.init("agent-alpha", "/api/users", .GET);
    const decision = policy_set.evaluateWithDecision(&ctx);

    try std.testing.expectEqual(types.Effect.allow, decision.effect);
    try std.testing.expectEqualStrings("allow-api", decision.policy_id);
}

test "U1: Valid JWT + multiple matching permissions → allow (first-match)" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Policies with more specific first, then general
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-specific",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .path = "/api/v2/*" },
                types.Condition{ .method = .GET },
            },
        },
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };
    const policy_set = types.PolicySet{ .policies = policies };

    const bearer = try generateBearerToken(gpa, "agent-beta", 3600);
    defer gpa.free(bearer);

    const agent = try middleware.authenticate(bearer);
    _ = agent;

    // Path matching the FIRST policy (more specific)
    const ctx_specific = types.RequestContext.init("agent-beta", "/api/v2/users", .GET);
    const decision_specific = policy_set.evaluateWithDecision(&ctx_specific);
    try std.testing.expectEqual(types.Effect.allow, decision_specific.effect);
    try std.testing.expectEqualStrings("allow-specific", decision_specific.policy_id);

    // Path matching the SECOND policy (general fallback)
    const ctx_general = types.RequestContext.init("agent-beta", "/api/v1/data", .GET);
    const decision_general = policy_set.evaluateWithDecision(&ctx_general);
    try std.testing.expectEqual(types.Effect.allow, decision_general.effect);
    try std.testing.expectEqualStrings("allow-api", decision_general.policy_id);
}

test "U1: Valid JWT + allowed path → audit entry created" {
    const gpa = std.testing.allocator;

    // Set up audit logger
    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, gpa);
    defer audit_logger.deinit();

    // Set up auth
    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Set up policy
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };
    const policy_set = types.PolicySet{ .policies = policies };

    // Authenticate
    const bearer = try generateBearerToken(gpa, "agent-gamma", 3600);
    defer gpa.free(bearer);

    const agent = try middleware.authenticate(bearer);
    _ = agent;

    // Evaluate policy
    const ctx = types.RequestContext.init("agent-gamma", "/api/data", .GET);
    const decision = policy_set.evaluateWithDecision(&ctx);
    try std.testing.expectEqual(types.Effect.allow, decision.effect);

    // Log to audit and verify
    audit_logger.logCompat("agent-gamma", "/api/data", "GET", "allow", "allow-all");
    try std.testing.expect(audit_logger.sequence >= 1);

    const entry = audit_logger.getEntry(audit_logger.sequence - 1);
    try std.testing.expect(entry != null);
    try std.testing.expect(entry.?.decision == 1); // allow
}

// ---------------------------------------------------------------------------
// U2: Error Paths
// ---------------------------------------------------------------------------

test "U2: Expired JWT → 401 Unauthorized" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    const bearer = try generateExpiredBearerToken(gpa, "agent-expired");
    defer gpa.free(bearer);

    const result = middleware.authenticate(bearer);
    try std.testing.expectError(error.ExpiredToken, result);
}

test "U2: Tampered signature → 401 Unauthorized" {
    const gpa = std.testing.allocator;

    // Generate a valid JWT, then corrupt its signature
    const token = try jwt.generateTestJWT(gpa, TEST_SECRET, "agent-tampered", 3600);
    defer gpa.free(token);

    // Corrupt the signature part (after the second dot)
    var dot_count: usize = 0;
    var tamper_pos: usize = 0;
    for (token, 0..) |c, i| {
        if (c == '.') {
            dot_count += 1;
            if (dot_count == 2) {
                tamper_pos = i + 1;
                break;
            }
        }
    }
    try std.testing.expect(tamper_pos > 0);

    // Flip a bit in the signature
    var tampered = try gpa.dupe(u8, token);
    defer gpa.free(tampered);
    tampered[tamper_pos] ^= 0xFF;

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{tampered});
    defer gpa.free(auth_header);

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    const result = middleware.authenticate(auth_header);
    try std.testing.expectError(error.InvalidToken, result);
}

test "U2: Wrong signing secret → 401 Unauthorized" {
    const gpa = std.testing.allocator;

    // Generate JWT with one secret, verify with another
    const wrong_secret = "completely-different-secret-key-for-testing!";
    const token = try jwt.generateTestJWT(gpa, wrong_secret, "agent-wrong-secret", 3600);
    defer gpa.free(token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    // Middleware initialized with DIFFERENT secret
    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    const result = middleware.authenticate(auth_header);
    try std.testing.expectError(error.WrongSecret, result);
}

test "U2: Valid JWT + denied path → 403 Forbidden" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Policy: allow /api/*, deny /admin/*
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

    // Authenticate with valid JWT
    const bearer = try generateBearerToken(gpa, "agent-delta", 3600);
    defer gpa.free(bearer);

    const agent = try middleware.authenticate(bearer);
    _ = agent;

    // Path that has an explicit deny policy
    const ctx_denied = types.RequestContext.init("agent-delta", "/admin/settings", .GET);
    const decision = policy_set.evaluateWithDecision(&ctx_denied);

    try std.testing.expectEqual(types.Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("deny-admin", decision.policy_id);
}

test "U2: Valid JWT + no matching policy → default deny (403)" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Single policy that only allows /api/*
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };
    const policy_set = types.PolicySet{ .policies = policies };

    const bearer = try generateBearerToken(gpa, "agent-epsilon", 3600);
    defer gpa.free(bearer);

    const agent = try middleware.authenticate(bearer);
    _ = agent;

    // Path that doesn't match any policy → default-deny
    const ctx_nomatch = types.RequestContext.init("agent-epsilon", "/other/path", .GET);
    const decision = policy_set.evaluateWithDecision(&ctx_nomatch);

    try std.testing.expectEqual(types.Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("default-deny", decision.policy_id);
}

test "U2: Missing auth header → 401 Unauthorized" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    const result = middleware.authenticate(null);
    try std.testing.expectError(error.Unauthorized, result);
}

test "U2: Malformed Bearer token → 401 Unauthorized" {
    const gpa = std.testing.allocator;

    var middleware = try auth_middleware.AuthMiddleware.init(gpa, TEST_SECRET);
    defer middleware.deinit();

    // Non-Bearer formatted token
    const result = middleware.authenticate("Basic dXNlcjpwYXNz");
    try std.testing.expectError(error.Unauthorized, result);
}

test "U2: Oversized JWT payload → graceful error (no panic)" {
    const gpa = std.testing.allocator;

    // Generate a JWT with a very long subject (~300 bytes) to exercise the
    // HMAC buffer path. This would have caused a stack buffer overflow before
    // the HMAC hotfix — now it should handle gracefully.

    // Build a long subject string at runtime
    const long_sub = try gpa.alloc(u8, 280);
    defer gpa.free(long_sub);
    @memset(long_sub, 'B');

    const token = try jwt.generateTestJWT(gpa, TEST_SECRET, long_sub, 3600);
    defer gpa.free(token);

    // Parse and verify — should NOT panic even with large payload
    var arena = try SecurityArena.init(gpa, 8192);
    defer arena.deinit();

    var secret = try Secret.init(gpa, TEST_SECRET);
    defer secret.deinit();

    const parsed = try jwt.JWT.parse(token, &arena);

    // Any result (success or error) is fine — we just didn't crash
    if (parsed.verify(&secret, .{})) |_| {} else |_| {}
}
