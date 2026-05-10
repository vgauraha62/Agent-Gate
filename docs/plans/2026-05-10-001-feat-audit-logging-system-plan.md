---
title: feat: Tamper-Evident Audit Logging System
type: feat
status: active
date: 2026-05-10
origin: PRD.md
---

# Tamper-Evident Audit Logging System

## Overview

Implement a high-performance, cryptographically verifiable audit logging system. The goal is to replace the basic ring buffer with a tamper-evident structure using a Merkle-style hash chain and digital signatures to ensure non-repudiation and integrity of all security decisions.

---

## Problem Frame

The current audit logger is a simple in-memory circular buffer. While functional for debugging, it lacks integrity guarantees. An attacker with memory access could modify previous log entries to hide unauthorized access. To meet security requirements, the log must be "append-only" in a cryptographic sense, where any modification to history invalidates the current state.

---

## Requirements Trace

- R1. Implement a high-performance ring buffer for log entries.
- R2. Implement a Merkle-style hash chain for integrity verification.
- R3. Digitally sign the root hash of the log to provide authenticity.
- R4. Provide mechanisms to export and verify the log.
- R5. Ensure minimal impact on request latency (<100µs target).

---

## Scope Boundaries

- **Non-goals**:
    - Persistent disk storage (logs remain in-memory for this prototype, but the structure supports persistence).
    - Remote WORM storage integration.
    - Complex key rotation schemes (will use a single server private key).

### Deferred to Follow-Up Work
- Asynchronous background flushing thread (will implement synchronous commitment for the prototype to ensure correctness first).

---

## Context & Research

### Relevant Code and Patterns
- `src/audit/logger.zig`: Existing `AuditLogger` with ring buffer pattern.
- `src/auth/jwt.zig`: Use of `std.crypto.hash.sha2` and `secureCompare`.
- `src/secret.zig`: `Secret` container for managing the signing key.

### Institutional Learnings
- Current ring buffer uses `index % MAX_ENTRIES`; should move to power-of-two masking for performance.
- Memory zeroization patterns in `secret.zig` should be applied to the signing key.

### External References
- Merkle Mountain Ranges (MMR) for efficient appending.
- BLAKE3 for high-performance hashing (if available in `std.crypto`, otherwise SHA-256).
- Ed25519 for compact, fast digital signatures.

---

## Key Technical Decisions

- **Hash Algorithm**: Use SHA-256 (via `std.crypto.hash`) for consistency with current JWT implementation, moving to BLAKE3 if performance bottlenecks are identified.
- **Integrity Model**: Implement a hash chain where `Entry[N].hash = hash(Entry[N].data + Entry[N-1].hash)`. This provides a linear Merkle proof.
- **Signing**: Sign the latest "tail" hash using an Ed25519 private key stored in a `Secret` container.
- **Buffer Sizing**: Fix buffer size to a power of two (e.g., 1024) to replace modulo with bitwise AND.

---

## Open Questions

### Resolved During Planning
- **How to handle wrap-around in hash chain?** The chain will be logical. When the physical buffer wraps, the sequence number continues to increment, and the hash chain persists across the wrap boundary.

### Deferred to Implementation
- **Precise Ed25519 wrapper**: Determine the most ergonomic way to use `std.crypto.pallas` or similar for signatures in current Zig version.

---

## Output Structure

```
src/audit/
├── logger.zig       # Main AuditLog struct, ring buffer logic, and hash chain
├── crypto.zig      # Hashing and signing helpers (new)
└── types.zig       # LogEntry and Decision types (refactored)
```

---

## Implementation Units

- [ ] U1. **Refactor Log Data Structures**

**Goal:** Define `LogEntry` and `AuditLog` with support for hash chaining.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `src/audit/logger.zig`
- Create: `src/audit/types.zig`

**Approach:**
- Move `LogEntry` to `types.zig`.
- Add `previous_hash: [32]u8` and `current_hash: [32]u8` to `LogEntry`.
- Update `AuditLog` to use power-of-two size and masking.

**Test scenarios:**
- Happy path: LogEntry correctly holds previous hash.
- Edge case: Initial entry has zeroed previous hash.

**Verification:** `zig build test` confirms struct alignment and initialization.

---

- [ ] U2. **Implement Hash Chaining Logic**

**Goal:** Ensure every log entry is cryptographically linked to the previous one.

**Requirements:** R2

**Dependencies:** U1

**Files:**
- Modify: `src/audit/logger.zig`

**Approach:**
- Implement `computeEntryHash(entry: LogEntry) [32]u8`.
- In `log()` method, fetch the hash of the previous entry and update the new entry's `previous_hash` before computing its own `current_hash`.

**Test scenarios:**
- Happy path: Sequence of 3 logs forms a valid chain.
- Error path: Modifying an early entry in the chain invalidates all subsequent hashes.

**Verification:** Test that changing one byte in entry $N$ results in a hash mismatch for entry $N+1$.

---

- [ ] U3. **Implement Root Signing**

**Goal:** Sign the latest log hash to prevent history rewrite attacks.

**Requirements:** R3

**Dependencies:** U2

**Files:**
- Create: `src/audit/crypto.zig`
- Modify: `src/audit/logger.zig`
- Modify: `src/secret.zig` (if needed for key loading)

**Approach:**
- Create a signing utility in `crypto.zig` using Ed25519.
- Add `signing_key: Secret` to `AuditLog`.
- Add `signTail()` method that signs the `current_hash` of the latest entry.

**Test scenarios:**
- Happy path: Signed root can be verified with public key.
- Error path: Invalid signature fails verification.

**Verification:** Successful verification of the log tail signature.

---

- [ ] U4. **Verification and Export API**

**Goal:** Provide a way to verify the entire log's integrity.

**Requirements:** R4

**Dependencies:** U3

**Files:**
- Modify: `src/audit/logger.zig`

**Approach:**
- Implement `verifyIntegrity() bool` which iterates through the buffer, recalculating hashes and checking the chain.
- Implement `exportLog()` to dump entries in a verifiable format (JSON/Binary).

**Test scenarios:**
- Happy path: Intact log passes `verifyIntegrity()`.
- Error path: Tampered log (single bit flip) fails `verifyIntegrity()`.
- Integration: Exported log can be reconstructed and verified externally.

**Verification:** `verifyIntegrity()` returns true for valid logs and false for tampered ones.

---

## System-Wide Impact

- **Interaction graph:** `src/server/http.zig` calls `AuditLog.log()`. This now involves hashing and potentially signing, increasing the CPU cost per request.
- **Error propagation:** Hashing/Signing failures should be treated as critical errors; if the log cannot be committed, the security sidecar must decide whether to fail-open or fail-closed (Default: Fail-closed).
- **State lifecycle risks:** The `Secret` key must be properly zeroized.
- **Unchanged invariants:** The HTTP request/response flow remains the same; only the internal logging mechanism changes.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| CPU Overhead of Hashing | Use SHA-256 (fast) and avoid signing every single entry; sign only at checkpoints or on request. |
| Memory Exhaustion | Fixed-size ring buffer prevents unbounded growth. |
| Key Compromise | Use `Secret` container and suggest hardware-backed keys in future iterations. |

---

## Sources & References

- **Origin document:** [PRD.md](PRD.md)
- Local research on `src/audit/logger.zig`
- External best practices on Merkle Chains.
