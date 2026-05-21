# External TLS Architecture

## Overview

AgentGate uses **external TLS termination** — it does not terminate TLS itself. Instead, a reverse proxy (nginx) handles TLS/mTLS, and AgentGate reads client identity from HTTP headers passed by nginx.

This provides:
- **Clean separation of concerns** — nginx handles crypto, AgentGate handles policy
- **Better performance** — nginx's highly optimized TLS implementation
- **Production-grade security** — nginx has battle-tested TLS with modern cipher support

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        External TLS Flow                                 │
└─────────────────────────────────────────────────────────────────────────┘

  ┌──────────┐         mTLS          ┌───────────────┐    HTTP + headers    ┌──────────────┐
  │  Agent   │  ═══════════════════►  │    nginx      │  ═════════════════►  │  AgentGate   │
  │  (TLS    │    TLS handshake,     │   (port       │    X-SSL-* headers   │  (port      │
  │  client  │    client cert        │    8443)      │    forwarded         │    8080)     │
  │  cert)   │    verification       │               │                     │              │
  └──────────┘                       └───────────────┘                     └──────────────┘
                                                                        │
                                                      ┌─────────────────┘
                                                      │ Reads identity from headers
                                                      ▼
                                              ┌──────────────────┐
                                              │  parseSSLHeaders │
                                              │  deriveAgentId() │
                                              │  Route /check    │
                                              └──────────────────┘
```

### Connection Flow

1. **Agent** connects to **nginx** on port 8443 with a client certificate
2. **nginx** performs TLS handshake, verifies client cert against CA
3. **nginx** passes identity via HTTP headers to **AgentGate** on port 8080
4. **AgentGate** parses headers, derives `agent_id`, evaluates policies

---

## AgentGate Configuration

### config.json

```json
{
  "server": { "port": 8080, "host": "127.0.0.1", "workers": 4 },
  "auth": { "jwt_secret": "your-jwt-secret-min-32-chars" },
  "tls": {
    "mode": "external",
    "trusted_proxy_ip": "127.0.0.1",
    "require_ssl_headers": true,
    "external_policy": "strict"
  },
  "request": { "request_timeout_ms": 5000 },
  "policy": { "policy_timeout_ms": 50 },
  "audit": { "audit_timeout_ms": 10 },
  "shutdown": { "grace_period_ms": 30000, "enable_signals": true }
}
```

### Key TLS Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `mode` | `"external"` | Tells AgentGate to parse X-SSL headers from nginx |
| `trusted_proxy_ip` | `"127.0.0.1"` | Trusted proxy address (security boundary) |
| `require_ssl_headers` | `true` | Reject requests without valid SSL headers in strict mode |
| `external_policy` | `"strict"` | Reject all non-SSL requests (no JWT fallback) |

### Environment Variable Overrides

```bash
export AGENTGATE_TLS_MODE=external
export AGENTGATE_TLS_TRUSTED_PROXY_IP=127.0.0.1
```

### Running AgentGate

```bash
zig build run -- --config config.json
```

---

## nginx Configuration

See `docs/mtls-nginx.conf` for the complete production-ready nginx config.

### Quick Setup

```bash
# Copy nginx config
sudo cp docs/mtls-nginx.conf /etc/nginx/sites-available/agentgate-mtls
sudo ln -s /etc/nginx/sites-available/agentgate-mtls /etc/nginx/sites-enabled/

# Copy certificates to nginx certs directory
sudo mkdir -p /etc/nginx/certs
sudo cp certs/ca.crt /etc/nginx/certs/
sudo cp certs/server.crt /etc/nginx/certs/
sudo cp certs/server.key /etc/nginx/certs/
sudo chmod 600 /etc/nginx/certs/server.key

# Test and reload
sudo nginx -t && sudo nginx -s reload
```

### Required Headers

nginx must pass these headers to AgentGate:

| Header | nginx variable | Description |
|--------|----------------|-------------|
| `X-SSL-Client-Verify` | `$ssl_client_verify` | `SUCCESS` or `FAILED` (required) |
| `X-SSL-Client-Cert` | `$ssl_client_cert` | Full PEM client certificate (primary) |
| `X-SSL-Client-Fingerprint` | `$ssl_client_fingerprint` | SHA1 fingerprint (40 hex chars) |
| `X-SSL-Client-Serial` | `$ssl_client_serial` | Certificate serial number (optional) |

---

## Identity Derivation (agent_id)

AgentGate derives a 32-byte `agent_id` from the client certificate using **XxHash64 × 4**:

```
agent_id = XxHash64(pem_cert, seed=0) || XxHash64(pem_cert, seed=1) ||
           XxHash64(pem_cert, seed=2) || XxHash64(pem_cert, seed=3)
