# ADR-0003: /check-only IO dump with secret redaction

## Context
Needed headers+body visibility for gate debugging.

## Decision
`ENABLE_IO_DUMP` prints IN (method/path/redacted-headers/body) and OUT (decision/policy/response) to stderr; secrets masked.

## Consequences
Per-request stderr volume; flip off when done (rebuild).

## Links
`src/server/http.zig`, `docs/CURRENT_WORKING.md`

## Date
2026-09-20
