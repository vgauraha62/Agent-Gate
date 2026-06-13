const std = @import("std");
const histogram = @import("histogram.zig");
const Histogram = histogram.Histogram;

pub const Metrics = struct {
    // Counters (atomic)
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    authenticated_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    unauthorized_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allowed_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    denied_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Active sessions gauge
    active_sessions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Latency histogram
    latency_histogram: Histogram = Histogram.init(),

    /// Record a request with latency
    pub fn recordRequest(self: *Metrics, latency_us: u64, allowed: bool) void {
        self.latency_histogram.record(latency_us);
        _ = self.requests_total.fetchAdd(1, .monotonic);
        if (allowed) {
            _ = self.allowed_requests.fetchAdd(1, .monotonic);
        } else {
            _ = self.denied_requests.fetchAdd(1, .monotonic);
        }
    }

    /// Get P50 latency
    pub fn p50(self: *const Metrics) u64 {
        return self.latency_histogram.p50();
    }

    /// Get P90 latency
    pub fn p90(self: *const Metrics) u64 {
        return self.latency_histogram.p90();
    }

    /// Get P99 latency
    pub fn p99(self: *const Metrics) u64 {
        return self.latency_histogram.p99();
    }

    /// Get P99.9 latency
    pub fn p999(self: *const Metrics) u64 {
        return self.latency_histogram.p999();
    }

    /// Get mean latency
    pub fn meanLatency(self: *const Metrics) u64 {
        return self.latency_histogram.mean();
    }

    /// Get request count
    pub fn requestCount(self: *const Metrics) u64 {
        return self.requests_total.load(.monotonic);
    }

    /// Get allowed count
    pub fn allowedCount(self: *const Metrics) u64 {
        return self.allowed_requests.load(.monotonic);
    }

    /// Get denied count
    pub fn deniedCount(self: *const Metrics) u64 {
        return self.denied_requests.load(.monotonic);
    }

    /// Get active sessions
    pub fn activeSessions(self: *const Metrics) u64 {
        return self.active_sessions.load(.monotonic);
    }

    /// Simple metrics export - using std.fmt for reliability
    pub fn exportMetrics(self: *Metrics) []const u8 {
        var buf: [4096]u8 = [_]u8{0} ** 4096;
        
        const req = self.requests_total.load(.monotonic);
        const all = self.allowed_requests.load(.monotonic);
        const den = self.denied_requests.load(.monotonic);
        const act = self.active_sessions.load(.monotonic);
        const cnt = self.latency_histogram.count();
        const p50_val = self.p50();
        const p90_val = self.p90();
        const p99_val = self.p99();
        
        const output = std.fmt.bufPrint(&buf, 
            "requests_total: {d}\nallowed: {d}\ndenied: {d}\nactive: {d}\nhistogram_count: {d}\nlatency_p50: {d}\nlatency_p90: {d}\nlatency_p99: {d}\n",
            .{ req, all, den, act, cnt, p50_val, p90_val, p99_val }) catch return buf[0..0];
        
        return output;
    }

    /// Full export
    pub fn exportMetricsFull(self: *Metrics) []const u8 {
        return self.exportMetrics();
    }

    pub fn incRequests(self: *Metrics) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
    }

    pub fn incAllowed(self: *Metrics) void {
        _ = self.allowed_requests.fetchAdd(1, .monotonic);
    }

    pub fn incDenied(self: *Metrics) void {
        _ = self.denied_requests.fetchAdd(1, .monotonic);
    }

    pub fn incConnections(self: *Metrics) void {
        _ = self.active_sessions.fetchAdd(1, .monotonic);
    }

    pub fn decConnections(self: *Metrics) void {
        _ = self.active_sessions.fetchSub(1, .monotonic);
    }

    pub fn incActiveSessions(self: *Metrics) void {
        _ = self.active_sessions.fetchAdd(1, .monotonic);
    }

    pub fn decActiveSessions(self: *Metrics) void {
        _ = self.active_sessions.fetchSub(1, .monotonic);
    }
};

pub var global_metrics: Metrics = Metrics{};

pub fn getMetrics() []const u8 {
    return global_metrics.exportMetrics();
}

pub fn getMetricsFull() []const u8 {
    return global_metrics.exportMetricsFull();
}

pub fn incrementCounter(counter: *std.atomic.Value(u64)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

test "Metrics counter basic" {
    var m = Metrics{};
    try std.testing.expectEqual(@as(u64, 0), m.requests_total.load(.monotonic));
}

test "Metrics export format" {
    var m = Metrics{};
    m.requests_total.store(100, .monotonic);
    m.allowed_requests.store(80, .monotonic);

    const output = m.exportMetrics();
    try std.testing.expect(std.mem.indexOf(u8, output, "requests_total") != null);
}

test "Metrics histogram record" {
    var m = Metrics{};

    m.recordRequest(100, true);
    m.recordRequest(200, true);
    m.recordRequest(50, false);

    try std.testing.expectEqual(@as(u64, 3), m.requestCount());
    try std.testing.expectEqual(@as(u64, 2), m.allowedCount());
    try std.testing.expectEqual(@as(u64, 1), m.deniedCount());
    try std.testing.expectEqual(@as(u64, 350), m.latency_histogram.sum());
}

test "Metrics percentile calculation" {
    var m = Metrics{};

    for (1..101) |i| {
        m.recordRequest(@intCast(i), true);
    }

    const p50 = m.p50();
    const p90 = m.p90();
    const p99 = m.p99();

    try std.testing.expect(p50 > 0);
    try std.testing.expect(p90 >= p50);
    try std.testing.expect(p99 >= p90);
}

test "Metrics backward compatibility" {
    var m = Metrics{};

    m.incRequests();
    m.incAllowed();
    m.incDenied();
    m.incConnections();
    m.decConnections();

    try std.testing.expectEqual(@as(u64, 1), m.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.allowed_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.denied_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.active_sessions.load(.monotonic));
}

test "Metrics export includes latency" {
    var m = Metrics{};

    m.recordRequest(100, true);
    m.recordRequest(200, true);

    const output = m.exportMetrics();
    try std.testing.expect(std.mem.indexOf(u8, output, "histogram_count") != null);
}