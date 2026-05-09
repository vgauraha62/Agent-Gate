---
title: Day 5 - HTTP Server Foundation
type: feat
status: active
date: 2026-04-30
origin: docs/plans/2026-04-23-001-feat-policy-engine-foundation-plan.md
---

# Day 5 - HTTP Server Foundation

## Overview

Implement HTTP server with JWT authentication middleware and policy-based authorization. This completes the core request processing pipeline: receive HTTP request → validate JWT → evaluate policy → return allow/deny decision.

## Problem Frame

Agents need to send requests through the sidecar for policy enforcement. The server must:
- Parse HTTP requests without external dependencies
- Extract and validate JWT tokens from Authorization headers
- Evaluate requests against the policy engine
- Return 200 (allow) or 403 (deny) responses
- Log all decisions for audit trail

Performance target: <50µs P99 latency for auth + policy evaluation.

## Requirements Trace

From PRD.md Day 5 specification (lines 305-356):
- R1. HTTP server with request/response handling
- R2. JWT authentication middleware integration
- R3. Policy engine integration for authorization
- R4. Request logging and audit trail
- R5. Health check endpoint (no auth required)
- R6. Policy check endpoint (requires auth)

## Scope Boundaries

- HTTP/1.1 only - no HTTP/2 or HTTP/3 support yet
- Plaintext HTTP initially - TLS termination deferred to Day 9 (mTLS)
- Synchronous request handling - thread-per-connection concurrency
- In-memory audit log - persistent storage deferred to Day 7
- Basic metrics counters - histograms deferred to Day 8

### Deferred to Separate Tasks

- TLS/mTLS support: Day 9, separate PR
- Persistent audit log: Day 7
- Prometheus histogram metrics: Day 8
- Request routing beyond /health and /check: Day 6

## Context & Research

### Relevant Code and Patterns

- `src/auth/jwt.zig` - JWT.parse() and JWT.verify() for token validation
- `src/policy/engine.zig` - PolicyEngine.evaluate() for allow/deny decisions
- `src/memory.zig` - SecurityArena for request-scoped allocations
- `src/secret.zig` - Secret container for JWT key storage
- `src/agent.zig` - Agent struct with PermissionSet

### Institutional Learnings

- Day 2 established arena-based memory management pattern
- Day 3 JWT module uses SecurityArena for all allocations
- Day 4 policy engine has zero allocations in hot path
- All tests must pass with GPA showing zero leaks

### External References

- RFC 7230 - HTTP/1.1 Message Syntax
- RFC 7231 - HTTP/1.1 Semantics and Content
- Zig std.net for TCP listener patterns

## Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Build HTTP parser from scratch | No external deps, full control, matches PRD approach |
| Thread-per-connection concurrency | Simple, matches PRD Day 6 early |
| Zero-copy request parsing where possible | Performance, arena-based for headers |
| Bearer token in Authorization header | Standard JWT transport, RFC 6750 |
| Default deny for missing/invalid JWT | Security-first, consistent with policy engine |

## Open Questions

### Resolved During Planning

- Q: What HTTP methods to support? → A: GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD
- Q: How to handle request body? → A: Read into arena buffer, max 1MB initially
- Q: What response format for /check? → A: JSON with {allowed: bool, reason: string}

### Deferred to Implementation

- Exact thread pool size configuration
- Maximum concurrent connections limit
- Request timeout duration

## Output Structure

```
src/
├── main.zig              # Modify: wire up HTTP server
├── root.zig              # Modify: export server modules
├── server/
│   ├── http.zig          # HTTP server + parser
│   └── auth_middleware.zig # JWT extraction + verification
├── audit/
│   └── logger.zig        # Basic audit logging
└── metrics/
    └── prometheus.zig    # Basic metrics counters
```

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

### Request Processing Flow

```
┌─────────────────────────────────────────────────────────────┐
│  TCP Connection (port 8080)                                 │
│       │                                                      │
│       ▼                                                      │
│  ┌─────────────────┐                                        │
│  │ HTTP Parser     │ → Request { method, path, headers }   │
│  └────────┬────────┘                                        │
│           │                                                  │
│       ┌───┴───┬───────────┐                                 │
│       ▼       ▼           ▼                                 │
│  ┌────────┐ ┌────────┐ ┌──────────┐                        │
│  │ /health│ │  JWT   │ │  Audit   │                        │
│  │  (no   │ │  Auth  │ │  Logger  │                        │
│  │  auth) │ │  Check │ │          │                        │
│  └────────┘ └───┬────┘ └──────────┘                        │
│                 │                                           │
│                 ▼                                           │
│         ┌───────────────┐                                   │
│         │ Policy Engine │                                   │
│         │  Evaluation   │                                   │
│         └───────┬───────┘                                   │
│                 │                                           │
│       ┌─────────┴─────────┐                                 │
│       ▼                   ▼                                 │
│  Allow (200)         Deny (403)                             │
└─────────────────────────────────────────────────────────────┘
```

### Response Format

