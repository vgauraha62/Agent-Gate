// src/server/http_async.zig
// Fully Async I/O HTTP Server using epoll
// Minimal implementation - no thread pool, inline request processing

const std = @import("std");
const c = std.c;
const posix = std.posix;
const types = @import("../policy/types.zig");
const audit = @import("../audit/logger.zig");
const prometheus = @import("../metrics/prometheus.zig");
const config = @import("../config.zig");
const hosted = @import("../hosted.zig");

// ============================================================
// Constants
// ============================================================

const MAX_FDS = 256;                     // Max fds to track
const SOCKET_BACKLOG = 4096;            // Listen backlog
const EPOLL_MAX_EVENTS = 64;            // Events per epoll_wait
const READ_BUFFER_SIZE = 8192;          // HTTP request buffer
const WRITE_BUFFER_SIZE = 8192;         // Response buffer

const EPOLLIN: u32 = 0x001;
const EPOLLOUT: u32 = 0x004;
const EPOLLET: u32 = 0x80000000;
const EPOLL_CTL_ADD: c_int = 1;
const EPOLL_CTL_MOD: c_int = 2;
const EPOLL_CTL_DEL: c_int = 3;

// Pre-allocated static HTTP responses
const HEALTH_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
const AGENTS_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]";
const NOT_FOUND_RESPONSE = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found";
const JSON_BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"error\":\"Invalid request\"}";

// ============================================================
// Public Types
// ============================================================

