# ADR-0001: Collapse redundant policy rules (58 -> 36)

## Context
Substring matchers made many rules overlap; two curl-flag rules broke legit CLI flags.

## Decision
Single `policies/ai-agent.json` (retired `src/policy/policies.json` duplicate); merged null-trunc/root/boot/etc groups; dropped evasion enumerations covered as substrings; dropped curl-flag rules and engine-redundant deny-default.

## Consequences
Smaller audit surface; tab-separated deletion prefix and bare binary paths are known gaps (see LLD).

## Links
`policies/ai-agent.json`, `docs/LLD.md`

## Date
2026-09-20
