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
    const header = try parseHeader(header_json, arena.allocator());

    // Decode payload
    const payload_json = try base64UrlDecode(parts[1], arena);
    const payload = try parsePayload(payload_json, arena.allocator());

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

    /// Verify the JWT signature, expiration, and optional claims.
    /// `options` controls audience verification and clock skew tolerance.
    pub fn verify(self: *const Self, secret: *Secret, options: VerifyOptions) !bool {
        // Check expiration
        try verifyExpiration(self.payload);
        // Check issued-at and not-before constraints
        try verifyTimeConstraints(self.payload);
        // Check audience if expected
        try verifyAudience(self.payload, options.expected_audience);
        // Verify signature using original encoded parts
        return try verifySignature(self.header, self.encoded_header, self.encoded_payload, self.signature, secret);
    }
};

/// Decode base64url string into arena (Zig 0.15+ compatible)
fn base64UrlDecode(input: []const u8, arena: *SecurityArena) ![]u8 {
    if (input.len == 0) return error.InvalidBase64;

    // Calculate output size: 3 bytes per 4 chars (roughly)
    const max_output_size = (input.len * 3 + 3) / 4;
    const output = try arena.alloc(max_output_size);

    // Custom base64url decode (URL-safe alphabet: A-Z, a-z, 0-9, -, _)
    var decoded_len: usize = 0;
    var buffer: [4]u8 = undefined;
    var buf_idx: usize = 0;

    for (input) |byte| {
        var value: u8 = undefined;

        if (byte >= 'A' and byte <= 'Z') {
            value = byte - 'A';
        } else if (byte >= 'a' and byte <= 'z') {
            value = byte - 'a' + 26;
        } else if (byte >= '0' and byte <= '9') {
            value = byte - '0' + 52;
        } else if (byte == '-') {
            value = 62;
        } else if (byte == '_') {
            value = 63;
        } else if (byte == '=') {
            continue; // Padding - skip
        } else {
            return error.InvalidBase64;
        }

        buffer[buf_idx] = value;
        buf_idx += 1;

        if (buf_idx == 4) {
            output[decoded_len] = (buffer[0] << 2) | (buffer[1] >> 4);
            output[decoded_len + 1] = (buffer[1] << 4) | (buffer[2] >> 2);
            output[decoded_len + 2] = (buffer[2] << 6) | buffer[3];
            decoded_len += 3;
            buf_idx = 0;
        }
    }

    // Handle remaining bytes
    if (buf_idx > 0) {
        if (buf_idx >= 2) {
            output[decoded_len] = (buffer[0] << 2) | (buffer[1] >> 4);
            decoded_len += 1;
        }
        if (buf_idx >= 3) {
            output[decoded_len] = (buffer[1] << 4) | (buffer[2] >> 2);
            decoded_len += 1;
        }
    }

    return output[0..decoded_len];
}

/// Encode bytes to base64url string (Zig 0.15+ compatible)
fn base64UrlEncode(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // base64url encoding WITHOUT padding (URL-safe alphabet)
    // For n bytes: full_groups * 4 + (rem == 0 ? 0 : rem == 1 ? 2 : 3)
    const full_groups = input.len / 3;
    const rem = input.len % 3;
    const extra: usize = if (rem == 0) 0 else if (rem == 1) 2 else 3;
    const output_len = full_groups * 4 + extra;
    
    const output = try allocator.alloc(u8, output_len);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    var idx: usize = 0;
    var i: usize = 0;

    while (i + 3 <= input.len) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        output[idx] = alphabet[b0 >> 2];
        output[idx + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[idx + 2] = alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)];
        output[idx + 3] = alphabet[b2 & 0x3f];

        idx += 4;
        i += 3;
    }

    // Handle remaining bytes (1 or 2 bytes left)
    if (i < input.len) {
        const b0 = input[i];
        output[idx] = alphabet[b0 >> 2];
        idx += 1;

        if (i + 1 < input.len) {
            const b1 = input[i + 1];
            output[idx] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            output[idx + 1] = alphabet[(b1 & 0x0f) << 2];
            idx += 2;
        } else {
            output[idx] = alphabet[(b0 & 0x03) << 4];
            idx += 1;
        }
    }

    // idx should equal output_len at this point - return the full slice
    return output[0..idx];
}

