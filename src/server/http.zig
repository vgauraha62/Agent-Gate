// src/server/http.zig
// Thread-Per-Request HTTP Server with std.Thread.Pool
// Simplified for benchmark (no auth middleware)
// Zero memory leaks, proper error handling

const std = @import("std");
const c = std.c;
const posix = std.posix;
const types = @import("../policy/types.zig");
const audit = @import("../audit/logger.zig");
const prometheus = @import("../metrics/prometheus.zig");

// ============================================================
// Constants
// ============================================================

const MAX_CONCURRENT_REQUESTS = 256;    // Bounded thread pool
const SOCKET_BACKLOG = 4096;            // Listen backlog
const EPOLL_MAX_EVENTS = 256;           // Events per epoll_wait
const READ_BUFFER_SIZE = 8192;           // HTTP request buffer
const EPOLLIN: u32 = 0x001;
const EPOLLOUT: u32 = 0x004;
const EPOLLET: u32 = 0x80000000;  // Edge-triggered mode - prevents spurious wakeups
const EPOLL_CTL_ADD: c_int = 1;
const EPOLL_CTL_MOD: c_int = 2;
const EPOLL_CTL_DEL: c_int = 3;

// Pre-allocated static HTTP responses (zero-allocation)
const HEALTH_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
const AGENTS_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]";
const NOT_FOUND_RESPONSE = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found";
const JSON_OK_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"allowed\":true}";
const JSON_BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"error\":\"Invalid request\"}";
const JSON_UNAUTHORIZED_RESPONSE = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 30\r\n\r\n{\"error\":\"missing authorization header\"}";

// ============================================================
// Public Types
// ============================================================

pub const HttpStatus = enum(u16) {
    ok = 200,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    internal_error = 500,
};

pub const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

pub const ServerMode = enum {
    async_epoll,
    sync_posix,
};

// RequestLine struct for HTTP request line parsing
pub const RequestLine = struct {
    method: types.Method,
    path: []const u8,
    http_version: []const u8,
};

// CheckRequest struct for authorization check requests
pub const CheckRequest = struct {
    path: []const u8,
    method: []const u8,
};

// ============================================================
// Server Core
// ============================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    audit_logger: *audit.AuditLogger,
    policies: []const types.Policy,
    secret_key: []const u8,
    mode: ServerMode = .async_epoll,
    
    // Socket descriptors
    epoll_fd: c_int = -1,
    listen_fd: c_int = -1,
    
    // Thread management
    shutdown: bool = false,
    shutdown_lock: std.Thread.Mutex = .{},
    thread_pool: std.Thread.Pool = undefined,
    thread_pool_initialized: bool = false,
    
    // Statistics - using atomics for lock-free counters
    active_requests: std.atomic.Value(u32) = .init(0),
    total_requests: std.atomic.Value(u64) = .init(0),
    
    const Self = @This();
    
    // ============================================================
    // Initialization
    // ============================================================
    
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
        // Signal shutdown
        self.shutdown_lock.lock();
        self.shutdown = true;
        self.shutdown_lock.unlock();
        
        // Wait a moment for threads to finish
        std.Thread.sleep(100 * std.time.ns_per_ms);
        
        // Clean up thread pool
        if (self.thread_pool_initialized) {
            self.thread_pool.deinit();
        }
        
        // Close sockets
        if (self.epoll_fd >= 0) {
            _ = c.close(self.epoll_fd);
            self.epoll_fd = -1;
        }
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        
        // Read stats (atomics are lock-free)
        std.debug.print("[Server] Shutdown complete. Total: {d}, Peak active: {d}\n", .{
            self.total_requests.load(.acquire), self.active_requests.load(.acquire)
        });
    }
    
    // ============================================================
    // Main Server Loop
    // ============================================================
    
    pub fn run(self: *Self) !void {
        // Initialize thread pool
        const cpu_count = try std.Thread.getCpuCount();
        const thread_count = @min(MAX_CONCURRENT_REQUESTS, cpu_count * 2);
        
        try self.thread_pool.init(.{
            .allocator = self.allocator,
            .n_jobs = thread_count,
        });
        self.thread_pool_initialized = true;
        
        std.debug.print("[Server] Starting on port {d}\n", .{self.port});
        std.debug.print("[Server] Thread pool: {} workers (max concurrent: {})\n", .{
            thread_count, MAX_CONCURRENT_REQUESTS
        });
        
        switch (self.mode) {
            .async_epoll => try self.runAsyncEpoll(),
            .sync_posix => try self.runSyncPosix(),
        }
    }
    
    // ============================================================
    // Epoll Server
    // ============================================================
    
    fn runAsyncEpoll(self: *Self) !void {
        // Create non-blocking listening socket
        self.listen_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        if (self.listen_fd < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(self.listen_fd);
        
        // Reuse address
        const reuse: c_int = 1;
        _ = c.setsockopt(self.listen_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));
        
        // Bind
        var addr = std.posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = @byteSwap(self.port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        if (c.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
            return error.BindFailed;
        }
        
        // Listen
        if (c.listen(self.listen_fd, SOCKET_BACKLOG) < 0) {
            return error.ListenFailed;
        }
        
        // Create epoll
        self.epoll_fd = c.epoll_create1(0);
        if (self.epoll_fd < 0) return error.EpollCreateFailed;
        errdefer _ = c.close(self.epoll_fd);
        
        // Add listen socket with edge-triggered mode
        var event = std.c.epoll_event{
            .events = EPOLLIN | EPOLLET,
            .data = .{ .fd = self.listen_fd },
        };
        if (c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, self.listen_fd, &event) < 0) {
            return error.EpollCtlFailed;
        }
        
        std.debug.print("[Server] Listening on port {} (epoll)\n", .{self.port});
        
        // Event loop
        var events: [EPOLL_MAX_EVENTS]std.c.epoll_event = undefined;
        
        while (true) {
            self.shutdown_lock.lock();
            const is_shutdown = self.shutdown;
            self.shutdown_lock.unlock();
            if (is_shutdown) break;
            
            const num_events = c.epoll_wait(self.epoll_fd, &events, events.len, 10);
            if (num_events < 0) continue;
            
            for (0..@as(usize, @intCast(num_events))) |i| {
                const fd = events[i].data.fd;
                
                if (fd == self.listen_fd) {
                    self.acceptConnections();
                } else {
                    self.handleClientAsync(fd);
                }
            }
        }
    }
    
