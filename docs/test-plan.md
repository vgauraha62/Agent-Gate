# AgentGate Day 6: Test Plan

## Overview

This document outlines the comprehensive testing strategy for AgentGate Day 6 implementation, covering:
1. Unit tests for individual components
2. Integration tests for E2E flows
3. Performance and stress tests

---

## Part 1: Unit Tests

### 1.1 Error Taxonomy Tests (`src/errors.zig`)

**Purpose:** Validate unified error enum and HTTP status mapping.

```zig
// Test cases to implement:
test "toHttpStatus: auth errors map to 401" {
    try std.testing.expectEqual(401, toHttpStatus(error.Unauthorized));
    try std.testing.expectEqual(401, toHttpStatus(error.TokenExpired));
    try std.testing.expectEqual(401, toHttpStatus(error.InvalidSignature));
}

test "toHttpStatus: policy errors map to 403" {
    try std.testing.expectEqual(403, toHttpStatus(error.PolicyDenied));
    try std.testing.expectEqual(403, toHttpStatus(error.PolicyEvaluationFailed));
}

test "toHttpStatus: client errors map to 400" {
    try std.testing.expectEqual(400, toHttpStatus(error.MalformedRequest));
    try std.testing.expectEqual(400, toHttpStatus(error.InvalidBody));
}

test "toHttpStatus: server errors map to 500" {
    try std.testing.expectEqual(500, toHttpStatus(error.InternalError));
    try std.testing.expectEqual(500, toHttpStatus(error.AllocatorFailed));
}

test "toHttpStatus: timeout errors map to 504" {
    try std.testing.expectEqual(504, toHttpStatus(error.PolicyTimeout));
    try std.testing.expectEqual(504, toHttpStatus(error.AuthTimeout));
}
```

**File:** `src/errors.zig`

---

### 1.2 Config Tests (`src/config.zig`)

**Purpose:** Validate JWT secret configuration and validation.

```zig
// Test cases to implement:
test "Config: jwt_secret minimum length validation (32 bytes)" {
    // Valid: exactly 32 bytes
    try std.testing.expect(minSecretLengthOk("32-byte-secret-here-exactly!32bytes"));
    
    // Valid: more than 32 bytes
    try std.testing.expect(minSecretLengthOk("this-is-a-very-long-secret-that-exceeds-32-bytes"));
    
    // Invalid: less than 32 bytes
    try std.testing.expect(!minSecretLengthOk("too-short"));
}

test "Config: parse timeout values from JSON" {
    const json = 
        \\{"server": {"request_timeout_ms": 5000}, "auth": {"jwt_secret": "x"*32}}
    ;
    const config = try Config.parse(json);
    try std.testing.expectEqual(@as(u64, 5000), config.server.request_timeout_ms);
}

test "Config: default timeout values" {
    const config = Config.default();
    try std.testing.expectEqual(@as(u32, 5000), config.server.request_timeout_ms);    try std.testing.expectEqual(@as(u32, 100), config.auth.auth_timeout_ms);
    try std.testing.expectEqual(@as(u32, 50), config.policy.policy_timeout_ms);
}
```

**File:** `src/config_test.zig`

---

### 1.3 Policy Decision Struct Tests (`src/policy/types.zig`)

**Purpose:** Validate the new `Decision` struct with policy attribution.

```zig
// Test cases to implement:
test "Decision: struct creation with policy attribution" {
    const decision = Decision{
        .effect = .allow,
        .policy_id = "policy-001",
        .timestamp = 1234567890,
        .evaluation_time_ns = 1500,
    };
    
    try std.testing.expectEqual(Effect.allow, decision.effect);
    try std.testing.expectEqualStrings("policy-001", decision.policy_id);
}

test "Decision: default deny has default policy_id" {
    const decision = Decision.defaultDeny();
    try std.testing.expectEqual(Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("default-deny", decision.policy_id);
}

test "PolicySet: evaluate returns Decision with policy_id" {
    const policies = &[_]Policy{
        Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
        },
    };
    
    const ctx = RequestContext.init("agent", "/api/test", .GET);
    const decision = PolicySet.evaluateDecision(policies, &ctx);
    
    try std.testing.expectEqual(Effect.allow, decision.effect);
    try std.testing.expectEqualStrings("allow-api", decision.policy_id);
}

test "PolicySet: no match returns default-deny policy_id" {
    const policies = &[_]Policy{
        Policy{
            .id = "allow-specific",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/specific/*" }},
        },
    };
    
    const ctx = RequestContext.init("agent", "/other", .GET);
    const decision = PolicySet.evaluateDecision(policies, &ctx);
    
    try std.testing.expectEqual(Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("default-deny", decision.policy_id);
}

test "PolicySet: first-match-wins with policy attribution" {
    const policies = &[_]Policy{
        Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]Condition{Condition{ .path = "*" }},
        },
        Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
        },
    };
    
    const ctx = RequestContext.init("agent", "/api/test", .GET);
    const decision = PolicySet.evaluateDecision(policies, &ctx);
    
    // First match (deny-all) wins
    try std.testing.expectEqual(Effect.deny, decision.effect);
    try std.testing.expectEqualStrings("deny-all", decision.policy_id);
}
```