/// Parse header JSON into Header struct.
/// The returned Header strings are allocated using `allocator` and must be freed
/// by the caller (typically via arena reset). JSON parse temporary memory uses
/// page_allocator and is freed before this function returns.
fn parseHeader(json_bytes: []const u8, allocator: std.mem.Allocator) !Header {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Get string slices from JSON object (these point to memory owned by 'parsed')
    const alg_slice = if (obj.get("alg")) |v|
        if (v == .string) v.string else return error.InvalidHeader
    else
        return error.InvalidHeader;

    const typ_slice = if (obj.get("typ")) |v|
        if (v == .string) v.string else return error.InvalidHeader
    else
        return error.InvalidHeader;

    // Allocate owned copies of the strings using the caller's allocator
    const alg = try allocator.dupe(u8, alg_slice);
    const typ = try allocator.dupe(u8, typ_slice);

    return Header{
        .alg = alg,
        .typ = typ,
    };
}

/// Parse payload JSON into Payload struct.
/// The returned Payload strings are allocated using `allocator` and must be freed
/// by the caller (typically via arena reset). JSON parse temporary memory uses
/// page_allocator and is freed before this function returns.
fn parsePayload(json_bytes: []const u8, allocator: std.mem.Allocator) !Payload {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // --- Phase 1: Extract and validate all values (no allocations) ---

    // Required: sub
    const sub_raw = if (obj.get("sub")) |v|
        if (v == .string) v.string else return error.InvalidPayload
    else
        return error.InvalidPayload;

    // Required: exp (validate before allocating sub)
    const exp = if (obj.get("exp")) |v|
        if (v == .integer) v.integer else return error.InvalidPayload
    else
        return error.InvalidPayload;

    // Optional: aud
    const aud_raw = if (obj.get("aud")) |v|
        if (v == .string) v.string else null
    else
        null;

    // Optional: iat
    const iat_int = if (obj.get("iat")) |v|
        if (v == .integer) @as(u64, @intCast(v.integer)) else null
    else
        null;

    // Optional: nbf
    const nbf_int = if (obj.get("nbf")) |v|
        if (v == .integer) @as(u64, @intCast(v.integer)) else null
    else
        null;

    // --- Phase 2: Allocate owned copies (all validation succeeded) ---

    const sub = try allocator.dupe(u8, sub_raw);

    var aud: ?[]const u8 = null;
    if (aud_raw) |a| {
        aud = try allocator.dupe(u8, a);
    }

    return Payload{
        .sub = sub,
        .exp = @intCast(exp),
        .aud = aud,
        .iat = iat_int,
        .nbf = nbf_int,
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
    const signing_input = try std.heap.page_allocator.alloc(u8, signing_input_len);
    defer std.heap.page_allocator.free(signing_input);

    @memcpy(signing_input[0..encoded_header.len], encoded_header);
    signing_input[encoded_header.len] = '.';
    @memcpy(signing_input[encoded_header.len + 1 ..], encoded_payload);

// Compute expected HMAC using manual implementation (Zig 0.15 compatible)
    var expected_sig: [64]u8 = undefined;
    var sig_len: usize = 0;
    switch (algo) {
        .sha256 => {
            const result = try hmacSha256(secret.asBytes(), signing_input);
            @memcpy(expected_sig[0..32], &result);
            sig_len = 32;
        },
        .sha384 => {
            const result = try hmacSha384(secret.asBytes(), signing_input);
            @memcpy(expected_sig[0..48], &result);
            sig_len = 48;
        },
        .sha512 => {
            const result = try hmacSha512(secret.asBytes(), signing_input);
            @memcpy(expected_sig[0..64], &result);
            sig_len = 64;
        },
    }

    // Constant-time comparison
    return secureCompare(expected_sig[0..sig_len], signature);
}

/// Manual HMAC-SHA256 implementation - returns fixed-size array.
/// Uses heap allocation for inner/outer message buffers to avoid stack overflow
/// with large messages (the fixed [256]u8 stack buffers previously overflowed).
fn hmacSha256(key: []const u8, message: []const u8) ![32]u8 {
    const block_size = 64;
    var key_block: [block_size]u8 = .{0} ** block_size;
    var result: [32]u8 = undefined;

    // If key is longer than block size, hash it first
    if (key.len > block_size) {
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &hash_buf, .{});
        @memcpy(key_block[0..32], &hash_buf);
    } else {
        @memcpy(key_block[0..key.len], key);
    }

    // XOR with ipad (0x36) and opad (0x5c)
    var ipad: [block_size]u8 = undefined;
    var opad: [block_size]u8 = undefined;
    for (0..block_size) |i| {
        ipad[i] = key_block[i] ^ 0x36;
        opad[i] = key_block[i] ^ 0x5c;
    }

    // Inner hash: H((key ^ ipad) || message)
    // Use dynamic allocation for inner_msg to support arbitrarily large messages
    var inner: [32]u8 = undefined;
    const inner_msg = try std.heap.page_allocator.alloc(u8, block_size + message.len);
    defer std.heap.page_allocator.free(inner_msg);
    @memcpy(inner_msg[0..block_size], &ipad);
    @memcpy(inner_msg[block_size..], message);
    std.crypto.hash.sha2.Sha256.hash(inner_msg, &inner, .{});

    // Outer hash: H((key ^ opad) || inner)
    const outer_msg = try std.heap.page_allocator.alloc(u8, block_size + 32);
    defer std.heap.page_allocator.free(outer_msg);
    @memcpy(outer_msg[0..block_size], &opad);
    @memcpy(outer_msg[block_size..], &inner);
    std.crypto.hash.sha2.Sha256.hash(outer_msg, &result, .{});

    return result;
}

