---
title: Day 4 - Policy Engine Foundation
type: feat
status: active
date: 2026-04-23
origin: docs/brainstorms/agent-gate-prd.md
---

# Day 4 - Policy Engine Foundation

## Overview

Implement the policy engine that evaluates agent requests against JSON-defined policies. This includes:
- JSON policy language parser
- Runtime policy evaluation with wildcard matching
- Compile-time policy generation for performance
- Benchmark harness targeting <100µs for 1000 policies

## Problem Frame

Agents need fast, deterministic allow/deny decisions based on:
- Agent identity
- Request path (with wildcard support)
- HTTP method
- Custom conditions

Policies must evaluate quickly (<100µs for 1000 policies) to meet the <50µs P99 latency target.

## Requirements Trace

- R1. JSON policy language design (version, policies array) - PRD.md line 241-265
- R2. Policy struct: id, effect, conditions - PRD.md line 269-275
- R3. Effect enum: allow, deny - PRD.md line 277
- R4. Condition union: agent_id, path, method, custom - PRD.md line 278-283
- R5. Policy evaluator with RequestContext - PRD.md line 274
- R6. Compile-time policy generation via comptime - PRD.md line 287-296
- R7. Policy evaluation benchmark (<100µs for 1000 policies) - PRD.md line 299-301

## Scope Boundaries

- Runtime JSON parsing only - no YAML or other formats
- Wildcard patterns: exact match, prefix match (`/api/users/*`), match-all (`*`)
- No custom conditions implementation in this phase (deferred)
- Single policy file at compile time - no hot reload
- First-match-wins evaluation strategy

### Deferred to Separate Tasks

- Custom conditions (Day 4+ extension)
- Hot-reload of policies at runtime
- Policy caching layer
- mTLS-based agent identity (Day 9)

## Context & Research

### Relevant Code and Patterns

- `src/auth/jwt.zig` - JSON parsing pattern with `std.json.parseFromSlice`
- `src/secret.zig` - Zeroizing secret container for policy storage
- `src/memory.zig` - SecurityArena for request-scoped allocations
- `src/agent.zig` - Agent context with PermissionSet (agent_id as [32]u8)

### Institutional Learnings

None yet - Day 4 is first policy engine work.

### External References

- Zig `std.json` documentation for parsing patterns
- Zig `comptime` and `@embedFile` for compile-time evaluation

## Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| First-match-wins evaluation | Simplest strategy, deterministic, matches PRD examples |
| Wildcard at end only (`/api/*`) | Simpler implementation, covers 90% of use cases |
| Separate parser and engine modules | Clean separation: parser reads JSON, engine evaluates |
| Arena-based runtime parsing | Reuse Day 2 SecurityArena, zero leaks |
| Compile-time policy generation | Pre-compute decision tree for performance |

## Open Questions

### Resolved During Planning

- Q: How to handle multiple methods in policy? → A: Array of strings, match any
- Q: What happens if no policy matches? → A: Default deny

### Deferred to Implementation

- Exact benchmark iteration count for stable measurements
- Whether to use std.json.Value or typed parsing for conditions

## Output Structure

```
src/policy/
├── parser.zig          # JSON policy parser
├── engine.zig          # Policy evaluation engine
├── types.zig           # Shared types (Policy, Effect, Condition)
├── wildcard.zig        # Wildcard matching utilities
├── benchmark.zig       # Performance benchmarks
└── policies.json       # Example policy file
```

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

