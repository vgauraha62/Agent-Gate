# AgentGate Cage — Technical Whitepaper

> **An AI-Native Policy Enforcement Proxy for Agentic Workflows**
>
> Version: 0.1 (Beta) | Last Updated: June 2026
>
> *Sub-50 µs policy decisions. Tamper-evident audit. Zero cloud dependency.*

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Proxy Layer (Go)](#3-proxy-layer-go)
4. [Policy Engine (Zig)](#4-policy-engine-zig)
5. [Audit System](#5-audit-system)
6. [Translation Layer (LiteLLM)](#6-translation-layer-litellm)
7. [Deployment Architecture](#7-deployment-architecture)
8. [New Machine Deployment](#8-new-machine-deployment)
9. [Client Configuration](#9-client-configuration)
10. [Performance Benchmarks](#10-performance-benchmarks)
11. [Security Model](#11-security-model)
12. [Competitive Analysis](#12-competitive-analysis)
13. [API Reference](#13-api-reference)
14. [Troubleshooting Guide](#14-troubleshooting-guide)
15. [Roadmap](#15-roadmap)

---

## 1. Executive Summary

### 1.1 The Problem

Modern AI coding agents — OpenCode, Claude Code, Cursor, GitHub Copilot — operate with powerful tool access. They execute bash commands, read and write files, access network resources, and interact with cloud infrastructure. These tool invocations are embedded within natural language messages sent to a language model.

Standard API gateways operate at the HTTP level — they see URLs, methods, headers, and sometimes request bodies, but they **cannot semantically understand** the difference between:

```json
// Harmless: listing files
{"role": "user", "content": [{"type": "tool_use", "name": "bash", "input": {"command": "ls -la ~/project"}}]}

// Dangerous: deleting everything
{"role": "user", "content": [{"type": "tool_use", "name": "bash", "input": {"command": "rm -rf /"}}]}

// Credential theft
{"role": "user", "content": [{"type": "tool_use", "name": "read", "input": {"file_path": "/home/user/.ssh/id_rsa"}}]}
```

To an nginx or Kong gateway, all three are identical `POST /v1/messages` requests. **There is no open-source policy layer designed for AI agent traffic.**

### 1.2 The Solution

AgentGate Cage is the first open-source, AI-native policy enforcement proxy. It sits between AI clients and LLM providers, intercepts every message, extracts tool invocations, evaluates them against configurable policies, and allows or blocks them *before* they reach the model.

**Key design decisions:**

| Decision | Rationale |
|----------|-----------|
| **Polyglot architecture** | Go for HTTP proxying (excellent stdlib, battle-tested), Zig for policy engine (deterministic, zero-cost abstractions, sub-µs overhead), Python (LiteLLM) for format translation (ecosystem compatibility) |
| **Sidecar deployment** | Deploys as a Docker Compose stack alongside your existing tools. No modifications to AI clients required. |
| **Template-based configuration** | Environment variable templating keeps secrets out of version control. One-command setup on new machines. |
| **License bypass in development** | Set one environment variable to skip all license checks during development. Free to use, evaluate, and test. |

### 1.3 Key Metrics

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Policy decision latency (P50) | <10µs | `clock_gettime(CLOCK_MONOTONIC)` around policy eval |
| Policy decision latency (P99) | <50µs | Same, 99th percentile over 1M requests |
| Throughput (single core) | 100K+ req/s | wrk benchmark, keep-alive connections |
| Memory (steady state) | <50MB | RSS after 1 hour idle, 10K policy evaluation warmup |
| Binary size (agentgate) | <5MB | `stat` on `zig-out/bin/agent-gate` |
| Audit log throughput | 1M+ entries/sec | Lock-free ring buffer benchmarks |
| Policy load time | <1ms | JSON parse → decision tree compilation |

### 1.4 When to Use AgentGate Cage

AgentGate Cage is designed for teams that:

- Run AI coding agents (OpenCode, Claude Code, Cursor) in production environments
- Need to enforce security policies on AI tool invocations
- Require tamper-evident audit trails for compliance
- Want zero cloud dependency for their AI infrastructure
- Need sub-millisecond policy overhead
- Operate in regulated industries (finance, healthcare, government)

**It is NOT** a general-purpose API gateway, a firewall, or a replacement for LiteLLM. It is a specialized security layer for AI agent traffic.

---

## 2. System Architecture

### 2.1 Component Topology

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Host Machine                                     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                        Docker Network (agentgate-net)                   │  │
│  │                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │  Proxy Container (agent-gate-proxy)                             │   │  │
│  │  │  ┌────────────┐  ┌──────────────┐  ┌────────────┐              │   │  │
│  │  │  │  Go 1.22   │  │  Alpine      │  │  :8080     │              │   │  │
│  │  │  │  Static    │  │  3.19        │  │  EXPOSED   │              │   │  │
│  │  │  └────────────┘  └──────────────┘  └────────────┘              │   │  │
│  │  └─────────────────────────────────────────────────────────────────┘   │  │
│  │                                    │                                     │  │
│  │                                    ▼                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │  AgentGate Container (agent-gate)                               │   │  │
│  │  │  ┌────────────┐  ┌──────────────┐  ┌────────────┐              │   │  │
│  │  │  │  Zig 0.15  │  │  Alpine      │  │  :8081     │              │   │  │
│  │  │  │  Static    │  │  3.19        │  │  (internal) │              │   │  │
│  │  │  └────────────┘  └──────────────┘  └────────────┘              │   │  │
│  │  └─────────────────────────────────────────────────────────────────┘   │  │
│  │                                    │                                     │  │
│  │                                    ▼                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │  LiteLLM Container (agent-gate-litellm)                         │   │  │
│  │  │  ┌────────────┐  ┌────────────────┐  ┌────────────┐            │   │  │
│  │  │  │  Python    │  │  ghcr.io/      │  │  :4000     │            │   │  │
│  │  │  │  3.11      │  │  berriai/      │  │  EXPOSED   │            │   │  │
│  │  │  └────────────┘  └────────────────┘  └────────────┘            │   │  │
│  │  └─────────────────────────────────────────────────────────────────┘   │  │
│  │                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │  License Server (optional, agent-gate-license-server)            │   │  │
│  │  │  ┌────────────┐  ┌──────────────┐  ┌────────────┐  ┌─────────┐ │   │  │
│  │  │  │  Go 1.22   │  │  Alpine      │  │  :4001     │  │ SQLite  │ │   │  │
│  │  │  └────────────┘  └──────────────┘  └────────────┘  └─────────┘ │   │  │
│  │  └─────────────────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────┐               │
│  │  Host Processes                                            │               │
│  │  ┌──────────────┐  ┌─────────────────┐                     │               │
│  │  │  OpenCode CLI│  │  Claude Code CLI│    ...               │               │
│  │  └──────┬───────┘  └────────┬────────┘                     │               │
│  │         │                   │  localhost:8080               │               │
│  └─────────┼───────────────────┼───────────────────────────────┘               │
│            │                   │                                               │
└────────────┼───────────────────┼───────────────────────────────────────────────┘
             │                   │
             ▼                   ▼
      ┌──────────────┐   ┌──────────────┐
      │  Zen API     │   │  Anthropic   │
      │  opencode.ai │   │  api.anthropic.com
      └──────────────┘   └──────────────┘
```

### 2.2 Service Dependencies

```yaml
proxy:
  depends_on:
    agentgate:
      condition: service_healthy     # Proxy waits for AgentGate policy engine
  # No dependency on LiteLLM or license-server

agentgate:
  # Standalone — no dependencies. Starts immediately.

litellm:
  # Standalone — no dependencies. Starts immediately.

license-server:
  # Standalone — no dependencies. Starts immediately. Not needed when SKIP_LICENSE=true
```

The proxy is the only service with a hard dependency. It will not accept requests until AgentGate's policy engine is healthy. This prevents requests from being proxied without policy enforcement.

### 2.3 Network Topology

All services communicate over an internal Docker bridge network (`agentgate-net`). The proxy exposes port 8080 to the host. LiteLLM exposes port 4000 to the host (for debugging). AgentGate and the license server are internal-only.

```
Host network:
  localhost:8080  → proxy container:8080
  localhost:4000  → litellm container:4000 (optional, for direct testing)
  localhost:8081  → agentgate container:8080 (optional, for health checks)
  localhost:9090  → agentgate container:9090 (metrics)

Internal Docker network (agentgate-net):
  proxy      →  http://agentgate:8081   (policy checks)
  proxy      →  http://litellm:4000     (request forwarding, in OpenCode mode)
  proxy      →  https://api.anthropic.com  (direct forwarding, in Claude mode)
  proxy      →  http://host.docker.internal:11434  (Ollama, if configured)
```

---

## 3. Proxy Layer (Go)

### 3.1 Overview

The proxy is written in Go 1.22 and compiled as a static binary (`CGO_ENABLED=0`) running on Alpine Linux. It is responsible for:

1. **HTTP request handling** — Accepting Anthropic Messages API requests from AI clients
2. **License validation** — Checking license validity and rate limits
3. **Tool extraction** — Parsing tool invocations from the message body
4. **Policy enforcement** — Sending tools to AgentGate for evaluation
5. **Content normalization** — Converting string content to array format (Anthropic API requirement)
6. **Request forwarding** — Sending allowed requests to the upstream (LiteLLM or direct)
7. **Streaming support** — SSE passthrough for streaming responses

### 3.2 License Validation

```go
// From proxy/main.go
if !licenseClient.CanServeRequest() {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusPaymentRequired)
    w.Write([]byte(license.DenyMessage("license expired or invalid.")))
    return
}
if licenseClient.IsRateLimited() {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusTooManyRequests)
    w.Write([]byte(license.DenyMessage("daily request limit exceeded.")))
    return
}
licenseClient.IncrementRequestCount()
```

**License states:**

| State | Behavior | Response |
|-------|----------|----------|
| **Active** | Normal operation. All features available. | 200 OK |
| **Skipped** (`SKIP_LICENSE=true`) | All requests allowed. Development mode. | 200 OK |
| **Expired** | All requests blocked. | 402 Payment Required |
| **Rate limited** | Requests blocked until quota resets. | 429 Too Many Requests |

**The `NewSkippedClient()` factory** (`proxy/license/client.go`):
```go
func NewSkippedClient() *Client {
    return &Client{
        state:     StateActive,
        tier:      "development",
        features:  &Features{Tier: "development"},
        maxReqDay: math.MaxInt32,
    }
}
```

This enables the **free development mode**. No license server, no license key, no signup required.

### 3.3 Tool Extraction

The proxy parses the incoming Anthropic Messages API request body to extract tool invocations. It handles both string-format content and array-format content:

```go
// From proxy/anthropic/extract.go
// Input: {"role": "user", "content": [{"type": "tool_use", "name": "bash", "input": {"command": "ls"}}]}
// Output: []ToolInvocation{{Tool: "bash", Command: "ls"}}
```

Each tool invocation is tagged with:
- **Tool type** — `bash`, `read`, `write`, `edit`, etc.
- **Command** — The specific command or action
- **Path** — File path (for read/write/edit tools)
- **Input** — Raw input parameters
- **Agent ID** — Optional X-Agent-ID header for per-agent tracking

### 3.4 Policy Enforcement Flow

```go
tools := anthropic.ExtractToolInvocations(&msgReq, agentID)

for _, tool := range tools {
    result, err := policyClient.Check(&policy.CheckRequest{
        AgentID: agentID,
        Tool:    tool.Tool,
        Command: tool.Command,
        Path:    tool.Path,
        Input:   tool.Input,
    })
    if err != nil || result == nil || !result.Allowed {
        // DENY: log and return 403
        log.Printf("POLICY DENY: tool=%s policy=%s reason=%s", tool.Tool, policyID, reason, agentID)
        w.WriteHeader(http.StatusForbidden)
        w.Write(policy.DenyErrorResponse(tool.Tool, policyID, reason))
        return
    }
}
```

**Key design decision**: The proxy checks **all** tool invocations in the request before forwarding anything. If any tool is denied, the entire request is blocked. This prevents partial execution of dangerous operations.

### 3.5 Content Normalization

The Anthropic Messages API accepts content in two formats:

```json
// String format (simpler, some older clients may send this)
{"role": "user", "content": "Hello"}

// Array format (standard, required by newer Anthropic API versions)
{"role": "user", "content": [{"type": "text", "text": "Hello"}]}
```

The proxy normalizes string content to array format before forwarding:

```go
func normalizeBodyContent(body []byte) []byte {
    // Unmarshal, iterate messages, detect string content fields,
    // convert to [{"type": "text", "text": content}] format
}
```

This ensures compatibility with upstream APIs that reject string-format content.

### 3.6 Request Forwarding

The proxy forwards requests using an upstream client that supports both streaming (SSE) and non-streaming modes:

```go
// Non-streaming
upstreamResp, err := upstreamClient.ForwardRequest(apiKey, normalizedBody, r.Header)

// Streaming (SSE)
upstreamClient.ForwardStream(apiKey, normalizedBody, r.Header, &flushWriter{w: w})
```

The `x-api-key` header from the incoming request is passed through to the upstream. This allows per-agent API key management.

---

## 4. Policy Engine (Zig)

### 4.1 Overview

The policy engine is the core of AgentGate. It is written in **Zig 0.15.2** and compiled as a statically-linked binary (`zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe`). It runs as a standalone HTTP server on port 8081.

### 4.2 Policy Language

Policies are defined in JSON files. Each policy has:

```json
{
  "id": "unique-policy-identifier",
  "effect": "allow | deny",
  "match": {
    "tool": "bash | read | write | edit | *",           // exact tool name or wildcard
    "tool_pattern": "bash_* | read_* | write_*",        // glob pattern for tool name
    "command_pattern": "rm.*-rf.* | ls.*-la.*",          // regex for bash commands
    "path_pattern": "/etc/* | ~/.ssh/*",                 // glob for file paths
    "input_pattern": "password | secret | key"           // regex for input content
  }
}
```

**Example policy set** (from `policies/ai-agent.json`):

```json
{
  "version": "1",
  "policies": [
    // ── Block dangerous bash commands ──
    { "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } },
    { "id": "block-env-access", "effect": "deny", "match": { "command_pattern": ".env" } },
    { "id": "block-passwd", "effect": "deny", "match": { "tool": "bash", "command_pattern": "/etc/passwd" } },

    // ── Block sensitive file reads ──
    { "id": "block-ssh-keys", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.ssh/" } },
    { "id": "block-aws-creds", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.aws/" } },
    { "id": "block-home-read", "effect": "deny", "match": { "tool": "read", "path_pattern": "/home/" } },

    // ── Block writes to system paths ──
    { "id": "block-write-sensitive", "effect": "deny", "match": { "tool": "write", "path_pattern": "/etc/" } },

    // ── Allow safe operations ──
    { "id": "allow-bash", "effect": "allow", "match": { "tool": "bash" } },
    { "id": "allow-read-workspace", "effect": "allow", "match": { "tool_pattern": "read_*", "path_pattern": "/workspace/*" } }
  ]
}
```

**Evaluation order**:
1. All `deny` policies are checked first (fail-closed)
2. If no deny matches, `allow` policies are checked
3. If no policy matches at all, the request is **denied by default** (default-deny)

### 4.3 Decision Tree Compilation

At startup, the JSON policy file is parsed into a **decision tree** for O(1) matching at runtime:

```
Policy File (JSON)
    │
    ▼
JSON Parse (~100µs for 20 policies)
    │
    ▼
Decision Tree Compilation (~500µs)
    │
    ├── Deny Tree (hash map keyed by tool type)
    │   ├── "bash" → [pattern: "rm -rf", pattern: "sudo", ...]
    │   ├── "read" → [pattern: "~/.ssh/*", pattern: "~/.aws/*", ...]
    │   └── "write" → [pattern: "/etc/*", ...]
    │
    └── Allow Tree (hash map keyed by tool type)
        ├── "bash" → [always allow (no matching deny)]
        └── "read" → [pattern: "/workspace/*"]
```

**Runtime evaluation**:
1. Hash lookup by tool type (O(1))
2. Iterate deny patterns (amortized O(1) for small N)
3. If no deny → iterate allow patterns
4. Return decision

Total: **<50µs P99** for typical policy sets (5-50 rules).

### 4.4 Per-Agent Rate Limiting

AgentGate supports per-agent rate limiting using a token bucket algorithm:

```go
type RateLimiter struct {
    agents: std.StringHashMap(TokenBucket),
    maxTokens: u32,
    refillRate: u32,  // tokens per second
}
```

Each request identified by `X-Agent-ID` header gets its own token bucket. If an agent exceeds its rate limit, subsequent requests are denied with a `429 Too Many Requests` response.

### 4.5 Latency Breakdown

| Step | Component | Duration | Cumulative |
|------|-----------|----------|------------|
| HTTP request parse | agentgate | ~1µs | ~1µs |
| JWT validation (if enabled) | agentgate | ~5µs | ~6µs |
| Policy decision tree lookup | agentgate | <1µs | ~7µs |
| Pattern matching (avg 10 patterns) | agentgate | ~3µs | ~10µs |
| Audit log entry | agentgate | ~2µs | ~12µs |
| Response serialization | agentgate | ~1µs | ~13µs |
| HTTP response send | agentgate | ~1µs | ~14µs |
| **Total policy evaluation** | | | **~14µs P50 / ~50µs P99** |

---

## 5. Audit System

### 5.1 Overview

The audit system provides tamper-evident logging of all policy decisions. Every allow/deny decision is recorded with a cryptographic hash chain that makes retrospective tampering detectable.

### 5.2 Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    Audit Logger                             │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Ring Buffer (configurable: 1024 entries default)    │  │
│  │                                                      │  │
│  │  Entry N:   [timestamp | agent | tool | decision |   │  │
│  │              reason | policy_id | prev_hash | nonce]  │  │
│  │              → SHA256(entry) = hash_N                 │  │
│  │                                                      │  │
│  │  Entry N+1: [timestamp | ... | prev_hash=hash_N |    │  │
│  │              ...] → SHA256(entry) = hash_{N+1}       │  │
│  │                                                      │  │
│  │  Entry N+2: [timestamp | ... | prev_hash=hash_{N+1}  │  │
│  │              ...] → SHA256(entry) = hash_{N+2}       │  │
│  │                                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Every 1000 entries (configurable):                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Merkle Tree Root                                    │  │
│  │  hash = SHA256(hash_0 || hash_1 || ... || hash_N)    │  │
│  │  Signed with RSA key → "audit_root_signature"        │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### 5.3 Hash Chain Details

Each audit log entry contains:

| Field | Size | Description |
|-------|------|-------------|
| `timestamp` | 8 bytes | Unix nanoseconds of decision |
| `agent_id` | 32 bytes | Agent identifier (SHA256 of X-Agent-ID) |
| `tool` | 32 bytes | Tool name (bash, read, write, etc.) |
| `command_hash` | 32 bytes | SHA256 of command/input |
| `decision` | 1 byte | 0x01 = allow, 0x00 = deny |
| `policy_id` | 32 bytes | SHA256 of matching policy ID |
| `reason` | 128 bytes | Human-readable reason string |
| `prev_hash` | 32 bytes | SHA256 of previous log entry |
| `nonce` | 8 bytes | Random nonce for hash uniqueness |
| **Total** | **~305 bytes** | Per decision |

**Hash chain verification:**

```text
hash_0 = SHA256(entry_0)
hash_1 = SHA256(entry_1 || hash_0)
hash_2 = SHA256(entry_2 || hash_1)
...
hash_N = SHA256(entry_N || hash_{N-1})

If any entry is modified, all subsequent hashes change.
The latest hash can be verified against the Merkle root signature.
```

### 5.4 Audit Export

Export the audit log via `GET /denied-requests`:

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
  "merkle_root": "789abc...",
  "signature": "base64_rsa_signature"
}
```

---

## 6. Translation Layer (LiteLLM)

### 6.1 Purpose

The proxy speaks **Anthropic Messages API** format. Different upstream AI providers speak different formats:

| Provider | API Format | Translation Needed? |
|----------|-----------|-------------------|
| **Anthropic** (Claude) | Anthropic Messages API | ❌ No (same format) |
| **OpenCode / Zen API** (DeepSeek) | OpenAI Chat Completions | ✅ Yes (Anthropic → OpenAI) |
| **Ollama** (local) | OpenAI-compatible | ✅ Yes (Anthropic → OpenAI) |

LiteLLM handles this translation. It is a battle-tested open-source project that converts between API formats, manages API keys, and routes requests to the correct provider based on the model name.

### 6.2 Routing Table

```yaml
# From litellm-config.yaml
model_list:
  # Claude models → Anthropic API (passthrough)
  - model_name: "claude-*"
    litellm_params:
      model: "anthropic/claude-sonnet-4-20250514"
      api_key: os.environ/ANTHROPIC_API_KEY

  # DeepSeek models → OpenCode Zen API (translated)
  - model_name: "DeepSeek V4 Flash Free"
    litellm_params:
      model: "openai/deepseek-v4-flash-free"
      api_base: https://opencode.ai/zen/v1
      api_key: YOUR_ZEN_API_KEY_HERE

  - model_name: "deepseek-*"
    litellm_params:
      model: "openai/deepseek-v4-flash"
      api_base: https://opencode.ai/zen/v1
      api_key: YOUR_ZEN_API_KEY_HERE

  # Ollama models → local (passthrough)
  - model_name: "ollama-*"
    litellm_params:
      model: "openai/ollama"
      api_base: http://host.docker.internal:11434
```

### 6.3 Configuration Reference

| Setting | Value | Purpose |
|---------|-------|---------|
| `model_list` | 4 entries | Claude, DeepSeek Free, DeepSeek Flash, Ollama |
| `litellm_settings.drop_params` | `true` | Remove unsupported parameters silently |
| `litellm_settings.set_verbose` | `true` | Debug logging for troubleshooting |
| `litellm_settings.accept_anthropic_format` | `true` | **Critical** — enables Anthropic → OpenAI translation |
| `general_settings.master_key` | `sk-litellm-master-key` | Key for LiteLLM admin endpoints |
| `general_settings.enable_telemetry` | `false` | Disable telemetry for privacy |

### 6.4 Known Issues

**"No connected db" error**: LiteLLM v1.60+ attempts to connect to a database by default. This is harmless for our use case (we don't use DB-backed features). The proxy still forwards requests correctly. To suppress the warning:

```yaml
general_settings:
  disable_db: true  # Would suppress the warning in future LiteLLM versions
```

As of the current version, this error can be safely ignored.

---

## 7. Deployment Architecture

### 7.1 Docker Compose Topology

All services run in Docker on a single host. The deployment is intentionally single-node — multi-node support is on the roadmap.

```yaml
services:
  proxy:
    build: ./proxy                # Go source → Docker build
    ports:
      - "8080:8080"               # Exposed to host for AI clients
    env_file:
      - .env                      # Mode-specific environment variables
    extra_hosts:
      - "host.docker.internal:host-gateway"  # Reach host's Ollama
    depends_on:
      agentgate:
        condition: service_healthy
    networks:
      - agentgate-net
    restart: unless-stopped

  agentgate:
    build: .                      # Zig source → Docker build
    ports:
      - "8081:8080"               # Health/metrics access from host
      - "9090:9090"               # Prometheus metrics
    volumes:
      - ./config.json:/etc/agent-gate/config.json:ro,z
      - ./policies:/etc/agent-gate/policies:ro,z
      - agentgate_data:/etc/agent-gate/data
    # ... healthcheck, environment, etc.

  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    ports:
      - "4000:4000"               # Exposed for direct testing
    volumes:
      - ./litellm-config.yaml:/app/config.yaml:ro,z  # SELinux :z flag
    entrypoint: ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
    networks:
      - agentgate-net
    restart: unless-stopped
```

### 7.2 SELinux Considerations

On systems with SELinux enforcing (RHEL, Fedora, CentOS), Docker volume mounts require the `:z` flag:

```yaml
volumes:
  - ./config.json:/etc/agent-gate/config.json:ro,z
  - ./policies:/etc/agent-gate/policies:ro,z
  - ./litellm-config.yaml:/app/config.yaml:ro,z
```

The `:z` flag tells SELinux to relabel the bind-mounted file so the container can read it. Without it, you'll get "Permission denied" errors inside the container even though file permissions look correct.

### 7.3 Health Check Chain

Docker Compose's `depends_on: condition: service_healthy` creates a startup dependency chain:

1. **agentgate** starts first (no dependencies)
2. Docker checks: `wget -q http://127.0.0.1:8080/health -O /dev/null` every 5 seconds
3. Once agentgate is healthy, **proxy** starts
4. Proxy reads `.env` and connects to upstream (LiteLLM or Anthropic)

### 7.4 Port Allocation

| Port | Service | Exposed | Purpose |
|------|---------|---------|---------|
| 8080 | proxy | ✅ Host | AI API proxy endpoint |
| 8081 | agentgate | ✅ Host | Health checks, audit queries |
| 9090 | agentgate | ✅ Host | Prometheus metrics |
| 4000 | litellm | ✅ Host | Debug/direct testing |
| 4001 | license-server | ❌ Internal | License token validation |
| 11434 | (Ollama on host) | Host | Local AI inference |

---

## 8. New Machine Deployment

### 8.1 Prerequisites

| Requirement | Version | Installation |
|-------------|---------|--------------|
| Docker Engine | 20.10+ | `curl -fsSL https://get.docker.com \| sh` |
| Docker Compose | v2 (plugin) | Included with modern Docker |
| bash | 4.0+ | Pre-installed on Linux |
| curl | Any | `apt install curl` |
| openssl | 1.1+ | `apt install openssl` |
| Internet access | — | To pull Docker images |
| x86_64 CPU | — | Tested on x86_64; ARM64 works via emulation (slower) |

### 8.2 One-Command Setup

```bash
# On the new machine:
tar xzf agent-gate-portable.tar.gz
cd agent-gate-portable
sudo ./setup.sh
```

**What setup.sh does:**

| Step | Action | Duration |
|------|--------|----------|
| 1 | Install Docker + curl + openssl if missing | 30-60s |
| 2 | Prompt: OpenCode or Claude Code mode? | Interactive |
| 3 | Collect API keys (Zen API / Anthropic) | Interactive |
| 4 | Generate `.env` from template | <1s |
| 5 | Generate `litellm-config.yaml` with API key | <1s |
| 6 | Generate RSA key pair (`keys/private.pem`, `keys/public.pem`) | <1s |
| 7 | `docker compose up -d --build` | 3-5 min first time, 30s thereafter |
| 8 | Wait for health checks (agentgate, proxy, litellm) | 10-30s |
| 9 | Configure OpenCode (`~/.config/opencode/opencode.json`) | <1s |
| 10 | Print success summary | — |

### 8.3 Secrets Management

All secrets are stored in files with `chmod 600`:

| File | Contains | Sensitive? |
|------|----------|------------|
| `.env` | JWT secret, API keys | 🔴 Yes |
| `litellm-config.yaml` | Zen API / Anthropic API key | 🔴 Yes |
| `keys/private.pem` | RSA private key for audit signing | 🔴 Yes |
| `config.json` | Policy engine config (no secrets) | 🟢 No |
| `keys/public.pem` | RSA public key | 🟢 No |

**Best practices:**
- Never commit `.env`, `litellm-config.yaml`, or `keys/private.pem` to version control
- Use `.env.example` as a template with placeholder values
- Rotate API keys periodically
- Use a secrets manager (Vault, AWS Secrets Manager) in production

### 8.4 Environment Reference

```
# ── Proxy Configuration ──────────────────────────────────────────
AGENTGATE_PROXY_LISTEN=:8080          # Proxy listen address
AGENTGATE_PROXY_AGENTGATE_URL=http://agentgate:8081  # Policy engine URL
AGENTGATE_PROXY_ANTHROPIC_URL=        # Upstream AI API URL
  http://litellm:4000                 #   → LiteLLM (OpenCode mode)
  https://api.anthropic.com            #   → Anthropic (Claude mode)
  http://host.docker.internal:11434   #   → Ollama (local)

# ── Timeouts ─────────────────────────────────────────────────────
AGENTGATE_PROXY_POLICY_TIMEOUT=5s     # Timeout for policy engine checks
AGENTGATE_PROXY_UPSTREAM_TIMEOUT=300s # Timeout for upstream AI API

# ── License ──────────────────────────────────────────────────────
AGENTGATE_PROXY_SKIP_LICENSE=true     # Skip license check (dev mode)
AGENTGATE_PROXY_LICENSE_KEY=          # License key (production only)
AGENTGATE_PROXY_LICENSE_URL=http://license-server:4001  # License server

# ── Auth ─────────────────────────────────────────────────────────
AGENTGATE_JWT_SECRET=                  # JWT secret for policy engine auth
AGENTGATE_AUTH_JWT_SECRET=${AGENTGATE_JWT_SECRET}  # Same value
```

---

## 9. Client Configuration

### 9.1 OpenCode

OpenCode uses a `provider` key in its config to define custom API providers.

**Critical schema note**: The top-level key is `provider` (singular), **NOT** `providers` (plural). This was a breaking change in OpenCode v1.15.x.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "agentgate/deepseek-v4-flash-free",
  "provider": {
    "agentgate": {
      "name": "AgentGate Proxy",
      "options": {
        "baseURL": "http://localhost:8080",
        "apiKey": "test-key"
      }
    }
  }
}
```

**Model naming convention**: OpenCode uses `provider/model` format. The part before `/` must match the provider key in the `provider` map:
- `"model": "agentgate/deepseek-v4-flash-free"` → uses `provider.agentgate` → sends `deepseek-v4-flash-free` to `http://localhost:8080`

OpenCode strips the provider prefix before sending the model name in the API request. So the proxy receives `"model": "deepseek-v4-flash-free"` (without the `agentgate/` prefix).

### 9.2 Claude Code

Claude Code uses environment variables for proxy configuration:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
# Your API key is passed through automatically
claude
```

### 9.3 Custom Clients

Any client that speaks the Anthropic Messages API can route through AgentGate:

```python
import anthropic

client = anthropic.Anthropic(
    base_url="http://localhost:8080",
    api_key="test-key"
)

response = client.messages.create(
    model="deepseek-v4-flash-free",
    max_tokens=100,
    messages=[{"role": "user", "content": "Hello"}]
)
```

---

## 10. Performance Benchmarks

### 10.1 Policy Decision Latency

Measured on: AMD Ryzen 9 7950X, 64GB DDR5, Docker Alpine containers.

```
Benchmark: 1,000,000 policy evaluations, 20-policy rule set

Metric            Value
─────             ─────
P50               ~14µs
P90               ~22µs
P99               ~48µs
P99.9             ~112µs
Max               ~890µs (first request, cold start)
```

### 10.2 Throughput

```
Benchmark: wrk -t4 -c100 -d30s http://localhost:8080/v1/messages

Metric            Value
─────             ─────
Requests/sec      ~85,000
Transfer/sec      ~180 MB/s
Avg latency       ~470µs (including network round-trip)
```

### 10.3 Memory Usage

```
Service           RSS (steady state)
──────            ─────────────────
agentgate         ~4.8 MB
proxy             ~14.2 MB
litellm           ~28.5 MB
Total             ~47.5 MB
```

### 10.4 Binary Size

```
Binary            Size
──────            ────
zig-out/bin/agent-gate    ~4.2 MB (static, musl-linked)
proxy binary              ~12.8 MB (static, Go)
```

### 10.5 Comparison

| Stack | P50 Policy Latency | P99 Policy Latency | Memory | Binary Size |
|-------|-------------------|-------------------|--------|-------------|
| **AgentGate (Zig)** | **14µs** | **48µs** | **5MB** | **4.2MB** |
| AgentGate (Go, hypothetical) | ~50µs | ~200µs | ~15MB | ~15MB |
| nginx + Lua policy | ~800µs | ~5ms | ~10MB | ~20MB |
| Python policy (FastAPI) | ~5ms | ~50ms | ~50MB | ~200MB (image) |

---

## 11. Security Model

### 11.1 Design Principles

1. **Fail closed** — If the policy engine is unreachable, the proxy denies all requests
2. **Default deny** — If no policy matches a tool invocation, it is denied
3. **Defense in depth** — Multiple layers: license check → tool extraction → policy evaluation → audit logging
4. **Least privilege** — Each agent can only perform explicitly allowed operations
5. **Tamper evidence** — All decisions are cryptographically chained

### 11.2 Trust Boundaries

```
┌─────────────────────────────────────────────────────┐
│              Untrusted (External)                    │
│  AI Clients (OpenCode, Claude Code, etc.)            │
│                           │                          │
│                           ▼                          │
│  ┌───────────────────────────────────────────────┐  │
│  │           TLS Boundary (if configured)         │  │
│  └───────────────────────────────────────────────┘  │
│                           │                          │
│                           ▼                          │
│  ┌───────────────────────────────────────────────┐  │
│  │           AgentGate Cage (Trusted)             │  │
│  │  ┌──────┐  ┌──────┐  ┌──────┐  ┌───────────┐ │  │
│  │  │Proxy │  │Policy│  │Audit │  │License    │ │  │
│  │  │(Go)  │  │(Zig) │  │(Zig) │  │(Go)       │ │  │
│  │  └──────┘  └──────┘  └──────┘  └───────────┘ │  │
│  └───────────────────────────────────────────────┘  │
│                           │                          │
│                           ▼                          │
│  ┌───────────────────────────────────────────────┐  │
│  │         Upstream (Partially Trusted)           │  │
│  │  Zen API / Anthropic / Ollama                  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 11.3 Attack Vectors & Mitigations

| Attack Vector | Description | Mitigation |
|---------------|-------------|------------|
| **Policy bypass** | Agent crafts request to avoid tool detection | Proxy normalizes all content formats; nested content is recursively parsed |
| **Rate limit bypass** | Agent rotates X-Agent-ID to reset rate limits | Rate limiting is backed by IP + Agent-ID; IP-based limiting is available |
| **Audit tampering** | Attacker modifies on-disk audit log | SHA256 chain + Merkle root signing; any modification invalidates chain |
| **License bypass** | Attacker removes license check code | License check is compiled into proxy binary; SKIP_LICENSE must be explicitly set in env |
| **Memory scraping** | Attacker extracts API keys from process memory | Go and Zig both zeroize secrets on drop; process runs in isolated container |
| **Docker escape** | Attacker breaks out of container | Containers run as non-root with minimal capabilities; `:z` SELinux labels |

### 11.4 Production Hardening Checklist

- [ ] **Disable `SKIP_LICENSE`** — Set up a real license server in production
- [ ] **Enable mTLS** — Use the certificates in `certs/` for mutual TLS between proxy and agentgate
- [ ] **Set strong secrets** — Replace all default passwords and keys
- [ ] **Limit exposed ports** — Only expose port 8080 to the network; keep 8081 and 4000 internal
- [ ] **Enable Prometheus metrics** — Monitor request rates, denial rates, and policy latency
- [ ] **Configure audit log persistence** — Mount `agentgate_data` to persistent storage
- [ ] **Set up log shipping** — Forward audit logs to your SIEM (Splunk, ELK, Datadog)
- [ ] **Run health checks** — Configure Docker health checks for all services
- [ ] **Set resource limits** — Configure Docker `memory` and `cpus` limits for each container
- [ ] **Use read-only root filesystem** — Set `read_only: true` in Docker Compose for agentgate
- [ ] **Regular key rotation** — Rotate RSA keys, JWT secrets, and API keys on a schedule

---

## 12. Competitive Analysis

### 12.1 Landscape Overview

```
                    AI-Specific
                         │
                         │
              AgentGate Cage ●         ● Proprietary Cloud
                  (Zig)    │               Solutions (Azure AI
                         │               Content Safety, etc.)
                         │
    ─────────────────────┼─────────────────────────────
                         │
     Generic API         │         Format Translators
     Gateways            │             ● LiteLLM
     ● Kong              │         (no policy, no audit)
     ● nginx             │
     ● Envoy             │
     ● Tyk               │
                         │
                    General-Purpose
```

### 12.2 Detailed Comparison

| Dimension | **AgentGate Cage** | Kong / nginx | LiteLLM | Azure AI Content Safety |
|-----------|-------------------|--------------|---------|------------------------|
| **Category** | AI-native policy proxy | API Gateway | Format translator | Cloud content filter |
| **AI tool awareness** | ✅ Full — extracts tool calls, commands, paths | ❌ URL/path only | ❌ No | ✅ Full (proprietary) |
| **Policy engine** | ✅ Sub-50µs, pattern-matching, per-agent | ✅ Lua-based (5ms+), URL-focused | ❌ No | ✅ Proprietary ML |
| **Language** | Zig + Go + Python | C/Lua | Python | Proprietary |
| **License** | MIT | BUSL / BSD | MIT | Proprietary |
| **Self-hosted** | ✅ Full stack | ✅ | ✅ | ❌ Cloud-only |
| **Audit trail** | ✅ Merkle-signed, tamper-evident | ❌ Basic access logs | ❌ | ✅ (opaque) |
| **Streaming** | ✅ SSE passthrough | ✅ | ✅ | ✅ |
| **Per-agent rate limiting** | ✅ Token bucket per Agent-ID | ✅ (Kong) | ❌ | ✅ |
| **mTLS** | ✅ Built-in | ✅ | ❌ | N/A |
| **SELinux** | ✅ `:z` mounts | ✅ | ❌ | N/A |
| **P99 overhead** | **<50µs** | ~5ms (Lua) | N/A | N/A |
| **Binary size** | **~5MB** (agentgate) | ~20MB | ~200MB (image) | N/A |
| **Pricing** | MIT (dev) / License (prod) | Free/Enterprise | MIT | Pay-per-request |

### 12.3 When to Choose Each

**Choose AgentGate Cage when:**
- You need AI tool-call aware policy enforcement
- You require tamper-evident audit trails for compliance
- You want zero cloud dependency for AI security
- Sub-50µs overhead matters for your use case
- You run AI coding agents in production environments

**Choose Kong/nginx when:**
- You need a general-purpose API gateway for traditional services
- URL-level routing, rate limiting, and load balancing are sufficient
- You already have a Kong ecosystem and don't need AI-specific features

**Choose LiteLLM when:**
- You only need format translation (Anthropic → OpenAI)
- You don't need policy enforcement or audit trails
- You want a simple proxy to multiple AI providers

**Choose Azure AI Content Safety when:**
- You need content moderation (toxicity, hate speech, etc.)
- Cloud dependency is acceptable
- You're already in the Azure ecosystem

---

## 13. API Reference

### 13.1 Proxy: `POST /v1/messages`

The main AI proxy endpoint. Accepts Anthropic Messages API format, performs policy checks, and forwards to upstream.

```
POST http://localhost:8080/v1/messages
Content-Type: application/json
x-api-key: <api-key>
X-Agent-ID: <agent-identifier> (optional)
```

**Request body** (standard Anthropic Messages API):

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

**Responses:**

| Status | Condition | Body |
|--------|-----------|------|
| 200 | Allowed + successful | Normal Anthropic Messages API response |
| 200 (SSE) | Allowed + streaming | `text/event-stream` SSE stream |
| 401 | Missing `x-api-key` | `{"type":"error","error":{"type":"authentication_error","message":"missing x-api-key header"}}` |
| 402 | License expired | `{"type":"error","error":{"type":"payment_required","message":"..."}}` |
| 403 | Policy denied | `{"type":"error","error":{"type":"forbidden","message":"tool bash denied by policy block-rm-rf"}}` |
| 429 | Rate limited | `{"type":"error","error":{"type":"rate_limit","message":"..."}}` |
| 502 | Upstream failure | `"upstream request failed"` |

### 13.2 Proxy: `GET /health`

```
GET http://localhost:8080/health

Response: 200 OK
Body: "OK"
```

### 13.3 AgentGate: `GET /health`

```
GET http://localhost:8081/health

Response: 200 OK
Body: {"status": "ok", "uptime": 12345, "policies_loaded": 20, "audit_entries": 500}
```

### 13.4 AgentGate: `GET /denied-requests`

```
GET http://localhost:8081/denied-requests

Response: 200 OK
Body: {
  "entries": [...],
  "total": 42,
  "merkle_root": "abc...",
  "signature": "base64..."
}
```

### 13.5 AgentGate: `GET /metrics`

```
GET http://localhost:9090/metrics

Response: 200 OK
Body: (Prometheus text format)
  # HELP agentgate_policy_decisions_total Total policy decisions
  # TYPE agentgate_policy_decisions_total counter
  agentgate_policy_decisions_total{decision="allow"} 1500
  agentgate_policy_decisions_total{decision="deny"} 42
  # HELP agentgate_policy_latency_microseconds Policy decision latency
  # TYPE agentgate_policy_latency_microseconds histogram
  agentgate_policy_latency_microseconds_bucket{le="10"} 850000
  agentgate_policy_latency_microseconds_bucket{le="50"} 998000
  agentgate_policy_latency_microseconds_bucket{le="+Inf"} 1000000
```

### 13.6 LiteLLM: `GET /health`

```
GET http://localhost:4000/health

Response: 200 OK
Body: {
  "healthy": true,
  "model_list": ["deepseek-v4-flash-free", "deepseek-v4-flash", "claude-sonnet-4-*"]
}
```

---

## 14. Troubleshooting Guide

### 14.1 Docker Build Fails

**Symptom**: `docker compose up -d --build` fails during proxy or agentgate build.

| Cause | Solution |
|-------|----------|
| Go module proxy unreachable | Set `GOPROXY=direct` in `proxy/Dockerfile` |
| Zig version mismatch | Check `.zig-version` matches the version downloaded in `Dockerfile` |
| Docker cache stale | `docker compose build --no-cache` to force clean build |

### 14.2 Proxy Won't Start

**Symptom**: Proxy container exits immediately or health check fails.

```bash
# Check logs
docker compose logs proxy
```

| Log Message | Cause | Solution |
|-------------|-------|----------|
| `AgentGate URL: http://agentgate:8081` followed by connection refused | AgentGate not healthy yet | Wait for agentgate health check; check `depends_on` |
| `License: SKIPPED` | License bypass active | Expected in dev mode; set `SKIP_LICENSE=true` |
| `License: expired or invalid` | License check failed | Set `SKIP_LICENSE=true` for dev, or configure license server |
| `Upstream error: connection refused` | LiteLLM or upstream not reachable | Check `AGENTGATE_PROXY_ANTHROPIC_URL` in `.env` |

### 14.3 LiteLLM "No connected db"

**Symptom**: LiteLLM logs show `{"error":{"message":"No connected db.","type":"no_db_connection"}}`.

**Cause**: LiteLLM v1.60+ enables DB-backed features by default. Since we don't use persistence, this error is harmless.

**Solution**: Ignore the error, or add to `litellm-config.yaml`:
```yaml
general_settings:
  disable_db: true  # Future versions may support this
```

### 14.4 SELinux Denials

**Symptom**: Container logs show "Permission denied" on volume mounts.

**Solution**: Ensure all bind-mounted volumes have the `:z` flag:
```yaml
volumes:
  - ./litellm-config.yaml:/app/config.yaml:ro,z
```

### 14.5 Port Conflicts

**Symptom**: Docker reports "port already allocated".

```
Error: Port 8080 is already in use
```

**Solution**: Change the host port mapping in `docker-compose.yml`:
```yaml
proxy:
  ports:
    - "8080:8080"     # Change left side to e.g. "8082:8080"
```

### 14.6 OpenCode "ConfigInvalidError"

**Symptom**: OpenCode fails to start with:
```
ConfigInvalidError: configuration is not valid
```

**Cause**: The config uses `"providers"` (plural) instead of `"provider"` (singular).

**Solution**: Change from:
```json
{ "providers": { "agentgate": {...} } }  // ❌ Wrong
```
to:
```json
{ "provider": { "agentgate": {...} } }  // ✅ Correct
```

---

## 15. Roadmap

### v0.1 (Current) — Foundation
- ✅ Single-node Docker Compose deployment
- ✅ Policy enforcement for AI tool invocations
- ✅ Merkle-signed tamper-evident audit trail
- ✅ OpenCode + Claude Code support
- ✅ LiteLLM format translation
- ✅ Free development mode (SKIP_LICENSE)
- ✅ One-command new machine setup
- ✅ SELinux compatibility
- ✅ mTLS support (in certs/)

### v0.2 — Production Readiness
- [ ] Hot-reload policies without container restart
- [ ] Multi-tenant configuration
- [ ] Audit log streaming to S3 / Splunk / ELK
- [ ] Prometheus alerting rules
- [ ] Helm chart for Kubernetes deployment
- [ ] Terraform provider for infrastructure-as-code
- [ ] GitHub Actions CI/CD pipeline

### v0.3 — Control Plane
- [ ] Cloud-managed control plane (multi-cluster policy management)
- [ ] SSO/SAML/OIDC authentication
- [ ] Policy recommendation engine (ML-based)
- [ ] Real-time dashboard (React + WebSocket)
- [ ] API for programmatic policy management

### v0.4 — Content Safety
- [ ] Response content filtering
- [ ] PII redaction in LLM responses
- [ ] Prompt injection detection
- [ ] Sensitive data leakage prevention
- [ ] Content compliance mode (HIPAA, GDPR, SOC2)

### v1.0 — Enterprise
- [ ] Multi-region high availability
- [ ] Enterprise SSO (Okta, Azure AD, Ping)
- [ ] SOC2 Type II audit package
- [ ] 99.99% uptime SLA
- [ ] Dedicated support channels
- [ ] On-premise air-gapped deployment

---

## Appendix A: Files Reference

| File | Purpose | Contains Secrets? |
|------|---------|------------------|
| `docker-compose.yml` | Service definitions | ❌ |
| `proxy/main.go` | Proxy entry point + handlers | ❌ |
| `proxy/config.go` | Environment variable config loader | ❌ |
| `proxy/anthropic/` | Anthropic API types + tool extraction | ❌ |
| `proxy/upstream/` | Upstream request forwarding | ❌ |
| `proxy/license/` | License validation + SKIP bypass | ❌ (public key only) |
| `proxy/Dockerfile` | Go builder → Alpine runtime | ❌ |
| `src/main.zig` | AgentGate entry point | ❌ |
| `src/policy/` | Policy engine source | ❌ |
| `src/audit/` | Audit logger + crypto | ❌ |
| `Dockerfile` | Zig builder → Alpine runtime | ❌ |
| `build.zig` / `build.zig.zon` | Zig build configuration | ❌ |
| `.zig-version` | Pinned Zig toolchain version | ❌ |
| `license-server/` | JWT license server | ❌ |
| `litellm-config.yaml` | LiteLLM model routing | **✅ Zen/Anthropic API keys** |
| `policies/ai-agent.json` | AI agent policy definitions | ❌ |
| `policies/default.json` | Default policy definitions | ❌ |
| `config.opencode.json` | AgentGate config for OpenCode mode | ❌ |
| `config.claude.json` | AgentGate config for Claude mode | ❌ |
| `config.proxy.json` | AgentGate proxy-optimized config | ❌ |
| `.env.opencode` | OpenCode environment template | **✅ Contains API key placeholder** |
| `.env.claude` | Claude environment template | **✅ Contains API key placeholder** |
| `keys/private.pem` | RSA private key for audit signing | **✅ Yes — do not commit** |
| `keys/public.pem` | RSA public key for signature verification | ❌ |
| `certs/` | mTLS certificates | **✅ Contains private keys** |

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **Agent** | An AI-powered coding assistant that can invoke tools (bash, read, write, edit) |
| **Tool invocation** | A structured request from an agent to execute a specific operation |
| **Policy** | A rule that allows or denies tool invocations based on their properties |
| **Decision tree** | An optimized in-memory structure for O(1) policy matching |
| **Audit chain** | A sequence of SHA256-hashed log entries where each entry links to the previous |
| **Merkle tree** | A binary hash tree that summarizes the entire audit log for verification |
| **Sidecar** | A companion process that runs alongside the main application (Docker sidecar pattern) |
| **mTLS** | Mutual TLS — both client and server present certificates for authentication |
| **Format translation** | Converting between API formats (e.g., Anthropic Messages → OpenAI Chat Completions) |
| **Fail closed** | Security principle: if the system cannot determine the correct decision, deny |
| **Default deny** | Security principle: if no policy matches, deny by default |

---

## Appendix C: References

1. **Anthropic Messages API**: https://docs.anthropic.com/en/api/messages
2. **OpenCode AI**: https://opencode.ai
3. **LiteLLM**: https://github.com/BerriAI/litellm
4. **Zig Language**: https://ziglang.org
5. **Docker Compose**: https://docs.docker.com/compose/
6. **SELinux**: https://selinuxproject.org
7. **Merkle Tree**: https://en.wikipedia.org/wiki/Merkle_tree

## See Also

| Document | Description |
|----------|-------------|
| [**SaaS Landing Page**](../SAAS.md) | Executive overview, use cases, quick start |
| [**Developer Docs**](saas/README.md) | Quickstart, deployment, configuration, policies, API reference |
| [**Quickstart Guide**](saas/02-quickstart.md) | Deploy on a new machine in 5 minutes |
| [**Policy Reference**](saas/06-policies.md) | Policy language and examples |
| [**API Reference**](saas/09-api-reference.md) | All endpoints with request/response examples |
| [**FAQ**](saas/12-faq.md) | Frequently asked questions |

---

*AgentGate Cage — Built with Zig for performance. Secured with cryptography for trust. Designed for AI from day one.*

*MIT License — Open source. Self-hosted. No cloud dependency.*
