---
title: "Day 12: Testing & Fuzzing"
type: feat
status: active
date: 2026-05-22
origin: PRD.md
---

# Day 12: Testing & Fuzzing

## Overview
Establish a rigorous validation suite for AgentGate, focusing on security-critical parsers (JWT, Policy) and end-to-end request flow. The goal is to move from basic unit tests to high-coverage integration tests and crash-resistant fuzzing targets.

---

## Problem Frame
Security sidecars are high-value targets. A single parser bug (e.g., buffer overflow in JWT parsing or logic error in policy evaluation) can lead to full bypass of the security gate. Standard unit tests are insufficient for finding these edge cases.

---

## Requirements Trace
- R1. Integration tests verifying valid and invalid request flows (PRD.md Day 12).
- R2. Fuzzing targets for JWT and Policy parsers to ensure robustness against malformed input (PRD.md Day 12).
- R3. Test coverage > 85% (PRD.md Success Metrics Dashboard).

---

## Scope Boundaries
- **Non-goals**:
    - Formal verification (TLA+, Coq) of the policy engine.
    - Fuzzing of the network stack (relying on Zig's `std.net` and `std.crypto.tls` correctness).
    - Performance benchmarking (covered in Day 11).

---

## Context & Research

### Relevant Code and Patterns
- `src/integration_test.zig`: Existing (orphaned) SecurityArena/Secret/Agent lifecycle tests — to be wired and extended.
- `src/test_integration.zig`: Active `zig build test` entry point (114 lines).
- `src/integration_e2e_test.zig`: Full Policy→Audit integration flow (322 lines, `zig build test-e2e`).
- `src/e2e_server_test.zig`: Server lifecycle + auth middleware tests (316 lines, `zig build test-e2e-server`).
- `src/auth/jwt.zig`: 985 lines. Target for JWT parser tests and fuzzing. **Contains known stack-buffer overflow in HMAC implementations** when message exceeds 192 bytes (HS256) or 128 bytes (HS384/HS512).
- `src/policy/parser.zig`: Target for Policy parser tests and fuzzing.
- `src/policy/engine.zig`: Target for policy evaluation logic tests.

### Critical Code Findings (from codebase audit)
1. **HMAC stack buffer overflow** (jwt.zig): `hmacSha256`/`hmacSha384`/`hmacSha512` use fixed 256-byte stack buffers for `inner_msg`/`outer_msg`. Messages >192 bytes (HS256) or >128 bytes (HS384/HS512) overflow silently.
2. **page_allocator leak** (jwt.zig): `parseHeader()` and `parsePayload()` use `std.heap.page_allocator.dupe()` — memory is never freed. Long-running fuzzing will OOM even with arena resets unless patched.
3. **Two orphaned test files**: `src/integration_test.zig` (200 lines) and `src/audit/integration_test.zig` (263 lines) exist but are not wired into any build step.

### Institutional Learnings
- Use `std.testing.allocator` (GPA) in all tests to ensure zero memory leaks.
- Reuse existing test helpers: `generateTestJWT()` and `generateExpiredJWT()` already public in `src/auth/jwt.zig`.
- Integration tests should simulate the full request lifecycle: Auth -> Policy -> Audit.

---

## Key Technical Decisions
- **Fuzzing Framework**: Use `libFuzzer` via Zig's native support (`-fno-omit-frame-pointer`, `-fsanitize=fuzzer`) for coverage-guided fuzzing.
- **Integration Strategy**: Reuse and extend `src/integration_test.zig` (after wiring it into `build.zig`). Leverage existing `generateTestJWT()` helpers rather than rebuilding. Audit existing `e2e_server_test.zig` to avoid duplication before building new `TestServer` mock infrastructure.

---

## Open Questions

### Resolved During Planning
- **Where to put fuzzers?** Create a top-level `fuzz/` directory with seed corpus subdirectories `fuzz/corpus/jwt/` and `fuzz/corpus/policy/`.
- **Which file for integration tests?** Wire the orphaned `src/integration_test.zig` into `build.zig`, then add U1/U2 tests there. This recovers ~200 lines of existing (never-run) tests and provides a single home for request-flow tests.

### Deferred to Implementation
- **Exact `libFuzzer` flags for Zig**: Will be determined based on the specific Zig compiler version used during execution.
- **Coverage tooling**: Research what works with Zig 0.17.0-dev (kcov, grcov, or manual analysis). Deferred from planning to implementation phase.

---

## Output Structure
```text
agentgate/
├── fuzz/
│   ├── corpus/
│   │   ├── jwt/               (seed corpus: valid tokens, edge cases)
│   │   └── policy/            (seed corpus: valid policies, deep JSON)
│   ├── fuzz_jwt.zig
│   └── fuzz_policy.zig
└── src/
    └── integration_test.zig   (wired + extended with U1, U2)
```

---

## Dependency Graph

```
U0a (wire orphan → security step) ──→ U1 (valid paths) ──→ U2 (error paths)
│                                       │                       │
│                                       │                       │
U0b (fuzz infra) ──→ U3 (JWT fuzz)     └── U5 (coverage) ←─────┘
                  └─→ U4 (policy fuzz)         ↑
                                               └── U0c (coverage tooling research)
```

---

## Implementation Units

### U0a — Wire Orphaned Test Files into Build
**Goal:** Recover ~463 lines of existing-but-never-run tests, and establish `integration_test.zig` as the home for U1/U2.
**Requirements:** (infrastructure prerequisite)
**Dependencies:** None
**Files:**
- Modify: `build.zig`
**Approach:**
- Add `zig build test-security` build step pointing to `src/integration_test.zig`.
- Add `zig build test-audit` build step pointing to `src/audit/integration_test.zig`.
- Add both to the existing `test-all` aggregate step.
**Verification:** `zig build test-security && zig build test-audit` both pass (existing orphaned tests execute correctly).

---

### U0b — Scaffold Fuzzing Infrastructure
**Goal:** Make `zig build fuzz-jwt` and `zig build fuzz-policy` invocable.
**Requirements:** (infrastructure prerequisite)
**Dependencies:** None
**Files:**
- Modify: `build.zig`
- Create: `fuzz/` directory
- Create: `fuzz/corpus/jwt/` (empty, populated during U3)
- Create: `fuzz/corpus/policy/` (empty, populated during U4)
**Approach:**
- Add a `buildFuzzTarget(comptime name: []const u8, source: []const u8)` helper function to `build.zig`.
- Configure: `-fsanitize=fuzzer`, `-fno-omit-frame-pointer`.
- Wire `fuzz/fuzz_jwt.zig` and `fuzz/fuzz_policy.zig`.
**Verification:** `zig build fuzz-jwt -- --help` prints libFuzzer help (binary links correctly).

---

### U0c — Coverage Tooling Research
**Goal:** Determine how to measure line coverage for Zig 0.17.0-dev.
**Requirements:** (infrastructure prerequisite)
**Dependencies:** None
**Files:** None (research task)
**Approach:**
- Test: `kcov`, `grcov`, `zig test --color` branch analysis, or other approaches.
- Document the chosen approach for U5.
**Verification:** A generated coverage report exists for at least `src/auth/jwt.zig`.

---

### U1 — Integration Tests: Valid Path
**Goal:** Verify that a correctly signed, non-expired JWT with appropriate permissions allows a request.
**Requirements:** R1
**Dependencies:** U0a (file must be wired)
**Files:**
- Modify: `src/integration_test.zig`
**Approach:**
- Reuse existing `generateTestJWT()` from `src/auth/jwt.zig` — do not recreate.
- Audit `src/e2e_server_test.zig` to understand existing coverage and avoid duplication.
- Mock a request with valid JWT and a path allowed by policy.
- Assert response status is 200 OK.
**Test scenarios:**
- Happy path: Valid JWT + Allowed Path -> 200 OK.
- Happy path: Valid JWT + Multiple Permissions -> 200 OK.
**Verification:** `zig build test-security` passes U1 scenarios.

---

### U2 — Integration Tests: Error Paths
**Goal:** Verify that invalid or malicious tokens are rejected.
**Requirements:** R1
**Dependencies:** U1
**Files:**
- Modify: `src/integration_test.zig`
**Approach:**
- Implement a suite of "negative" tests targeting the Auth Engine.
- Reuse `generateExpiredJWT()` from `src/auth/jwt.zig`.
- Mock requests with various failure modes.
**Test scenarios:**
- Expired JWT -> 401 Unauthorized.
- Tampered signature -> 401 Unauthorized.
- Wrong secret -> 401 Unauthorized.
- Valid JWT + Denied Path (Policy) -> 403 Forbidden.
- Malformed JWT (invalid base64, wrong format, missing parts) -> 401 Unauthorized.
- Oversized JWT payload (near HMAC 192-byte boundary) -> graceful error (no panic).
**Verification:** `zig build test-security` passes U2 scenarios.

---

### U3 — JWT Fuzzing Target
**Goal:** Ensure `JWT.parse` and `JWT.verify` cannot be crashed by arbitrary byte sequences.
**Requirements:** R2
**Dependencies:** U0b (fuzz infra)
**Files:**
- Create: `fuzz/fuzz_jwt.zig`
- Modify: `src/auth/jwt.zig` (fix `page_allocator` leak so fuzzer doesn't OOM)
**Approach:**
- Implement the `fuzz` entry point required by libFuzzer.
- **Call `verify` after `parse`** — the HMAC buffer overflow lives in the verify path, not parse. A parse-only fuzzer will miss it.
- Use a dedicated arena allocator for each fuzz iteration.
- **Fix `page_allocator` leak** in `parseHeader()`/`parsePayload()` or wrap in the same arena to prevent fuzzer OOM.
- Pre-populate seed corpus `fuzz/corpus/jwt/` with valid tokens, expired tokens, edge-case base64, and tokens near the 192-byte HMAC boundary.
**Fuzzing loop:**
```
for each fuzz input:
  1. Reset arena
  2. Call JWT.parse(input, arena)
  3. If parse succeeds, call JWT.verify(parsed_jwt, test_secret)
  4. (verify exercises SHA256/SHA384/SHA512 HMAC → catches stack overflow)
```
**Test scenarios:**
- Empty input.
- Extremely large input (exceeds HMAC buffer limits).
- Random binary data.
- Tokens with payload exactly at/above 192 bytes (HS256 boundary).
**Verification:** `zig build fuzz-jwt -- -runs=10000` — no crashes, no panics.

---

### U4 — Policy Fuzzing Target
**Goal:** Ensure `PolicyFile.parse` is robust against malformed JSON or unexpected policy structures.
**Requirements:** R2
**Dependencies:** U0b (fuzz infra)
**Files:**
- Create: `fuzz/fuzz_policy.zig`
**Approach:**
- Implement the `fuzz` entry point for libFuzzer.
- Pass input to `PolicyFile.parse` (not `Policy.parse` — correct API name).
- Use a dedicated arena allocator for each fuzz iteration.
- Verify that all memory allocated during parsing is freed even on failure.
- Pre-populate seed corpus `fuzz/corpus/policy/` with valid policies, deeply nested JSON, unicode paths, and large arrays.
**Test scenarios:**
- Invalid JSON syntax.
- Deeply nested JSON objects (recursion depth test).
- Missing required policy fields.
- Extremely large input.
**Verification:** `zig build fuzz-policy -- -runs=10000` — no crashes, no leaks.

---

### U5 — Coverage Validation
**Goal:** Quantify test effectiveness and identify gaps.
**Requirements:** R3
**Dependencies:** U0a, U0c, U1, U2
**Files:**
- Modify: `build.zig` (or a script) for coverage tooling
**Approach:**
- Run coverage tool (determined in U0c) on `zig build test-all`.
- Analyze uncovered branches in `jwt.zig`, `parser.zig`, and `engine.zig`.
- If <85%, add targeted unit tests for remaining uncovered branches.
- The wiring of orphaned `integration_test.zig` and `audit/integration_test.zig` (U0a) already contributes ~463 lines of tested code toward the target.
**Verification:** Coverage report confirms > 85% line coverage.

---

## System-Wide Impact
- **Error propagation**: Fuzzing tests must verify that errors are handled gracefully (via `try` or `catch`) and do not result in `panic`.
- **State lifecycle**: Fuzzing targets must explicitly reset allocators to avoid OOM crashes during long runs.
- **HMAC buffer overflow fix**: The stack buffer overflow in `hmacSha256`/`hmacSha384`/`hmacSha512` must be fixed or protected before fuzzing can meaningfully verify robustness. The fuzzer should still be run against the unfixed version to confirm it catches the crash.
- **page_allocator leak fix**: JWT parser's use of `std.heap.page_allocator.dupe()` must be converted to arena-based allocation to prevent fuzzer OOM.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Fuzzer finds crash in `std` | Report to Zig community; isolate the crash to determine if it's a logic error in AgentGate. |
| Coverage target not met | Add targeted unit tests for remaining uncovered branches identified in U5. |
| HMAC buffer overflow pre-existing | Fix the overflow in `jwt.zig` as part of U3; verify fix with fuzzer. |
| page_allocator leak causes fuzzer OOM | Convert to arena-based allocation in U3 before fuzzing. |
| Coverage tooling doesn't work with Zig 0.17.0-dev | Fall back to manual branch analysis using compiler warnings and test annotations. |
