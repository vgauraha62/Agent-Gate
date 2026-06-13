---
title: Overview
nav_order: 1
---

# Overview

## What Is AgentGate Cage?

AgentGate Cage is a **policy enforcement sidecar** for AI coding agents. It sits between your AI client (OpenCode, Claude Code, Cursor) and the LLM (DeepSeek, Claude, Ollama), intercepts every tool invocation, evaluates it against security policies, and allows or blocks it *before* the LLM processes it.

Think of it as a **firewall for AI agent tool calls**.

## The Problem It Solves

AI agents execute powerful operations on your behalf:

```bash
# An AI agent might run any of these:
ls -la ~/project        # ✅ Harmless — read workspace files
rm -rf /                # ❌ Dangerous — delete everything
cat ~/.ssh/id_rsa       # ❌ Dangerous — steal SSH keys
kubectl delete pod ...   # ❌ Dangerous — destroy production
```

Standard API gateways (nginx, Kong, Envoy) **cannot distinguish** between these operations. They see `POST /v1/messages` for all of them.

AgentGate understands tool semantics:

```json
// AgentGate extracts these from the request body:
{ "tool": "bash",  "command": "rm -rf /" }        → DENY (policy: block-rm-rf)
{ "tool": "bash",  "command": "ls -la ~/project" }  → ALLOW (policy: allow-bash)
{ "tool": "read",  "path": "~/.ssh/id_rsa" }        → DENY (policy: block-ssh-keys)
```

## Key Capabilities

| Capability | What It Does |
|------------|-------------|
| **Tool extraction** | Parses Anthropic Messages API format to extract tool name, command, path, and input |
| **Policy evaluation** | Matches tool invocations against configurable allow/deny rules in <50µs |
| **Tamper-evident audit** | Every decision is SHA256-chained and Merkle-signed for verifiable audit trails |
| **Format translation** | Translates Anthropic Messages API ↔ OpenAI Chat Completions via LiteLLM |
| **Per-agent rate limiting** | Prevents individual agents from overwhelming the system |
| **License enforcement** | Free development mode; license-gated production features |
| **mTLS support** | Mutual TLS authentication between proxy and policy engine |

## Architecture at a Glance

```
Client → Proxy (:8080) → AgentGate (:8081) → LiteLLM (:4000) → AI API
         (Go)              (Zig)              (Python)
```

- **Proxy (Go)**: HTTP handling, license check, tool extraction, content normalization, request forwarding
- **AgentGate (Zig)**: Policy engine, audit logging, authentication, rate limiting, metrics
- **LiteLLM (Python)**: Format translation (Anthropic ↔ OpenAI), model routing, API key injection

## When to Use AgentGate Cage

**Use it when:**
- You run AI coding agents in development or production
- You need to enforce security policies on AI tool invocations
- You require tamper-evident audit trails for compliance
- You want zero cloud dependency for AI security infrastructure
- Sub-millisecond policy overhead matters

**Don't use it when:**
- You only need a general-purpose API gateway (use Kong/nginx)
- You only need format translation without policy (use LiteLLM alone)
- You're in a no-container environment (Docker is required)

## Quick Facts

| Fact | Value |
|------|-------|
| Language | Zig (policy engine) + Go (proxy) + Python (LiteLLM) |
| Policy latency | <50µs P99 |
| Throughput | 100K+ req/s |
| License | MIT (open source) |
| Deployment | Docker Compose (single host) |
| Status | Beta (v0.1) |

## Next Steps

- [**Quickstart**](02-quickstart.md) — Deploy in 5 minutes
- [**Architecture**](03-architecture.md) — Deep dive into components
- [**Deployment**](04-deployment.md) — Full deployment guide
