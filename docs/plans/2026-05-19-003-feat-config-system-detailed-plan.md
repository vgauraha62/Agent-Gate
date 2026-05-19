---
title: feat: Implementation of Comprehensive Configuration System
type: feat
status: active
date: 2026-05-19
origin: PRD.md
---

# Configuration System Implementation Plan

## Overview
Implement a tiered configuration system for AgentGate that allows settings to be defined in a JSON file and overridden by environment variables. This replaces the current "deconstructed injection" pattern with a structured `Config` object passed to system components.

---

## Problem Frame
Currently, configuration is handled by passing individual primitives (ports, secrets, flags) from `main.zig` to component initializers. This is brittle, hard to extend, and lacks a standardized way to override settings in containerized environments (e.g., Kubernetes/Docker) without modifying source or using complex flag sets.

---

## Requirements Trace
- R1. **Hierarchical Loading**: Settings must follow priority: `Environment Variables` $\rightarrow$ `JSON File` $\rightarrow$ `Defaults` (see origin: PRD.md Day 10).
- R2. **Generic Overrides**: Any configuration field must be overridable via `AGENTGATE_[FIELD_NAME]` environment variables using reflection to avoid boilerplate.
- R3. **Type Safety**: All overrides must be correctly cast to the target type (u16, u32, bool, etc.).
- R4. **Validation**: The system must validate the final resolved configuration before the server starts (e.g., check secret lengths, timeout consistency).
- R5. **Clean Injection**: Components (`Server`, `AuditLogger`) should receive configuration objects rather than lists of primitives.

---

## Scope Boundaries
- **Included**: Generic reflection-based env overrides, JSON parsing, component signature updates, and tiered priority testing.
- **Non-goals**:
    - Support for YAML or TOML.
    - Dynamic configuration reloading (SIGHUP) without process restart.
    - Encrypted secrets in the JSON file (secrets should be provided via env vars or mounted files).

---

## Context & Research

### Relevant Code and Patterns
- `src/config.zig`: Already contains the `Config` struct hierarchy and basic `validate()` logic.
- `src/main.zig`: The current entry point that manually extracts fields and passes them to `Server.init`.
- `src/server/http.zig`: The `Server.init` function currently has a long list of primitive arguments.
- `src/audit/logger.zig`: `AuditLogger.init` currently uses hardcoded buffer sizes.

### Institutional Learnings
- Use `std.json.parseFromSlice` with `.ignore_unknown_fields = true` to allow forwards-compatibility of config files.
- Use `std.process.getEnvVarOwned` for environment retrieval, ensuring the resulting memory is managed.

---

## Key Technical Decisions
- **Reflection Strategy**: Use `@typeInfo(T).Struct.fields` in a generic function `applyOverrides(T, *T, allocator)` to automatically map environment variables to struct members. This eliminates the need to manually add each new config field to the override logic.
- **Injection Pattern**: Transition from "Primitive Injection" to "Object Injection". The `Server` will receive the root `Config` object, while smaller components (like `AuditLogger`) will receive their specific sub-config (e.g., `AuditConfig`).
- **Memory Management**: Environment variable strings will be allocated into the `Config` object's lifecycle, with a corresponding `deinit()` to clean up all owned strings.

---

## Implementation Units

- [ ] U1. **Generic Reflection-based Env Overrides**

**Goal:** Implement a system that automatically overrides struct fields using environment variables.

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Modify: `src/config.zig`

**Approach:**
- Create a helper `parseEnvValue(type, value_str) anyerror!T` to handle conversion from string to `u16`, `u32`, `bool`, and `[]const u8`.
- Implement `applyOverrides(comptime T: type, target: anytype, allocator: std.mem.Allocator) void`.
- Iterate over `@typeInfo(T).Struct.fields`.
- Construct env var name: `"AGENTGATE_" ++ std.ascii.upperString(field.name)`.
- If variable exists, parse and update the `target` field.

**Test scenarios:**
- Happy path: `AGENTGATE_PORT=9000` correctly updates `ServerConfig.port`.
- Happy path: `AGENTGATE_ENABLE_TLS=true` correctly updates `ServerConfig.enable_tls`.
- Error path: `AGENTGATE_PORT=not-a-number` is handled gracefully (log warning, keep default).
- Edge case: Field name with underscores is correctly uppercased.

**Verification:**
- `tests/config_test.zig` verifies that `Symmetry` is maintained between env var names and struct fields.

---

- [ ] U2. **JSON Loading and Tiered Integration**

**Goal:** Implement the logic to load from file and then apply overrides.

