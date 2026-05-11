const std = @import("std");
const Config = @import("config.zig");
const http = @import("server/http.zig");
const http_async = @import("server/http_async.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("AgentGate v1.0.0\n", .{});

    // Load configuration
    var config = Config.Config.default();
    defer config.deinit();

    // Override with environment or defaults
    if (std.process.getEnvVarOwned(allocator, "JWT_SECRET")) |jwt_secret| {
        defer allocator.free(jwt_secret);
        config.auth.jwt_secret = jwt_secret;
    } else |_| {
        // Use default for testing
        config.auth.jwt_secret = "agent-gate-default-secret-32bytes!";
    }

    // Validate configuration
    config.validate() catch |err| {
        std.debug.print("[Startup] Config validation failed: {}\n", .{err});
        return err;
    };

    var mode = http.ServerMode.async_epoll;
    var use_async_io = false;
    var use_thread_pool = true;

    // Parse command line arguments
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sync")) {
            mode = http.ServerMode.sync_posix;
        } else if (std.mem.eql(u8, arg, "--async") or std.mem.eql(u8, arg, "--async-epoll")) {
            mode = http.ServerMode.async_epoll;
        } else if (std.mem.eql(u8, arg, "--async-io")) {
            use_async_io = true;
            use_thread_pool = false;
        } else if (std.mem.eql(u8, arg, "--thread-pool")) {
            use_async_io = false;
            use_thread_pool = true;
        }
    }

    if (use_async_io) {
        std.debug.print("[Startup] Mode: async (epoll) - NO thread pool (fully async I/O)\n", .{});
        
        // Initialize audit logger
        var audit_logger = audit.AuditLogger.init();
        
        // Define default policies
        const default_policies = &[_]types.Policy{};
        
        // Create async server
        var server = http_async.Server.init(
            allocator,
            config.server.port,
            &audit_logger,
            default_policies,
            config.auth.jwt_secret,
            .async_epoll,
        );
        defer server.deinit();
        
        std.debug.print("[Startup] Starting async HTTP server on port {d}...\n", .{config.server.port});
        try server.run();
    } else {
        std.debug.print("[Startup] Mode: {s}\n", .{
            if (use_thread_pool) "async (epoll) with Thread.Pool" else "async (epoll) - minimal"
        });
        std.debug.print("[Startup] Starting HTTP server on port {d}...\n", .{config.server.port});

        // Initialize audit logger
        var audit_logger = audit.AuditLogger.init();

        // Define default policies (empty for benchmark)
        const default_policies = &[_]types.Policy{};

        // Create server with simplified API (no auth middleware)
        var server = http.Server.init(
            allocator,
            config.server.port,
            &audit_logger,
            default_policies,
            config.auth.jwt_secret,
            mode,
        );
        defer server.deinit();

        try server.run();
    }
}