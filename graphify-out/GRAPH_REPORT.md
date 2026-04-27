# Graph Report - .  (2026-04-28)

## Corpus Check
- Corpus is ~16,474 words - fits in a single context window. You may not need a graph.

## Summary
- 108 nodes · 145 edges · 18 communities detected
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 20 edges (avg confidence: 0.82)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_JWT Implementation|JWT Implementation]]
- [[_COMMUNITY_Policy Engine Design|Policy Engine Design]]
- [[_COMMUNITY_Agent Permission System|Agent Permission System]]
- [[_COMMUNITY_Architecture & Performance|Architecture & Performance]]
- [[_COMMUNITY_Threat Model & Security|Threat Model & Security]]
- [[_COMMUNITY_Main Entry Point|Main Entry Point]]
- [[_COMMUNITY_Memory Arena|Memory Arena]]
- [[_COMMUNITY_Project Planning|Project Planning]]
- [[_COMMUNITY_JWT Design|JWT Design]]
- [[_COMMUNITY_Build System|Build System]]
- [[_COMMUNITY_Integration Tests|Integration Tests]]
- [[_COMMUNITY_mTLS Auth|mTLS Auth]]
- [[_COMMUNITY_Policy Parser|Policy Parser]]
- [[_COMMUNITY_Policy Engine Impl|Policy Engine Impl]]
- [[_COMMUNITY_HTTP Server|HTTP Server]]
- [[_COMMUNITY_Prometheus Metrics|Prometheus Metrics]]
- [[_COMMUNITY_Audit Logger|Audit Logger]]
- [[_COMMUNITY_README|README]]

## God Nodes (most connected - your core abstractions)
1. `Day 4 Policy Engine Foundation Plan` - 14 edges
2. `SecurityArena` - 11 edges
3. `Architecture Document` - 10 edges
4. `Day 3 JWT Authentication Plan` - 10 edges
5. `Threat Model` - 9 edges
6. `Agent` - 7 edges
7. `Day 2 Core Data Structures Plan` - 7 edges
8. `Agent Context Structure` - 7 edges
9. `PermissionSet` - 6 edges
10. `PRD Main Project Document` - 6 edges

## Surprising Connections (you probably didn't know these)
- `Payload` --conceptually_related_to--> `Agent Context Structure`  [INFERRED]
  src/auth/jwt.zig → docs/plans/2026-04-22-001-feat-day2-core-data-structures-plan.md
- `Day 3 JWT Authentication Plan` --implements--> `Header`  [EXTRACTED]
  docs/plans/2026-04-22-002-feat-day3-jwt-authentication-plan.md → src/auth/jwt.zig
- `JWT Parser and Verifier` --shares_data_with--> `Header`  [EXTRACTED]
  docs/plans/2026-04-22-002-feat-day3-jwt-authentication-plan.md → src/auth/jwt.zig
- `Day 3 JWT Authentication Plan` --implements--> `Payload`  [EXTRACTED]
  docs/plans/2026-04-22-002-feat-day3-jwt-authentication-plan.md → src/auth/jwt.zig
- `JWT Parser and Verifier` --shares_data_with--> `Payload`  [EXTRACTED]
  docs/plans/2026-04-22-002-feat-day3-jwt-authentication-plan.md → src/auth/jwt.zig

## Hyperedges (group relationships)
- **Day 2 Memory Safety Components** — security_arena, secret_container, agent_context, permission_set [EXTRACTED 0.95]
- **Day 3 JWT Verification Flow** — jwt_parser, jwt_header, jwt_payload, hmac_verification, constant_time_compare [EXTRACTED 0.95]
- **Day 4 Policy Evaluation Flow** — policy_parser, policy_engine, policy_struct, effect_enum, condition_union, request_context, wildcard_matching, compile_time_policy_gen [EXTRACTED 0.90]

## Communities

### Community 0 - "JWT Implementation"
Cohesion: 0.19
Nodes (8): base64UrlDecode(), HashAlgorithm, JWT, parseHeader(), parsePayload(), secureCompare(), verifyExpiration(), verifySignature()

