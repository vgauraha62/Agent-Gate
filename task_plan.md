# Task Plan: Day 12 Testing & Fuzzing

## Goal
Achieve >85% test coverage and establish fuzzing harness for JWT and Policy parsers.

## Implementation Units

- [x] U0a. **Wire orphaned test files**: `src/integration_test.zig` → `zig build test-security`, `src/audit/integration_test.zig` → `zig build test-audit`. Fixed compilation errors (callconv, file paths, pointless discards). Both added to `zig build test-all`.
- [x] U0b. **Scaffold fuzzing infrastructure**: Created `src/fuzz_jwt.zig`, `src/fuzz_policy.zig`, build steps in `build.zig`, seed corpus dirs at `fuzz/corpus/jwt/` and `fuzz/corpus/policy/`.
- [x] U0c. **Coverage tooling research**: No kcov/grcov/llvm-profdata available in environment. Zig 0.15 has no built-in coverage flags. Performed manual code-path gap analysis instead.
- [x] HMAC **hotfix**: Fixed stack buffer overflow in `hmacSha256`/`hmacSha384`/`hmacSha512` — replaced fixed `[256]u8` stack buffers with `page_allocator` dynamic allocation. All call sites updated with `try`.
- [x] U1. **Integration Tests: Valid Path**: 10 test cases in `src/integration_test.zig` covering valid allow decision, multiple permissions, audit logging on allow.
- [x] U2. **Integration Tests: Error Paths**: Tests for expired JWT, tampered signature, wrong secret, denied path, default deny, missing header, malformed token, oversized payload.
- [x] U3. **JWT Fuzzing Target**: Created `src/fuzz_jwt.zig` (64 lines). Fixed `page_allocator` leak in `parseHeader`/`parsePayload` by threading `allocator: std.mem.Allocator` parameter through both functions, so arena allocation is used instead of leaking. Also fixed ordering bug (allocating `sub` before validating `exp`). Populated seed corpus with 3 entries.
- [x] U4. **Policy Fuzzing Target**: Created `src/fuzz_policy.zig` (56 lines). Populated seed corpus with 3 entries.
- [x] U5. **Coverage Gap Analysis**: Manual audit of all 13 source files (see `findings.md`). Found 3 critical, 4 high, 6 medium uncovered paths.

## Verification
- [x] `zig build test-all` passes — 706 tests across 13 steps, 0 leaked.
- [x] Fuzzing targets compile and run standalone (`echo '...' | fuzz_jwt` → OK).
- [x] Coverage gap analysis documented (manual — no kcov/grcov available in environment).
