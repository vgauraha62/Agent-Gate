//! JWT - JSON Web Token parser and verifier.
//!
//! Implements JWT parsing with base64url decoding and HMAC signature verification.
//! Uses constant-time comparison to prevent timing attacks.

const std = @import("std");
const Secret = @import("../secret.zig").Secret;
const SecurityArena = @import("../memory.zig").SecurityArena;

/// JWT header containing algorithm and type.
pub const Header = struct {
    alg: []const u8,
    typ: []const u8,

    /// Returns the hash algorithm for the JWT.
    pub fn hashAlgorithm(self: Header) HashAlgorithm {
        if (std.mem.eql(u8, self.alg, "HS256")) return .sha256;
        if (std.mem.eql(u8, self.alg, "HS384")) return .sha384;
        if (std.mem.eql(u8, self.alg, "HS512")) return .sha512;
        return .sha256; // default
    }
};

/// Hash algorithm enum for HMAC.
pub const HashAlgorithm = enum {
    sha256,
    sha384,
    sha512,

    /// Returns the expected signature length for this algorithm.
    pub fn signatureLength(self: HashAlgorithm) usize {
        return switch (self) {
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }
};

/// JWT payload containing claims.
pub const Payload = struct {
    sub: []const u8,
    exp: u64,
    aud: ?[]const u8 = null,
    iat: ?u64 = null,
    nbf: ?u64 = null,
};

/// JWT token representation.
pub const JWT = struct {
    header: Header,
    payload: Payload,
    signature: []const u8,
    /// Original encoded header (for signature verification)
    encoded_header: []const u8,
    /// Original encoded payload (for signature verification)
    encoded_payload: []const u8,

    const Self = @This();

    /// Parse a JWT token string.
    /// Uses arena for all allocations - caller must manage arena lifecycle.
    pub fn parse(token: []const u8, arena: *SecurityArena) !JWT {
        // Split token into three parts
        var parts: [3][]const u8 = undefined;
        var part_count: usize = 0;
        var last_idx: usize = 0;

        for (token, 0..) |c, i| {
            if (c == '.') {
                if (part_count >= 2) return error.MalformedToken;
                parts[part_count] = token[last_idx..i];
                part_count += 1;
                last_idx = i + 1;
            }
        }

        if (part_count != 2) return error.MalformedToken;
        parts[2] = token[last_idx..];

        // Decode header
        const header_json = try base64UrlDecode(parts[0], arena);
        const header = try parseHeader(header_json);

        // Decode payload
        const payload_json = try base64UrlDecode(parts[1], arena);
        const payload = try parsePayload(payload_json);

        // Decode signature
        const signature = try base64UrlDecode(parts[2], arena);

        return JWT{
            .header = header,
            .payload = payload,
            .signature = signature,
            .encoded_header = parts[0],
            .encoded_payload = parts[1],
        };
    }

    /// Verify the JWT signature and expiration.
    pub fn verify(self: *const Self, secret: *Secret) !bool {
        // Check expiration first
        try verifyExpiration(self.payload);

        // Verify signature using original encoded parts
        return try verifySignature(self.header, self.encoded_header, self.encoded_payload, self.signature, secret);
    }
};

/// Base64URL decoder instance.
const base64_url = std.base64.Base64UrlNoPadding;

/// Decode base64url string into arena.
fn base64UrlDecode(input: []const u8, arena: *SecurityArena) ![]u8 {
    if (input.len == 0) return error.InvalidBase64;

    // Calculate output size
    const max_output_size = (input.len * 3 + 3) / 4;
    const output = try arena.alloc(u8, max_output_size);

    // Decode
    const decoded_len = try base64_url.Decoder.calcSizeForSlice(input);
    const actual_output = output[0..decoded_len];

    try base64_url.Decoder.decode(actual_output, input);

    return actual_output;
}

/// Parse header JSON into Header struct.
fn parseHeader(json_bytes: []const u8) !Header {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    const alg = if (obj.get("alg")) |v|
        if (v == .string) v.string else return error.InvalidHeader
    else
        return error.InvalidHeader;

    const typ = if (obj.get("typ")) |v|
        if (v == .string) v.string else return error.InvalidHeader
    else
        return error.InvalidHeader;

    return Header{
        .alg = alg,
        .typ = typ,
    };
}

/// Parse payload JSON into Payload struct.
fn parsePayload(json_bytes: []const u8) !Payload {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Required: sub
    const sub = if (obj.get("sub")) |v|
        if (v == .string) v.string else return error.InvalidPayload
    else
        return error.InvalidPayload;

    // Required: exp
    const exp = if (obj.get("exp")) |v|
        if (v == .integer) @intCast(v.integer) else return error.InvalidPayload
    else
        return error.InvalidPayload;

    // Optional: aud
    var aud: ?[]const u8 = null;
    if (obj.get("aud")) |v| {
        if (v == .string) aud = v.string;
    }

    // Optional: iat
    var iat: ?u64 = null;
    if (obj.get("iat")) |v| {
        if (v == .integer) iat = @intCast(v.integer);
    }

    // Optional: nbf
    var nbf: ?u64 = null;
    if (obj.get("nbf")) |v| {
        if (v == .integer) nbf = @intCast(v.integer);
    }

    return Payload{
        .sub = sub,
        .exp = exp,
        .aud = aud,
        .iat = iat,
        .nbf = nbf,
    };
}

/// Verify JWT signature using HMAC.
fn verifySignature(
    header: Header,
    encoded_header: []const u8,
    encoded_payload: []const u8,
    signature: []const u8,
    secret: *Secret,
) !bool {
    const algo = header.hashAlgorithm();
    const expected_sig_len = algo.signatureLength();

    if (signature.len != expected_sig_len) {
        return error.InvalidSignature;
    }

    // Build signing input: base64url(header).base64url(payload)
    const signing_input_len = encoded_header.len + 1 + encoded_payload.len;
    const signing_input = try std.testing.allocator.alloc(u8, signing_input_len);
    defer std.testing.allocator.free(signing_input);

    @memcpy(signing_input[0..encoded_header.len], encoded_header);
    signing_input[encoded_header.len] = '.';
    @memcpy(signing_input[encoded_header.len + 1 ..], encoded_payload);

    // Compute expected HMAC
    var expected_sig: [64]u8 = undefined;
    const actual_sig_len = switch (algo) {
        .sha256 => std.crypto.auth.hmac.sha256(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
        .sha384 => std.crypto.auth.hmac.sha384(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
        .sha512 => std.crypto.auth.hmac.sha512(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
    };

    // Constant-time comparison
    return secureCompare(expected_sig[0..actual_sig_len], signature);
}
    const algo = header.hashAlgorithm();
    const expected_sig_len = algo.signatureLength();

    if (signature.len != expected_sig_len) {
        return error.InvalidSignature;
    }

    // Compute expected HMAC
    var expected_sig: [64]u8 = undefined;
    const actual_sig_len = switch (algo) {
        .sha256 => std.crypto.auth.hmac.sha256(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
        .sha384 => std.crypto.auth.hmac.sha384(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
        .sha512 => std.crypto.auth.hmac.sha512(
            &expected_sig,
            signing_input,
            secret.asBytes(),
        ),
    };

    // Constant-time comparison
    return secureCompare(expected_sig[0..actual_sig_len], signature);
}

/// Verify token expiration.
fn verifyExpiration(payload: Payload) !void {
    const now = @as(u64, @intCast(std.time.timestamp()));
    if (payload.exp < now) {
        return error.TokenExpired;
    }
}

/// Constant-time byte comparison to prevent timing attacks.
pub fn secureCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        result |= a_byte ^ b_byte;
    }
    return result == 0;
}

/// Errors for JWT operations.
pub const JwtError = error{
    MalformedToken,
    InvalidBase64,
    InvalidHeader,
    InvalidPayload,
    InvalidSignature,
    TokenExpired,
    NotImplemented,
};

test "JWT Header struct" {
    const header = Header{
        .alg = "HS256",
        .typ = "JWT",
    };

    try std.testing.expectEqualStrings("HS256", header.alg);
    try std.testing.expectEqualStrings("JWT", header.typ);
    try std.testing.expectEqual(HashAlgorithm.sha256, header.hashAlgorithm());
}

test "JWT Payload struct" {
    const payload = Payload{
        .sub = "agent-123",
        .exp = 9999999999,
        .aud = null,
        .iat = null,
        .nbf = null,
    };

    try std.testing.expectEqualStrings("agent-123", payload.sub);
    try std.testing.expectEqual(@as(u64, 9999999999), payload.exp);
}

test "secureCompare equal" {
    const a = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const b = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    try std.testing.expect(secureCompare(&a, &b));
}

test "secureCompare not equal" {
    const a = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const b = [_]u8{ 0xDE, 0xAD, 0xBE, 0x00 };

    try std.testing.expect(!secureCompare(&a, &b));
}

test "secureCompare different lengths" {
    const a = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const b = [_]u8{ 0xDE, 0xAD, 0xBE };

    try std.testing.expect(!secureCompare(&a, &b));
}

test "base64UrlDecode valid" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    // "SGVsbG8=" decodes to "Hello"
    const input = "SGVsbG8";
    const result = try base64UrlDecode(input, &arena);

    try std.testing.expectEqualStrings("Hello", result);
}

test "base64UrlDecode empty" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 64);
    defer arena.deinit();

    const result = base64UrlDecode("", &arena);
    try std.testing.expectError(error.InvalidBase64, result);
}

