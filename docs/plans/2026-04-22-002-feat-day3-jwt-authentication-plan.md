---
title: 'feat: Day 3 Authentication Engine (JWT)'
type: feat
status: active
date: 2026-04-22
origin: PRD.md (Day 3 specification, lines 187-236)
---

# Day 3: Authentication Engine (JWT)

## Overview

Implement JWT parser and verifier for AgentGate sidecar. Two core components: JWT token parser with base64url decoding, and HMAC signature verifier with constant-time comparison. All tokens validated against Secret-stored keys. Tests cover valid, expired, tampered, and wrong-secret scenarios.

## Problem Frame

JWT authentication requires:
- Safe base64url decoding (no allocation leaks)
- Constant-time signature comparison (timing attack prevention)
- Secure secret key storage (zeroize on deinit)
- Proper expiration checking

Without proper implementation:
- Timing leaks expose secret keys
- Memory leaks under request load
- Token forgery via signature bypass

## Requirements Trace

From PRD.md Day 3 specification:

- R1. JWT struct with header, payload, signature
- R2. Header parsing (alg, typ fields)
- R3. Payload parsing (sub, exp, aud, extra claims)
- R4. HMAC-SHA256/384/512 signature verification
- R5. Constant-time signature comparison
- R6. Expiration check
- R7. Tests: valid, expired, tampered, wrong secret
- R8. Integration with Secret container for key storage

## Scope Boundaries

- JWT parsing and verification only
- HMAC-SHA256/384/512 algorithms supported
- No JWT generation/signing (verification only)
- No JWK/JWKS support (Day 3 scope)
- No mTLS integration (Day 9)

### Deferred to Separate Tasks

- mTLS integration: Day 9, separate PR
- JWK/JWKS support: future iteration
- JWT generation: not needed for sidecar (verify-only)

## Context & Research

### Relevant Code and Patterns

- `src/secret.zig` - Secret container for key storage, zeroize on deinit
- `src/memory.zig` - SecurityArena for request-scoped parsing
- `src/agent.zig` - Agent struct (JWT subject maps to agent ID)
- Zig std.crypto - `std.crypto.hmac` for HMAC verification
- Zig std.base64 - `std.base64.UrlDecoder` for base64url decoding

### Institutional Learnings

- Day 2 established zeroize pattern for sensitive data
- SecurityArena used for all request-scoped allocations
- GPA testing required for leak detection

### External References

- RFC 7519 - JSON Web Token (JWT) specification
- RFC 7515 - JSON Web Signature (JWS)
- Zig std.crypto documentation for HMAC-SHA256/384/512

## Key Technical Decisions

- **HMAC-SHA256 default, SHA384/512 optional**: SHA256 provides 128-bit security, sufficient for most cases. SHA384/512 available for higher security requirements.
- **Base64url decoding into arena**: Prevents allocation leaks, arena reset frees all decoded data at once.
- **Constant-time compare mandatory**: All signature comparisons use `secureCompare()` to prevent timing attacks.
- **Expiration check returns error, not bool**: Expired tokens should fail fast with `error.TokenExpired`, not return false silently.

## Open Questions

### Resolved During Planning

- None - PRD provides clear specifications

### Deferred to Implementation

- Exact error union types (depend on Zig std.crypto API)
- Base64 padding handling (test both with/without padding)

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
┌─────────────────────────────────────────────────────────────┐
│                    JWT Verification Flow                     │
│                                                              │
│  Raw Token: "header.payload.signature"                       │
│       │                                                      │
│       ▼                                                      │
│  ┌─────────────────┐                                        │
│  │ Split by '.'    │                                        │
│  └────────┬────────┘                                        │
│           │                                                  │
│       ┌───┴───┬───────────┐                                 │
│       ▼       ▼           ▼                                 │
│  ┌────────┐ ┌────────┐ ┌──────────┐                        │
│  │ Header │ │Payload │ │Signature │                        │
│  │ base64 │ │ base64 │ │  base64  │                        │
│  │  url   │ │  url   │ │   url    │                        │
│  └───┬────┘ └───┬────┘ └────┬─────┘                        │
│      │          │           │                                │
│      ▼          ▼           ▼                                │
│  ┌─────────────────────────────┐                            │
│  │   Base64URL Decode          │                            │
│  │   (into SecurityArena)      │                            │
│  └───────────┬─────────────────┘                            │
│              │                                               │
│      ┌───────┴───────┐                                      │
│      ▼               ▼                                      │
│  ┌────────┐    ┌─────────────┐                             │
│  │ Header │    │   Payload   │                             │
│  │  alg=  │    │   exp check │                             │
│  │  typ=  │    │   sub, aud  │                             │
│  └────────┘    └─────────────┘                             │
│                          │                                   │
│                          ▼                                   │
│              ┌─────────────────────┐                        │
│              │  HMAC Verification  │                        │
│              │  - Compute HMAC     │                        │
│              │  - secureCompare()  │                        │
│              └──────────┬──────────┘                        │
│                         │                                    │
│              ┌──────────┴──────────┐                        │
│              ▼                     ▼                        │
│         Valid (true)         Invalid (false)                │
│                                error.InvalidSignature        │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Units

