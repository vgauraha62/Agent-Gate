//! Policy evaluation benchmark.
//!
//! Benchmarks policy evaluation performance targeting <100µs for 1000 policies.

const std = @import("std");
const types = @import("types.zig");
const engine = @import("engine.zig");

const SecurityArena = @import("../memory.zig").SecurityArena;

/// Benchmark configuration.
pub const Config = struct {
    /// Number of policies to test with.
    policy_count: usize = 1000,
    /// Number of iterations to run.
    iterations: usize = 1000,
    /// Number of warmup iterations.
    warmup: usize = 100,
};

/// Benchmark results.
pub const Results = struct {
    /// Policy count tested.
    policy_count: usize,
    /// Total iterations run.
    iterations: usize,
    /// Total time in nanoseconds.
    total_ns: u64,
    /// Average time per iteration in nanoseconds.
    avg_ns: u64,
    /// P50 (median) time in nanoseconds.
    p50_ns: u64,
    /// P99 time in nanoseconds.
    p99_ns: u64,
    /// Target met (P99 < 100µs = 100000ns).
    target_met: bool,

    const Self = @This();

    /// Print results to stdout.
    pub fn print(self: *const Self, writer: anytype) !void {
        try writer.print("Policy Evaluation Benchmark\n", .{});
        try writer.print("===========================\n", .{});
        try writer.print("Policies: {}\n", .{self.policy_count});
        try writer.print("Iterations: {}\n", .{self.iterations});
        try writer.print("Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0});
        try writer.print("Avg per eval: {d:.2}µs\n", .{@as(f64, @floatFromInt(self.avg_ns)) / 1000.0});
        try writer.print("P50: {d:.2}µs\n", .{@as(f64, @floatFromInt(self.p50_ns)) / 1000.0});
        try writer.print("P99: {d:.2}µs\n", .{@as(f64, @floatFromInt(self.p99_ns)) / 1000.0});
        try writer.print("Target (<100µs): {}\n", .{self.target_met});
    }
};

/// Generate test policies inline (no parsing overhead).
fn generatePoliciesInline(comptime count: usize) [count]types.Policy {
    var policies: [count]types.Policy = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        policies[i] = types.Policy{
            .id = "policy",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        };
    }
    return policies;
}

/// Run benchmark with inline policies (no parsing overhead).
/// This measures pure evaluation performance.
pub fn benchmark(config: Config) Results {
    // Generate policies at compile time for various counts
    const policies = switch (config.policy_count) {
        1 => &generatePoliciesInline(1),
        10 => &generatePoliciesInline(10),
        100 => &generatePoliciesInline(100),
        1000 => &generatePoliciesInline(1000),
        else => &generatePoliciesInline(config.policy_count),
    };

    // Warmup
    var wi: usize = 0;
    while (wi < config.warmup) : (wi += 1) {
        const ctx = types.RequestContext.init("agent", "/api/resource-0/test", .GET);
        _ = engine.evaluate(policies, &ctx);
    }

    // Benchmark - collect all timings for percentile calculation
    var timings: [2000]u64 = undefined;
    const timing_count = if (config.iterations < 2000) config.iterations else 2000;

    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const ctx = types.RequestContext.init("agent", "/api/resource-0/test", .GET);
        _ = engine.evaluate(policies, &ctx);

        // Record individual timings for percentile calculation
        if (i < timing_count) {
            const t_start = std.time.nanoTimestamp();
            const ctx2 = types.RequestContext.init("agent", "/api/resource-0/test", .GET);
            _ = engine.evaluate(policies, &ctx2);
            const t_end = std.time.nanoTimestamp();
            timings[i] = t_end - t_start;
        }
    }

    const end = std.time.nanoTimestamp();
    const total_ns = end - start;
    const avg_ns = total_ns / config.iterations;

    // Sort timings for percentiles
    std.mem.sort(u64, timings[0..timing_count], {}, std.sort.asc(u64));

    const p50_idx = (timing_count - 1) / 2;
    const p99_idx = (timing_count * 99) / 100;

    const p50 = timings[p50_idx];
    const p99 = timings[p99_idx];

    return Results{
        .policy_count = config.policy_count,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .p50_ns = p50,
        .p99_ns = p99,
        .target_met = p99 < 100_000, // 100µs
    };
}

