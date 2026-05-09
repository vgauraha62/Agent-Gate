const std = @import("std");
const Config = @import("config.zig").Config;
const http = @import("server/http.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Agent-Gate HTTP Server v1.0.0\n", .{});

    const config = Config.init();
    std.debug.print("Config: sensor_count={}, event_interval_ms={}, max_log_entries={}\n", .{
        config.sensor_count,
        config.event_interval_ms,
        config.max_log_entries,
    });

    const port: u16 = 8080;
    const secret_key = "super-secret-key-for-testing";

    var mode = http.ServerMode.async_epoll;

    // Parse command line arguments (Zig 0.13+ compatible)
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();
    // Skip first arg (program name)
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sync")) {
            mode = http.ServerMode.sync_posix;
        } else if (std.mem.eql(u8, arg, "--async") or std.mem.eql(u8, arg, "--async-epoll")) {
            mode = http.ServerMode.async_epoll;
        }
    }

    std.debug.print("[Startup] Mode: {s}\n", .{
        if (mode == .async_epoll) "async (epoll)" else "sync (POSIX sockets)",
    });

    var audit_logger = audit.AuditLogger.init(allocator);
    defer audit_logger.deinit();

    const default_policies = [_]types.Policy{
        types.Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };

    var server = http.Server.init(
        allocator,
        port,
        &audit_logger,
        &default_policies,
        secret_key,
        mode,
    );
    defer server.deinit();

    std.debug.print("[Startup] Starting HTTP server...\n", .{});

    server.run() catch |err| {
        std.debug.print("[Startup] Server error: {}\n", .{err});
        return err;
    };
}