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
const denial_tracker = @import("../denial_tracker.zig");
const mtls = @import("../auth/mTLS.zig");

// Import config for TLSMode
const config = @import("../config.zig");

// Compile-time flags
const ENABLE_DEBUG_LOGS = false;  // Disable debug logging in production

// ============================================================
// Constants
// ============================================================

const MAX_CONCURRENT_REQUESTS = 1024;  // Increased to handle more concurrent requests
const SOCKET_BACKLOG = 8192;            // Listen backlog (increased for higher throughput)
const EPOLL_MAX_EVENTS = 256;           // Events per epoll_wait
const READ_BUFFER_SIZE = 8192;           // HTTP request buffer
const EPOLLIN: u32 = 0x001;
const EPOLLOUT: u32 = 0x004;
const EPOLLET: u32 = 0x80000000;  // Edge-triggered mode - prevents spurious wakeups
const EPOLL_CTL_ADD: c_int = 1;
const EPOLL_CTL_MOD: c_int = 2;
const EPOLL_CTL_DEL: c_int = 3;

// Pre-allocated static HTTP responses (zero-allocation)
const HEALTH_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK";
const AGENTS_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n[]";
const NOT_FOUND_RESPONSE = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nnot found";
const JSON_OK_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\nConnection: keep-alive\r\n\r\n{\"allowed\":true}";
const JSON_BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: keep-alive\r\n\r\n{\"error\":\"Invalid request\"}";
const JSON_UNAUTHORIZED_RESPONSE = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 30\r\nConnection: keep-alive\r\n\r\n{\"error\":\"missing authorization header\"}";

// ============================================================
// Public Types
// ============================================================

pub const HttpStatus = enum(u16) {
    ok = 200,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    gateway_timeout = 504,
    internal_error = 500,
};

pub const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    headers: []const u8, // Raw headers for keep-alive detection
    keep_alive: bool,   // Detected during parsing (single pass)
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

// ============================================================================
// SSL/TLS Header Parsing for External mTLS Mode
// ============================================================================

/// SSL client information parsed from X-SSL headers (set by nginx).
pub const SSLClientInfo = struct {
    /// SHA256 fingerprint (computed from PEM or 64 hex chars).
    fingerprint: [32]u8,
    /// SHA1 fingerprint (40 hex chars from nginx - optional).
    fingerprint_sha1: [20]u8,
    /// Whether nginx successfully verified the client certificate.
    verified: bool,
    /// Optional: Client certificate serial number.
    serial: []const u8,
    /// Optional: Subject Common Name from client certificate.
    subject_cn: []const u8,
    /// Full PEM-encoded client certificate (primary source for agent_id).
    pem_cert: []const u8,

    const Self = @This();

    /// Check if this SSL info is valid (verified AND has identity source).
    pub fn isValid(self: *const Self) bool {
        return self.verified and (
            !self.isFingerprintZero() or
            !self.isFingerprintSHA1Zero() or
            self.pem_cert.len > 0
        );
    }

    /// Check if SHA256 fingerprint is all zeros.
    pub fn isFingerprintZero(self: *const Self) bool {
        for (self.fingerprint) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Check if SHA1 fingerprint is all zeros.
    pub fn isFingerprintSHA1Zero(self: *const Self) bool {
        for (self.fingerprint_sha1) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Convert SSL info to agent_id with priority order:
    /// 1. SHA256 fingerprint (if available)
    /// 2. SHA1 fingerprint expanded to 32 bytes (if available)
    /// 3. Caller must compute from PEM using deriveAgentIdFromPEM()
    pub fn toAgentId(self: *const Self) ?[32]u8 {
        // Priority 1: SHA256 fingerprint (most secure)
        if (!self.isFingerprintZero()) {
            return self.fingerprint;
        }

        // Priority 2: SHA1 fingerprint expanded (fallback)
        if (!self.isFingerprintSHA1Zero()) {
            var expanded: [32]u8 = .{0} ** 32;
            @memcpy(expanded[0..20], &self.fingerprint_sha1);
            return expanded;
        }

        // Priority 3: Caller must compute from PEM
        return null;
    }
};

/// Parse X-SSL headers from nginx proxy.
/// Expected headers:
/// - X-SSL-Client-Verify: SUCCESS or FAILED (REQUIRED)
/// - X-SSL-Client-Cert: Full PEM certificate (PRIMARY - compute SHA256 from this)
/// - X-SSL-Client-Fingerprint: SHA1 fingerprint (40 hex chars - fallback)
/// - X-SSL-Client-Serial: Optional certificate serial
/// - X-SSL-Client-CN: Optional subject CN
pub fn parseSSLHeaders(headers: []const u8) ?SSLClientInfo {
    var info = SSLClientInfo{
        .fingerprint = .{0} ** 32,
        .fingerprint_sha1 = .{0} ** 20,
        .verified = false,
        .serial = "",
        .subject_cn = "",
        .pem_cert = "",
    };

    // Parse X-SSL-Client-Verify (REQUIRED - determines if we have valid cert)
    if (extractHeaderValue(headers, "X-SSL-Client-Verify")) |value| {
        info.verified = std.mem.eql(u8, value, "SUCCESS");
    }

    // Parse X-SSL-Client-Cert (PRIMARY - full PEM for SHA256 computation)
    if (extractHeaderValue(headers, "X-SSL-Client-Cert")) |pem| {
        if (pem.len > 0) {
            info.pem_cert = pem;
        }
    }

    // Parse X-SSL-Client-Fingerprint - could be SHA1 (40 chars) or SHA256 (64 chars)
    if (extractHeaderValue(headers, "X-SSL-Client-Fingerprint")) |fingerprint_hex| {
        // Strip "SHA1:" prefix if present (nginx format)
        const clean_hex = if (std.mem.startsWith(u8, fingerprint_hex, "SHA1:"))
            fingerprint_hex[5..]
        else
            fingerprint_hex;

        if (clean_hex.len == 40) {
            // SHA1 fingerprint (40 hex chars = 20 bytes)
            _ = std.fmt.hexToBytes(&info.fingerprint_sha1, clean_hex) catch {
                // Invalid hex, leave as zero
            };
        } else if (clean_hex.len == 64) {
            // SHA256 fingerprint (64 hex chars = 32 bytes)
            _ = std.fmt.hexToBytes(&info.fingerprint, clean_hex) catch {
                // Invalid hex, leave as zero
            };
        }
    }

    // Parse optional X-SSL-Client-Serial
    if (extractHeaderValue(headers, "X-SSL-Client-Serial")) |serial| {
        info.serial = serial;
    }

    // Parse optional X-SSL-Client-CN
    if (extractHeaderValue(headers, "X-SSL-Client-CN")) |cn| {
        info.subject_cn = cn;
    }

    // Only return info if verified and has some identity
    if (!info.isValid()) {
        return null;
    }

    return info;
}

/// Extract a header value from raw HTTP headers.
/// Returns the value part (after the colon) or null if not found.
fn extractHeaderValue(headers: []const u8, header_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + header_name.len < headers.len) : (i += 1) {
        // Case-insensitive header name match
        if (std.ascii.toLower(headers[i]) == std.ascii.toLower(header_name[0])) {
            if (i + header_name.len <= headers.len and
                std.mem.eql(u8, headers[i..][0..header_name.len], header_name)) {
                // Found header, skip to colon
                var j = i + header_name.len;
                while (j < headers.len and headers[j] != ':') j += 1;
                if (j >= headers.len) return null;

                // Skip colon and whitespace
                j += 1;
                while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) j += 1;

                // Find end of value (CRLF)
                var value_end = j;
                while (value_end < headers.len and
                    headers[value_end] != '\r' and headers[value_end] != '\n') {
                    value_end += 1;
                }

                return headers[j..value_end];
            }
        }
    }
    return null;
}

/// Derive agent_id from PEM certificate (fallback when fingerprint header unavailable).
/// Uses SHA256 of the PEM certificate bytes.
pub fn deriveAgentIdFromPEM(pem_cert: []const u8) ?[32]u8 {
    if (pem_cert.len == 0) return null;
    return mtls.deriveAgentId(pem_cert);
}

/// Check if an agent_id array is all zeros.
pub fn isAgentIdZero(agent_id: [32]u8) bool {
    for (agent_id) |b| {
        if (b != 0) return false;
    }
    return true;
}

// ============================================================
// Server Core
// ============================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    audit_logger: *audit.AuditLogger,
    policy_set: types.PolicySet,
    policy_timeout_ms: u32,
    secret_key: []const u8,
    mode: ServerMode = .async_epoll,

    // TLS mode for external mTLS support
    tls_mode: config.TLSMode = .disabled,
    require_ssl_headers: bool = true,
    external_policy: config.ExternalPolicy = .strict,

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

    // Per-request state (set in handleRequestThread, used in defer)
    last_request_allowed: bool = false,

    const Self = @This();
    
    // ============================================================
    // Initialization
    // ============================================================
    
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config.Config,
        audit_logger: *audit.AuditLogger,
        policy_set: types.PolicySet,
    ) Self {
        return Self{
            .allocator = allocator,
            .port = cfg.server.port,
            .audit_logger = audit_logger,
            .policy_set = policy_set,
            .policy_timeout_ms = cfg.policy.policy_timeout_ms,
            .secret_key = cfg.auth.jwt_secret,
            .mode = .async_epoll,
            .tls_mode = cfg.tls.mode,
            .require_ssl_headers = cfg.tls.require_ssl_headers,
            .external_policy = cfg.tls.external_policy,
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
        const thread_count = @min(MAX_CONCURRENT_REQUESTS, cpu_count * 2);  // 8 threads (4 cores * 2)
        
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

        // Spawn to thread pool - let pool handle backpressure
        self.thread_pool.spawn(handleRequestThread, .{self, client_fd}) catch |err| {
            std.log.err("Thread spawn failed: {}", .{err});
            _ = c.close(client_fd);
        };
    }
    
    // ============================================================
    // Request Processing Thread
    // ============================================================

    fn handleRequestThread(self: *Self, client_fd: c_int) void {
        // Track active requests
        _ = self.active_requests.fetchAdd(1, .acq_rel);
        var allowed = false;

        // Keep-alive loop: handle multiple requests on same connection
        var requests_served: usize = 0;
        const max_requests_per_conn = 100; // Safety limit
        var buffer: [READ_BUFFER_SIZE]u8 = undefined;

        while (requests_served < max_requests_per_conn) {
            // Read request
            const bytes_read = c.read(client_fd, &buffer, buffer.len);

            if (bytes_read <= 0) {
                // Connection closed or error - exit loop
                break;
            }

            // Track timing for this request
            const req_start = std.time.nanoTimestamp();

            const request_str = buffer[0..@as(usize, @intCast(bytes_read))];

            // Parse request
            const parsed = parseHttpRequestFast(request_str) catch {
                // Invalid request - close connection
                break;
            };

            // Keep-alive already detected in single pass during parsing
            const keep_alive = parsed.keep_alive;

            // ============================================================
            // SSL Header Parsing for External mTLS Mode
            // ============================================================
            var agent_id: [32]u8 = .{0} ** 32;
            var has_valid_identity = false;

            // Parse SSL headers from nginx (only in external mode)
            if (self.tls_mode == .external or self.tls_mode == .native) {
                if (parseSSLHeaders(parsed.headers)) |ssl_info| {
                    // Priority 1: SHA256 fingerprint (64 hex chars from header or PEM computation)
                    if (ssl_info.toAgentId()) |derived_id| {
                        agent_id = derived_id;
                        has_valid_identity = true;
                        if (ENABLE_DEBUG_LOGS) {
                            std.log.debug("Agent ID from fingerprint: {s}", .{
                                std.fmt.bytesToHex(agent_id, .lower)
                            });
                        }
                    } else if (ssl_info.pem_cert.len > 0) {
                        // Priority 2: Compute from PEM certificate (primary method)
                        if (deriveAgentIdFromPEM(ssl_info.pem_cert)) |computed_id| {
                            agent_id = computed_id;
                            has_valid_identity = true;
                            if (ENABLE_DEBUG_LOGS) {
                                std.log.debug("Agent ID from PEM: {s}", .{
                                    std.fmt.bytesToHex(agent_id, .lower)
                                });
                            }
                        }
                    } else if (!ssl_info.isFingerprintSHA1Zero()) {
                        // Priority 3: SHA1 fingerprint (expand to 32 bytes)
                        @memcpy(agent_id[0..20], &ssl_info.fingerprint_sha1);
                        has_valid_identity = true;
                        if (ENABLE_DEBUG_LOGS) {
                            std.log.debug("Agent ID from SHA1: {s}", .{
                                std.fmt.bytesToHex(agent_id, .lower)
                            });
                        }
                    }
                }
            }

            // Security check: in external mode with require_ssl_headers, reject if no valid identity
            const needs_auth = self.tls_mode == .external and self.require_ssl_headers;
            const is_public_endpoint = std.mem.eql(u8, parsed.path, "/health") or
                std.mem.eql(u8, parsed.path, "/metrics") or
                std.mem.eql(u8, parsed.path, "/denied-requests") or
                std.mem.eql(u8, parsed.path, "/v1/agents");

            // Route - track whether request was allowed
            allowed = false;

            if (std.mem.eql(u8, parsed.path, "/health")) {
                // Hot path - no metrics
                sendHealthResponse(client_fd);
            } else if (std.mem.eql(u8, parsed.path, "/metrics")) {
                sendMetricsResponse(client_fd);
            } else if (std.mem.eql(u8, parsed.path, "/denied-requests") and std.mem.eql(u8, parsed.method, "GET")) {
                handleDeniedRequests(client_fd, parsed.query) catch {
                    sendErrorResponse(client_fd, .internal_error, "Failed to handle denied requests");
                    break;
                };
            } else if (std.mem.eql(u8, parsed.path, "/v1/agents")) {
                // Hot path - no metrics
                sendAgentsListResponse(client_fd);
            } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
                // Security check: reject in external mode if no valid identity
                if (needs_auth and !is_public_endpoint and !has_valid_identity) {
                    // Reject request - SSL headers required in external mode
                    sendJsonResponse(client_fd, .forbidden,
                        "{\"error\":\"SSL headers required in external TLS mode\"}");
                    allowed = false;
                } else {
                    allowed = handleCheckRequest(self, client_fd, parsed.body, agent_id);
                }
                // Only record metrics for policy decisions
                const req_end = std.time.nanoTimestamp();
                const latency_us = @as(u64, @intCast(@divTrunc(req_end - req_start, 1000)));
                prometheus.global_metrics.recordRequest(latency_us, allowed);
                _ = self.total_requests.fetchAdd(1, .monotonic);
            } else {
                sendNotFoundResponse(client_fd);
            }

            requests_served += 1;

            // If client didn't request keep-alive, exit loop
            if (!keep_alive) break;
        }

        // Cleanup - always close when done
        _ = self.active_requests.fetchSub(1, .release);
        _ = c.close(client_fd);
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
        const path_with_query = parts.next() orelse return error.InvalidRequest;

        // Extract path and query
        var query: []const u8 = "";
        var path: []const u8 = path_with_query;
        if (std.mem.indexOfScalar(u8, path_with_query, '?')) |q_idx| {
            path = path_with_query[0..q_idx];
            query = path_with_query[q_idx + 1 ..];
        }

        // Find body and detect keep-alive in single pass
        var pos = line_end + 2;
        var body_start = pos;
        var keep_alive = false;

        // Check if hot path (for optimization)
        const is_hot_path = path.len > 1 and (path[1] == 'v' or path[1] == 'h' or path[1] == 'm');

        while (pos + 3 < buf.len) {
            if (buf[pos] == '\r' and buf[pos+1] == '\n' and
                buf[pos+2] == '\r' and buf[pos+3] == '\n') {
                body_start = pos + 4;

                // Only scan for keep-alive if not hot path
                if (!is_hot_path) {
                    const headers_slice = buf[line_end + 2 .. pos];
                    keep_alive = detectKeepAlive(headers_slice);
                } else {
                    keep_alive = true; // Hot paths assume keep-alive
                }
                break;
            }
            pos += 1;
        }

        // Extract headers (between request line and body)
        const headers = if (pos > line_end + 2) buf[line_end + 2 .. pos] else "";
        const body = if (body_start < buf.len) buf[body_start..] else "";

        return ParsedRequest{
            .method = method,
            .path = path,
            .query = query,
            .body = body,
            .headers = headers,
            .keep_alive = keep_alive,
        };
    }

    /// Detect keep-alive from headers (single pass, called from parseHttpRequestFast)
    inline fn detectKeepAlive(headers: []const u8) bool {
        // Quick scan for "Connection: keep-alive"
        var i: usize = 0;
        while (i + 12 < headers.len) : (i += 1) {
            if (headers[i] == 'C' or headers[i] == 'c') {
                if (i + 12 <= headers.len and headers[i..i+12].len == 12) {
                    // Check if it's "Connection:" (12 chars)
                    const slice = headers[i..i+12];
                    if (slice[0] == 'C' and slice[1] == 'o' and slice[2] == 'n' and
                        slice[3] == 'n' and slice[4] == 'e' and slice[5] == 'c' and
                        slice[6] == 't' and slice[7] == 'i' and slice[8] == 'o' and
                        slice[9] == 'n' and slice[10] == ':') {
                        // Found Connection header, check value
                        var j = i + 12;
                        while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) j += 1;
                        if (j + 10 <= headers.len) {
                            const value = headers[j..j+10];
                            // Check for "keep-alive" (case insensitive)
                            if (value.len >= 10 and
                                (value[0] == 'k' or value[0] == 'K') and
                                (value[1] == 'e' or value[1] == 'E') and
                                (value[2] == 'e' or value[2] == 'E') and
                                (value[3] == 'p' or value[3] == 'P') and
                                (value[4] == '-' or value[4] == '-') and
                                (value[5] == 'a' or value[5] == 'A') and
                                (value[6] == 'l' or value[6] == 'L') and
                                (value[7] == 'i' or value[7] == 'I') and
                                (value[8] == 'v' or value[8] == 'V') and
                                (value[9] == 'e' or value[9] == 'E')) {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    /// Check if client requested keep-alive connection
    /// Scans headers for "Connection: keep-alive" (case-insensitive)
    fn wantsKeepAlive(headers: []const u8) bool {
        // Look for "Connection:" header
        const search = "Connection:";
        var i: usize = 0;
        while (i + search.len < headers.len) : (i += 1) {
            if (headers[i] == 'C' or headers[i] == 'c') {
                if (i + search.len <= headers.len and
                    std.mem.eql(u8, headers[i..][0..search.len], search)) {
                    // Found Connection header, check value
                    var j = i + search.len;
                    while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) j += 1;
                    const value_start = j;
                    while (j < headers.len and headers[j] != '\r' and headers[j] != '\n') j += 1;
                    const value = headers[value_start..j];

                    // Check if value starts with "keep-alive" (case-insensitive)
                    if (value.len >= 10) {
                        const lower_first = std.ascii.toLower(value[0]);
                        if (lower_first == 'k' and
                            std.mem.eql(u8, value[0..10], "keep-alive")) {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
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
    
    fn handleCheckRequest(self: *Self, client_fd: c_int, body: []const u8, agent_id: [32]u8) bool {
        const check = parseCheckRequestFast(body);

        // Build request context for policy evaluation
        const method = types.Method.parse(check.method) catch .GET;
        const ctx = types.RequestContext.init(
            std.fmt.bytesToHex(agent_id, .lower)[0..],
            check.path,
            method,
        );

        // Evaluate with timeout using real policy engine
        const decision = self.policy_set.evaluateWithTimeout(&ctx, self.policy_timeout_ms) catch |err| {
            if (err == error.PolicyTimeout) {
                // Return 504 Gateway Timeout
                sendJsonResponse(client_fd, .gateway_timeout,
                    "{\"allowed\":false,\"reason\":\"policy timeout\",\"policy_id\":\"timeout\"}");
                return false;
            }
            // Other errors - treat as deny
            sendJsonResponse(client_fd, .forbidden,
                "{\"allowed\":false,\"reason\":\"policy evaluation error\",\"policy_id\":\"error\"}");
            return false;
        };

        // Check decision effect
        switch (decision.effect) {
            .allow => {
                sendJsonResponse(client_fd, .ok, "{\"allowed\":true}");
                return true;
            },
            .deny => {
                // Record the denial for audit
                const timestamp_us = @as(i64, std.time.timestamp()) * 1_000_000;
                const denial = denial_tracker.DenialRecord.init(
                    timestamp_us,
                    agent_id,
                    check.path,
                    check.method,
                    decision.policy_id,
                    .explicit_deny,
                );
                denial_tracker.getTracker().record(denial) catch {};

                // Build denial response with dynamic policy_id
                var response_buf: [512]u8 = undefined;
                const response = std.fmt.bufPrint(&response_buf,
                    "{{\"allowed\":false,\"reason\":\"policy denied\",\"policy_id\":\"{s}\"}}",
                    .{decision.policy_id}) catch "{\"allowed\":false,\"reason\":\"policy denied\"}";

                sendJsonResponse(client_fd, .forbidden, response);
                return false;
            },
        }
    }

    // ============================================================
    // Denied Requests Endpoint
    // ============================================================

    fn handleDeniedRequests(client_fd: c_int, query: []const u8) !void {
        const tracker = denial_tracker.getTracker();

        // Check if denial tracking is enabled
        _ = tracker.getRecent(1, null, null) catch |err| {
            if (err == error.DenialTrackingDisabled) {
                sendErrorResponse(client_fd, .internal_error, "denial tracking is disabled");
                return;
            }
            return err;
        };

        // Parse query parameters
        var limit: usize = 100;
        var filter_agent: ?[32]u8 = null;
        var since_us: ?i64 = null;

        if (query.len > 0) {
            var parts = std.mem.splitSequence(u8, query, "&");
            while (parts.next()) |part| {
                var kv = std.mem.splitSequence(u8, part, "=");
                const key = kv.next() orelse "";
                const value = kv.next() orelse "";

                if (std.mem.eql(u8, key, "limit")) {
                    limit = std.fmt.parseInt(usize, value, 10) catch 100;
                    limit = @min(limit, 1000);
                } else if (std.mem.eql(u8, key, "agent")) {
                    // Parse hex to bytes (64 hex chars = 32 bytes)
                    if (value.len == 64) {
                        var bytes: [32]u8 = undefined;
                        _ = std.fmt.hexToBytes(&bytes, value) catch continue;
                        filter_agent = bytes;
                    }
                } else if (std.mem.eql(u8, key, "since")) {
                    since_us = std.fmt.parseInt(i64, value, 10) catch null;
                }
            }
        }

        // Get denials (returns owned copies)
        const denials = try tracker.getRecent(limit, filter_agent, since_us);
        defer tracker.allocator.free(denials);

        // Build JSON response
        var buf = try std.ArrayList(u8).initCapacity(tracker.allocator, 4096);
        defer buf.deinit(tracker.allocator);

        try buf.writer(tracker.allocator).print("{{\"total\":{},\"denials\":[", .{tracker.getTotalDenials()});

        for (denials, 0..) |d, i| {
            if (i > 0) {
                try buf.writer(tracker.allocator).writeAll(",");
            }

            const agent_hex = std.fmt.bytesToHex(d.agent_id, .lower);
            try buf.writer(tracker.allocator).print(
                \\{{"timestamp":{},"agent_id":"{s}","path":"{s}","method":"{s}","policy_id":"{s}","reason":"{s}"}}
            , .{
                d.timestamp_us,
                agent_hex,
                d.getPath(),
                d.getMethod(),
                d.getPolicyId(),
                @tagName(d.reason),
            });
        }

        try buf.writer(tracker.allocator).writeAll("]}");

        sendJsonResponse(client_fd, .ok, buf.items);
    }

    // ============================================================
    // Response Helpers
    // ============================================================
    
    fn sendHealthResponse(client_fd: c_int) void {
        _ = c.write(client_fd, HEALTH_RESPONSE, HEALTH_RESPONSE.len);
    }
    
    fn sendMetricsResponse(client_fd: c_int) void {
        const metrics = prometheus.global_metrics.exportMetrics();
        
        // Simple approach: write parts separately
        const header1 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
        _ = c.write(client_fd, header1, header1.len);
        
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
        _ = c.write(client_fd, &len_buf, len_pos);
        
        const header2 = "\r\n\r\n";
        _ = c.write(client_fd, header2, header2.len);
        
        // Write metrics
        _ = c.write(client_fd, metrics.ptr, metrics.len);
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
        @memcpy(response[0..header.len], header);
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
        if (total_len <= 2048) {
            var response: [2048]u8 = undefined;
            @memcpy(response[0..header.len], header);
            @memcpy(response[header.len..][0..json.len], json);
            _ = c.write(client_fd, &response, total_len);
        } else {
            // For large responses, write in two parts
            _ = c.write(client_fd, header.ptr, header.len);
            _ = c.write(client_fd, json.ptr, json.len);
        }
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
        .gateway_timeout => "Gateway Timeout",
        .internal_error => "Internal Server Error",
    };
}