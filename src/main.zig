const std = @import("std");
const Config = @import("config.zig");
const http = @import("server/http.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");
const auth_middleware = @import("server/auth_middleware.zig");

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
    std.debug.print("[Startup] Auth timeout: {d}ms, Policy timeout: {d}ms\n", .{
        config.auth.auth_timeout_ms,
        config.policy.policy_timeout_ms,
    });

    // Initialize audit logger
    var audit_logger = audit.AuditLogger.init(allocator);
    defer audit_logger.deinit();

    // Initialize auth middleware with configured secret
    var middleware = try auth_middleware.AuthMiddleware.init(allocator, config.auth.jwt_secret);
    defer middleware.deinit();

    // Define default policies
    const default_policies = [_]types.Policy{
        types.Policy{
            .id = "allow-all",
            .effect = .allow,
            .conditions = &[_]types.Condition{types.Condition{ .path = "*" }},
        },
    };

    // Create server with auth middleware and config-driven timeouts
    var server = http.Server.initWithTimeout(
        allocator,
        config.server.port,
        &audit_logger,
        &default_policies,
        config.auth.jwt_secret,
        &middleware,
        mode,
        config.request.request_timeout_ms,
    );
    defer server.deinit();

    std.debug.print("[Startup] Starting HTTP server on port {d}...\n", .{config.server.port});

    server.run() catch |err| {
        std.debug.print("[Startup] Server error: {}\n", .{err});
        return err;
    };
}