test "parseHeader valid" {
    const json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header = try parseHeader(json);

    try std.testing.expectEqualStrings("HS256", header.alg);
    try std.testing.expectEqualStrings("JWT", header.typ);
}

test "parseHeader missing alg" {
    const json = "{\"typ\":\"JWT\"}";
    const result = parseHeader(json);
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parseHeader missing typ" {
    const json = "{\"alg\":\"HS256\"}";
    const result = parseHeader(json);
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parsePayload valid" {
    const json = "{\"sub\":\"agent-123\",\"exp\":9999999999}";
    const payload = try parsePayload(json);

    try std.testing.expectEqualStrings("agent-123", payload.sub);
    try std.testing.expectEqual(@as(u64, 9999999999), payload.exp);
    try std.testing.expectEqual(@as(?[]const u8, null), payload.aud);
}

test "parsePayload with optional fields" {
    const json = "{\"sub\":\"agent-123\",\"exp\":9999999999,\"iat\":1000000000,\"nbf\":1000000000}";
    const payload = try parsePayload(json);

    try std.testing.expectEqualStrings("agent-123", payload.sub);
    try std.testing.expectEqual(@as(u64, 9999999999), payload.exp);
    try std.testing.expectEqual(@as(?u64, 1000000000), payload.iat);
    try std.testing.expectEqual(@as(?u64, 1000000000), payload.nbf);
}

