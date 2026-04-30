//! Policy language parser - JSON policy file parser.
//!
//! Parses JSON policy files into Policy structs using arena allocation.
//! Follows src/auth/jwt.zig patterns for JSON parsing.

const std = @import("std");
const types = @import("types.zig");
const SecurityArena = @import("../memory.zig").SecurityArena;

pub const PolicyFile = struct {
    version: []const u8,
    policies: []const types.Policy,
};

const Self = @This();

/// Parse a JSON policy file into PolicyFile struct.
/// Uses arena for all allocations - caller must manage arena lifecycle.
pub fn parse(json_bytes: []const u8, arena: *SecurityArena) !PolicyFile {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Parse version (required)
    const version = if (obj.get("version")) |v|
        if (v == .string) v.string else return error.InvalidPolicyFile
    else
        return error.InvalidPolicyFile;

    // Parse policies array (required)
    const policies_array = if (obj.get("policies")) |v|
        if (v == .array) v.array else return error.InvalidPolicyFile
    else
        return error.InvalidPolicyFile;

    // Allocate policies slice
    const policies = try arena.alloc(types.Policy, policies_array.items.len);

    // Parse each policy
    for (policies_array.items, 0..) |policy_value, i| {
        policies[i] = try parsePolicy(policy_value, arena);
    }

    return PolicyFile{
        .version = version,
        .policies = policies,
    };
}

/// Parse a single policy from JSON value.
fn parsePolicy(value: std.json.Value, arena: *SecurityArena) !types.Policy {
    const obj = value.object;

    // Parse id (required)
    const id = if (obj.get("id")) |v|
        if (v == .string) v.string else return error.InvalidPolicy
    else
        return error.InvalidPolicy;

    // Parse effect (required)
    const effect_value = if (obj.get("effect")) |v|
        if (v == .string) v.string else return error.InvalidPolicy
    else
        return error.InvalidPolicy;

    const effect = try types.Effect.parse(effect_value);

    // Parse match conditions (required)
    const match_obj = if (obj.get("match")) |v|
        if (v == .object) v.object else return error.InvalidPolicy
    else
        return error.InvalidPolicy;

    // Count conditions
    var condition_count: usize = 0;
    if (match_obj.get("agent_id")) |_| condition_count += 1;
    if (match_obj.get("path")) |_| condition_count += 1;
    if (match_obj.get("method")) |_| condition_count += 1;

    // Allocate conditions slice
    const conditions = try arena.alloc(types.Condition, condition_count);
    var condition_idx: usize = 0;

    // Parse agent_id condition (optional)
    if (match_obj.get("agent_id")) |v| {
        const agent_id = if (v == .string) v.string else return error.InvalidCondition;
        conditions[condition_idx] = types.Condition{ .agent_id = agent_id };
        condition_idx += 1;
    }

    // Parse path condition (optional)
    if (match_obj.get("path")) |v| {
        const path = if (v == .string) v.string else return error.InvalidCondition;
        conditions[condition_idx] = types.Condition{ .path = path };
        condition_idx += 1;
    }

    // Parse method condition (optional, can be string or array)
    if (match_obj.get("method")) |v| {
        const method_condition = switch (v) {
            .string => types.Condition{ .method = try types.Method.parse(v.string) },
            .array => try parseMethodArray(v.array, arena),
            else => return error.InvalidCondition,
        };
        conditions[condition_idx] = method_condition;
        condition_idx += 1;
    }

    return types.Policy{
        .id = id,
        .effect = effect,
        .conditions = conditions[0..condition_idx],
    };
}

/// Parse method array from JSON value.
fn parseMethodArray(array: std.json.Array, arena: *SecurityArena) !types.Condition {
    const methods = try arena.alloc(types.Method, array.items.len);

    for (array.items, 0..) |method_value, i| {
        const method_str = if (method_value == .string) method_value.string else return error.InvalidMethod;
        methods[i] = try types.Method.parse(method_str);
    }

    return types.Condition{ .methods = methods };
}

/// Parse policies at compile time for comptime policy generation.
pub fn parseComptime(comptime json_bytes: []const u8) PolicyFile {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, json_bytes, .{});

    const obj = parsed.object;

    const version = if (obj.get("version")) |v|
        if (v == .string) v.string else @compileError("Invalid policy file: missing or invalid version")
    else
        @compileError("Invalid policy file: missing version");

    const policies_array = if (obj.get("policies")) |v|
        if (v == .array) v.array else @compileError("Invalid policy file: policies must be an array")
    else
        @compileError("Invalid policy file: missing policies");

    var policies: [policies_array.items.len]types.Policy = undefined;

    for (policies_array.items, 0..) |policy_value, i| {
        policies[i] = parsePolicyComptime(policy_value);
    }

    return PolicyFile{
        .version = version,
        .policies = &policies,
    };
}