pub const ServerMode = enum {
    async_epoll,
    sync_posix,
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
    
    // Statistics
    total_requests: u64 = 0,
    
    // Hosted API context (optional)
    hosted_ctx: ?*hosted.HostedContext = null,
    
    const Self = @This();
    
    // ============================================================
    // Initialization
    // ============================================================
    
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config.Config,
        audit_logger: *audit.AuditLogger,
        policies: []const types.Policy,
    ) Self {
        return Self{
            .allocator = allocator,
            .port = cfg.server.port,
            .audit_logger = audit_logger,
            .policies = policies,
            .secret_key = cfg.auth.jwt_secret,
            .mode = .async_epoll,
        };
    }
    
    /// Set the hosted API context (enables admin endpoints and API key auth).
    pub fn setHostedContext(self: *Self, ctx: *hosted.HostedContext) void {
        self.hosted_ctx = ctx;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown_lock.lock();
        self.shutdown = true;
        self.shutdown_lock.unlock();
        
        // Close sockets
        if (self.epoll_fd >= 0) {
            _ = c.close(self.epoll_fd);
            self.epoll_fd = -1;
        }
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        
        std.debug.print("[Server] Shutdown complete. Total: {d}\n", .{self.total_requests});
    }
    
    // ============================================================
    // Main Server Loop
    // ============================================================
    
    pub fn run(self: *Self) !void {
        std.debug.print("[Server] Starting on port {d}\n", .{self.port});
        std.debug.print("[Server] Async I/O mode (epoll, single-threaded)\n", .{});
        
        switch (self.mode) {
            .async_epoll => try self.runAsyncEpoll(),
            .sync_posix => try self.runSyncPosix(),
        }
    }
    
    // ============================================================
    // Epoll Server (Fully Async)
    // ============================================================
    
    fn runAsyncEpoll(self: *Self) !void {
        // Create non-blocking listening socket
        self.listen_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        if (self.listen_fd < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(self.listen_fd);
        
        // Reuse address
        const reuse: c_int = 1;
        _ = c.setsockopt(self.listen_fd, 1, 2, &reuse, @sizeOf(c_int)); // SOL_SOCKET=1, SO_REUSEADDR=2
        
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
        var read_buffer: [READ_BUFFER_SIZE]u8 = undefined;
        var write_buffer: [WRITE_BUFFER_SIZE]u8 = undefined;
        
        while (true) {
            // Check shutdown
            self.shutdown_lock.lock();
            const is_shutdown = self.shutdown;
            self.shutdown_lock.unlock();
            if (is_shutdown) break;
            
            const num_events = c.epoll_wait(self.epoll_fd, &events, events.len, 10);
            if (num_events < 0) continue;
            
            for (0..@as(usize, @intCast(num_events))) |i| {
                const fd = events[i].data.fd;
                const events_mask = events[i].events;
                
                if (fd == self.listen_fd) {
                    // Accept incoming connections
                    self.acceptConnection(&read_buffer, &write_buffer);
                    continue;
                }
                
                // Check for error conditions
                const is_error = (events_mask & 0x8) != 0 or (events_mask & 0x10) != 0 or (events_mask & 0x20) != 0;
                if (is_error) {
                    _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
                    _ = c.close(fd);
                    continue;
                }
                
                // Handle read event
                if ((events_mask & EPOLLIN) != 0) {
                    self.handleClientRead(fd, &read_buffer, &write_buffer);
                }
                
                // Handle write event
                if ((events_mask & EPOLLOUT) != 0) {
                    self.handleClientWrite(fd, &write_buffer);
                }
            }
        }
    }
    
    fn acceptConnection(self: *Self, read_buffer: []u8, write_buffer: []u8) void {
        var client_addr: std.posix.sockaddr.in = undefined;
        var addr_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
        
        const client_fd = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
        if (client_fd < 0) return;
        
        // Add to epoll for reading
        var event = std.c.epoll_event{
            .events = EPOLLIN | EPOLLOUT | EPOLLET,
            .data = .{ .fd = client_fd },
        };
        if (c.epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, client_fd, &event) < 0) {
            _ = c.close(client_fd);
            return;
        }
        
        // Immediately read and respond (simplified for benchmark)
        const start_time = std.time.nanoTimestamp();
        const allowed = self.handleClientRequest(client_fd, read_buffer, write_buffer);
        const end_time = std.time.nanoTimestamp();
        const diff = end_time - start_time;
        const latency_us = @as(u64, @intCast(@divTrunc(diff, 1000)));
        prometheus.global_metrics.recordRequest(latency_us, allowed);
    }
    
    fn handleClientRead(self: *Self, fd: c_int, read_buffer: []u8, write_buffer: []u8) void {
        // Start timing
        const start_time = std.time.nanoTimestamp();

        const n = c.read(fd, read_buffer.ptr, read_buffer.len);
        if (n <= 0) {
            _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
            _ = c.close(fd);
            return;
        }

        self.total_requests += 1;
        // Note: requests_total is incremented by recordRequest() below - do NOT add incRequests() here

        // Process request inline - get decision for metrics
        const allowed = self.handleClientRequest(fd, read_buffer[0..@as(usize, @intCast(n))], write_buffer);

        // Record latency
        const end_time = std.time.nanoTimestamp();
        const diff = end_time - start_time;
        const latency_us = @as(u64, @intCast(@divTrunc(diff, 1000)));
        prometheus.global_metrics.recordRequest(latency_us, allowed);
    }
    
    fn handleClientWrite(self: *Self, fd: c_int, write_buffer: []u8) void {
        _ = self;
        _ = fd;
        _ = write_buffer;
    }
    
    fn handleClientRequest(self: *Self, fd: c_int, request_data: []u8, write_buffer: []u8) bool {
        // Parse HTTP request
        const parsed = self.parseRequest(request_data) catch {
            self.sendError(fd, write_buffer, 400, "Invalid request");
            return false;
        };

        // Route and respond - return whether request was allowed
        if (std.mem.eql(u8, parsed.path, "/health")) {
            self.sendStatic(fd, write_buffer, HEALTH_RESPONSE);
            return false;
        } else if (std.mem.eql(u8, parsed.path, "/metrics")) {
            self.sendMetrics(fd, write_buffer);
            return false;
        } else if (std.mem.eql(u8, parsed.path, "/v1/agents")) {
            self.sendStatic(fd, write_buffer, AGENTS_RESPONSE);
            return false;
        } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
            // Parse request body to get path
            const body = request_data;
            const check = parseCheckRequest(body);
            
            // Simple demo policy: deny paths starting with /admin or /secret or /system
            const is_denied = std.mem.startsWith(u8, check.path, "/admin") or
                              std.mem.startsWith(u8, check.path, "/secret") or
                              std.mem.startsWith(u8, check.path, "/system");
            
            if (is_denied) {
                self.sendJson(fd, write_buffer, "{\"allowed\":false,\"reason\":\"policy denied\",\"policy_id\":\"demo-deny-policy\"}");
                return false;
            } else {
                self.sendJson(fd, write_buffer, "{\"allowed\":true}");
                return true;
            }
        } else {
            self.sendStatic(fd, write_buffer, NOT_FOUND_RESPONSE);
            return false;
        }
    }
    
    fn sendStatic(self: *Self, fd: c_int, buffer: []u8, response: []const u8) void {
        if (response.len > buffer.len) {
            _ = c.write(fd, response.ptr, response.len);
        } else {
            @memcpy(buffer[0..response.len], response);
            _ = c.write(fd, buffer.ptr, response.len);
        }
        
        // Close connection after response
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
        _ = c.close(fd);
    }
    
    fn sendJson(self: *Self, fd: c_int, buffer: []u8, json: []const u8) void {
        const header_len = std.fmt.bufPrint(buffer,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{json.len}
        ) catch {
            self.sendStatic(fd, buffer, JSON_BAD_REQUEST_RESPONSE);
            return;
        };
        
        const copy_len = @min(header_len.len + json.len, buffer.len);
        @memcpy(buffer[header_len.len..copy_len], json[0..copy_len - header_len.len]);
        
        _ = c.write(fd, buffer.ptr, copy_len);
        
        // Close connection after response
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
        _ = c.close(fd);
    }
    
    fn sendError(self: *Self, fd: c_int, buffer: []u8, status: u16, message: []const u8) void {
        const body = std.fmt.bufPrint(buffer, "{{\"error\":\"{s}\"}}\n", .{message}) catch return;
        const status_text: []const u8 = switch (status) {
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            else => "Error",
        };
        
        const header_len = std.fmt.bufPrint(buffer,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ status, status_text, body.len }
        ) catch return;
        
        const copy_len = @min(header_len.len + body.len, buffer.len);
        @memcpy(buffer[header_len.len..copy_len], body[0..copy_len - header_len.len]);
        
        _ = c.write(fd, buffer.ptr, copy_len);
        
        // Close connection after error
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
        _ = c.close(fd);
    }
    
    fn sendMetrics(self: *Self, fd: c_int, buffer: []u8) void {
        _ = buffer; // Not used in this simplified implementation
        const metrics = prometheus.global_metrics.exportMetrics();
        
        // Simple approach: write parts separately to avoid any buffer issues
        const header1 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
        _ = c.write(fd, header1, header1.len);
        
        // Write content-length as string manually
        var len_buf: [16]u8 = undefined;
        var len_pos: usize = 0;
        var mlen = metrics.len;
        if (mlen == 0) {
            len_buf[0] = '0';
            len_pos = 1;
        } else {
            while (mlen > 0) {
                len_buf[len_pos] = '0' + @as(u8, @intCast(mlen % 10));
                len_pos += 1;
                mlen /= 10;
            }
        }
        // Reverse
        var i: usize = 0;
        while (i < len_pos / 2) {
            const tmp = len_buf[i];
            len_buf[i] = len_buf[len_pos - 1 - i];
            len_buf[len_pos - 1 - i] = tmp;
            i += 1;
        }
        _ = c.write(fd, &len_buf, len_pos);
        
        const header2 = "\r\n\r\n";
        _ = c.write(fd, header2, header2.len);
        
        // Write metrics
        _ = c.write(fd, metrics.ptr, metrics.len);
        
        // Close connection
        _ = c.epoll_ctl(self.epoll_fd, EPOLL_CTL_DEL, fd, null);
        _ = c.close(fd);
    }
    
    fn parseRequest(self: *Self, buf: []u8) !struct { method: []const u8, path: []const u8 } {
        _ = self;
        var line_end: usize = 0;
        while (line_end < buf.len and buf[line_end] != '\r') line_end += 1;
        if (line_end == 0) return error.InvalidRequest;
        
        var parts = std.mem.splitSequence(u8, buf[0..line_end], " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        
        return .{ .method = method, .path = path };
    }
    
    fn runSyncPosix(self: *Self) !void {
        _ = self;
        @panic("Sync POSIX mode not implemented");
    }

    const CheckResult = struct {
        path: []const u8,
        method: []const u8,
    };

    /// Parse check request body - extract path and method from JSON
    fn parseCheckRequest(body: []const u8) CheckResult {
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
};