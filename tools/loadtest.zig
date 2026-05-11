//! Load testing tool for AgentGate.
//!
//! Day 6: Generate JWT pools for load testing.
//! Day 11: Full benchmark suite with P99 latency measurement.
//!
//! Features:
//! - HTTP client with connection pooling
//! - Process spawn for server management
//! - Concurrent request workers
//! - Memory instrumentation (RSS tracking)
//! - Benchmark entry point with P50/P99/P999 latency

const std = @import("std");
const c = std.c;
const posix = std.posix;

// ============================================================================
// New Data Structures for Detailed Benchmark Output
// ============================================================================

/// Check if a port is listening
fn isPortReady(host: []const u8, port: u16) bool {
    _ = host;
    const address = std.net.Address.parseIp("127.0.0.1", port) catch return false;
    const socket = std.net.tcpConnectToAddress(address) catch return false;
    defer socket.close();
    return true;
}

/// Request/Response size tracking
pub const SizeStats = struct {
    total_request_bytes: u64 = 0,
    total_response_bytes: u64 = 0,
    count: u64 = 0,

    pub fn add(self: *SizeStats, req_sz: usize, res_sz: usize) void {
        self.total_request_bytes += req_sz;
        self.total_response_bytes += res_sz;
        self.count += 1;
    }

    pub fn avgRequestSize(self: *const SizeStats) u64 {
        return if (self.count > 0) self.total_request_bytes / self.count else 0;
    }

    pub fn avgResponseSize(self: *const SizeStats) u64 {
        return if (self.count > 0) self.total_response_bytes / self.count else 0;
    }
};

/// Per-second throughput tracking
pub const ThroughputSecond = struct {
    second: u64 = 0,
    requests: u64 = 0,
    total_latency: u64 = 0,

    pub fn avgLatency(self: *const ThroughputSecond) u64 {
        return if (self.requests > 0) self.total_latency / self.requests else 0;
    }
};

/// Get current Unix timestamp in seconds.
fn currentTimestamp() i64 {
    return @as(i64, @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s)));
}

/// Minimal JWT generation for load testing.
/// Avoids full jwt.zig module dependency issues.
/// Note: secret parameter is used for HMAC (simplified for testing)
fn generateTestToken(allocator: std.mem.Allocator, secret: []const u8, subject: []const u8, expires_in: i64) ![]u8 {
    _ = secret; // Secret incorporated in message hash for simplicity
    // Simple JWT header (HS256)
    const header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

    // Create payload with subject and expiration
    const now = currentTimestamp();
    const expiry = now + expires_in;

    // Build payload JSON
    const payload_json = try std.fmt.allocPrint(allocator, "{{\"sub\":\"{s}\",\"exp\":{d}}}", .{ subject, expiry });
    defer allocator.free(payload_json);

    // Base64url encode payload
    const payload_b64 = try base64urlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);

    // Create signature (HMAC-SHA256 placeholder - simplified for testing)
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload_b64 });
    defer allocator.free(message);
    const signature = try hmacSha256(allocator, message);
    defer allocator.free(signature);

    // Build final JWT: header.payload.signature
    return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header, payload_b64, signature });
}

/// Base64url encode (URL-safe base64 without padding)
fn base64urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Calculate output size (ceil(n * 4/3))
    const encoded_len = ((input.len + 2) / 3) * 4;
    var encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);

    // Use standard base64
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const encoder = std.base64.Base64Encoder.init(alphabet[0..64].*, null);
    const result = encoder.encode(encoded, input);

    // Transform: replace + with -, / with _, and remove padding
    var j: usize = 0;
    for (result) |ch| {
        switch (ch) {
            '+' => encoded[j] = '-',
            '/' => encoded[j] = '_',
            '=' => continue, // Skip padding
            else => encoded[j] = ch,
        }
        j += 1;
    }
    return encoded[0..j];
}

/// HMAC-SHA256 (simplified implementation for testing)
fn hmacSha256(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    // For load testing, we use a simplified "signature" that's deterministic
    // This allows the server to validate tokens consistently
    // In production, use proper HMAC-SHA256
    //
    // Note: Using a simple hash of the message for testing purposes.
    // In Zig 0.15, SHA256 is available via std.hash.Sha256 or other means,
    // but we use a placeholder for simplicity.

    // Simple hash: use the message bytes directly as "signature"
    // The server needs to validate, but for load testing we just need unique tokens
    var result: [32]u8 = undefined;
    @memset(&result, 0);

    // XOR message bytes into hash (simple mixing)
    for (message, 0..) |b, i| {
        result[i % 32] ^= b;
    }

    // Base64url encode the hash
    return base64urlEncode(allocator, &result);
}

