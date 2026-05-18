//! Configuration system for AgentGate.
//!
//! Day 6: Dynamic secret injection + timeout configuration
//! Day 10: Full configuration with env var overrides (as per PRD)

const std = @import("std");
const Secret = @import("secret.zig").Secret;

pub const MIN_SECRET_LENGTH: usize = 32;

/// TLS mode for AgentGate.
    /// Defines how TLS is handled: disabled, native (AgentGate handles TLS), or external (nginx handles TLS).
    pub const TLSMode = enum {
        /// Plain HTTP mode - no TLS.
        disabled,
        /// Native TLS mode - AgentGate handles TLS directly (native mTLS).
        native,
        /// External TLS mode - nginx handles TLS, AgentGate parses X-SSL headers.
        external,
    };

    /// External mode policy - controls behavior when TLS is handled by nginx.
    pub const ExternalPolicy = enum {
        /// Strict: Reject all non-SSL requests in external mode.
        /// No fallback to JWT or other auth methods.
        strict,
        /// Permissive: Allow fallback to other auth methods (e.g., JWT).
        /// Use when some agents use mTLS and others use JWT.
        permissive,
    };

/// TLS/mTLS configuration.
pub const TLSConfig = struct {
    /// TLS mode: disabled, native, or external.
    /// When set to .native or .external, TLS is enabled.
    mode: TLSMode = .disabled,
    /// Path to CA certificate (for validating client certs in native mode).
    ca_cert_path: []const u8 = "",
    /// Path to server certificate (for native mode).
    server_cert_path: []const u8 = "",
    /// Path to server private key (for native mode).
    server_key_path: []const u8 = "",
    /// Require client certificate (for mTLS). If false, regular TLS.
    require_client_cert: bool = true,
    /// TLS handshake timeout in milliseconds.
    handshake_timeout_ms: u32 = 5000,

    // External mode settings (when nginx handles TLS)
    /// Trusted proxy IP for external mode (default: 127.0.0.1).
    trusted_proxy_ip: []const u8 = "127.0.0.1",
    /// Require SSL headers in external mode - reject direct access.
    require_ssl_headers: bool = true,
    /// External mode policy: strict (reject non-SSL) or permissive (allow fallback).
    external_policy: ExternalPolicy = .strict,
    /// Enable PEM certificate fallback - compute fingerprint from PEM if header not available.
    enable_pem_fallback: bool = true,
    /// List of trusted SSL headers that AgentGate will parse.
    /// Default includes all standard X-SSL headers.
    trusted_headers: []const []const u8 = &.{
        "X-SSL-Client-Verify",
        "X-SSL-Client-Fingerprint",
        "X-SSL-Client-Cert",
        "X-SSL-Client-CN",
        "X-SSL-Client-Serial",
    },

    const Self = @This();

    /// Check if TLS is enabled (backward compatible with .enabled field).
    /// Returns true if mode is not .disabled.
    pub fn isEnabled(self: *const Self) bool {
        return self.mode != .disabled;
    }

    /// Check if TLS is properly configured for native mode.
    pub fn isNativeConfigured(self: *const Self) bool {
        return self.mode == .native and
            self.ca_cert_path.len > 0 and
            self.server_cert_path.len > 0 and
            self.server_key_path.len > 0;
    }

    /// Check if external mode is properly configured.
    pub fn isExternalConfigured(self: *const Self) bool {
        return self.mode == .external;
    }

    /// Check if TLS is properly configured (auto-detects mode).
    pub fn isConfigured(self: *const Self) bool {
        return switch (self.mode) {
            .disabled => true,
            .native => self.isNativeConfigured(),
            .external => true, // External mode doesn't require certs in AgentGate
        };
    }

    /// Validate TLS configuration when enabled.
    pub fn validate(self: *const Self) !void {
        if (self.mode == .disabled) return;

        if (self.mode == .native) {
            if (self.ca_cert_path.len == 0) {
                return error.TLSCARequired;
            }
            if (self.server_cert_path.len == 0) {
                return error.TLSServerCertRequired;
            }
            if (self.server_key_path.len == 0) {
                return error.TLSServerKeyRequired;
            }
        }

        if (self.handshake_timeout_ms == 0) {
            return error.TLSInvalidTimeout;
        }
    }
};

