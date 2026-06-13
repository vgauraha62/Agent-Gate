//! Usage Tracker for hosted AgentGate.
//!
//! Tracks API usage per key with sliding-window rate limiting.
//! Periodically flushes usage data to persistent storage.

const std = @import("std");
const time = std.time;

// ============================================================================
// Constants
// ============================================================================

/// Window size for rate limiting (in seconds).
pub const RATE_LIMIT_WINDOW: u64 = 1; // 1-second sliding window
/// How often to persist usage data (in seconds).
pub const FLUSH_INTERVAL: u64 = 30;
/// Maximum number of tracked keys in memory.
pub const MAX_TRACKED_KEYS: usize = 10_000;

// ============================================================================
// Types
// ============================================================================

/// A single usage record.
pub const UsageRecord = struct {
    /// SHA256 hash of the API key
    key_hash: [32]u8,
    /// Timestamp of this request (microseconds)
    timestamp_us: i64,
    /// Request path
    path: []const u8,
    /// HTTP method
    method: []const u8,
    /// Whether the request was allowed
    allowed: bool,
    /// Response status code
    status: u16,
    /// Latency in microseconds
    latency_us: u64,
};

/// In-memory rate limit state for a single key.
pub const RateLimitState = struct {
    /// Token bucket count (for token bucket algorithm)
    tokens: f64,
    /// Last time tokens were refilled
    last_refill_us: i64,
    /// Maximum burst size
    max_burst: u32,

    const Self = @This();

    pub fn init(rate_per_second: u32) Self {
        return Self{
            .tokens = @as(f64, @floatFromInt(rate_per_second)),
            .last_refill_us = time.microTimestamp(),
            .max_burst = rate_per_second,
        };
    }

    /// Try to consume a token. Returns true if allowed.
    pub fn tryConsume(self: *Self, rate_per_second: u32) bool {
        const now_us = time.microTimestamp();
        const elapsed_us = now_us - self.last_refill_us;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_us)) / 1_000_000.0;

        // Refill tokens based on elapsed time
        self.tokens = @min(
            @as(f64, @floatFromInt(self.max_burst)),
            self.tokens + elapsed_s * @as(f64, @floatFromInt(rate_per_second)),
        );
        self.last_refill_us = now_us;

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

/// Aggregated usage stats for a key.
pub const KeyUsageStats = struct {
    key_hash: [32]u8,
    total_requests: u64,
    allowed_requests: u64,
    denied_requests: u64,
    last_request_us: i64,
    avg_latency_us: f64,
    p50_latency_us: u64,
    p99_latency_us: u64,
};

/// Usage tracker with rate limiting.
pub const UsageTracker = struct {
    /// Rate limit state per key hash
    rate_limits: std.AutoHashMap([32]u8, RateLimitState),
    /// Request log (ring buffer of recent requests)
    recent_requests: std.ArrayList(UsageRecord),
    /// Max recent requests to keep in memory
    max_recent: usize,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Thread safety
    mutex: std.Thread.Mutex,
    /// Whether tracking is enabled
    enabled: bool,
    /// Rate limiter enabled
    rate_limiting_enabled: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_recent: usize) Self {
        return Self{
            .rate_limits = std.AutoHashMap([32]u8, RateLimitState).init(allocator),
            .recent_requests = std.ArrayList(UsageRecord){},
            .max_recent = max_recent,
            .allocator = allocator,
            .mutex = .{},
            .enabled = true,
            .rate_limiting_enabled = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.rate_limits.deinit();
        self.cleanupRecentRequests();
        self.recent_requests.deinit(self.allocator);
    }

    /// Record a request and check rate limit.
    /// Makes copies of path and method strings.
    /// Returns true if the request is within rate limits.
    pub fn recordAndCheck(self: *Self, key_hash: [32]u8, rate_limit: u32, record: UsageRecord) bool {
        if (!self.enabled) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check rate limit
        if (self.rate_limiting_enabled and rate_limit > 0) {
            var state = self.rate_limits.getOrPut(key_hash) catch return true;
            if (!state.found_existing) {
                state.value_ptr.* = RateLimitState.init(rate_limit);
            }
            if (!state.value_ptr.tryConsume(rate_limit)) {
                return false; // Rate limited
            }
        }

        // Copy path and method strings (caller may be using literal strings)
        var record_copy = record;
        record_copy.path = self.allocator.dupe(u8, record.path) catch return true;
        record_copy.method = self.allocator.dupe(u8, record.method) catch {
            self.allocator.free(record_copy.path);
            return true;
        };

        // Store recent request (ring buffer style)
        if (self.recent_requests.items.len >= self.max_recent) {
            // Remove oldest
            const oldest = self.recent_requests.orderedRemove(0);
            self.allocator.free(oldest.path);
            self.allocator.free(oldest.method);
        }
        self.recent_requests.append(self.allocator, record_copy) catch {
            self.allocator.free(record_copy.path);
            self.allocator.free(record_copy.method);
        };

        return true;
    }

    /// Get usage stats for a specific key.
    pub fn getKeyStats(self: *Self, key_hash: [32]u8) ?KeyUsageStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats: KeyUsageStats = .{
            .key_hash = key_hash,
            .total_requests = 0,
            .allowed_requests = 0,
            .denied_requests = 0,
            .last_request_us = 0,
            .avg_latency_us = 0,
            .p50_latency_us = 0,
            .p99_latency_us = 0,
        };

        var total_latency: u64 = 0;
        var latencies = std.ArrayList(u64){};
        defer latencies.deinit(self.allocator);

        for (self.recent_requests.items) |*r| {
            if (std.mem.eql(u8, &r.key_hash, &key_hash)) {
                stats.total_requests += 1;
                if (r.allowed) stats.allowed_requests += 1 else stats.denied_requests += 1;
                if (r.timestamp_us > stats.last_request_us) stats.last_request_us = r.timestamp_us;
                total_latency += r.latency_us;
                latencies.append(self.allocator, r.latency_us) catch {};
            }
        }

        if (stats.total_requests > 0) {
            stats.avg_latency_us = @as(f64, @floatFromInt(total_latency)) / @as(f64, @floatFromInt(stats.total_requests));

            // Sort for percentiles
            std.mem.sort(u64, latencies.items, {}, comptime std.sort.asc(u64));
            stats.p50_latency_us = latencies.items[@min(latencies.items.len / 2, latencies.items.len - 1)];
            stats.p99_latency_us = latencies.items[@min(@as(usize, @intFromFloat(@as(f64, @floatFromInt(latencies.items.len)) * 0.99)), latencies.items.len - 1)];
        }

        return stats;
    }

    /// Get overall usage summary.
    pub fn getGlobalStats(self: *Self) GlobalUsageStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = GlobalUsageStats{};
        for (self.recent_requests.items) |*r| {
            stats.total_requests += 1;
            if (r.allowed) stats.allowed_requests += 1 else stats.denied_requests += 1;
            stats.total_latency_us += r.latency_us;
        }
        if (stats.total_requests > 0) {
            stats.avg_latency_us = @as(f64, @floatFromInt(stats.total_latency_us)) / @as(f64, @floatFromInt(stats.total_requests));
        }
        return stats;
    }

    fn cleanupRecentRequests(self: *Self) void {
        for (self.recent_requests.items) |*r| {
            self.allocator.free(r.path);
            self.allocator.free(r.method);
        }
        self.recent_requests.clearAndFree(self.allocator);
    }
};

