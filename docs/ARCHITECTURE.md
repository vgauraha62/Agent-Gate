# Architecture (canonical)

Supersedes: root `ARCHITECTURE.md`, `docs/saas/03-architecture.md` (both now stubs pointing here).

## System overview

AgentGate Cage: four containers gating AI-agent tool calls. Two traffic paths:

1. Chat path: client -> proxy `:8080` (`POST /v1/messages`) -> policy check -> litellm `:4000` -> upstream model.
2. Gate path: harness -> agentgate `:8081` (`POST /check`) -> allow/deny JSON. Denials recorded in-memory + stdout.

## Components

- proxy (Go): Anthropic Messages handler, tool extraction, request/response-side policy filter, license check.
- agentgate (Zig): policy engine (first-match-wins), denial tracker ring (1000), audit logger, Prometheus counters.
- litellm: translation between Anthropic and OpenAI wire shapes, upstream to Zen/Ollama.
- license-server: JWT license issue/verify.

## Trust boundaries

Tool calls are gated before execution. Deny-by-default: engine returns deny when no policy matches. Secrets (API keys, certs) are redacted from IO dumps.