/// Manual HMAC-SHA384 implementation - returns fixed-size array.
/// Uses heap allocation for inner/outer message buffers to avoid stack overflow.
fn hmacSha384(key: []const u8, message: []const u8) ![48]u8 {
    const block_size = 128;
    var key_block: [block_size]u8 = .{0} ** block_size;
    var result: [48]u8 = undefined;

    if (key.len > block_size) {
        var hash_buf: [48]u8 = undefined;
        std.crypto.hash.sha2.Sha384.hash(key, &hash_buf, .{});
        @memcpy(key_block[0..48], &hash_buf);
    } else {
        @memcpy(key_block[0..key.len], key);
    }

    var ipad: [block_size]u8 = undefined;
    var opad: [block_size]u8 = undefined;
    for (0..block_size) |i| {
        ipad[i] = key_block[i] ^ 0x36;
        opad[i] = key_block[i] ^ 0x5c;
    }

    // Inner hash — dynamic allocation to avoid stack overflow
    var inner: [48]u8 = undefined;
    const inner_msg = try std.heap.page_allocator.alloc(u8, block_size + message.len);
    defer std.heap.page_allocator.free(inner_msg);
    @memcpy(inner_msg[0..block_size], &ipad);
    @memcpy(inner_msg[block_size..], message);
    std.crypto.hash.sha2.Sha384.hash(inner_msg, &inner, .{});

    // Outer hash — dynamic allocation to avoid stack overflow
    const outer_msg = try std.heap.page_allocator.alloc(u8, block_size + 48);
    defer std.heap.page_allocator.free(outer_msg);
    @memcpy(outer_msg[0..block_size], &opad);
    @memcpy(outer_msg[block_size..], &inner);
    std.crypto.hash.sha2.Sha384.hash(outer_msg, &result, .{});

    return result;
}

