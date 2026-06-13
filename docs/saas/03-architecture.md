---
title: Architecture
nav_order: 3
---

# Architecture

## System Overview

AgentGate Cage consists of four containerized services that work together to intercept, inspect, and enforce policies on AI agent tool calls.

```
┌──────────────────────────────────────────────────────────────────────┐
│                        AgentGate Cage                                │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Proxy (Go)   :8080                                           │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────┐ ┌─────────────┐ │   │
│  │  │HTTP      │ │Tool      │ │Content       │ │Upstream     │ │   │
│  │  │Handler   │ │Extractor │ │Normalizer    │ │Forwarder    │ │   │
│  │  └──────────┘ └──────────┘ └──────────────┘ └─────────────┘ │   │
│  │                                                              │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────┐                │   │
│  │  │License   │ │Policy    │ │Streaming     │                │   │
│  │  │Validator │ │Client    │ │SSE Handler   │                │   │
│  │  └──────────┘ └──────────┘ └──────────────┘                │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                               │                                      │
│                               ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  AgentGate (Zig)   :8081                                     │   │
│  │  ┌──────────────┐ ┌────────────┐ ┌──────────┐ ┌──────────┐ │   │
│  │  │JWT / mTLS   │ │Policy      │ │Audit     │ │Rate      │ │   │
│  │  │Auth         │ │Engine      │ │Logger    │ │Limiter   │ │   │
│  │  └──────────────┘ └────────────┘ └──────────┘ └──────────┘ │   │
│  │                                                              │   │
│  │  ┌──────────────┐ ┌────────────┐                            │   │
│  │  │Prometheus   │ │Denial      │                            │   │
│  │  │Metrics      │ │Tracker     │                            │   │
│  │  └──────────────┘ └────────────┘                            │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                               │                                      │
│                               ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  LiteLLM (Python)   :4000                                    │   │
│  │  ┌──────────────────┐ ┌──────────────────┐                   │   │
│  │  │Model Router      │ │Format Translator │                   │   │
│  │  │(model→provider)  │ │(Anthropic↔OpenAI)│                   │   │
│  │  └──────────────────┘ └──────────────────┘                   │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Proxy (Go)

**Purpose**: HTTP entry point for AI clients. Handles all incoming requests, performs initial validation, extracts tool calls, checks policies, and forwards approved requests.

**Key files**: `proxy/main.go`, `proxy/config.go`, `proxy/anthropic/`, `proxy/upstream/`, `proxy/license/`, `proxy/policy/`

**Key responsibilities:**
- Parse Anthropic Messages API requests
- Extract tool invocations from message content
- Validate license status (or skip in dev mode)
- Send tools to AgentGate for policy evaluation
- Normalize content format (string→array)
- Forward allowed requests to upstream (LiteLLM or direct)
- Handle SSE streaming responses

### 2. AgentGate (Zig)

**Purpose**: Policy decision engine. Evaluates tool invocations against configurable rules, maintains tamper-evident audit logs, and enforces rate limits.

**Key files**: `src/main.zig`, `src/policy/`, `src/audit/`, `src/auth/`, `src/server/`

**Key responsibilities:**
- Serve policy evaluation HTTP API on `:8081`
- Authenticate requests (JWT or mTLS)
- Match tool invocations against policy decision tree
- Record all decisions in cryptographically chained audit log
- Sign audit log Merkle roots periodically
- Enforce per-agent rate limits
- Export Prometheus metrics on `:9090`

**Performance**: Policy decisions complete in <50µs P99. The Zig compiler's zero-cost abstractions and deterministic memory management enable this level of performance.

### 3. LiteLLM (Python)

**Purpose**: Format translation layer. Converts Anthropic Messages API format to OpenAI Chat Completions format, and routes to the correct AI provider based on model name.

**Key files**: `litellm-config.yaml`

**Key responsibilities:**
- Receive Anthropic-format requests from proxy
- Identify target provider from model name
- Translate to provider-native format
- Inject API credentials
- Route to correct upstream (Zen API, Anthropic, Ollama)
- Return response to proxy

**Why LiteLLM?**: LiteLLM is a battle-tested, MIT-licensed proxy that handles the complex format translation between AI providers. Rather than reimplementing this, AgentGate leverages LiteLLM's ecosystem compatibility.

### 4. License Server (Go)

**Purpose**: Issues and validates JWT license tokens. Optionally used in production for license enforcement.

**Key files**: `license-server/`

**Key responsibilities:**
- Issue JWT tokens with RSA signatures
- Validate tokens at proxy startup
- Enforce per-license rate limits and feature tiers
- Store license state in SQLite

**In development mode**: The license server is not needed. Set `AGENTGATE_PROXY_SKIP_LICENSE=true` to bypass all license checks.

## Data Flow: Request Lifecycle

```
┌────────────┐     ┌──────────────────────────────────────────────────────┐     ┌──────────┐
│            │     │               AgentGate Cage                        │     │          │
│  AI Client │     │                                                     │     │ Upstream  │
│  (OpenCode)│     │  Proxy          AgentGate         LiteLLM           │     │ AI API   │
│            │     │  (:8080)        (:8081)           (:4000)           │     │          │
└─────┬──────┘     └─────┬─────────────┬────────────────┬───────────────┘     └─────┬────┘
      │                  │              │                │                         │
      │ 1. POST          │              │                │                         │
      │ /v1/messages     │              │                │                         │
      │─────────────────▶│              │                │                         │
      │                  │              │                │                         │
      │ 2. License check │              │                │                         │
      │    (SKIP or OK)  │              │                │                         │
      │                  │              │                │                         │
      │ 3. Extract tools │              │                │                         │
      │    from message  │              │                │                         │
      │                  │              │                │                         │
      │ 4. Check tool    │              │                │                         │
      │    invocations   │─────────────▶│                │                         │
      │                  │   POST /api  │                │                         │
      │                  │   /check     │                │                         │
      │                  │              │ 5. Evaluate    │                         │
      │                  │              │    policies    │                         │
      │                  │              │    (match tree)│                         │
      │                  │              │                │                         │
      │ 6. Policy result │◀─────────────│                │                         │
      │    (allow/deny)  │   200/403    │                │                         │
      │                  │              │                │                         │
      │ [If DENY:        │              │                │                         │
      │  return 403]     │              │                │                         │
      │                  │              │                │                         │
      │ [If ALLOW:       │              │                │                         │
      │  7. Normalize    │              │                │                         │
      │     content      │              │                │                         │
      │                  │              │                │                         │
      │ 8. Forward       │──────────────┼───────────────▶│                         │
      │    request       │              │   POST /v1     │                         │
      │                  │              │   /chat/        │                         │
      │                  │              │   completions   │                         │
      │                  │              │                │ 9. Translate format     │
      │                  │              │                │    and forward          │
      │                  │              │                │────────────────────────▶│
      │                  │              │                │                         │
      │                  │              │                │ 10. AI response         │
      │                  │              │                │◀────────────────────────│
      │                  │              │                │                         │
      │ 11. Stream       │◀─────────────┼────────────────│                         │
      │     response     │   SSE stream │                │                         │
      │◀─────────────────│              │                │                         │
      │                  │              │                │                         │
```

## Service Dependencies

```
agentgate (standalone)
    │
    ▼ (depends_on: service_healthy)
proxy
    │
    ├──▶ LiteLLM (OpenCode mode)
    │         │
    │         ├──▶ Zen API (DeepSeek)
    │         └──▶ Ollama (local)
    │
    └──▶ Anthropic API (Claude mode, direct)
```

## Network Architecture

All services communicate over an internal Docker bridge network (`agentgate-net`). External access is limited to explicitly exposed ports.

```
Host ports exposed:
  :8080 → proxy    (AI client API)
  :8081 → agentgate (health checks, audit queries)
  :4000 → litellm   (debug/testing)
  :9090 → agentgate (metrics)

Internal-only:
  proxy      → http://agentgate:8081   (policy API)
  proxy      → http://litellm:4000     (AI upstream)
  proxy      → http://license-server:4001 (license validation)
```

## Related

- [**Configuration**](05-configuration.md) — Environment variables and config files
- [**Deployment**](04-deployment.md) — Full deployment guide
- [**Whitepaper**](../AGENTGATE_WHITEPAPER.md) — Deep architecture dive
