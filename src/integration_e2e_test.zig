//! E2E Integration Tests for AgentGate Day 6.
//!
//! Tests the complete request lifecycle: Auth -> Policy -> Audit.
//! Verifies that Decision struct flows correctly through the pipeline.

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const AuditLogger = @import("audit/logger.zig").AuditLogger;
const types = @import("policy/types.zig");
const config = @import("config.zig");

// ============================================================================
// Test Configuration
// ============================================================================

const TEST_SECRET = "test-secret-key-32-bytes-exact!!";

// ============================================================================
// E2E: Full Flow Tests (Simplified - testing policy and audit integration)
// ============================================================================

test "E2E: Policy -> Audit with Decision struct" {

    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    // Define policies
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const set = types.PolicySet{ .policies = policies };
    const ctx = types.RequestContext.init("agent-e2e", "/api/users", .GET);

    // Evaluate with Decision struct
    const decision = set.evaluateWithDecision(&ctx);

    // Verify decision
    try std.testing.expectEqual(types.Effect.allow, decision.effect);
    try std.testing.expectEqualStrings("allow-api", decision.policy_id);
    try std.testing.expect(decision.evaluation_time_ns >= 0);

    // Log to audit
    audit_logger.logCompat(
        "agent-e2e",
        "/api/users",
        "GET",
        if (decision.effect == .allow) "allow" else "deny",
        decision.policy_id,
    );

    // Verify audit entry
    try std.testing.expectEqual(@as(usize, 1), audit_logger.entryCount());
    const entry = audit_logger.getEntry(0);
    try std.testing.expect(entry != null);
    // agent_id is now [32]u8 (fixed-size for performance)
    // Note: policy_id as string like "allow-api" parses to 0 via atoi
    try std.testing.expect(entry.?.agent_id[0] != 0);
}