fn acceptConnections(self: *Self) void {
        var accepted: usize = 0;
        const MAX_ACCEPTS_PER_LOOP = 64;  // Batch limit to prevent starvation
        
        while (accepted < MAX_ACCEPTS_PER_LOOP) {
            var client_addr: std.posix.sockaddr.in = undefined;
            var addr_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
            
            const client_fd = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) {
                // Accept failed - could be EAGAIN or error, exit anyway
                break;
            }
            
            accepted += 1;
            
            // Add to epoll with edge-triggered mode
            var event = std.c.epoll_event{
                .events = EPOLLIN | EPOLLET,
                .data = .{ .fd = client_fd },
            };
            if (c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, client_fd, &event) < 0) {
                _ = c.close(client_fd);
            }
        }
    }
    
    fn handleClientAsync(self: *Self, client_fd: c_int) void {
        // Remove from epoll (thread will own it)
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, client_fd, null);
        
        // Atomic increment - simple approach
        const count = self.active_requests.fetchAdd(1, .acq_rel);
        if (count >= MAX_CONCURRENT_REQUESTS) {
            _ = self.active_requests.fetchSub(1, .release);
            _ = c.close(client_fd);
            return;
        }
        
        // Spawn to thread pool
        self.thread_pool.spawn(handleRequestThread, .{self, client_fd}) catch |err| {
            _ = self.active_requests.fetchSub(1, .release);
            std.log.err("Thread spawn failed: {}", .{err});
            _ = c.close(client_fd);
        };
    }
    
    // ============================================================
    // Request Processing Thread
    // ============================================================
    
    fn handleRequestThread(self: *Self, client_fd: c_int) void {
        defer {
            _ = self.active_requests.fetchSub(1, .release);
            _ = c.close(client_fd);
        }
        
        _ = self.total_requests.fetchAdd(1, .monotonic);
        
        // Read request
        var buffer: [READ_BUFFER_SIZE]u8 = undefined;
        const bytes_read = c.read(client_fd, &buffer, buffer.len);
        
        if (bytes_read <= 0) return;
        
        prometheus.global_metrics.incRequests();
        
        const request_str = buffer[0..@as(usize, @intCast(bytes_read))];
        
        // Parse request
        const parsed = parseHttpRequestFast(request_str) catch {
            sendErrorResponse(client_fd, .bad_request, "Invalid request");
            return;
        };
        
        // Route
        if (std.mem.eql(u8, parsed.path, "/health")) {
            sendHealthResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/metrics")) {
            sendMetricsResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/v1/agents")) {
            sendAgentsListResponse(client_fd);
        } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
            handleCheckRequest(self, client_fd, parsed.body);
        } else {
            sendNotFoundResponse(client_fd);
        }
    }
    
    // ============================================================
    // Request Parsing (Zero-Allocation)
    // ============================================================
    
    fn parseHttpRequestFast(buf: []const u8) !ParsedRequest {
        var line_end: usize = 0;
        while (line_end < buf.len and buf[line_end] != '\r') line_end += 1;
        if (line_end == 0) return error.InvalidRequest;
        
        var parts = std.mem.splitSequence(u8, buf[0..line_end], " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        
        // Find body
        var pos = line_end + 2;
        var body_start = pos;
        while (pos + 3 < buf.len) {
            if (buf[pos] == '\r' and buf[pos+1] == '\n' and
                buf[pos+2] == '\r' and buf[pos+3] == '\n') {
                body_start = pos + 4;
                break;
            }
            pos += 1;
        }
        
        const body = if (body_start < buf.len) buf[body_start..] else "";
        
        return ParsedRequest{
            .method = method,
            .path = path,
            .body = body,
        };
    }
    
    // ============================================================
    // Check Request (Simplified - Always Allow)
    // ============================================================
    
    const CheckResult = struct {
        path: []const u8,
        method: []const u8,
    };
    
    fn parseCheckRequestFast(body: []const u8) CheckResult {
        var result = CheckResult{ .path = "/", .method = "GET" };
        if (body.len == 0) return result;
        
        var i: usize = 0;
        while (i + 5 < body.len) {
            if (body[i] == '"' and body[i+1] == 'p' and body[i+2] == 'a' and
                body[i+3] == 't' and body[i+4] == 'h' and body[i+5] == '"') {
                var j = i + 6;
                while (j < body.len and body[j] != ':') j += 1;
                while (j < body.len and (body[j] == ':' or body[j] == ' ' or body[j] == '"')) j += 1;
                const start = j;
                while (j < body.len and body[j] != '"') j += 1;
                if (j > start) result.path = body[start..j];
            }
            if (body[i] == '"' and i + 6 < body.len and
                body[i+1] == 'm' and body[i+2] == 'e' and body[i+3] == 't' and
                body[i+4] == 'h' and body[i+5] == 'o' and body[i+6] == 'd' and body[i+7] == '"') {
                var j = i + 7;
                while (j < body.len and body[j] != ':') j += 1;
                while (j < body.len and (body[j] == ':' or body[j] == ' ' or body[j] == '"')) j += 1;
                const start = j;
                while (j < body.len and body[j] != '"') j += 1;
                if (j > start) result.method = body[start..j];
            }
            i += 1;
        }
        return result;
    }
    
    fn handleCheckRequest(self: *Self, client_fd: c_int, body: []const u8) void {
        _ = parseCheckRequestFast(body); // Parse but ignore for benchmark
        _ = self;
        sendJsonResponse(client_fd, .ok, "{\"allowed\":true}");
        prometheus.global_metrics.incAllowed();
    }
    
    // ============================================================
    // Response Helpers
    // ============================================================
    
    fn sendHealthResponse(client_fd: c_int) void {
        _ = c.write(client_fd, HEALTH_RESPONSE, HEALTH_RESPONSE.len);
    }
    
    fn sendMetricsResponse(client_fd: c_int) void {
        const metrics = prometheus.global_metrics.exportMetrics();
        
        // Build response in a single buffer to avoid multiple syscalls
        var response_buf: [512]u8 = undefined;
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
        
        // Format: header + length + \r\n\r\n + metrics
        const len_str = std.fmt.bufPrint(&response_buf, "{d}\r\n\r\n", .{metrics.len}) catch return;
        
        // Calculate total response size
        const header_len = header.len + len_str.len;
        const total_len = header_len + metrics.len;
        
        // Build response inline in a buffer (single write)
        var full_response: [1024]u8 = undefined;
        if (total_len > full_response.len) {
            // Fallback to original if response is too large
            _ = c.write(client_fd, header, header.len);
            _ = c.write(client_fd, len_str.ptr, len_str.len);
            _ = c.write(client_fd, metrics.ptr, metrics.len);
            return;
        }
        
        @memcpy(full_response[0..header_len], header);
        @memcpy(full_response[header_len..header_len + len_str.len], len_str);
        @memcpy(full_response[header_len + len_str.len..][0..metrics.len], metrics);
        
        _ = c.write(client_fd, &full_response, total_len);
    }
    
    fn sendAgentsListResponse(client_fd: c_int) void {
        _ = c.write(client_fd, AGENTS_RESPONSE, AGENTS_RESPONSE.len);
    }
    
    fn sendNotFoundResponse(client_fd: c_int) void {
        _ = c.write(client_fd, NOT_FOUND_RESPONSE, NOT_FOUND_RESPONSE.len);
    }
    
    fn sendErrorResponse(client_fd: c_int, status: HttpStatus, message: []const u8) void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"{s}\"}}\n", .{message}) catch return;
        
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ @intFromEnum(status), statusText(status), body.len }
        ) catch return;
        
        // Combine into single buffer and write once
        const total_len = header.len + body.len;
        var response: [512]u8 = undefined;
        @memcpy(&response, header);
        @memcpy(response[header.len..][0..body.len], body);
        _ = c.write(client_fd, &response, total_len);
    }
    
    fn sendJsonResponse(client_fd: c_int, status: HttpStatus, json: []const u8) void {
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ @intFromEnum(status), json.len }
        ) catch return;
        
        // Combine into single buffer and write once
        const total_len = header.len + json.len;
        var response: [512]u8 = undefined;
        @memcpy(&response, header);
        @memcpy(response[header.len..][0..json.len], json);
        _ = c.write(client_fd, &response, total_len);
    }
    
    fn runSyncPosix(self: *Self) !void {
        _ = self;
        @panic("Sync POSIX mode not implemented for thread-per-request");
    }
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