/// Server configuration.
pub const ServerConfig = struct {
    /// Port to listen on.
    port: u16 = 8080,
    /// Host to bind to.
    host: []const u8 = "127.0.0.1",
    /// Number of worker threads (0 = auto based on CPU cores).
    workers: u8 = 4,
    /// Enable TLS (deprecated - use tls.enabled instead).
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
    /// TLS/mTLS settings.
    tls: TLSConfig = .{},

    const Self = @This();

    /// Create default configuration.
    pub fn default() Self {
        return .{};
    }

    /// Load TLS configuration with environment variable overrides.
    /// Environment variables take priority over config file values.
    pub fn loadTLSFromEnv(self: *Self, allocator: std.mem.Allocator) void {
        // Only override if TLS was enabled in config file
        if (self.tls.mode == .disabled) return;

        // Override TLS mode
        if (std.process.getEnvVarOwned(allocator, "AGENTGATE_TLS_MODE")) |mode_str| {
            if (std.mem.eql(u8, mode_str, "native")) {
                self.tls.mode = .native;
            } else if (std.mem.eql(u8, mode_str, "external")) {
                self.tls.mode = .external;
            } else if (std.mem.eql(u8, mode_str, "disabled")) {
                self.tls.mode = .disabled;
            }
        } else |_| {}

        // Override CA certificate path
        if (std.process.getEnvVarOwned(allocator, "AGENTGATE_TLS_CA")) |ca_path| {
            self.tls.ca_cert_path = ca_path;
        } else |_| {}

        // Override server certificate path
        if (std.process.getEnvVarOwned(allocator, "AGENTGATE_TLS_CERT")) |cert_path| {
            self.tls.server_cert_path = cert_path;
        } else |_| {}

        // Override server key path
        if (std.process.getEnvVarOwned(allocator, "AGENTGATE_TLS_KEY")) |key_path| {
            self.tls.server_key_path = key_path;
        } else |_| {}

        // Override trusted proxy IP for external mode
        if (std.process.getEnvVarOwned(allocator, "AGENTGATE_TLS_TRUSTED_PROXY")) |proxy_ip| {
            self.tls.trusted_proxy_ip = proxy_ip;
        } else |_| {}
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

        // Validate TLS configuration
        try self.tls.validate();
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
    TLSCARequired,
    TLSServerCertRequired,
    TLSServerKeyRequired,
    TLSInvalidTimeout,
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
    const json = "{\"server\": {\"port\": 9000}, \"auth\": {\"jwt_secret\": \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\", \"auth_timeout_ms\": 200}}";

    var config = try Config.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 9000), config.server.port);
    try std.testing.expectEqual(@as(u32, 200), config.auth.auth_timeout_ms);
    try std.testing.expectEqual(@as(u32, 32), config.auth.jwt_secret.len);
}

test "Config: MIN_SECRET_LENGTH is 32" {
    try std.testing.expectEqual(@as(usize, 32), MIN_SECRET_LENGTH);
}

test "TLSConfig: default values" {
    const tls = TLSConfig{};

    try std.testing.expectEqual(false, tls.enabled);
    try std.testing.expectEqual(true, tls.require_client_cert);
    try std.testing.expectEqual(@as(u32, 5000), tls.handshake_timeout_ms);
}

test "TLSConfig: isConfigured returns false when disabled" {
    const tls = TLSConfig{ .enabled = false };
    try std.testing.expectEqual(false, tls.isConfigured());
}

test "TLSConfig: isConfigured returns false when partially configured" {
    var tls = TLSConfig{ .enabled = true };
    tls.ca_cert_path = "/path/to/ca.crt";
    // Missing server_cert_path and server_key_path

    try std.testing.expectEqual(false, tls.isConfigured());
}

test "TLSConfig: isConfigured returns true when fully configured" {
    var tls = TLSConfig{
        .enabled = true,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectEqual(true, tls.isConfigured());
}

test "TLSConfig: validate passes when disabled" {
    const tls = TLSConfig{ .enabled = false };
    try tls.validate();
}

test "TLSConfig: validate fails when enabled but missing CA" {
    var tls = TLSConfig{
        .enabled = true,
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectError(error.TLSCARequired, tls.validate());
}

test "TLSConfig: validate fails when enabled but missing server cert" {
    var tls = TLSConfig{
        .enabled = true,
        .ca_cert_path = "/path/to/ca.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectError(error.TLSServerCertRequired, tls.validate());
}

test "TLSConfig: validate fails when enabled but missing server key" {
    var tls = TLSConfig{
        .enabled = true,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
    };

    try std.testing.expectError(error.TLSServerKeyRequired, tls.validate());
}

test "TLSConfig: validate passes when fully configured" {
    var tls = TLSConfig{
        .enabled = true,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try tls.validate();
}

test "Config: parse JSON with TLS" {
    const json = "{\"server\": {\"port\": 8080}, \"auth\": {\"jwt_secret\": \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}, \"tls\": {\"enabled\": true, \"ca_cert_path\": \"./certs/ca.crt\", \"server_cert_path\": \"./certs/server.crt\", \"server_key_path\": \"./certs/server.key\"}}";

    var config = try Config.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(true, config.tls.enabled);
    try std.testing.expectEqualStrings("./certs/ca.crt", config.tls.ca_cert_path);
    try std.testing.expectEqualStrings("./certs/server.crt", config.tls.server_cert_path);
    try std.testing.expectEqualStrings("./certs/server.key", config.tls.server_key_path);
}