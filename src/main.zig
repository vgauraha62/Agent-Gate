const std = @import("std");
const Config = @import("config.zig");
const http = @import("server/http.zig");
const http_async = @import("server/http_async.zig");
const audit = @import("audit/logger.zig");
const types = @import("policy/types.zig");
const parser = @import("policy/parser.zig");
const Memory = @import("memory.zig");
const denial_tracker = @import("denial_tracker.zig");
const apikey = @import("apikey.zig");
const usage = @import("usage.zig");
const hosted = @import("hosted.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
        // Auto-discover config.json from current working directory
        if (std.fs.cwd().access("config.json", .{})) {
            config = try Config.Config.load("config.json", allocator);
            std.debug.print("[Startup] Loading configuration from config.json (auto-discovered)\n", .{});
        } else |_| {
            // Fall back to defaults + env overrides
            config = Config.Config.default();
            Config.applyOverrides(&config, allocator);
        }
    }
    defer config.deinit(allocator);

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

    // ========================================================================
    // Hosted API Mode Initialization
    // ========================================================================
    var key_store: ?apikey.ApiKeyStore = null;
    var usage_tracker: ?usage.UsageTracker = null;
    var hosted_ctx: ?hosted.HostedContext = null;

    if (config.api.enabled) {
        std.debug.print("[Startup] Hosted API mode enabled\n", .{});

        // Initialize API key store
        const storage_path = if (config.api.storage_path.len > 0)
            config.api.storage_path
        else
            "/etc/agent-gate/data";

        // Ensure storage directory exists
        std.fs.cwd().makePath(storage_path) catch {};
        std.debug.print("[Startup] API key storage: {s}\n", .{storage_path});

        key_store = apikey.ApiKeyStore.init(allocator, storage_path) catch |err| {
            std.debug.print("[Startup] Failed to init API key store: {}\n", .{err});
            return err;
        };

        // Initialize usage tracker
        usage_tracker = usage.UsageTracker.init(allocator, config.api.max_recent_requests);
        usage_tracker.?.rate_limiting_enabled = config.api.enable_rate_limiting;
        usage_tracker.?.enabled = config.api.enable_usage_tracking;

        // Initialize hosted context
        if (key_store) |*ks| {
            if (usage_tracker) |*ut| {
                hosted_ctx = hosted.HostedContext.init(allocator, &config.api, ks, ut);

                // Generate admin key if not configured
                if (config.api.admin_key.len == 0) {
                    std.debug.print("[Startup] No admin key configured, generating one...\n", .{});
                    // Note: admin key is printed once to stdout on startup
                    // Users should save it and set it explicitly in config for persistence
                    const admin_key = try std.fmt.allocPrint(allocator, "ag_admin_{s}", .{
                        @as([]const u8, try generateRandomString(allocator, 24)),
                    });
                    // Can't modify config.api.admin_key since it's a const pointer, so we store
                    // it separately. For simplicity, we'll update the ApiConfig struct directly.
                    // Since config is var, we can modify its api field
                    config.api.admin_key = admin_key;
                    std.debug.print("\n", .{});
                    std.debug.print("╔══════════════════════════════════════════════════╗\n", .{});
                    std.debug.print("║       ADMIN API KEY (save this securely!)       ║\n", .{});
                    std.debug.print("╠══════════════════════════════════════════════════╣\n", .{});
                    std.debug.print("║  {s}\n", .{admin_key});
                    std.debug.print("╚══════════════════════════════════════════════════╝\n", .{});
                    std.debug.print("\n", .{});
                    std.debug.print("[Startup] Set AGENTGATE_API_ADMIN_KEY env var to reuse this key across restarts\n", .{});
                }

                std.debug.print("[Startup] Hosted API ready at {s}\n", .{config.api.base_url});
                std.debug.print("[Startup] Admin endpoints: {s}/v1/admin/keys\n", .{config.api.base_url});
                std.debug.print("[Startup] Default rate limit: {} req/s\n", .{config.api.default_rate_limit});
            }
        }
    }

    // Load policies from JSON file
    const policy_file_path = config.policy.policy_file;
    std.debug.print("[Startup] Loading policies from: {s}\n", .{policy_file_path});

    var policy_arena = try Memory.SecurityArena.init(allocator, 65536);
    defer policy_arena.deinit();

    const policy_json = std.fs.cwd().readFileAlloc(allocator, policy_file_path, 1024 * 1024) catch |err| {
        std.debug.print("[Startup] Failed to read policy file '{s}': {}\n", .{ policy_file_path, err });
        return err;
    };
    defer allocator.free(policy_json);

    const policy_file = try parser.parse(policy_json, &policy_arena);
    const policy_set = types.PolicySet{ .policies = policy_file.policies };
    std.debug.print("[Startup] Loaded {} policies from {s}\n", .{ policy_file.policies.len, policy_file_path });

    if (use_async_io) {
        std.debug.print("[Startup] Mode: async (epoll) - NO thread pool (fully async I/O)\n", .{});

        // Initialize audit logger with config
        var audit_logger = try audit.AuditLogger.init(&config.audit, allocator);
        defer audit_logger.deinit();

        // Create async server with config
        var server = http_async.Server.init(
            allocator,
            &config,
            &audit_logger,
            policy_set.policies,
        );
        defer server.deinit();

        // Pass hosted context if available
        if (hosted_ctx) |*hctx| {
            server.setHostedContext(hctx);
        }

        std.debug.print("[Startup] Starting async HTTP server on port {d}...\n", .{config.server.port});
        try server.run();
    } else {
        std.debug.print("[Startup] Mode: {s}\n", .{
            if (use_thread_pool) "async (epoll) with Thread.Pool" else "async (epoll) - minimal"
        });
        std.debug.print("[Startup] Starting HTTP server on port {d}...\n", .{config.server.port});

        // Initialize audit logger with config
        var audit_logger = try audit.AuditLogger.init(&config.audit, allocator);
        defer audit_logger.deinit();

        // Create server with config object
        var server = http.Server.init(
            allocator,
            &config,
            &audit_logger,
            policy_set,
        );
        defer server.deinit();

        // Pass hosted context if available
        if (hosted_ctx) |*hctx| {
            server.setHostedContext(hctx);
        }

        try server.run();
    }
}

/// Generate a cryptographically random alphanumeric string of the given length.
fn generateRandomString(allocator: std.mem.Allocator, len: usize) ![]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    var buf = try allocator.alloc(u8, len);
    const random_bytes = try allocator.alloc(u8, len);
    defer allocator.free(random_bytes);

    std.crypto.random.bytes(random_bytes);
    for (buf, 0..) |_, i| {
        buf[i] = chars[@as(usize, @intCast(random_bytes[i] % chars.len))];
    }
    return buf;
}