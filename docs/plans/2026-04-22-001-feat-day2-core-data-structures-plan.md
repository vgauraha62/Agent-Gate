---
title: 'feat: Day 2 Core Data Structures & Memory Management'
type: feat
status: active
date: 2026-04-22
origin: PRD.md (Day 2 specification)
---

# Day 2: Core Data Structures & Memory Management

## Overview

Implement foundational memory-safe data structures for AgentGate sidecar. Three core components: custom arena allocator for request-scoped memory, zeroizing secret container for sensitive data, and agent context structure for authenticated sessions. All components must pass memory safety tests with zero leaks.

---

## Problem Frame

Zig requires manual memory management. Without proper abstractions:
- Memory leaks accumulate under load
- Secrets persist in memory after use (security vulnerability)
- Agent context data scattered across unrelated structures

Day 2 solves these with purpose-built, security-aware data structures.

---

## Requirements Trace

From PRD.md Day 2 specification:

- R1. Custom arena allocator in `src/memory.zig` with alloc/reset/zeroize/deinit
- R2. Zeroizing secret container in `src/secret.zig` with secure memory clearing
- R3. Agent context structure in `src/agent.zig` with ID, timestamp, permissions
- R4. Memory safety tests with >90% coverage

**Origin actors:** None (Day 2 is implementation-focused, no user actors defined)
**Origin flows:** None (infrastructure layer, no user flows)
**Origin acceptance examples:** PRD shows code examples for each structure

---

## Scope Boundaries

- Implementation of three Zig source files plus tests
- No HTTP server integration yet (Day 5)
- No JWT authentication yet (Day 3)
- No policy engine yet (Day 4)

### Deferred to Follow-Up Work

- Integration with HTTP request handler (Day 6)
- Arena allocator benchmarking (Day 11)
- Stress testing (Day 15)

---

## Context & Research

### Relevant Code and Patterns

- `src/main.zig` - existing test structure, uses `std.testing.allocator`
- `build.zig` - test executable setup via `b.addTest()`
- Zig 0.17.0-dev std.mem features: `std.mem.Allocator`, `std.heap.FixedBufferAllocator`

### Institutional Learnings

- None yet (Day 2 is first implementation after setup)

### External References

- Zig std.mem documentation for arena allocator patterns
- `std.crypto.mem.zeroize` for secure memory clearing
- `std.crypto.timing_safe_equal` for constant-time comparison

---

## Key Technical Decisions

- **Arena allocator uses FixedBufferAllocator wrapper**: Simpler than custom implementation, leverages std library testing. Wraps a fixed buffer with arena semantics.
- **Secret uses explicit zeroize before deinit**: Zig doesn't guarantee memory isn't copied; we zeroize in-place before freeing to minimize exposure window.
- **Agent ID stored as [32]u8 (SHA256 hash)**: Fixed-size array avoids allocation, matches JWT subject hash format from PRD.
- **Permissions as bitset union**: Compact representation, fast evaluation. Each permission is a flag in a u64 bitset.

---

## Open Questions

### Resolved During Planning

- None - PRD provides clear specifications

### Deferred to Implementation

- Exact capacity for SecurityArena buffer (PRD shows interface, not size)
- Permission enum variant names (PRD shows structure, not specific permissions)
- Test coverage percentage target (PRD says ">90%", exact number depends on implementation)

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
┌─────────────────────────────────────────────────────────────┐
│                    Memory Architecture                       │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │  SecurityArena   │  │  Secret          │                │
│  │  - fixed buffer  │  │  - allocated     │                │
│  │  - index tracker │  │  - zeroize on    │                │
│  │  - reset fn      │  │    deinit        │                │
│  └──────────────────┘  └──────────────────┘                │
│                                                              │
│  ┌──────────────────┐                                       │
│  │  Agent           │                                       │
│  │  - id: [32]u8    │                                       │
│  │  - timestamp     │                                       │
│  │  - permissions   │                                       │
│  └──────────────────┘                                       │
│                                                              │
│  Test Layer:                                                 │
│  - Arena alloc/free/reset cycles                            │
│  - Secret zeroize verification                              │
│  - Agent context lifecycle                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Units

- [ ] U1. **SecurityArena Allocator**

**Goal:** Custom arena allocator for request-scoped memory with reset capability

**Requirements:** R1

**Dependencies:** None

**Files:**
- Create: `src/memory.zig`
- Test: `src/memory_test.zig` (or inline tests in `memory.zig`)

**Approach:**
- Wrap `std.heap.FixedBufferAllocator` with arena semantics
- Expose `init(capacity)`, `alloc(size)`, `reset()`, `deinit()` interface per PRD
- Buffer allocated on heap via provided allocator
- Reset sets index back to zero without freeing

**Test scenarios:**
- Happy path: Multiple allocations succeed within capacity
- Edge case: Allocation exceeding capacity returns error
- Edge case: Reset allows reuse of full buffer
- Edge case: Zero-size allocation behavior
- Integration: Multiple alloc-reset cycles, verify no leaks

