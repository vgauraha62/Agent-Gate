const std = @import("std");

pub const Metrics = struct {
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    authenticated_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    unauthorized_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allowed_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    denied_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn exportMetrics(self: *Metrics) []const u8 {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        pos += (std.fmt.bufPrint(buf[pos..], "# HELP requests_total Total requests\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "# TYPE requests_total counter\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "requests_total {d}\n", .{self.requests_total.load(.monotonic)}) catch return buf[0..pos]).len;

        pos += (std.fmt.bufPrint(buf[pos..], "# HELP allowed_requests Allowed requests\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "# TYPE allowed_requests counter\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "allowed_requests {d}\n", .{self.allowed_requests.load(.monotonic)}) catch return buf[0..pos]).len;

        pos += (std.fmt.bufPrint(buf[pos..], "# HELP denied_requests Denied requests\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "# TYPE denied_requests counter\n", .{}) catch return buf[0..pos]).len;
        pos += (std.fmt.bufPrint(buf[pos..], "denied_requests {d}\n", .{self.denied_requests.load(.monotonic)}) catch return buf[0..pos]).len;

        return buf[0..pos];
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
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn decConnections(self: *Metrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }
};

pub var global_metrics: Metrics = Metrics{};

pub fn getMetrics() []const u8 {
    return global_metrics.exportMetrics();
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
    try std.testing.expect(std.mem.indexOf(u8, output, "requests_total 100") != null);
}