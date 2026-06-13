# AgentGate: Can You Track/Block/Set Policies for Cloud LLMs & Coding Agents?

> **Verdict: No — Not Today. AgentGate has zero LLM/model/provider awareness.**

---

## The Short Answer

| Question | Answer |
|----------|--------|
| Can I track Claude Code, OpenCode, Cursor, Copilot? | **❌ No** |
| Can I block specific cloud models (GPT-4, Claude, Gemini)? | **❌ No** |
| Can I set policies per LLM provider (Anthropic, OpenAI)? | **❌ No** |
| Can I enforce policies when using any cloud LLM + IDE? | **❌ No** |
| Can I track token usage, cost, model selection? | **❌ No** |
| Can I intercept/proxy LLM API traffic? | **❌ No** |
| Is there any MCP/IDE/harness integration? | **❌ No** |

---

## What AgentGate Actually Is Today

AgentGate is a **policy enforcement sidecar for software agent swarms**. It does one thing:

```
Agent sends: POST /check  {"path": "/api/users", "method": "GET"}
AgentGate returns: {"allowed": true}  or  {"allowed": false, "policy_id": "deny-admin"}
```

That's it. It **does not proxy, forward, intercept, or inspect any traffic**. It's a standalone HTTP service that returns allow/deny decisions.

### Architecture (What Actually Runs)

```
┌──────────────┐          ┌──────────────┐
│  Your Agent  │──POST──▶ │  AgentGate   │
│  (asks:      │  /check  │  (responds:  │
│  "can I do   │          │  yes or no)  │
│  this?")     │◀─────────│              │
└──────────────┘          └──────────────┘
         │                       │
         │                       ├── Policy Engine (path/method/agent_id matching)
         │                       ├── Audit Logger (allow/deny decisions)
         │                       ├── Denial Tracker (ring buffer of denials)
         │                       └── Prometheus Metrics (request counts, latency)
         │
         ▼
   Agent decides whether
   to proceed on its own
```

> [!IMPORTANT]
> AgentGate is an **advisory service**, not a proxy. It doesn't sit in the data path. Your agent asks "can I do X?" and AgentGate says yes/no. The agent is responsible for obeying.

---

## What the Policy Engine Can Match On