**Verification:**
- `zig build test` passes
- GPA (General Purpose Allocator) in test mode detects no leaks

---

- [ ] U2. **Zeroizing Secret Container**

**Goal:** Secure container for sensitive data that zeroes memory before deallocation

**Requirements:** R2

**Dependencies:** U1 (may use arena for some allocations)

**Files:**
- Create: `src/secret.zig`
- Test: `src/secret_test.zig`

**Approach:**
- Store bytes as `[]u8` with owning allocator
- `init(allocator, data)` copies data into fresh allocation
- `asBytes()` returns const slice for reading
- `zeroize()` overwrites with zeros via `std.crypto.mem.zeroize`
- `deinit()` calls zeroize then frees

**Test scenarios:**
- Happy path: Secret initialized with data, retrieved via asBytes
- Edge case: Empty secret (zero-length data)
- Security: After zeroize, memory verified as all zeros
- Security: After deinit, no references remain
- Integration: Secret used in arena, arena reset, secret still valid

**Verification:**
- Zeroize test passes (memory is zeros after call)
- No memory leaks under GPA

---

- [ ] U3. **Agent Context Structure**

**Goal:** Represent authenticated agent with ID, timestamp, and permissions

**Requirements:** R3

**Dependencies:** U2 (may contain Secret for sensitive fields)

**Files:**
- Create: `src/agent.zig`
- Test: `src/agent_test.zig`

**Approach:**
- `id: [32]u8` fixed array for SHA256 hash
- `authenticated_at: i128` Unix timestamp
- `permissions: PermissionSet` - u64 bitset or enum union
- `deinit()` for any allocated fields (permissions may be inline)

**PermissionSet design:**
```zig
pub const Permission = enum(u64) {
    read_users = 1 << 0,
    write_users = 1 << 1,
    read_admin = 1 << 2,
    write_admin = 1 << 3,
    // ... extend as needed
};

pub const PermissionSet = packed struct {
    flags: u64 = 0,
    
    pub fn has(self: PermissionSet, p: Permission) bool {
        return (self.flags & @intFromEnum(p)) != 0;
    }
    
    pub fn set(self: *PermissionSet, p: Permission) void {
        self.flags |= @intFromEnum(p);
    }
};
```

**Test scenarios:**
- Happy path: Agent created with valid ID, timestamp, permissions
- Edge case: Agent with no permissions (all flags zero)
- Edge case: Agent with all permissions (all flags set)
- Permission check: has() returns correct boolean
- Integration: Agent stored in arena, arena reset

**Verification:**
- Agent struct compiles with expected layout
- Permission bitset operations work correctly

---

- [ ] U4. **Memory Safety Test Suite**

**Goal:** Comprehensive tests verifying memory safety across all components

**Requirements:** R4

**Dependencies:** U1, U2, U3

**Files:**
- Modify: `src/memory_test.zig` (from U1)
- Modify: `src/secret_test.zig` (from U2)
- Modify: `src/agent_test.zig` (from U3)
- Create: `src/integration_test.zig` (new)

**Approach:**
- Use `std.testing.allocator` for leak detection
- Use `std.testing.GPA` for detailed leak reporting
- Test each component in isolation
- Test components together (integration)
- Aim for >90% line coverage

**Test scenarios:**

*Memory allocator tests:*
- Alloc then free, verify no leak
- Multiple allocs, reset, verify reuse
- Alloc beyond capacity returns error

*Secret tests:*
- Init, read, zeroize, deinit - verify zeros
- Multiple secrets, verify isolation

*Agent tests:*
- Create, use, deinit - no leak
- Permission operations correct

*Integration tests:*
- Arena holds multiple agents
- Secrets in arena, arena reset
- Full lifecycle: alloc -> use -> reset -> dealloc

**Verification:**
- All tests pass via `zig build test`
- GPA reports zero leaks
- Coverage report shows >90%

---

## System-Wide Impact

- **Interaction graph:** These components are foundational - all later days (auth, policy, audit, server) will import them
- **Error propagation:** Arena allocation failures should propagate as `error.OutOfMemory`; Secret/Agent init failures should clearly indicate cause
- **State lifecycle risks:** Arena reset invalidates all prior allocations - documentation must warn users
- **API surface parity:** None - these are internal components, not exposed externally yet

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Arena reset invalidates pointers | Document clearly; consider debug mode that poisons freed memory |
| Secret zeroize may be optimized away | Use `std.crypto.mem.zeroize` which has volatile semantics |
| Permission bitset size limits | Start with u64 (64 permissions); can extend to u128 if needed |
| Test coverage hard to measure | Use `zig build test --coverage` if available, or manual line counting |

---

## Documentation / Operational Notes

- Add doc comments to all public functions
- Include usage examples in doc comments
- Note security properties (zeroize, constant-time where applicable)

---

## Sources & References

- **Origin:** PRD.md Day 2 specification (lines 128-185)
- **Zig std.mem:** `std.heap.FixedBufferAllocator`, `std.mem.Allocator`
- **Zig std.crypto:** `std.crypto.mem.zeroize`
