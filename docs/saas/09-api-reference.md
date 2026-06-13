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
| 403 | Policy denied | `{"type":"error","error":{"type":"forbidden","message":"tool bash denied by policy block-rm-rf"}}` |
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
**Body**:
```json
{
  "status": "ok",
  "uptime": 12345,
  "policies_loaded": 20,
  "audit_entries": 500
}
```

### `GET /denied-requests`

Retrieve denied requests from the audit log.

**URL**: `http://localhost:8081/denied-requests`

**Method**: `GET`

**Response**: `200 OK`
**Body**:
```json
{
  "entries": [
    {
      "seq": 1423,
      "timestamp": "2026-06-02T14:30:00.123456789Z",
      "agent_id": "a1b2c3d4e5f6...",
      "tool": "bash",
      "command_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "decision": "deny",
      "policy_id": "block-rm-rf",
      "reason": "rm -rf blocked by policy block-rm-rf",
      "prev_hash": "abcdef...",
      "hash": "123456..."
    }
  ],
  "total": 42,
  "merkle_root": "789abc...",
  "signature": "base64_rsa_signature"
}
```

### `GET /metrics`

Prometheus-format metrics.

**URL**: `http://localhost:9090/metrics`

**Method**: `GET`

**Response**: `200 OK`
**Headers**: `Content-Type: text/plain; version=0.0.4`

**Body**:
```
# HELP agentgate_policy_decisions_total Total policy decisions
# TYPE agentgate_policy_decisions_total counter
agentgate_policy_decisions_total{decision="allow"} 1500
agentgate_policy_decisions_total{decision="deny"} 42

# HELP agentgate_policy_latency_microseconds Policy decision latency
# TYPE agentgate_policy_latency_microseconds histogram
agentgate_policy_latency_microseconds_bucket{le="10"} 850000
agentgate_policy_latency_microseconds_bucket{le="50"} 998000
agentgate_policy_latency_microseconds_bucket{le="+Inf"} 1000000

# HELP agentgate_audit_entries_total Total audit log entries
# TYPE agentgate_audit_entries_total counter
agentgate_audit_entries_total 1500

# HELP agentgate_rate_limited_total Total rate-limited requests
# TYPE agentgate_rate_limited_total counter
agentgate_rate_limited_total 5

# HELP agentgate_active_agents Currently active agent sessions
# TYPE agentgate_active_agents gauge
agentgate_active_agents 3
```

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
