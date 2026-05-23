//! JWT Authentication Middleware
//! Day 6: Dynamic Secret Injection
//!
//! Extracts and validates JWT tokens from Authorization headers.
//! Supports configurable secret via Config injection.

const std = @import("std");
const jwt_mod = @import("../auth/jwt.zig");
const JWT = jwt_mod.JWT;
const JwtError = jwt_mod.JwtError;
const SecurityArena = @import("../memory.zig").SecurityArena;
const Secret = @import("../secret.zig").Secret;
const Agent = @import("../agent.zig").Agent;
const PermissionSet = @import("../agent.zig").PermissionSet;
const errors = @import("../errors.zig");

/// Authentication error types
pub const AuthError = error{
    Unauthorized,    // Missing or invalid auth header
    InvalidToken,    // JWT format invalid after parsing
    ExpiredToken,    // JWT exp claim expired
    WrongSecret,     // JWT signature doesn't match secret
    InvalidClaims,   // JWT claims validation failed
    OutOfMemory,     // Memory allocation failed
    SecretNotConfigured,  // No secret configured
};

/// AuthMiddleware - JWT authentication handler with configurable secret.
/// Day 6: Updated to accept secret as parameter.
pub const AuthMiddleware = struct {
    /// The JWT signing secret (stored securely).
    secret: Secret,
    /// Arena allocator for per-request allocations.
    /// Stored as a value (not pointer) to avoid lifetime issues.
    arena: SecurityArena,

    const Self = @This();

    /// Initialize auth middleware with a secret.
    /// The secret is stored securely and zeroized on deinit.
    pub fn init(allocator: std.mem.Allocator, jwt_secret: []const u8) !Self {
        const secret = try Secret.init(allocator, jwt_secret);
const arena = try SecurityArena.init(allocator, 4096);

        return Self{
            .secret = secret,
            .arena = arena,
        };
    }

    /// Clean up the middleware (zeroize secret, free memory).
    pub fn deinit(self: *Self) void {
        self.secret.deinit();
        self.arena.deinit();
    }

    /// Authenticate a request using the Authorization header.
    /// Uses the configured secret for verification.
    pub fn authenticate(self: *Self, authorization: ?[]const u8) AuthError!Agent {
        // Create fresh arena for this request to avoid state issues
        var arena = try SecurityArena.init(self.secret.allocator, 4096);
        defer arena.deinit();
        return authenticateWithSecret(&arena, authorization, &self.secret);
    }
};

/// Extract and validate JWT from Authorization header using provided secret.
/// Returns Agent on success, AuthError on failure.
/// Day 6: Refactored to accept secret as parameter.
pub fn authenticateWithSecret(
    arena: *SecurityArena,
    authorization: ?[]const u8,
    secret: *Secret,
) AuthError!Agent {
    if (authorization == null) {
        return error.Unauthorized;
    }

    const auth_header = authorization.?;

    // Match Bearer token format: "Bearer <token>"
    if (auth_header.len < 7) {
        return error.Unauthorized;
    }

    const is_bearer = std.mem.startsWith(u8, auth_header, "Bearer ");
    if (!is_bearer) return error.Unauthorized;

    const token = auth_header[7..];
    if (token.len == 0) return error.Unauthorized;

    // Parse the JWT using arena (arena is reset on each call)
    arena.reset();
    const parsed_jwt = JWT.parse(token, arena) catch return error.InvalidToken;

    // Verify with provided secret
    const valid = JWT.verify(&parsed_jwt, secret, .{}) catch |err| {
        // Map JWT errors to Auth errors
        if (err == JwtError.TokenExpired) return error.ExpiredToken;
        if (err == JwtError.InvalidSignature) return error.WrongSecret;
        // All other JWT errors map to InvalidClaims
        return error.InvalidClaims;
    };

    if (!valid) {
        return error.WrongSecret;
    }

    // Extract agent identity
    var id_buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &id_buf, .{});

    var permissions = PermissionSet{};
    permissions.all();

    return Agent{
        .id = id_buf,
        .authenticated_at = std.time.timestamp(),
        .permissions = permissions,
    };
}

test "AuthMiddleware: init and authenticate with valid token" {
    const gpa = std.testing.allocator;
    const test_secret = "test-secret-key-32-bytes-exactly!!";

    var middleware = try AuthMiddleware.init(gpa, test_secret);
    defer middleware.deinit();

    // Generate valid token
    const token = try jwt_mod.generateTestJWT(gpa, test_secret, "agent-test", 3600);
    defer gpa.free(token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    // Should succeed
    const agent = middleware.authenticate(auth_header);
    try std.testing.expect(agent != error.Unauthorized);
}

test "AuthMiddleware: authenticate rejects expired token" {
    const gpa = std.testing.allocator;
    const test_secret = "test-secret-key-32-bytes-exactly!!";

    var middleware = try AuthMiddleware.init(gpa, test_secret);
    defer middleware.deinit();

    // Generate expired token
    const token = try jwt_mod.generateExpiredJWT(gpa, test_secret, "agent-test");
    defer gpa.free(token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    // Should fail with ExpiredToken
    const result = middleware.authenticate(auth_header);
    try std.testing.expectError(error.ExpiredToken, result);
}

test "AuthMiddleware: authenticate rejects wrong secret" {
    const gpa = std.testing.allocator;
    const test_secret = "test-secret-key-32-bytes-exactly!!";
    const wrong_secret = "wrong-secret-key-32-bytes-exactly!";

    var middleware = try AuthMiddleware.init(gpa, test_secret);
    defer middleware.deinit();

    // Generate token with wrong secret
    const token = try jwt_mod.generateTestJWT(gpa, wrong_secret, "agent-test", 3600);
    defer gpa.free(token);

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    // Should fail with WrongSecret
    const result = middleware.authenticate(auth_header);
    try std.testing.expectError(error.WrongSecret, result);
}

test "authenticateWithSecret: null header returns Unauthorized" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    var secret = try Secret.init(gpa, "test-secret-32-bytes-exactly!!!");
    defer secret.deinit();

    const result = authenticateWithSecret(&arena, null, &secret);
    try std.testing.expectError(error.Unauthorized, result);
}

test "authenticateWithSecret: missing Bearer prefix" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    var secret = try Secret.init(gpa, "test-secret-32-bytes-exactly!!!");
    defer secret.deinit();

    const result = authenticateWithSecret(&arena, "Basic abc123", &secret);
    try std.testing.expectError(error.Unauthorized, result);
}

test "authenticateWithSecret: empty token" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    var secret = try Secret.init(gpa, "test-secret-32-bytes-exactly!!!");
    defer secret.deinit();

    const result = authenticateWithSecret(&arena, "Bearer ", &secret);
    try std.testing.expectError(error.Unauthorized, result);
}

test "authenticateWithSecret: invalid JWT format" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    var secret = try Secret.init(gpa, "test-secret-32-bytes-exactly!!!");
    defer secret.deinit();

    const result = authenticateWithSecret(&arena, "Bearer invalid.token", &secret);
    try std.testing.expectError(error.InvalidToken, result);
}