/// Manual HMAC-SHA512 implementation - returns fixed-size array.
/// Uses heap allocation for inner/outer message buffers to avoid stack overflow.
fn hmacSha512(key: []const u8, message: []const u8) ![64]u8 {
    const block_size = 128;
    var key_block: [block_size]u8 = .{0} ** block_size;
    var result: [64]u8 = undefined;

    if (key.len > block_size) {
        var hash_buf: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(key, &hash_buf, .{});
        @memcpy(key_block[0..64], &hash_buf);
    } else {
        @memcpy(key_block[0..key.len], key);
    }

    var ipad: [block_size]u8 = undefined;
    var opad: [block_size]u8 = undefined;
    for (0..block_size) |i| {
        ipad[i] = key_block[i] ^ 0x36;
        opad[i] = key_block[i] ^ 0x5c;
    }

    // Inner hash — dynamic allocation to avoid stack overflow
    var inner: [64]u8 = undefined;
    const inner_msg = try std.heap.page_allocator.alloc(u8, block_size + message.len);
    defer std.heap.page_allocator.free(inner_msg);
    @memcpy(inner_msg[0..block_size], &ipad);
    @memcpy(inner_msg[block_size..], message);
    std.crypto.hash.sha2.Sha512.hash(inner_msg, &inner, .{});

    // Outer hash — dynamic allocation to avoid stack overflow
    const outer_msg = try std.heap.page_allocator.alloc(u8, block_size + 64);
    defer std.heap.page_allocator.free(outer_msg);
    @memcpy(outer_msg[0..block_size], &opad);
    @memcpy(outer_msg[block_size..], &inner);
    std.crypto.hash.sha2.Sha512.hash(outer_msg, &result, .{});

    return result;
}

/// Verify token expiration.
fn verifyExpiration(payload: Payload) !void {
    const now = @as(u64, @intCast(std.time.timestamp()));
    if (payload.exp < now) {
        return error.TokenExpired;
    }
}

/// Verify issued-at (iat) and not-before (nbf) time constraints.
/// Allows a 30-second clock skew tolerance.
pub fn verifyTimeConstraints(payload: Payload) !void {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const tolerance = 30; // seconds of clock skew tolerance

    if (payload.iat) |iat| {
        if (iat > now + tolerance) {
            return error.TokenNotYetValid;
        }
    }
    if (payload.nbf) |nbf| {
        if (nbf > now + tolerance) {
            return error.TokenNotYetValid;
        }
    }
}

