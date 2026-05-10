# Task Plan: AgentGate Implementation

## Goal
Build a lightweight agent security sidecar in Zig. Prototype ready for acquisition demo by Day 15.

## Phases

### Phase 1: Project Setup & Directory Structure (Complete)
- [x] Initialize Zig project
- [x] Configure `build.zig`
- [x] Create directory structure
- [x] Initial documentation (README, ARCHITECTURE, THREAT_MODEL)

### Phase 2: Core Data Structures & Memory Management (Complete)
- [x] Custom arena allocator (`src/memory.zig`)
- [x] Zeroizing secret container (`src/secret.zig`)
- [x] Agent context structure (`src/agent.zig`)
- [x] Memory safety tests

### Phase 3: Authentication Engine (JWT) (Complete)
- [x] JWT parser and verifier
- [x] Constant-time comparison
- [x] Signature verification (HMAC)
- [x] Expiration and tampering tests

### Phase 4: Policy Engine Foundation (Complete)
- [x] JSON policy language design
- [x] Policy parser and evaluator
- [x] Compile-time policy generation
- [x] Performance benchmark (<100µs for 1000 policies)

### Phase 5: HTTP Server Foundation (Complete)
- [x] Minimal HTTP server (epoll-based)
- [x] Request parsing
- [x] Basic routing
- [x] Integration with Auth/Policy/Audit for `/check` endpoint

---

### Phase 6: End-to-End Request Processing & Concurrency (Complete)

**Goal:** Seamlessly integrate Auth, Policy, and Audit modules. Resolve secret management and policy attribution gaps. Verify performance under concurrency.

### Requirements
- R1. Full request lifecycle implementation.
- [x] R2. High-concurrency handling (epoll/worker distribution).
- [x] R3. Audit logs capture specific policy IDs and agent identities.
- [x] R4. Full flow latency <100µs.

### Implementation Units (from docs/plans/2026-05-09-001-feat-day6-end-to-end-request-processing-plan.md)
- [x] U1. **Detailed Policy Decisions**: Update `PolicyEngine.evaluate` to return `Decision` (Effect + Policy ID).
- [x] U2. **Dynamic Secret Injection**: Inject `JWT_SECRET` via `Config` instead of hardcoding.
- [x] U3. **Hardened Request Lifecycle**: Improve I/O error handling and resource cleanup in `src/server/http.zig`.
- [x] U4. **E2E Integration Test Suite**: Create `src/integration_test_e2e.zig` to validate full path.
- [x] U5. **Concurrency Stress Test**: Run high-load benchmarks (`scripts/stress_test_day6.sh`) to verify stability and P99 latency.

### Dependencies
- Day 5 Server foundation.
- Day 4 Policy engine.
- Day 3 Auth engine.

### Verification
- [x] `zig build test` passes (including E2E tests).
- [x] Audit logs contain correct `policy_id`.
- [x] Stress test shows stable memory and <100µs P99 latency.

---

## Phase 7: Audit Logging System (Active)

**Goal:** Implement tamper-evident audit log with cryptographic verification.

### Requirements
- R1. Ring buffer for high-performance logging.
- R2. Merkle tree for integrity proof.
- R3. Cryptographic signing of root hash.
- R4. Support for export and verification.

### Implementation Units (from PRD.md)
- [ ] U1. **Ring Buffer Audit Log**: Implement `AuditLog` in `src/audit/logger.zig` with `LogEntry` (timestamp, agent_id, path, decision, request_hash).
- [ ] U2. **Integrity Mechanism**: Implement Merkle tree root updates for each single entry.
- [ ] U3. **Cryptographic Proof**: Sign new root with server private key after each entry.
- [ ] U4. **Verification & Export**: Implement `verify()` and `export()` methods.

### Dependencies
- Phase 6 E2E flow.
- `std.crypto` for hashing and signing.

### Verification
- [ ] `zig build test` for audit log ring buffer wrap-around.
- [ ] Verify tamper detection (modify entry $\rightarrow$ hash mismatch).
- [ ] Verify cryptographic signature of Merkle root.

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| | | |

## Decisions
| Decision | Rationale |
|----------|-----------|
| Return `Decision` struct from Policy Engine | Needed for detailed audit logs (Policy ID attribution). |
| Inject secrets via `Config` | Security: avoid hardcoded secrets; support rotation. |
