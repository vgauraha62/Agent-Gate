const std = @import("std");
const Config = @import("config.zig");
const http = @import("server/http.zig");
const http_async = @import("server/http_async.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");
const denial_tracker = @import("denial_tracker.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("AgentGate v1.0.0\n", .{});

    // Parse command line arguments first
    var mode = http.ServerMode.async_epoll;
    var use_async_io = false;
    var use_thread_pool = true;
    var config_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
        }
    }

    // Load configuration - priority: Env > File > Defaults
    var config: Config.Config = undefined;
    if (config_path) |path| {
        std.debug.print("[Startup] Loading configuration from {s}\n", .{path});
        config = try Config.Config.load(path, allocator);
    } else {
        // Use defaults + env overrides
        config = Config.Config.default();
        Config.applyOverrides(&config, allocator);
    }
    defer config.deinit();

    // Validate configuration
    config.validate() catch |err| {
        std.debug.print("[Startup] Config validation failed: {}\n", .{err});
        return err;
    };

    // Log configuration summary
    std.debug.print("[Startup] Configuration:\n", .{});
    std.debug.print("  Server: {s}:{d}\n", .{ config.server.host, config.server.port });
    std.debug.print("  Workers: {d}\n", .{config.server.workers});
    std.debug.print("  TLS: {s}\n", .{ @tagName(config.tls.mode) });
    std.debug.print("  Request timeout: {d}ms\n", .{config.request.request_timeout_ms});
    std.debug.print("  Auth timeout: {d}ms\n", .{config.auth.auth_timeout_ms});

    // Initialize denial tracker for request visibility
    try denial_tracker.initGlobal(allocator);
    defer denial_tracker.deinitGlobal();

    if (use_async_io) {
        std.debug.print("[Startup] Mode: async (epoll) - NO thread pool (fully async I/O)\n", .{});

        // Initialize audit logger with config
        var audit_logger = audit.AuditLogger.init(&config.audit);

        // Define default policies
        const default_policies = &[_]types.Policy{};

        // Create async server with config
        var server = http_async.Server.init(
            allocator,
            &config,
            &audit_logger,
            default_policies,
        );
        defer server.deinit();

        std.debug.print("[Startup] Starting async HTTP server on port {d}...\n", .{config.server.port});
        try server.run();
    } else {
        std.debug.print("[Startup] Mode: {s}\n", .{
            if (use_thread_pool) "async (epoll) with Thread.Pool" else "async (epoll) - minimal"
        });
        std.debug.print("[Startup] Starting HTTP server on port {d}...\n", .{config.server.port});

        // Initialize audit logger with config
        var audit_logger = audit.AuditLogger.init(&config.audit);

        // Define default policies (empty for benchmark)
        const default_policies = &[_]types.Policy{};

        // Create server with config object
        var server = http.Server.init(
            allocator,
            &config,
            &audit_logger,
            default_policies,
        );
        defer server.deinit();

        try server.run();
    }
}