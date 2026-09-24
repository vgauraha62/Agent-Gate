# High-Level Design

## Proxy (Go, `proxy/`)

- `main.go:handleMessages`: license gate -> parse `/v1/messages` -> request-side tool check -> normalize -> forward (stream SSE filter or non-stream filter).
- `policy/client.go`: `POST /check` to agentgate, 5s timeout.
- `upstream/client.go`: forward + streaming tool filter.
- Logging: `METHOD PATH` per request; DEBUG body lines dump full payloads (privacy note: disable for shared logs).

## Agentgate (Zig, `src/`)

- `server/http.zig:handleRequestThread`: read -> parse (`parseHttpRequestFast`) -> route (`/health`, `/metrics`, `/denied-requests`, `/check`, admin).
- `handleCheckRequest`: build context -> `evaluateWithTimeout` -> allow JSON or deny JSON + tracker record.
- `policy/types.zig`: matchers — exact/wildcard agent + tool, substring command, prefix/substring path. First-match-wins (`engine.zig`).
- `denial_tracker.zig`: thread-safe ring, last 1000, served at `/denied-requests`.
- `metrics/prometheus.zig`: allowed/denied counters.
- `audit/logger.zig`: hash-chained ring (decisions only, no payload text).

## Policy model (`policies/ai-agent.json`)

Deny rules for destructive commands + sensitive paths, then allow rules, engine default-deny. Substring semantics: one pattern covers variants (the deletion prefix covers recursive forms; the directory-remove name covers API spellings). Full table: generated block in LLD.

## Deployment (`docker-compose.yml`)

proxy :8080, agentgate :8081/:9090, litellm :4000, license-server :4001. Volumes: config + policies read-only into agentgate; `agentgate_data` for API storage. Env selects upstream (`AGENTGATE_PROXY_ANTHROPIC_URL`).

## Failure modes

Policy engine timeout -> 504 deny. Engine unreachable -> proxy 403 policy-error. License invalid -> 402. No match -> deny.