```json
// GET /health
{ "status": "ok" }

// POST /check (allowed)
{ "allowed": true, "policy_id": "allow-api" }

// POST /check (denied)
{ "allowed": false, "policy_id": "deny-default", "reason": "no matching policy" }
```

## Implementation Units

- [ ] **Unit 1: Fix Deprecated APIs in main.zig**

**Goal:** Update main.zig from deprecated std.Io/std.process.Init to modern Zig pattern

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `src/main.zig`
- Modify: `src/root.zig`

**Approach:**
- Replace `std.Io` with `std.io`
- Replace `std.process.Init` with modern main() signature
- Use `std.heap.GeneralPurposeAllocator` for top-level allocations
- Wire up HTTP server startup

**Patterns to follow:**
- Modern Zig main() pattern: `pub fn main() !void`
- Use `std.net` for TCP operations

**Test scenarios:**
- Happy path: `zig build` compiles without deprecation warnings
- Happy path: `zig build test` passes

**Verification:**
- No deprecated API usage in main.zig
- Binary builds and runs

---

- [ ] **Unit 2: HTTP Types and Server Struct**

**Goal:** Define HTTP types (Method, Request, Response, Server)

**Requirements:** R1

**Dependencies:** Unit 1

**Files:**
- Modify: `src/server/http.zig`
- Test: inline tests in http.zig

**Approach:**
- Define `Method` enum for HTTP methods
- Define `Request` struct with method, path, headers, body
- Define `Response` struct with status, headers, body
- Define `Server` struct with TCP listener and allocator

**Patterns to follow:**
- Use `[]const u8` for string slices
- Use arena for header allocations
- Follow Day 2 SecurityArena pattern

**Test scenarios:**
- Happy path: Create valid Request struct
- Happy path: Create valid Response struct
- Edge case: Empty headers map
- Edge case: Large request body (1MB limit)

**Verification:**
- All types compile
- Type tests pass

---

- [ ] **Unit 3: HTTP Request Parser**

**Goal:** Implement zero-copy HTTP request parser

**Requirements:** R1

**Dependencies:** Unit 2

**Files:**
- Modify: `src/server/http.zig`
- Test: inline tests in http.zig

**Approach:**
- Parse request line: `METHOD PATH HTTP/1.1`
- Parse headers into arena-allocated map
- Handle body reading with content-length
- Return error for malformed requests

**Patterns to follow:**
- Zero-copy parsing where possible
- Arena allocation for headers
- Follow Zig std.mem parsing patterns

**Test scenarios:**
- Happy path: Parse valid GET request
- Happy path: Parse valid POST request with body
- Edge case: Request with many headers
- Edge case: Request with empty body
- Edge case: Request with large body
- Error path: Malformed request line returns error
- Error path: Missing Content-Length with body returns error
- Error path: Invalid HTTP version returns error

**Verification:**
- Parser tests pass
- Zero memory leaks under GPA

---

- [ ] **Unit 4: JWT Authentication Middleware**

**Goal:** Extract and validate JWT from Authorization header

**Requirements:** R2

**Dependencies:** Unit 2, Unit 3, Day 3 JWT module

**Files:**
- Create: `src/server/auth_middleware.zig`
- Test: inline tests in auth_middleware.zig

**Approach:**
- Extract Bearer token from Authorization header
- Call `JWT.parse()` with SecurityArena
- Call `JWT.verify()` with Secret key
- Return Agent on success, 401 on failure

**Patterns to follow:**
- Use SecurityArena for JWT parsing
- Follow Day 3 JWT module patterns
- Return clear error types (Unauthorized, InvalidToken)

**Test scenarios:**
- Happy path: Valid Bearer token returns Agent
- Error path: Missing Authorization header returns 401
- Error path: Invalid Bearer format returns 401
- Error path: Expired JWT returns 401
- Error path: Tampered JWT returns 401
- Error path: Wrong secret returns 401

**Verification:**
- Auth middleware tests pass
- Integration with JWT module works

---

- [ ] **Unit 5: Policy Integration**

**Goal:** Integrate policy engine for allow/deny decisions

**Requirements:** R3

**Dependencies:** Unit 4, Day 4 Policy Engine

**Files:**
- Modify: `src/server/http.zig`
- Test: inline tests in http.zig

**Approach:**
- Build `RequestContext` from request + agent
- Call `PolicyEngine.evaluate()`
- Return 200 (allow) or 403 (deny)
- Include matched policy ID in response

**Patterns to follow:**
- Use Day 4 policy engine types
- Zero allocations in hot path
- First-match-wins evaluation

**Test scenarios:**
- Happy path: Allowed request returns 200
- Happy path: Denied request returns 403
- Edge case: No matching policy returns 403 (default deny)
- Integration: Full request + agent + policy evaluation

**Verification:**
- Policy integration tests pass
- Response includes correct policy ID

---

- [ ] **Unit 6: Audit Logger (Basic)**

**Goal:** Implement basic in-memory audit logging

**Requirements:** R4

**Dependencies:** Unit 5

**Files:**
- Modify: `src/audit/logger.zig`
- Test: inline tests in logger.zig