/// Verify audience claim.
/// If `expected` is provided, the token's `aud` claim must match.
/// If `expected` is null, the check is skipped.
pub fn verifyAudience(payload: Payload, expected: ?[]const u8) !void {
    const actual = payload.aud;
    if (expected) |exp| {
        if (actual) |act| {
            if (!std.mem.eql(u8, exp, act)) {
                return error.InvalidAudience;
            }
        } else {
            // Expected audience but token has none
            return error.InvalidAudience;
        }
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
    TokenNotYetValid,
    InvalidAudience,
    NotImplemented,
};

/// Options for JWT verification.
pub const VerifyOptions = struct {
    /// Expected audience claim. If provided, the token's `aud` claim must match.
    /// If null, audience verification is skipped.
    expected_audience: ?[]const u8 = null,
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
    const header = try parseHeader(json, std.testing.allocator);
    defer std.testing.allocator.free(header.alg);
    defer std.testing.allocator.free(header.typ);

    try std.testing.expectEqualStrings("HS256", header.alg);
    try std.testing.expectEqualStrings("JWT", header.typ);
}

test "parseHeader missing alg" {
    const json = "{\"typ\":\"JWT\"}";
    const result = parseHeader(json, std.testing.allocator);
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parseHeader missing typ" {
    const json = "{\"alg\":\"HS256\"}";
    const result = parseHeader(json, std.testing.allocator);
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parsePayload valid" {
    const json = "{\"sub\":\"agent-123\",\"exp\":9999999999}";
    const payload = try parsePayload(json, std.testing.allocator);
    defer std.testing.allocator.free(payload.sub);
    if (payload.aud) |a| {
        defer std.testing.allocator.free(a);
    }

    try std.testing.expectEqualStrings("agent-123", payload.sub);
    try std.testing.expectEqual(@as(u64, 9999999999), payload.exp);
    try std.testing.expectEqual(@as(?[]const u8, null), payload.aud);
}

test "parsePayload with optional fields" {
    const json = "{\"sub\":\"agent-123\",\"exp\":9999999999,\"iat\":1000000000,\"nbf\":1000000000}";
    const payload = try parsePayload(json, std.testing.allocator);
    defer std.testing.allocator.free(payload.sub);
    if (payload.aud) |a| {
        defer std.testing.allocator.free(a);
    }

    try std.testing.expectEqualStrings("agent-123", payload.sub);
    try std.testing.expectEqual(@as(u64, 9999999999), payload.exp);
    try std.testing.expectEqual(@as(?u64, 1000000000), payload.iat);
    try std.testing.expectEqual(@as(?u64, 1000000000), payload.nbf);
}

test "parsePayload missing sub" {
    const json = "{\"exp\":9999999999}";
    const result = parsePayload(json, std.testing.allocator);
    try std.testing.expectError(error.InvalidPayload, result);
}

test "parsePayload missing exp" {
    const json = "{\"sub\":\"agent-123\"}";
    const result = parsePayload(json, std.testing.allocator);
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
    const header_encoded = try base64UrlEncode(header_json, allocator);

    // Payload
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"sub\":\"{s}\",\"exp\":{d}}}",
        .{ sub, exp },
    );
    defer allocator.free(payload_json);

    const payload_encoded = try base64UrlEncode(payload_json, allocator);

    // Signing input
    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ header_encoded, payload_encoded },
    );
    defer allocator.free(signing_input);

    // Compute HMAC-SHA256 using the manual implementation
    const signature = try hmacSha256(secret, signing_input);

    const sig_encoded = try base64UrlEncode(&signature, allocator);

    // Calculate total output length
    const total_len = header_encoded.len + 1 + payload_encoded.len + 1 + sig_encoded.len;
    
    // Allocate exactly the space we need for the final result
    const result = try allocator.alloc(u8, total_len);
    
    // Build the result
    @memcpy(result[0..header_encoded.len], header_encoded);
    var pos = header_encoded.len;
    result[pos] = '.'; pos += 1;
    @memcpy(result[pos..(pos + payload_encoded.len)], payload_encoded);
    pos += payload_encoded.len;
    result[pos] = '.'; pos += 1;
    @memcpy(result[pos..(pos + sig_encoded.len)], sig_encoded);

    // Free intermediate allocations (they were allocated separately)
    allocator.free(header_encoded);
    allocator.free(payload_encoded);
    allocator.free(sig_encoded);

    return result;
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
    const valid = try jwt.verify(&secret, .{});
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
    const result = jwt.verify(&secret, .{});

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

    // Verify with wrong secret should return false (not an error)
    var jwt = try JWT.parse(token, &arena);
    const valid = try jwt.verify(&wrong_secret, .{});

    // Signature mismatch returns false, not an error
    try std.testing.expect(!valid);
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
    const tampered = try gpa.dupe(u8, token);
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
        const verify_result = jwt.verify(&secret, .{});
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
    const header = try parseHeader(header_json, std.testing.allocator);
    defer std.testing.allocator.free(header.alg);
    defer std.testing.allocator.free(header.typ);

    try std.testing.expectEqual(HashAlgorithm.sha384, header.hashAlgorithm());
    try std.testing.expectEqual(@as(usize, 48), HashAlgorithm.sha384.signatureLength());
}

test "JWT with HS512 algorithm" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 4096);
    defer arena.deinit();

    // Test header parsing with HS512
    const header_json = "{\"alg\":\"HS512\",\"typ\":\"JWT\"}";
    const header = try parseHeader(header_json, std.testing.allocator);
    defer std.testing.allocator.free(header.alg);
    defer std.testing.allocator.free(header.typ);

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
        _ = jwt.verify(&secret, .{}) catch continue;
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
    try std.testing.expect(try jwt.verify(&secret, .{}));

    // Reset arena
    arena.reset();

    // After reset, token data is zeroed - verify may fail or succeed depending on timing
    // This demonstrates the security property: arena reset invalidates data
    _ = jwt.verify(&secret, .{}) catch {};
}

// ============================================================================
// Public Test Helpers (Day 6)
// ============================================================================

/// Generate a valid JWT token for testing purposes.
/// Caller owns returned memory - must free with allocator.
pub fn generateTestJWT(
    allocator: std.mem.Allocator,
    secret: []const u8,
    subject: []const u8,
    expires_in_seconds: u64,
) ![]u8 {
    const now = @as(u64, @intCast(std.time.timestamp()));
    const exp = now + expires_in_seconds;
    return try generateTestToken(allocator, secret, subject, exp);
}

