---
title: feat: Day 8 Metrics & Monitoring
type: feat
status: active
date: 2026-05-13
origin: PRD.md
---

# Day 8 Metrics & Monitoring

## Overview
Upgrade monitoring from basic counters to a production-grade OpenMetrics 2.0 compatible system. Implement high-precision latency tracking using HDR Histograms to verify sub-50µs P99 targets.

---

## Problem Frame
Need real-time observability into sidecar performance and decision accuracy. Current counters are insufficient for tail-latency analysis (P99). Must avoid telemetry overhead impacting the critical request path.

---

## Requirements Trace
- R1. Atomic counters for `requests_total`, `allowed_total`, `denied_total`.
- R2. High-precision latency tracking (P99 focus) using HDR Histogram.
- R3. Gauge for `active_sessions`.
- R4. `/metrics` endpoint implementing OpenMetrics 2.0 text format.
- R5. Recording overhead < 1µs per request.

---

## Scope Boundaries
- No remote pushing (Pushgateway/Remote Write); pull-based only.
- No complex label sets (only `method` and `path`).
- No persistent metrics storage; all in-memory.

---

## Context & Research

### Relevant Code and Patterns
- `src/metrics/prometheus.zig`: Existing basic counters.
- `src/server/http.zig`: Request loop in `handleRequestThread` where hooks will be placed.
- `std.atomic.Value`: Used for lock-free counters.

### External References
- OpenMetrics 2.0 Specification (Composite Values for Histograms).
- HDR Histogram (High Dynamic Range) for precise percentile tracking.

---

## Key Technical Decisions
- **OpenMetrics 2.0**: Use Composite Value format for histograms to reduce exposition size and improve precision.
- **HDR Implementation**: Use a fixed-precision bucket array to minimize recording time to ~5-10ns.
- **Tethered Timing**: Start timer at `handleRequestThread` entry, stop before socket close.

---

## Implementation Units

- [ ] U1. **HDR Histogram Core**
**Goal:** Implement a high-precision latency histogram.
**Requirements:** R2
**Files:**
- Create: `src/metrics/histogram.zig`
- Test: `src/metrics/histogram_test.zig`
**Approach:** implement a logarithmic bucket system to capture microsecond precision across 1µs to 1s range.
**Test scenarios:**
- Happy path: Record 100 samples, verify P50, P90, P99 are calculated correctly.
- Edge case: Record values at extreme ends of range.
- Integration: Verify no memory leaks during continuous recording.
**Verification:** `zig build test` for histogram logic.

- [ ] U2. **Metrics Core Upgrade**
**Goal:** Integrate HDR Histogram and OpenMetrics 2.0 counters.
**Requirements:** R1, R3
**Dependencies:** U1
**Files:**
- Modify: `src/metrics/prometheus.zig`
**Approach:** Update `Metrics` struct to include the HDR histogram and `active_sessions` gauge. Use `std.atomic` for all counters.
**Test scenarios:**
- Happy path: Increment counters and verify values.
- Concurrency: Multiple threads incrementing counters without loss.
**Verification:** Correct atomic increments in tests.

- [ ] U3. **OpenMetrics Exporter**
**Goal:** Implement the Prometheus/OpenMetrics 2.0 text format.
**Requirements:** R4
**Dependencies:** U2
**Files:**
- Modify: `src/metrics/prometheus.zig`
**Approach:** Implement `export()` to write metrics using the composite value format for histograms.
**Test scenarios:**
- Happy path: Verify output matches OpenMetrics 2.0 spec (e.g., `{count:N,sum:S,bucket:[...]}`).
- Integration: Ensure `# EOF` is present at end of stream.
**Verification:** Validated via `curl` output analysis.

- [ ] U4. **Server Integration & Hooks**
**Goal:** Wire metrics into the request lifecycle.
**Requirements:** R5
**Dependencies:** U3
**Files:**
- Modify: `src/server/http.zig`
**Approach:** 
1. Add `start_time` using `std.time.timer` at start of `handleRequestThread`.
2. Call `metrics.recordRequest(latency, allowed)` before closing connection.
3. Map `/metrics` route to `metrics.export()`.
**Test scenarios:**
- Happy path: Request to `/check` updates counters and latency histogram.
- Happy path: `/metrics` returns valid data.
- Performance: Measure overhead of `recordRequest` call.
**Verification:** `/metrics` endpoint shows incremented values after requests.

- [ ] U5. **Observability Validation**
**Goal:** Verify P99 accuracy under load.
**Requirements:** R2, R5
**Dependencies:** U4
**Files:**
- Create: `scripts/benchmark_metrics.sh`
**Approach:** Run high-load test (10k req/s), scrape `/metrics`, and compare P99 with external timing.
**Test scenarios:**
- Integration: Run 1-minute burst, verify P99 latency matches expected system performance.
**Verification:** P99 latency reported by `/metrics` is within 5% of actual observed latency.

---

## System-Wide Impact
- **Interaction graph**: `handleRequestThread` $\rightarrow$ `Metrics.recordRequest` $\rightarrow$ `HDRHistogram.record`.
- **Error propagation**: Metrics recording must never throw; use `catch {}` to ensure telemetry failure doesn't crash the server.
- **State lifecycle risks**: Atomic counters are safe; Histogram needs to be thread-safe (use atomic bucket updates or a mutex for the specific bucket).

---

## Risks & Dependencies
| Risk | Mitigation |
|------|------------|
| Telemetry overhead | Use lock-free atomics and minimal-op HDR recording. |
| Cardinality explosion | Limit labels to `method` and `path`. Normalize paths. |
| Memory growth | Fixed-size HDR bucket array. |

---

## Sources & References
- **Origin document:** [PRD.md](PRD.md)
- External docs: [OpenMetrics 2.0 Spec](https://github.com/prometheus/docs/blob/main/docs/specs/om/open_metrics_spec_2_0.md)