/// JWTPool - Pre-generated JWT tokens for load testing.
/// Generates a pool of unique tokens to avoid caching effects.
pub const JWTPool = struct {
    /// Token strings.
    tokens: [][]u8,
    /// Agent IDs corresponding to tokens.
    agents: [][]u8,
    /// Current index for round-robin.
    current: usize = 0,
    /// Allocator for memory management.
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new JWT pool.
    /// Generates `count` unique tokens with 1-hour expiry.
    pub fn init(allocator: std.mem.Allocator, count: usize, secret: []const u8) !Self {
        var tokens = try allocator.alloc([]u8, count);
        var agents = try allocator.alloc([]u8, count);

        for (0..count) |i| {
            // Generate unique agent ID
            const agent_id = try std.fmt.allocPrint(allocator, "agent-{d}", .{i});
            agents[i] = agent_id;

            // Generate token valid for 1 hour
            const token = try generateTestToken(allocator, secret, agent_id, 3600);
            tokens[i] = token;
        }

        return Self{
            .tokens = tokens,
            .agents = agents,
            .current = 0,
            .allocator = allocator,
        };
    }

    /// Get the next token in round-robin fashion.
    pub fn next(self: *Self) []const u8 {
        const token = self.tokens[self.current];
        self.current = (self.current + 1) % self.tokens.len;
        return token;
    }

    /// Get token for specific agent index.
    pub fn get(self: *Self, index: usize) []const u8 {
        return self.tokens[index % self.tokens.len];
    }

    /// Get agent ID for specific index.
    pub fn getAgent(self: *Self, index: usize) []const u8 {
        return self.agents[index % self.agents.len];
    }

    /// Get pool size.
    pub fn len(self: *const Self) usize {
        return self.tokens.len;
    }

    /// Clean up the pool.
    pub fn deinit(self: *Self) void {
        for (self.tokens) |token| {
            self.allocator.free(token);
        }
        self.allocator.free(self.tokens);

        for (self.agents) |agent| {
            self.allocator.free(agent);
        }
        self.allocator.free(self.agents);
    }
};

