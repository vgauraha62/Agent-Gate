# AgentGate Roadmap

## v1.0 (Current - Day 6-15)

### Phase 1: Core Foundation (Days 1-5) ✅
- [x] Project setup and build system
- [x] Core data structures (Arena, Secret, Agent)
- [x] JWT authentication
- [x] Policy engine foundation
- [x] HTTP server foundation

### Phase 2: Integration & Features (Days 6-10)
- [x] Day 6: End-to-End Request Processing ✅ COMPLETE
  - [x] Decision struct with policy attribution
  - [x] Error taxonomy (errors.zig)
  - [x] Config with timeout settings
  - [x] Graceful shutdown handler
  - [x] Load testing tools
  - [x] Dynamic secret injection (config flow wired)
  - [x] Hardened request lifecycle (timeout enforcement)
- [ ] Day 7: Audit Logging System
- [ ] Day 8: Metrics & Monitoring
- [ ] Day 9: mTLS Support (deferred from Day 6)
- [ ] Day 10: Configuration System

### Phase 3: Production Readiness (Days 11-15)
- [x] Day 11: Performance Optimization (Baseline: 10k req, P50=2.6ms, P99=16ms)
- [ ] Day 12: Testing & Fuzzing
- [ ] Day 13: Deployment Artifacts
- [ ] Day 14: Documentation & Demo
- [ ] Day 15: Final Testing & Package

---

## v2 Features (Post-Acquisition)

### High Priority

#### Hot Config Reload (SIGUSR1)
**Priority:** High | **Complexity:** Medium

Implement zero-downtime configuration reload via SIGUSR1 signal.

Requirements:
- Atomic config swap
- Preserve active connections
- Reload secrets, policies, timeouts
- No connection drops

```zig
// Planned implementation
pub fn handleSIGUSR1() void {
    // 1. Load new config from disk
    // 2. Validate new config
    // 3. Swap atomically using atomic pointers
    // 4. Zero old secret memory
}
```

#### Work-Stealing Thread Pool
**Priority:** Medium | **Complexity:** High

Optimize CPU utilization with work-stealing for multi-core systems.

Requirements:
- Lock-free task stealing
- Load imbalance detection
- Automatic enablement when imbalance >20%

```zig
// Planned: Work-stealing implementation
pub fn getNextTask(self: *Worker) ?Task {
    // 1. Check local queue
    if (self.local_queue.pop()) |task| return task;

    // 2. Steal from random workers
    if (self.steal()) |task| return task;

    return null;
}
```

#### Prometheus Metrics Endpoint
**Priority:** High | **Complexity:** Low

Already planned for Day 8 in PRD.

### Medium Priority

#### Zero-Copy Request Parsing
**Priority:** Medium | **Complexity:** High

Reduce allocations in HTTP parsing path.

#### Distributed Tracing
**Priority:** Medium | **Complexity:** Medium

OpenTelemetry integration for observability.

#### Rate Limiting
**Priority:** Medium | **Complexity:** Medium

Token bucket / sliding window rate limiting.

### Low Priority

#### mTLS Certificate Rotation
**Priority:** Low | **Complexity:** High

Support runtime certificate rotation without restart.

#### LDAP/Active Directory Integration
**Priority:** Low | **Complexity:** High

Enterprise authentication support.

#### gRPC Backend
**Priority:** Low | **Complexity:** Medium

Alternative to HTTP for high-performance scenarios.

---

## Deferred Items

| Item | Original Day | New Target | Reason |
|------|-------------|------------|--------|
| mTLS | Day 6 | Day 9 | Complexity, security review needed |
| Zero-copy parsing | Day 6 | Day 11 | Optimization phase |
| Hot config reload | Day 6 | v2 | Atomic swap complexity |

---

## Architecture Considerations for v2

### Secrets Management
- [ ] HashiCorp Vault integration
- [ ] AWS Secrets Manager integration
- [ ] Kubernetes Secrets integration

### Observability
- [ ] OpenTelemetry tracing
- [ ] Structured logging (JSON format)
- [ ] Alerting integration

### Scalability
- [ ] Horizontal scaling via consistent hashing
- [ ] Redis-backed session store
- [ ] Multi-region deployment support

---

## Performance Benchmark Results (Day 11 Baseline)

### Test Environment
- Zig version: 0.15.2
- Build: ReleaseFast
- Server mode: async (epoll)
- Test machine: Linux x86_64

### Baseline Results (Day 11 - Phase 4 Complete)

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Total Requests | 10,000 | - | ✅ |
| Successful | 10,000 | - | ✅ 100% |
| Failed | 0 | - | ✅ |
| P50 Latency | 2,656 μs | < 500 μs | ⚠️ |
| P99 Latency | 16,038 μs | < 500 μs | ⚠️ |
| P999 Latency | 39,039 μs | - | - |
| Avg Latency | 3,420 μs | < 500 μs | ⚠️ |
| Memory (RSS) | 1 MB | < 50 MB | ✅ |
| Throughput | 292 req/s | 5k+ req/s | ⚠️ |

### Observations
- Server handles 10k requests without errors
- Latency higher than target due to TCP connection overhead per request
- Memory usage well within limits
- Thread pool not fully utilized (only 2 threads spawned)

### Optimization Opportunities (for Day 11+)
1. Connection pooling to reduce TCP overhead
2. epoll-based client connections in loadtest
3. HTTP keep-alive support
4. Batch request processing
5. Async I/O in benchmark client

---

## Version Compatibility

| Version | Target Date | Key Features |
|---------|------------|-------------|
| v1.0 | Day 15 | Core functionality, acquisition demo |
| v1.1 | Post-acquisition | Hot reload, work-stealing |
| v1.2 | +3 months | Prometheus enhancements, rate limiting |
| v2.0 | +6 months | Distributed mode, Vault integration |