---
title: Day 6 End-to-End Request Processing (Deepened)
type: feat
status: active
date: 2026-05-09
origin: PRD.md
deepened: 2026-05-09
---

# Day 6 End-to-End Request Processing (Deepened)

## Overview

Integrate Auth, Policy, and Audit modules into a seamless, zero-allocation request lifecycle. This plan resolves critical gaps in secret management and policy attribution, then verifies the system's performance and stability under high concurrency using the epoll-based server.

---

## Problem Frame

The system currently possesses functional but isolated modules. The integration in `src/server/http.zig` is a "happy path" prototype using hardcoded secrets and generic audit logs. To achieve the target <50µs P99 latency and maintain security standards, the integration must be hardened to handle real-world error states, dynamic configurations, and high-concurrency pressure without memory leaks or lock contention.

---

## Requirements Trace

- R1. End-to-end request processing implementation (PRD Day 6)
- R2. Concurrent request handling with epoll and efficient worker distribution (PRD Day 6)
- R3. Audit logs must capture specific policy IDs and agent identities (PRD Day 7, integrated early)
- R4. Full flow latency <100µs (Phase 2 Success Criteria)
- R5. Zero memory leaks under concurrent load (PRD Phase 1/2 Success Criteria)

---

## Scope Boundaries

- **Included**: Request flow from socket read $\rightarrow$ Auth $\rightarrow$ Policy $\rightarrow$ Audit $\rightarrow$ socket write.
- **Included**: Transition from hardcoded secrets to configuration-driven secrets.
- **Included**: Detailed policy attribution in audit entries.
- **Excluded**: mTLS handshake implementation (Deferred to Day 9).
- **Excluded**: Zero-copy request parsing (Deferred to Day 11).
- **Excluded**: Changes to the core `epoll` event loop logic.

### Deferred to Follow-Up Work

- Advanced mTLS support: Day 9.
- Zero-copy request parsing: Day 11.
- Prometheus metrics endpoint integration: Day 8.

---

## Context & Research

### Relevant Code and Patterns

- `src/server/http.zig`: The primary orchestration point. The `sendCheckResponse` function currently implements the rudimentary flow.
- `src/auth/jwt.zig` / `src/server/auth_middleware.zig`: Authentication logic. Currently relies on a hardcoded string.
- `src/policy/engine.zig`: The evaluator. Currently returns a simple `Effect` enum.
- `src/audit/logger.zig`: The sink. Ring buffer implementation.
- `src/memory.zig`: `SecurityArena` for request-scoped memory.

### Institutional Learnings

- **Zero-Allocation Path**: The critical path from request arrival to response must avoid `std.heap.page_allocator` and use the `SecurityArena`.
- **Constant Time**: Auth verification must use `secureCompare` to prevent timing attacks.

---

## Key Technical Decisions

- **Decision**: Replace `Effect` return in `PolicyEngine.evaluate` with a `Decision` struct: `{ effect: Effect, policy_id: []const u8 }`.
- **Rationale**: The Audit Logger requires the specific policy ID that granted or denied access to provide an immutable and useful audit trail.
- **Decision**: Move `JWT_SECRET` to `src/config.zig` and inject via `Server` initialization.
- **Rationale**: Hardcoded secrets are a security vulnerability and prevent environment-specific configuration.
- **Decision**: Implement an explicit Error-to-HTTP status map in the server.
- **Rationale**: Ensures consistent API behavior and prevents leaking internal error details to the client.

---

## Open Questions

### Resolved During Planning

- **How to distribute requests to workers?**: The `runAsyncEpoll` loop will continue to handle I/O, and request processing will be dispatched to a pool of worker threads to maximize CPU utilization on multi-core systems.

### Deferred to Implementation

- **Optimal ring-buffer size for AuditLogger**: Will be determined during U5 stress tests to balance memory usage vs. log retention.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Request Lifecycle Flow:**
`Socket Read` $\rightarrow$ `ParseRequest` $\rightarrow$ `AuthMiddleware (verify JWT)` $\rightarrow$ `PolicyEngine (evaluate context)` $\rightarrow$ `AuditLogger (log Decision)` $\rightarrow$ `Send Response`

**Data Flow:**
1. `ParsedRequest` $\rightarrow$ `AuthMiddleware` $\rightarrow$ `Agent` (ID, Permissions)
2. `Agent` + `ParsedRequest` $\rightarrow$ `RequestContext`
3. `RequestContext` $\rightarrow$ `PolicyEngine` $\rightarrow$ `Decision` (Effect, PolicyID)
4. `Agent` + `Decision` + `Request` $\rightarrow$ `AuditLogger` $\rightarrow$ `LogEntry`

---

## Implementation Units

- [ ] U1. **Detailed Policy Decisions**

**Goal:** Update Policy Engine to return specific policy attribution.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `src/policy/types.zig` (Define `Decision` struct)
- Modify: `src/policy/engine.zig` (Update `evaluate` return type)
- Test: `src/policy/engine_test.zig`

**Approach:**
- Implement `pub const Decision = struct { effect: Effect, policy_id: []const u8 };`.
- Update `evaluate` logic to capture and return the ID of the matching policy.
- Ensure "default-deny" is returned when no policies match.

**Test scenarios:**
- Happy path: Valid request matches "policy-001" $\rightarrow$ returns `.allow` and `"policy-001"`.
- Edge case: Request matches no policies $\rightarrow$ returns `.deny` and `"default-deny"`.