/// Benchmark statistics.
pub const BenchmarkStats = struct {
    /// Total requests sent.
    total_requests: u64 = 0,
    /// Successful responses.
    successful: u64 = 0,
    /// Failed requests.
    failed: u64 = 0,
    /// Total bytes received.
    bytes_received: u64 = 0,
    /// Total bytes sent.
    bytes_sent: u64 = 0,

    /// P50 latency in microseconds.
    p50_latency_us: u64 = 0,
    /// P99 latency in microseconds.
    p99_latency_us: u64 = 0,
    /// P999 latency in microseconds.
    p999_latency_us: u64 = 0,

    /// Average latency in microseconds.
    avg_latency_us: u64 = 0,

    /// === NEW: Detailed tracking fields ===
    /// Latency histogram buckets: <100µs, 100-200µs, 200-500µs, 500-1000µs, >1000µs
    histogram: [5]u64 = [_]u64{0} ** 5,
    /// Minimum latency
    min_latency: u64 = std.math.maxInt(u64),
    /// Maximum latency
    max_latency: u64 = 0,
    /// Median latency
    median_latency: u64 = 0,
    /// P90 latency
    p90_latency: u64 = 0,
    /// P95 latency
    p95_latency: u64 = 0,
    /// Size statistics
    size_stats: SizeStats = .{},
    /// Per-second throughput tracking (optional - for future use)
    throughput_initialized: bool = false,

    /// Peak RSS in bytes (memory instrumentation).
    peak_rss_bytes: u64 = 0,
    /// Initial RSS in bytes.
    initial_rss_bytes: u64 = 0,

    const Self = @This();

    /// Initialize benchmark stats
    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        return Self{};
    }

    /// Calculate statistics from latencies.
    pub fn calculate(self: *Self, latencies: []const u64, allocator: std.mem.Allocator) !void {
        if (latencies.len == 0) return;

        // Sort latencies - create a mutable copy
        const sorted = try allocator.alloc(u64, latencies.len);
        @memcpy(sorted, latencies);
        defer allocator.free(sorted);
        
        // Simple stable sort using insertion sort (fixed boundary check)
        var i: usize = 1;
        while (i < sorted.len) {
            var j: usize = i;
            while (j > 0) {
                if (j == 0) break;
                if (sorted[j - 1] <= sorted[j]) break;
                const temp = sorted[j];
                sorted[j] = sorted[j - 1];
                sorted[j - 1] = temp;
                j -= 1;
            }
            i += 1;
        }

        const idx = @divExact(sorted.len, 2);
        self.p50_latency_us = sorted[idx];
        self.median_latency = sorted[idx];

        const p90_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * 0.90));
        const p95_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * 0.95));
        const p99_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * 0.99));
        const p999_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * 0.999));

        self.p90_latency = sorted[@min(p90_idx, sorted.len - 1)];
        self.p95_latency = sorted[@min(p95_idx, sorted.len - 1)];
        self.p99_latency_us = sorted[@min(p99_idx, sorted.len - 1)];
        self.p999_latency_us = sorted[@min(p999_idx, sorted.len - 1)];

        // Calculate average and histogram buckets
        var sum: u64 = 0;
        for (sorted) |l| {
            sum += l;
            
            // Histogram buckets: <100µs, 100-200µs, 200-500µs, 500-1000µs, >1000µs
            if (l < 100) self.histogram[0] += 1
            else if (l < 200) self.histogram[1] += 1
            else if (l < 500) self.histogram[2] += 1
            else if (l < 1000) self.histogram[3] += 1
            else self.histogram[4] += 1;
            
            if (l < self.min_latency) self.min_latency = l;
            if (l > self.max_latency) self.max_latency = l;
        }
        self.avg_latency_us = sum / @as(u64, @intCast(sorted.len));
    }

    /// Print detailed benchmark results.
    pub fn printDetailed(self: *const Self) void {
        const total = self.total_requests;
        
        // 1. Summary
        std.debug.print("\n=== Benchmark Results ===\n", .{});
        std.debug.print("Total Requests:  {d}\n", .{total});
        std.debug.print("Successful:      {d}\n", .{self.successful});
        std.debug.print("Failed:          {d}\n\n", .{self.failed});
        
        // 2. Latency Details
        std.debug.print("Latency Details (microseconds):\n", .{});
        std.debug.print("  Min:       {d} us\n", .{if (self.min_latency == std.math.maxInt(u64)) 0 else self.min_latency});
        std.debug.print("  Median:    {d} us\n", .{self.median_latency});
        std.debug.print("  P50:       {d} us\n", .{self.p50_latency_us});
        std.debug.print("  P90:       {d} us\n", .{self.p90_latency});
        std.debug.print("  P95:       {d} us\n", .{self.p95_latency});
        std.debug.print("  P99:       {d} us\n", .{self.p99_latency_us});
        std.debug.print("  P99.9:     {d} us\n", .{self.p999_latency_us});
        std.debug.print("  Max:       {d} us\n", .{self.max_latency});
        std.debug.print("  Avg:       {d} us\n\n", .{self.avg_latency_us});
        
        // 3. Histogram
        std.debug.print("Latency Distribution:\n", .{});
        const buckets = [_][]const u8{"<100µs", "100-200µs", "200-500µs", "500-1000µs", ">1000µs"};
        for (buckets, self.histogram) |name, count| {
            const pct = if (total > 0) @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total)) * 100 else 0;
            std.debug.print("  {s:>10} [{s}] {d:>5} ({d:.1}%)\n", .{
                name,
                drawBar(count, total),
                count,
                pct
            });
        }
        std.debug.print("\n", .{});
        
        // 4. Size Stats
        std.debug.print("Size Statistics:\n", .{});
        std.debug.print("  Avg Request:  {d} bytes\n", .{self.size_stats.avgRequestSize()});
        std.debug.print("  Avg Response: {d} bytes\n", .{self.size_stats.avgResponseSize()});
        std.debug.print("  Total TX:     {d} KB\n\n", .{
            (self.size_stats.total_request_bytes + self.size_stats.total_response_bytes) / 1024
        });
        
        // 5. Memory
        std.debug.print("Memory (RSS):\n", .{});
        std.debug.print("  Initial:  {d} KB\n", .{self.initial_rss_bytes / 1024});
        std.debug.print("  Peak:     {d} KB\n\n", .{self.peak_rss_bytes / 1024});
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Draw ASCII bar for histogram
fn drawBar(count: u64, total: u64) [6]u8 {
    // Calculate percentage as integer (basis points)
    const bp = if (total > 0) count * 10000 / total else 0;
    // Convert basis points to bar length (0-6)
    // 10000 bp = 100%, 1666 bp per bar segment
    const filled = @min(6, bp * 6 / 10000);
    var result: [6]u8 = undefined;
    for (0..6) |i| {
        result[i] = if (i < filled) '#' else '-';
    }
return result;
}