- [ ] **U1: JWT Base64URL Decoding**

**Goal:** Implement safe base64url decoding for JWT token parts

**Requirements:** R1, R2, R3

**Dependencies:** Day 2 SecurityArena

**Files:**
- Create: `src/auth/jwt.zig` (base64url decode functions)
- Test: `src/auth/jwt_test.zig` (decode tests)

**Approach:**
- Use `std.base64.UrlDecoder` for base64url decoding
- Decode into SecurityArena buffer (no individual allocations)
- Handle both padded and unpadded base64url input
- Return error for invalid base64 characters

**Patterns to follow:**
- `src/memory.zig` - arena allocation pattern
- `src/secret.zig` - error handling pattern

**Test scenarios:**
- Happy path: Valid base64url decodes correctly
- Edge case: Unpadded base64url (no trailing `=`)
- Edge case: Empty string input
- Error case: Invalid base64 character returns error
- Error case: Truncated padding returns error

**Verification:**
- All decode tests pass
- No memory leaks under GPA

---

- [ ] **U2: JWT Header and Payload Structs**

**Goal:** Define JWT Header and Payload data structures

**Requirements:** R1, R2, R3

**Dependencies:** U1 (decoding)

**Files:**
- Modify: `src/auth/jwt.zig` (Header, Payload structs)
- Test: `src/auth/jwt_test.zig` (struct tests)

**Approach:**
```zig
pub const Header = struct {
    alg: []const u8,  // "HS256", "HS384", "HS512"
    typ: []const u8,  // "JWT"
};

pub const Payload = struct {
    sub: []const u8,      // Subject (agent ID)
    exp: u64,             // Expiration timestamp
    aud: []const u8,      // Audience
    iat: ?u64,            // Issued at (optional)
    nbf: ?u64,            // Not before (optional)
};
```
- Parse JSON from decoded base64url bytes
- Use `std.json.parseFromSlice` with arena allocator
- Store string slices pointing to arena memory

**Patterns to follow:**
- `src/agent.zig` - struct definition pattern
- Zig std.json parsing pattern

**Test scenarios:**
- Happy path: Valid header JSON parses to Header struct
- Happy path: Valid payload JSON parses to Payload struct
- Edge case: Missing optional fields (iat, nbf) default to null
- Error case: Invalid JSON returns parse error
- Error case: Missing required fields (sub, exp) returns error

**Verification:**
- Header and Payload structs compile
- JSON parsing tests pass

---

- [ ] **U3: JWT Signature Verification**

**Goal:** Implement HMAC-SHA256/384/512 signature verification

**Requirements:** R4, R5

**Dependencies:** U1, U2, Day 2 Secret

**Files:**
- Modify: `src/auth/jwt.zig` (verify function)
- Test: `src/auth/jwt_test.zig` (signature tests)

**Approach:**
```zig
pub fn verifySignature(
    header: Header,
    signing_input: []const u8,
    signature: []const u8,
    secret: *Secret,
) !bool {
    // Select hash algorithm based on header.alg
    // Compute HMAC of signing_input with secret key
    // Use secureCompare() for constant-time comparison
}

pub fn secureCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        result |= a_byte ^ b_byte;
    }
    return result == 0;
}
```
- Use `std.crypto.auth.hmac` for HMAC computation
- Support HS256 (SHA256), HS384 (SHA384), HS512 (SHA512)
- Constant-time comparison prevents timing attacks

**Patterns to follow:**
- `src/secret.zig` - secret key usage pattern
- Zig std.crypto.hmac usage pattern

**Test scenarios:**
- Happy path: Valid signature returns true
- Error path: Wrong secret returns false
- Error path: Wrong algorithm returns error
- Security: secureCompare takes constant time (benchmark test)

**Verification:**
- Signature verification tests pass
- Timing analysis shows no significant timing variance

---

- [ ] **U4: JWT Expiration Check**

**Goal:** Implement token expiration validation

**Requirements:** R6

**Dependencies:** U2 (Payload struct)

**Files:**
- Modify: `src/auth/jwt.zig` (expiration check)
- Test: `src/auth/jwt_test.zig` (expiration tests)