**Verification:** `zig build test` passes for policy engine.

---

- [ ] U2. **Dynamic Secret Injection**

**Goal:** Eliminate hardcoded JWT secrets.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `src/config.zig` (Add `jwt_secret` field)
- Modify: `src/server/http.zig` (Pass secret during init)
- Modify: `src/server/auth_middleware.zig` (Accept secret in `init`)

**Approach:**
- Update `Config` struct to include `jwt_secret: []const u8`.
- Modify `AuthMiddleware` to store the secret in a `Secret` container.
- Wire the flow: `main.zig` $\rightarrow$ `Config.load()` $\rightarrow$ `Server.init()` $\rightarrow$ `AuthMiddleware.init()`.

**Test scenarios:**
- Happy path: Server starts with secret from `config.json` and successfully verifies tokens.
- Error path: Server fails to start or returns error if `jwt_secret` is empty/missing.

**Verification:** Successful authentication using a secret loaded from disk.

---

 la- [ ] U3. **Hardened Request Lifecycle**

**Goal:** Ensure robustness and resource safety in the E2E flow.

**Requirements:** R1, R4, R5

**Dependencies:** U1, U2

**Files:**
- Modify: `src/server/http.zig`

**Approach:**
- Audit all `std.net.Stream` read/write calls; replace `_ = ...` with proper error handling.
- Use `defer` blocks to ensure `Agent` and `ParsedRequest` are cleaned up even on error paths.
- Map internal errors (e.g., `error.InvalidToken`, `error.PolicyDenied`) to standard HTTP status codes (401, 403).

**Test scenarios:**
- Error path: Malformed HTTP request $\rightarrow$ returns 400 Bad Request.
- Error path: Client disconnects during header read $\rightarrow$ server cleans up arena and socket without leaking.
- Error path: Invalid JWT $\rightarrow$ returns 401 Unauthorized.

**Verification:** GPA reports zero leaks during a series of malformed requests.

---

- [ ] U4. **E2E Integration Test Suite**

**Goal:** Validate the complete chain from network byte to audit log.

**Requirements:** R1, R3

**Dependencies:** U1, U2, U3

**Files:**
- Create: `src/integration_test_e2e.zig`
- Modify: `build.zig` (Add E2E test target)

**Approach:**
- Implement a test harness that spawns the server on a random port.
- Use a helper to generate valid/invalid JWTs.
- Perform HTTP calls and verify:
    1. HTTP status code.
    2. Response body JSON.
    3. `AuditLogger` contains a `LogEntry` with the correct `agent_id` and `policy_id`.

**Test scenarios:**
- Integration: Valid JWT + Allowed Path $\rightarrow$ 200 OK $\rightarrow$ Audit Log shows `.allow` + correct Policy ID.
- Integration: Valid JWT + Forbidden Path $\rightarrow$ 403 Forbidden $\rightarrow$ Audit Log shows `.deny` + correct Policy ID.
- Integration: Expired JWT $\rightarrow$ 401 Unauthorized $\rightarrow$ Audit Log shows `.deny` + `"auth-failure"`.

**Verification:** All E2E scenarios pass in `zig build test`.

---

- [ ] U5. **Concurrency Stress Test**

**Goal:** Verify latency targets and stability under load.

**Requirements:** R2, R4, R5

**Dependencies:** U3, U4

**Files:**
- Create: `scripts/stress_test_day6.sh`
- Modify: `src/server/http.zig` (Add basic timing instrumentation if missing)

**Approach:**
- Use `wrk` or `hey` to simulate 100+ concurrent clients.
- Generate a pool of 1,000 valid JWTs to avoid caching effects in auth.
- Measure P99 latency for the `/check` endpoint.
- Monitor resident set size (RSS) to ensure no memory growth over 1 million requests.

**Test scenarios:**
- Happy path: 10k req/s with 100 concurrent connections $\rightarrow$ P99 < 100µs.
- Edge case: Sudden spike of 1k concurrent connections $\rightarrow$ no crashes, graceful recovery.

**Verification:** Benchmark output shows stable memory and P99 latency within targets.

---

## System-Wide Impact

- **Interaction graph**: The critical path is now `Server` $\rightarrow$ `AuthMiddleware` $\rightarrow$ `PolicyEngine` $\rightarrow$ `AuditLogger`. Any latency in one affects the total P99.
- **Error propagation**: Errors no longer just "fail" but are mapped to HTTP codes, improving observability for agent clients.
- **State lifecycle risks**: The `AuditLogger` ring buffer will wrap around under stress tests. The verification in U4 must check the *most recent* entry or a window of entries.
- **Unchanged invariants**: The core `epoll` loop remains unchanged. The concurrency model relies on the provided worker distribution.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Memory leaks in the hot path | Use `SecurityArena` for all per-request data. Run GPA during E2E tests. |
| Audit Log contention | The ring buffer is designed for high throughput; verify with U5 stress tests. |
| Secret Leakage | Use `Secret` wrapper for the JWT key; ensure it is never printed to logs. |
| Performance degradation | Benchmark each unit (U1-U3) before the full stress test (U5). |

---

## Sources & References

- **Origin document:** [PRD.md](PRD.md)
- Related code: `src/server/http.zig`, `src/policy/engine.zig`, `src/audit/logger.zig`, `src/auth/jwt.zig`