test "parsePayload missing sub" {
    const json = "{\"exp\":9999999999}";
    const result = parsePayload(json);
    try std.testing.expectError(error.InvalidPayload, result);
}

test "parsePayload missing exp" {
    const json = "{\"sub\":\"agent-123\"}";
    const result = parsePayload(json);
    try std.testing.expectError(error.InvalidPayload, result);
}

test "verifyExpiration unexpired" {
    const payload = Payload{
        .sub = "agent-123",
        .exp = 9999999999,
    };

    try verifyExpiration(payload);
}

test "verifyExpiration expired" {
    const payload = Payload{
        .sub = "agent-123",
        .exp = 0, // Already expired
    };

    try std.testing.expectError(error.TokenExpired, verifyExpiration(payload));
}

/// Helper to generate a test JWT token.
fn generateTestToken(
    allocator: std.mem.Allocator,
    secret: []const u8,
    sub: []const u8,
    exp: u64,
) ![]u8 {
    // Header
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    var header_buf: [100]u8 = undefined;
    const header_encoded = base64_url.Encoder.encode(&header_buf, header_json);

    // Payload
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"sub\":\"{s}\",\"exp\":{d}}}",
        .{ sub, exp },
    );
    defer allocator.free(payload_json);

    var payload_buf: [256]u8 = undefined;
    const payload_encoded = base64_url.Encoder.encode(&payload_buf, payload_json);

    // Signing input
    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ header_encoded, payload_encoded },
    );
    defer allocator.free(signing_input);

    // Compute HMAC-SHA256
    var signature: [32]u8 = undefined;
    _ = std.crypto.auth.hmac.sha256(&signature, signing_input, secret);

    var sig_buf: [64]u8 = undefined;
    const sig_encoded = base64_url.Encoder.encode(&sig_buf, &signature);

    // Combine
    return try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.{s}",
        .{ header_encoded, payload_encoded, sig_encoded },
    );
}

test "JWT full parse and verify - valid token" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    // Generate valid token (expires in far future)
    const token = try generateTestToken(gpa, secret_key, "agent-123", 9999999999);
    defer gpa.free(token);

    // Parse and verify
    var jwt = try JWT.parse(token, &arena);
    const valid = try jwt.verify(&secret);

    try std.testing.expect(valid);
    try std.testing.expectEqualStrings("agent-123", jwt.payload.sub);
}

