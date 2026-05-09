const std = @import("std");

pub const MAX_ENTRIES: usize = 1000;

pub const LogEntry = struct {
    timestamp: u64,
    agent_id: []const u8,
    path: []const u8,
    method: []const u8,
    decision: []const u8,
    policy_id: []const u8,
};

pub const AuditLogger = struct {
    entries: [MAX_ENTRIES]LogEntry,
    index: usize = 0,
    total_count: usize = 0,
    allocator: std.mem.Allocator,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) AuditLogger {
        return AuditLogger{
            .entries = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AuditLogger) void {
        const count = self.entryCount();
        for (0..count) |i| {
            const actual_index = (self.index - count + i) % MAX_ENTRIES;
            const entry = &self.entries[actual_index];
            self.allocator.free(entry.agent_id);
            self.allocator.free(entry.path);
            self.allocator.free(entry.method);
            self.allocator.free(entry.decision);
            self.allocator.free(entry.policy_id);
        }
    }

    pub fn log(
        self: *AuditLogger,
        agent_id: []const u8,
        path: []const u8,
        method: []const u8,
        decision: []const u8,
        policy_id: []const u8,
    ) !void {
        self.sequence += 1;

        const entry = LogEntry{
            .timestamp = self.sequence,
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .path = try self.allocator.dupe(u8, path),
            .method = try self.allocator.dupe(u8, method),
            .decision = try self.allocator.dupe(u8, decision),
            .policy_id = try self.allocator.dupe(u8, policy_id),
        };

        self.entries[self.index % MAX_ENTRIES] = entry;
        self.index += 1;
        self.total_count += 1;
    }

    pub fn entryCount(self: *AuditLogger) usize {
        return @min(MAX_ENTRIES, self.total_count);
    }

    pub fn getEntry(self: *AuditLogger, index: usize) ?*const LogEntry {
        if (index >= self.entryCount()) return null;
        const actual_index = (self.index - self.entryCount() + index) % MAX_ENTRIES;
        return &self.entries[actual_index];
    }

    pub fn exportJSON(self: *AuditLogger) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.writer().writeAll("[");
        var first = true;

        const count = self.entryCount();
        for (0..count) |i| {
            if (!first) try buffer.writer().writeAll(",");
            first = false;

            const entry = self.getEntry(i).?;
            try std.json.stringify(
                .{
                    .timestamp = entry.timestamp,
                    .agent_id = entry.agent_id,
                    .path = entry.path,
                    .method = entry.method,
                    .decision = entry.decision,
                    .policy_id = entry.policy_id,
                },
                self.allocator,
                &buffer.writer(),
                .{},
            );
        }

        try buffer.writer().writeAll("]");
        return buffer.toOwnedSlice();
    }
};

test "AuditLogger basic" {
    var logger = AuditLogger.init(std.heap.page_allocator);
    defer logger.deinit();

    try logger.log("agent-1", "/api/test", "GET", "allow", "test-policy");
    try std.testing.expectEqual(@as(usize, 1), logger.entryCount());
}

test "AuditLogger ring buffer" {
    var logger = AuditLogger.init(std.heap.page_allocator);
    defer logger.deinit();

    for (0..MAX_ENTRIES + 10) |i| {
        const path = std.fmt.allocPrint(std.heap.page_allocator, "/api/{d}", .{i}) catch @panic("OOM");
        defer std.heap.page_allocator.free(path);
        try logger.log("agent-1", path, "GET", "allow", "test");
    }

    try std.testing.expectEqual(MAX_ENTRIES, logger.entryCount());
}