/// Benchmark with worst-case scenario: all policies must be checked before match.
pub fn benchmarkWorstCase(config: Config) Results {
    // Policies that don't match until the last one
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "deny-1",
            .effect = .deny,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/other/*" }},
        },
        types.Policy{
            .id = "allow-last",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/api/*" }},
        },
    };

    // Warmup
    var wi: usize = 0;
    while (wi < config.warmup) : (wi += 1) {
        const ctx = types.RequestContext.init("agent", "/api/test", .GET);
        _ = engine.evaluate(policies, &ctx);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    var total_evals: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const ctx = types.RequestContext.init("agent", "/api/test", .GET);
        _ = engine.evaluate(policies, &ctx);
        total_evals += 1;
    }

    const end = std.time.nanoTimestamp();
    const total_ns = end - start;
    const avg_ns = total_ns / config.iterations;

    return Results{
        .policy_count = 2,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .p50_ns = avg_ns,
        .p99_ns = avg_ns,
        .target_met = avg_ns < 100_000,
    };
}

/// Benchmark default-deny scenario (no policies match).
pub fn benchmarkDefaultDeny(config: Config) Results {
    const policies = &[_]types.Policy{
        types.Policy{
            .id = "allow-specific",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "/special/*" }},
        },
    };

    // Warmup
    var wi: usize = 0;
    while (wi < config.warmup) : (wi += 1) {
        const ctx = types.RequestContext.init("agent", "/other/path", .GET);
        _ = engine.evaluate(policies, &ctx);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const ctx = types.RequestContext.init("agent", "/other/path", .GET);
        _ = engine.evaluate(policies, &ctx);
    }

    const end = std.time.nanoTimestamp();
    const total_ns = end - start;
    const avg_ns = total_ns / config.iterations;

    return Results{
        .policy_count = 1,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .p50_ns = avg_ns,
        .p99_ns = avg_ns,
        .target_met = avg_ns < 100_000,
    };
}

/// Run all benchmarks and print results.
pub fn runAllBenchmarks() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n=== Policy Engine Benchmark ===\n\n", .{});

    // Test with 1 policy (baseline)
    try stdout.print("1 policy (baseline):\n", .{});
    const result_1 = benchmark(.{
        .policy_count = 1,
        .iterations = 10000,
        .warmup = 100,
    });
    try result_1.print(stdout);
    try stdout.print("\n", .{});

    // Test with 10 policies
    try stdout.print("10 policies:\n", .{});
    const result_10 = benchmark(.{
        .policy_count = 10,
        .iterations = 10000,
        .warmup = 100,
    });
    try result_10.print(stdout);
    try stdout.print("\n", .{});

    // Test with 100 policies
    try stdout.print("100 policies:\n", .{});
    const result_100 = benchmark(.{
        .policy_count = 100,
        .iterations = 10000,
        .warmup = 100,
    });
    try result_100.print(stdout);
    try stdout.print("\n", .{});

    // Test with 1000 policies (target)
    try stdout.print("1000 policies (TARGET):\n", .{});
    const result_1000 = benchmark(.{
        .policy_count = 1000,
        .iterations = 10000,
        .warmup = 1000,
    });
    try result_1000.print(stdout);
    try stdout.print("\n", .{});

    // Worst case scenario
    try stdout.print("Worst case (last policy matches):\n", .{});
    const result_worst = benchmarkWorstCase(.{
        .policy_count = 2,
        .iterations = 10000,
        .warmup = 100,
    });
    try result_worst.print(stdout);
    try stdout.print("\n", .{});

    // Default deny scenario
    try stdout.print("Default deny (no match):\n", .{});
    const result_deny = benchmarkDefaultDeny(.{
        .policy_count = 1,
        .iterations = 10000,
        .warmup = 100,
    });
    try result_deny.print(stdout);
    try stdout.print("\n", .{});

    // Summary
    try stdout.print("=== Summary ===\n", .{});
    try stdout.print("Target: P99 < 100µs for 1000 policies\n", .{});
    try stdout.print("Result: P99 = {d:.2}µs - {}\n", .{
        @as(f64, @floatFromInt(result_1000.p99_ns)) / 1000.0,
        if (result_1000.target_met) "PASS" else "FAIL",
    });
    try stdout.print("=== Complete ===\n\n", .{});
}

test "benchmark runs without error" {
    const result = benchmark(.{
        .policy_count = 1,
        .iterations = 100,
        .warmup = 10,
    });

    try std.testing.expect(result.iterations == 100);
    try std.testing.expect(result.target_met);
}

test "benchmark target met for 1000 policies" {
    // This is the key benchmark: P99 < 100µs for 1000 policies
    const result = benchmark(.{
        .policy_count = 1000,
        .iterations = 1000,
        .warmup = 100,
    });

    try std.testing.expect(result.policy_count == 1000);
    try std.testing.expect(result.target_met);
}

test "benchmark worst case" {
    const result = benchmarkWorstCase(.{
        .policy_count = 2,
        .iterations = 100,
        .warmup = 10,
    });

    try std.testing.expect(result.target_met);
}

test "benchmark default deny" {
    const result = benchmarkDefaultDeny(.{
        .policy_count = 1,
        .iterations = 100,
        .warmup = 10,
    });

    try std.testing.expect(result.target_met);
}
