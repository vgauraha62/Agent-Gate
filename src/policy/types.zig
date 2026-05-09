//! Policy types - Core data structures for policy evaluation.
//!
//! Defines the core types: Effect, Method, Condition, Policy, and RequestContext.

const std = @import("std");

/// Effect - The result of policy evaluation.
pub const Effect = enum(u1) {
    /// Deny the request.
    deny = 0,
    /// Allow the request.
    allow = 1,

    const Self = @This();

    /// Parse effect from string.
    pub fn parse(s: []const u8) !Self {
        if (std.mem.eql(u8, s, "allow")) return .allow;
        if (std.mem.eql(u8, s, "deny")) return .deny;
        return error.InvalidEffect;
    }
};

/// HTTP Methods supported by policies.
pub const Method = enum(u3) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    OPTIONS = 5,
    HEAD = 6,

    const Self = @This();

    /// Parse method from string (case-insensitive).
    pub fn parse(s: []const u8) !Self {
        // Uppercase copy and compare
        var buf: [10]u8 = undefined;
        const upper = if (s.len <= buf.len) upper: {
            for (s, 0..) |c, i| {
                if (c >= 'a' and c <= 'z') {
                    buf[i] = c - 32;
                } else {
                    buf[i] = c;
                }
            }
            break :upper buf[0..s.len];
        } else s;

        if (std.mem.eql(u8, upper, "GET")) return .GET;
        if (std.mem.eql(u8, upper, "POST")) return .POST;
        if (std.mem.eql(u8, upper, "PUT")) return .PUT;
        if (std.mem.eql(u8, upper, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, upper, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, upper, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, upper, "HEAD")) return .HEAD;
        return error.InvalidMethod;
    }

    /// Get string representation.
    pub fn string(self: Self) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .OPTIONS => "OPTIONS",
            .HEAD => "HEAD",
        };
    }
};

/// Condition - A single matching condition for a policy.
/// Conditions are AND'd together within a policy.
pub const Condition = union(enum) {
    /// Match against agent_id (supports "*" wildcard).
    agent_id: []const u8,
    /// Match against request path (supports prefix wildcard like "/api/*").
    path: []const u8,
    /// Match against a single HTTP method.
    method: Method,
    /// Match against multiple HTTP methods (any match).
    methods: []const Method,

    const Self = @This();

    /// Check if this condition matches the request context.
    pub fn matches(self: Self, ctx: *const RequestContext) bool {
        return switch (self) {
            .agent_id => matchesAgentId(self.agent_id, ctx.agent_id),
            .path => matchesPath(self.path, ctx.path),
            .method => self.method == ctx.method,
            .methods => matchesMethodAny(self.methods, ctx.method),
        };
    }
};

/// Policy - A single policy rule with effect and conditions.
pub const Policy = struct {
    /// Unique identifier for the policy.
    id: []const u8,
    /// Effect when this policy matches.
    effect: Effect,
    /// Conditions to match (AND'd together).
    conditions: []const Condition,

    const Self = @This();

    /// Check if all conditions match the request context.
    pub fn matchesAll(self: *const Self, ctx: *const RequestContext) bool {
        for (self.conditions) |cond| {
            if (!cond.matches(ctx)) return false;
        }
        return true;
    }
};

/// RequestContext - The context for policy evaluation.
/// Contains information about the incoming request.
pub const RequestContext = struct {
    /// Agent ID from JWT token (sub claim).
    agent_id: []const u8,
    /// Request path.
    path: []const u8,
    /// HTTP method.
    method: Method,

    const Self = @This();

    /// Create a new request context.
    pub fn init(agent_id: []const u8, path: []const u8, method: Method) Self {
        return Self{
            .agent_id = agent_id,
            .path = path,
            .method = method,
        };
    }
};

/// PolicySet - A collection of policies for evaluation.
/// Uses first-match-wins strategy.
pub const PolicySet = struct {
    /// List of policies to evaluate in order.
    policies: []const Policy,

    const Self = @This();

    /// Evaluate the request context against all policies.
    /// Returns first matching policy's effect, or deny if none match.
    pub fn evaluate(self: *const Self, ctx: *const RequestContext) Effect {
        for (self.policies) |policy| {
            if (policy.matchesAll(ctx)) {
                return policy.effect;
            }
        }
        return .deny; // Default deny
    }
};