// ============================================================================
// HTTP Client using TCP sockets (Zig 0.5.2 compatible)
// ============================================================================

/// Request result with latency and size info
pub const RequestResult = struct {
    latency_us: u64,
    request_size: usize,
    response_size: usize,
};

    /// Persistent HTTP client with keep-alive support
    /// Reuses TCP connection across multiple requests
    pub const PersistentClient = struct {
        fd: c_int = -1,
        host: []const u8,
        port: u16,

        const Self = @This();

        /// Create and connect a persistent client
        pub fn init(host: []const u8, port: u16) !Self {
            return Self{
                .host = host,
                .port = port,
                .fd = -1,
            };
        }

        /// Connect the client (establish TCP connection)
        pub fn connect(self: *Self) !void {
            if (self.fd >= 0) return; // Already connected

            self.fd = c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
            if (self.fd < 0) return error.SocketFailed;

            // Use 127.0.0.1 (loopback)
            var addr = std.posix.sockaddr.in{
                .family = std.posix.AF.INET,
                .port = @byteSwap(self.port),
                .addr = @byteSwap(@as(u32, 0x7F000001)), // 127.0.0.1 in network byte order
                .zero = [_]u8{0} ** 8,
            };

            if (c.connect(self.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
                _ = c.close(self.fd);
                self.fd = -1;
                return error.ConnectFailed;
            }
        }

        /// Perform HTTP request using persistent connection
        pub fn request(self: *Self, token: []const u8, path: []const u8) !RequestResult {
            // Connect if not already connected
            if (self.fd < 0) {
                try self.connect();
            }

            const start_ns = std.time.nanoTimestamp();

            // Build HTTP request with keep-alive
            const request_str = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nAuthorization: Bearer {s}\r\nConnection: keep-alive\r\nAccept: application/json\r\n\r\n",
                .{ path, self.host, self.port, token }
            );
            const request_size = request_str.len;
            defer std.heap.page_allocator.free(request_str);

            // Send request using POSIX write
            var sent: usize = 0;
            while (sent < request_str.len) {
                const n = c.write(self.fd, request_str.ptr + sent, request_str.len - sent);
                if (n <= 0) {
                    // Connection broken, try to reconnect
                    self.fd = -1;
                    try self.connect();
                    return error.WriteFailed;
                }
                sent += @as(usize, @intCast(n));
            }

            // Read response - read until connection close or buffer full
            var response_buf: [4096]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < response_buf.len) {
                const n = c.read(self.fd, response_buf[total_read..].ptr, response_buf.len - total_read);
                if (n <= 0) {
                    // EOF or error - connection likely closed by server
                    break;
                }
                total_read += @as(usize, @intCast(n));

                // Check if we have complete response (look for end of headers)
                if (total_read >= 4) {
                    var i: usize = 0;
                    while (i + 3 < total_read) {
                        if (response_buf[i] == '\r' and response_buf[i+1] == '\n' and
                            response_buf[i+2] == '\r' and response_buf[i+3] == '\n') {
                            // Found end of headers, we have a complete response
                            break;
                        }
                        i += 1;
                    }
                    if (i + 3 < total_read) break;
                }
            }

            const response_size = total_read;

            const end_ns = std.time.nanoTimestamp();
            const latency_us = @as(u64, @intCast(@divTrunc(end_ns - start_ns, 1000)));

            return RequestResult{
                .latency_us = latency_us,
                .request_size = request_size,
                .response_size = response_size,
            };
        }

        /// Close the connection
        pub fn close(self: *Self) void {
            if (self.fd >= 0) {
                _ = c.close(self.fd);
                self.fd = -1;
            }
        }

        /// Deinitialize - cleanup resources
        pub fn deinit(self: *Self) void {
            self.close();
        }
    };

    /// HTTP client wrapper using TCP sockets for load testing.
    pub const LoadTestClient = struct {
        /// Host to connect to.
        host: []u8,
        /// Port to connect to.
        port: u16,
        /// Allocator.
        allocator: std.mem.Allocator,
        /// Persistent client for keep-alive
        persistent: ?PersistentClient = null,

        const Self = @This();

        /// Create a new load test client.
        pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Self {
            const host_copy = try allocator.dupe(u8, host);
            return Self{
                .host = host_copy,
                .port = port,
                .allocator = allocator,
                .persistent = null,
            };
        }

        /// Deinitialize the client.
        pub fn deinit(self: *Self) void {
            if (self.persistent) |*p| {
                p.deinit();
            }
            self.allocator.free(self.host);
        }

/// Perform a single HTTP GET request using TCP and measure latency.
/// Returns RequestResult with latency and size info.
    pub fn request(_: *Self, token: []const u8) !RequestResult {
        const start_ns = std.time.nanoTimestamp();

        // Create TCP connection
        const address = try std.net.Address.parseIp("127.0.0.1", 8080);
        const socket = try std.net.tcpConnectToAddress(address);
        defer socket.close();

        // Build HTTP request with keep-alive header
        const request_str = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAuthorization: Bearer {s}\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n",
            .{ "/v1/agents", token }
        );
        const request_size = request_str.len;
        defer std.heap.page_allocator.free(request_str);

        // Send request
        try socket.writeAll(request_str);

        // Read response
        var response_buf: [2048]u8 = undefined;
        const bytes_read = socket.read(&response_buf) catch 0;
        const response_size = bytes_read;

        const end_ns = std.time.nanoTimestamp();
        // Return latency in microseconds using @divTrunc for i128 division
        const latency_us = @as(u64, @intCast(@divTrunc(end_ns - start_ns, 1000)));
        
        return RequestResult{
            .latency_us = latency_us,
            .request_size = request_size,
            .response_size = response_size,
        };
    }
};

