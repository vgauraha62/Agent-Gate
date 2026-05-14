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

### Phase 6: End-to-End Request Processing & Concurrency (Complete)
- [x] Full request lifecycle implementation.
- [x] High-concurrency handling.
- [x] Audit logs capture policy IDs and identities.
- [x] Full flow latency <100µs.

### Phase 7: Audit Logging System (Complete)
- [x] Ring buffer audit log (`src/audit/logger.zig`).
- [x] Merkle tree integrity mechanism.
- [x] Cryptographic signing of root hash.
- [x] Verification & Export methods.

---

### Phase 8: Metrics & Monitoring (Active)

**Goal:** Implement Prometheus-compatible metrics endpoint for real-time observability.

### Requirements
- R1. Atomic counters for `requests_total`, `allowed_total`, `denied_total`.
- R2. HDR Histogram for request latency (P99 focus).
- R3. Gauge for `active_sessions`.
- R4. `/metrics` endpoint returning plaintext Prometheus format.
- R5. Low-overhead recording (sub-microsecond).

### Implementation Units
- [ ] U1. **Metrics Core**: Implement `Metrics` struct in `src/metrics/prometheus.zig` using `std.atomic`.
- [ ] U2. **Latency Tracking**: Integrate HDR histogram for high-precision latency buckets.
- [ ] U3. **Prometheus Exporter**: Implement `export()` method to write metrics in Prometheus text format.
- [ ] U4. **HTTP Integration**: Add `/metrics` route to `src/server/http.zig` and link to `Metrics` instance.
- [ ] U5. **Validation**: Verify output with `curl` and validate latency recording accuracy.

### Dependencies
- Phase 6/7 Server and Request flow.
- `std.atomic` for lock-free counters.

### Verification
- [ ] `curl localhost:8080/metrics` returns valid Prometheus data.
- [ ] Counters increment correctly under load.
- [ ] P99 latency reflects real-world request timing.
