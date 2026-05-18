---
title: "feat: External mTLS Support via Nginx Proxy"
type: feat
status: completed
date: 2026-05-18
origin: PRD.md, 2026-05-15-001-feat-mtls-support-plan.md
---

# External mTLS Support via Nginx Proxy

## Overview

Implement mutual TLS (mTLS) using an external nginx proxy as the TLS termination point. AgentGate receives identity information via HTTP headers, avoiding the need to implement TLS handshake in AgentGate itself.

This approach is more suitable for production deployments where nginx is typically the entry point, and provides better separation of concerns.

---

## Problem Frame

The original plan (2026-05-15-001) specified native TLS where AgentGate performs the TLS handshake. However:
1. The Zig standard library's `std.crypto.tls` was not available in the deployed Zig version
2. Production deployments typically use nginx as the TLS termination point anyway
3. External mode provides better performance (nginx handles crypto)

---

## Requirements Trace

- [x] **R1. Mutual Authentication**: Server validates client certificate against trusted CA via nginx
- [x] **R2. Identity Derivation**: The `agent_id` ([32]u8) derived from client certificate SHA256
- [x] **R3. Secure Configuration**: TLS configuration loadable with mode selection
- [x] **R4. Seamless Integration**: Identity available to policy engine without changing HTTP parsing

---

## Implementation Units

### ✅ U1. TLS Configuration Schema

**Goal:** Define TLS mode and configuration options.

**Files:**
- Modify: `src/config.zig`

**Changes:**
- Added `TLSMode` enum: `.disabled`, `.native`, `.external`
- Added `ExternalPolicy` enum: `.strict`, `.permissive`
- Updated `TLSConfig` with:
  - `mode: TLSMode`
  - `trusted_proxy_ip: []const u8`
  - `require_ssl_headers: bool`
  - `enable_pem_fallback: bool`
  - `trusted_headers: []const []const u8`

**Status:** ✅ Complete

---

### ✅ U2. SSL Header Parsing

**Goal:** Parse X-SSL headers from nginx to extract client certificate identity.

**Files:**
- Modify: `src/server/http.zig`

**Changes:**
- Added `SSLClientInfo` struct with fields:
  - `fingerprint: [32]u8` (SHA256)
  - `fingerprint_sha1: [20]u8` (SHA1 fallback)
  - `verified: bool`
  - `serial`, `subject_cn`, `pem_cert`
- Added `parseSSLHeaders()` function
- Added `deriveAgentIdFromPEM()` fallback function

**Status:** ✅ Complete

---

### ✅ U3. Request Handler Integration

**Goal:** Use SSL identity in policy decisions.

**Files:**
- Modify: `src/server/http.zig`, `src/main.zig`

**Changes:**
- Added `tls_mode` and `external_policy` to Server struct
- Updated `handleRequestThread` with priority logic:
  1. Non-zero passed_agent_id (native TLS)
  2. SSL headers → fingerprint → agent_id
  3. PEM cert → compute SHA256 → agent_id
  4. SHA1 fingerprint expanded → agent_id
  5. REJECT (no valid identity in external mode)
- Added security check: returns 403 if bypassing nginx in strict mode

**Status:** ✅ Complete

---

### ✅ U4. Nginx Configuration

**Goal:** Provide production-ready nginx config for mTLS.

**Files:**
- Create: `docs/mtls-nginx.conf`

**Features:**
- mTLS with `ssl_verify_client on`
- Passes headers: X-SSL-Client-Verify, X-SSL-Client-Cert, X-SSL-Client-Fingerprint
- Modern TLS settings (TLSv1.2/1.3, strong ciphers)
- Security headers (HSTS, X-Frame-Options, etc.)

**Status:** ✅ Complete

---

### ✅ U5. Integration Testing

**Goal:** End-to-end verification of mTLS functionality.

**Files:**
- Create: `scripts/test_mtls.sh`

**Tests (9 total):**
1. Health endpoint accessible
2. Valid client certificate → 200 OK
3. No client certificate → TLS rejection
4. Direct access to AgentGate (bypass nginx) → 403
5. Agent ID present in denial records
6. Header injection attempt blocked
7. Cleanup of existing processes

**Status:** ✅ Complete

---

## Alternative Approach vs Original Plan

| Aspect | Original Plan | Implemented |
|--------|---------------|--------------|
| TLS Termination | Native (AgentGate) | External (nginx) |
| Identity Source | TLS handshake | HTTP headers |
| Dependencies | std.crypto.tls | None (header parsing) |
| Complexity | Higher | Lower |

---

## System-Wide Impact

- **Connection flow**: TCP → TLS (nginx) → HTTP + headers → AgentGate
- **Error propagation**: Invalid cert rejected at nginx; missing headers rejected at AgentGate
- **Unchanged invariants**: HTTP parsing and policy evaluation unchanged

---

## Verification

Run the test suite:
```bash
cd /home/gauraha/zig/agent-gate
./scripts/test_mtls.sh
```

Expected output:
```
Passed: 9
Failed: 0

✓ All tests passed!
```

---

## Future Work (Deferred)

- Native TLS mode implementation (if std.crypto.tls becomes available)
- OCSP/CRL certificate revocation checking
- Session resumption for performance
- Integration with HashiCorp Vault for automated cert rotation

---

## Sources

- Original plan: `docs/plans/2026-05-15-001-feat-mtls-support-plan.md`
- PRD: `PRD.md`
- Related code: `src/config.zig`, `src/server/http.zig`, `docs/mtls-nginx.conf`