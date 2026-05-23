---
title: "refactor: Performance Optimization for Sub-50µs Latency"
type: refactor
status: active
date: 2026-05-22
origin: task_plan.md
---

# refactor: Performance Optimization for Sub-50µs Latency

## Overview

Optimize request processing and policy evaluation to achieve sub-50µs P99 latency. This involves transitioning the policy engine from a linear scan $O(N)$ to a Trie-based lookup $O(L)$ and ensuring strict zero-copy semantics across the request pipeline.

---

## Problem Frame

Current implementation uses linear iteration over policies, causing latency to degrade as policy counts increase. While the HTTP parser is largely zero-copy, the policy engine's evaluation hot-path is the primary bottleneck preventing the target < 50µs P99 latency.

---

## Requirements Trace

- R1. Sub-500µs P99 latency (Baseline from `task_plan.md`).
- R2. Sub-50µs P99 latency (Target from `PRD.md`).
- R3. Zero-copy request parsing: No heap allocations for headers or paths.
- R4. Optimized policy evaluation: Replace linear scan with decision tree/trie.
- R5. High throughput: Support > 100K requests per second.

---

## Scope Boundaries

- **Non-Goals**:
    - Redesigning the `epoll` network loop (keep as is unless Trie optimization is insufficient).
    - Adding new policy language features.
    - Optimizing non-hot-path admin endpoints (e.g., `/denied-requests`).

### Deferred to Follow-Up Work

- Transition to `io_uring` for extreme throughput: Deferred to post-acquisition optimization.
- Dynamic policy reloading without restart: Deferred.

---

## Context & Research

### Relevant Code and Patterns

- `src/server/http.zig`: Contains `parseHttpRequestFast` (zero-allocation parser).
- `src/policy/engine.zig`: Contains current linear policy evaluation logic.
- `src/memory.zig`: `SecurityArena` for request-scoped allocations.

### Institutional Learnings

- Use `SecurityArena` for all per-request data to ensure zero-leak and $O(1)$ cleanup.
- Prioritize returning slices of the original read buffer over `std.mem.dupe`.
- Move parsing to `comptime` via `parseComptime` to eliminate runtime overhead.

---

## Key Technical Decisions

- **Trie-based Path Lookup**: Replace linear scan of policies with a Path Trie. Path matching is the most frequent operation; a Trie reduces complexity from $O(N \times L)$ to $O(L)$.
- **Comptime Structure Generation**: The Trie will be constructed at compile-time using `@embedFile` and `comptime` logic, resulting in a static, read-only structure in the binary.
- **Flat Array Storage**: The Trie nodes will be stored in a contiguous array to improve cache locality and avoid pointer chasing.

---

## Open Questions

### Resolved During Planning

- **How to handle wildcards in Trie?**: Use a special "wildcard" child node in the Trie that is checked if no exact match is found.

### Deferred to Implementation

- **Exact memory layout of the flattened Trie**: Will be determined by the `comptime` generator implementation.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Request Flow Optimization:**
`Buffer` $\rightarrow$ `parseHttpRequestFast` (Slices) $\rightarrow$ `PolicyTrie.lookup(path)` $\rightarrow$ `Decision`

**Trie Structure (Pseudo-code):**
```zig
const TrieNode = struct {
    children: [256]?*const TrieNode,
    policy_id: ?u32,
    is_wildcard: bool,
};
```

---

## Implementation Units

- [ ] U1. **Zero-Copy Parsing Audit**

**Goal:** Ensure no hidden allocations exist in the request path.
**Requirements:** R3.
**Dependencies:** None.
**Files:**
- Modify: `src/server/http.zig`
- Test: `src/server/http_test.zig`
**Approach:**
- Scan `handleCheckRequest` and `parseHttpRequestFast` for any calls to `allocator.alloc` or `std.mem.dupe`.
- Replace `std.fmt.bytesToHex` in the hot path with a static lookup table if it performs allocations.
**Test scenarios:**
- Happy path: Valid request returns slices pointing exactly to the input buffer.
- Error path: Invalid headers do not trigger leaked allocations.
**Verification:**
- Run tests with `std.testing.allocator` (GPA) and verify zero leaks.

