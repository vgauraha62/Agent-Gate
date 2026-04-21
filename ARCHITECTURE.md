# Architecture

## System Overview

AgentGate is a sidecar proxy that enforces authentication and authorization policies for agentic swarms.

## Components

### Auth Engine
- JWT/PASETO validation
- mTLS handshake support
- Constant-time signature comparison

### Policy Engine
- JSON-based policy language
- Compile-time policy → decision tree compilation
- Pattern matching on agent_id, path, method

### Audit Logger
- Ring buffer (configurable size)
- Per-entry SHA256 hash
- Merkle tree root signed periodically
- Export for external verification

### HTTP Server
- Minimal HTTP/1.1 parser
- Zero-copy request parsing
- Concurrent connection handling

### Metrics
- Prometheus-compatible `/metrics` endpoint
- Latency histograms (HDR)
- Request counters, gauges

## Data Flow

1. Request arrives with JWT bearer token
2. Auth Engine validates token → Agent context
3. Policy Engine evaluates Agent + Request → Decision
4. Audit Logger records decision
5. Response returned (200 Allow / 403 Deny)

## Performance Targets

| Metric | Target |
|--------|--------|
| P99 Latency | <50µs |
| Throughput | >100K req/s |
| Memory | <50MB steady |
| Binary Size | <5MB |

## Security Properties

- Secrets zeroized on drop
- Constant-time comparisons
- Audit log tamper-evident
- TLS for all external comms
