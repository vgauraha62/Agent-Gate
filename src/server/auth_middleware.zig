//! JWT Authentication Middleware
//! Day 5: HTTP Server Foundation - Unit 4
//!
//! Extracts and validates JWT tokens from Authorization headers.

const std = @import("std");
const jwt_mod = @import("../auth/jwt.zig");
const JWT = jwt_mod.JWT;
const JwtError = jwt_mod.JwtError;
const SecurityArena = @import("../memory.zig").SecurityArena;
const Secret = @import("../secret.zig").Secret;
const Agent = @import("../agent.zig").Agent;
const PermissionSet = @import("../agent.zig").PermissionSet;

/// Authentication error types
pub const AuthError = error{
    Unauthorized,    // Missing or invalid auth header
    InvalidToken,    // JWT format invalid after parsing
    ExpiredToken,    // JWT exp claim expired
    WrongSecret,     // JWT signature doesn't match secret
    InvalidClaims,   // JWT claims validation failed
    OutOfMemory,     // Memory allocation failed
};

/// Extract and validate JWT from Authorization header
/// Returns Agent on success, AuthError on failure
pub fn authenticateFromHeader(
    allocator: std.mem.Allocator,
    authorization: ?[]const u8,
) AuthError!Agent {
    if (authorization == null) {
        return error.Unauthorized;
    }

    const auth_header = authorization.?;

    // 2. Match Bearer token format: "Bearer <token>"
    if (auth_header.len < 7) {
        return error.Unauthorized;
    }

    // Check for "Bearer " prefix (7 bytes including space)
    const is_bearer = std.mem.startsWith(u8, auth_header, "Bearer ");
    if (!is_bearer) return error.Unauthorized;

    const token = auth_header[7..];
    if (token.len == 0) return error.Unauthorized;

    // 3. Parse JWT using SecurityArena
    var arena = try SecurityArena.init(allocator, 4096);
    defer arena.deinit();

    // Parse the JWT (any parse error -> InvalidToken)
    const parsed_jwt = JWT.parse(token, &arena) catch return error.InvalidToken;

    // Get secret key for verification
    // In production, this would come from secure storage
    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(allocator, secret_key);
    defer secret.deinit();

    // 4. Verify JWT (any error -> invalid claims)
    const valid = JWT.verify(&parsed_jwt, &secret) catch return error.InvalidClaims;

    if (!valid) {
        return error.WrongSecret;
    }

    // 5. Extract agent identity from verified claims
    // Create SHA256 hash of sub as agent ID (fixed 32 bytes)
    var id_buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &id_buf, .{});

    // Create agent context with permissions
    var permissions = PermissionSet{};
    permissions.all(); // Grant all permissions for now

    return Agent{
        .id = id_buf,
        .authenticated_at = std.time.timestamp(),
        .permissions = permissions,
    };
}

/// AuthMiddleware - Middleware handler wrapper
pub const AuthMiddleware = struct {
    pub fn handle(allocator: std.mem.Allocator, authorization: ?[]const u8) AuthError!Agent {
        return authenticateFromHeader(allocator, authorization);
    }
};

test "Unit 4: JWT Authentication Middleware Tests" {
    // Test 1: Missing Authorization header returns error
    {
        const result = authenticateFromHeader(null);
        try std.testing.expectError(error.Unauthorized, result);
    }

    // Test 2: Missing Bearer prefix returns error
    {
        const result = authenticateFromHeader("Basic dG9rZW4=");
        try std.testing.expectError(error.Unauthorized, result);
    }

    // Test 3: Empty Bearer token returns error
    {
        const result = authenticateFromHeader("Bearer ");
        try std.testing.expectError(error.Unauthorized, result);
    }
}
