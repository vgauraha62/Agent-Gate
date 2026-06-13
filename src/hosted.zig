//! Hosted API mode — ties together API key auth, usage tracking,
//! and admin endpoints for the managed AgentGate service.
//!
//! This module is the "controller" layer for the hosted API.

const std = @import("std");
const apikey = @import("apikey.zig");
const usage = @import("usage.zig");
const config_mod = @import("config.zig");

// ============================================================================
// Types
// ============================================================================

/// Context shared across the hosted API.
pub const HostedContext = struct {
    /// API key store
    key_store: *apikey.ApiKeyStore,
    /// Usage tracker
    usage_tracker: *usage.UsageTracker,
    /// Hosted API config
    config: *const config_mod.ApiConfig,
    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new hosted context.
    pub fn init(
        allocator: std.mem.Allocator,
        config: *const config_mod.ApiConfig,
        key_store: *apikey.ApiKeyStore,
        usage_tracker: *usage.UsageTracker,
    ) Self {
        return Self{
            .key_store = key_store,
            .usage_tracker = usage_tracker,
            .config = config,
            .allocator = allocator,
        };
    }

    /// Authenticate a request using either API key or admin key.
    /// Returns:
    ///   - .admin if the master admin key was used
    ///   - .key{idx} if a valid API key was used
    ///   - null if authentication failed
    pub const AuthResult = union(enum) {
        admin: void,
        key: usize,
    };

    pub fn authenticate(self: *Self, api_key_header: ?[]const u8) ?AuthResult {
        const key = api_key_header orelse return null;

        // Check master admin key first
        if (self.config.admin_key.len > 0 and std.mem.eql(u8, key, self.config.admin_key)) {
            return AuthResult{ .admin = {} };
        }

        // Check regular API keys
        if (self.key_store.validateKey(key)) |idx| {
            return AuthResult{ .key = idx };
        }

        return null;
    }

    /// Record usage for a request.
    pub fn recordUsage(
        self: *Self,
        key_hash: ?[32]u8,
        path: []const u8,
        method: []const u8,
        allowed: bool,
        status: u16,
        latency_us: u64,
    ) void {
        if (!self.config.enable_usage_tracking) return;

        const hash = key_hash orelse return;

        const path_copy = self.allocator.dupe(u8, path) catch return;
        const method_copy = self.allocator.dupe(u8, method) catch {
            self.allocator.free(path_copy);
            return;
        };

        const record = usage.UsageRecord{
            .key_hash = hash,
            .timestamp_us = std.time.microTimestamp(),
            .path = path_copy,
            .method = method_copy,
            .allowed = allowed,
            .status = status,
            .latency_us = latency_us,
        };

        _ = self.usage_tracker.recordAndCheck(hash, 0, record, null);
    }
};

// ============================================================================
// Admin API Response Builders
// ============================================================================

/// Build a JSON response for listing API keys.
pub fn buildKeysListJson(ctx: *HostedContext, allocator: std.mem.Allocator) ![]const u8 {
    const keys = try ctx.key_store.listKeys(allocator);
    defer allocator.free(keys);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try buf.writer(allocator).writeAll("{\"keys\":[");
    for (keys, 0..) |k, i| {
        if (i > 0) try buf.writer(allocator).writeAll(",");
        try buf.writer(allocator).print(
            \\{{"key_prefix":"{s}","name":"{s}","status":"{s}","created_at":{},"last_used_at":{},"total_requests":{},"rate_limit":{},"expires_at":{},"notes":"{s}"}}
        , .{
            std.mem.trimRight(u8, k.key_prefix, " "),
            k.name,
            @tagName(k.status),
            k.created_at,
            k.last_used_at,
            k.total_requests,
            k.rate_limit,
            k.expires_at,
            k.notes,
        });
    }
    try buf.writer(allocator).writeAll("]}");

    return buf.toOwnedSlice(allocator);
}

/// Build JSON response for usage stats.
pub fn buildUsageJson(ctx: *HostedContext, allocator: std.mem.Allocator) ![]const u8 {
    const global = ctx.usage_tracker.getGlobalStats();
    return try std.fmt.allocPrint(allocator,
        \\{{"total_requests":{},"allowed_requests":{},"denied_requests":{},"avg_latency_us":{d:.1}}}
    , .{
        global.total_requests,
        global.allowed_requests,
        global.denied_requests,
        global.avg_latency_us,
    });
}

/// Build JSON response for server stats.
pub fn buildServerStatsJson(ctx: *HostedContext, allocator: std.mem.Allocator) ![]const u8 {
    const key_stats = ctx.key_store.getStats();
    const usage_global = ctx.usage_tracker.getGlobalStats();

    return try std.fmt.allocPrint(allocator,
        \\{{"total_keys":{},"active_keys":{},"total_api_requests":{},"total_usage_requests":{},"allowed_requests":{},"denied_requests":{},"avg_latency_us":{d:.1}}}
    , .{
        key_stats.total_keys,
        key_stats.active_keys,
        key_stats.total_requests,
        usage_global.total_requests,
        usage_global.allowed_requests,
        usage_global.denied_requests,
        usage_global.avg_latency_us,
    });
}

// ============================================================================
// JSON Error Response Helpers
// ============================================================================

pub fn jsonError(allocator: std.mem.Allocator, status: u16, message: []const u8) ![]const u8 {
    _ = status;
    return try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
}

pub fn jsonSuccess(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{{\"success\":true,\"message\":\"{s}\"}}", .{message});
}

// ============================================================================
// Tests
// ============================================================================

test "HostedContext: authenticate with admin key" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try apikey.ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();
    var tracker = usage.UsageTracker.init(allocator, 100);
    defer tracker.deinit();

    var api_cfg = config_mod.ApiConfig{
        .admin_key = "admin-master-key-123",
        .enabled = true,
    };

    var ctx = HostedContext.init(allocator, &api_cfg, &store, &tracker);

    // Authenticate with admin key
    const result = ctx.authenticate("admin-master-key-123");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .admin);
}

test "HostedContext: authenticate with regular API key" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try apikey.ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();
    var tracker = usage.UsageTracker.init(allocator, 100);
    defer tracker.deinit();

    var api_cfg = config_mod.ApiConfig{
        .admin_key = "admin-key",
        .enabled = true,
    };

    var ctx = HostedContext.init(allocator, &api_cfg, &store, &tracker);

    // Create a regular API key
    const key = try store.createKey("test-user", 100, 0, "");
    defer allocator.free(key);

    // Authenticate with that key
    const result = ctx.authenticate(key);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .key);
}

test "HostedContext: reject invalid key" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try apikey.ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();
    var tracker = usage.UsageTracker.init(allocator, 100);
    defer tracker.deinit();

    var api_cfg = config_mod.ApiConfig{
        .admin_key = "admin-key",
        .enabled = true,
    };

    var ctx = HostedContext.init(allocator, &api_cfg, &store, &tracker);
    const result = ctx.authenticate("invalid-key-12345");
    try std.testing.expect(result == null);
}