**File:** `src/policy/decision_test.zig`

---

### 1.4 JWT Tests (`src/auth/jwt.zig`)

**Existing tests:** Comprehensive tests already exist (864 lines).

**Additional tests to add:**

```zig
test "JWT: generateTestJWT creates valid tokens" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();
    
    const secret = "test-secret-key-for-jwt-generation";
    var sec = try Secret.init(gpa, secret);
    defer sec.deinit();
    
    // Generate token valid for 1 hour
    const token = try generateTestJWT(gpa, secret, "agent-test", 3600);
    defer gpa.free(token);
    
    // Verify token parses correctly
    var jwt = try JWT.parse(token, &arena);
    try std.testing.expectEqualStrings("agent-test", jwt.payload.sub);
}

test "JWT: generateExpiredJWT creates expired tokens" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();
    
    const secret = "test-secret";
    const token = try generateExpiredJWT(gpa, secret, "agent-test");
    defer gpa.free(token);
    
    var jwt = try JWT.parse(token, &arena);
    const result = jwt.verify(&secret);
    try std.testing.expectError(error.TokenExpired, result);
}
```

---

### 1.5 Audit Logger Tests (`src/audit/logger.zig`)

**Existing tests:** Basic tests for ring buffer exist.

**Additional tests to add:**

```zig
test "AuditLogger: ring buffer wrap-around" {
    const gpa = std.testing.allocator;
    var logger = AuditLogger.init(gpa);
    defer logger.deinit();
    
    // Fill buffer beyond capacity
    for (0..MAX_ENTRIES + 100) |i| {
        const path = try std.fmt.allocPrint(gpa, "/api/request-{d}", .{i});
        defer gpa.free(path);
        try logger.log("agent-1", path, "GET", "allow", "policy-001");
    }
    
    // Should only have MAX_ENTRIES
    try std.testing.expectEqual(MAX_ENTRIES, logger.entryCount());
}

test "AuditLogger: getEntry returns correct order after wrap" {
    const gpa = std.testing.allocator;
    var logger = AuditLogger.init(gpa);
    defer logger.deinit();
    
    // Log more than capacity
    for (0..MAX_ENTRIES + 50) |i| {
        const path = try std.fmt.allocPrint(gpa, "/path-{d}", .{i});
        defer gpa.free(path);
        try logger.log("agent-1", path, "GET", "allow", "policy");
    }
    
    // Most recent entries should be retrievable
    const last_entry = logger.getEntry(logger.entryCount() - 1);
    try std.testing.expect(last_entry != null);
}

test "AuditLogger: sequence number increments correctly" {
    const gpa = std.testing.allocator;
    var logger = AuditLogger.init(gpa);
    defer logger.deinit();
    
    try logger.log("a1", "/p1", "GET", "allow", "p1");
    try logger.log("a2", "/p2", "POST", "deny", "p2");
    try logger.log("a3", "/p3", "PUT", "allow", "p3");
    
    try std.testing.expectEqual(@as(u64, 3), logger.sequence);
}

test "AuditLogger: exportJSON includes policy_id" {
    const gpa = std.testing.allocator;
    var logger = AuditLogger.init(gpa);
    defer logger.deinit();
    
    try logger.log("agent-1", "/api/test", "GET", "allow", "allow-policy-001");
    
    const json = try logger.exportJSON();
    defer gpa.free(json);
    
    // JSON should contain policy_id
    try std.testing.expect(std.mem.indexOf(u8, json, "allow-policy-001") != null);
}
```

---

### 1.6 HTTP Server Tests (`src/server/http.zig`)

**Existing tests:** Basic parsing tests exist.

**Additional tests to add:**