/// PolicyError - Errors for policy operations.
pub const PolicyError = error{
    InvalidEffect,
    InvalidMethod,
    InvalidPolicy,
    InvalidCondition,
    ParseError,
};

/// Match agent_id against pattern (supports "*" wildcard).
fn matchesAgentId(pattern: []const u8, agent_id: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    return std.mem.eql(u8, pattern, agent_id);
}

/// Match path against pattern (supports prefix wildcard "/api/*").
fn matchesPath(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Check for prefix wildcard (ends with "/*")
    if (pattern.len >= 2 and pattern[pattern.len - 2] == '/' and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 2];
        return std.mem.startsWith(u8, path, prefix);
    }

    return std.mem.eql(u8, pattern, path);
}

/// Match if method is in the list.
fn matchesMethodAny(methods: []const Method, method: Method) bool {
    for (methods) |m| {
        if (m == method) return true;
    }
    return false;
}

// Tests

test "Effect parse valid" {
    try std.testing.expectEqual(Effect.allow, try Effect.parse("allow"));
    try std.testing.expectEqual(Effect.deny, try Effect.parse("deny"));
}

test "Effect parse invalid" {
    try std.testing.expectError(error.InvalidEffect, Effect.parse("invalid"));
}

test "Method parse valid" {
    try std.testing.expectEqual(Method.GET, try Method.parse("GET"));
    try std.testing.expectEqual(Method.POST, try Method.parse("POST"));
    try std.testing.expectEqual(Method.DELETE, try Method.parse("DELETE"));
}

test "Method parse case insensitive" {
    try std.testing.expectEqual(Method.GET, try Method.parse("get"));
    try std.testing.expectEqual(Method.POST, try Method.parse("post"));
}

test "Method parse invalid" {
    try std.testing.expectError(error.InvalidMethod, Method.parse("INVALID"));
}

test "Method string" {
    try std.testing.expectEqualStrings("GET", Method.GET.string());
    try std.testing.expectEqualStrings("POST", Method.POST.string());
}

test "Condition agent_id wildcard" {
    const ctx = RequestContext.init("any-agent", "/api/test", .GET);

    try std.testing.expect((Condition{ .agent_id = "*" }).matches(&ctx));
    try std.testing.expect((Condition{ .agent_id = "any-agent" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .agent_id = "other-agent" }).matches(&ctx));
}

