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

### Phase 8: Metrics & Monitoring (Complete)
- [x] U1. Metrics Core: Implement `Metrics` struct in `src/metrics/prometheus.zig` using `std.atomic`.
- [x] U2. Latency Tracking: Integrate HDR histogram for high-precision latency buckets.
- [x] U3. Prometheus Exporter: Implement `export()` method to write metrics in Prometheus text format.
- [x] U4. HTTP Integration: Add `/metrics` route to `src/server/http.zig` and link to `Metrics` instance.
- [x] U5. Validation: Verify output with `curl` and validate latency recording accuracy.

---

### Phase 9: mTLS Support (Active)

**Goal:** Implement mutual TLS for agent authentication.

### Requirements
- R1. Mutual authentication: Server validates client cert, client validates server cert.
- R2. Identity derivation: Derive `agent_id` from client certificate hash.
- R3. Secure config: Load CA, server cert, and server key from secure storage.
- R4. Seamless integration: `TLSServer` wraps standard TCP listener.

### Implementation Units
- [ ] U1. **mTLS Core**: Implement `TLSConfig` and `TLSServer` in `src/auth/mtls.zig` using `std.crypto.tls`.
- [ ] U2. **Identity Mapping**: Implement `hashCertificate` to derive `agent_id` from peer certificate.
- [ ] U3. **Server Integration**: Update `src/server/http.zig` to support TLS handshake during connection acceptance.
- [ ] U4. **Cert Tooling**: Create shell scripts for generating test CA, server, and agent certificates via `openssl`.
- [ ] U5. **Validation**: Verify successful mutual handshake and rejection of invalid/missing client certificates.

### Dependencies
- `std.crypto.tls` for handshake logic.
- Valid X.509 certificates for testing.

### Verification
- [ ] `curl --cert agent.crt --key agent.key --cacert ca.crt https://localhost:8080/check` works.
- [ ] `curl https://localhost:8080/check` (no cert) returns TLS alert/error.
- [ ] `agent_id` derived from cert matches expected SHA256 hash.