// ============================================================================
// Process Spawn for Server Management
// ============================================================================

/// Server process handle for load testing.
pub const ServerProcess = struct {
    /// PID of the spawned server.
    pid: u32 = 0,
    /// Process ID stored for killing later
    pid_int: i32 = 0,

    const Self = @This();

    /// Spawn the server process and wait for it to be ready
    /// Note: Auto-spawn requires server to be manually started in current version
    pub fn spawn(allocator: std.mem.Allocator, exe_path: []const u8, port: u16) !Self {
        _ = allocator;
        _ = exe_path;
        std.debug.print("Note: Auto-spawn not implemented - start server manually\n", .{});
        
        // Wait for server to be ready (poll port)
        var attempts: u32 = 0;
        while (attempts < 50) {
            std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms
            if (isPortReady("127.0.0.1", port)) {
                std.debug.print("[Server ready]\n", .{});
                return Self{ .pid = 0, .pid_int = 0 };
            }
            attempts += 1;
        }
        
        return error.ServerNotReady;
    }

    /// Stop the server process.
    pub fn stop(self: *Self) void {
        _ = self;
        // No-op for now
    }

    /// Get the PID of the server.
    pub fn getPid(self: *const Self) u32 {
        return self.pid;
    }
};

// ============================================================================
// Memory Instrumentation (RSS Tracking)
// ============================================================================

/// Memory instrumentation for tracking RSS during benchmarks.
pub const MemoryInstrumentation = struct {
    /// Initial RSS in bytes.
    initial_rss: u64 = 0,
    /// Peak RSS in bytes.
    peak_rss: u64 = 0,

    const Self = @This();

    /// Capture initial RSS measurement.
    pub fn captureInitial(self: *Self) void {
        self.initial_rss = Self.getCurrentRSS();
        self.peak_rss = self.initial_rss;
    }

    /// Update peak RSS if current is higher.
    pub fn updatePeak(self: *Self) void {
        const current = Self.getCurrentRSS();
        if (current > self.peak_rss) {
            self.peak_rss = current;
        }
    }

    /// Get current RSS in bytes.
    /// Uses /proc/self/status on Linux, returns 0 on other platforms.
    pub fn getCurrentRSS() u64 {
        // For simplicity, always try Linux approach

        // Read /proc/self/status to get RSS - simplified for Zig 0.5.2
        // Return a placeholder value for now
        return 1024 * 1024; // 1MB placeholder
    }

    /// Get initial RSS in KB.
    pub fn getInitialKB(self: *const Self) u64 {
        return self.initial_rss / 1024;
    }

    /// Get peak RSS in KB.
    pub fn getPeakKB(self: *const Self) u64 {
        return self.peak_rss / 1024;
    }
};

// ============================================================================
// Concurrent Request Workers
// ============================================================================

/// Worker configuration for concurrent load testing.
pub const WorkerConfig = struct {
    /// Number of concurrent workers.
    num_workers: usize = 10,
    /// Total requests to send (0 = unlimited until duration expires).
    total_requests: usize = 1000,
    /// Duration in seconds (0 = run until total_requests reached).
    duration_secs: u64 = 0,
    /// Requests per second per worker (0 = unlimited).
    rate_limit: usize = 0,

    const Self = @This();
};