test "Condition path wildcard prefix" {
    const ctx = RequestContext.init("agent-1", "/api/users/123", .GET);

    try std.testing.expect((Condition{ .path = "*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/users/*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/*" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/api/admin/*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/users/123" }).matches(&ctx));
}

test "Condition method" {
    const ctx = RequestContext.init("agent-1", "/api/test", .GET);

    try std.testing.expect((Condition{ .method = .GET }).matches(&ctx));
    try std.testing.expect(!(Condition{ .method = .POST }).matches(&ctx));
}

test "Condition methods array" {
    const ctx = RequestContext.init("agent-1", "/api/test", .POST);

    const methods = &[_]Method{ .GET, .POST, .PUT };
    try std.testing.expect((Condition{ .methods = methods }).matches(&ctx));
}

test "Policy matches all" {
    const conditions = &[_]Condition{
        Condition{ .agent_id = "service-a" },
        Condition{ .path = "/api/*" },
        Condition{ .method = .GET },
    };
    const policy = Policy{
        .id = "test-policy",
        .effect = .allow,
        .conditions = conditions,
    };

    const ctx = RequestContext.init("service-a", "/api/users", .GET);
    try std.testing.expect(policy.matchesAll(&ctx));

    // Missing path condition
    const ctx2 = RequestContext.init("service-a", "/other", .GET);
    try std.testing.expect(!policy.matchesAll(&ctx2));
}

test "PolicySet first match wins" {
    const deny_policy = Policy{
        .id = "deny-all",
        .effect = .deny,
        .conditions = &[_]Condition{Condition{ .path = "*" }},
    };
    const allow_policy = Policy{
        .id = "allow-api",
        .effect = .allow,
        .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
    };

    const policies = &[_]Policy{ deny_policy, allow_policy };
    const set = PolicySet{ .policies = policies };

    // First policy (deny-all) matches first
    const ctx = RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(Effect.deny, set.evaluate(&ctx));
}

test "PolicySet default deny" {
    const allow_policy = Policy{
        .id = "allow-specific",
        .effect = .allow,
        .conditions = &[_]Condition{Condition{ .path = "/special/*" }},
    };

    const policies = &[_]Policy{allow_policy};
    const set = PolicySet{ .policies = policies };

    const ctx = RequestContext.init("agent", "/other", .GET);
    try std.testing.expectEqual(Effect.deny, set.evaluate(&ctx));
}

test "RequestContext init" {
    const ctx = RequestContext.init("my-agent", "/api/users", .POST);

    try std.testing.expectEqualStrings("my-agent", ctx.agent_id);
    try std.testing.expectEqualStrings("/api/users", ctx.path);
    try std.testing.expectEqual(Method.POST, ctx.method);
}

// Edge case tests

test "Effect case sensitivity" {
    // Effect parsing is case-sensitive
    try std.testing.expectError(error.InvalidEffect, Effect.parse("ALLOW"));
    try std.testing.expectError(error.InvalidEffect, Effect.parse("Deny"));
    try std.testing.expectError(error.InvalidEffect, Effect.parse(""));
}

test "Effect empty string" {
    try std.testing.expectError(error.InvalidEffect, Effect.parse(""));
}

test "Method empty string" {
    try std.testing.expectError(error.InvalidMethod, Method.parse(""));
}

test "Method special characters" {
    try std.testing.expectError(error.InvalidMethod, Method.parse("GET "));
    try std.testing.expectError(error.InvalidMethod, Method.parse(" GET"));
    try std.testing.expectError(error.InvalidMethod, Method.parse("G-ET"));
}

test "Method all valid methods" {
    try std.testing.expectEqual(Method.GET, try Method.parse("GET"));
    try std.testing.expectEqual(Method.POST, try Method.parse("POST"));
    try std.testing.expectEqual(Method.PUT, try Method.parse("PUT"));
    try std.testing.expectEqual(Method.DELETE, try Method.parse("DELETE"));
    try std.testing.expectEqual(Method.PATCH, try Method.parse("PATCH"));
    try std.testing.expectEqual(Method.OPTIONS, try Method.parse("OPTIONS"));
    try std.testing.expectEqual(Method.HEAD, try Method.parse("HEAD"));
}

test "Method mixed case" {
    try std.testing.expectEqual(Method.GET, try Method.parse("get"));
    try std.testing.expectEqual(Method.GET, try Method.parse("Get"));
    try std.testing.expectEqual(Method.GET, try Method.parse("gEt"));
}

test "Condition agent_id exact match" {
    const ctx = RequestContext.init("exact-agent", "/api/test", .GET);

    try std.testing.expect((Condition{ .agent_id = "exact-agent" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .agent_id = "other-agent" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .agent_id = "exact" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .agent_id = "exact-agent-id" }).matches(&ctx));
}

test "Condition agent_id empty" {
    const ctx = RequestContext.init("", "/api/test", .GET);

    try std.testing.expect((Condition{ .agent_id = "*" }).matches(&ctx));
    try std.testing.expect((Condition{ .agent_id = "" }).matches(&ctx));
}

test "Condition path exact match only" {
    const ctx = RequestContext.init("agent", "/metrics", .GET);

    try std.testing.expect((Condition{ .path = "/metrics" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/metrics/" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/metrics/cpu" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/health" }).matches(&ctx));
}

test "Condition path prefix wildcard edge cases" {
    const ctx = RequestContext.init("agent", "/api/users/123/profile", .GET);

    // Prefix wildcards
    try std.testing.expect((Condition{ .path = "/api/*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/users/*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/users/123/*" }).matches(&ctx));

    // Non-matching prefixes
    try std.testing.expect(!(Condition{ .path = "/api/admin/*" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/other/*" }).matches(&ctx));

    // Missing wildcard - exact match only
    try std.testing.expect(!(Condition{ .path = "/api/users" }).matches(&ctx));
}

test "Condition path wildcard at end only" {
    // Wildcard only works at end, not in middle
    const ctx = RequestContext.init("agent", "/api/test", .GET);

    try std.testing.expect((Condition{ .path = "*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "/api/*" }).matches(&ctx));

    // Pattern without wildcard - must be exact
    try std.testing.expect(!(Condition{ .path = "/api" }).matches(&ctx));
}

test "Condition path empty path" {
    const ctx = RequestContext.init("agent", "", .GET);

    try std.testing.expect((Condition{ .path = "*" }).matches(&ctx));
    try std.testing.expect((Condition{ .path = "" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/api/*" }).matches(&ctx));
}

test "Condition path special characters" {
    const ctx = RequestContext.init("agent", "/api/test?query=1&foo=bar", .GET);

    try std.testing.expect((Condition{ .path = "/api/*" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path = "/api/test" }).matches(&ctx)); // Query string mismatch
}

test "Condition methods empty array" {
    const ctx = RequestContext.init("agent", "/api/test", .GET);
    const empty_methods: []const Method = &[_]Method{};

    try std.testing.expect(!(Condition{ .methods = empty_methods }).matches(&ctx));
}

test "Condition methods single element" {
    const ctx_post = RequestContext.init("agent", "/api/test", .POST);
    const ctx_get = RequestContext.init("agent", "/api/test", .GET);
    const methods = &[_]Method{.POST};

    try std.testing.expect((Condition{ .methods = methods }).matches(&ctx_post));
    try std.testing.expect(!(Condition{ .methods = methods }).matches(&ctx_get));
}

test "Policy empty conditions" {
    const policy = Policy{
        .id = "empty-conditions",
        .effect = .allow,
        .conditions = &[_]Condition{},
    };

    const ctx = RequestContext.init("agent", "/api/test", .GET);

    // Empty conditions = all conditions satisfied (vacuous truth)
    try std.testing.expect(policy.matchesAll(&ctx));
}

test "Policy single condition" {
    const policy = Policy{
        .id = "single-condition",
        .effect = .allow,
        .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
    };

    const ctx_match = RequestContext.init("agent", "/api/test", .GET);
    const ctx_no_match = RequestContext.init("agent", "/other", .GET);

    try std.testing.expect(policy.matchesAll(&ctx_match));
    try std.testing.expect(!policy.matchesAll(&ctx_no_match));
}

test "Policy all conditions must match" {
    const policy = Policy{
        .id = "multi-condition",
        .effect = .allow,
        .conditions = &[_]Condition{
            Condition{ .agent_id = "service-a" },
            Condition{ .path = "/api/*" },
            Condition{ .method = .GET },
        },
    };

    // All match
    const ctx_all = RequestContext.init("service-a", "/api/test", .GET);
    try std.testing.expect(policy.matchesAll(&ctx_all));

    // Only agent_id matches
    const ctx_agent = RequestContext.init("service-a", "/other", .POST);
    try std.testing.expect(!policy.matchesAll(&ctx_agent));

    // Only path matches
    const ctx_path = RequestContext.init("other", "/api/test", .POST);
    try std.testing.expect(!policy.matchesAll(&ctx_path));

    // Only method matches
    const ctx_method = RequestContext.init("other", "/other", .GET);
    try std.testing.expect(!policy.matchesAll(&ctx_method));
}

test "PolicySet empty policies" {
    const policies = &[_]Policy{};
    const set = PolicySet{ .policies = policies };

    const ctx = RequestContext.init("agent", "/api/test", .GET);
    try std.testing.expectEqual(Effect.deny, set.evaluate(&ctx));
}

test "PolicySet single allow policy" {
    const policies = &[_]Policy{
        Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "*" }},
        },
    };
    const set = PolicySet{ .policies = policies };

    const ctx = RequestContext.init("agent", "/any/path", .GET);
    try std.testing.expectEqual(Effect.allow, set.evaluate(&ctx));
}

test "PolicySet single deny policy" {
    const policies = &[_]Policy{
        Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]Condition{Condition{ .path = "*" }},
        },
    };
    const set = PolicySet{ .policies = policies };

    const ctx = RequestContext.init("agent", "/any/path", .GET);
    try std.testing.expectEqual(Effect.deny, set.evaluate(&ctx));
}

test "PolicySet ordering matters - specific before general" {
    const policies_specific_first = &[_]Policy{
        Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
        },
        Policy{
            .id = "deny-all",
            .effect = .deny,
            .conditions = &[_]Condition{Condition{ .path = "*" }},
        },
    };

    const policies_general_first = &[_]Policy{
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

    const ctx_api = RequestContext.init("agent", "/api/test", .GET);
    const ctx_other = RequestContext.init("agent", "/other", .GET);

    // Specific first: /api/* allowed, /other denied
    const set_specific = PolicySet{ .policies = policies_specific_first };
    try std.testing.expectEqual(Effect.allow, set_specific.evaluate(&ctx_api));
    try std.testing.expectEqual(Effect.deny, set_specific.evaluate(&ctx_other));

    // General first: everything denied (first match wins)
    const set_general = PolicySet{ .policies = policies_general_first };
    try std.testing.expectEqual(Effect.deny, set_general.evaluate(&ctx_api));
    try std.testing.expectEqual(Effect.deny, set_general.evaluate(&ctx_other));
}

test "PolicySet multiple policies with same effect" {
    const policies = &[_]Policy{
        Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
        },
        Policy{
            .id = "allow-admin",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/admin/*" }},
        },
        Policy{
            .id = "allow-health",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/health" }},
        },
    };
    const set = PolicySet{ .policies = policies };

    const ctx_api = RequestContext.init("agent", "/api/users", .GET);
    const ctx_admin = RequestContext.init("agent", "/admin/settings", .GET);
    const ctx_health = RequestContext.init("agent", "/health", .GET);
    const ctx_other = RequestContext.init("agent", "/other", .GET);

    try std.testing.expectEqual(Effect.allow, set.evaluate(&ctx_api));
    try std.testing.expectEqual(Effect.allow, set.evaluate(&ctx_admin));
    try std.testing.expectEqual(Effect.allow, set.evaluate(&ctx_health));
    try std.testing.expectEqual(Effect.deny, set.evaluate(&ctx_other));
}

test "PolicySet allow and deny mixed" {
    const policies = &[_]Policy{
        Policy{
            .id = "allow-api",
            .effect = .allow,
            .conditions = &[_]Condition{Condition{ .path = "/api/*" }},
        },
        Policy{
            .id = "deny-admin",
            .effect = .deny,
            .conditions = &[_]Condition{Condition{ .path = "/api/admin/*" }},
        },
    };
    const set = PolicySet{ .policies = policies };

    // /api/admin/* matches allow-api first (first match wins)
    const ctx_admin = RequestContext.init("agent", "/api/admin/users", .GET);
    try std.testing.expectEqual(Effect.allow, set.evaluate(&ctx_admin));
}

test "RequestContext special characters in agent_id" {
    const ctx = RequestContext.init("service-with-dash_underscore123", "/api/test", .GET);

    try std.testing.expectEqualStrings("service-with-dash_underscore123", ctx.agent_id);
}

test "RequestContext unicode in path" {
    const ctx = RequestContext.init("agent", "/api/users/用户名", .GET);

    try std.testing.expectEqualStrings("/api/users/用户名", ctx.path);
}

test "RequestContext very long path" {
    const long_path = "/api/" ++ "segment/" ** 20;
    const ctx = RequestContext.init("agent", long_path, .GET);

    try std.testing.expect((Condition{ .path = "/api/*" }).matches(&ctx));
}

test "wildcard matches everything including empty" {
    const empty_ctx = RequestContext.init("", "", .GET);
    try std.testing.expect((Condition{ .path = "*" }).matches(&empty_ctx));
    try std.testing.expect((Condition{ .agent_id = "*" }).matches(&empty_ctx));
}

test "method condition does not check path or agent_id" {
    const ctx1 = RequestContext.init("agent-a", "/path-a", .GET);
    const ctx2 = RequestContext.init("agent-b", "/path-b", .GET);

    const method_cond = Condition{ .method = .GET };
    try std.testing.expect(method_cond.matches(&ctx1));
    try std.testing.expect(method_cond.matches(&ctx2));
}

test "path condition does not check agent_id or method" {
    const ctx1 = RequestContext.init("agent-a", "/api/test", .POST);
    const ctx2 = RequestContext.init("agent-b", "/api/test", .DELETE);

    const path_cond = Condition{ .path = "/api/*" };
    try std.testing.expect(path_cond.matches(&ctx1));
    try std.testing.expect(path_cond.matches(&ctx2));
}

test "agent_id condition does not check path or method" {
    const ctx1 = RequestContext.init("specific-agent", "/path-a", .GET);
    const ctx2 = RequestContext.init("specific-agent", "/path-b", .DELETE);

    const agent_cond = Condition{ .agent_id = "specific-agent" };
    try std.testing.expect(agent_cond.matches(&ctx1));
    try std.testing.expect(agent_cond.matches(&ctx2));
}