```zig
test "Server: parseCheckRequest extracts path and method" {
    const gpa = std.testing.allocator;
    var logger = audit.AuditLogger.init(gpa);
    defer logger.deinit();
    
    var server = Server.init(gpa, 8080, &logger, &[_]types.Policy{}, "secret", .async_epoll);
    
    const check = server.parseCheckRequest(`{"path":"/api/users","method":"POST"}`);
    try std.testing.expectEqualStrings("/api/users", check.path);
    try std.testing.expectEqualStrings("POST", check.method);
}

test "Server: parseCheckRequest handles empty body" {
    const gpa = std.testing.allocator;
    var logger = audit.AuditLogger.init(gpa);
    defer logger.deinit();
    
    var server = Server.init(gpa, 8080, &logger, &[_]types.Policy{}, "secret", .sync_posix);
    
    const check = server.parseCheckRequest("");
    try std.testing.expectEqualStrings("/", check.path);
    try std.testing.expectEqualStrings("GET", check.method);
}

test "Server: error response maps to HTTP status" {
    const gpa = std.testing.allocator;
    var logger = audit.AuditLogger.init(gpa);
    defer logger.deinit();
    
    var server = Server.init(gpa, 8080, &logger, &[_]types.Policy{}, "secret", .async_epoll);
    
    // Verify statusText mapping
    try std.testing.expectEqualStrings("OK", server.statusText(.ok));
    try std.testing.expectEqualStrings("Unauthorized", server.statusText(.unauthorized));
    try std.testing.expectEqualStrings("Forbidden", server.statusText(.forbidden));
}
```

---

## Part 2: Integration Tests

### 2.1 Auth -> Policy -> Audit E2E Flow

**Purpose:** Validate the complete request lifecycle from JWT to audit log.

```zig
// File: src/integration_e2e_test.zig

const std = @import("std");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;
const Agent = @import("agent.zig").Agent;
const AuditLogger = @import("audit/logger.zig").AuditLogger;
const jwt = @import("auth/jwt.zig");
const types = @import("policy/types.zig");
const engine = @import("policy/engine.zig");

test "E2E: Full flow - Auth -> Policy -> Audit" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();
    
    // Setup
    const secret_key = "test-secret-key-for-integration";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();
    
    var audit_logger = AuditLogger.init(gpa);
    defer audit_logger.deinit();
    
    // Generate valid JWT
    const token = try generateTestJWT(gpa, secret_key, "agent-e2e", 3600);
    defer gpa.free(token);
    
    // Parse and verify JWT
    var parsed = try jwt.JWT.parse(token, &arena);
    const valid = try parsed.verify(&secret);
    try std.testing.expect(valid);
    
    // Build request context
    const ctx = types.RequestContext.init(parsed.payload.sub, "/api/users", .GET);
    
    // Evaluate policy
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };
    const decision = engine.evaluate(policies, &ctx);
    
    // Log to audit
    try audit_logger.log(
        parsed.payload.sub,
        "/api/users",
        "GET",
        if (decision == .allow) "allow" else "deny",
        "allow-api",
    );
    
    // Verify audit entry
    try std.testing.expectEqual(@as(usize, 1), audit_logger.entryCount());
    const entry = audit_logger.getEntry(0);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("agent-e2e", entry.?.agent_id);
    try std.testing.expectEqualStrings("allow-api", entry.?.policy_id);
}

test "E2E: Auth failure -> 401 logged" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();
    
    const secret_key = "test-secret";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();
    
    var audit_logger = AuditLogger.init(gpa);
    defer audit_logger.deinit();
    
    // Generate expired token
    const token = try generateExpiredJWT(gpa, secret_key, "agent-test");
    defer gpa.free(token);
    
    // Parse token
    var parsed = jwt.JWT.parse(token, &arena) catch return;
    const verify_result = parsed.verify(&secret);
    
    // Should fail with TokenExpired
    try std.testing.expectError(jwt.JwtError.TokenExpired, verify_result);
    
    // Log auth failure (even failed auth should be logged for security)
    try audit_logger.log(
        "unknown",
        "/api/protected",
        "GET",
        "deny",
        "auth-failure",
    );
    
    try std.testing.expectEqual(@as(usize, 1), audit_logger.entryCount());
}

test "E2E: Policy deny -> 403 logged with correct policy_id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();
    
    var audit_logger = AuditLogger.init(gpa);
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
    const decision = engine.evaluate(policies, &ctx);
    
    try std.testing.expectEqual(types.Effect.deny, decision);
    
    // Log decision
    try audit_logger.log(
        "agent-1",
        "/admin/users",
        "GET",
        "deny",
        "deny-admin",
    );
    
    const entry = audit_logger.getEntry(0);
    try std.testing.expectEqualStrings("deny-admin", entry.?.policy_id);
}
```