**Approach:**
```zig
pub fn verifyExpiration(payload: Payload, now: i128) !void {
    if (payload.exp < now) {
        return error.TokenExpired;
    }
}
```
- Compare `exp` claim against current timestamp
- Return `error.TokenExpired` for expired tokens
- Use `std.time.timestamp()` for current time

**Patterns to follow:**
- Error handling pattern from existing modules

**Test scenarios:**
- Happy path: Unexpired token passes
- Error path: Expired token returns `error.TokenExpired`
- Edge case: Token expiring in 1 second passes
- Edge case: Token expired 1 second ago fails

**Verification:**
- Expiration tests pass
- Correct error type returned

---

- [ ] **U5: JWT Parse and Verify Integration**

**Goal:** Implement main `JWT.parse()` and `JWT.verify()` entry points

**Requirements:** R1, R7, R8

**Dependencies:** U1, U2, U3, U4

**Files:**
- Modify: `src/auth/jwt.zig` (main JWT struct)
- Test: `src/auth/jwt_test.zig` (integration tests)

**Approach:**
```zig
pub const JWT = struct {
    header: Header,
    payload: Payload,
    signature: [32]u8,
    
    pub fn parse(token: []const u8, arena: *SecurityArena) !JWT {
        // Split by '.', decode, parse JSON
    }
    
    pub fn verify(self: *const JWT, secret: *Secret) !bool {
        // Verify signature and expiration
    }
};
```
- Parse splits token, decodes parts, parses JSON
- Verify checks signature and expiration
- Arena used for all temporary allocations

**Patterns to follow:**
- Day 2 patterns (arena usage, Secret integration)

**Test scenarios:**
- Happy path: Valid token parses and verifies
- Error path: Malformed token (wrong parts) returns error
- Error path: Tampered payload returns invalid signature
- Error path: Expired token returns TokenExpired
- Error path: Wrong secret returns invalid signature

**Verification:**
- All integration tests pass
- GPA reports zero leaks

---

- [ ] **U6: Comprehensive Test Suite**

**Goal:** Complete test coverage for all JWT scenarios

**Requirements:** R7, R8

**Dependencies:** U1-U5

**Files:**
- Modify: `src/auth/jwt_test.zig` (all tests)

**Approach:**
- Use `std.testing.allocator` for leak detection
- Use GPA for detailed leak reporting
- Test each algorithm (HS256, HS384, HS512)
- Test all error cases

**Test scenarios:**

*Parsing tests:*
- Valid JWT with all claims
- Valid JWT with minimal claims (sub, exp only)
- JWT with custom claims (iat, nbf)
- Malformed JWT (not 3 parts)
- Invalid base64 in header
- Invalid base64 in payload
- Invalid base64 in signature
- Invalid JSON in header
- Invalid JSON in payload

*Signature tests:*
- HS256 valid signature
- HS384 valid signature
- HS512 valid signature
- Wrong secret key
- Tampered header
- Tampered payload
- Empty signature

*Expiration tests:*
- Unexpired token
- Expired token
- Token expiring in 1 second
- Token expired 1 second ago

*Integration tests:*
- JWT + Secret lifecycle (no leaks)
- JWT parsed in arena, arena reset
- Multiple JWTs, verify isolation
- Constant-time comparison timing analysis

**Verification:**
- `zig build test` passes
- All 25+ tests pass
- GPA reports zero leaks

## System-Wide Impact

- **Interaction graph:** JWT module will be imported by HTTP server (Day 5-6) for request authentication
- **Error propagation:** JWT errors should propagate clearly (`error.TokenExpired`, `error.InvalidSignature`, `error.MalformedToken`)
- **State lifecycle risks:** Arena reset invalidates decoded token data - callers must verify before reset
- **API surface parity:** None - JWT is internal module, not exposed externally yet

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Zig std.crypto API changes | Use direct `std.crypto.auth.hmac` calls, avoid wrappers |
| Base64 padding edge cases | Test both padded and unpadded input |
| Timing attacks on signature | Constant-time `secureCompare()` mandatory |
| Memory leaks from JSON parsing | Use arena allocator, verify with GPA |
| Secret key exposure | Store keys in Secret container, zeroize on deinit |

## Documentation / Operational Notes

- Add doc comments to all public functions
- Include JWT usage examples in doc comments
- Note security properties (constant-time, zeroize)
- Document supported algorithms (HS256, HS384, HS512)

## Sources & References

- **Origin:** PRD.md Day 3 specification (lines 187-236)
- **RFC 7519:** JSON Web Token (JWT)
- **RFC 7515:** JSON Web Signature (JWS)
- **Zig std.crypto:** `std.crypto.auth.hmac`
- **Zig std.base64:** `std.base64.UrlDecoder`
- Related code: `src/secret.zig`, `src/memory.zig`