**Requirements:** R1

**Dependencies:** U1

**Files:**
- Modify: `src/config.zig`

**Approach:**
- Implement `Config.load(path: []const u8, allocator: std.mem.Allocator) !Config`.
- Sequence: 
    1. Initialize `Config.default()`.
    2. If file exists at `path`, use `std.json.parseFromSlice` to update the config object.
    3. Call `applyEnvOverrides()` to apply final overrides over the file settings.
- Ensure all owned strings from the JSON parser are correctly transferred to the final `Config` object.

**Test scenarios:**
- Happy path: Valid JSON file is loaded and values are applied.
- Priority test: JSON file says port 8080, Env var says 9000 $\rightarrow$ final port is 9000.
- Priority test: No JSON file, Env var says 9000 $\rightarrow$ final port is 9000.
- Error path: Malformed JSON file returns `ConfigError.ParseError`.

**Verification:**
- Unit tests in `tests/config_test.zig` prove the priority chain: `Env > File > Default`.

---

- [ ] U3. **Component Signature Refactor**

**Goal:** Update components to accept configuration objects instead of primitives.

**Requirements:** R5

**Dependencies:** U1, U2

**Files:**
- Modify: `src/server/http.zig` (`Server.init`)
- Modify: `src/audit/logger.zig` (`AuditLogger.init`)

**Approach:**
- Change `Server.init` signature from `(allocator, port, logger, policies, ...)` to `(allocator, config: *const Config, logger, policies)`.
- Update `Server` internal field usage to reference `config.server.port` etc.
- Update `AuditLogger.init` to accept `*const AuditConfig`, using `config.buffer_size` instead of the hardcoded constant.

**Test scenarios:**
- Integration: Server starts and binds to the port specified in the passed `Config` object.
- Integration: `AuditLogger` allocates buffer based on `AuditConfig.buffer_size`.

**Verification:**
- Project compiles and `zig build test` passes.

---

- [ ] U4. **Main Entry Point Wiring**

**Goal:** Wire the configuration lifecycle into the application startup.

**Requirements:** R4

**Dependencies:** U3

**Files:**
- Modify: `src/main.zig`

**Approach:**
- Update `main()` logic:
    1. Parse command-line arguments for `--config` path.
    2. Call `Config.load(path, allocator)`.
    3. Call `config.validate()`.
    4. Pass `&config` to `Server.init` and `AuditLogger.init`.
    5. Ensure `defer config.deinit()` is called at the end of `main`.

**Test scenarios:**
- Happy path: Server starts with `--config config.json`.
- Error path: Server fails to start with a clear error if `config.validate()` fails (e.g., secret too short).

**Verification:**
- Binary starts and logs "Loaded configuration from [path]".

---

- [ ] U5. **Full System Validation**

**Goal:** End-to-end verification of the configuration hierarchy.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** U4

**Files:**
- Create: `tests/config_integration_test.zig`

**Approach:**
- Create an integration test that:
    1. Writes a temporary JSON config file.
    2. Sets a specific environment variable.
    3. Initializes `Config.load()` and verifies the resulting object.
    4. Verifies that the server binds to the expected port based on the hierarchy.

**Test scenarios:**
- Integration: Full chain (Default $\rightarrow$ File $\rightarrow$ Env) produces correct final object.
- Integration: Invalid config file leads to immediate process exit with error.

**Verification:**
- All tests in `tests/config_integration_test.zig` pass.

---

## System-Wide Impact

- **Interaction graph:** `main.zig` now owns the `Config` object and distributes it as a read-only pointer to components. This centralizes all settings management.
- **Error propagation:** Configuration errors (Parse, Validation) now happen at the very beginning of the process, preventing "half-started" servers.
- **State lifecycle risks:** All strings loaded from JSON or Env are owned by the `Config` object. `config.deinit()` must be called to avoid memory leaks.
- **Unchanged invariants:** The actual logic of the HTTP server, Auth engine, and Policy engine remains identical; only how they *receive* their settings changes.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Memory leaks from env strings | Use `std.mem.Allocator` consistently in `applyEnvOverrides` and a single `deinit` call in `main`. |
| Reflection performance | `@typeInfo` is used during startup only; there is zero runtime overhead during request processing. |
| Type mismatch in env vars | Implement strict parsing in `parseEnvValue` and log a warning/fallback to default on failure. |

---

## Sources & References
- **Origin document:** [PRD.md](PRD.md)
- Related code: `src/config.zig`, `src/main.zig`, `src/server/http.zig`, `src/audit/logger.zig`
