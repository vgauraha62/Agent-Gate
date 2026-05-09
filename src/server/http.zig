//! HTTP Server - Async with sync fallback
//! Day 5: HTTP Server Foundation (Enhanced)
//!
//! Primary: Async server using epoll for high concurrency
//! Fallback: Synchronous POSIX sockets

const std = @import("std");
const c = std.c;
const auth = @import("auth_middleware.zig");
const types = @import("../policy/types.zig");
const audit = @import("../audit/logger.zig");
const prometheus = @import("../metrics/prometheus.zig");

const EPOLLIN: u32 = 0x001;
const EPOLLOUT: u32 = 0x004;
const EPOLL_CTL_ADD: c_int = 1;
const EPOLL_CTL_MOD: c_int = 2;
const EPOLL_CTL_DEL: c_int = 3;

pub const HttpStatus = enum(u16) {
    ok = 200,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    internal_error = 500,
};

pub const CheckRequest = struct {
    path: []const u8,
    method: []const u8,
};

pub const ServerMode = enum {
    async_epoll,
    sync_posix,
};

pub fn statusText(status: HttpStatus) []const u8 {
    return switch (status) {
        .ok => "OK",
        .bad_request => "Bad Request",
        .unauthorized => "Unauthorized",
        .forbidden => "Forbidden",
        .not_found => "Not Found",
        .internal_error => "Internal Server Error",
    };
}

