# mTLS + nginx + AgentGate: Multi-Instance Architecture

> **Status**: Fully implemented and production-ready.
> **Date**: 2026-05-25
> **Core files**: `src/server/http.zig`, `src/auth/mTLS.zig`, `docs/mtls-nginx.conf`
> **Config mode**: `tls.mode = "external"`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Identity Derivation](#3-identity-derivation)
4. [AgentGate Configuration](#4-agentgate-configuration)
5. [nginx Configuration](#5-nginx-configuration)
6. [Multi-Instance Deployment Patterns](#6-multi-instance-deployment-patterns)
7. [Shared Nothing Architecture](#7-shared-nothing-architecture)
8. [Security Model](#8-security-model)
9. [Deployment with Docker](#9-deployment-with-docker)
10. [Kubernetes Deployment](#10-kubernetes-deployment)
11. [FAQ](#11-faq)

---

## 1. Overview

AgentGate uses **external TLS termination** — it does not terminate TLS itself. A reverse proxy (nginx) handles all TLS/mTLS handshakes, and AgentGate reads client identity from HTTP headers forwarded by nginx.

This architecture provides:

- **Clean separation of concerns** — nginx handles crypto, AgentGate handles policy
- **Better performance** — nginx's battle-tested TLS implementation (OpenSSL/BoringSSL)
- **Production-grade security** — nginx supports TLS 1.3, modern cipher suites, OCSP stapling
- **Horizontal scalability** — AgentGate instances are stateless and can scale independently
- **Swarm-ready** — all agents authenticate via client certificates, no shared JWT secrets needed

### Why This Architecture for a Swarm?

In an agent swarm, each agent has a **unique client certificate** signed by a trusted CA. The certificate IS the agent's identity. When an agent connects through nginx:

1. nginx verifies the certificate chain against the CA
2. nginx forwards the certificate details to AgentGate via HTTP headers
3. AgentGate derives a deterministic `agent_id` from the certificate
4. The `agent_id` is used for policy evaluation and audit logging

No shared secrets, no token issuance, no expiry management. The certificate is the credential.

---

## 2. Architecture

### 2.1 Single Instance

```
┌──────────┐         mTLS          ┌───────────────┐    HTTP + headers    ┌──────────────┐
│  Agent   │  ═══════════════════►  │    nginx      │  ═════════════════►  │  AgentGate   │
│  (TLS    │    TLS handshake,     │   (port       │    X-SSL-* headers   │  (port      │
│  client  │    client cert        │    8443)      │    forwarded         │    8080)     │
│  cert)   │    verification       │               │                     │              │
└──────────┘                       └───────────────┘                     └──────────────┘
                                                                            │
                                                     ┌──────────────────────┘
                                                     ▼
                                            ┌──────────────────┐
                                            │  parseSSLHeaders │
                                            │  deriveAgentId() │
                                            │  Route /check    │
                                            │  Policy eval     │
                                            └──────────────────┘
```

### 2.2 Multi-Instance (Swarm)

```
                         ┌─────────────┐
                         │  nginx LB   │
                         │  (port 443) │
                         └──────┬──────┘
                                │
               ┌────────────────┼────────────────┐
               ▼                ▼                ▼
        ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
        │   nginx      │ │   nginx      │ │   nginx      │
        │  mTLS term   │ │  mTLS term   │ │  mTLS term   │
        └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
               ▼                ▼                ▼
        ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
        │  AgentGate   │ │  AgentGate   │ │  AgentGate   │
        │  instance 1  │ │  instance 2  │ │  instance N  │
        └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
               │                │                │
               └────────────────┼────────────────┘
                                ▼
                       ┌────────────────┐
                       │  Backend       │
                       │  Service(s)    │
                       └────────────────┘
```

Each AgentGate instance is **independent and stateless**. No shared state, no inter-instance communication, no leader election.

### 2.3 Connection Flow (Step by Step)

```
Step 1: Agent connects to nginx:8443
        → TLS handshake begins
        → nginx requests client certificate
        → Agent presents client cert signed by trusted CA

Step 2: nginx verifies certificate
        → Validates signature chain against CA cert
        → Checks expiry, revocation status
        → Extracts PEM, SHA1 fingerprint, serial

Step 3: nginx forwards to AgentGate:8080
        → Sets X-SSL-Client-Verify: SUCCESS
        → Sets X-SSL-Client-Cert: <full PEM>
        → Sets X-SSL-Client-Fingerprint: <SHA1>
        → Sets X-SSL-Client-Serial: <serial>

Step 4: AgentGate processes request
        → Parses X-SSL-* headers
        → Derives agent_id from certificate (XxHash64 × 4)
        → Routes to /check endpoint
        → Evaluates policy against (agent_id, path, method)
        → Returns allow/deny decision

Step 5: nginx forwards decision to agent
        → On allow: proxy request to upstream service
        → On deny: return 403 to agent
```

---

## 3. Identity Derivation

### 3.1 Algorithm

AgentGate derives a deterministic 32-byte `agent_id` from the client certificate using **XxHash64**:

```zig
// src/auth/mTLS.zig
agent_id = XxHash64(cert_der, seed=0)  // bytes  0..7
        || XxHash64(cert_der, seed=1)  // bytes  8..15
        || XxHash64(cert_der, seed=2)  // bytes 16..23
        || XxHash64(cert_der, seed=3)  // bytes 24..31
```

XxHash64 is chosen over SHA256 because:
- **Speed**: ~10× faster than SHA256 for cert-sized inputs
- **Deterministic**: same cert → same id across restarts and instances
- **Collision resistance**: 256-bit output is sufficient for agent identification
- **nvidia already validated the certificate** — cryptographic identity verification is done by nginx at the TLS layer, so AgentGate only needs a consistent fingerprint

### 3.2 Priority Order

When parsing SSL headers, AgentGate tries these sources in order:

| Priority | Source | Header | Notes |
|----------|--------|--------|-------|
| 1 (best) | PEM certificate | `X-SSL-Client-Cert` | Full PEM → compute XxHash64. Most robust. |
| 2 | SHA256 fingerprint | `X-SSL-Client-Fingerprint` | 64 hex chars → use as-is. Only if nginx configured for SHA256. |
| 3 (fallback) | SHA1 fingerprint | `X-SSL-Client-Fingerprint` | 40 hex chars → expand to 32 bytes. Standard nginx. |

### 3.3 Properties

- **Same cert, same id**: Deterministic across all AgentGate instances
- **New cert, new id**: Certificate rotation creates a new agent identity
- **No central identity registry**: Identity is purely cryptographic
- **32-byte output**: Matches `Agent.id: [32]u8` struct

---

## 4. AgentGate Configuration

### 4.1 config.json (Baked in Docker Image)

```json
{
  "server": {
    "port": 8080,
    "host": "0.0.0.0",
    "workers": 4
  },
  "tls": {
    "mode": "external",
    "trusted_proxy_ip": "127.0.0.1",
    "require_ssl_headers": true,
    "external_policy": "strict"
  }
}
```

### 4.2 TLS Settings Explained

| Setting | Value | What It Does |
|---------|-------|-------------|
| `mode` | `"external"` | Enables X-SSL-* header parsing. No TLS termination in AgentGate. |
| `trusted_proxy_ip` | `"127.0.0.1"` | Only trust SSL headers from this IP. In Docker, set to nginx container IP or adjust. |
| `require_ssl_headers` | `true` | **Critical for security.** Reject any request that lacks valid SSL headers. |
| `external_policy` | `"strict"` | No JWT fallback. Only mTLS identity is accepted. |

### 4.3 Environment Variable Overrides

```bash
# Listen on all interfaces (required in Docker)
export AGENTGATE_SERVER_HOST=0.0.0.0

# Set the trusted proxy IP (nginx container IP)
export AGENTGATE_TLS_TRUSTED_PROXY_IP=172.17.0.2

# Change TLS mode (if needed)
export AGENTGATE_TLS_MODE=external
```

### 4.4 The JWT Secret (Not Used in mTLS Mode)

```json
{
  "auth": {
    "jwt_secret": "change-me-in-production-0123456789"
  }
}
```

This field exists on the `Config` struct and is read during server initialization (`http.zig` line 321), but **it is never used in the request handling path**. In mTLS mode it is dead configuration — present only because the struct requires it and validation enforces `>= 32 characters`.

The `AuthMiddleware` module (`src/server/auth_middleware.zig`) exists in the codebase but is **never imported or called** by `http.zig`, `http_async.zig`, or `http_uring.zig`. It is only used by test files.

---

## 5. nginx Configuration

### 5.1 Production mTLS Configuration

```nginx
server {
    listen 8443 ssl;
    server_name agentgate.internal;

    # Server certificate
    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    # CA certificate for verifying client certs
    ssl_client_certificate /etc/nginx/certs/ca.crt;
    ssl_verify_client on;
    ssl_verify_depth 2;

    # Modern TLS configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # Forward client certificate details to AgentGate
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # SSL/mTLS headers
        proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
        proxy_set_header X-SSL-Client-Cert    $ssl_client_cert;
        proxy_set_header X-SSL-Client-Fingerprint $ssl_client_fingerprint;
        proxy_set_header X-SSL-Client-Serial  $ssl_client_serial;
    }
}
```

### 5.2 Required Headers

| Header | nginx Variable | Required | Description |
|--------|---------------|----------|-------------|
| `X-SSL-Client-Verify` | `$ssl_client_verify` | **Yes** | `SUCCESS` or `FAILED` |
| `X-SSL-Client-Cert` | `$ssl_client_cert` | **Yes** | Full PEM (primary id source) |
| `X-SSL-Client-Fingerprint` | `$ssl_client_fingerprint` | No | SHA1 (40 hex chars, fallback) |
| `X-SSL-Client-Serial` | `$ssl_client_serial` | No | Certificate serial number |

> **Note**: nginx `$ssl_client_fingerprint` is SHA1, not SHA256. AgentGate uses the PEM certificate as the primary identity source and SHA1 only as a fallback.

---

## 6. Multi-Instance Deployment Patterns

### 6.1 Pattern A: Per-Service Sidecars

Each backend service gets its own AgentGate + nginx pair, with **service-specific policies**.

```
                    ┌─────────────────────────┐
                    │     Agent (caller)       │
                    │     client cert: X       │
                    └───────────┬─────────────┘
                                │
           ┌────────────────────┼────────────────────┐
           ▼                    ▼                     ▼
   ┌───────────────┐    ┌───────────────┐    ┌───────────────┐
   │  nginx svc-A  │    │  nginx svc-B  │    │  nginx svc-C  │
   │  mTLS term    │    │  mTLS term    │    │  mTLS term    │
   └───────┬───────┘    └───────┬───────┘    └───────┬───────┘
           ▼                    ▼                     ▼
   ┌───────────────┐    ┌───────────────┐    ┌───────────────┐
   │  AgentGate A  │    │  AgentGate B  │    │  AgentGate C  │
   │  policy: svcA │    │  policy: svcB │    │  policy: svcC │
   └───────┬───────┘    └───────┬───────┘    └───────┬───────┘
           ▼                    ▼                     ▼
   ┌───────────────┐    ┌───────────────┐    ┌───────────────┐
   │  Service A    │    │  Service B    │    │  Service C    │
   └───────────────┘    └───────────────┘    └───────────────┘
```

**When to use**: Microservice architecture where each service has different access policies. Service A might allow read access to all agents, while Service B restricts to admin agents.

**Configuration**: Each AgentGate instance has a different `policy_file` in its config.

### 6.2 Pattern B: Horizontal Scaling (Same Service)

Multiple AgentGate instances behind a load balancer, all serving the same backend.

```
                    ┌─────────────┐
                    │   AWS NLB   │
                    │  / HAProxy  │
                    │  port 443   │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
   ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
   │  nginx        │ │  nginx        │ │  nginx        │
   │  mTLS term    │ │  mTLS term    │ │  mTLS term    │
   └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
           ▼                 ▼                 ▼
   ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
   │  AgentGate 1  │ │  AgentGate 2  │ │  AgentGate 3  │
   │  same policy  │ │  same policy  │ │  same policy  │
   └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
           │                 │                 │
           └─────────────────┼─────────────────┘
                             ▼
                   ┌─────────────────┐
                   │  Backend Service │
                   └─────────────────┘
```

**When to use**: High-throughput scenario where a single AgentGate instance can't handle the load, or for HA (N+1 redundancy).

**Characteristics**:
- All instances use the **same policy file** (same decision logic)
- All instances are **stateless** — no session affinity needed
- Scale up/down based on CPU/memory metrics
- Each instance has its own in-memory denial tracker (no shared audit)

### 6.3 Pattern C: Multi-Region / Edge Deployment

```
   US-East                 EU-West                AP-Southeast
   ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
   │  nginx       │       │  nginx       │       │  nginx       │
   │  mTLS term   │       │  mTLS term   │       │  mTLS term   │
   └──────┬───────┘       └──────┬───────┘       └──────┬───────┘
          ▼                      ▼                      ▼
   ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
   │  AgentGate   │       │  AgentGate   │       │  AgentGate   │
   │  region-us   │       │  region-eu   │       │  region-ap   │
   └──────┬───────┘       └──────┬───────┘       └──────┬───────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 ▼
                       ┌──────────────────┐
                       │  Global Backend  │
                       │  (multi-region)  │
                       └──────────────────┘
```

**When to use**: Global service with agents in multiple geographic regions. Each region has local policy evaluation for low latency.

**Important**: The **CA certificate must be the same across all regions** so that the same agent certificate produces the same `agent_id` everywhere.

---

## 7. Shared Nothing Architecture

AgentGate instances are designed around a **shared nothing** architecture. This is what makes multi-instance deployment simple.

### 7.1 What Is Shared

| Resource | Shared? | How |
|----------|---------|-----|
| **CA certificate** | ✅ Yes | Must be same across all instances so same cert → same `agent_id` |
| **Policy file** | Per-service group | All instances fronting the same service use the same policy file |
| **nginx config** | Per-instance group | Each nginx has its own config (identical or load-balanced) |

### 7.2 What Is NOT Shared

| Resource | Not Shared | Why It's Fine |
|----------|------------|---------------|
| **Denial records** | Per-instance in-memory ring buffer | Denial tracking is for local debugging. Aggregate via logs if needed. |
| **Audit logs** | Per-instance in-memory Merkle chain | Each instance has its own tamper-evident audit chain. Centralize via log shipping. |
| **JWT secret** | Not used in mTLS mode | The field exists but is dead code. No JWT secrets needed. |
| **Agent sessions** | Not applicable | AgentGate is stateless — each request is independently evaluated. |
| **Metrics counters** | Per-instance | Prometheus scrapes each instance separately; aggregate at the Prometheus level. |

### 7.3 Implications

- **No Redis / memcached / DB needed** — zero infrastructure dependencies
- **No leader election** — a black-box scale-out model
- **No session affinity** — any AgentGate can handle any request
- **No cache invalidation** — policies are loaded from file at startup (SIGHUP for reload)
- **Linear scaling** — double the instances, double the throughput

---

## 8. Security Model

### 8.1 Defense in Depth

```
Layer 1: Network ACL
    → Only allow port 8443 from agent IP ranges
    → Block direct access to AgentGate port 8080

Layer 2: TLS Termination (nginx)
    → TLS 1.2/1.3 only
    → Strong cipher suites
    → mTLS with client certificate verification

Layer 3: Header Forwarding (nginx)
    → Only nginx can set X-SSL-* headers
    → Requires network isolation (trusted_proxy_ip)

Layer 4: Identity Derivation (AgentGate)
    → Deterministic agent_id from certificate
    → No JWT fallback (external_policy: strict)

Layer 5: Policy Enforcement (AgentGate)
    → Path and method-based allow/deny rules
    → Per-agent policy evaluation
    → Timeout-protected (50ms default)
```

### 8.2 Public Endpoints (No Certificate Required)

These endpoints bypass `require_ssl_headers` checks:

| Endpoint | Purpose |
|----------|---------|
| `/health` | Container health checks (Docker, K8s) |
| `/metrics` | Prometheus metrics scraping |
| `/denied-requests` | Denial record audit (debugging) |
| `/v1/agents` | Agent list (debugging) |

### 8.3 Known Security Considerations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Header injection** | Direct access to AgentGate with fake X-SSL-* headers is accepted in some configurations | `require_ssl_headers: true` rejects requests without headers. Network ACLs should block direct access to port 8080. |
| **SHA1 fingerprint** | nginx `$ssl_client_fingerprint` is SHA1 (not SHA256) | AgentGate uses PEM certificate as primary source. SHA1 is only fallback. |
| **agent_id collision** | XxHash64 is not collision-resistant | nvidia already validated the certificate chain. AgentGate only needs a fingerprint, not cryptographic identity. |

### 8.4 Strict Mode Behavior

With `require_ssl_headers: true` and `external_policy: "strict"`:

```
Request with valid X-SSL headers  → 200 OK / 403 Forbidden (policy decision)
Request without X-SSL headers     → 403 "SSL headers required in external TLS mode"
Request with invalid X-SSL cert   → 403 (identity is zeroed)
```

---

## 9. Deployment with Docker

### 9.1 Docker Compose (Single Instance)

```yaml
version: "3.8"
services:
  nginx:
    image: nginx:alpine
    ports:
      - "8443:8443"
    volumes:
      - ./nginx-mtls.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - agentgate

  agentgate:
    image: agent-gate:latest
    expose:
      - "8080"
    environment:
      - AGENTGATE_SERVER_HOST=0.0.0.0
      - AGENTGATE_TLS_TRUSTED_PROXY_IP=nginx
    volumes:
      - ./policies:/etc/agent-gate/policies:ro
```

### 9.2 Docker Compose (Multiple Instances)

```yaml
version: "3.8"
services:
  nginx:
    image: nginx:alpine
    ports:
      - "8443:8443"
    volumes:
      - ./nginx-mtls.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro

  agentgate-1:
    image: agent-gate:latest
    expose:
      - "8080"
    environment:
      - AGENTGATE_SERVER_HOST=0.0.0.0
      - AGENTGATE_TLS_TRUSTED_PROXY_IP=nginx
    volumes:
      - ./policies:/etc/agent-gate/policies:ro

  agentgate-2:
    image: agent-gate:latest
    expose:
      - "8080"
    environment:
      - AGENTGATE_SERVER_HOST=0.0.0.0
      - AGENTGATE_TLS_TRUSTED_PROXY_IP=nginx
    volumes:
      - ./policies:/etc/agent-gate/policies:ro

  # nginx upstream block load-balances across agentgate-1 and agentgate-2
```

nginx upstream config:
```nginx
upstream agentgate_backend {
    server agentgate-1:8080;
    server agentgate-2:8080;
}
```

---

## 10. Kubernetes Deployment

### 10.1 Architecture in K8s

In Kubernetes, the common pattern is a **sidecar container** per pod, or a separate deployment.

Option A — Sidecar per pod:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          # mTLS termination, forwards to AgentGate on localhost:8080
        - name: agentgate
          image: agent-gate:latest
          env:
            - name: AGENTGATE_SERVER_HOST
              value: "0.0.0.0"
            - name: AGENTGATE_TLS_TRUSTED_PROXY_IP
              value: "127.0.0.1"
        - name: my-app
          image: my-app:latest
```

Option B — Separate Deployment (for shared sidecars):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentgate
spec:
  replicas: 3
  selector:
    matchLabels:
      app: agentgate
  template:
    metadata:
      labels:
        app: agentgate
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/conf.d
            - name: certs
              mountPath: /etc/nginx/certs
              readOnly: true
        - name: agentgate
          image: agent-gate:latest
          ports:
            - containerPort: 8080
          env:
            - name: AGENTGATE_SERVER_HOST
              value: "0.0.0.0"
            - name: AGENTGATE_TLS_TRUSTED_PROXY_IP
              value: "127.0.0.1"
          volumeMounts:
            - name: policies
              mountPath: /etc/agent-gate/policies
              readOnly: true
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 10Mi
            limits:
              cpu: 100m
              memory: 50Mi
      volumes:
        - name: nginx-config
          configMap:
            name: agentgate-nginx-config
        - name: certs
          secret:
            secretName: agentgate-certs
        - name: policies
          configMap:
            name: agentgate-policies
```

### 10.2 Resource Scaling

| Metric | Single Instance | 3-Replica Deployment |
|--------|----------------|----------------------|
| Binary size | ~3MB (musl static) | — |
| Container image | ~13MB (Alpine) | — |
| Memory per instance | ~5-10MB idle | 15-30MB total |
| CPU per instance | < 10m idle | < 30m total |
| Max throughput | ~50K req/s (est.) | ~150K req/s (est.) |

---

## 11. FAQ

### Q: Do all AgentGate instances need the same JWT secret?

**No.** In mTLS mode, the JWT secret is never used. It exists on the `Config` struct but is dead code in the production request path. Each instance can have a different placeholder value.

### Q: Do AgentGate instances need to share state?

**No.** AgentGate is shared-nothing. Policy files are loaded from disk at startup. Denial tracking and audit logs are per-instance in-memory buffers. No Redis, no database, no coordination.

### Q: Can I mix mTLS and JWT auth in the same swarm?

**Not currently.** The `http.zig` server does not have JWT authentication wired into the request pipeline. The `AuthMiddleware` module exists but is only used by tests. If you need JWT alongside mTLS, you would need to wire it into `/check` route handling.

### Q: What happens when an AgentGate instance crashes?

In-flight requests are dropped. Since AgentGate is stateless, the load balancer routes subsequent requests to healthy instances. No session recovery needed. Denial records in the crashed instance's memory are lost (they are debugging aids, not authoritative).

### Q: How do I update policies across multiple instances?

**Method 1 (ConfigMap):** Update a Kubernetes ConfigMap and roll the deployment. Each new pod reads the updated policy file at startup.

**Method 2 (SIGHUP):** Send `SIGHUP` to all AgentGate processes. The server re-reads the config file and reloads policies.

**Method 3 (file watch):** Not yet implemented — the current code loads policies once at startup.

### Q: Can I use a single nginx for multiple AgentGate instances?

Yes. nginx acts as a reverse proxy and can load-balance across multiple upstream AgentGate instances:

```nginx
upstream agentgate_backend {
    least_conn;
    server agentgate-1:8080 max_fails=3 fail_timeout=30s;
    server agentgate-2:8080 max_fails=3 fail_timeout=30s;
    server agentgate-3:8080 max_fails=3 fail_timeout=30s;
}

server {
    listen 8443 ssl;
    # ... mTLS config ...
    location / {
        proxy_pass http://agentgate_backend;
        # ... forward X-SSL headers ...
    }
}
```

### Q: What ports does AgentGate expose?

| Port | Purpose | Notes |
|------|---------|-------|
| 8080 | Policy check API | HTTP, always behind nginx |
| 9090 | Prometheus metrics | `/metrics` endpoint (future) |

Both ports are `EXPOSE`d in the Dockerfile. nginx should be the only client with network access to port 8080.

---

## References

- `docs/EXTERNAL_TLS_ARCHITECTURE.md` — External TLS flow and SSL header parsing
- `docs/PRODUCTION_MTLS.md` — Production mTLS setup guide with PKI integration
- `docs/mtls-nginx.conf` — Production nginx configuration
- `docs/mTLS_TEST_SUITE_REPORT.md` — Test suite results and known limitations
- `scripts/test_mtls.sh` — Full integration test suite (15 tests)
- `src/server/http.zig` — SSL header parsing and identity derivation
- `src/auth/mTLS.zig` — `deriveAgentId()` implementation
- `src/config.zig` — TLS configuration schema and env var overrides
- `Dockerfile` — Multi-stage build with baked config