The policy engine matches on exactly **3 dimensions** (defined in [types.zig](file:///home/gauraha/zig/agent-gate/src/policy/types.zig#L120-L149)):

| Dimension | Type | Example | Wildcard? |
|-----------|------|---------|-----------|
| `agent_id` | Opaque 32-byte hash | `"auth-service"` or `"*"` | ✅ `"*"` only |
| `path` | HTTP URL path | `"/api/users/*"` | ✅ Prefix `"/api/*"` |
| `method` | HTTP method | `"GET"`, `["GET", "POST"]` | ❌ |

### What's NOT in the Policy Language

The policy engine has **zero awareness** of:

- ❌ Model names (`claude-3.5-sonnet`, `gpt-4o`, `gemini-2.5-pro`)
- ❌ Providers (`anthropic`, `openai`, `google`)  
- ❌ Agent types (`claude-code`, `opencode`, `cursor`, `copilot`)
- ❌ Token budgets or limits
- ❌ Cost thresholds
- ❌ Request/response body content
- ❌ API keys or credentials
- ❌ Time-based rules (business hours, etc.)
- ❌ IP addresses or network origin
- ❌ Tool/function call names
- ❌ File system paths or operations

### Current Policy Format (what exists)

```json
{
  "version": "1",
  "policies": [
    { "id": "allow-api", "effect": "allow", "match": { "path": "/api/*" } },
    { "id": "deny-admin", "effect": "deny", "match": { "path": "/admin/*" } }
  ]
}
```

### What You'd NEED for LLM Governance (doesn't exist)

```json
{
  "id": "block-claude-opus",
  "effect": "deny",
  "match": {
    "provider": "anthropic",
    "model": "claude-opus-4-*",
    "agent_type": "claude-code"
  }
}
```

---

## Why It Can't Work with Cloud LLMs Today — 5 Missing Layers

### 1. No Traffic Interception (No Proxy)

AgentGate is **not a proxy**. A grep across the entire `src/` directory for `proxy`, `forward`, `upstream`, `reverse_proxy`, or `backend` returns **zero results**. There is no code to:
- Intercept outgoing HTTPS requests to `api.anthropic.com` or `api.openai.com`
- Forward requests to upstream LLM APIs
- Inspect request/response payloads
- Modify headers or inject policies into the traffic path

The server only has these endpoints ([http.zig](file:///home/gauraha/zig/agent-gate/src/server/http.zig#L597-L657)):
- `/health` — health check
- `/metrics` — Prometheus-style metrics
- `/check` — policy evaluation (POST only)
- `/denied-requests` — query recent denials
- `/v1/agents` — list agents (returns `[]`)
- `/v1/admin/*` — admin key management (hosted mode only)

### 2. No LLM Protocol Understanding

A grep for `claude`, `openai`, `anthropic`, `llm`, `model`, `provider`, `gemini`, `copilot`, `cursor`, `opencode` across all source files returns **zero results**. AgentGate has no knowledge of:
- OpenAI API format (`/v1/chat/completions`)
- Anthropic API format (`/v1/messages`)
- Google AI API format
- Any LLM-specific request/response structure
- Streaming vs non-streaming calls
- Tool/function call schemas

### 3. No Token/Cost Tracking

A grep for `token`, `cost`, `billing`, `spend` returns **zero results**. The [usage.zig](file:///home/gauraha/zig/agent-gate/src/usage.zig) tracker records:
- Request counts (total, allowed, denied)
- Latency (avg, P50, P99)
- Rate limiting (token bucket per API key)

But nothing about LLM-specific usage (input tokens, output tokens, model, cost).

### 4. No IDE/MCP/Harness Integration

A grep for `MCP`, `model context`, `ide`, `vscode`, `coding agent` returns **zero results**. There is:
- No MCP (Model Context Protocol) server or client
- No VS Code extension
- No IDE plugin hooks
- No `CLAUDE.md` or `AGENTS.md` integration
- No way to configure Claude Code, OpenCode, or Cursor to use AgentGate
- No environment variable interception (`ANTHROPIC_API_KEY`, etc.)

### 5. No Identity Mapping for Coding Agents

The [Agent](file:///home/gauraha/zig/agent-gate/src/agent.zig) struct is:
```zig
pub const Agent = struct {
    id: [32]u8,              // Opaque hash — no name, type, or version
    authenticated_at: i128,
    permissions: PermissionSet, // Infrastructure-level: read/write users/admin/policies/audit
};
```

There are **no string fields** — no `agent_name`, `agent_type`, `agent_version`, or `provider`. The agent identity is a raw 32-byte hash derived from either:
- mTLS client certificate (via nginx X-SSL headers)
- JWT `sub` claim (**but JWT auth is NOT wired into any production server**)

---

## What AgentGate CAN Do Today

Despite the limitations for LLM governance, AgentGate is a solid access control system for its designed use case:

| Capability | Status | Details |
|-----------|--------|---------|
| Authenticate software agents via mTLS | ✅ Working | Via nginx + X-SSL headers |
| Authenticate via API keys (hosted mode) | ✅ Working | With rate limiting, key management |
| Allow/deny decisions on path+method+agent | ✅ Working | Sub-millisecond policy evaluation |
| Tamper-evident audit logging | ✅ Working | SHA-256 hash chain, Ed25519 signed checkpoints |
| Denial tracking with filtering | ✅ Working | Ring buffer, queryable by agent/time |
| Prometheus-style metrics | ✅ Working | Request counts, latency percentiles |
| Rate limiting per API key | ✅ Working | Token bucket algorithm |
| Admin API for key management | ✅ Working | Create/list/revoke keys |
| JWT authentication library | ✅ Built | But **NOT wired** to any server |
| mTLS direct (without nginx) | ⚠️ Placeholder | TLS handshake is a stub |

---

## How Could You Achieve LLM Governance?

> [!WARNING]
> None of these exist today. This section describes what would need to be built.

### Option A: Make AgentGate an LLM Proxy (Major Rework)

Turn AgentGate into a forward/reverse proxy that sits between coding agents and LLM APIs:

```
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│  Claude Code │──HTTPS──▶│  AgentGate   │──HTTPS──▶│  api.anthro  │
│  / OpenCode  │          │  (proxy)     │          │  pic.com     │
│  / Cursor    │◀─────────│              │◀─────────│              │
└──────────────┘          └──────────────┘          └──────────────┘
                                │
                                ├── Parse model from request body
                                ├── Apply model/provider policies
                                ├── Count tokens from response
                                ├── Track cost per agent/key
                                └── Log everything to audit
```

**Requires:** HTTP/HTTPS proxy engine, TLS termination for outbound, LLM protocol parsers, token counting, cost database.

### Option B: Use AgentGate as a Policy Advisory + External Enforcement

Keep AgentGate as-is but extend the policy dimensions and use an external enforcement layer:

1. Extend the policy schema to support model/provider matching
2. Configure IDE/agent env to check AgentGate before API calls
3. Use environment variable injection (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`) to route through a separate proxy
4. Have the proxy call AgentGate's `/check` endpoint for policy decisions

### Option C: Abandon AgentGate for This Use Case

Use purpose-built LLM proxy/governance tools that already exist:
- **LiteLLM Proxy** — LLM proxy with model/provider policies, token tracking, cost tracking
- **Portkey** — AI gateway with policies, observability, caching
- **Helicone** — LLM observability platform
- **LangFuse** — LLM tracing and monitoring

---

## Key Findings Summary

| Component | File | LLM Awareness | Notes |
|-----------|------|---------------|-------|
| Policy Engine | [types.zig](file:///home/gauraha/zig/agent-gate/src/policy/types.zig) | ❌ None | Matches on agent_id, path, method only |
| Policy Parser | [parser.zig](file:///home/gauraha/zig/agent-gate/src/policy/parser.zig) | ❌ None | JSON → Condition{agent_id, path, method} |
| HTTP Server | [http.zig](file:///home/gauraha/zig/agent-gate/src/server/http.zig) | ❌ None | Returns allow/deny, not a proxy |
| Auth (JWT) | [jwt.zig](file:///home/gauraha/zig/agent-gate/src/auth/jwt.zig) | ❌ None | Standard JWT, no custom claims |
| Auth (mTLS) | [mTLS.zig](file:///home/gauraha/zig/agent-gate/src/auth/mTLS.zig) | ❌ None | Cert hash → agent_id, no names |
| Agent | [agent.zig](file:///home/gauraha/zig/agent-gate/src/agent.zig) | ❌ None | [32]u8 ID, no name/type/version |
| Audit | [logger.zig](file:///home/gauraha/zig/agent-gate/src/audit/logger.zig) | ❌ None | Binary allow/deny, no model info |
| Usage | [usage.zig](file:///home/gauraha/zig/agent-gate/src/usage.zig) | ❌ None | Request counts only, no tokens/cost |
| Metrics | [prometheus.zig](file:///home/gauraha/zig/agent-gate/src/metrics/prometheus.zig) | ❌ None | Global counters only, no per-model |
| Hosted Mode | [hosted.zig](file:///home/gauraha/zig/agent-gate/src/hosted.zig) | ❌ None | API key management, basic stats |
| Config | [config.zig](file:///home/gauraha/zig/agent-gate/src/config.zig) | ❌ None | No model/provider config sections |

**Bottom line:** AgentGate is a high-performance generic HTTP policy enforcement sidecar. It's excellent at what it does — sub-millisecond access control decisions for software agent swarms. But it has **absolutely zero capability** to track, block, or set policies for cloud-based LLMs or coding agents like Claude Code, OpenCode, Cursor, or Copilot.