pub const RequestLine = struct {
    method: types.Method,
    path: []const u8,
    http_version: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    audit_logger: *audit.AuditLogger,
    policies: []const types.Policy,
    secret_key: []const u8,
    mode: ServerMode = .async_epoll,
    epoll_fd: c_int = -1,
    listen_fd: c_int = -1,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        audit_logger: *audit.AuditLogger,
        policies: []const types.Policy,
        secret_key: []const u8,
        mode: ServerMode,
    ) Self {
        return Self{
            .allocator = allocator,
            .port = port,
            .audit_logger = audit_logger,
            .policies = policies,
            .secret_key = secret_key,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.epoll_fd >= 0) {
            _ = c.close(self.epoll_fd);
        }
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
        }
    }

    pub fn run(self: *Self) !void {
        std.debug.print("[HTTP Server] Starting on port {d} in {s} mode\n", .{
            self.port,
            if (self.mode == .async_epoll) "async (epoll)" else "sync (POSIX sockets)",
        });

        switch (self.mode) {
            .async_epoll => try self.runAsyncEpoll(),
            .sync_posix => try self.runSyncPosix(),
        }
    }

    fn runAsyncEpoll(self: *Self) !void {
        self.listen_fd = c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (self.listen_fd < 0) return error.SocketCreateFailed;

        const reuse: c_int = 1;
        _ = c.setsockopt(self.listen_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));

        var addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = @byteSwap(self.port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };

        if (c.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (c.listen(self.listen_fd, 128) < 0) return error.ListenFailed;

        self.epoll_fd = c.epoll_create1(0);
        if (self.epoll_fd < 0) return error.EpollCreateFailed;

        var event = std.c.epoll_event{
            .events = EPOLLIN,
            .data = .{ .fd = self.listen_fd },
        };
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, self.listen_fd, &event);

        std.debug.print("[HTTP Server] Async server (epoll) listening on port {d}\n", .{self.port});

        var events: [64]std.c.epoll_event = undefined;

        while (true) {
            const num_events = c.epoll_wait(self.epoll_fd, &events, events.len, 1000);
            if (num_events < 0) continue;

            var i: usize = 0;
            while (i < @as(usize, @intCast(num_events))) : (i += 1) {
                const fd = events[i].data.fd;

                if (fd == self.listen_fd) {
                    var client_addr: std.posix.sockaddr.in = undefined;
                    var addr_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
                    const client_fd = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);

                    if (client_fd >= 0) {
                        var client_event = std.c.epoll_event{
                            .events = EPOLLIN,
                            .data = .{ .fd = client_fd },
                        };
                        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, client_fd, &client_event);
                    }
                } else {
                    self.handleEpollClient(fd) catch {};
                }
            }
        }
    }

    fn handleEpollClient(self: *Self, client_fd: c_int) !void {
        defer {
            _ = c.epoll_ctl(@as(c_int, @intCast(self.getEpollFd())), EPOLL_CTL_DEL, client_fd, null);
            _ = c.close(client_fd);
        }

        var buf: [8192]u8 = undefined;
        const bytes_read = c.read(client_fd, &buf, buf.len);

        if (bytes_read <= 0) return;

        prometheus.global_metrics.incRequests();

        const request_str = buf[0..@as(usize, @intCast(bytes_read))];
        const parsed = self.parseHttpRequest(request_str) catch {
            self.sendErrorResponse(client_fd, .bad_request, "invalid request");
            return;
        };

        std.debug.print("[HTTP Server] {s} {s}\n", .{ parsed.method, parsed.path });

        if (std.mem.eql(u8, parsed.path, "/health") and std.mem.eql(u8, parsed.method, "GET")) {
            self.sendHealthResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/metrics") and std.mem.eql(u8, parsed.method, "GET")) {
            self.sendMetricsResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
            self.sendCheckResponse(client_fd, parsed.body);
        } else {
            self.sendNotFoundResponse(client_fd);
        }
    }

    fn getEpollFd(self: *Self) c_int {
        return self.epoll_fd;
    }

    fn runSyncPosix(self: *Self) !void {
        const listen_fd = c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (listen_fd < 0) return error.SocketCreateFailed;
        defer _ = c.close(listen_fd);

        const reuse: c_int = 1;
        _ = c.setsockopt(listen_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));

        var addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = @byteSwap(self.port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };

        if (c.bind(listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (c.listen(listen_fd, 128) < 0) return error.ListenFailed;

        std.debug.print("[HTTP Server] Sync server listening on port {d}\n", .{self.port});

        while (true) {
            var client_addr: std.posix.sockaddr.in = undefined;
            var addr_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
            const client_fd = c.accept(listen_fd, @ptrCast(&client_addr), &addr_len);

            if (client_fd < 0) continue;

            self.handleConnection(client_fd);
        }
    }

    fn handleConnection(self: *Self, client_fd: c_int) void {
        defer _ = c.close(client_fd);

        var buf: [8192]u8 = undefined;
        const bytes_read = c.read(client_fd, &buf, buf.len);

        if (bytes_read <= 0) return;

        prometheus.global_metrics.incRequests();

        const request_str = buf[0..@as(usize, @intCast(bytes_read))];
        const parsed = self.parseHttpRequest(request_str) catch {
            self.sendErrorResponse(client_fd, .bad_request, "invalid request");
            return;
        };

        std.debug.print("[HTTP Server] {s} {s}\n", .{ parsed.method, parsed.path });

        if (std.mem.eql(u8, parsed.path, "/health") and std.mem.eql(u8, parsed.method, "GET")) {
            self.sendHealthResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/metrics") and std.mem.eql(u8, parsed.method, "GET")) {
            self.sendMetricsResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
            self.sendCheckResponse(client_fd, parsed.body);
        } else {
            self.sendNotFoundResponse(client_fd);
        }
    }

    fn parseHttpRequest(_: *Self, buf: []const u8) !struct { method: []const u8, path: []const u8, body: []const u8 } {
        var line_end: usize = 0;
        while (line_end < buf.len and buf[line_end] != '\r') line_end += 1;

        if (line_end == 0) return error.InvalidRequest;

        const request_line = buf[0..line_end];
        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        var body_start = line_end + 2;
        while (body_start < buf.len and buf[body_start] != '\n') body_start += 1;
        if (body_start < buf.len) body_start += 1;

        const body = if (body_start < buf.len) buf[body_start..] else "";

        return .{ .method = method, .path = path, .body = body };
    }

    fn parseCheckRequest(_: *Self, body: []const u8) CheckRequest {
        if (body.len == 0) {
            return CheckRequest{ .path = "/", .method = "GET" };
        }

        var result = CheckRequest{ .path = "/", .method = "GET" };

        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return result;
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                if (obj.get("path")) |v| {
                    if (v == .string) result.path = v.string;
                }
                if (obj.get("method")) |v| {
                    if (v == .string) result.method = v.string;
                }
            },
            else => {},
        }

        return result;
    }

    fn sendHealthResponse(self: *Self, client_fd: c_int) void {
        const body_mode = if (self.mode == .async_epoll) "async-epoll" else "sync-posix";
        var body_buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"status\":\"ok\",\"mode\":\"{s}\"}}\n", .{body_mode}) catch return;

        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        ) catch return;

        _ = c.write(client_fd, header.ptr, header.len);
        _ = c.write(client_fd, body.ptr, body.len);
    }

    fn sendMetricsResponse(_: *Self, client_fd: c_int) void {
        const export_buf = prometheus.global_metrics.exportMetrics();
        const body_len = export_buf.len + 1;

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\n\r\n",
            .{body_len},
        ) catch return;

        _ = c.write(client_fd, header.ptr, header.len);
        _ = c.write(client_fd, export_buf.ptr, export_buf.len);
        _ = c.write(client_fd, "\n", 1);
    }

    fn sendCheckResponse(self: *Self, client_fd: c_int, body: []const u8) void {
        const check_req = self.parseCheckRequest(body);

        const ctx = types.RequestContext.init(
            "agent",
            check_req.path,
            types.Method.parse(check_req.method) catch .GET,
        );

        const policy_set = types.PolicySet{ .policies = self.policies };
        const effect = policy_set.evaluate(&ctx);

        var response_body: [256]u8 = undefined;
        var response: []const u8 = undefined;

        if (effect == .allow) {
            prometheus.global_metrics.incAllowed();
            response = std.fmt.bufPrint(&response_body, "{{\"allowed\":true,\"policy_id\":\"allow\",\"mode\":\"{s}\"}}\n", .{
                if (self.mode == .async_epoll) "async-epoll" else "sync-posix"
            }) catch return;
        } else {
            prometheus.global_metrics.incDenied();
            response = std.fmt.bufPrint(&response_body, "{{\"allowed\":false,\"reason\":\"policy denied\",\"mode\":\"{s}\"}}\n", .{
                if (self.mode == .async_epoll) "async-epoll" else "sync-posix"
            }) catch return;
        }

        const status_code: u16 = if (effect == .allow) 200 else 403;
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ status_code, response.len },
        ) catch return;

        _ = c.write(client_fd, header.ptr, header.len);
        _ = c.write(client_fd, response.ptr, response.len);
    }

    fn sendNotFoundResponse(self: *Self, client_fd: c_int) void {
        var body_buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"not found\",\"mode\":\"{s}\"}}\n", .{
            if (self.mode == .async_epoll) "async-epoll" else "sync-posix"
        }) catch return;

        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        ) catch return;

        _ = c.write(client_fd, header.ptr, header.len);
        _ = c.write(client_fd, body.ptr, body.len);
    }

    fn sendErrorResponse(_: *Self, client_fd: c_int, status: HttpStatus, message: []const u8) void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"{s}\"}}\n", .{message}) catch return;

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ @intFromEnum(status), statusText(status), body.len },
        ) catch return;

        _ = c.write(client_fd, header.ptr, header.len);
        _ = c.write(client_fd, body.ptr, body.len);
    }
};

