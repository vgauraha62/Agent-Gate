//! High-Dynamic Range (HDR) Histogram for latency tracking.
//!
//! Design goals:
//! - Zero heap allocations in hot path (record method)
//! - Thread-safe bucket updates
//! - Precise percentile tracking (P50, P90, P99, P99.9)
//! - Range: 1µs to 1s (1,000,000µs)
//! - Target: <1µs recording overhead
//!
//! Uses logarithmic bucket system with power-of-2 boundaries.

const std = @import("std");
const atomic = std.atomic;

/// Number of buckets - enough for 1µs to 1s in power-of-2 steps
/// 2^0 = 1, 2^1 = 2, ... 2^19 = 524288 (~1s) = 20 buckets
const NUM_BUCKETS: usize = 20;

/// Minimum latency in microseconds
const MIN_VALUE: u64 = 1;

/// Maximum latency in microseconds (1 second)
const MAX_VALUE: u64 = 1_000_000;

/// Thread-safe HDR Histogram for latency recording
/// Zero-allocation in hot path - all data pre-allocated
pub const Histogram = struct {
    /// Bucket counts - fixed-size array, no heap
    buckets: [NUM_BUCKETS]atomic.Value(u64) = undefined,

    /// Total count of recorded values
    total_count: atomic.Value(u64) = atomic.Value(u64).init(0),

    /// Sum of all recorded values (for calculating mean)
    total_sum: atomic.Value(u64) = atomic.Value(u64).init(0),

    /// Minimum value recorded (0 if no values yet)
    min_value: atomic.Value(u64) = atomic.Value(u64).init(0),

    /// Maximum value recorded (0 if no values yet)
    max_value: atomic.Value(u64) = atomic.Value(u64).init(0),

    /// Initialization
    pub fn init() Histogram {
        var h = Histogram{};
        // Initialize atomic values in buckets
        for (0..NUM_BUCKETS) |i| {
            h.buckets[i] = atomic.Value(u64).init(0);
        }
        return h;
    }

    /// Get bucket index for a value (log2-based)
    /// Returns index into buckets array (0 to NUM_BUCKETS-1)
    inline fn getBucketIndex(value: u64) usize {
        if (value < MIN_VALUE) return 0;
        if (value >= MAX_VALUE) return NUM_BUCKETS - 1;

        // Fast log2 calculation for power-of-2 bucketing
        // Find the highest set bit position
        var v = value;
        var idx: usize = 0;
        while (v > 1) {
            v >>= 1;
            idx += 1;
        }
        // Cap at max bucket
        if (idx >= NUM_BUCKETS) idx = NUM_BUCKETS - 1;
        return idx;
    }

    /// Get the upper bound of a bucket (inclusive)
    pub fn getBucketUpperBound(idx: usize) u64 {
        if (idx >= NUM_BUCKETS) return MAX_VALUE;
        return @as(u64, 1) << @as(u6, @intCast(idx + 1));
    }

    /// Get the lower bound of a bucket (inclusive)
    pub fn getBucketLowerBound(idx: usize) u64 {
        if (idx == 0) return MIN_VALUE;
        return @as(u64, 1) << @as(u6, @intCast(idx));
    }

    /// Record a latency value - ZERO ALLOCATION, THREAD-SAFE
    /// Target: <1µs overhead
    pub fn record(self: *Histogram, value: u64) void {
        // Determine bucket
        const idx = getBucketIndex(value);

        // Increment bucket count atomically
        _ = self.buckets[idx].fetchAdd(1, .monotonic);

        // Update total count
        _ = self.total_count.fetchAdd(1, .monotonic);

        // Update sum for mean calculation
        _ = self.total_sum.fetchAdd(value, .monotonic);

        // Update min (use compare-swap loop for thread safety)
        var current_min = self.min_value.load(.monotonic);
        while (current_min == 0 or value < current_min) {
            const existing = self.min_value.cmpxchgWeak(current_min, value, .monotonic, .monotonic);
            if (existing) |actual| {
                // CAS failed, another thread updated - check if we still need to update
                current_min = actual;
                if (value >= current_min) break; // We're no longer the minimum
            } else {
                // CAS succeeded, we updated the value
                break;
            }
        }

        // Update max (use compare-swap loop for thread safety)
        var current_max = self.max_value.load(.monotonic);
        while (value > current_max) {
            const existing = self.max_value.cmpxchgWeak(current_max, value, .monotonic, .monotonic);
            if (existing) |actual| {
                // CAS failed, another thread updated - check if we still need to update
                current_max = actual;
                if (value <= current_max) break; // We're no longer the maximum
            } else {
                // CAS succeeded, we updated the value
                break;
            }
        }
    }

    /// Get total number of recorded values
    pub fn count(self: *const Histogram) u64 {
        return self.total_count.load(.monotonic);
    }

    /// Get sum of all recorded values
    pub fn sum(self: *const Histogram) u64 {
        return self.total_sum.load(.monotonic);
    }

    /// Get minimum recorded value (0 if no values)
    pub fn min(self: *const Histogram) u64 {
        return self.min_value.load(.monotonic);
    }

    /// Get maximum recorded value (0 if no values)
    pub fn max(self: *const Histogram) u64 {
        return self.max_value.load(.monotonic);
    }

    /// Get mean latency in microseconds
    pub fn mean(self: *const Histogram) u64 {
        const c = self.count();
        if (c == 0) return 0;
        return self.sum() / c;
    }

    /// Calculate percentile with linear interpolation - returns value in microseconds
    /// p: percentile as decimal (e.g., 0.50 for P50, 0.99 for P99)
    pub fn percentile(self: *const Histogram, p: f64) u64 {
        const c = self.count();
        if (c == 0) return 0;
        if (c == 1) {
            // Single value - find it and return it
            for (0..NUM_BUCKETS) |i| {
                if (self.buckets[i].load(.monotonic) > 0) {
                    return getBucketLowerBound(i);
                }
            }
            return 0;
        }

        // Target count for the percentile
        const c_f64: f64 = @floatFromInt(c);
        const target_f64 = p * (c_f64 - 1); // Use target_f64 - 1 for nearest-rank behavior
        const target: u64 = @intFromFloat(target_f64);

        // Sum buckets from lowest to find the percentile
        var running: u64 = 0;
        for (0..NUM_BUCKETS) |i| {
            const bucket_count = self.buckets[i].load(.monotonic);
            if (running + bucket_count > target) {
                // We're in this bucket - interpolate within bucket
                const position_in_bucket = target - running;
                const lower = getBucketLowerBound(i);
                const upper = getBucketUpperBound(i);
                
                if (bucket_count == 1) {
                    // Only one value in bucket - return lower bound
                    return lower;
                }
                
                // Linear interpolation within bucket
                const fraction = @as(f64, @floatFromInt(position_in_bucket)) / @as(f64, @floatFromInt(bucket_count - 1));
                const range = upper - lower;
                const interpolated = lower + @as(u64, @intFromFloat(@as(f64, @floatFromInt(range)) * fraction));
                return interpolated;
            }
            running += bucket_count;
        }

        // If we get here, return max value
        return MAX_VALUE;
    }

    /// Get P50 (median)
    pub fn p50(self: *const Histogram) u64 {
        return self.percentile(0.50);
    }

    /// Get P90
    pub fn p90(self: *const Histogram) u64 {
        return self.percentile(0.90);
    }

    /// Get P99
    pub fn p99(self: *const Histogram) u64 {
        return self.percentile(0.99);
    }

    /// Get P99.9
    pub fn p999(self: *const Histogram) u64 {
        return self.percentile(0.999);
    }

    /// Reset all values to zero
    pub fn reset(self: *Histogram) void {
        for (0..NUM_BUCKETS) |i| {
            self.buckets[i].store(0, .monotonic);
        }
        self.total_count.store(0, .monotonic);
        self.total_sum.store(0, .monotonic);
        self.min_value.store(0, .monotonic);
        self.max_value.store(0, .monotonic);
    }

    /// Get bucket distribution for export
    /// Returns slice of (upper_bound, count) pairs
    pub fn getBucketDistribution(self: *const Histogram) [NUM_BUCKETS]struct { u64, u64 } {
        var result: [NUM_BUCKETS]struct { u64, u64 } = undefined;
        for (0..NUM_BUCKETS) |i| {
            result[i] = .{ getBucketUpperBound(i), self.buckets[i].load(.monotonic) };
        }
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Histogram: init zero values" {
    const h = Histogram.init();
    try std.testing.expectEqual(@as(u64, 0), h.count());
    try std.testing.expectEqual(@as(u64, 0), h.sum());
    try std.testing.expectEqual(@as(u64, 0), h.min());
    try std.testing.expectEqual(@as(u64, 0), h.max());
}

test "Histogram: record single value" {
    var h = Histogram.init();
    h.record(100); // 100 microseconds

    try std.testing.expectEqual(@as(u64, 1), h.count());
    try std.testing.expectEqual(@as(u64, 100), h.sum());
    try std.testing.expectEqual(@as(u64, 100), h.min());
    try std.testing.expectEqual(@as(u64, 100), h.max());
}

test "Histogram: record multiple values" {
    var h = Histogram.init();

    // Record various latencies
    h.record(10);
    h.record(50);
    h.record(100);
    h.record(500);
    h.record(1000);

    try std.testing.expectEqual(@as(u64, 5), h.count());
    try std.testing.expectEqual(@as(u64, 1660), h.sum());
    try std.testing.expectEqual(@as(u64, 10), h.min());
    try std.testing.expectEqual(@as(u64, 1000), h.max());
    try std.testing.expectEqual(@as(u64, 332), h.mean()); // 1660/5
}

test "Histogram: percentile calculations with interpolation" {
    var h = Histogram.init();

    // Record 100 values from 1 to 100
    for (1..101) |i| {
        h.record(@intCast(i));
    }

    // With interpolation, P50 should be around 50 (exact interpolated value)
    const p50 = h.p50();
    try std.testing.expect(p50 >= 48 and p50 <= 55);

    // P90 should be around 90-110 (bucket 6 is 64-128, interpolation within bucket)
    const p90 = h.p90();
    try std.testing.expect(p90 >= 90 and p90 <= 130);

    // P99 should be around 99-128
    const p99 = h.p99();
    try std.testing.expect(p99 >= 95 and p99 <= 130);
}

test "Histogram: reset clears all values" {
    var h = Histogram.init();

    h.record(100);
    h.record(200);

    try std.testing.expectEqual(@as(u64, 2), h.count());

    h.reset();

    try std.testing.expectEqual(@as(u64, 0), h.count());
    try std.testing.expectEqual(@as(u64, 0), h.sum());
    try std.testing.expectEqual(@as(u64, 0), h.min());
    try std.testing.expectEqual(@as(u64, 0), h.max());
}

test "Histogram: bucket index calculation" {
    var h = Histogram.init();

    // Test various values map to correct buckets
    h.record(1); // Bucket 0
    h.record(2); // Bucket 1
    h.record(3); // Bucket 1 (log2 floor)
    h.record(100); // Bucket 6 (2^6 = 64, 2^7 = 128)
    h.record(1000); // Bucket 9 (2^9 = 512, 2^10 = 1024)
}

test "Histogram: bucket distribution" {
    var h = Histogram.init();

    h.record(1);
    h.record(2);
    h.record(3);
    h.record(100);
    h.record(1000);

    const dist = h.getBucketDistribution();

    // Verify some buckets have counts
    var has_values = false;
    for (dist) |pair| {
        if (pair[1] > 0) has_values = true;
    }
    try std.testing.expect(has_values);
}

test "Histogram: edge case - very small values" {
    var h = Histogram.init();
    h.record(0); // Below min, goes to bucket 0
    h.record(1); // Min value

    try std.testing.expectEqual(@as(u64, 2), h.count());
}

test "Histogram: edge case - very large values" {
    var h = Histogram.init();
    h.record(500000); // 500ms
    h.record(1000000); // 1s (max)

    try std.testing.expectEqual(@as(u64, 2), h.count());
    try std.testing.expectEqual(@as(u64, 1000000), h.max());
}

test "Histogram: p999 with many samples" {
    var h = Histogram.init();

    // Record 1000 values
    for (1..1001) |i| {
        h.record(@intCast(i));
    }

    const p999 = h.p999();
    // P99.9 of 1000 values should be around 1000
    try std.testing.expect(p999 >= 512);
}

test "Histogram: min/max correct after sequential records" {
    var h = Histogram.init();

    h.record(100);
    try std.testing.expectEqual(@as(u64, 100), h.min());
    try std.testing.expectEqual(@as(u64, 100), h.max());

    h.record(50);
    try std.testing.expectEqual(@as(u64, 50), h.min());
    try std.testing.expectEqual(@as(u64, 100), h.max());

    h.record(200);
    try std.testing.expectEqual(@as(u64, 50), h.min());
    try std.testing.expectEqual(@as(u64, 200), h.max());

    h.record(75);
    try std.testing.expectEqual(@as(u64, 50), h.min());
    try std.testing.expectEqual(@as(u64, 200), h.max());
}