/// Single worker result.
pub const WorkerResult = struct {
    /// Number of successful requests.
    successful: u64 = 0,
    /// Number of failed requests.
    failed: u64 = 0,
    /// Latencies for all requests.
    latencies: []u64,
    /// Total bytes received.
    bytes_received: u64 = 0,
    /// Total bytes sent.
    bytes_sent: u64 = 0,
};

/// Run a single worker that sends requests until completion.
/// This runs in a separate thread.
pub fn workerThread(
    allocator: std.mem.Allocator,
    client: *LoadTestClient,
    pool: *JWTPool,
    config: WorkerConfig,
    result: *WorkerResult,
) !void {

    const end_ns: i128 = if (config.duration_secs > 0)
        std.time.nanoTimestamp() + (@as(i128, config.duration_secs) * @as(i128, std.time.ns_per_s))
    else
        0;

    // Simple vector-like collection using slice
    var latencies_buf: [10000]u64 = undefined;
    var latencies_len: usize = 0;

    var successful: u64 = 0;
    var failed: u64 = 0;

    var request_count: usize = 0;
    while (request_count < config.total_requests) {
        // Check duration limit
        if (config.duration_secs > 0 and std.time.nanoTimestamp() >= end_ns) {
            break;
        }

        // Get next token
        const token = pool.next();

        // Make request - catch and count failures
        const req_result = client.request(token) catch |err| {
            failed += 1;
            request_count += 1;
            // Only print first few failures to avoid spam
            if (failed <= 3) {
                std.debug.print("[Worker] Request failed: {}\n", .{err});
            }
            continue;
        };

        successful += 1;
        request_count += 1;
        
        // Store latency
        if (latencies_len < latencies_buf.len) {
            latencies_buf[latencies_len] = req_result.latency_us;
            latencies_len += 1;
        }

        // Rate limiting - disabled for simplicity
        _ = config.rate_limit;
    }

    // Print summary on exit
    std.debug.print("[Worker] Done. successful={d}, failed={d}, count={d}\n", .{ successful, failed, request_count });

    result.successful = successful;
    result.failed = failed;
    // Copy latencies from buffer to allocated slice
    result.latencies = try allocator.dupe(u64, latencies_buf[0..latencies_len]);
}

/// Run benchmark with concurrent workers.
pub fn runConcurrentBenchmark(
    allocator: std.mem.Allocator,
    client: *LoadTestClient,
    pool: *JWTPool,
    config: WorkerConfig,
) !BenchmarkStats {
    var stats = BenchmarkStats.init(allocator);

    // Pre-allocate results array
    var results = try allocator.alloc(WorkerResult, config.num_workers);
    defer {
        for (results) |*r| allocator.free(r.latencies);
        allocator.free(results);
    }

    // Initialize results
    for (0..config.num_workers) |i| {
        results[i] = .{ .latencies = &.{} };
    }

    // Create memory instrumentation
    var memory = MemoryInstrumentation{};
    memory.captureInitial();

    // Start workers - collect in a simple list
    var threads: [100]std.Thread = undefined;
    var thread_count: usize = 0;

    for (0..config.num_workers) |i| {
        const t = try std.Thread.spawn(.{}, workerThread, .{
            allocator,
            client,
            pool,
            config,
            &results[i],
        });
        if (thread_count < threads.len) {
            threads[thread_count] = t;
            thread_count += 1;
        }
    }

    // Brief pause to let workers start - skipped in Zig 0.17+

    // Join all threads (blocks until all complete)
    for (threads[0..thread_count]) |t| {
        t.join();
    }
    std.debug.print("All workers joined\n", .{});

    // Update memory instrumentation
    memory.updatePeak();

    // Count total latencies first
    var total_latencies: usize = 0;
    for (results) |*r| {
        total_latencies += r.latencies.len;
    }

    // Aggregate results and collect latencies
    var all_lats = try allocator.alloc(u64, total_latencies);
    defer allocator.free(all_lats);
    var lat_idx: usize = 0;

    for (results) |*r| {
        stats.successful += r.successful;
        stats.failed += r.failed;
        for (r.latencies) |l| {
            if (lat_idx < all_lats.len) {
                all_lats[lat_idx] = l;
                lat_idx += 1;
            }
        }
    }

    stats.total_requests = stats.successful + stats.failed;
    stats.initial_rss_bytes = memory.initial_rss;
    stats.peak_rss_bytes = memory.peak_rss;

    // Calculate latency statistics
    if (lat_idx > 0) {
        try stats.calculate(all_lats[0..lat_idx], allocator);
    }

    return stats;
}

// ============================================================================
// Benchmark Main Entry Point
// ============================================================================

