# JWT Authentication in AgentGate: Current State & Future Path

> **Status**: Library implemented, **not wired into production servers**.
> **Date**: 2026-05-25
> **Core files**: `src/auth/jwt.zig`, `src/server/auth_middleware.zig`, `scripts/jwt_helper.sh`
> **Production status**: DORMANT — the JWT auth middleware is never imported or called by any live server code.

---

## Table of Contents

1. [Current State: Not Wired](#1-current-state-not-wired)
2. [What Exists Today](#2-what-exists-today)
3. [How JWT Auth Would Work (If Wired)](#3-how-jwt-auth-would-work-if-wired)
4. [Shared Secret: The Trust Anchor](#4-shared-secret-the-trust-anchor)
5. [JWT vs mTLS: Comparison](#5-jwt-vs-mtls-comparison)
6. [Use Cases for JWT](#6-use-cases-for-jwt)
7. [What Would Need to Change to Wire JWT](#7-what-would-need-to-change-to-wire-jwt)
8. [Multi-Instance Considerations](#8-multi-instance-considerations)
9. [Generating and Managing JWTs](#9-generating-and-managing-jwts)

---

## 1. Current State: Not Wired

### The Hard Evidence

| File | Uses JWT Auth? | Source of Truth |
|------|---------------|-----------------|
| `src/server/http.zig` (default production server) | ❌ **Never** | Zero references to `Authorization`, `Bearer`, or `AuthMiddleware` |
| `src/server/http_async.zig` (alternative server) | ❌ **Never** | Same — no JWT code path |
| `src/server/http_uring.zig` (experimental server) | ❌ **Never** | Same — io_uring, no JWT |
| `src/server/auth_middleware.zig` (JWT module) | Library only | Only imported by test files |
| `src/integration_test.zig` | ✅ Tests only | Imports `auth_middleware` for testing |
| `src/e2e_server_test.zig` | ✅ Tests only | Imports `auth_middleware` for testing |

### The Actual Request Flow

```
Request arrives
  │
  ▼
Parse HTTP headers (method, path, headers, body)
  │
  ▼
Parse X-SSL-* headers from nginx (mTLS identity)
  │  ├─ X-SSL-Client-Verify: SUCCESS
  │  ├─ X-SSL-Client-Cert: <PEM>
  │  └─ X-SSL-Client-Fingerprint: <SHA1>
  │
  ▼
Derive agent_id from certificate fingerprint
  │  (XxHash64 × 4 of the PEM certificate)
  │
  ▼
Route: /health, /metrics, /v1/agents, /check, /denied-requests
  │
  ▼
/check: Evaluate policy(agent_id, path, method) → allow/deny
  │
  ▼
No Authorization header parsing    ← JWT is NOT in this path
No Bearer token extraction         ← JWT is NOT in this path
No JWT signature verification      ← JWT is NOT in this path
```

### The Secret Key Field

The `Server` struct has a `secret_key: []const u8` field (set from `cfg.auth.jwt_secret` at `http.zig` line 321), but it is **stored and never read** during request processing. It's configuration that exists only because the struct defines it.

### Why Does the JWT Library Exist?

| Reason | Explanation |
|--------|-------------|
| **Historical evolution** | JWT was implemented first (Day 3 plan), then mTLS replaced it as the primary auth (Day 9 plan) |
| **Test infrastructure** | Tests need JWTs to simulate agents with identities |
| **Future fallback** | The library is ready if someone wants to deploy AgentGate without nginx |
| **Developer experience** | Local dev without nginx can use JWT for quick testing |

---

## 2. What Exists Today

### 2.1 JWT Library (`src/auth/jwt.zig`)

A complete HS256/HMAC JWT implementation:

```zig
// Header
pub const Header = struct {
    alg: []const u8,     // "HS256", "HS384", "HS512"
    typ: []const u8,     // "JWT"
};

// Payload
pub const Payload = struct {
    sub: []const u8,     // agent subject (identifier)
    exp: u64,           // expiration timestamp
    aud: ?[]const u8,   // audience (optional)
    iat: ?u64,          // issued at (optional)
    nbf: ?u64,          // not before (optional)
};

// JWT token representation
pub const JWT = struct {
    header: Header,
    payload: Payload,
    signature: []const u8,
    encoded_header: []const u8,
    encoded_payload: []const u8,

    pub fn parse(token: []const u8, arena: *SecurityArena) !JWT { ... }
    pub fn verify(jwt: *const JWT, secret: *Secret, options: VerifyOptions) !bool { ... }
};
```

**Supported features:**
- HS256, HS384, HS512 signature verification
- Base64url decoding (no padding)
- Constant-time HMAC comparison (timing attack resistant)
- Token expiry validation
- `iat` (issued at) and `nbf` (not before) validation
- Leeway tolerance for clock skew

### 2.2 Auth Middleware (`src/server/auth_middleware.zig`)

A wrapper that ties JWT parsing to Agent identity:

```zig
pub const AuthMiddleware = struct {
    secret: Secret,           // Zeroizing container
    arena: SecurityArena,     // Per-request allocator

    pub fn authenticate(self: *Self, authorization: ?[]const u8) AuthError!Agent {
        // 1. Extract Bearer token from Authorization header
        // 2. Parse JWT using arena allocator
        // 3. Verify signature against secret
        // 4. Validate claims (exp, iat, nbf)
        // 5. Return Agent with id = SHA256(token)
    }
};
```

**Agent identity derivation:**
```zig
// auth_middleware.zig line 110-111
var id_buf: [32]u8 = undefined;
std.crypto.hash.sha2.Sha256.hash(token, &id_buf, .{});
```

The agent's 32-byte identity is the **SHA256 of the raw JWT token string**. This means:
- The same token always produces the same `agent_id`
- A new token (even with the same `sub`) produces a different `agent_id`
- The `sub` claim is available in the JWT payload but is not used for identity

### 2.3 JWT Helper Script (`scripts/jwt_helper.sh`)

A bash script for minting test JWTs:

```bash
# Usage
./scripts/jwt_helper.sh <agent-subject> <secret-key>

# Example — generate a JWT for agent-1
JWT=$(./scripts/jwt_helper.sh "agent-1" "your-secret-min-32-chars!!")
echo "$JWT"
# eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZ2VudC0xIiwiZXhwIjox...

# Verify with curl
curl -X POST http://localhost:8080/check \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/test","method":"GET"}'
```

Generates:
- HS256-signed JWT
- `sub`: the agent identifier
- `exp`: current time + 1 hour
- `iat`: current time

### 2.4 Config Validation

```zig
// config.zig line 474-475
if (self.auth.jwt_secret.len < self.auth.min_secret_length) {
    return error.SecretTooShort;
}
// MIN_SECRET_LENGTH = 32
```

The JWT secret must be **at least 32 characters**. This validation runs at startup regardless of whether JWT will be used, which is why the baked Docker config has a 38-character placeholder.

---

## 3. How JWT Auth Would Work (If Wired)

### 3.1 Request Flow (Hypothetical)

```
Agent                                          AgentGate
  │                                              │
  │  1. Obtain JWT from Identity Provider        │
  │     (signed with shared secret)              │
  │                                              │
  │  2. POST /check                              │
  │     Authorization: Bearer <JWT>              │
  │     Content-Type: application/json           │
  │     {"path":"/api/data","method":"GET"}      │
  │─────────────────────────────────────────────►│
  │                                              │
  │                 3. Extract Bearer token      │
  │                 4. Parse JWT                 │
  │                 5. Verify signature (HMAC)   │
  │                 6. Check expiry (exp)        │
  │                 7. Derive agent_id = SHA256  │
  │                 8. Evaluate policy           │
  │                                              │
  │  9. Response                                 │
  │◄─────────────────────────────────────────────│
  │     {"allowed":true}                         │
  │     or                                       │
  │     {"allowed":false,"reason":"policy ..."}  │
```

### 3.2 Identity Derivation

```
JWT Token:      eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZ2VudC0xIn0.signature
                       │                                    │
                       ▼                                    │
               SHA256(token)                                │
                       │                                    │
                       ▼                                    │
               [32-byte agent_id] ◄─────────────────────────┘
                                     (same for mTLS—always
                                      32-byte deterministic ID)
```

The agent identity (`[32]u8`) is always the same size regardless of auth method. The policy engine and audit logger don't care whether the identity came from mTLS or JWT.

### 3.3 Wiring That Would Be Needed

To activate JWT auth in `http.zig`, the `/check` route handler would need to:

```zig
// Current code (no JWT):
fn handleRequestThread(self: *Self, client_fd: c_int) void {
    // ... parse SSL headers, derive agent_id from cert ...
    // ... route to /check with agent_id from mTLS ...
}

// With JWT support added:
fn handleRequestThread(self: *Self, client_fd: c_int) void {
    // 1. Try mTLS first (parse X-SSL headers)
    var agent_id: [32]u8 = deriveFromSSLCertificates(...);

    // 2. If no mTLS identity, try JWT Bearer token
    if (isAgentIdZero(agent_id)) {
        const auth_header = parsed.headers.get("Authorization");
        agent_id = try authenticateJWT(auth_header, self.secret_key);
    }

    // 3. If still no identity, reject
    if (isAgentIdZero(agent_id)) {
        return sendErrorResponse(client_fd, .unauthorized, "authentication required");
    }

    // 4. Route to /check with agent_id (same as today)
    handleCheckRequest(client_fd, parsed.body, agent_id);
}
```

---

## 4. Shared Secret: The Trust Anchor

### 4.1 How It Works

```
                  ┌─────────────────────┐
                  │  Identity Provider  │
                  │  knows:             │
                  │  shared_secret      │
                  └──────────┬──────────┘
                             │ signs JWTs
                             │ with shared_secret
                             ▼
                  ┌─────────────────────┐
                  │  Agent              │
                  │  has: JWT           │
                  └──────────┬──────────┘
                             │ presents JWT
                             ▼
┌───────────────────────────────────────────────┐
│  AgentGate Cluster                            │
│                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ Instance │  │ Instance │  │ Instance │    │
│  │ 1        │  │ 2        │  │ 3        │    │
│  │ secret=X │  │ secret=X │  │ secret=X │    │
│  └──────────┘  └──────────┘  └──────────┘    │
│       │             │             │           │
│  All verify the same JWT signature             │
└───────────────────────────────────────────────┘
```

All AgentGate instances **must share the same JWT secret**. This is the single trust anchor. Any agent with a validly-signed JWT can authenticate to any AgentGate instance.

### 4.2 Secret Distribution

| Method | Tools | Production Ready |
|--------|-------|-----------------|
| **Kubernetes Secret** | `kubectl create secret generic agentgate-jwt --from-literal=jwt-secret=$(openssl rand -base64 24)` | ✅ Yes |
| **Environment variable** | `AGENTGATE_AUTH_JWT_SECRET=...` | ✅ Yes |
| **Config file** | `config.json` → `auth.jwt_secret` | ✅ Yes |
| **Vault** | Inject via Vault agent sidecar | ✅ Yes |
| **Docker secrets** | Mount `/run/secrets/` | ✅ Yes |
| **Hardcoded (dev only)** | Baked placeholder in Dockerfile | ❌ Not for prod |

### 4.3 Secret Rotation

There is currently **no zero-downtime rotation mechanism**. To rotate the secret:

1. Generate a new secret
2. Update all AgentGate instances with the new secret
3. Re-issue JWTs to all agents with the new secret
4. Old JWTs signed with the old secret will be rejected

A future enhancement could support **dual-key rotation** (two active secrets, validate against either) for seamless migration.

---

## 5. JWT vs mTLS: Comparison

| Property | JWT Bearer Token | mTLS Certificate |
|----------|-----------------|-------------------|
| **Identity proof** | Shared secret signature | Public key cryptography |
| **Secret distribution** | Must share across all AgentGate instances | Only CA cert needs to be shared |
| **Agent credential** | Token string (can be stolen) | Private key (never leaves agent) |
| **Token lifecycle** | Explicit expiry (`exp` claim) | Certificate validity period |
| **Revocation** | Short TTL + blacklist | CRL / OCSP |
| **Rotation** | Re-issue all tokens | Re-issue per-agent certs |
| **Infrastructure** | Needs Identity Provider / token service | Needs CA + PKI |
| **Performance** | Fast (HMAC, symmetric crypto) | Slower (asymmetric crypto at TLS layer) |
| **Complexity** | Low (one secret, one algorithm) | Higher (CA, cert management, nginx) |
| **Network requirements** | Direct HTTP access to AgentGate | Requires TLS-terminating proxy |
| **Currently wired?** | ❌ No | ✅ Yes |
| **Swarm readiness** | All instances share secret | Each agent has unique cert |

### When to Choose JWT

- **No TLS infrastructure** — AgentGate is accessed directly over plain HTTP
- **Existing JWT ecosystem** — Your agents already use JWTs for other services
- **Simple deployments** — Single AgentGate instance, small agent count
- **Quick prototyping** — No need to manage certificates or nginx

### When to Choose mTLS

- **Agent swarm** — Each agent has a unique cryptographic identity
- **Production** — Stronger security (private key never leaves agent)
- **Regulated environments** — Certificate-based audit trails
- **Multi-instance** — No shared secrets to distribute
- **Current architecture** — Already implemented and tested

---

## 6. Use Cases for JWT

### 6.1 Direct Access (No nginx)

```
Agent ──HTTP + Bearer JWT──→ AgentGate
```

No TLS termination layer. AgentGate receives HTTP directly and validates the JWT in the Authorization header.

**Requirements:**
- All agents must possess valid JWTs
- An external Identity Provider must issue the JWTs
- AgentGate must have the shared secret configured

### 6.2 JWT as Fallback (When mTLS Unavailable)

```
Agent ──HTTP──→ AgentGate
                 │
                 ├─ X-SSL headers present? → mTLS identity
                 └─ No SSL headers? → try JWT Bearer
```

Agents that support mTLS authenticate via certificate. Agents that don't (legacy systems, third-party tools) use JWT.

**Current status:** This hybrid mode is **not implemented**. The current code has an `is_public_endpoint` check that bypasses SSL header requirements for `/health` etc., but there's no JWT fallback for the `/check` endpoint when mTLS headers are absent.

### 6.3 Service-to-Service (Machine Identity)

```
Service A                  Service B
  │                          │
  │  1. Get JWT from         │
  │     AgentGate's IdP      │
  │                          │
  │  2. Call Service B       │
  │     Authorization: JWT   │
  │──────────────────────────►│
  │                          │
  │        3. AgentGate (B)  │
  │           validates JWT  │
  │           evaluates      │
  │           policy         │
  │                          │
```

Services authenticate to each other using JWTs. Each service's AgentGate validates the JWT before forwarding to the upstream.

### 6.4 Development Without nginx

```bash
# Start AgentGate directly (no nginx)
export AGENTGATE_AUTH_JWT_SECRET="dev-secret-32-chars-minimum!!!!"
zig build run

# Generate a JWT
JWT=$(./scripts/jwt_helper.sh "agent-dev" "$AGENTGATE_AUTH_JWT_SECRET")

# Test
curl -X POST http://localhost:8080/check \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/test","method":"GET"}'
```

This is the primary practical use case for JWT today — local development without requiring nginx or certificates.

---

## 7. What Would Need to Change to Wire JWT

### 7.1 Code Changes

```
Files to modify:
  └── src/server/http.zig (or http_async.zig)
       ├── Add import: const AuthMiddleware = @import("auth_middleware.zig");
       ├── Add field: auth_middleware: AuthMiddleware,
       ├── Add init: .auth_middleware = try AuthMiddleware.init(allocator, cfg.auth.jwt_secret),
       ├── Add deinit: self.auth_middleware.deinit();
       └── Modify handleRequestThread():
            ├── After mTLS identity derivation
            ├── If agent_id is zero AND request is not public endpoint:
            │   ├── Extract Authorization header from parsed.headers
            │   ├── Call auth_middleware.authenticate(authorization)
            │   └── If failure → send 401 Unauthorized
            └── Pass agent_id to /check (unchanged)
```

Total estimated effort: **~30 lines of new code** in `http.zig`.

### 7.2 Configuration Changes

The existing config already supports JWT:

```json
{
  "auth": {
    "jwt_secret": "your-secret-32-chars-minimum!!!"
  },
  "tls": {
    "mode": "external",         // or "none" if no nginx
    "external_policy": "jwt"    // new option: allow JWT fallback
  }
}
```

A new `external_policy` value like `"jwt"` could enable the JWT fallback path without breaking existing mTLS configurations. The current values are `"strict"` (reject without SSL headers) and `"permissive"` (accept without headers for testing).

### 7.3 Security Considerations When Wiring JWT

| Concern | Mitigation |
|---------|------------|
| JWT theft | Use short expiry times (minutes, not hours). Require TLS transport. |
| Clock skew | Allow configurable leeway (default 30s). AgentGate validates `exp` and `nbf`. |
| Weak JWT secret | Enforce `>= 32` characters. Use `openssl rand -base64 24`. |
| No revocation | JWTs are valid until expiry. For immediate revocation, change the shared secret (invalidate ALL tokens). |
| Mixed auth confusion | If both mTLS and JWT are accepted, ensure the request has only one identity source. |

---

## 8. Multi-Instance Considerations

### 8.1 Shared Secret, Shared Trust

When using JWT with multiple AgentGate instances:

```
                 ┌──────────────────────┐
                 │  Shared Secret (S)   │
                 └──────┬───────────────┘
                        │ distributed to all instances
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ AgentGate 1  │ │ AgentGate 2  │ │ AgentGate 3  │
│ secret = S   │ │ secret = S   │ │ secret = S   │
└──────────────┘ └──────────────┘ └──────────────┘
        │               │               │
 All verify same JWT ←──┼───────────────┘
                        │
                        ▼
               ┌────────────────┐
               │  Load Balancer │
               └────────────────┘
```

Every instance can validate any JWT because they all know the same secret. No session affinity needed.

### 8.2 What Must Be Consistent Across Instances

| Setting | Must Match? | Reason |
|---------|-------------|--------|
| `auth.jwt_secret` | **Yes** | All instances must validate the same tokens |
| Clock | **Yes** | JWT expiry validation uses system clock; sync via NTP |
| `policy.evaluate_timeout_ms` | No | Each instance can have different timeout (affects decision quality, not correctness) |

### 8.3 What Is NOT Affected by JWT

- **Policy files** — independent per instance
- **Denial records** — per-instance ring buffer
- **Audit logs** — per-instance Merkle chain
- **Metrics** — per-instance Prometheus counters
- **Performance** — JWT verification is CPU-local; no shared state

---

## 9. Generating and Managing JWTs

### 9.1 Using openssl (No Script Needed)

```bash
# Generate a secure random secret
SECRET=$(openssl rand -base64 24)
echo "Secret: $SECRET"

# JWT Header: {"alg":"HS256","typ":"JWT"}
HEADER=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64 -w 0 | tr '+/' '-_' | tr -d '=')

# JWT Payload: {"sub":"agent-1","exp":$(($(date +%s)+3600)),"iat":$(date +%s)}
PAYLOAD=$(echo -n "{\"sub\":\"agent-1\",\"exp\":$(($(date +%s)+3600)),\"iat\":$(date +%s)}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')

# Sign
SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64 -w 0 | tr '+/' '-_' | tr -d '=')

# Full JWT
JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"
echo "$JWT"
```

### 9.2 Using the Helper Script

```bash
# Generate
JWT=$(./scripts/jwt_helper.sh "agent-1" "your-secret-32-chars-minimum!!")

# Decode and inspect (header + payload are base64url)
echo "$JWT" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
# {"sub":"agent-1","exp":1748112345,"iat":1748108745}
```

### 9.3 JWT Claims

| Claim | Required | Description |
|-------|----------|-------------|
| `sub` | Yes | Agent subject identifier (e.g., `"agent-001"`) |
| `exp` | Yes | Expiration timestamp (Unix epoch seconds) |
| `iat` | No | Issued at timestamp |
| `nbf` | No | Not before timestamp |
| `aud` | No | Audience (e.g., `"agentgate"`) |

### 9.4 Integrating with an Identity Provider

AgentGate does not issue tokens. To use JWT auth, integrate with an external IdP:

```bash
# Using a hypothetical token service
TOKEN=$(curl -s -X POST https://idp.example.com/token \
  -H "Authorization: Basic $(echo -n 'agent-1:client-secret' | base64)" \
  -d 'grant_type=client_credentials' \
  -d 'audience=agentgate' | jq -r '.access_token')

# Use the token with AgentGate
curl -X POST http://localhost:8080/check \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/data","method":"GET"}'
```

The IdP must sign the JWT with the same secret that AgentGate instances are configured with.

---

## References

- `src/auth/jwt.zig` — JWT parsing and HMAC verification (1130 lines)
- `src/server/auth_middleware.zig` — Auth middleware wrapping JWT → Agent (227 lines)
- `scripts/jwt_helper.sh` — Bash script for minting test JWTs
- `docs/plans/2026-04-22-002-feat-day3-jwt-authentication-plan.md` — Original JWT implementation plan
- `src/config.zig` — JWT secret config and validation (`MIN_SECRET_LENGTH = 32`)
- `future/mtls-nginx-agentgate.md` — The active (mTLS) authentication architecture