test "Server init async" {
    const allocator = std.heap.page_allocator;
    var logger = audit.AuditLogger.init(allocator);
    defer logger.deinit();

    const policies = &[_]types.Policy{};
    const server = Server.init(allocator, 8080, &logger, policies, "test-secret", .async_epoll);

    try std.testing.expectEqual(@as(u16, 8080), server.port);
    try std.testing.expectEqual(ServerMode.async_epoll, server.mode);
}

test "Server init sync" {
    const allocator = std.heap.page_allocator;
    var logger = audit.AuditLogger.init(allocator);
    defer logger.deinit();

    const policies = &[_]types.Policy{};
    const server = Server.init(allocator, 8080, &logger, policies, "test-secret", .sync_posix);

    try std.testing.expectEqual(@as(u16, 8080), server.port);
    try std.testing.expectEqual(ServerMode.sync_posix, server.mode);
}

test "Server statusText" {
    try std.testing.expectEqualStrings("OK", statusText(.ok));
    try std.testing.expectEqualStrings("Bad Request", statusText(.bad_request));
    try std.testing.expectEqualStrings("Unauthorized", statusText(.unauthorized));
    try std.testing.expectEqualStrings("Forbidden", statusText(.forbidden));
}

test "Server parse HTTP request valid" {
    const allocator = std.heap.page_allocator;
    var logger = audit.AuditLogger.init(allocator);
    defer logger.deinit();

    var server = Server.init(allocator, 8080, &logger, &[_]types.Policy{}, "secret", .async_epoll);

    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const parsed = try server.parseHttpRequest(raw);

    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/health", parsed.path);
}

test "Server parse HTTP request with body" {
    const allocator = std.heap.page_allocator;
    var logger = audit.AuditLogger.init(allocator);
    defer logger.deinit();

    var server = Server.init(allocator, 8080, &logger, &[_]types.Policy{}, "secret", .sync_posix);

    const raw = "POST /check HTTP/1.1\r\n\r\n{\"path\":\"/api/test\"}";
    const parsed = try server.parseHttpRequest(raw);

    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqualStrings("/check", parsed.path);
    try std.testing.expectEqualStrings("{\"path\":\"/api/test\"}", parsed.body);
}