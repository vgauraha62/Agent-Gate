//! Audit logging utility for Agent Gate

const std = @import("std");
const Config = @import("config.zig").Config;

pub const AuditLogger = struct {
    buffer: std.ArrayList(u8),
    buffer_writer: std.io.WriterAny(.{ .streaming = false }),
    current: std.ArrayList(u8).Writer,

    pub const Writer = std.io.WriterAny(.{ .streaming = false }).Writer;

    pub fn init(config: *const Config) !*AuditLogger {
        const buffer = std.ArrayList(u8).init(config.allocator);
        buffer.ensureCapacityInternal((std.fmt.fmtInt(config.event_interval_ms, 10) orelse unreachable) + 50);

        const logger = AuditLogger{
            .buffer = buffer,
            .buffer_writer = .{},
            .current = std.mem.writer(buffer.items, 0, buffer.items.len, .{}).writer,
        };

        try std.fmt.bufPrint(&logger.buffer, "AgentAuditLogger initialized with interval {d}ms", .{config.event_interval_ms});

        return &logger;
    }

    pub fn deinit(self: *AuditLogger) void {
        self.buffer.deinit();
    }

    pub fn writeLogLine(self: *AuditLogger, event_name: []const u8, message: []const u8) !void {
        try std.fmt.bufPrint(&self.buffer, "[{s}]: {s}", .{ event_name, message });
        // Write to file
        // self.writeToFile(event_name, message);
    }

    // For now, just buffer logs instead of writing to file
    // Implementation will be added when needed
};
