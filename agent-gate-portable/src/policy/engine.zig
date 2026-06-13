//! Policy evaluation engine - First-match-wins policy evaluator.
//!
//! Evaluates requests against a list of policies using first-match-wins strategy.
//! Zero allocations in the hot path - all work done with const references.

const std = @import("std");
const types = @import("types.zig");

const Self = @This();

/// Evaluate a request context against a list of policies.
/// Returns the effect of the first matching policy, or deny if none match.
///
/// Strategy: First-match-wins
/// - Iterate policies in order
/// - For each policy, check ALL conditions (AND logic)
/// - First policy where all conditions match wins
/// - Return that policy's effect
/// - No match = default deny
///
/// Allocations: Zero - uses const references only
pub fn evaluate(policies: []const types.Policy, ctx: *const types.RequestContext) types.Effect {
    for (policies) |policy| {
        if (policy.matchesAll(ctx)) {
            return policy.effect;
        }
    }
    return .deny; // Default deny when no policy matches
}

/// Evaluate a request context against a single policy.
/// Returns true if ALL conditions match (AND logic).
pub fn evaluatePolicy(policy: *const types.Policy, ctx: *const types.RequestContext) bool {
    return policy.matchesAll(ctx);
}

/// Generate an optimized policy evaluator at compile time.
/// Embeds the policy file and generates a decision function.
///
/// Usage:
///   const MyPolicies = PolicySet(@embedFile("policies.json"));
///   const result = MyPolicies.evaluate(&ctx);
pub fn PolicySet(comptime policies_json: []const u8) type {
    const policy_file = @import("parser.zig").parseComptime(policies_json);

    return struct {
        const Compiled = @This();

        /// Compile-time policies slice.
        pub const policies = policy_file.policies;

        /// Evaluate request context against compiled policies.
        pub fn evaluate(ctx: *const types.RequestContext) types.Effect {
            return Self.evaluate(policies, ctx);
        }

        /// Check if a specific policy exists by ID.
        pub fn hasPolicy(comptime id: []const u8) bool {
            for (policies) |policy| {
                if (std.mem.eql(u8, policy.id, id)) return true;
            }
            return false;
        }

        /// Get policy count at compile time.
        pub const policy_count = policies.len;
    };
}

/// Generate a decision tree for optimized evaluation.
/// For future optimization: pre-computes path prefixes for O(1) lookups.
pub fn buildDecisionTree(comptime policies: []const types.Policy) type {
    // Simple implementation: just return the policies slice
    // Future optimization: build a trie for path matching
    return struct {
        const Tree = @This();
        pub const stored_policies = policies;

        pub fn evaluate(ctx: *const types.RequestContext) types.Effect {
            return Self.evaluate(stored_policies, ctx);
        }
    };
}

// Tests

test "engine evaluate first match wins" {
    const deny_policy = types.Policy{
        .id = "deny-all",
        .effect = .deny,
        .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
    };
    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const policies = &[_]types.Policy{ deny_policy, allow_policy };
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // First policy (deny-all) matches first
    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.deny, result);
}

test "engine evaluate default deny" {
    const allow_policy = types.Policy{
        .id = "allow-specific",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/special/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("agent", "/other", .GET);

    // No match = default deny
    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.deny, result);
}

test "engine evaluate allow match" {
    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("agent", "/api/users", .GET);

    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.allow, result);
}