/// Global usage summary.
pub const GlobalUsageStats = struct {
    total_requests: u64 = 0,
    allowed_requests: u64 = 0,
    denied_requests: u64 = 0,
    total_latency_us: u64 = 0,
    avg_latency_us: f64 = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "UsageTracker: basic recording" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator, 100);
    defer tracker.deinit();

    var key_hash: [32]u8 = undefined;
    @memset(&key_hash, 0xAB);

    const record = UsageRecord{
        .key_hash = key_hash,
        .timestamp_us = std.time.microTimestamp(),
        .path = "/v1/check",
        .method = "POST",
        .allowed = true,
        .status = 200,
        .latency_us = 42,
    };

    const allowed = tracker.recordAndCheck(key_hash, 100, record);
    try std.testing.expect(allowed);

    const stats = tracker.getKeyStats(key_hash);
    try std.testing.expect(stats != null);
    try std.testing.expect(stats.?.total_requests == 1);
    try std.testing.expect(stats.?.allowed_requests == 1);
}

test "UsageTracker: rate limiting kicks in" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator, 100);
    defer tracker.deinit();

    var key_hash: [32]u8 = undefined;
    @memset(&key_hash, 0x01);

    // Set rate limit to 2 per second
    const rate: u32 = 2;

    // First 2 should be allowed
    for (0..2) |i| {
        const record = UsageRecord{
            .key_hash = key_hash,
            .timestamp_us = std.time.microTimestamp(),
            .path = "/v1/check",
            .method = "POST",
            .allowed = true,
            .status = 200,
            .latency_us = @as(u64, @intCast(i)),
        };
        const allowed = tracker.recordAndCheck(key_hash, rate, record);
        try std.testing.expect(allowed);
    }

    // Third should be rate limited
    const record = UsageRecord{
        .key_hash = key_hash,
        .timestamp_us = std.time.microTimestamp(),
        .path = "/v1/check",
        .method = "POST",
        .allowed = false,
        .status = 429,
        .latency_us = 0,
    };
    const allowed = tracker.recordAndCheck(key_hash, rate, record);
    try std.testing.expect(!allowed);
}

test "UsageTracker: disabled tracking allows all" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator, 100);
    defer tracker.deinit();
    tracker.enabled = false;

    var key_hash: [32]u8 = undefined;
    @memset(&key_hash, 0xFF);

    // Even with 0 rate limit, should pass since disabled
    const record = UsageRecord{
        .key_hash = key_hash,
        .timestamp_us = std.time.microTimestamp(),
        .path = "/v1/check",
        .method = "GET",
        .allowed = true,
        .status = 200,
        .latency_us = 10,
    };
    const allowed = tracker.recordAndCheck(key_hash, 0, record);
    try std.testing.expect(allowed);
}

test "UsageTracker: global stats" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator, 1000);
    defer tracker.deinit();

    var key1: [32]u8 = undefined;
    var key2: [32]u8 = undefined;
    @memset(&key1, 0xAA);
    @memset(&key2, 0xBB);

    // Record some requests
    for (0..5) |i| {
        _ = tracker.recordAndCheck(key1, 1000, .{
            .key_hash = key1,
            .timestamp_us = std.time.microTimestamp(),
            .path = "/v1/check",
            .method = "POST",
            .allowed = i % 2 == 0,
            .status = if (i % 2 == 0) @as(u16, 200) else 403,
            .latency_us = @as(u64, @intCast(i * 10)),
        });
    }
    for (0..3) |_| {
        _ = tracker.recordAndCheck(key2, 1000, .{
            .key_hash = key2,
            .timestamp_us = std.time.microTimestamp(),
            .path = "/v1/check",
            .method = "GET",
            .allowed = true,
            .status = 200,
            .latency_us = 5,
        });
    }

    const global = tracker.getGlobalStats();
    try std.testing.expect(global.total_requests == 8);
    try std.testing.expect(global.allowed_requests == 6);
    try std.testing.expect(global.denied_requests == 2);
}