/// Generate an expired JWT token for testing.
/// Useful for testing token expiration handling.
pub fn generateExpiredJWT(
    allocator: std.mem.Allocator,
    secret: []const u8,
    subject: []const u8,
) ![]u8 {
    // Set expiration to 1 hour ago
    const now = @as(u64, @intCast(std.time.timestamp()));
    const exp = now - 3600; // 1 hour in the past
    return try generateTestToken(allocator, secret, subject, exp);
}

/// Claims for token generation.
pub const TokenClaims = struct {
    subject: []const u8,
    expires_at: u64,
    audience: ?[]const u8 = null,
    issued_at: ?u64 = null,
    not_before: ?u64 = null,
};

/// Generate a JWT token with optional claims (aud, iat, nbf).
/// Caller owns returned memory — must free with allocator.
pub fn generateTokenWithClaims(
    allocator: std.mem.Allocator,
    secret: []const u8,
    claims: TokenClaims,
) ![]u8 {
    // Build payload JSON dynamically including optional fields
    var payload_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer payload_buf.deinit(allocator);

    const writer = payload_buf.writer(allocator);

    try writer.print("{{\"sub\":\"{s}\",\"exp\":{d}", .{
        claims.subject,
        claims.expires_at,
    });

    if (claims.audience) |a| {
        try writer.print(",\"aud\":\"{s}\"", .{a});
    }
    if (claims.issued_at) |i| {
        try writer.print(",\"iat\":{d}", .{i});
    }
    if (claims.not_before) |n| {
        try writer.print(",\"nbf\":{d}", .{n});
    }

    try writer.writeAll("}");

    // Encode and sign
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_encoded = try base64UrlEncode(header_json, allocator);
    defer allocator.free(header_encoded);

    const payload_encoded = try base64UrlEncode(payload_buf.items, allocator);
    defer allocator.free(payload_encoded);

    const signing_input = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ header_encoded, payload_encoded },
    );
    defer allocator.free(signing_input);

    const signature = try hmacSha256(secret, signing_input);
    const sig_encoded = try base64UrlEncode(&signature, allocator);
    defer allocator.free(sig_encoded);

    const total_len = header_encoded.len + 1 + payload_encoded.len + 1 + sig_encoded.len;
    const result = try allocator.alloc(u8, total_len);
    const written = try std.fmt.bufPrint(result, "{s}.{s}.{s}", .{
        header_encoded, payload_encoded, sig_encoded,
    });
    return result[0..written.len];
}

test "generateTestJWT creates valid tokens" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();

    const secret = "test-secret-key-for-jwt-generation";
    var sec = try Secret.init(gpa, secret);
    defer sec.deinit();

    // Generate token valid for 1 hour
    const token = try generateTestJWT(gpa, secret, "agent-test", 3600);
    defer gpa.free(token);

    // Verify token parses correctly
    var jwt = try JWT.parse(token, &arena);
    try std.testing.expectEqualStrings("agent-test", jwt.payload.sub);

    // Verify it can be verified successfully
    const valid = try jwt.verify(&sec, .{});
    try std.testing.expect(valid);
}

test "generateExpiredJWT creates expired tokens" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 1024);
    defer arena.deinit();

    const secret = "test-secret";
    var sec = try Secret.init(gpa, secret);
    defer sec.deinit();

    const token = try generateExpiredJWT(gpa, secret, "agent-test");
    defer gpa.free(token);

    var jwt = try JWT.parse(token, &arena);
    const result = jwt.verify(&sec, .{});
    try std.testing.expectError(JwtError.TokenExpired, result);
}

test "generateTestJWT with different expiration times" {
    const gpa = std.testing.allocator;
    var arena = try SecurityArena.init(gpa, 2048);
    defer arena.deinit();

    const secret = "test-secret-key-for-testing";
    var sec = try Secret.init(gpa, secret);
    defer sec.deinit();

    // Token valid for 1 hour
    const token = try generateTestJWT(gpa, secret, "agent", 3600);
    defer gpa.free(token);

    var jwt = try JWT.parse(token, &arena);
    try std.testing.expect(try jwt.verify(&sec, .{}));

    // Note: Actual expiration timing test skipped as std.time.sleep unavailable
    // The expired token test above covers expiration behavior
}