/// Parse a single policy at compile time.
fn parsePolicyComptime(value: std.json.Value) types.Policy {
    const obj = value.object;

    const id = if (obj.get("id")) |v|
        if (v == .string) v.string else @compileError("Invalid policy: missing or invalid id")
    else
        @compileError("Invalid policy: missing id");

    const effect_value = if (obj.get("effect")) |v|
        if (v == .string) v.string else @compileError("Invalid policy: missing or invalid effect")
    else
        @compileError("Invalid policy: missing effect");

    const effect = if (std.mem.eql(u8, effect_value, "allow"))
        types.Effect.allow
    else if (std.mem.eql(u8, effect_value, "deny"))
        types.Effect.deny
    else
        @compileError("Invalid policy: effect must be 'allow' or 'deny'");

    const match_obj = if (obj.get("match")) |v|
        if (v == .object) v.object else @compileError("Invalid policy: match must be an object")
    else
        @compileError("Invalid policy: missing match");

    // Count conditions at comptime
    var condition_count: usize = 0;
    if (match_obj.get("agent_id") != null) condition_count += 1;
    if (match_obj.get("path") != null) condition_count += 1;
    if (match_obj.get("method") != null) condition_count += 1;

    var conditions: [4]types.Condition = undefined;
    var condition_idx: usize = 0;

    if (match_obj.get("agent_id")) |v| {
        const agent_id = if (v == .string) v.string else @compileError("Invalid condition: agent_id must be a string");
        conditions[condition_idx] = types.Condition{ .agent_id = agent_id };
        condition_idx += 1;
    }

    if (match_obj.get("path")) |v| {
        const path = if (v == .string) v.string else @compileError("Invalid condition: path must be a string");
        conditions[condition_idx] = types.Condition{ .path = path };
        condition_idx += 1;
    }

    if (match_obj.get("method")) |v| {
        const method_condition = switch (v) {
            .string => types.Condition{ .method = parseMethodComptime(v.string) },
            .array => parseMethodArrayComptime(v.array),
            else => @compileError("Invalid condition: method must be string or array"),
        };
        conditions[condition_idx] = method_condition;
        condition_idx += 1;
    }

    return types.Policy{
        .id = id,
        .effect = effect,
        .conditions = conditions[0..condition_idx],
    };
}

/// Parse method string at compile time.
fn parseMethodComptime(method_str: []const u8) types.Method {
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
    if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
    @compileError("Invalid method: " ++ method_str);
}

/// Parse method array at compile time.
fn parseMethodArrayComptime(array: std.json.Array) types.Condition {
    var methods: [10]types.Method = undefined;
    var method_count: usize = 0;

    for (array.items) |method_value| {
        const method_str = if (method_value == .string) method_value.string else @compileError("Invalid method in array");
        methods[method_count] = parseMethodComptime(method_str);
        method_count += 1;
    }

    var slice_methods: [10]types.Method = undefined;
    for (methods[0..method_count], 0..) |m, i| {
        slice_methods[i] = m;
    }

    return types.Condition{ .methods = slice_methods[0..method_count] };
}

// Tests

test "parse valid policy file" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-all", "effect": "allow", "match": {"path": "*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("1", result.version);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqualStrings("allow-all", result.policies[0].id);
    try std.testing.expectEqual(types.Effect.allow, result.policies[0].effect);
}

