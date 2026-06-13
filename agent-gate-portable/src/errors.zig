//! Error Taxonomy - Unified error enum for AgentGate.
//!
//! Provides a single source of truth for all errors with HTTP status mapping.
//! Day 5.5: Foundation hardening for Day 6 integration.

const std = @import("std");

/// AgentGate unified error taxonomy.
/// Organized by HTTP status code for easy mapping.
pub const AgentGateError = error{
    // === 401 Unauthorized (Auth failures) ===
    /// Missing or no Authorization header present.
    Unauthorized,
    /// JWT token has expired (exp claim < current time).
    TokenExpired,
    /// HMAC signature verification failed.
    InvalidSignature,
    /// JWT structure malformed (missing parts, invalid base64, etc.).
    MalformedToken,
    /// Authorization header present but not in Bearer format.
    MissingAuthHeader,

    // === 403 Forbidden (Policy denials) ===
    /// Request matched a deny policy or no allow policy matched.
    PolicyDenied,
    /// Policy engine encountered an internal error during evaluation.
    PolicyEvaluationFailed,
    /// Referenced policy does not exist in the policy set.
    PolicyNotFound,

    // === 400 Bad Request (Client errors) ===
    /// HTTP request malformed (invalid request line, headers, etc.).
    MalformedRequest,
    /// Request body JSON is invalid or malformed.
    InvalidBody,
    /// Required field missing from request body.
    MissingRequiredField,

    // === 500 Internal Server Error (Server failures) ===
    /// Unexpected internal error occurred.
    InternalError,
    /// Memory allocation failed.
    AllocatorFailed,
    /// Audit log ring buffer overflow (data lost).
    AuditLogFull,
    /// Ring buffer write would overwrite unread data.
    RingBufferOverflow,

    // === 504 Gateway Timeout (Timeout errors) ===
    /// Upstream service did not respond in time.
    UpstreamTimeout,
    /// Policy evaluation exceeded timeout limit.
    PolicyTimeout,
    /// Authentication step exceeded timeout limit.
    AuthTimeout,
};

/// Convert any error to HTTP status code.
/// Provides consistent API error responses.
pub inline fn toHttpStatus(err: anyerror) u16 {
    return switch (err) {
        // 401 Unauthorized
        error.Unauthorized,
        error.TokenExpired,
        error.InvalidSignature,
        error.MalformedToken,
        error.MissingAuthHeader => 401,

        // 403 Forbidden
        error.PolicyDenied,
        error.PolicyEvaluationFailed,
        error.PolicyNotFound => 403,

        // 400 Bad Request
        error.MalformedRequest,
        error.InvalidBody,
        error.MissingRequiredField => 400,

        // 500 Internal Server Error
        error.InternalError,
        error.AllocatorFailed,
        error.AuditLogFull,
        error.RingBufferOverflow => 500,

        // 504 Gateway Timeout
        error.UpstreamTimeout,
        error.PolicyTimeout,
        error.AuthTimeout => 504,

        // Unknown errors default to 500
        else => 500,
    };
}

/// Get human-readable error message for client responses.
/// Never leaks internal implementation details.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        // 401 errors
        error.Unauthorized => "missing authorization header",
        error.TokenExpired => "token has expired",
        error.InvalidSignature => "invalid token signature",
        error.MalformedToken => "invalid token format",
        error.MissingAuthHeader => "authorization header required",

        // 403 errors
        error.PolicyDenied => "access denied by policy",
        error.PolicyEvaluationFailed => "policy check failed",
        error.PolicyNotFound => "policy not found",

        // 400 errors
        error.MalformedRequest => "invalid request format",
        error.InvalidBody => "invalid request body",
        error.MissingRequiredField => "required field missing",

        // 500 errors
        error.InternalError => "internal server error",
        error.AllocatorFailed => "service temporarily unavailable",
        error.AuditLogFull => "audit log unavailable",
        error.RingBufferOverflow => "audit log overflow",

        // 504 errors
        error.UpstreamTimeout => "upstream service timeout",
        error.PolicyTimeout => "policy evaluation timeout",
        error.AuthTimeout => "authentication timeout",

        else => "unknown error",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "AgentGateError: auth errors map to 401" {
    try std.testing.expectEqual(401, toHttpStatus(error.Unauthorized));
    try std.testing.expectEqual(401, toHttpStatus(error.TokenExpired));
    try std.testing.expectEqual(401, toHttpStatus(error.InvalidSignature));
    try std.testing.expectEqual(401, toHttpStatus(error.MalformedToken));
    try std.testing.expectEqual(401, toHttpStatus(error.MissingAuthHeader));
}