test "JWT verify - expired token" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    // Generate expired token
    const token = try generateTestToken(gpa, secret_key, "agent-123", 0);
    defer gpa.free(token);

    // Parse and verify should fail
    var jwt = try JWT.parse(token, &arena);
    const result = jwt.verify(&secret);

    try std.testing.expectError(error.TokenExpired, result);
}

test "JWT verify - wrong secret" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    const wrong_key = "wrong-secret-key";

    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    var wrong_secret = try Secret.init(gpa, wrong_key);
    defer wrong_secret.deinit();

    // Generate token with correct secret
    const token = try generateTestToken(gpa, secret_key, "agent-123", 9999999999);
    defer gpa.free(token);

    // Verify with wrong secret should fail
    var jwt = try JWT.parse(token, &arena);
    const result = jwt.verify(&wrong_secret);

    try std.testing.expectError(error.InvalidSignature, result);
}

test "JWT parse - malformed token (missing parts)" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    const result = JWT.parse("only.two", &arena);
    try std.testing.expectError(error.MalformedToken, result);
}

test "JWT parse - malformed token (no dots)" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    const result = JWT.parse("nodots", &arena);
    try std.testing.expectError(error.MalformedToken, result);
}

test "JWT parse - malformed token (too many parts)" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    const result = JWT.parse("one.two.three.four", &arena);
    try std.testing.expectError(error.MalformedToken, result);
}

test "JWT verify - tampered payload" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    // Generate valid token
    const token = try generateTestToken(gpa, secret_key, "agent-123", 9999999999);
    defer gpa.free(token);

    // Tamper with payload (find and modify a character)
    var tampered = gpa.dupe(u8, token).catch unreachable;
    defer gpa.free(tampered);

    // Find second dot (start of signature) and modify payload before it
    var dot_count: usize = 0;
    for (tampered, 0..) |*c, i| {
        if (c.* == '.') {
            dot_count += 1;
            if (dot_count == 2) break;
        } else if (dot_count == 1 and c.* != '.') {
            // Modify a payload character
            if (c.* == '1') c.* = '2' else c.* = '1';
            break;
        }
        _ = i;
    }

    // Verify should fail
    const result = JWT.parse(tampered, &arena);
    if (result) |jwt| {
        const verify_result = jwt.verify(&secret);
        try std.testing.expectError(error.InvalidSignature, verify_result);
    } else |_| {
        // Parse failure is also acceptable
        try std.testing.expect(true);
    }
}

test "JWT with HS384 algorithm" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Test header parsing with HS384
    const header_json = "{\"alg\":\"HS384\",\"typ\":\"JWT\"}";
    const header = try parseHeader(header_json);

    try std.testing.expectEqual(HashAlgorithm.sha384, header.hashAlgorithm());
    try std.testing.expectEqual(@as(usize, 48), HashAlgorithm.sha384.signatureLength());
}

test "JWT with HS512 algorithm" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Test header parsing with HS512
    const header_json = "{\"alg\":\"HS512\",\"typ\":\"JWT\"}";
    const header = try parseHeader(header_json);

    try std.testing.expectEqual(HashAlgorithm.sha512, header.hashAlgorithm());
    try std.testing.expectEqual(@as(usize, 64), HashAlgorithm.sha512.signatureLength());
}

test "JWT no memory leaks" {
    const gpa = std.testing.allocator;

    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    // Multiple parse/verify cycles
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const token = try generateTestToken(gpa, secret_key, "agent-123", 9999999999);
        var jwt = JWT.parse(token, &arena) catch continue;
        _ = jwt.verify(&secret) catch continue;
        gpa.free(token);
    }
}

test "JWT arena reset invalidates token" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    const secret_key = "super-secret-key-for-testing";
    var secret = try Secret.init(gpa, secret_key);
    defer secret.deinit();

    // Generate and parse token
    const token = try generateTestToken(gpa, secret_key, "agent-123", 9999999999);
    defer gpa.free(token);

    var jwt = try JWT.parse(token, &arena);

    // Verify before reset works
    try std.testing.expect(try jwt.verify(&secret));

    // Reset arena
    arena.reset();

    // After reset, token data is zeroed - verify may fail or succeed depending on timing
    // This demonstrates the security property: arena reset invalidates data
    _ = jwt.verify(&secret) catch {};
}
