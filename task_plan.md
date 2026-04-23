# Task Plan: Day 1 - Project Setup & Directory Structure (PRD)

## Goal
Set up project structure per PRD.md Day 1 specification.

## Phases

### Phase 1: Analysis (Complete)
- [x] Read PRD.md - 15-day implementation plan
- [x] Read existing code files

### Phase 2: Directory Structure (Complete)
Create per PRD:
```
agentgate/
├── src/
│   ├── main.zig (exists)
│   ├── root.zig (exists)
│   ├── auth/
│   │   ├── jwt.zig
│   │   └── mTLS.zig
│   ├── policy/
│   │   ├── engine.zig
│   │   └── parser.zig
│   ├── audit/
│   │   └── logger.zig
│   ├── server/
│   │   └── http.zig
│   └── metrics/
│       └── prometheus.zig
├── build.zig (exists)
├── build.zig.zon (exists)
├── README.md
├── ARCHITECTURE.md
└── THREAT_MODEL.md
```

### Phase 3: Documentation (Complete)
- [x] Create README.md - project vision
- [x] Create ARCHITECTURE.md - system design
- [x] Create THREAT_MODEL.md - security analysis

### Phase 4: Verification (Complete)
- [x] `zig build` succeeds
- [x] `zig build test` passes

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| | | |

## Decisions
| Decision | Rationale |
|----------|-----------|
| | |

## Phase 5: Day 2 - Core Data Structures & Memory Management (COMPLETE ✅)
- [x] Implement custom arena allocator in `src/memory.zig`
- [x] Implement zeroizing secret container in `src/secret.zig`
- [x] Implement Agent context structure in `src/agent.zig`
- [x] Write memory safety tests (27 tests, all passing)

---

## Phase 6: Day 3 - Authentication Engine (JWT) (Pending)

**Goal:** Implement JWT parser and verifier with timing-attack protection per PRD.md lines 187-236

### Requirements (R1-R8)
- R1. JWT struct with header, payload, signature
- R2. Header parsing (alg, typ fields)
- R3. Payload parsing (sub, exp, aud, extra claims)
- R4. HMAC-SHA256/384/512 signature verification
- R5. Constant-time signature comparison
- R6. Expiration check
- R7. Tests: valid, expired, tampered, wrong secret
- R8. Integration with Secret container for key storage

### Dependencies
- Day 2: Secret container (for key storage)
- Day 2: SecurityArena (for request-scoped parsing)

### Files to Create/Modify
- Create: `src/auth/jwt.zig`
- Create: `src/auth/jwt_test.zig` (or inline tests)
- Modify: `src/auth/mTLS.zig` (deferred - Day 9)

### Implementation Approach

**JWT Structure:**
```zig
pub const JWT = struct {
    header: Header,
    payload: Payload,
    signature: [32]u8,  // HMAC-SHA256
    
    pub fn parse(token: []const u8) !JWT { ... }
    pub fn verify(self: *const JWT, secret: *Secret) !bool { ... }
};

const Header = struct {
    alg: []const u8,  // "HS256", "HS384", "HS512"
    typ: []const u8,  // "JWT"
};

const Payload = struct {
    sub: []const u8,      // Subject (agent ID)
    exp: u64,             // Expiration timestamp
    aud: []const u8,      // Audience
    iat: ?u64,            // Issued at (optional)
    extra: ?std.json.Value, // Custom claims (optional)
};
```

**Constant-Time Comparison:**
```zig
pub fn secureCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        result |= a_byte ^ b_byte;
    }
    return result == 0;
}
```

### Test Scenarios

**Unit Tests:**
- JWT parse valid token
- JWT parse malformed token (fails gracefully)
- Signature verification with correct secret
- Signature verification with wrong secret (fails)
- Expired token (fails)
- Valid unexpired token (passes)
- Tampered payload (fails)
- Constant-time comparison (timing analysis)

**Integration Tests:**
- JWT + Secret lifecycle
- JWT parsed in arena, arena reset
- Multiple JWTs, verify isolation

### Acceptance Criteria
- [ ] `zig build test` passes
- [ ] All 8+ test scenarios covered
- [ ] Constant-time comparison verified (no timing leaks)
- [ ] GPA reports zero memory leaks
- [ ] Code follows Day 2 patterns (zeroize, arena usage)

### Risks & Mitigations
| Risk | Mitigation |
|------|------------|
| Zig std.crypto API changes | Use std.crypto.hmac directly, avoid wrappers |
| Base64 URL encoding edge cases | Test with padding/no-padding variants |
| Timing attacks | Use constant-time compare, verify with benchmarks |
| Memory leaks from string allocations | Use arena allocator, verify with GPA |

### Estimated Effort
- Morning: JWT parser + Header/Payload structs
- Afternoon: Signature verification + tests
- Total: 8 hours