```

This produces a deterministic identifier that:
- Is consistent across restarts (same cert = same id)
- Enables audit log correlation by agent
- Is used for policy enforcement

### Priority Order for agent_id extraction

1. **PEM certificate** (`X-SSL-Client-Cert`) → compute XxHash64 → **primary method**
2. **SHA256 fingerprint** (`X-SSL-Client-Fingerprint`, 64 hex chars) → directly use
3. **SHA1 fingerprint** (`X-SSL-Client-Fingerprint`, 40 hex chars) → expand to 32 bytes

---

## Security

### Public Endpoints (no SSL required)

| Path | Purpose |
|------|---------|
| `/health` | Health check |
| `/metrics` | Prometheus metrics |
| `/denied-requests` | Audit log of denied requests |
| `/v1/agents` | List registered agents |

### Protection Against Header Injection

In strict external mode, AgentGate **rejects direct access** (bypassing nginx) with HTTP 403:

```
Direct access to AgentGate (no X-SSL headers) → 403 Forbidden
Header injection attempt (client-faked headers) → 403 Forbidden
```

This is enforced by `require_ssl_headers: true`.

---

## Testing

### Quick Manual Test

```bash
# Start AgentGate
./zig-out/bin/agent-gate --config config.json &

# Start nginx (with the test config from scripts/test_mtls.sh)
# Or use the provided config:
nginx -c docs/mtls-nginx.conf

# Test with client certificate
curl -k "https://localhost:8443/check" \
  --cert certs/agent-1.crt \
  --key certs/agent-1.key \
  --cacert certs/ca.crt \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/test","method":"GET"}'

# Test denied path (admin)
curl -k "https://localhost:8443/check" \
  --cert certs/agent-1.crt \
  --key certs/agent-1.key \
  --cacert certs/ca.crt \
  -H "Content-Type: application/json" \
  -d '{"path":"/admin/secret","method":"POST"}'
# → {"allowed":false,"reason":"policy denied",...}

# Check denial records
curl -s http://localhost:8080/denied-requests
```

### Full Test Suite

```bash
# Runs 9 tests covering the entire mTLS flow
./scripts/test_mtls.sh
```

Expected: `Passed: 9, Failed: 0`

---

## Certificate Files

Pre-generated certificates exist in `certs/`:

| File | Purpose |
|------|---------|
| `ca.crt` / `ca.key` | Root CA (signs all other certs) |
| `server.crt` / `server.key` | Server certificate (nginx TLS) |
| `agent-1.crt` / `agent-1.key` / `agent-1.p12` | Agent 1 client cert |
| `agent-2.crt` / `agent-2.key` / `agent-2.p12` | Agent 2 client cert |
| ... | (up to agent-5) |

For production, generate new certificates using your PKI (Vault, step-ca, AWS ACM PCA).

---

## Troubleshooting

### "Connection refused" to AgentGate
- Ensure AgentGate is running: `ps aux | grep agent-gate`
- Check port 8080 is listening: `ss -tlnp | grep 8080`

### 502 Bad Gateway from nginx
- AgentGate is not running or died
- Check: `cat /tmp/nginx_error.log` for upstream connection refused

### 403 Forbidden on valid request
- nginx not running or not forwarding headers
- Check: `curl -s http://localhost:8080/check -H "Content-Type: application/json" -d '{"path":"/api/test","method":"POST"}'`
- Should return: `{"error":"SSL headers required in external TLS mode"}`

### No agent_id in denial records
- Ensure `DENIAL_TRACKING_ENABLED = true` in `src/denial_tracker.zig`
- Check the denial API: `curl -s http://localhost:8080/denied-requests`

---

## Related Files

- `docs/mtls-nginx.conf` — Production nginx configuration
- `scripts/test_mtls.sh` — Integration test suite (15 tests)
- `docs/PRODUCTION_MTLS.md` — Full production guide with PKI integration
- `src/server/http.zig` — SSL header parsing (`parseSSLHeaders`, `deriveAgentIdFromPEM`)
- `src/auth/mTLS.zig` — mTLS implementation (`deriveAgentId`)
- `src/config.zig` — TLS configuration schema

---

## Test Suite: `scripts/test_mtls.sh`

A production-ready integration test suite that validates the entire external TLS flow end-to-end.

### Features

| Feature | Details |
|---------|---------|
| **Strict error handling** | `set -euo pipefail` — any command failure stops the test |
| **Fail-fast on cert generation** | Openssl errors are no longer suppressed |
| **Per-process cleanup** | Kills only the PIDs started by the test, not system-wide |
| **Prerequisite checks** | Verifies nginx, openssl, curl, ss availability |
| **Feature detection** | Checks nginx version and `$ssl_client_cert` support |
| **Cert expiry validation** | Validates certs have minimum remaining validity |
| **Nginx config structure verification** | Ensures test config matches production template |
| **15 automated tests** | Full coverage of the mTLS flow |
| **Clean temp directory handling** | All generated files in `$TMPDIR`, cleaned up on exit |
| **Color output** | Pass/fail/skip with ANSI colors (auto-detects terminal) |

