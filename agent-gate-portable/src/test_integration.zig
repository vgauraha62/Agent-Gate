const std = @import("std");
const http = @import("server/http.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");
const config = @import("config.zig");
const AuditLog = audit.AuditLog;

test "HttpStatus enum values" {
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(http.HttpStatus.ok));
    try std.testing.expectEqual(@as(u16, 400), @intFromEnum(http.HttpStatus.bad_request));
    try std.testing.expectEqual(@as(u16, 401), @intFromEnum(http.HttpStatus.unauthorized));
    try std.testing.expectEqual(@as(u16, 403), @intFromEnum(http.HttpStatus.forbidden));
}

test "HttpStatus statusText" {
    try std.testing.expectEqualStrings("OK", http.statusText(http.HttpStatus.ok));
    try std.testing.expectEqualStrings("Bad Request", http.statusText(http.HttpStatus.bad_request));
    try std.testing.expectEqualStrings("Unauthorized", http.statusText(http.HttpStatus.unauthorized));
    try std.testing.expectEqualStrings("Forbidden", http.statusText(http.HttpStatus.forbidden));
}

test "RequestLine struct" {
    const line = http.RequestLine{
        .method = .GET,
        .path = "/api/test",
        .http_version = "HTTP/1.1",
    };
    try std.testing.expectEqual(types.Method.GET, line.method);
    try std.testing.expectEqualStrings("/api/test", line.path);
}

test "CheckRequest struct" {
    const req = http.CheckRequest{
        .path = "/api/users",
        .method = "POST",
    };
    try std.testing.expectEqualStrings("/api/users", req.path);
    try std.testing.expectEqualStrings("POST", req.method);
}

test "ServerInit creates valid server" {
    var audit_logger = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer audit_logger.deinit();

    const policy_set = types.PolicySet{ .policies = &[_]types.Policy{types.Policy{
        .id = "test",
        .effect = .allow,
        .conditions = &[_]types.Condition{},
    }} };

    var cfg = config.Config.default();
    cfg.server.port = 8080;
    cfg.auth.jwt_secret = "secret-key-32-bytes-long-enough!!!";

    const server = http.Server.init(std.heap.page_allocator, &cfg, &audit_logger, policy_set);

    try std.testing.expectEqual(@as(u16, 8080), server.port);
}

test "AuditLog log entry" {
    var logger = try AuditLog.init(&config.AuditConfig{}, std.testing.allocator);
    defer logger.deinit();
    const agent_id = [_]u8{0xAA} ** 32;

    logger.log(agent_id, "/api/test", .allow, 1);

    try std.testing.expectEqual(@as(u64, 1), logger.entryCount());

    const entry = logger.getEntry(0);
    try std.testing.expect(entry != null);
}

test "AuditLog ring buffer wrap" {
    var logger = try AuditLog.init(&config.AuditConfig{ .buffer_size = 1024 }, std.testing.allocator);
    defer logger.deinit();
    const agent_id = [_]u8{0xAA} ** 32;

    const buf_len = logger.buffer.len;
    for (0..buf_len + 5) |_| {
        logger.log(agent_id, "/api/test", .allow, 1);
    }

    try std.testing.expectEqual(@as(u64, buf_len + 5), logger.entryCount());
}

test "Policy types - Method parse" {
    try std.testing.expectEqual(types.Method.GET, try types.Method.parse("GET"));
    try std.testing.expectEqual(types.Method.POST, try types.Method.parse("POST"));
    try std.testing.expectEqual(types.Method.PUT, try types.Method.parse("PUT"));
    try std.testing.expectEqual(types.Method.DELETE, try types.Method.parse("DELETE"));
}

test "Policy types - Method parse case insensitive" {
    try std.testing.expectEqual(types.Method.GET, try types.Method.parse("get"));
    try std.testing.expectEqual(types.Method.POST, try types.Method.parse("post"));
}

test "Policy types - Method string" {
    try std.testing.expectEqualStrings("GET", types.Method.GET.string());
    try std.testing.expectEqualStrings("POST", types.Method.POST.string());
}

test "Policy types - Effect parse" {
    try std.testing.expectEqual(types.Effect.allow, try types.Effect.parse("allow"));
    try std.testing.expectEqual(types.Effect.deny, try types.Effect.parse("deny"));
}

test "Policy types - RequestContext" {
    const ctx = types.RequestContext.init("agent-1", "/api/test", .GET);

    try std.testing.expectEqualStrings("agent-1", ctx.agent_id);
    try std.testing.expectEqualStrings("/api/test", ctx.path);
    try std.testing.expectEqual(types.Method.GET, ctx.method);
}