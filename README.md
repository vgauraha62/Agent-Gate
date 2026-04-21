# AgentGate

Lightweight agent security sidecar built in Zig.

## Problem

Agentic swarms lack standardized policy enforcement. Each agent implements auth/ad-hoc policies, leading to:
- Inconsistent security posture
- No audit trail
- High latency from repeated auth checks
- No compile-time policy guarantees

## Solution

AgentGate sits between agents and upstream services:
- **Sub-50µs P99 latency** - compile-time policy generation
- **Zero memory leaks** - arena allocation, explicit lifetimes
- **Tamper-evident audit log** - Merkle tree + cryptographic signatures
- **Drop-in deployment** - Docker Compose, Kubernetes

## Architecture

```
Agent → AgentGate (Auth + Policy + Audit) → Upstream
```

## Status

Day 1/15 - Project setup complete.

## Quick Start

```bash
zig build
zig build run
zig build test
```

## License

MIT
