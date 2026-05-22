//! Configuration system for AgentGate.
//!
//! Day 6: Dynamic secret injection + timeout configuration
//! Day 10: Full configuration with env var overrides (as per PRD)

const std = @import("std");
const Secret = @import("secret.zig").Secret;

pub const MIN_SECRET_LENGTH: usize = 32;

/// Environment variable parsing error.
pub const EnvParseError = error{
    /// The value could not be parsed to the target type.
    InvalidValue,
    /// The target type is not supported for env var parsing.
    UnsupportedType,
    /// Failed to allocate memory for string conversion.
    OutOfMemory,
};

// ============================================================================
// Type-Safe Environment Variable Parser
// ============================================================================

/// Parse a string value from an environment variable into the target Zig type.
/// Supports: u8, u16, u32, u64, i8, i16, i32, i64, bool, []const u8, and enums.
pub fn parseEnvValue(comptime T: type, value: []const u8) EnvParseError!T {
    // Use direct type switch instead of @typeInfo for compatibility
    switch (T) {
        u8 => {
            const result = std.fmt.parseInt(u8, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        u16 => {
            const result = std.fmt.parseInt(u16, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        u32 => {
            const result = std.fmt.parseInt(u32, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        u64 => {
            const result = std.fmt.parseInt(u64, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        i8 => {
            const result = std.fmt.parseInt(i8, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        i16 => {
            const result = std.fmt.parseInt(i16, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        i32 => {
            const result = std.fmt.parseInt(i32, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        i64 => {
            const result = std.fmt.parseInt(i64, value, 10) catch {
                return EnvParseError.InvalidValue;
            };
            return result;
        },
        bool => {
            // Check for true values (case-insensitive)
            // Use first 5 chars, lowercased for comparison
            const trimmed = value[0..@min(value.len, 5)];
            // Simple manual lowercase for ASCII
            var lower_buffer: [5]u8 = undefined;
            const lower_len = @min(trimmed.len, 5);
            for (trimmed, 0..) |c, i| {
                if (i >= 5) break;
                lower_buffer[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            }
            const lower = lower_buffer[0..lower_len];
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "1") or std.mem.eql(u8, lower, "yes") or std.mem.eql(u8, lower, "on")) {
                return true;
            }
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "0") or std.mem.eql(u8, lower, "no") or std.mem.eql(u8, lower, "off")) {
                return false;
            }
            return EnvParseError.InvalidValue;
        },
        []const u8 => {
            return value;
        },
        // Handle specific enum types explicitly
        TLSMode => {
            return parseTLSMode(value) catch {
                return EnvParseError.InvalidValue;
            };
        },
        ExternalPolicy => {
            return parseExternalPolicy(value) catch {
                return EnvParseError.InvalidValue;
            };
        },
        else => {
            // For other types, return unsupported
            return EnvParseError.UnsupportedType;
        },
    }
}

/// Parse TLSMode enum from string.
fn parseTLSMode(value: []const u8) EnvParseError!TLSMode {
    inline for (std.meta.fields(TLSMode)) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, value)) {
            return @enumFromInt(field.value);
        }
    }
    return EnvParseError.InvalidValue;
}

/// Parse ExternalPolicy enum from string.
fn parseExternalPolicy(value: []const u8) EnvParseError!ExternalPolicy {
    inline for (std.meta.fields(ExternalPolicy)) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, value)) {
            return @enumFromInt(field.value);
        }
    }
    return EnvParseError.InvalidValue;
}

// ============================================================================
// Environment Variable Override System
// ============================================================================

// Comptime validation: ensures all config struct fields have supported types
// for env var overrides. If you add a new field to any sub-config and its type
// is not listed below, you MUST add parsing support in parseEnvValue().
// Fields with types not listed here will silently fall through to the
// UnsupportedType catch-all — add support if the field should be overridable.
comptime {
    const sub_configs = [_]type{ ServerConfig, AuthConfig, PolicyConfig, AuditConfig, RequestConfig, ShutdownConfig, TLSConfig };
    for (sub_configs) |SubT| {
        for (std.meta.fields(SubT)) |field| {
            switch (field.type) {
                // Types with explicit parsing support in parseEnvValue
                u8, u16, u32, u64,
                i8, i16, i32, i64,
                usize,
                bool, []const u8,
                TLSMode, ExternalPolicy => {},
                // Types that fall through to UnsupportedType catch-all
                // These fields are NOT overridable via env vars — intentional
                ?[]const u8, []const []const u8 => {},
                else => @compileError(
                    "Unsupported type '" ++ @typeName(field.type) ++
                    "' for field '" ++ field.name ++ "' in " ++ @typeName(SubT) ++
                    ". Add parsing support to parseEnvValue() or add the type to the comptime list above.",
                ),
            }
        }
    }
}

/// Apply environment variable overrides to a Config struct.
/// Uses flattened naming: AGENTGATE_SERVER_PORT for config.server.port
pub fn applyOverrides(config: *Config, allocator: std.mem.Allocator) void {
    applyOverridesFor(ServerConfig, &config.server, "SERVER", allocator);
    applyOverridesFor(AuthConfig, &config.auth, "AUTH", allocator);
    applyOverridesFor(PolicyConfig, &config.policy, "POLICY", allocator);
    applyOverridesFor(AuditConfig, &config.audit, "AUDIT", allocator);
    applyOverridesFor(RequestConfig, &config.request, "REQUEST", allocator);
    applyOverridesFor(ShutdownConfig, &config.shutdown, "SHUTDOWN", allocator);
    applyOverridesFor(TLSConfig, &config.tls, "TLS", allocator);
}

/// Generic function to apply environment variable overrides to any config struct.
/// Environment variable naming: AGENTGATE_<PREFIX>_<FIELD_NAME>
/// Example: AGENTGATE_SERVER_PORT overrides ServerConfig.port
///
/// Uses std.posix.getenv (borrowed reference to process environment) instead of
/// getEnvVarOwned to avoid allocations and use-after-free on string fields.
/// The environ pointer is valid for the process lifetime.
fn applyOverridesFor(comptime T: type, target: *T, comptime prefix: []const u8, allocator: std.mem.Allocator) void {
    inline for (std.meta.fields(T)) |field| {
        const field_upper = toUpperAlloc(field.name, allocator) catch return;
        defer allocator.free(field_upper);

        const env_name = std.fmt.allocPrint(allocator, "AGENTGATE_{s}_{s}", .{ prefix, field_upper }) catch return;
        defer allocator.free(env_name);

        // Borrowed reference to process environment - valid for process lifetime.
        // No allocation, no use-after-free for string fields.
        if (std.posix.getenv(env_name)) |env_value| {
            const parsed = parseEnvValue(field.type, env_value) catch {
                std.debug.print("[Config] Warning: Invalid value '{s}' for {s}, keeping default\n", .{ env_value, env_name });
                return;
            };
            @field(target, field.name) = parsed;
        }
    }
}

/// Convert string to uppercase and return as newly allocated string.
fn toUpperAlloc(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    return result;
}

/// Parse a boolean from string (for internal use).
fn parseBool(value: []const u8) EnvParseError!bool {
    return parseEnvValue(bool, value);
}

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
    /// Path to policy JSON file (relative to working directory).
    /// If null, defaults to "policies/default.json".
    policy_file: ?[]const u8 = null,
};

/// Audit configuration.
pub const AuditConfig = struct {
    /// Audit log ring buffer size (must be power of two).
    buffer_size: u32 = 1024,
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
    /// Uses std.posix.getenv (borrowed reference) to avoid allocations.
    pub fn loadTLSFromEnv(self: *Self, allocator: std.mem.Allocator) void {
        _ = allocator; // Used only for consistency with applyOverrides API
        // Only override if TLS was enabled in config file
        if (self.tls.mode == .disabled) return;

        // Override TLS mode
        if (std.posix.getenv("AGENTGATE_TLS_MODE")) |mode_str| {
            if (std.ascii.eqlIgnoreCase(mode_str, "native")) {
                self.tls.mode = .native;
            } else if (std.ascii.eqlIgnoreCase(mode_str, "external")) {
                self.tls.mode = .external;
            } else if (std.ascii.eqlIgnoreCase(mode_str, "disabled")) {
                self.tls.mode = .disabled;
            }
        }

        // Override CA certificate path
        if (std.posix.getenv("AGENTGATE_TLS_CA")) |ca_path| {
            self.tls.ca_cert_path = ca_path;
        }

        // Override server certificate path
        if (std.posix.getenv("AGENTGATE_TLS_CERT")) |cert_path| {
            self.tls.server_cert_path = cert_path;
        }

        // Override server key path
        if (std.posix.getenv("AGENTGATE_TLS_KEY")) |key_path| {
            self.tls.server_key_path = key_path;
        }

        // Override trusted proxy IP for external mode
        if (std.posix.getenv("AGENTGATE_TLS_TRUSTED_PROXY")) |proxy_ip| {
            self.tls.trusted_proxy_ip = proxy_ip;
        }
    }

    /// Clean up owned allocations.
    /// Uses std.posix.getenv for env var lookup (borrowed environ pointer),
    /// so no owned allocations need to be freed here. All string fields
    /// point to either compile-time constants, JSON file memory managed
    /// by the caller, or the process environment block.
    pub fn deinit(self: *Self) void {
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

        // Audit buffer size must be a power of two
        if (self.audit.buffer_size == 0 or (self.audit.buffer_size & (self.audit.buffer_size - 1)) != 0) {
            return error.InvalidBufferSize;
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

    /// Load configuration from JSON file with environment variable overrides.
    /// Priority: Environment Variables > JSON File > Defaults
    pub fn load(path: []const u8, allocator: std.mem.Allocator) !Self {
        // Start with default configuration
        var config = Self.default();

        // Try to load from file
        const file = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
            // File doesn't exist or can't be read - use defaults + env overrides
            applyOverrides(&config, allocator);
            return config;
        };
        // NOTE: Do NOT free file here - config struct holds slices pointing to it.
        // Caller must manage allocator lifecycle (e.g., arena deinit at program end).

        // Parse JSON from file
        var parsed = try std.json.parseFromSlice(Self, allocator, file, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Merge parsed config into our config
        config = parsed.value;

        // Apply environment variable overrides (highest priority)
        applyOverrides(&config, allocator);

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
    InvalidBufferSize,
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

    try std.testing.expectEqual(false, tls.isEnabled());
    try std.testing.expectEqual(true, tls.require_client_cert);
    try std.testing.expectEqual(@as(u32, 5000), tls.handshake_timeout_ms);
}

test "TLSConfig: isConfigured returns true when disabled" {
    const tls = TLSConfig{ .mode = .disabled };
    // When TLS is disabled, it's considered "configured" (no config needed)
    try std.testing.expectEqual(true, tls.isConfigured());
}

test "TLSConfig: isConfigured returns false when partially configured" {
    var tls = TLSConfig{ .mode = .native };
    tls.ca_cert_path = "/path/to/ca.crt";
    // Missing server_cert_path and server_key_path

    try std.testing.expectEqual(false, tls.isConfigured());
}

test "TLSConfig: isConfigured returns true when fully configured" {
    var tls = TLSConfig{
        .mode = .native,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectEqual(true, tls.isConfigured());
}

test "TLSConfig: validate passes when disabled" {
    const tls = TLSConfig{ .mode = .disabled };
    try tls.validate();
}

test "TLSConfig: validate fails when enabled but missing CA" {
    var tls = TLSConfig{
        .mode = .native,
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectError(error.TLSCARequired, tls.validate());
}

test "TLSConfig: validate fails when enabled but missing server cert" {
    var tls = TLSConfig{
        .mode = .native,
        .ca_cert_path = "/path/to/ca.crt",
        .server_key_path = "/path/to/server.key",
    };

    try std.testing.expectError(error.TLSServerCertRequired, tls.validate());
}

test "TLSConfig: validate fails when enabled but missing server key" {
    var tls = TLSConfig{
        .mode = .native,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
    };

    try std.testing.expectError(error.TLSServerKeyRequired, tls.validate());
}

test "TLSConfig: validate passes when fully configured" {
    var tls = TLSConfig{
        .mode = .native,
        .ca_cert_path = "/path/to/ca.crt",
        .server_cert_path = "/path/to/server.crt",
        .server_key_path = "/path/to/server.key",
    };

    try tls.validate();
}

test "Config: parse JSON with TLS" {
    const json = "{\"server\": {\"port\": 8080}, \"auth\": {\"jwt_secret\": \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}, \"tls\": {\"mode\": \"native\", \"ca_cert_path\": \"./certs/ca.crt\", \"server_cert_path\": \"./certs/server.crt\", \"server_key_path\": \"./certs/server.key\"}}";

    var config = try Config.parse(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqual(true, config.tls.isEnabled());
    try std.testing.expectEqualStrings("./certs/ca.crt", config.tls.ca_cert_path);
    try std.testing.expectEqualStrings("./certs/server.crt", config.tls.server_cert_path);
    try std.testing.expectEqualStrings("./certs/server.key", config.tls.server_key_path);
}

// ============================================================================
// Environment Variable Parser Tests
// ============================================================================

test "parseEnvValue: u16 from string" {
    const result = try parseEnvValue(u16, "8080");
    try std.testing.expectEqual(@as(u16, 8080), result);
}

test "parseEnvValue: u8 from string" {
    const result = try parseEnvValue(u8, "4");
    try std.testing.expectEqual(@as(u8, 4), result);
}

test "parseEnvValue: u32 from string" {
    const result = try parseEnvValue(u32, "5000");
    try std.testing.expectEqual(@as(u32, 5000), result);
}

test "parseEnvValue: u64 from string" {
    const result = try parseEnvValue(u64, "1234567890");
    try std.testing.expectEqual(@as(u64, 1234567890), result);
}

test "parseEnvValue: i32 from string" {
    const result = try parseEnvValue(i32, "-100");
    try std.testing.expectEqual(@as(i32, -100), result);
}

test "parseEnvValue: bool true from 'true'" {
    const result = try parseEnvValue(bool, "true");
    try std.testing.expectEqual(true, result);
}

test "parseEnvValue: bool true from '1'" {
    const result = try parseEnvValue(bool, "1");
    try std.testing.expectEqual(true, result);
}

test "parseEnvValue: bool true from 'yes'" {
    const result = try parseEnvValue(bool, "yes");
    try std.testing.expectEqual(true, result);
}

test "parseEnvValue: bool false from 'false'" {
    const result = try parseEnvValue(bool, "false");
    try std.testing.expectEqual(false, result);
}

test "parseEnvValue: bool false from '0'" {
    const result = try parseEnvValue(bool, "0");
    try std.testing.expectEqual(false, result);
}

test "parseEnvValue: bool false from 'no'" {
    const result = try parseEnvValue(bool, "no");
    try std.testing.expectEqual(false, result);
}

test "parseEnvValue: bool case insensitive" {
    try std.testing.expectEqual(true, try parseEnvValue(bool, "TRUE"));
    try std.testing.expectEqual(true, try parseEnvValue(bool, "True"));
    try std.testing.expectEqual(false, try parseEnvValue(bool, "FALSE"));
    try std.testing.expectEqual(false, try parseEnvValue(bool, "False"));
}

test "parseEnvValue: bool invalid returns error" {
    try std.testing.expectError(error.InvalidValue, parseEnvValue(bool, "invalid"));
    try std.testing.expectError(error.InvalidValue, parseEnvValue(bool, "maybe"));
}

test "parseEnvValue: invalid integer returns error" {
    try std.testing.expectError(error.InvalidValue, parseEnvValue(u16, "not-a-number"));
    try std.testing.expectError(error.InvalidValue, parseEnvValue(u16, ""));
}

test "parseEnvValue: enum from string" {
    const result = try parseEnvValue(TLSMode, "native");
    try std.testing.expectEqual(TLSMode.native, result);
}

test "parseEnvValue: enum case insensitive" {
    try std.testing.expectEqual(TLSMode.native, try parseEnvValue(TLSMode, "NATIVE"));
    try std.testing.expectEqual(TLSMode.native, try parseEnvValue(TLSMode, "Native"));
    try std.testing.expectEqual(TLSMode.external, try parseEnvValue(TLSMode, "EXTERNAL"));
}

test "parseEnvValue: enum invalid returns error" {
    try std.testing.expectError(error.InvalidValue, parseEnvValue(TLSMode, "invalid"));
    try std.testing.expectError(error.InvalidValue, parseEnvValue(TLSMode, ""));
}

test "parseEnvValue: unsupported type returns error" {
    try std.testing.expectError(error.UnsupportedType, parseEnvValue(f32, "1.0"));
    try std.testing.expectError(error.UnsupportedType, parseEnvValue([]u8, "test"));
}

// ============================================================================
// applyOverrides Tests
// ============================================================================

test "applyOverrides: preserves defaults when no env var" {
    var config = Config.default();
    config.auth.jwt_secret = "test-secret-that-is-long-enough-32";

    applyOverrides(&config, std.testing.allocator);

    // Default values should be preserved when no env vars are set
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqual(@as(u8, 4), config.server.workers);
    try std.testing.expectEqual(@as(u32, 100), config.auth.auth_timeout_ms);
    try std.testing.expectEqual(TLSMode.disabled, config.tls.mode);
}

test "toUpperAlloc: converts lowercase to uppercase" {
    const result = try toUpperAlloc("hello", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("HELLO", result);
}

test "toUpperAlloc: preserves uppercase" {
    const result = try toUpperAlloc("HELLO", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("HELLO", result);
}

test "toUpperAlloc: handles mixed case" {
    const result = try toUpperAlloc("HeLLo", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("HELLO", result);
}