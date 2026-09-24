---
title: API Reference
nav_order: 9
---

# API Reference

## Proxy Endpoints

### `POST /v1/messages`

Main AI proxy endpoint. Accepts Anthropic Messages API format, performs policy checks, and forwards to upstream.

**URL**: `http://localhost:8080/v1/messages`

**Method**: `POST`

**Headers**:

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | ✅ | `application/json` |
| `x-api-key` | ✅ | API key (any non-empty value in dev mode) |
| `X-Agent-ID` | ❌ | Agent identifier for per-agent tracking |

**Request Body** (Anthropic Messages API format):

```json
{
  "model": "deepseek-v4-flash-free",
  "max_tokens": 1024,
  "stream": false,
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "Hello"}]}
  ],
  "tools": [
    {
      "name": "bash",
      "description": "Execute a bash command",
      "input_schema": {
        "type": "object",
        "properties": {
          "command": {"type": "string"}
        }
      }
    }
  ]
}
```

**Responses**:

| Status | Condition | Body |
|--------|-----------|------|
| 200 | Allowed + successful | Standard Anthropic Messages API response |
| 200 (SSE) | Allowed + streaming | `text/event-stream` SSE stream |
| 400 | Invalid request body | `{"type":"error","error":{"type":"invalid_request_error","message":"..."}}` |
| 401 | Missing `x-api-key` | `{"type":"error","error":{"type":"authentication_error","message":"missing x-api-key header"}}` |
| 402 | License expired | `{"type":"error","error":{"type":"payment_required","message":"license expired"}}` |
| 403 | Policy denied | `{"type":"error","error":{"type":"forbidden","message":"tool bash denied by policy block-rm"}}` |
| 405 | Wrong method | `method not allowed` |
| 429 | Rate limited | `{"type":"error","error":{"type":"rate_limit_error","message":"..."}}` |
| 502 | Upstream failure | `"upstream request failed"` |

### `GET /health`

Proxy health check.

**URL**: `http://localhost:8080/health`

**Method**: `GET`

**Response**: `200 OK`
**Body**: `OK`

## AgentGate Endpoints

### `GET /health`

Policy engine health check.

**URL**: `http://localhost:8081/health`

**Method**: `GET`

**Response**: `200 OK`
**Body**: `OK`

### `GET /denied-requests`

Retrieve recent denied requests from the denial tracker.

**URL**: `http://localhost:8081/denied-requests`

**Method**: `GET`

**Query Parameters**:

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `limit` | int | 100 | Max entries (max 1000) |
| `agent` | hex(64) | — | Filter by agent ID (64 hex chars) |
| `since` | int | — | Unix timestamp (µs) — only entries after this time |

**Response**: `200 OK`
**Body**:
```json
{
  "total": 42,
  "denials": [
    {
      "timestamp": 1748800000123456,
      "agent_id": "a1b2c3d4e5f6...",
      "path": "/etc/passwd",
      "method": "read",
      "policy_id": "block-sensitive-files",
      "reason": "file_path_denied"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `total` | int | Total denials since server start |
| `denials[].timestamp` | int | Unix timestamp in microseconds |
| `denials[].agent_id` | string | 64-char hex agent fingerprint |
| `denials[].path` | string | The path that was checked |
| `denials[].method` | string | HTTP method |
| `denials[].policy_id` | string | Policy that denied the request |
| `denials[].reason` | string | Enum reason for denial |

### `POST /check`

Evaluate a tool invocation against the policy engine.

**URL**: `http://localhost:8081/check`

**Method**: `POST`

**Headers**:

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | ✅ | `application/json` |
| `X-API-Key` | 🟡 | Required in hosted API mode (`api.enabled: true`) |

**Request Body**:

Supports two formats:

**Legacy format:**
```json
{
  "path": "/api/users",
  "method": "GET"
}
```

**Tool-aware format (recommended):**
```json
{
  "tool": "bash",
  "command": "ls -la",
  "path": "/workspace"
}
```

**Response**: `200 OK`

```json
{"allowed": true}
```

On denial:
```json
{"allowed": false, "reason": "policy denied by: block-rm", "policy_id": "block-rm"}
```

---

### `GET /v1/agents`

List registered agents. Currently returns a static placeholder.

**URL**: `http://localhost:8081/v1/agents`

**Method**: `GET`

**Response**: `200 OK`
**Body**: `[]`

---

### `GET /v1/admin/keys`

List API keys (hosted mode only, requires admin auth).

**URL**: `http://localhost:8081/v1/admin/keys`

**Method**: `GET`

**Headers**:

| Header | Required | Description |
|--------|----------|-------------|
| `X-Admin-Key` | ✅ | Admin API key |

