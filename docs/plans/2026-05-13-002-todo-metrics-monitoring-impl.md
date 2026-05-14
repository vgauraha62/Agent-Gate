# Day 8: Metrics & Monitoring - Implementation Todo List

> Status: **COMPLETED** | Date: 2026-05-13 | Follows: `2026-05-13-001-feat-metrics-monitoring-plan.md`

---

## Overview

Implementation todo list for upgrading monitoring from basic counters to production-grade OpenMetrics 2.0 system with HDR Histogram latency tracking.

**Goal:** Verify sub-50µs P99 latency targets with <1µs telemetry overhead per request.

---

## Implementation Order

### Phase 1: HDR Histogram Core (U1) - Foundation ✅ COMPLETED

| # | Task | File | Status |
|---|------|------|--------|
| 1.1 | Create HDR Histogram struct with logarithmic bucket system (1µs to 1s range) | `src/metrics/histogram.zig` | ✅ DONE |
| 1.2 | Implement `record(value: u64)` method - thread-safe bucket increment | `src/metrics/histogram.zig` | ✅ DONE |
| 1.3 | Implement percentile calculations: P50, P90, P99, P99.9 methods | `src/metrics/histogram.zig` | ✅ DONE |
| 1.4 | Implement `reset()` method - zero all buckets | `src/metrics/histogram.zig` | ✅ DONE |
| 1.5 | Add histogram unit tests - verify P50/P90/P99 accuracy | `src/metrics/histogram.zig` | ✅ DONE |
| 1.6 | Add edge case tests - min/max value recording | `src/metrics/histogram.zig` | ✅ DONE |

**Rationale:** Foundation for all latency tracking. Must be zero-allocation in hot path.

---

### Phase 2: Metrics Core Upgrade (U2) - Integrate with Existing ✅ COMPLETED

| # | Task | File | Status |
|---|------|------|--------|
| 2.1 | Add histogram field to Metrics struct | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.2 | Add `recordRequest(latency_us: u64, allowed: bool)` method | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.3 | Add P50/P90/P99 getter methods for export | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.4 | Add `active_sessions` gauge (rename active_connections) | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.5 | Add thread-safety to histogram recording | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.6 | Update existing tests for backward compatibility | `src/metrics/prometheus.zig` | ✅ DONE |
| 2.7 | Add new metric integration tests | `src/metrics/prometheus.zig` | ✅ DONE |

**Rationale:** Build on existing prometheus.zig - maintain counters but add histogram capability.

---

### Phase 3: OpenMetrics 2.0 Exporter (U3) - Export Format ✅ COMPLETED

| # | Task | File | Status |
|---|------|------|--------|
| 3.1 | Implement histogram bucket format with `le=` labels | `src/metrics/prometheus.zig` | ✅ DONE |
| 3.2 | Add histogram HELP/TYPE comments | `src/metrics/prometheus.zig` | ✅ DONE |
| 3.3 | Implement composite value format `{count:N,sum:S,bucket:[...]}` | `src/metrics/prometheus.zig` | ✅ DONE |
| 3.4 | Add `# EOF` at end of stream per OpenMetrics 2.0 spec | `src/metrics/prometheus.zig` | ✅ DONE |
| 3.5 | Add export format tests | `src/metrics/prometheus.zig` | ✅ DONE |
| 3.6 | Handle buffer overflow - dynamic buffer or streaming | `src/metrics/prometheus.zig` | ✅ DONE |

**Rationale:** Current export is basic Prometheus format - need to add histogram data.

---

### Phase 4: Server Integration - HTTP Handlers (U4) ✅ COMPLETED

