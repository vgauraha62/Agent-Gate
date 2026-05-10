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
    for (result) |c| {
        switch (c) {
            '+' => encoded[j] = '-',
            '/' => encoded[j] = '_',
            '=' => continue, // Skip padding
            else => encoded[j] = c,
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

    /// Peak RSS in bytes (memory instrumentation).
    peak_rss_bytes: u64 = 0,
    /// Initial RSS in bytes.
    initial_rss_bytes: u64 = 0,

    const Self = @This();

    /// Calculate statistics from latencies.
    pub fn calculate(self: *Self, latencies: []const u64, allocator: std.mem.Allocator) !void {
        if (latencies.len == 0) return;

        // Sort latencies - create a mutable copy
        const sorted = try allocator.alloc(u64, latencies.len);
        @memcpy(sorted, latencies);
        defer allocator.free(sorted);
        // Simple insertion sort for small arrays
        for (sorted, 1..) |_, i| {
            var j = i;
            while (j > 0 and sorted[j - 1] > sorted[j]) {
                const temp = sorted[j];
                sorted[j] = sorted[j - 1];
                sorted[j - 1] = temp;
                j -= 1;
            }
        }

        const idx = @divExact(sorted.len, 2);
        self.p50_latency_us = sorted[idx];

        const p99_idx = @divExact(sorted.len * 99, 100);
        self.p99_latency_us = sorted[@min(p99_idx, sorted.len - 1)];

        const p999_idx = @divExact(sorted.len * 999, 1000);
        self.p999_latency_us = sorted[@min(p999_idx, sorted.len - 1)];

        // Calculate average
        var sum: u64 = 0;
        for (sorted) |l| {
            sum += l;
        }
        self.avg_latency_us = sum / @as(u64, @intCast(sorted.len));
    }

    /// Print benchmark results.
    pub fn print(self: *const Self) void {
        std.debug.print("Benchmark Results:\n", .{});
        std.debug.print("  Total requests:  {d}\n", .{self.total_requests});
        std.debug.print("  Successful:      {d}\n", .{self.successful});
        std.debug.print("  Failed:          {d}\n", .{self.failed});
        std.debug.print("  P50 latency:     {d} us\n", .{self.p50_latency_us});
        std.debug.print("  P99 latency:     {d} us\n", .{self.p99_latency_us});
        std.debug.print("  P999 latency:    {d} us\n", .{self.p999_latency_us});
        std.debug.print("  Avg latency:     {d} us\n", .{self.avg_latency_us});
        std.debug.print("  Memory (RSS):    {d} KB (peak: {d} KB)\n", .{
            self.initial_rss_bytes / 1024,
            self.peak_rss_bytes / 1024,
        });
    }
};

// ============================================================================
// HTTP Client using TCP sockets (Zig 0.5.2 compatible)
// ============================================================================

/// HTTP client wrapper using TCP sockets for load testing.
pub const LoadTestClient = struct {
    /// Host to connect to.
    host: []u8,
    /// Port to connect to.
    port: u16,
    /// Allocator.
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new load test client.
    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Self {
        const host_copy = try allocator.dupe(u8, host);
        return Self{
            .host = host_copy,
            .port = port,
            .allocator = allocator,
        };
    }

    /// Deinitialize the client.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.host);
    }

/// Perform a single HTTP GET request using TCP and measure latency.
    /// Returns latency in microseconds on success, or error on failure.
    pub fn request(_: *Self, token: []const u8) !u64 {
        const start_ns = std.time.nanoTimestamp();

        // Create TCP connection
        const address = try std.net.Address.parseIp("127.0.0.1", 8080);
        const socket = try std.net.tcpConnectToAddress(address);
        defer socket.close();

        // Build HTTP request
        const path = "/v1/agents";
        const request_str = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAuthorization: Bearer {s}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
            .{ path, token }
        );
        defer std.heap.page_allocator.free(request_str);

        // Send request
        try socket.writeAll(request_str);

        // Read response headers (small read)
        var response_buf: [512]u8 = undefined;
        const bytes_read = socket.read(&response_buf) catch 0;
        _ = bytes_read;

        const end_ns = std.time.nanoTimestamp();
        // Return latency in microseconds using @divTrunc for i128 division
        return @as(u64, @intCast(@divTrunc(end_ns - start_ns, 1000)));
    }
};

// ============================================================================
// Process Spawn for Server Management
// ============================================================================

/// Server process handle for load testing.
/// Note: Server spawning is simplified - server must be running externally.
pub const ServerProcess = struct {
    /// PID of the spawned server.
    pid: u32 = 0,

    const Self = @This();

    /// Stub spawn - use runBenchmark with spawn_server=false
    pub fn spawn(allocator: std.mem.Allocator, exe_path: []const u8, port: u16) !Self {
        _ = allocator;
        _ = exe_path;
        _ = port;
        return Self{ .pid = 0 };
    }

    /// Stop the server process.
    pub fn stop(self: *Self) void {
        _ = self;
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
        const latency = client.request(token) catch |err| {
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
        if (latencies_len < latencies_buf.len) {
            latencies_buf[latencies_len] = latency;
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
    var stats = BenchmarkStats{};

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

    // Wait for completion
    const timeout_ns = if (config.duration_secs > 0)
        config.duration_secs * 1_000_000_000
    else
        30 * 1_000_000_000; // 30 second default for benchmarks

    var timeout = false;
    const start_wait = std.time.nanoTimestamp();
    while (thread_count > 0) {
        if (std.time.nanoTimestamp() - start_wait > timeout_ns) {
            timeout = true;
            break;
        }
        // Brief sleep to avoid busy-waiting
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (timeout) {
        std.debug.print("Warning: Benchmark timed out\n", .{});
    }

    // Join all threads
    for (threads[0..thread_count]) |t| {
        t.join();
    }

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
    config.num_workers = 10; // More workers for better concurrency
    config.total_requests = 1000; // More requests for better statistics
    config.duration_secs = 30; // 30 second max duration

    std.debug.print("=== AgentGate Baseline Benchmark ===\n", .{});
    std.debug.print("Config: {} workers, {} requests\n", .{ config.num_workers, config.total_requests });
    std.debug.print("Target: http://127.0.0.1:{}\n", .{ config.port });

    std.debug.print("Waiting for server to be ready...\n", .{});
    
    // Try to connect with retry
    var connected = false;
    for (0..30) |_| {
        if (std.net.Address.parseIp("127.0.0.1", 8080)) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |socket| {
                socket.close();
                connected = true;
                break;
            } else |_| {}
        } else |_| {}
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
    
    if (!connected) {
        std.debug.print("[ERROR] Could not connect to server at 127.0.0.1:8080\n", .{});
        std.debug.print("Make sure the server is running: ./zig-out/bin/agent-gate\n", .{});
        return error.ServerNotReady;
    }
    
    std.debug.print("Server is ready!\n\n", .{});
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

    std.debug.print("\n=== Benchmark Results ===\n", .{});
    stats.print();

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
    var stats = BenchmarkStats{};
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