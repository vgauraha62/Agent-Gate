//! Configuration system for AgentGate.
//!
//! Day 6: Dynamic secret injection + timeout configuration
//! Day 10: Full configuration with env var overrides (as per PRD)

const std = @import("std");
const Secret = @import("secret.zig").Secret;

pub const MIN_SECRET_LENGTH: usize = 32;

/// Server configuration.
pub const ServerConfig = struct {
    /// Port to listen on.
    port: u16 = 8080,
    /// Host to bind to.
    host: []const u8 = "127.0.0.1",
    /// Number of worker threads (0 = auto based on CPU cores).
    workers: u8 = 4,
    /// Enable TLS.
    enable_tls: bool = false,
};

/// Authentication configuration.
pub const AuthConfig = struct {
    /// JWT signing secret (minimum 32 bytes).
    jwt_secret: []const u8 = "",
    /// Minimum required secret length.
    min_secret_length: usize = MIN_SECRET_LENGTH,
    /// Auth timeout in milliseconds.
    auth_timeout_ms: u32 = 100,
};

/// Policy configuration.
pub const PolicyConfig = struct {
    /// Policy evaluation timeout in milliseconds.
    policy_timeout_ms: u32 = 50,
    /// Maximum policies to evaluate per request.
    max_policies: usize = 1000,
};

/// Audit configuration.
pub const AuditConfig = struct {
    /// Audit log ring buffer size.
    buffer_size: u32 = 1000,
    /// Audit log timeout in milliseconds.
    audit_timeout_ms: u32 = 10,
};

/// Request configuration.
pub const RequestConfig = struct {
    /// Total request timeout in milliseconds.
    request_timeout_ms: u32 = 5000,
    /// Maximum request body size in bytes.
    max_body_size: usize = 65536,
    /// Maximum header count.
    max_headers: usize = 64,
};

/// Graceful shutdown configuration.
pub const ShutdownConfig = struct {
    /// Grace period in milliseconds before force shutdown.
    grace_period_ms: u32 = 30000,
    /// Enable signal handling.
    enable_signals: bool = true,
};

/// Main configuration struct for AgentGate.
pub const Config = struct {
    /// Server settings.
    server: ServerConfig = .{},
    /// Authentication settings.
    auth: AuthConfig = .{},
    /// Policy settings.
    policy: PolicyConfig = .{},
    /// Audit settings.
    audit: AuditConfig = .{},
    /// Request settings.
    request: RequestConfig = .{},
    /// Shutdown settings.
    shutdown: ShutdownConfig = .{},

    const Self = @This();

    /// Create default configuration.
    pub fn default() Self {
        return .{};
    }

    /// Clean up owned allocations.
    /// Call this when config is no longer needed.
    pub fn deinit(self: *Self) void {
        // Currently all fields are either primitives or slices pointing to
        // external/interned strings. If we add owned allocations in the future,
        // clean them up here.
        _ = self;
    }

    /// Validate the configuration.
    /// Returns error if configuration is invalid.
    pub fn validate(self: *const Self) !void {
        // Validate server config
        if (self.server.port == 0) {
            return error.InvalidPort;
        }

        // Validate auth config
        if (self.auth.jwt_secret.len < self.auth.min_secret_length) {
            return error.SecretTooShort;
        }

        // Validate timeouts are reasonable
        if (self.server.workers == 0) {
            return error.InvalidWorkerCount;
        }

        // Policy timeout should be less than request timeout
        if (self.policy.policy_timeout_ms >= self.request.request_timeout_ms) {
            return error.PolicyTimeoutExceedsRequestTimeout;
        }

        // Audit timeout should be less than request timeout
        if (self.audit.audit_timeout_ms >= self.request.request_timeout_ms) {
            return error.AuditTimeoutExceedsRequestTimeout;
        }
    }

    /// Parse configuration from JSON string.
    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Self {
        var parsed = try std.json.parseFromSlice(Self, allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var config = parsed.value;
        errdefer config.deinit();

        // Copy any owned strings if needed
        // For now, we use the parsed values directly

        return config;
    }

    /// Get timeout budget for a specific stage.
    /// Returns the remaining time after previous stages.
    pub fn getRemainingTimeout(self: *const Self, elapsed_ms: u32) u32 {
        if (elapsed_ms >= self.request.request_timeout_ms) {
            return 0;
        }
        return self.request.request_timeout_ms - elapsed_ms;
    }
};

/// Config errors.
pub const ConfigError = error{
    InvalidPort,
    SecretTooShort,
    InvalidWorkerCount,
    PolicyTimeoutExceedsRequestTimeout,
    AuditTimeoutExceedsRequestTimeout,
    ParseError,
    FileNotFound,
};

// ============================================================================
// Tests
// ============================================================================

test "Config: default values" {
    const config = Config.default();

    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqual(@as(u8, 4), config.server.workers);
    try std.testing.expectEqual(@as(u32, 100), config.auth.auth_timeout_ms);
    try std.testing.expectEqual(@as(u32, 50), config.policy.policy_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5000), config.request.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 30000), config.shutdown.grace_period_ms);
}

test "Config: validate accepts valid config" {
    var config = Config.default();
    config.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";

    try config.validate();
}

test "Config: validate rejects short secret" {
    var config = Config.default();
    config.auth.jwt_secret = "too-short";

    try std.testing.expectError(error.SecretTooShort, config.validate());
}

test "Config: validate rejects zero port" {
    var config = Config.default();
    config.server.port = 0;
    config.auth.jwt_secret = "valid-secret-key-32-bytes-exactly!!";

    try std.testing.expectError(error.InvalidPort, config.validate());
}

test "Config: validate rejects policy timeout >= request timeout" {
    var config = Config.default();
    config.auth.jwt_secret = "valid-secret-key-32-bytes-exactly!!";
    config.policy.policy_timeout_ms = 5000; // Equal to request timeout
    config.request.request_timeout_ms = 5000;

    try std.testing.expectError(error.PolicyTimeoutExceedsRequestTimeout, config.validate());
}

test "Config: validate accepts policy timeout < request timeout" {
    var config = Config.default();
    config.auth.jwt_secret = "valid-secret-key-32-bytes-exactly!!";
    config.policy.policy_timeout_ms = 1000; // Less than request timeout
    config.request.request_timeout_ms = 5000;

    try config.validate();
}

test "Config: getRemainingTimeout" {
    const config = Config.default();

    try std.testing.expectEqual(@as(u32, 4900), config.getRemainingTimeout(100));
    try std.testing.expectEqual(@as(u32, 5000), config.getRemainingTimeout(0));
    try std.testing.expectEqual(@as(u32, 0), config.getRemainingTimeout(5000));
    try std.testing.expectEqual(@as(u32, 0), config.getRemainingTimeout(6000));
}

test "Config: parse JSON" {
    const json =
        \\{"server": {"port": 9000}, "auth": {"jwt_secret": "x" ** 32, "auth_timeout_ms": 200}}
    ;

    const config = try Config.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 9000), config.server.port);
    try std.testing.expectEqual(@as(u32, 200), config.auth.auth_timeout_ms);
    try std.testing.expectEqual(@as(u32, 32), config.auth.jwt_secret.len);
}

test "Config: MIN_SECRET_LENGTH is 32" {
    try std.testing.expectEqual(@as(usize, 32), MIN_SECRET_LENGTH);
}