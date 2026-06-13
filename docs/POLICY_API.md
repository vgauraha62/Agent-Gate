# Policy API Contract

## Overview

This document specifies the HTTP contract between the **Go proxy** (Anthropic API reverse proxy)
and the **Zig AgentGate** (policy evaluation engine). The Go proxy calls AgentGate to determine
whether AI agent tool invocations should be allowed or denied.

## Endpoint

```
POST /check
```

**Host**: AgentGate (port 8081 in two-service deployment)  
**Content-Type**: `application/json`

---

## Request Format

```json
{
  "agent_id": "claude-code-session-abc123",
  "tool": "bash",
  "command": "cat /etc/passwd",
  "path": "/etc/passwd",
  "input": {
    "command": "cat /etc/passwd",
    "description": "..."
  }
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_id` | string | optional | Agent/session identifier from `X-Agent-ID` header or derived from API key. Falls back to empty string if unavailable. |
| `tool` | string | required | The tool name being invoked (e.g., `bash`, `read`, `write`, `edit`, `read_file`, `write_file`). |
| `command` | string | optional | The command string or content being passed to the tool. For `bash` tools this is the shell command. For `write`/`edit` tools this is the content. |
| `path` | string | optional | The file path being accessed by the tool (e.g., `/workspace/src/main.go`). |
| `input` | object | optional | The full raw input object from the tool_use content block, for future use. |

### Legacy Format (Backward Compatible)

The `/check` endpoint also accepts the original simple format:

```json
{
  "path": "/api/users",
  "method": "GET"
}
```

When the legacy format is used (no `tool` field), the existing HTTP-based policy evaluation path
is followed using only `path` and `method` matching.

---

## Response Format

### ALLOW

```json
{
  "allowed": true,
  "policy_id": "allow-bash"
}
```

HTTP Status: **200 OK**

### DENY

```json
{
  "allowed": false,
  "policy_id": "block-secrets",
  "reason": "Access to /etc/passwd blocked"
}
```

HTTP Status: **403 Forbidden**

### TIMEOUT

```json
{
  "allowed": false,
  "policy_id": "timeout",
  "reason": "policy timeout"
}
```

HTTP Status: **504 Gateway Timeout**

### ERROR

```json
{
  "allowed": false,
  "policy_id": "error",
  "reason": "policy evaluation error"
}
```

HTTP Status: **403 Forbidden**

---

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `allowed` | boolean | `true` if the request is allowed, `false` if denied |
| `policy_id` | string | The ID of the policy that produced this decision. `"default-deny"` if no policy matched. `"timeout"` if evaluation timed out. `"error"` on evaluation failure. |
| `reason` | string | Human-readable reason for the decision (only present when `allowed` is `false`) |

---

## Tool Conditions

AgentGate supports these tool-aware condition types in policy definitions:

| Condition Field | Description | Example |
|----------------|-------------|---------|
| `tool` | Exact match on tool name | `"tool": "bash"` |
| `tool_pattern` | Wildcard match on tool name | `"tool_pattern": "read_*"` |
| `command_pattern` | Substring match on command content | `"command_pattern": "rm -rf"` |
| `path_pattern` | Prefix/substring match on file path | `"path_pattern": "/workspace/*"` |

---

## Error Handling

| HTTP Status | Meaning |
|-------------|---------|
| 200 | Request evaluated. Check `allowed` field. |
| 403 | Policy denied the request (or evaluation error). |
| 504 | Policy evaluation timed out (exceeded `policy_timeout_ms`). |
| 502 | AgentGate returned an unexpected response. |

---

## Example Sequences

### Allowed bash command

```http
POST /check HTTP/1.1
Content-Type: application/json

{"agent_id": "claude-abc", "tool": "bash", "command": "ls -la"}

HTTP/1.1 200 OK
Content-Type: application/json

{"allowed": true, "policy_id": "allow-bash"}
```

### Denied dangerous command

```http
POST /check HTTP/1.1
Content-Type: application/json

{"agent_id": "claude-abc", "tool": "bash", "command": "rm -rf /"}

HTTP/1.1 403 Forbidden
Content-Type: application/json

{"allowed": false, "policy_id": "block-rm-rf", "reason": "Dangerous command blocked: rm -rf"}
```

### Denied file access

```http
POST /check HTTP/1.1
Content-Type: application/json

{"agent_id": "claude-abc", "tool": "read", "path": "/etc/passwd"}

HTTP/1.1 403 Forbidden
Content-Type: application/json

{"allowed": false, "policy_id": "block-passwd", "reason": "Access to /etc/passwd blocked"}
```
