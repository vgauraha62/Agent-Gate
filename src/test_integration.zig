const std = @import("std");
const http = @import("server/http.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");

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
    var audit_logger = audit.AuditLogger.init(std.heap.page_allocator);
    defer audit_logger.deinit();

    const policies = &[_]types.Policy{types.Policy{
        .id = "test",
        .effect = .allow,
        .conditions = &[_]types.Condition{},
    }};

    const server = http.Server.init(std.heap.page_allocator, 8080, &audit_logger, policies, "secret-key", .async_epoll);

    try std.testing.expectEqual(@as(u16, 8080), server.port);
}

test "AuditLogger log entry" {
    var logger = audit.AuditLogger.init(std.heap.page_allocator);
    defer logger.deinit();

    try logger.log("agent-1", "/api/test", "GET", "allow", "test-policy");

    try std.testing.expectEqual(@as(usize, 1), logger.entryCount());

    const entry = logger.getEntry(0);
    try std.testing.expect(entry != null);
}

test "AuditLogger ring buffer wrap" {
    var logger = audit.AuditLogger.init(std.heap.page_allocator);
    defer logger.deinit();

    for (0..audit.MAX_ENTRIES + 5) |i| {
        const path = std.fmt.allocPrint(std.heap.page_allocator, "/api/test/{d}", .{i}) catch @panic("OOM");
        defer std.heap.page_allocator.free(path);
        try logger.log("agent-1", path, "GET", "allow", "test-policy");
    }

    try std.testing.expectEqual(audit.MAX_ENTRIES, logger.entryCount());
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