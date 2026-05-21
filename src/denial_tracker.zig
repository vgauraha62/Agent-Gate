// src/denial_tracker.zig - Thread-safe ring buffer for denied requests
// Fixed-size records, no per-record allocations
// Stores last 1000 denials with full context

const std = @import("std");

/// Compile-time flag to enable/disable denial tracking
/// Set to false to disable denial tracking (improves performance)
pub const DENIAL_TRACKING_ENABLED = true;

// Configuration
const MAX_PATH_LEN = 256;
const MAX_METHOD_LEN = 8;
const MAX_POLICY_ID_LEN = 32;
const DEFAULT_CAPACITY = 1000;

/// Reason why a request was denied
pub const DenialReason = enum(u8) {
    explicit_deny = 0,
    no_matching_policy = 1,
};

/// A single denial record with bounded-size fields (no allocation)
pub const DenialRecord = struct {
    timestamp_us: i64,
    agent_id: [32]u8,

    // Bounded-size fields (no allocation per record)
    path: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    path_len: usize = 0,

    method: [MAX_METHOD_LEN]u8 = [_]u8{0} ** MAX_METHOD_LEN,
    method_len: usize = 0,

    policy_id: [MAX_POLICY_ID_LEN]u8 = [_]u8{0} ** MAX_POLICY_ID_LEN,
    policy_id_len: usize = 0,

    reason: DenialReason,

    /// Initialize from fields (copies data into bounded arrays)
    pub fn init(
        timestamp_us: i64,
        agent_id: [32]u8,
        path: []const u8,
        method: []const u8,
        policy_id: []const u8,
        reason: DenialReason,
    ) DenialRecord {
        var record = DenialRecord{
            .timestamp_us = timestamp_us,
            .agent_id = agent_id,
            .reason = reason,
        };

        // Copy bounded fields (truncate if too long)
        @memcpy(record.path[0..@min(path.len, MAX_PATH_LEN)], path[0..@min(path.len, MAX_PATH_LEN)]);
        record.path_len = @min(path.len, MAX_PATH_LEN);

        @memcpy(record.method[0..@min(method.len, MAX_METHOD_LEN)], method[0..@min(method.len, MAX_METHOD_LEN)]);
        record.method_len = @min(method.len, MAX_METHOD_LEN);

        @memcpy(record.policy_id[0..@min(policy_id.len, MAX_POLICY_ID_LEN)], policy_id[0..@min(policy_id.len, MAX_POLICY_ID_LEN)]);
        record.policy_id_len = @min(policy_id.len, MAX_POLICY_ID_LEN);

        return record;
    }

    /// Get path as slice
    pub fn getPath(self: *const DenialRecord) []const u8 {
        const len = if (self.path_len > MAX_PATH_LEN) MAX_PATH_LEN else self.path_len;
        return self.path[0..len];
    }

    /// Get method as slice
    pub fn getMethod(self: *const DenialRecord) []const u8 {
        const len = if (self.method_len > MAX_METHOD_LEN) MAX_METHOD_LEN else self.method_len;
        return self.method[0..len];
    }

    /// Get policy_id as slice
    pub fn getPolicyId(self: *const DenialRecord) []const u8 {
        const len = if (self.policy_id_len > MAX_POLICY_ID_LEN) MAX_POLICY_ID_LEN else self.policy_id_len;
        return self.policy_id[0..len];
    }
};