**Approach:**
- Define `LogEntry` struct with timestamp, agent_id, path, decision
- Implement ring buffer for in-memory storage
- Log each request decision
- Provide export function for debugging

**Patterns to follow:**
- Use Day 2 Secret pattern for sensitive data
- Follow arena allocation patterns
- Prepare for Day 7 cryptographic proof chain

**Test scenarios:**
- Happy path: Log entry added to buffer
- Edge case: Ring buffer wraps correctly
- Edge case: Maximum capacity reached

**Verification:**
- Audit logger tests pass
- Entries are logged for each request

---

- [ ] **Unit 7: Metrics Counters (Basic)**

**Goal:** Implement basic Prometheus-style metrics

**Requirements:** R4 (partial)

**Dependencies:** Unit 5

**Files:**
- Modify: `src/metrics/prometheus.zig`
- Test: inline tests in prometheus.zig

**Approach:**
- Atomic counters for requests_total, allowed_total, denied_total
- Basic gauge for active_connections
- Export function for /metrics endpoint

**Patterns to follow:**
- Use std.atomic for thread-safe counters
- Follow Prometheus text format

**Test scenarios:**
- Happy path: Counter increments on request
- Happy path: Export returns Prometheus format

**Verification:**
- Metrics tests pass
- Counters are thread-safe

---

- [ ] **Unit 8: HTTP Endpoints**

**Goal:** Implement /health, /check, /metrics endpoints

**Requirements:** R5, R6

**Dependencies:** Units 4-7

**Files:**
- Modify: `src/server/http.zig`
- Modify: `src/main.zig`
- Test: integration tests in http_test.zig

**Approach:**
- `GET /health` - returns 200 with no auth required
- `POST /check` - requires auth, evaluates policy
- `GET /metrics` - returns Prometheus format metrics

**Patterns to follow:**
- Route based on path + method
- Return appropriate status codes
- JSON response bodies

**Test scenarios:**
- Happy path: GET /health returns 200 without auth
- Happy path: POST /check with valid JWT + allowed policy returns 200
- Happy path: POST /check with valid JWT + denied policy returns 403
- Error path: POST /check without auth returns 401
- Error path: POST /check with expired JWT returns 401
- Happy path: GET /metrics returns Prometheus format

**Verification:**
- All endpoint tests pass
- Server responds correctly to curl requests

---

- [ ] **Unit 9: Integration Tests**

**Goal:** Comprehensive end-to-end test suite

**Requirements:** R1-R6

**Dependencies:** Units 1-8

**Files:**
- Create: `src/server/http_test.zig`
- Create: `src/integration_http_test.zig`

**Approach:**
- Start test server on random port
- Send real HTTP requests
- Verify responses
- Check memory safety with GPA

**Patterns to follow:**
- Use std.testing.allocator for leak detection
- Use GPA for detailed leak reporting
- Test concurrent requests

**Test scenarios:**

*Endpoint tests:*
- Health check without auth
- Check endpoint with valid JWT
- Check endpoint with invalid JWT
- Check endpoint with expired JWT
- Check endpoint with tampered JWT
- Metrics endpoint returns correct format

*Policy integration tests:*
- Request matching allow policy → 200
- Request matching deny policy → 403
- Request with no matching policy → 403
- Wildcard agent_id policy works
- Path prefix policy works

*Concurrency tests:*
- Multiple concurrent requests handled
- No race conditions in metrics
- No race conditions in audit log

*Memory safety tests:*
- 1000 requests with no memory leaks
- Arena reset between requests
- JWT parsing allocations freed

**Verification:**
- All 20+ integration tests pass
- GPA reports zero leaks
- Server handles concurrent requests

## System-Wide Impact

- **Interaction graph:** HTTP server imports JWT module (Day 3), Policy Engine (Day 4), SecurityArena (Day 2), Secret (Day 2)
- **Error propagation:** JWT errors → 401, Policy deny → 403, Parse errors → 400, Internal errors → 500
- **State lifecycle risks:** Arena reset between requests invalidates parsed data - must complete evaluation before reset
- **API surface parity:** /metrics endpoint will need histogram support (Day 8), /check endpoint is primary API
- **Integration coverage:** End-to-end tests prove full request → auth → policy → response flow

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| HTTP parser edge cases | Medium | Medium | Comprehensive tests for malformed requests |
| Thread safety of counters | Low | High | Use std.atomic, test with concurrent requests |
| Memory leaks from headers | Medium | Medium | Arena-based allocation, GPA tests |
| JWT verification performance | Low | High | Benchmark hot path, optimize if needed |
| Ring buffer overflow | Low | Medium | Wrap correctly, document max capacity |

## Documentation / Operational Notes

- Document Bearer token format in Authorization header
- Document /health, /check, /metrics endpoints
- Note default deny behavior for missing/invalid JWT
- Document ring buffer capacity and wrap behavior

## Sources & References

- **Origin:** PRD.md Day 5 specification (lines 305-356)
- Related code: `src/auth/jwt.zig`, `src/policy/engine.zig`, `src/memory.zig`
- External: RFC 7230 (HTTP/1.1), RFC 6750 (Bearer Tokens)