test "parse multiple policies" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-api", "effect": "allow", "match": {"path": "/api/*"}},
        \\  {"id": "deny-admin", "effect": "deny", "match": {"path": "/admin/*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 2), result.policies.len);
    try std.testing.expectEqualStrings("allow-api", result.policies[0].id);
    try std.testing.expectEqualStrings("deny-admin", result.policies[1].id);
}

test "parse policy with agent_id condition" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "auth-service", "effect": "allow", "match": {"agent_id": "auth-service"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(types.Condition{ .agent_id = "auth-service" }, result.policies[0].conditions[0]);
}

test "parse policy with method string" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "get-only", "effect": "allow", "match": {"method": "GET"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(types.Condition{ .method = types.Method.GET }, result.policies[0].conditions[0]);
}

test "parse policy with method array" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "read-write", "effect": "allow", "match": {"method": ["GET", "POST", "PUT"]}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);

    const condition = result.policies[0].conditions[0];
    try std.testing.expectEqual(@as(usize, 3), condition.methods.len);
    try std.testing.expectEqual(types.Method.GET, condition.methods[0]);
    try std.testing.expectEqual(types.Method.POST, condition.methods[1]);
    try std.testing.expectEqual(types.Method.PUT, condition.methods[2]);
}

test "parse policy with all conditions" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "specific", "effect": "allow", "match": {"agent_id": "svc", "path": "/api/*", "method": "GET"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(@as(usize, 3), result.policies[0].conditions.len);
}

test "parse missing version" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"policies": []}
    ;

    try std.testing.expectError(error.InvalidPolicyFile, parse(json, &arena));
}

test "parse missing policies" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1"}
    ;

    try std.testing.expectError(error.InvalidPolicyFile, parse(json, &arena));
}

test "parse missing policy id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"effect": "allow", "match": {}}]}
    ;

    try std.testing.expectError(error.InvalidPolicy, parse(json, &arena));
}

test "parse missing policy effect" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "match": {}}]}
    ;

    try std.testing.expectError(error.InvalidPolicy, parse(json, &arena));
}

test "parse invalid effect value" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "invalid", "match": {}}]}
    ;

    try std.testing.expectError(error.InvalidEffect, parse(json, &arena));
}

test "parse missing match object" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow"}]}
    ;

    try std.testing.expectError(error.InvalidPolicy, parse(json, &arena));
}

test "parse malformed JSON" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json = "{ invalid json }";
    try std.testing.expectError(error.InvalidPolicyFile, parse(json, &arena));
}

test "parse empty policies array" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": []}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 0), result.policies.len);
}

test "parse method case insensitive" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "test", "effect": "allow", "match": {"method": "get"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(types.Condition{ .method = types.Method.GET }, result.policies[0].conditions[0]);
}

test "parse invalid method" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "test", "effect": "allow", "match": {"method": "INVALID"}}
        \\]}
    ;

    try std.testing.expectError(error.InvalidMethod, parse(json, &arena));
}

test "parse wildcard agent_id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-all", "effect": "allow", "match": {"agent_id": "*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(types.Condition{ .agent_id = "*" }, result.policies[0].conditions[0]);
}

test "parse wildcard path" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-all", "effect": "allow", "match": {"path": "*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(types.Condition{ .path = "*" }, result.policies[0].conditions[0]);
}

test "parse prefix wildcard path" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-api", "effect": "allow", "match": {"path": "/api/*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(types.Condition{ .path = "/api/*" }, result.policies[0].conditions[0]);
}

test "parse no memory leaks" {
    const gpa = std.testing.allocator;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var arena = try SecurityArena.init(gpa, 4096);

        const json =
            \\{"version": "1", "policies": [
            \\  {"id": "test", "effect": "allow", "match": {"path": "/api/*", "method": ["GET", "POST"]}}
            \\]}
        ;

        _ = parse(json, &arena) catch {};
        arena.deinit();
    }
}

test "parse comptime valid policy" {
    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "allow-all", "effect": "allow", "match": {"path": "*"}}
        \\]}
    ;

    const result = comptime parseComptime(json);
    try std.testing.expectEqualStrings("1", result.version);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
}

test "parse comptime invalid effect" {
    comptime {
        const json =
            \\{"version": "1", "policies": [
            \\  {"id": "test", "effect": "invalid", "match": {}}
            \\]}
        ;

        _ = parseComptime(json);
    }
}

// Edge case tests

test "parse policy with empty id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "", "effect": "allow", "match": {"path": "*"}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqualStrings("", result.policies[0].id);
}

test "parse policy with special characters in id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "policy-with_special.chars:123", "effect": "allow", "match": {"path": "*"}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("policy-with_special.chars:123", result.policies[0].id);
}

test "parse policy with empty match object" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "empty-match", "effect": "allow", "match": {}}]}
    ;

    // Empty match = no conditions = matches everything
    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(@as(usize, 0), result.policies[0].conditions.len);
}

test "parse policy with all HTTP methods" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "all-methods", "effect": "allow", "match": {"method": ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"]}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    const condition = result.policies[0].conditions[0];
    try std.testing.expectEqual(@as(usize, 7), condition.methods.len);
}

test "parse policy with single method array" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "single-method", "effect": "allow", "match": {"method": ["GET"]}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    const condition = result.policies[0].conditions[0];
    try std.testing.expectEqual(@as(usize, 1), condition.methods.len);
    try std.testing.expectEqual(types.Method.GET, condition.methods[0]);
}

test "parse policy with empty method array" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "empty-methods", "effect": "allow", "match": {"method": []}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    const condition = result.policies[0].conditions[0];
    try std.testing.expectEqual(@as(usize, 0), condition.methods.len);
}

test "parse policy with mixed case methods" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "mixed-case", "effect": "allow", "match": {"method": ["get", "Post", "PUT"]}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    const condition = result.policies[0].conditions[0];
    try std.testing.expectEqual(types.Method.GET, condition.methods[0]);
    try std.testing.expectEqual(types.Method.POST, condition.methods[1]);
    try std.testing.expectEqual(types.Method.PUT, condition.methods[2]);
}

test "parse policy with duplicate conditions" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Multiple policies with same ID (not validated by parser)
    const json =
        \\{"version": "1", "policies": [
        \\  {"id": "dup", "effect": "allow", "match": {"path": "/api/*"}},
        \\  {"id": "dup", "effect": "deny", "match": {"path": "/admin/*"}}
        \\]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 2), result.policies.len);
}

test "parse deeply nested path" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "deep-path", "effect": "allow", "match": {"path": "/api/v1/users/123/profile/settings"}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("/api/v1/users/123/profile/settings", result.policies[0].conditions[0].path);
}

test "parse path with query-like characters" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "query-path", "effect": "allow", "match": {"path": "/api/test?query=1"}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("/api/test?query=1", result.policies[0].conditions[0].path);
}

test "parse version as number" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Version as number should fail (must be string)
    const json =
        \\{"version": 1, "policies": []}
    ;

    try std.testing.expectError(error.InvalidPolicyFile, parse(json, &arena));
}

test "parse policies as object instead of array" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": {"policy1": {"id": "test"}}}
    ;

    try std.testing.expectError(error.InvalidPolicyFile, parse(json, &arena));
}

test "parse match as array instead of object" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": []}]}
    ;

    try std.testing.expectError(error.InvalidPolicy, parse(json, &arena));
}

test "parse agent_id as number instead of string" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"agent_id": 123}}]}
    ;

    try std.testing.expectError(error.InvalidCondition, parse(json, &arena));
}

test "parse path as number instead of string" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"path": 123}}]}
    ;

    try std.testing.expectError(error.InvalidCondition, parse(json, &arena));
}

test "parse method as number instead of string" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"method": 123}}]}
    ;

    try std.testing.expectError(error.InvalidCondition, parse(json, &arena));
}

test "parse method array with mixed types" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"method": ["GET", 123]}}]}
    ;

    try std.testing.expectError(error.InvalidMethod, parse(json, &arena));
}

test "parse extra fields in policy" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Extra fields should be ignored
    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"path": "*"}, "extra": "ignored", "description": "test policy"}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqualStrings("test", result.policies[0].id);
}

test "parse extra fields in policy file" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Extra fields at root level should be ignored
    const json =
        \\{"version": "1", "policies": [], "metadata": {"author": "test"}, "description": "test file"}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("1", result.version);
    try std.testing.expectEqual(@as(usize, 0), result.policies.len);
}

test "parse unicode in path" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "unicode", "effect": "allow", "match": {"path": "/api/用户名/test"}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings("/api/用户名/test", result.policies[0].conditions[0].path);
}

test "parse very long policy id" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 65536);
    defer arena.deinit();

    var long_id_buf: [1000]u8 = undefined;
    @memset(&long_id_buf, 'a');
    const long_id = long_id_buf[0..999];

    const json = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"version\": \"1\", \"policies\": [{{\"id\": \"{s}\", \"effect\": \"allow\", \"match\": {{\"path\": \"*\"}}}}]}}",
        .{long_id},
    );

    const result = try parse(json, &arena);
    try std.testing.expectEqualStrings(long_id, result.policies[0].id);
}

test "parse multiple conditions in single policy" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const json =
        \\{"version": "1", "policies": [{"id": "multi", "effect": "allow", "match": {"agent_id": "svc", "path": "/api/*", "method": ["GET", "POST"]}}]}
    ;

    const result = try parse(json, &arena);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(@as(usize, 3), result.policies[0].conditions.len);
}

test "parse comptime missing id" {
    comptime {
        const json =
            \\{"version": "1", "policies": [{"effect": "allow", "match": {}}]}
        ;

        _ = parseComptime(json);
    }
}

test "parse comptime missing match" {
    comptime {
        const json =
            \\{"version": "1", "policies": [{"id": "test", "effect": "allow"}]}
        ;

        _ = parseComptime(json);
    }
}

test "parse comptime invalid method" {
    comptime {
        const json =
            \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"method": "INVALID"}}]}
        ;

        _ = parseComptime(json);
    }
}

test "parse comptime method array" {
    const json =
        \\{"version": "1", "policies": [{"id": "test", "effect": "allow", "match": {"method": ["GET", "POST"]}}]}
    ;

    const result = comptime parseComptime(json);
    try std.testing.expectEqual(@as(usize, 1), result.policies.len);
    try std.testing.expectEqual(@as(usize, 1), result.policies[0].conditions.len);
}