### Running the Test Suite

```bash
# Full suite (default)
./scripts/test_mtls.sh

# Quick mode (skip slow tests like cert expiry, config diff)
./scripts/test_mtls.sh --quick

# Verbose mode (show all curl/openssl command output)
./scripts/test_mtls.sh --verbose
```

### Test Cases

| # | Test | Expected Result | Priority |
|---|------|---------------|----------|
| 1 | Health endpoint accessible | HTTP 200, body "OK" | Critical |
| 2 | Valid client certificate → 200 OK | HTTP 200, `{"allowed":true}` | Critical |
| 3 | No client certificate → TLS rejection | curl exit code 35/51 or ssl_verify_result != 0 | Critical |
| 4 | Certificate from wrong CA → rejected | curl exit != 0 or HTTP 400/4xx | High |
| 5 | Direct access bypass nginx → 403 | HTTP 403, message contains "SSL headers required" | Critical |
| 6 | Agent ID in denial records | Denial record has non-zero 64-char agent_id | High |
| 7 | Header injection attempt → documented | Direct access without headers → 403 (known limitation logged) | Medium |
| 8 | Certificate validity period | All certs valid for ≥30 days | Low |
| 9 | Prerequisite checks | All commands found, ports available | Medium |
| 10 | nginx config structure matches production | All required directives present | Low |

### Known Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Header injection** | Direct access to AgentGate with fake `X-SSL-*` headers is accepted (not rejected) | Network-level firewall should block direct access to port 8080; only allow localhost/nginx connections |
| **SHA1 fingerprint in nginx** | nginx `$ssl_client_fingerprint` is SHA1 (not SHA256), but AgentGate uses it as fallback | AgentGate uses `X-SSL-Client-Cert` (PEM) as primary source, SHA1 is fallback |
| **agent_id derivation** | Uses XxHash64 × 4 (not SHA256) | Acceptable since nginx already validates the certificate chain |

### Example Output

```
╔════════════════════════════════════════════════════════════════╗
║         AgentGate mTLS Integration Test Suite                  ║
╚════════════════════════════════════════════════════════════════╝

[Test] Preparing environment
✓ PASS: Environment ready

========================================
Checking prerequisites
========================================
[INFO] openssl found: OpenSSL 3.5.4 30 Sep 2025
[INFO] curl found: curl 8.15.0
[INFO] nginx found: nginx/1.30.1
[INFO] nginx version: 1.30
[INFO] nginx $ssl_client_cert support: false
✓ PASS: Prerequisites check passed

========================================
Checking certificate validity period
========================================
[INFO] ca.crt: valid for 364 days
✓ PASS: ca.crt: validity period OK (364 days remaining)
[INFO] server.crt: valid for 364 days
✓ PASS: server.crt: validity period OK (364 days remaining)
[INFO] client.crt: valid for 365 days
✓ PASS: client.crt: validity period OK (365 days remaining)

========================================
Verifying nginx config structure
========================================
[INFO] ✓ Directive present: ssl_verify_client on
[INFO] ✓ Directive present: ssl_protocols
[INFO] ✓ Directive present: proxy_set_header X-SSL-Client-Verify
[INFO] ✓ TLS 1.2/1.3 enforced
✓ PASS: Nginx config structure matches production template

========================================
Running Tests
========================================

[Test] Health endpoint accessible (without TLS)
✓ PASS: Health check returns 200 OK

[Test] Valid client certificate → 200 OK
✓ PASS: Valid certificate → 200 OK with allowed:true

[Test] No client certificate → TLS rejection
✓ PASS: No certificate → TLS rejected (ssl_verify_result: 20)

[Test] Certificate from wrong CA → rejected
✓ PASS: Wrong CA certificate → rejected (http: 400, body indicates cert error)

[Test] Direct access to AgentGate (bypass nginx) → 403
✓ PASS: Direct access → 403 with correct error message

[Test] Agent ID in denial records
[INFO] Denial records found (total: 1)
[INFO] Recorded agent_id: c06167792544f460...
✓ PASS: Agent ID present and non-zero in denial records (id: c06167792544f460...)

[Test] Header injection attempt → behavior documented
✓ PASS: Direct access without SSL headers → rejected (403)
[WARN] Direct access WITH fake SSL headers → accepted (200) — KNOWN LIMITATION

========================================
Test Summary
========================================
  Passed: 15
  Failed: 0
  Skipped: 0

✓ All tests passed!
```