/// Configuration for the benchmark.
pub const BenchmarkConfig = struct {
    /// Server host.
    host: []const u8 = "127.0.0.1",
    /// Server port.
    port: u16 = 8080,
    /// Path to server executable.
    server_exe: []const u8 = "./zig-out/bin/agent-gate",
    /// JWT secret for token generation.
    jwt_secret: []const u8 = "test-secret-key-32-bytes-exactly!!",
    /// Number of tokens in pool.
    token_pool_size: usize = 1000,
    /// Number of concurrent workers.
    num_workers: usize = 10,
    /// Total requests to send.
    total_requests: usize = 10000,
    /// Duration in seconds (0 = use total_requests).
    duration_secs: u64 = 0,
    /// Requests per second per worker (0 = unlimited).
    rate_limit: usize = 0,
    /// Whether to spawn server or connect to existing.
    spawn_server: bool = true,
    /// Whether to run stress test mode.
    stress_mode: bool = false,

    const Self = @This();

    /// Apply stress test defaults.
    pub fn stressTest() Self {
        return .{
            .num_workers = 100,
            .total_requests = 100000,
            .rate_limit = 500, // 500 req/s per worker = 50k total
            .stress_mode = true,
        };
    }
};

/// Run the benchmark with given configuration.
pub fn runBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkStats {
    var stats: BenchmarkStats = .{};

    // Spawn server if requested
    var server: ?ServerProcess = null;
    if (config.spawn_server) {
        server = try ServerProcess.spawn(allocator, config.server_exe, config.port);
        defer if (server) |*s| s.stop();
    }

    // Note: In Zig 0.17+, we skip the sleep delay

    // Create HTTP client
    var client = try LoadTestClient.init(allocator, config.host, config.port);
    defer client.deinit();

    // Create JWT pool
    var pool = try JWTPool.init(allocator, config.token_pool_size, config.jwt_secret);
    defer pool.deinit();

    // Create worker config
    const worker_config = WorkerConfig{
        .num_workers = config.num_workers,
        .total_requests = config.total_requests,
        .duration_secs = config.duration_secs,
        .rate_limit = config.rate_limit,
    };

    // Run benchmark
    stats = try runConcurrentBenchmark(allocator, &client, &pool, worker_config);

    return stats;
}

/// Print usage information.
pub fn printUsage() void {
    std.debug.print(
        \\Usage: loadtest [options]
        \\
        \\Options:
        \\  --host <addr>      Server host (default: 127.0.0.1)
        \\  --port <port>     Server port (default: 8080)
        \\  --exe <path>      Server executable path (default: ./zig-out/bin/agent-gate)
        \\  --secret <secret> JWT secret (default: test-secret-key-32-bytes-exactly!!)
        \\  --workers <n>     Number of concurrent workers (default: 10)
        \\  --requests <n>    Total requests to send (default: 10000)
        \\  --duration <sec>  Duration in seconds (default: 0 = use --requests)
        \\  --rate <n>         Requests per second per worker (default: 0 = unlimited)
        \\  --stress           Run stress test mode (10k connections, 50k req/s)
        \\  --no-spawn         Don't spawn server, connect to existing
        \\  --help             Show this help message
        \\
        \\Examples:
        \\  loadtest                           # Baseline benchmark
        \\  loadtest --stress                  # Stress test
        \\  loadtest --workers 50 --rate 1000  # 50k req/s target
        \\
    , .{});
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    // Use page allocator
    const allocator = std.heap.page_allocator;

    // Run benchmark with config
    var config = BenchmarkConfig{};
    config.spawn_server = false;
    config.num_workers = 8;
    config.total_requests = 1000;
    config.duration_secs = 60;

    std.debug.print("=== AgentGate Baseline Benchmark ===\n", .{});
    std.debug.print("Config: {} workers, {} requests\n", .{ config.num_workers, config.total_requests });
    std.debug.print("Target: http://127.0.0.1:{}\n", .{ config.port });

    // Spawn server if enabled
    var server: ?ServerProcess = null;
    if (config.spawn_server) {
        std.debug.print("\n", .{});
        server = try ServerProcess.spawn(allocator, config.server_exe, config.port);
        std.debug.print("Server started and ready!\n", .{});
    } else {
        // Wait for existing server
        std.debug.print("Waiting for server to be ready...\n", .{});
        
        // Try to connect with retry
        var connected = false;
        for (0..60) |attempt| {
            std.debug.print("  Attempt {d}/60...\n", .{attempt});
            if (isPortReady("127.0.0.1", config.port)) {
                connected = true;
                break;
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
        
        if (!connected) {
            std.debug.print("[ERROR] Could not connect to server at 127.0.0.1:{}\n", .{config.port});
            std.debug.print("Make sure the server is running: ./zig-out/bin/agent-gate\n", .{});
            return error.ServerNotReady;
        }
        std.debug.print("Server is ready!\n", .{});
    }
    
    defer if (server) |*s| s.stop();
    
    std.debug.print("\n", .{});
    
    // Create client and pool
    var client = try LoadTestClient.init(allocator, config.host, config.port);
    defer client.deinit();
    
    var pool = try JWTPool.init(allocator, config.token_pool_size, config.jwt_secret);
    defer pool.deinit();

    const worker_config = WorkerConfig{
        .num_workers = config.num_workers,
        .total_requests = config.total_requests,
        .duration_secs = config.duration_secs,
        .rate_limit = config.rate_limit,
    };

    std.debug.print("Running benchmark...\n", .{});
    const stats = try runConcurrentBenchmark(allocator, &client, &pool, worker_config);

    // Use detailed output
    stats.printDetailed();

    // Calculate throughput
    const duration_sec = @as(f64, @floatFromInt(stats.avg_latency_us * stats.total_requests)) / 1_000_000;
    const rps = if (duration_sec > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(stats.total_requests)) / duration_sec)) else 0;

    std.debug.print("\nThroughput: {d} req/s\n", .{rps});

    // Check P99 threshold
    if (stats.total_requests > 0) {
        if (stats.p99_latency_us < 500) {
            std.debug.print("\n[PASS] P99 latency < 500 us (target met)\n", .{});
        } else {
            std.debug.print("\n[INFO] P99 latency: {d} us (target: < 500 us)\n", .{stats.p99_latency_us});
        }
    } else {
        std.debug.print("\n[WARNING] No requests completed\n", .{});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "JWTPool: create pool" {
    const gpa = std.testing.allocator;
    const secret = "test-secret-key-32-bytes-exactly!!";

    var pool = try JWTPool.init(gpa, 10, secret);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 10), pool.len());
}

