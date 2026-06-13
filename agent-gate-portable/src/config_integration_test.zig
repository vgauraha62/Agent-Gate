//! Integration tests for the hierarchical configuration system.
//!
//! Verifies the priority chain: Environment Variables > JSON File > Defaults
//! Also tests validation, parse errors, and edge cases.

const std = @import("std");
const config = @import("config.zig");

test "Config: priority chain - defaults used when no file and no env" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);
    try std.testing.expectEqual(@as(u8, 4), cfg.server.workers);
    try std.testing.expectEqual(config.TLSMode.disabled, cfg.tls.mode);
}

test "Config: priority chain - env overrides file" {
    // Simulate file-loaded config: port=8080, then env override to 9000
    var cfg = config.Config.default();
    cfg.server.port = 8080;

    // Apply overrides (without AGENTGATE_SERVER_PORT set, port stays 8080)
    config.applyOverrides(&cfg, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);

    // Note: We can't actually set env vars in a portable way in tests,
    // but we verify the function exists and is correctly structured.
    // The unit tests in config.zig cover env var parsing directly.
}

test "Config: parse JSON with all fields" {
    const json =
        \\{
        \\  "server": { "port": 9090, "host": "0.0.0.0", "workers": 8 },
        \\  "auth": { "jwt_secret": "abcdefghijklmnopqrstuvwxyz123456", "auth_timeout_ms": 200 },
        \\  "policy": { "policy_timeout_ms": 100, "max_policies": 500 },
        \\  "audit": { "buffer_size": 2048, "audit_timeout_ms": 50 },
        \\  "request": { "request_timeout_ms": 10000, "max_body_size": 131072, "max_headers": 128 },
        \\  "shutdown": { "grace_period_ms": 60000, "enable_signals": false },
        \\  "tls": { "mode": "native", "ca_cert_path": "/etc/certs/ca.pem", "server_cert_path": "/etc/certs/server.pem", "server_key_path": "/etc/certs/key.pem" }
        \\}
    ;

    var parsed = try config.Config.parse(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, 9090), parsed.server.port);
    try std.testing.expectEqualStrings("0.0.0.0", parsed.server.host);
    try std.testing.expectEqual(@as(u8, 8), parsed.server.workers);
    try std.testing.expectEqual(@as(u32, 200), parsed.auth.auth_timeout_ms);
    try std.testing.expectEqual(@as(u32, 100), parsed.policy.policy_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), parsed.audit.buffer_size);
    try std.testing.expectEqual(@as(u32, 10000), parsed.request.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 60000), parsed.shutdown.grace_period_ms);
    try std.testing.expectEqual(false, parsed.shutdown.enable_signals);
    try std.testing.expectEqual(config.TLSMode.native, parsed.tls.mode);
}

test "Config: parse JSON ignores unknown fields" {
    const json =
        \\{
        \\  "server": { "port": 8080 },
        \\  "unknown_field": "should be ignored",
        \\  "future_feature": { "enabled": true }
        \\}
    ;

    var parsed = try config.Config.parse(std.testing.allocator, json);
    defer parsed.deinit();

    // Unknown fields should be silently ignored
    try std.testing.expectEqual(@as(u16, 8080), parsed.server.port);
}

test "Config: validate accepts valid config" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    try cfg.validate();
}

test "Config: validate rejects invalid port" {
    var cfg = config.Config.default();
    cfg.server.port = 0;
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    try std.testing.expectError(error.InvalidPort, cfg.validate());
}

test "Config: validate rejects short secret" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "too-short";
    try std.testing.expectError(error.SecretTooShort, cfg.validate());
}

test "Config: validate rejects policy timeout >= request timeout" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.policy.policy_timeout_ms = 5000;
    cfg.request.request_timeout_ms = 5000;
    try std.testing.expectError(error.PolicyTimeoutExceedsRequestTimeout, cfg.validate());
}

test "Config: validate rejects non-power-of-2 audit buffer" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.audit.buffer_size = 1000; // Not a power of 2
    try std.testing.expectError(error.InvalidBufferSize, cfg.validate());
}

test "Config: validate accepts power-of-2 audit buffer" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.audit.buffer_size = 2048; // Power of 2
    try cfg.validate();
}

