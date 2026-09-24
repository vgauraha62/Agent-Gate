# ADR-0002: Denial logs live in agentgate-1 only

## Context
Proxy duplicated every denial; two sources of truth.

## Decision
Removed `POLICY DENY` lines from proxy (`main.go`, `upstream/client.go`); agentgate-1 stdout + `/denied-requests` canonical.

## Consequences
Proxy logs stay quiet on denies; debugging uses agentgate-1 logs.

## Links
`src/server/http.zig`, `docs/CURRENT_WORKING.md`

## Date
2026-09-20