test "engine evaluate deny match" {
    const deny_policy = types.Policy{
        .id = "deny-admin",
        .effect = .deny,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/admin/*" }},
    };

    const policies = &[_]types.Policy{deny_policy};
    const ctx = types.RequestContext.init("agent", "/admin/users", .GET);

    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.deny, result);
}

test "engine evaluate agent_id wildcard" {
    const allow_policy = types.Policy{
        .id = "allow-all-agents",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .agent_id = "*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("any-agent-id", "/any-path", .GET);

    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.allow, result);
}

test "engine evaluate method matching" {
    const allow_policy = types.Policy{
        .id = "allow-get-only",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .method = types.Method.GET }},
    };

    const policies = &[_]types.Policy{allow_policy};

    // GET should match
    const ctx_get = types.RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_get));

    // POST should not match
    const ctx_post = types.RequestContext.init("agent", "/api/test", .POST);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_post));
}

test "engine evaluate methods array" {
    const methods = &[_]types.Method{ .GET, .POST, .PUT };
    const allow_policy = types.Policy{
        .id = "allow-read-write",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .methods = methods }},
    };

    const policies = &[_]types.Policy{allow_policy};

    // GET should match
    const ctx_get = types.RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_get));

    // PUT should match
    const ctx_put = types.RequestContext.init("agent", "/api/test", .PUT);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_put));

    // DELETE should not match
    const ctx_delete = types.RequestContext.init("agent", "/api/test", .DELETE);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_delete));
}

test "engine evaluate multiple conditions AND" {
    const allow_policy = types.Policy{
        .id = "allow-specific",
        .effect = .allow,
        .conditions = &[_]types.Condition{
            types.Condition{ .agent_id = "service-a" },
            types.Condition{ .path = "/api/*" },
            types.Condition{ .method = .GET },
        },
    };

    const policies = &[_]types.Policy{allow_policy};

    // All conditions match
    const ctx_all = types.RequestContext.init("service-a", "/api/users", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_all));

    // Wrong agent_id
    const ctx_wrong_agent = types.RequestContext.init("service-b", "/api/users", .GET);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_wrong_agent));

    // Wrong path
    const ctx_wrong_path = types.RequestContext.init("service-a", "/admin/users", .GET);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_wrong_path));

    // Wrong method
    const ctx_wrong_method = types.RequestContext.init("service-a", "/api/users", .POST);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_wrong_method));
}

test "engine evaluate empty policies" {
    const policies = &[_]types.Policy{};
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Empty policies = default deny
    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.deny, result);
}

test "engine evaluate complex scenario" {
    // Simulate real-world policy order
    const policies = &[_]types.Policy{
        // 1. Allow auth service
        types.Policy{
            .id = "allow-auth",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "auth-service" },
                types.Condition{ .path = "/api/auth/*" },
            },
        },
        // 2. Allow user service read
        types.Policy{
            .id = "allow-user-read",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "user-service" },
                types.Condition{ .path = "/api/users/*" },
                types.Condition{ .method = .GET },
            },
        },
        // 3. Deny admin delete
        types.Policy{
            .id = "deny-admin-delete",
            .effect = .deny,
            .conditions = &[_]types.Condition{
                types.Condition{ .path = "/api/admin/*" },
                types.Condition{ .method = .DELETE },
            },
        },
        // 4. Allow admin service all
        types.Policy{
            .id = "allow-admin",
            .effect = .allow,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "admin-service" },
                types.Condition{ .path = "/api/*" },
            },
        },
        // 5. Default deny all
        types.Policy{
            .id = "deny-default",
            .effect = .deny,
            .conditions = &[_]types.Condition{
                types.Condition{ .agent_id = "*" },
                types.Condition{ .path = "*" },
            },
        },
    };

    // Auth service should be allowed
    const ctx_auth = types.RequestContext.init("auth-service", "/api/auth/login", .POST);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_auth));

    // User service read should be allowed
    const ctx_user_read = types.RequestContext.init("user-service", "/api/users/123", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_user_read));

    // User service write should be denied (no matching policy, falls through to deny-default)
    const ctx_user_write = types.RequestContext.init("user-service", "/api/users/123", .POST);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_user_write));

    // Admin delete should be denied
    const ctx_admin_delete = types.RequestContext.init("any-agent", "/api/admin/users", .DELETE);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_admin_delete));

    // Admin service should be allowed
    const ctx_admin = types.RequestContext.init("admin-service", "/api/admin/users", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_admin));

    // Unknown agent should be denied
    const ctx_unknown = types.RequestContext.init("unknown", "/api/secret", .GET);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_unknown));
}

test "engine evaluate zero allocations" {
    const gpa = std.testing.allocator;
    const tracking_allocator = std.testing.TrackingAllocator.init(gpa, .{});

    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Reset allocation counter
    tracking_allocator.resetStatistics();

    // Evaluate multiple times
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = evaluate(policies, &ctx);
    }

    // Should have zero allocations in hot path
    const stats = tracking_allocator.statistics();
    try std.testing.expectEqual(@as(usize, 0), stats.total_allocs);
}

test "engine PolicySet comptime" {
    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-all", "effect": "allow", "match": {"path": "*"}}
        \\]}
    ;

    const MyPolicies = PolicySet(json);
    const ctx = types.RequestContext.init("agent", "/test", .GET);

    try std.testing.expectEqual(types.Effect.allow, MyPolicies.evaluate(&ctx));
    try std.testing.expectEqual(@as(usize, 1), MyPolicies.policy_count);
    try std.testing.expect(MyPolicies.hasPolicy("allow-all"));
    try std.testing.expect(!MyPolicies.hasPolicy("nonexistent"));
}

test "engine buildDecisionTree" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const Tree = buildDecisionTree(policies);
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    try std.testing.expectEqual(types.Effect.allow, Tree.evaluate(&ctx));
}

test "engine evaluate path exact match" {
    const allow_policy = types.Policy{
        .id = "allow-metrics",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/metrics" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    // Exact match
    const ctx_exact = types.RequestContext.init("agent", "/metrics", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_exact));

    // Similar but not exact
    const ctx_similar = types.RequestContext.init("agent", "/metrics/cpu", .GET);
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_similar));
}

test "engine evaluate prefix wildcard" {
    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    // Various paths that should match
    const paths_to_test = &[_][]const u8{
        "/api/users",
        "/api/users/123",
        "/api/users/123/profile",
        "/api/admin/settings",
        "/api/",
    };

    for (paths_to_test) |path| {
        const ctx = types.RequestContext.init("agent", path, .GET);
        try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx));
    }

    // Paths that should not match
    const paths_deny = &[_][]const u8{
        "/api",      // Missing trailing slash
        "/other",
        "/health",
    };

    for (paths_deny) |path| {
        const ctx = types.RequestContext.init("agent", path, .GET);
        try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx));
    }
}

test "engine evaluate policy ordering matters" {
    // More specific policy first
    const specific_first = &[_]types.Policy{
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
        types.Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };

    // More general policy first
    const general_first = &[_]types.Policy{
        types.Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Specific first: allow
    try std.testing.expectEqual(types.Effect.allow, evaluate(specific_first, &ctx));

    // General first: deny (first match wins)
    try std.testing.expectEqual(types.Effect.deny, evaluate(general_first, &ctx));
}

// Edge case tests

test "engine evaluate empty agent_id with wildcard" {
    const allow_policy = types.Policy{
        .id = "allow-all",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .agent_id = "*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("", "/api/test", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx));
}

test "engine evaluate empty path with wildcard" {
    const allow_policy = types.Policy{
        .id = "allow-all",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("agent", "", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx));
}

test "engine evaluate empty path exact match" {
    const allow_policy = types.Policy{
        .id = "allow-root",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "" }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx_empty = types.RequestContext.init("agent", "", .GET);
    const ctx_nonempty = types.RequestContext.init("agent", "/api", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_empty));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_nonempty));
}

test "engine evaluate path with trailing slash" {
    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx_with_slash = types.RequestContext.init("agent", "/api/", .GET);
    const ctx_without_slash = types.RequestContext.init("agent", "/api", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_with_slash));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_without_slash));
}

test "engine evaluate case sensitive path" {
    const allow_policy = types.Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/API/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx_upper = types.RequestContext.init("agent", "/API/users", .GET);
    const ctx_lower = types.RequestContext.init("agent", "/api/users", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_upper));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_lower));
}

test "engine evaluate method case sensitivity" {
    const allow_policy = types.Policy{
        .id = "allow-get",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .method = types.Method.GET }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx_get = types.RequestContext.init("agent", "/api/test", .GET);
    const ctx_post = types.RequestContext.init("agent", "/api/test", .POST);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_get));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_post));
}

test "engine evaluate all HTTP methods" {
    const methods = &[_]types.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD };
    const allow_policy = types.Policy{
        .id = "allow-all-methods",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .methods = methods }},
    };

    const policies = &[_]types.Policy{allow_policy};

    // Test each method
    const ctx_get = types.RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_get));

    const ctx_post = types.RequestContext.init("agent", "/api/test", .POST);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_post));

    const ctx_delete = types.RequestContext.init("agent", "/api/test", .DELETE);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_delete));
}

test "engine evaluate policy with no conditions matches everything" {
    const allow_policy = types.Policy{
        .id = "allow-all",
        .effect = .allow,
        .conditions = &[_]types.Condition{},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("any-agent", "any-path", .GET);

    // Empty conditions = vacuous truth, all conditions satisfied
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx));
}

test "engine evaluate deny takes precedence when first" {
    const deny_first = &[_]types.Policy{
        types.Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
        types.Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const ctx = types.RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(types.Effect.deny, evaluate(deny_first, &ctx));
}

test "engine evaluate multiple deny policies" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "deny-admin",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/admin/*" }},
        },
        types.Policy{
            .id = "deny-secret",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/secret/*" }},
        },
    };

    const ctx_admin = types.RequestContext.init("agent", "/admin/users", .GET);
    const ctx_secret = types.RequestContext.init("agent", "/secret/data", .GET);
    const ctx_other = types.RequestContext.init("agent", "/other", .GET);

    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_admin));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_secret));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_other));
}

test "engine evaluate specific before general allow" {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-specific",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/users/*" }},
        },
        types.Policy{
            .id = "allow-general",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    const ctx_specific = types.RequestContext.init("agent", "/api/users/123", .GET);
    const ctx_general = types.RequestContext.init("agent", "/api/other", .GET);

    // Both should be allowed, but different policies match
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_specific));
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_general));
}

test "engine evaluate PolicySet with hasPolicy" {
    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "policy-1", "effect": "allow", "match": {"path": "/api/*"}},
        \\  {"id": "policy-2", "effect": "deny", "match": {"path": "/admin/*"}}
        \\]}
    ;

    const MyPolicies = PolicySet(json);

    try std.testing.expect(MyPolicies.hasPolicy("policy-1"));
    try std.testing.expect(MyPolicies.hasPolicy("policy-2"));
    try std.testing.expect(!MyPolicies.hasPolicy("nonexistent"));
    try std.testing.expectEqual(@as(usize, 2), MyPolicies.policy_count);
}

test "engine evaluate large policy set" {
    // Create 100 policies at compile time
    comptime var policies_buf: [100]types.Policy = undefined;
    comptime {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            policies_buf[i] = types.Policy{
                .id = "policy",
                .effect = .allow,
                .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
            };
        }
    }

    const policies = &policies_buf;
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Should still evaluate quickly
    const result = evaluate(policies, &ctx);
    try std.testing.expectEqual(types.Effect.allow, result);
}

test "engine evaluate unicode paths" {
    const allow_policy = types.Policy{
        .id = "allow-unicode",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/用户名/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx_match = types.RequestContext.init("agent", "/api/用户名/test", .GET);
    const ctx_no_match = types.RequestContext.init("agent", "/api/other", .GET);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_match));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_no_match));
}

test "engine evaluate path with special characters" {
    const allow_policy = types.Policy{
        .id = "allow-special",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/test-query/*" }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx = types.RequestContext.init("agent", "/api/test-query/with-dash_and_underscore", .GET);
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx));
}

test "engine evaluate wildcard matches everything" {
    const allow_policy = types.Policy{
        .id = "allow-all",
        .effect = .allow,
        .conditions = &[_]types.Condition{
            types.Condition{ .agent_id = "*" },
            types.Condition{ .path = "*" },
        },
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx1 = types.RequestContext.init("any-agent", "any-path", .GET);
    const ctx2 = types.RequestContext.init("", "", .GET);
    const ctx3 = types.RequestContext.init("service-123", "/deep/nested/path/here", .DELETE);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx1));
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx2));
    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx3));
}

test "engine evaluate methods array with single element" {
    const methods = &[_]types.Method{.GET};
    const allow_policy = types.Policy{
        .id = "allow-get-only",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .methods = methods }},
    };

    const policies = &[_]types.Policy{allow_policy};

    const ctx_get = types.RequestContext.init("agent", "/api/test", .GET);
    const ctx_post = types.RequestContext.init("agent", "/api/test", .POST);

    try std.testing.expectEqual(types.Effect.allow, evaluate(policies, &ctx_get));
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx_post));
}

test "engine evaluate methods array empty" {
    const methods = &[_]types.Method{};
    const allow_policy = types.Policy{
        .id = "allow-none",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .methods = methods }},
    };

    const policies = &[_]types.Policy{allow_policy};
    const ctx = types.RequestContext.init("agent", "/api/test", .GET);

    // Empty methods array = no method matches
    try std.testing.expectEqual(types.Effect.deny, evaluate(policies, &ctx));
}

test "engine evaluatePolicy helper function" {
    const policy = types.Policy{
        .id = "test",
        .effect = .allow,
        .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
    };

    const ctx_match = types.RequestContext.init("agent", "/api/test", .GET);
    const ctx_no_match = types.RequestContext.init("agent", "/other", .GET);

    try std.testing.expect(evaluatePolicy(&policy, &ctx_match));
    try std.testing.expect(!evaluatePolicy(&policy, &ctx_no_match));
}
