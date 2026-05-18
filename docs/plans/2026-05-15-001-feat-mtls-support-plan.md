---
title: feat: mTLS Support for Agent Authentication
type: feat
status: active
date: 2026-05-15
origin: PRD.md
---

# mTLS Support for Agent Authentication

## Overview

Implement mutual TLS (mTLS) to provide a strong, certificate-based identity layer for agents. This replaces or complements JWT authentication by ensuring only agents with valid, CA-signed certificates can connect to the sidecar.

---

## Problem Frame

Currently, the sidecar relies on JWTs for identity. While effective, JWTs can be stolen. mTLS provides transport-layer security and cryptographically proves the identity of the agent via a X.509 certificate before any HTTP data is exchanged.

---

## Requirements Trace

- R1. **Mutual Authentication**: Server must validate client certificate against trusted CA; client must validate server certificate.
- R2. **Identity Derivation**: The `agent_id` ([32]u8) must be deterministically derived from the client's certificate (SHA256 of DER).
- R3. **Secure Configuration**: CA, server certificate, and server private key must be loadable from disk.
- R4. **Seamless Integration**: The mTLS layer must wrap the existing TCP listener without breaking the high-performance epoll loop.

---

## Scope Boundaries

- This plan focuses on the TLS handshake and identity derivation.
- **Non-goals**:
    - CRL (Certificate Revocation List) or OCSP checking (deferred to future security hardening).
    - Support for non-X.509 certificates.
    - Client-side certificate management (AgentGate is the server).

### Deferred to Follow-Up Work

- Integration with a formal PKI (e.g., HashiCorp Vault) for automated cert rotation.
- Optimizing TLS handshake latency using session resumption.

---

## Context & Research

### Relevant Code and Patterns

- `src/server/http.zig`: Current server uses raw `c_int` FDs and `std.posix.socket`. The mTLS layer must integrate here.
- `src/agent.zig`: Defines `Agent` struct with `id: [32]u8`. The mTLS layer will provide this ID.
- `src/secret.zig`: Use `Secret` container for the server's private key.

### Institutional Learnings

- The current server uses a thread-per-request model with a bounded pool. The TLS handshake should happen before the request is handed off to the pool to avoid wasting worker threads on unauthenticated connections.

### External References

- `std.crypto.tls`: Zig's standard library TLS implementation (will be used for the handshake).
- X.509 Standard: DER encoding is used for the deterministic hash of the certificate.

---

## Key Technical Decisions

- **Identity Hash**: Use SHA256 of the raw DER-encoded client certificate as the `agent_id`. This ensures a stable, 32-byte identifier consistent with the `Agent` struct.
- **Handshake Placement**: Perform the TLS handshake in the `acceptConnections` loop (or immediately after) before the FD is passed to the thread pool. This prevents "slowloris" style attacks on the thread pool by filtering unauthenticated clients at the edge.
- **Memory Strategy**: Use `Secret` for the server's private key to ensure it is zeroized on shutdown.

---

## Implementation Units

- [ ] U1. **mTLS Core Logic**

**Goal:** Implement TLS configuration and server wrapper.

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- Create: `src/auth/mtls.zig`

**Approach:**
- Implement `TLSConfig` struct to hold CA cert, server cert, and server private key.
- Implement `TLSServer` that wraps a `std.net.Server` (or raw FD) and provides a `TLSStream`.
- Use `std.crypto.tls` to configure mutual authentication (`client_auth = .require`).

**Test scenarios:**
- Happy path: Valid server/client certs result in successful handshake.
- Error path: Client with no certificate is rejected.
- Error path: Client with certificate signed by unknown CA is rejected.
- Error path: Server with expired certificate causes client failure.

**Verification:**
- `TLSServer.accept()` returns a valid stream and a peer certificate.

- [ ] U2. **Identity Derivation**

**Goal:** Extract `agent_id` from the peer certificate.

**Requirements:** R2

**Dependencies:** U1

**Files:**
- Modify: `src/auth/mtls.zig`

**Approach:**
- Implement `hashCertificate(cert: []const u8) [32]u8`.
- Use `std.crypto.sha2.sha256` to hash the DER-encoded certificate.

**Test scenarios:**
- Happy path: Same certificate always produces same `agent_id`.
- Edge case: Empty certificate data returns error/failure.

**Verification:**
- `hashCertificate` returns a 32-byte array matching the expected SHA256 of a test cert.

- [ ] U3. **Server Integration**

**Goal:** Integrate mTLS into the HTTP server lifecycle.

**Requirements:** R4

**Dependencies:** U1, U2

**Files:**
- Modify: `src/server/http.zig`

**Approach:**
- Add `tls_config: ?TLSConfig` to `Server` struct.
- Modify `acceptConnections` to wrap the accepted `client_fd` with a TLS handshake if `tls_config` is present.
- Update `handleClientAsync` to pass the derived `agent_id` to the request handler.
- Ensure `handleRequestThread` uses this `agent_id` as the authenticated identity for policy checks.

**Execution note:** Start by implementing a "TLS-aware" wrapper for the raw FD to avoid breaking the epoll logic.

**Test scenarios:**
- Integration: `curl` with certs can reach `/health`.
- Integration: `curl` without certs is rejected at the TLS layer.

**Verification:**
- Server accepts mTLS connections and correctly identifies agents by their cert hash.

- [ ] U4. **Certificate Tooling**

**Goal:** Provide scripts to generate test PKI.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Create: `scripts/gen_certs.sh`

**Approach:**
- Use `openssl` to generate:
    1. Root CA key/cert.
    2. Server key/cert (signed by CA).
    3. Multiple Agent keys/certs (signed by CA).

**Test expectation: none** -- Script execution is verified by the presence of files.

**Verification:**
- Running `./scripts/gen_certs.sh` produces all required `.crt` and `.key` files.

- [ ] U5. **Integration Validation**

**Goal:** End-to-end verification of mTLS identity and policy enforcement.

**Requirements:** R1, R2, R4

**Dependencies:** U1, U2, U3, U4

**Files:**
- Create: `src/auth/mtls_test.zig`

**Approach:**
- Create a test suite that:
    1. Starts the server with mTLS enabled.
    2. Uses a Zig client (or `curl`) to send requests with different certificates.
    3. Verifies that the `agent_id` in the audit log matches the cert hash.
    4. Verifies that denied certificates are rejected.

**Test scenarios:**
- Happy path: Agent A (valid cert) is allowed.
- Happy path: Agent B (valid cert) is allowed.
- Error path: Agent C (invalid cert) is rejected.
- Integration: The `agent_id` derived from TLS is used as the `Agent` context for policy evaluation.

**Verification:**
- All integration tests pass.

---

## System-Wide Impact

- **Interaction graph**: The TCP connection is now upgraded to TLS before the HTTP parser sees any bytes.
- **Error propagation**: TLS handshake failures result in immediate connection closure, bypassing the HTTP handler.
- **State lifecycle risks**: Server private key must be handled as a `Secret` to prevent memory leaks of the key.
- **Unchanged invariants**: The HTTP request parsing and policy evaluation logic remains identical; only the source of the `agent_id` changes (from JWT to TLS cert).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `std.crypto.tls` API instability | Use a wrapper in `mtls.zig` to isolate the std library's TLS implementation. |
| Handshake latency overhead | Use a dedicated thread for handshakes or optimize with `std.crypto.tls` settings. |
| Certificate format mismatch | Strictly use DER encoding for hashing to ensure portability. |

---

## Sources & References

- **Origin document:** [PRD.md](PRD.md)
- Related code: `src/server/http.zig`, `src/agent.zig`