test "AgentGateError: policy errors map to 403" {
    try std.testing.expectEqual(403, toHttpStatus(error.PolicyDenied));
    try std.testing.expectEqual(403, toHttpStatus(error.PolicyEvaluationFailed));
    try std.testing.expectEqual(403, toHttpStatus(error.PolicyNotFound));
}

test "AgentGateError: client errors map to 400" {
    try std.testing.expectEqual(400, toHttpStatus(error.MalformedRequest));
    try std.testing.expectEqual(400, toHttpStatus(error.InvalidBody));
    try std.testing.expectEqual(400, toHttpStatus(error.MissingRequiredField));
}

test "AgentGateError: server errors map to 500" {
    try std.testing.expectEqual(500, toHttpStatus(error.InternalError));
    try std.testing.expectEqual(500, toHttpStatus(error.AllocatorFailed));
    try std.testing.expectEqual(500, toHttpStatus(error.AuditLogFull));
    try std.testing.expectEqual(500, toHttpStatus(error.RingBufferOverflow));
}

test "AgentGateError: timeout errors map to 504" {
    try std.testing.expectEqual(504, toHttpStatus(error.UpstreamTimeout));
    try std.testing.expectEqual(504, toHttpStatus(error.PolicyTimeout));
    try std.testing.expectEqual(504, toHttpStatus(error.AuthTimeout));
}

test "AgentGateError: unknown errors default to 500" {
    try std.testing.expectEqual(500, toHttpStatus(error.FileNotFound));
    try std.testing.expectEqual(500, toHttpStatus(error.InvalidArgument));
}

test "AgentGateError: errorMessage returns safe strings" {
    // Auth errors
    try std.testing.expectEqualStrings("missing authorization header", errorMessage(error.Unauthorized));
    try std.testing.expectEqualStrings("token has expired", errorMessage(error.TokenExpired));
    try std.testing.expectEqualStrings("invalid token signature", errorMessage(error.InvalidSignature));
    try std.testing.expectEqualStrings("invalid token format", errorMessage(error.MalformedToken));

    // Policy errors
    try std.testing.expectEqualStrings("access denied by policy", errorMessage(error.PolicyDenied));
    try std.testing.expectEqualStrings("policy check failed", errorMessage(error.PolicyEvaluationFailed));

    // Client errors
    try std.testing.expectEqualStrings("invalid request format", errorMessage(error.MalformedRequest));
    try std.testing.expectEqualStrings("invalid request body", errorMessage(error.InvalidBody));

    // Server errors
    try std.testing.expectEqualStrings("internal server error", errorMessage(error.InternalError));
    try std.testing.expectEqualStrings("audit log unavailable", errorMessage(error.AuditLogFull));

    // Timeout errors
    try std.testing.expectEqualStrings("policy evaluation timeout", errorMessage(error.PolicyTimeout));
    try std.testing.expectEqualStrings("authentication timeout", errorMessage(error.AuthTimeout));

    // Unknown error
    try std.testing.expectEqualStrings("unknown error", errorMessage(error.FileNotFound));
}

test "AgentGateError: error messages don't leak internals" {
    // These internal errors should return generic messages
    try std.testing.expectEqualStrings("service temporarily unavailable", errorMessage(error.AllocatorFailed));
    try std.testing.expectEqualStrings("audit log overflow", errorMessage(error.RingBufferOverflow));
}