| # | Task | File | Status |
|---|------|------|--------|
| 4.1 | Add `start_time` timer to `handleRequestThread` using `std.time.nanoTimestamp()` | `src/server/http.zig` | ✅ DONE |
| 4.2 | Add `recordRequest()` call before response with latency + allowed/denied | `src/server/http.zig` | ✅ DONE |
| 4.3 | Update `/check` handler to record latency | `src/server/http.zig` | ✅ DONE |
| 4.4 | Add timing to http_async.zig - same changes for async server | `src/server/http_async.zig` | ✅ DONE |
| 4.5 | Update `/metrics` route to show histogram | `src/server/http.zig`, `src/server/http_async.zig` | ✅ DONE |
| 4.6 | Verify no regressions - run existing tests | All servers | ✅ DONE |

**Rationale:** Critical integration - measure from request start to just before response.

---

### Phase 5: Observability Validation (U5) ✅ COMPLETED

| # | Task | File | Status |
|---|------|------|--------|
| 5.1 | Create benchmark script `scripts/benchmark_metrics.sh` | `scripts/benchmark_metrics.sh` | ✅ DONE |
| 5.2 | Add curl/wrk to benchmark - scrape `/metrics` endpoint | `scripts/benchmark_metrics.sh` | ✅ DONE |
| 5.3 | Add P99 verification - compare histogram P99 with external timing | `scripts/benchmark_metrics.sh` | ✅ DONE |
| 5.4 | Add overhead measurement - verify <1µs per request | `scripts/benchmark_metrics.sh` | ✅ DONE |
| 5.5 | Document expected values - P99 < 50µs target | `scripts/benchmark_metrics.sh` | ✅ DONE |

**Rationale:** Validate system under realistic load - verify P99 < 50µs target.

---

## File Changes Summary

| Phase | Files Created | Files Modified |
|-------|----------------|----------------|
| U1 | `src/metrics/hogram.zig` | - |
| U2 | - | `src/metrics/prometheus.zig` |
| U3 | - | `src/metrics/prometheus.zig` |
| U4 | - | `src/server/http.zig`, `src/server/http_async.zig` |
| U5 | `scripts/benchmark_metrics.sh` | - |

---

## Codebase Integration Flow

```
main.zig (Day 7)
    │
    ├─ Creates audit_logger
    ├─ Creates http.Server / http_async.Server
    └─ Uses global_metrics (prometheus)

handleRequestThread (http.zig:300)
    │
    ├─ start timer (std.time.nanoTimestamp())
    ├─ parseHttpRequestFast()
    ├─ route to handler
    ├─ handleCheckRequest()
    ├─ end timer → recordRequest(latency, allowed)
    └─ send response
```

---

## Key Requirements from Plan - Implementation Status

| Requirement | Target | Status |
|-------------|--------|--------|
| R1: Atomic counters | `requests_total`, `allowed_total`, `denied_total` | ✅ IMPLEMENTED |
| R2: High-precision latency tracking | HDR Histogram - P99 focus | ✅ IMPLEMENTED |
| R3: Gauge for active_sessions | `active_sessions` gauge | ✅ IMPLEMENTED |
| R4: `/metrics` endpoint | OpenMetrics 2.0 text format | ✅ IMPLEMENTED |
| R5: Recording overhead | <1µs per request | ✅ TARGET |

---

## Key Considerations - Completed

1. **Atomic patterns**: ✅ Used `std.atomic.Value(u64)` like existing prometheus.zig
2. **No heap allocation in hot path**: ✅ Pre-allocate histogram buckets (follow audit logger)
3. **Backward compatibility**: ✅ Keep `incRequests()`, `incAllowed()`, etc. working
4. **Multiple server support**: ✅ Both `http.zig` and `http_async.zig` need integration
5. **Test structure**: ✅ Follow `src/audit/integration_test.zig` pattern

---

## Verification Commands

```bash
# Run unit tests
zig build test

# Run histogram specific tests
zig test src/metrics/histogram.zig

# Run metrics tests
zig test src/metrics/prometheus.zig

# Run benchmark (requires server running)
./scripts/benchmark_metrics.sh
```

---

## Test Results

```
All 16 tests passed:
- 6 prometheus tests
- 10 histogram tests
```