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


---

## Phase 7: Day 4 - Policy Engine Foundation (Pending)

**Goal:** Implement policy language, parser, and compile-time policy generation per PRD.md lines 238-301

### Requirements (R1-R7)
- R1. JSON policy language design (version, policies array)
- R2. Policy struct: id, effect, conditions
- R3. Effect enum: allow, deny
- R4. Condition union: agent_id, path, method, custom
- R5. Policy evaluator with RequestContext
- R6. Compile-time policy generation via comptime
- R7. Policy evaluation benchmark (<100µs for 1000 policies)

### Dependencies
- Day 2: SecurityArena (for runtime policy parsing)
- Day 3: JWT auth (for agent_id in RequestContext)

### Files to Create/Modify
- Create: `src/policy/` directory
- Create: `src/policy/parser.zig`
- Create: `src/policy/engine.zig`
- Create: `src/policy/policies.json` (example policies)
- Create: `src/policy/benchmark.zig`

### Implementation Approach

**Policy JSON Structure:**
```json
{
  "version": "1",
  "policies": [
    {
      "id": "policy-001",
      "effect": "allow",
      "match": {
        "agent_id": "auth-service",
        "path": "/api/users/*",
        "method": ["GET", "POST"]
      }
    },
    {
      "id": "policy-002",
      "effect": "deny",
      "match": {
        "agent_id": "*",
        "path": "/api/admin/*"
      }
    }
  ]
}
```

**Core Types:**
```zig
pub const Policy = struct {
    id: []const u8,
    effect: Effect,
    conditions: []Condition,
    
    pub fn evaluate(self: *const Policy, ctx: RequestContext) bool { ... }
};

pub const Effect = enum { allow, deny };

pub const Condition = union(enum) {
    agent_id: []const u8,
    path: []const u8,
    method: Method,
    custom: CustomCondition,
};

pub const RequestContext = struct {
    agent_id: [32]u8,
    path: []const u8,
    method: Method,
};
```

**Compile-Time Policy Generation:**
```zig
pub fn PolicySet(comptime policies_file: []const u8) type {
    comptime {
        const policies = @embedFile(policies_file);
        // Parse at compile time
        // Generate decision tree
        // Return optimized type
    }
}
```

**Wildcard Matching:**
```zig
fn matchPattern(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;
    if (pattern[0] == '*') return true;  // Match all
    if (pattern[pattern.len - 1] == '*') {
        // Prefix match
        return std.mem.startsWith(u8, value, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, value);
}
```

### Test Scenarios

**Unit Tests:**
- Policy parse valid JSON
- Policy parse malformed JSON (fails gracefully)
- Effect allow/deny evaluation
- Condition: agent_id exact match
- Condition: agent_id wildcard (*) match
- Condition: path prefix match (/api/users/*)
- Condition: method match (GET, POST)
- Multiple conditions AND evaluation
- Compile-time policy generation

**Integration Tests:**
- Policy engine + RequestContext
- Policy evaluation in arena
- Multiple policies, first-match-wins or deny-default
- Benchmark: 1000 policies <100µs

### Acceptance Criteria
- [ ] `zig build test` passes
- [ ] All 7+ test scenarios covered
- [ ] Benchmark: 1000 policies evaluated in <100µs
- [ ] GPA reports zero memory leaks
- [ ] Compile-time policy generation works
- [ ] Wildcard patterns (*, prefix/*) work correctly

### Risks & Mitigations
| Risk | Mitigation |
|------|------------|
| JSON parsing slow at runtime | Use comptime parsing, cache result |
| Wildcard matching edge cases | Test *, prefix/*, exact match |
| Policy order matters | Document: first-match-wins, deny default |
| Memory leaks from string allocations | Use arena allocator, verify with GPA |

### Estimated Effort
- Morning: Policy language design + parser
- Afternoon: Compile-time generation + benchmarks
- Total: 8 hours

### Deliverable
Policy engine that evaluates 1000 policies in <100µs