### Policy Evaluation Flow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────────┐
│  Request    │────▶│  Parse JSON  │────▶│  Evaluate   │────▶│  Allow/Deny │
│  Context    │     │  → Policy[]  │     │  Conditions │     │  Decision   │
└─────────────┘     └──────────────┘     └─────────────┘     └─────────────┘
```

### Compile-Time Generation

```zig
comptime {
    const json = @embedFile("policies.json");
    const policies = parsePoliciesComptime(json);
    const decision_tree = buildDecisionTree(policies);
    // Generate optimized evaluator type
}
```

## Implementation Units

- [ ] **Unit 1: Policy Types and Data Structures**

**Goal:** Define core policy types (Policy, Effect, Condition, RequestContext)

**Requirements:** R2, R3, R4, R5

**Dependencies:** None (foundational)

**Files:**
- Create: `src/policy/types.zig`
- Test: `src/policy/types_test.zig` (inline tests in types.zig)

**Approach:**
- Define `Effect` enum (allow, deny)
- Define `Condition` union with agent_id, path, method variants
- Define `Policy` struct with id, effect, conditions
- Define `RequestContext` struct for evaluation input
- Define `Method` enum for HTTP methods

**Patterns to follow:**
- Use `[]const u8` for string slices (no ownership)
- Use `?` for optional fields
- Follow `src/agent.zig` struct patterns

**Test scenarios:**
- Happy path: Create valid Policy struct
- Edge case: Empty conditions array
- Edge case: Wildcard agent_id (`*`)
- Edge case: Multiple methods in condition

**Verification:**
- `zig build test` passes for types module
- All struct definitions compile

---

- [ ] **Unit 2: Wildcard Matching Utilities**

**Goal:** Implement wildcard pattern matching for paths and agent_ids

**Requirements:** R4 (path/agent_id conditions)

**Dependencies:** Unit 1 (types)

**Files:**
- Create: `src/policy/wildcard.zig`
- Test: inline in wildcard.zig

**Approach:**
- `matchPattern(pattern: []const u8, value: []const u8) bool`
- Support: exact match, prefix match (`/api/*`), match-all (`*`)
- Use `std.mem.startsWith` for prefix matching

**Patterns to follow:**
- Use `std.mem.eql` for exact comparison
- Follow Zig stdlib pattern matching conventions

**Test scenarios:**
- Happy path: Exact match returns true
- Happy path: Prefix match `/api/users/*` matches `/api/users/123`
- Edge case: Wildcard alone (`*`) matches everything
- Edge case: Prefix mismatch returns false
- Error path: Empty pattern handling

**Verification:**
- All wildcard tests pass
- No allocations in match function

---

- [ ] **Unit 3: JSON Policy Parser**

**Goal:** Parse JSON policy files into Policy structs

**Requirements:** R1, R2

**Dependencies:** Unit 1 (types), Unit 2 (wildcard)

**Files:**
- Modify: `src/policy/parser.zig`
- Create: `src/policy/policies.json` (example policies)
- Test: inline in parser.zig

**Approach:**
- Use `std.json.parseFromSlice` for parsing
- Parse policy array from JSON object
- Handle optional fields (aud, extra claims)
- Use arena allocator for string allocations

**Patterns to follow:**
- Follow `src/auth/jwt.zig` JSON parsing pattern
- Use `std.json.Value` for flexible parsing
- Deinit parsed JSON after extraction

**Test scenarios:**
- Happy path: Parse valid policy JSON
- Happy path: Parse multiple policies
- Edge case: Empty policies array
- Error path: Malformed JSON returns error
- Error path: Missing required fields (id, effect) returns error
- Error path: Invalid effect value returns error

**Verification:**
- Parser handles PRD example JSON correctly
- Memory leak test with GPA shows zero leaks

---

- [ ] **Unit 4: Policy Evaluation Engine**

**Goal:** Evaluate requests against policy list with first-match-wins

**Requirements:** R5

**Dependencies:** Unit 1 (types), Unit 2 (wildcard), Unit 3 (parser)

**Files:**
- Modify: `src/policy/engine.zig`
- Test: inline in engine.zig

**Approach:**
- `evaluate(policies: []Policy, ctx: RequestContext) Effect`
- Iterate policies in order
- For each policy, check all conditions
- First match wins, return effect
- No match = default deny

**Patterns to follow:**
- Follow `src/auth/jwt.zig` evaluate pattern
- Use const references, no allocations in hot path

**Test scenarios:**
- Happy path: Allow policy matches, returns allow
- Happy path: Deny policy matches, returns deny
- Edge case: No policy matches, returns deny (default)
- Edge case: Wildcard agent_id matches any agent
- Edge case: Multiple conditions AND together
- Integration: Full request context evaluation

**Verification:**
- All evaluation tests pass
- Evaluation function has zero allocations

---

- [ ] **Unit 5: Compile-Time Policy Generation**

**Goal:** Generate optimized policy evaluator at compile time

**Requirements:** R6

**Dependencies:** Unit 4 (engine)

**Files:**
- Modify: `src/policy/engine.zig` (add comptime function)
- Create: `src/policy/policies.example.json`

**Approach:**
- `pub fn PolicySet(comptime policies_file: []const u8) type`
- Use `@embedFile` to read JSON at compile time
- Parse JSON at compile time
- Generate optimized decision tree type
- Return comptime evaluator

**Patterns to follow:**
- Follow Zig comptime patterns from stdlib
- Use `comptime var` for mutable compile-time state

**Test scenarios:**
- Happy path: Compile with valid policy file
- Error path: Compile fails with invalid JSON
- Integration: Runtime evaluation uses comptime policies

**Verification:**
- Code compiles with embedded policies
- Compile-time parsing completes without errors

---

- [ ] **Unit 6: Performance Benchmarks**

**Goal:** Measure policy evaluation performance, target <100µs for 1000 policies

**Requirements:** R7

**Dependencies:** Units 1-5

**Files:**
- Create: `src/policy/benchmark.zig`

**Approach:**
- Use `std.time.nanoseconds` for timing
- Create 1000 policies for benchmark
- Measure P50, P99 latency
- Report results in structured format

**Patterns to follow:**
- Follow benchmark patterns from other Zig projects
- Use warmup iterations before measuring

**Test scenarios:**
- Benchmark runs without errors
- Results are reproducible across runs

**Verification:**
- Benchmark completes in under 5 seconds
- P99 latency <100µs for 1000 policies

## System-Wide Impact

- **Interaction graph:** Policy engine called from main request handler (Day 5-6)
- **Error propagation:** Parse errors → 400, Evaluation errors → 500, Deny → 403
- **State lifecycle risks:** None - policies are immutable after load
- **API surface parity:** None - internal engine only
- **Integration coverage:** Will integrate with JWT auth (Day 3) for agent_id

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| JSON parsing too slow | Low | Medium | Use comptime parsing, benchmark early |
| Wildcard matching edge cases | Medium | Low | Comprehensive tests for *, prefix, exact |
| Compile-time parsing complexity | Medium | Medium | Start simple, optimize if needed |
| Memory leaks from arena | Low | High | GPA tests, follow Day 2 patterns |

## Documentation / Operational Notes

- Policy file format documented in `src/policy/policies.json` comments
- First-match-wins behavior must be documented for users
- Default deny must be explicit in documentation

## Sources & References

- **Origin document:** [PRD.md](../PRD.md) lines 238-301
- Related code: `src/auth/jwt.zig`, `src/memory.zig`, `src/agent.zig`
- External docs: Zig `std.json`, `comptime`, `@embedFile`