**Response**: `200 OK`

```json
{"keys": ["key_abc...", "key_def..."], "total": 2}
```

**Notes**: Requires `api.enabled: true` in config. If hosted mode is disabled, returns 404.

---

### `POST /v1/admin/keys`

Create a new API key.

**URL**: `http://localhost:8081/v1/admin/keys`

**Method**: `POST`

**Headers**:
- `Content-Type: application/json`
- `X-Admin-Key`: Admin API key

**Request Body**:
```json
{
  "name": "my-key",
  "rate_limit": 100
}
```

**Response**: `201 Created`

```json
{"key": "ag_k8sZ...", "name": "my-key", "rate_limit": 100}
```

---

### `DELETE /v1/admin/keys`

Revoke an API key.

**URL**: `http://localhost:8081/v1/admin/keys`

**Method**: `DELETE`

**Headers**:
- `Content-Type: application/json`
- `X-Admin-Key`: Admin API key

**Request Body**:
```json
{
  "key": "ag_k8sZ..."
}
```

**Response**: `200 OK`

```json
{"revoked": true}
```

---

### `GET /v1/admin/usage`

Retrieve usage statistics (hosted mode only).

**URL**: `http://localhost:8081/v1/admin/usage`

**Method**: `GET`

**Headers**:
- `X-Admin-Key`: Admin API key

**Response**: `200 OK`

```json
{"requests": 1234, "rate_limited": 5, "keys": 3}
```

---

### `GET /v1/admin/stats`

Server statistics (hosted mode only).

**URL**: `http://localhost:8081/v1/admin/stats`

**Method**: `GET`

**Headers**:
- `X-Admin-Key`: Admin API key

**Response**: `200 OK`

```json
{
  "uptime_seconds": 3600,
  "total_requests": 5000,
  "active_keys": 3,
  "rate_limited": 12
}
```

---

### `GET /metrics`

Policy engine metrics in custom key-value format.

**URL**: `http://localhost:8081/metrics`

**Method**: `GET`

**Response**: `200 OK`
**Headers**: `Content-Type: text/plain`

**Body**:
```
requests_total: 42
allowed: 38
denied: 4
active: 2
histogram_count: 50
latency_p50: 15
latency_p90: 45
latency_p99: 120
```

| Field | Description |
|-------|-------------|
| `requests_total` | Total requests evaluated |
| `allowed` | Requests that passed policy |
| `denied` | Requests blocked by policy |
| `active` | Current active sessions |
| `histogram_count` | Samples in latency histogram |
| `latency_p50` | Median latency (µs) |
| `latency_p90` | 90th percentile latency (µs) |
| `latency_p99` | 99th percentile latency (µs) |

**Prometheus scraping**: custom key-value format — convert with a small exporter or consume directly with scripts.

## LiteLLM Endpoints

### `GET /health`

LiteLLM health check with model status.

**URL**: `http://localhost:4000/health`

**Method**: `GET`

**Response**: `200 OK`
**Body**:
```json
{
  "healthy": true,
  "model_list": [
    "deepseek-v4-flash-free",
    "deepseek-v4-flash",
    "claude-sonnet-4-20250514"
  ]
}
```

### `GET /health/readiness`

Detailed service readiness.

**URL**: `http://localhost:4000/health/readiness`

**Response**: `200 OK`
**Body**: Detailed JSON with per-model status.

## Audit Log

The audit logger (`src/audit/logger.zig`) maintains a **Merkle chain** of every policy decision for compliance and forensics. This is an in-memory ring buffer — not directly exposed via REST.

```
LogEntry (packed struct):
  sequence: u64
  timestamp_us: u64
  agent_id: [32]u8
  path_hash: [16]u8
  decision: u8
  previous_hash: [16]u8   ← Merkle chain link
  current_hash: [16]u8    ← sha256(previous_hash || entry_data)
```

The `/denied-requests` endpoint is a **separate, simplified** view from the denial tracker — it includes event details but no cryptographic hashes.

---

## Error Codes

| Code | HTTP Status | Meaning |
|------|-------------|---------|
| `authentication_error` | 401 | Missing or invalid API key |
| `payment_required` | 402 | License expired or invalid |
| `forbidden` | 403 | Policy denied the tool invocation |
| `invalid_request_error` | 400 | Malformed request body |
| `rate_limit_error` | 429 | Too many requests (rate limited) |
| `upstream_error` | 502 | Upstream AI API unreachable or errored |
| `method_not_allowed` | 405 | Wrong HTTP method |

## Related

- [**Client Setup**](07-client-setup.md) — Client configuration
- [**Performance**](10-performance.md) — Performance benchmarks
- [**Troubleshooting**](11-troubleshooting.md) — Common issues