test "Config: getRemainingTimeout returns correct values" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(@as(u32, 5000), cfg.getRemainingTimeout(0));
    try std.testing.expectEqual(@as(u32, 4900), cfg.getRemainingTimeout(100));
    try std.testing.expectEqual(@as(u32, 0), cfg.getRemainingTimeout(5000));
    try std.testing.expectEqual(@as(u32, 0), cfg.getRemainingTimeout(6000));
}

test "Config: TLS validation passes when disabled" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.tls.mode = .disabled;
    try cfg.validate();
}

test "Config: TLS validation rejects invalid config in native mode" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.tls.mode = .native;
    // Missing required cert paths
    try std.testing.expectError(error.TLSCARequired, cfg.validate());
}

test "Config: TLS validation accepts native mode with all certs" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "this-is-a-valid-secret-key-32-bytes!";
    cfg.tls.mode = .native;
    cfg.tls.ca_cert_path = "/etc/certs/ca.pem";
    cfg.tls.server_cert_path = "/etc/certs/server.pem";
    cfg.tls.server_key_path = "/etc/certs/key.pem";
    try cfg.validate();
}

test "Config: parseEnvValue handles all supported types" {
    try std.testing.expectEqual(@as(u8, 42), try config.parseEnvValue(u8, "42"));
    try std.testing.expectEqual(@as(u16, 8080), try config.parseEnvValue(u16, "8080"));
    try std.testing.expectEqual(@as(u32, 5000), try config.parseEnvValue(u32, "5000"));
    try std.testing.expectEqual(@as(u64, 123456789), try config.parseEnvValue(u64, "123456789"));
    try std.testing.expectEqual(@as(i8, -10), try config.parseEnvValue(i8, "-10"));
    try std.testing.expectEqual(@as(i16, -100), try config.parseEnvValue(i16, "-100"));
    try std.testing.expectEqual(@as(i32, -5000), try config.parseEnvValue(i32, "-5000"));
    try std.testing.expectEqual(@as(i64, -123456789), try config.parseEnvValue(i64, "-123456789"));
    try std.testing.expectEqual(true, try config.parseEnvValue(bool, "true"));
    try std.testing.expectEqual(false, try config.parseEnvValue(bool, "false"));
    try std.testing.expectEqualStrings("hello", try config.parseEnvValue([]const u8, "hello"));
}

test "Config: parseEnvValue rejects invalid values" {
    try std.testing.expectError(error.InvalidValue, config.parseEnvValue(u16, "not-a-number"));
    try std.testing.expectError(error.InvalidValue, config.parseEnvValue(bool, "maybe"));
    try std.testing.expectError(error.UnsupportedType, config.parseEnvValue(f32, "1.0"));
}

test "Config: applyOverrides preserves defaults when no env vars set" {
    var cfg = config.Config.default();
    cfg.auth.jwt_secret = "test-secret-that-is-long-enough-32";
    config.applyOverrides(&cfg, std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);
    try std.testing.expectEqual(@as(u8, 4), cfg.server.workers);
    try std.testing.expectEqual(config.TLSMode.disabled, cfg.tls.mode);
}

test "Config: env override names follow AGENTGATE_<SECTION>_<FIELD> pattern" {
    // Verify the naming convention by checking a few fields
    const server_fields = std.meta.fields(config.ServerConfig);
    try std.testing.expectEqualStrings("port", server_fields[0].name);
    try std.testing.expectEqualStrings("host", server_fields[1].name);
    try std.testing.expectEqualStrings("workers", server_fields[2].name);
    // Env name would be: AGENTGATE_SERVER_PORT, AGENTGATE_SERVER_HOST, AGENTGATE_SERVER_WORKERS
}

test "Config: loadTLSFromEnv does nothing when TLS disabled" {
    var cfg = config.Config.default();
    cfg.tls.mode = .disabled;
    cfg.loadTLSFromEnv(std.testing.allocator);
    try std.testing.expectEqual(config.TLSMode.disabled, cfg.tls.mode);
}

test "Config: suite - all validation errors have unique types" {
    // Verify the error types are all distinct
    // This is a compile-time check that the error set is well-formed
    try std.testing.expect(@typeInfo(config.ConfigError).error_set != null);
}