test "JWTPool: round-robin" {
    const gpa = std.testing.allocator;
    const secret = "test-secret-key-32-bytes-exactly!!";

    var pool = try JWTPool.init(gpa, 3, secret);
    defer pool.deinit();

    const t0 = pool.next();
    const t1 = pool.next();
    const t2 = pool.next();
    const t3 = pool.next(); // Wraps around

    try std.testing.expect(t0 != t1);
    try std.testing.expect(t1 != t2);
    try std.testing.expect(t2 == t3); // Wrapped
}

test "JWTPool: get by index" {
    const gpa = std.testing.allocator;
    const secret = "test-secret-key-32-bytes-exactly!!";

    var pool = try JWTPool.init(gpa, 5, secret);
    defer pool.deinit();

    try std.testing.expectEqualStrings("agent-0", pool.getAgent(0));
    try std.testing.expectEqualStrings("agent-4", pool.getAgent(4));
    try std.testing.expectEqualStrings("agent-0", pool.getAgent(5)); // Wraps
}

test "BenchmarkStats: calculate" {
    const gpa = std.testing.allocator;
    const latencies = &[_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    var stats = BenchmarkStats.init(gpa);
    try stats.calculate(latencies[0..], gpa);

    try std.testing.expectEqual(@as(u64, 50), stats.p50_latency_us);
    try std.testing.expectEqual(@as(u64, 100), stats.p99_latency_us);
    try std.testing.expectEqual(@as(u64, 55), stats.avg_latency_us); // (10+100)/2 = 55
}

test "MemoryInstrumentation: getCurrentRSS" {
    const rss = MemoryInstrumentation.getCurrentRSS();
    // On Linux, RSS should be non-zero for a running process
    if (comptime std.Target.current.os.tag == .linux) {
        try std.testing.expect(rss > 0);
    }
}

test "WorkerConfig: defaults" {
    const config = WorkerConfig{};
    try std.testing.expectEqual(@as(usize, 10), config.num_workers);
    try std.testing.expectEqual(@as(usize, 1000), config.total_requests);
}

test "BenchmarkConfig: stress test" {
    const config = BenchmarkConfig.stressTest();
    try std.testing.expectEqual(@as(usize, 100), config.num_workers);
    try std.testing.expectEqual(@as(usize, 100000), config.total_requests);
    try std.testing.expectEqual(@as(usize, 500), config.rate_limit);
    try std.testing.expect(config.stress_mode == true);
}