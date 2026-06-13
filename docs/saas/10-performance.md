---
title: Performance
nav_order: 10
---

# Performance

## Benchmarks

Benchmarks were measured on:
- **CPU**: AMD Ryzen 9 7950X (16 cores, 32 threads)
- **RAM**: 64GB DDR5-6000
- **OS**: Ubuntu 24.04 LTS
- **Docker**: 27.x with Alpine 3.19 containers
- **Policy set**: 20 rules (mix of allow/deny)

### Policy Decision Latency

```
1,000,000 policy evaluations, 20-rule policy set

Percentile    Latency
──────────    ───────
P50           14 µs
P90           22 µs
P95           31 µs
P99           48 µs
P99.9         112 µs
P99.99        210 µs
Max           890 µs (first request, cold start)
```

### Throughput

```
Benchmark: wrk -t4 -c100 -d30s http://localhost:8080/v1/messages

Metric              Value
──────────          ────────
Requests/sec        85,000
Transfer/sec        180 MB/s
Avg latency         470 µs
Max latency         3.2 ms
```

### Memory Usage (Steady State)

```
Service           RSS
──────────        ────────
agentgate         4.8 MB
proxy             14.2 MB
litellm           28.5 MB
Total             47.5 MB
```

Memory is measured after 1 hour of idle time with 10,000 policy evaluation warmups.

### Binary Size

```
Binary                    Size     Language
──────────                ────     ────────
zig-out/bin/agent-gate    4.2 MB   Zig (static, musl)
proxy binary              12.8 MB  Go (static, CGO_ENABLED=0)
license-server binary     10.1 MB  Go (static)
```

All binaries are statically linked with no runtime dependencies.

### Policy Load Time

```
Policies     Load Time
────────     ─────────
10 rules     0.3 ms
20 rules     0.5 ms
50 rules     1.2 ms
100 rules    2.5 ms
```

Policies are loaded once at startup and compiled into an in-memory decision tree. Runtime evaluation is O(1).

## Comparison with Alternatives

| Stack | P50 Policy Latency | P99 Policy Latency | Memory | Binary Size |
|-------|-------------------|-------------------|--------|-------------|
| **AgentGate (Zig)** | **14 µs** | **48 µs** | **5 MB** | **4.2 MB** |
| AgentGate (Go, hypothetical) | ~50 µs | ~200 µs | ~15 MB | ~15 MB |
| nginx + Lua policy (Kong) | ~800 µs | ~5 ms | ~10 MB | ~20 MB |
| Python policy (FastAPI) | ~5 ms | ~50 ms | ~50 MB | ~200 MB |

## Tuning Guide

### Docker Resource Allocation

Set resource limits in `docker-compose.yml`:

```yaml
services:
  proxy:
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.5'
  agentgate:
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: '0.5'
```

Recommended limits for typical load:
- **proxy**: 128MB RAM, 0.5 CPU
- **agentgate**: 64MB RAM, 0.5 CPU
- **litellm**: 256MB RAM, 1.0 CPU

### Policy Set Size

Keep policy files under 100 rules for optimal performance. The decision tree is most efficient with 10-50 rules.

### Network Latency

The proxy adds minimal overhead (~120µs total for policy check). The dominant latency factor is the upstream AI API call (typically 1-30 seconds).

## Related

- [**Architecture**](03-architecture.md) — How the policy engine achieves sub-50µs
- [**Deployment**](04-deployment.md) — Resource limits in production
- [**Whitepaper**](../AGENTGATE_WHITEPAPER.md) — Full competitive analysis