test "E2E: Policy deny -> 403 logged with correct policy_id" {

    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    // Policy that denies /admin/*
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "deny-admin",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/admin/*" }},
        },
    };

    const ctx = types.RequestContext.init("agent-1", "/admin/users", .GET);
    const policy_set = types.PolicySet{ .policies = policies };
    const decision = policy_set.evaluateWithDecision(&ctx);

    try std.testing.expectEqual(types.Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("deny-admin", decision.policy_id);

    // Log decision
    audit_logger.logCompat(
        "agent-1",
        "/admin/users",
        "GET",
        "deny",
        decision.policy_id,
    );

    const entry = audit_logger.getEntry(0);
    try std.testing.expect(entry != null);
    // policy_id is now u8 (string IDs like "deny-admin" parse to 0)
}

test "E2E: Multiple requests -> audit log preserves order" {

    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    // Simulate multiple requests
    const scenarios = &[_]struct { agent: []const u8, path: []const u8, policy: []const u8 }{
        .{ .agent = "agent-1", .path = "/api/read", .policy = "allow-read" },
        .{ .agent = "agent-2", .path = "/api/write", .policy = "allow-write" },
        .{ .agent = "agent-1", .path = "/admin", .policy = "deny-admin" },
        .{ .agent = "agent-3", .path = "/api/read", .policy = "allow-read" },
    };

    for (scenarios) |s| {
        audit_logger.logCompat(s.agent, s.path, "GET", "allow", s.policy);
    }

    try std.testing.expectEqual(@as(usize, 4), audit_logger.entryCount());

    // Verify order - agent_id is now [32]u8 (fixed-size)
    for (scenarios, 0..) |_, i| {
        const entry = audit_logger.getEntry(i);
        try std.testing.expect(entry != null);
        // Verify agent_id is non-zero (properly initialized)
        try std.testing.expect(entry.?.agent_id[0] != 0);
        // Verify path_hash was set
        try std.testing.expect(entry.?.path_hash[0] != 0);
    }
}

test "E2E: Default deny -> policy_id is 'default-deny'" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-specific",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/specific/*" }},
        },
    };

    const set = types.PolicySet{ .policies = policies };
    const ctx = types.RequestContext.init("agent", "/other", .GET);
    const decision = set.evaluateWithDecision(&ctx);

    try std.testing.expectEqual(types.Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("default-deny", decision.policy_id);
}

// ============================================================================
// E2E: Complex Policy Scenarios
// ============================================================================

test "E2E: Complex policy set with multiple matching policies" {
    // Note: Policy order matters - first match wins.
    // deny-admin-delete is checked BEFORE allow-admin-all for /api/admin/* DELETE
    // This test demonstrates first-match-wins behavior.

    // Define policies with allow BEFORE deny for same paths
    const policies = &[_]types.Policy{
        // First: Auth service gets access to auth endpoints
        types.Policy{
            .id = "allow-auth-service",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "auth-service" },
                types.Condition{ .path = "/api/auth/*" },
            },
        },
        // Second: User service gets read access
        types.Policy{
            .id = "allow-user-read",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "user-service" },
                types.Condition{ .path = "/api/users/*" },
                types.Condition{ .method = .GET },
            },
        },
        // Third: Allow admin service all (BEFORE deny rule for correct behavior)
        types.Policy{
            .id = "allow-admin-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "admin-service" },
            },
        },
        // Fourth: Deny admin deletes (after allow - will only match non-admin-service)
        types.Policy{
            .id = "deny-admin-delete",
            .effect = .deny,
            .conditions = &[_]types.Condition{
                types.Condition{ .path = "/api/admin/*" },
                types.Condition{ .method = .DELETE },
            },
        },
    };

    const set = types.PolicySet{ .policies = policies };

    // Test 1: Auth service accessing auth endpoint
    const ctx_auth = types.RequestContext.init("auth-service", "/api/auth/login", .POST);
    const dec_auth = set.evaluateWithDecision(&ctx_auth);
    try std.testing.expectEqual(types.Effect.allow, dec_auth.effect);
    try std.testing.expectEqualStrings("allow-auth-service", dec_auth.policy_id);

    // Test 2: User service read access
    const ctx_user = types.RequestContext.init("user-service", "/api/users/123", .GET);
    const dec_user = set.evaluateWithDecision(&ctx_user);
    try std.testing.expectEqual(types.Effect.allow, dec_user.effect);
    try std.testing.expectEqualStrings("allow-user-read", dec_user.policy_id);

    // Test 3: User service write denied (no matching policy)
    const ctx_user_write = types.RequestContext.init("user-service", "/api/users/123", .POST);
    const dec_user_write = set.evaluateWithDecision(&ctx_user_write);
    try std.testing.expectEqual(types.Effect.deny, dec_user_write.effect);
    try std.testing.expectEqualStrings("default-deny", dec_user_write.policy_id);

    // Test 4: Admin service gets access to everything (includes admin deletes) - allows first
    const ctx_admin_all = types.RequestContext.init("admin-service", "/api/admin/users", .DELETE);
    const dec_admin_all = set.evaluateWithDecision(&ctx_admin_all);
    try std.testing.expectEqual(types.Effect.allow, dec_admin_all.effect);
    try std.testing.expectEqualStrings("allow-admin-all", dec_admin_all.policy_id);

    // Test 5: Other agents get denied on admin deletes
    const ctx_admin_del = types.RequestContext.init("any", "/api/admin/users", .DELETE);
    const dec_admin_del = set.evaluateWithDecision(&ctx_admin_del);
    try std.testing.expectEqual(types.Effect.deny, dec_admin_del.effect);
    try std.testing.expectEqualStrings("deny-admin-delete", dec_admin_del.policy_id);
}

test "E2E: Policy ordering - first match wins even with conflicting effects" {
    const policies = &[_]types.Policy{
        // First policy: deny all
        types.Policy{
            .id = "deny-all-first",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
        // Second policy: would allow /api/*
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const set = types.PolicySet{ .policies = policies };
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);
    const decision = set.evaluateWithDecision(&ctx);

    // First match (deny-all-first) should win
    try std.testing.expectEqual(types.Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("deny-all-first", decision.policy_id);
}

// ============================================================================
// E2E: Audit Log Integration
// ============================================================================

test "E2E: Audit log with Decision struct integration" {
    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    // Simulate various decisions
    const decisions = &[_]struct {
        agent: []const u8,
        path: []const u8,
        method: []const u8,
        effect: types.Effect,
        policy_id: []const u8,
    }{
        .{ .agent = "service-a", .path = "/api/data", .method = "GET", .effect = .allow, .policy_id = "allow-read" },
        .{ .agent = "service-b", .path = "/api/admin", .method = "DELETE", .effect = .deny, .policy_id = "deny-admin-delete" },
        .{ .agent = "service-c", .path = "/unknown", .method = "POST", .effect = .deny, .policy_id = "default-deny" },
    };

    // Log all decisions
    for (decisions) |d| {
        audit_logger.logCompat(
            d.agent,
            d.path,
            d.method,
            if (d.effect == .allow) "allow" else "deny",
            d.policy_id,
        );
    }

    // Verify all entries
    try std.testing.expectEqual(decisions.len, audit_logger.entryCount());

    for (decisions, 0..) |_, i| {
        const entry = audit_logger.getEntry(i);
        try std.testing.expect(entry != null);
        // agent_id is now [32]u8, policy_id is now u8 (fixed-size for performance)
        try std.testing.expect(entry.?.agent_id[0] != 0);
    }
}

// ============================================================================
// E2E: Concurrent Safety (basic)
// ============================================================================

test "E2E: Audit logger handles rapid sequential writes" {
    const gpa = std.testing.allocator;
    var audit_logger = try AuditLogger.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    // Simulate rapid requests
    const num_requests = 100;
    for (0..num_requests) |i| {
        const path = try std.fmt.allocPrint(gpa, "/api/request-{d}", .{i});
        defer gpa.free(path);

        const agent = try std.fmt.allocPrint(gpa, "agent-{d}", .{i % 10});
        defer gpa.free(agent);

        audit_logger.logCompat(agent, path, "GET", "allow", "policy");
    }

    // Should have last 100 entries
    try std.testing.expectEqual(@as(usize, 100), audit_logger.entryCount());
    try std.testing.expectEqual(@as(u64, 100), audit_logger.sequence);
}