---

### 2.2 Decision Struct Integration

```zig
test "E2E: Decision struct flows through entire pipeline" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();
    
    var secret = try Secret.init(gpa, "integration-secret-key-12345678901234");
    defer secret.deinit();
    
    var audit_logger = AuditLogger.init(gpa);
    defer audit_logger.deinit();
    
    // Generate valid token
    const token = try generateTestJWT(gpa, "integration-secret-key-12345678901234", "service-a", 3600);
    defer gpa.free(token);
    
    // Parse and verify
    var parsed = try jwt.JWT.parse(token, &arena);
    try std.testing.expect(try parsed.verify(&secret));
    
    // Build context
    const ctx = types.RequestContext.init(parsed.payload.sub, "/api/data", .POST);
    
    // Evaluate with policies
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-service-a",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "service-a" },
                types.Condition{ .path = "/api/*" },
                types.Condition{ .method = .POST },
            },
        },
        types.Policy{
            .id = "allow-all-read",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .path = "/api/*" },
                types.Condition{ .method = .GET },
            },
        },
    };
    
    const decision = engine.evaluate(policies, &ctx);
    
    // Decision should be allow from "allow-service-a" (first match)
    try std.testing.expectEqual(types.Effect.allow, decision);
    
    // Log with decision
    try audit_logger.log(
        parsed.payload.sub,
        "/api/data",
        "POST",
        "allow",
        "allow-service-a",
    );
    
    // Verify
    const entry = audit_logger.getEntry(0);
    try std.testing.expectEqualStrings("service-a", entry.?.agent_id);
    try std.testing.expectEqualStrings("allow-service-a", entry.?.policy_id);
}
```

---

### 2.3 Concurrent Request Test

```zig
test "E2E: Concurrent requests don't corrupt audit log" {
    const gpa = std.testing.allocator;
    
    var audit_logger = AuditLogger.init(gpa);
    defer audit_logger.deinit();
    
    const num_threads = 10;
    const requests_per_thread = 10;
    var threads: [num_threads]std.Thread = undefined;
    
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(id: usize) void {
                for (0..requests_per_thread) |j| {
                    const path = std.fmt.allocPrint(gpa, "/api/req-{d}-{d}", .{ id, j }) catch return;
                    defer gpa.free(path);
                    
                    const agent = std.fmt.allocPrint(gpa, "agent-{d}", .{id}) catch return;
                    defer gpa.free(agent);
                    
                    audit_logger.log(agent, path, "GET", "allow", "policy") catch return;
                }
            }
        }.run, .{i});
    }
    
    for (threads) |*thread| {
        thread.join();
    }
    
    // All entries should be logged
    try std.testing.expectEqual(num_threads * requests_per_thread, audit_logger.total_count);
}
```

---

## Part 3: Build Configuration

### Update `build.zig` to include E2E tests

```zig
// Add E2E test target
const e2e_test_module = b.createModule(.{
    .root_source_file = b.path("src/integration_e2e_test.zig"),
    .target = target,
    .optimize = optimize,
});

const e2e_test_obj = b.addTest(.{
    .root_module = e2e_test_module,
});

const e2e_test_step = b.step("test-e2e", "Run E2E integration tests");
const e2e_test_run = b.addRunArtifact(e2e_test_obj);
e2e_test_step.dependOn(&e2e_test_run.step);
```

---

## Part 4: Test Execution

### Run all tests

```bash
# Unit tests
zig build test

# E2E integration tests
zig build test-e2e

# Specific test file
zig build test --test-filter "E2E"
```

### Test coverage target

- Unit tests: >85% coverage
- Integration tests: All E2E scenarios covered
- Critical paths: 100% coverage

---

## Test Scenarios Summary

| Test Category | Files | Key Scenarios |
|---------------|-------|---------------|
| Errors | `src/errors.zig` | HTTP status mapping |
| Config | `src/config_test.zig` | JWT secret validation |
| Policy | `src/policy/decision_test.zig` | Decision struct, policy attribution |
| JWT | `src/auth/jwt.zig` | Token generation, verification |
| Audit | `src/audit/logger_test.zig` | Ring buffer, wrap-around |
| HTTP | `src/server/http_test.zig` | Request parsing, responses |
| E2E | `src/integration_e2e_test.zig` | Full flows, concurrent |

---

## Success Criteria

1. All unit tests pass
2. All integration tests pass
3. E2E tests verify complete request lifecycle
4. Concurrent tests show no data corruption
5. Audit logs contain correct policy attribution