- [ ] U2. **Trie-based Policy Engine**

**Goal:** Replace linear policy scan with a path-based Trie lookup.
**Requirements:** R4.
**Dependencies:** U1.
**Files:**
- Modify: `src/policy/engine.zig`
- Test: `src/policy/engine_test.zig`
**Approach:**
- Implement a `PathTrie` structure that stores policy IDs.
- Implement `lookup(path: []const u8)` that traverses the Trie and handles wildcard matching.
- Update `evaluate` to use the Trie result instead of a `for` loop.
**Test scenarios:**
- Happy path: Exact path match returns correct policy.
- Edge case: Path with trailing slash matches correctly.
- Edge case: Wildcard match returns the most specific policy.
- Error path: No match returns the default "deny" decision.
**Verification:**
- Verify correct policy decision for 100+ test cases.

- [ ] U3. **Comptime Decision Tree Generation**

**Goal:** Move Trie construction from runtime to compile-time.
**Requirements:** R4.
**Dependencies:** U2.
**Files:**
- Modify: `src/policy/engine.zig`
- Modify: `src/policy/parser.zig`
**Approach:**
- Use `comptime` block to parse the embedded policy JSON.
- Generate the `PathTrie` as a `const` static array at build-time.
- Ensure the runtime lookup uses this static structure.
**Test scenarios:**
- Integration: Build the project and verify the binary contains the pre-compiled Trie.
**Verification:**
- Startup time is reduced (no runtime policy parsing).

- [ ] U4. **Perfect Hash for Policy Attributes**

**Goal:** Implement $O(1)$ lookup for non-path attributes (e.g., agent\_id).
**Requirements:** R4.
**Dependencies:** U3.
**Files:**
- Modify: `src/policy/engine.zig`
**Approach:**
- For fixed attribute sets, use a compile-time perfect hash function to map attribute names to indices.
- Replace `StringHashMap` lookups with direct array indexing using the hash result.
**Test scenarios:**
- Happy path: Attribute lookup returns value in constant time.
**Verification:**
- Comparison of `evaluate` time with and without perfect hashing.

- [ ] U5. **Latency Benchmarking & Validation**

**Goal:** Verify sub-50µs P99 latency.
**Requirements:** R1, R2, R5.
**Dependencies:** U4.
**Files:**
- Create: `src/policy/benchmark.zig`
- Modify: `tools/loadtest.zig`
**Approach:**
- Implement a high-resolution timer benchmark that runs 1M evaluations.
- Measure P50, P90, and P99 latency.
- Run `loadtest.zig` to verify > 100K req/s throughput.
**Test scenarios:**
- Scaling: Measure latency for 1, 100, and 1000 policies.
- Worst-case: Measure latency for the deepest path in the Trie.
**Verification:**
- Benchmark output shows P99 < 50µs.

---

## System-Wide Impact

- **Interaction graph:** The `PolicyEngine` is a core dependency for `http.zig`. Changes to its interface may require updates in the request handler.
- **Error propagation:** Trie lookup failures must propagate as `error.PolicyNotFound` which maps to a 403 Forbidden response.
- **Unchanged invariants:** The "First-Match-Wins" semantics of the original policy engine must be preserved in the Trie implementation.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Trie implementation introduces bugs in wildcard matching | Extensive test suite with 100+ path combinations. |
| Comptime generation increases build times significantly | Use `@embedFile` and limit the complexity of the compile-time parser. |
| Perfect hash collisions for dynamic attributes | Only apply perfect hashing to static, known attribute keys. |

---

## Sources & References

- **Origin document:** [task_plan.md](../../task_plan.md)
- Related code: `src/server/http.zig`, `src/policy/engine.zig`
- PRD: `PRD.md`