### Community 1 - "Policy Engine Design"
Cohesion: 0.29
Nodes (15): Agent Context Structure, Condition Union, Day 2 Core Data Structures Plan, Day 4 Policy Engine Foundation Plan, Effect Enum, Day 2 Implementation Findings, Policy Benchmark <100µs for 1000 policies, PermissionSet Bitset (+7 more)

### Community 2 - "Agent Permission System"
Cohesion: 0.16
Nodes (3): Agent, Permission, PermissionSet

### Community 3 - "Architecture & Performance"
Cohesion: 0.18
Nodes (13): Architecture Document, Audit Logger with Merkle Tree, Auth Engine, Data Flow Auth→Policy→Audit, HTTP Server, Prometheus Metrics, mTLS Authentication, Binary Size Target <5MB (+5 more)

### Community 4 - "Threat Model & Security"
Cohesion: 0.2
Nodes (10): Agent Identities Asset, JWT Secrets Asset, Policy Decisions Asset, Compile-Time Policy Generation, DoS Attack Threat, Memory Disclosure Threat, Threat Model, Policy Bypass Threat (+2 more)

### Community 5 - "Main Entry Point"
Cohesion: 0.25
Nodes (3): main(), testOne(), printAnotherMessage()

### Community 6 - "Memory Arena"
Cohesion: 0.25
Nodes (1): SecurityArena

### Community 7 - "Project Planning"
Cohesion: 0.25
Nodes (8): Day 1 Project Setup, Day 2 Core Data Structures, Day 3 Authentication Engine, Day 4 Policy Engine Foundation, Findings Deprecated Zig API, PRD Main Project Document, Progress Log, Task Plan Day 1-7

### Community 8 - "JWT Design"
Cohesion: 0.6
Nodes (6): Constant-Time Comparison, Day 3 JWT Authentication Plan, HMAC Signature Verification, Header, JWT Parser and Verifier, Payload

### Community 9 - "Build System"
Cohesion: 1.0
Nodes (0): 

### Community 10 - "Integration Tests"
Cohesion: 1.0
Nodes (0): 

### Community 11 - "mTLS Auth"
Cohesion: 1.0
Nodes (0): 

### Community 12 - "Policy Parser"
Cohesion: 1.0
Nodes (0): 

### Community 13 - "Policy Engine Impl"
Cohesion: 1.0
Nodes (0): 

### Community 14 - "HTTP Server"
Cohesion: 1.0
Nodes (0): 

### Community 15 - "Prometheus Metrics"
Cohesion: 1.0
Nodes (0): 

### Community 16 - "Audit Logger"
Cohesion: 1.0
Nodes (0): 

### Community 17 - "README"
Cohesion: 1.0
Nodes (1): README

## Knowledge Gaps
- **20 isolated node(s):** `Permission`, `HashAlgorithm`, `Progress Log`, `README`, `Findings Deprecated Zig API` (+15 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Build System`** (2 nodes): `build()`, `build.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Integration Tests`** (1 nodes): `integration_test.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `mTLS Auth`** (1 nodes): `mTLS.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Policy Parser`** (1 nodes): `parser.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Policy Engine Impl`** (1 nodes): `engine.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `HTTP Server`** (1 nodes): `http.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Prometheus Metrics`** (1 nodes): `prometheus.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Audit Logger`** (1 nodes): `logger.zig`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `README`** (1 nodes): `README`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `SecurityArena` connect `Memory Arena` to `JWT Implementation`, `Main Entry Point`?**
  _High betweenness centrality (0.291) - this node is a cross-community bridge._
- **Why does `Day 3 JWT Authentication Plan` connect `JWT Design` to `Policy Engine Design`, `Project Planning`?**
  _High betweenness centrality (0.267) - this node is a cross-community bridge._
- **What connects `Permission`, `HashAlgorithm`, `Progress Log` to the rest of the system?**
  _20 weakly-connected nodes found - possible documentation gaps or missing edges._