/// Ring buffer for storing denials
pub const DenialTracker = struct {
    buffer: []DenialRecord,
    write_index: usize = 0,
    total_denials: usize = 0,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !DenialTracker {
        const buffer = try allocator.alloc(DenialRecord, DEFAULT_CAPACITY);

        // Pre-initialize records to zero
        for (buffer) |*r| {
            r.* = DenialRecord{
                .timestamp_us = 0,
                .agent_id = [_]u8{0} ** 32,
                .reason = .explicit_deny,
            };
        }

        return DenialTracker{
            .buffer = buffer,
            .write_index = 0,
            .total_denials = 0,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DenialTracker) void {
        self.allocator.free(self.buffer);
    }

    /// Record a denial (thread-safe)
    /// Returns error when DENIAL_TRACKING_ENABLED is false
    pub fn record(self: *DenialTracker, denial: DenialRecord) !void {
        if (!DENIAL_TRACKING_ENABLED) {
            return error.DenialTrackingDisabled;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = self.write_index % DEFAULT_CAPACITY;
        self.buffer[idx] = denial;
        self.write_index += 1;
        self.total_denials += 1;
    }

    /// Get recent denials - returns OWNED copies (caller must free)
    /// Caller must free the returned slice
    /// Returns error when DENIAL_TRACKING_ENABLED is false
    pub fn getRecent(
        self: *DenialTracker,
        limit: usize,
        filter_agent: ?[32]u8,
        since_us: ?i64,
    ) ![]DenialRecord {
        if (!DENIAL_TRACKING_ENABLED) {
            return error.DenialTrackingDisabled;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const total = self.total_denials;

        std.debug.print("[DEBUG getRecent] total_denials={}, limit={}, filter_agent={}, since_us={}\n", .{
            total, limit, filter_agent != null, since_us != null});

        if (total == 0) {
            const empty: []DenialRecord = &.{};
            return empty;
        }

        var results = try std.ArrayList(DenialRecord).initCapacity(self.allocator, limit);
        errdefer results.deinit(self.allocator);

        // Walk backward from most recent entry
        var i: usize = 0;
        while (i < total and results.items.len < limit) : (i += 1) {
            // Most recent entry is at (write_index - 1), going backwards
            const idx = (self.write_index + DEFAULT_CAPACITY - 1 - i) % DEFAULT_CAPACITY;
            const entry = &self.buffer[idx];

            // Skip empty records (timestamp 0 means empty/uninitialized)
            if (entry.timestamp_us == 0) continue;

            // Apply filters
            if (filter_agent) |agent| {
                if (!std.mem.eql(u8, &entry.agent_id, &agent)) {
                    continue;
                }
            }

            if (since_us) |since| {
                if (entry.timestamp_us < since) {
                    continue;
                }
            }

            // Clone the record (own the copy)
            try results.append(self.allocator, entry.*);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Get total denials (thread-safe)
    pub fn getTotalDenials(self: *DenialTracker) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_denials;
    }

    /// Get buffer capacity
    pub fn getCapacity(self: *DenialTracker) usize {
        _ = self;
        return DEFAULT_CAPACITY;
    }
};

// ============ Global Singleton ============

var global_tracker: ?*DenialTracker = null;
var global_allocator: ?std.mem.Allocator = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_allocator = allocator;
    const tracker = try allocator.create(DenialTracker);
    tracker.* = try DenialTracker.init(allocator);
    global_tracker = tracker;
}

pub fn deinitGlobal() void {
    if (global_tracker) |t| {
        t.deinit();
        if (global_allocator) |alloc| {
            alloc.destroy(t);
        }
        global_tracker = null;
    }
}

pub fn getTracker() *DenialTracker {
    return global_tracker orelse @panic("DenialTracker not initialized");
}

// ============ Tests ============

test "DenialRecord init and get methods" {
    const agent_id: [32]u8 = .{1} ** 32;

    const record = DenialRecord.init(
        1234567890123456,
        agent_id,
        "/admin/test",
        "GET",
        "deny-admin",
        .explicit_deny,
    );

    try std.testing.expectEqual(@as(i64, 1234567890123456), record.timestamp_us);
    try std.testing.expectEqualStrings("/admin/test", record.getPath());
    try std.testing.expectEqualStrings("GET", record.getMethod());
    try std.testing.expectEqualStrings("deny-admin", record.getPolicyId());
    try std.testing.expectEqual(DenialReason.explicit_deny, record.reason);
}

test "DenialRecord truncation" {
    const agent_id: [32]u8 = .{1} ** 32;

    // Path longer than MAX_PATH_LEN should be truncated
    const long_path = "a" ** 300;
    const record = DenialRecord.init(
        1234567890123456,
        agent_id,
        long_path,
        "GET",
        "policy",
        .explicit_deny,
    );

    try std.testing.expectEqual(MAX_PATH_LEN, record.path_len);
}