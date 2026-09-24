# AgentGate

Policy gate for AI-agent tool calls. AI clients (OpenCode / Claude Code) talk to a
Go proxy; every tool invocation is checked against a Zig policy engine before it
reaches the model upstream. Deny-by-default, denial audit, Prometheus metrics.

```
OpenCode / Claude Code
        │  POST /v1/messages (Anthropic API)
        ▼
┌──────────────┐  POST /check   ┌───────────────┐
│ Proxy   :8080 │──────────────▶│ AgentGate     │
│ (Go)          │◀ allow / deny │ (Zig)   :8081 │
└──────┬───────┘               └───────────────┘
       │ allowed only                ▲ denial ring (1000) + audit log
       ▼                             │ GET /denied-requests, /metrics :9090
┌──────────────┐               ┌───────────────┐
│ LiteLLM :4000 │  translate    │ License srv   │
│ Anthropic↔OA  │  + route      │ (Go)    :4001 │
└──────┬───────┘               └───────────────┘
       ▼
Upstream model (Zen / Anthropic / Ollama)
```

## Services (`docker-compose.yml`)

| container | role | ports |
|---|---|---|
| proxy | Go proxy, license gate, tool extraction, SSE filter | 8080 |
| agentgate | Zig policy engine | 8081 (API), 9090 (metrics) |
| litellm | format translation + upstream routing | 4000 |
| license-server | RSA-signed JWT license issue/verify | 4001 |

## Quick start

```bash
cp .env.example .env && chmod 600 .env   # fill LICENSE_KEY, AGENTGATE_JWT_SECRET, OPENCODE_API_KEY
docker compose up -d --build

curl http://localhost:8081/health   # agentgate
curl http://localhost:8080/health   # proxy
curl http://localhost:4000/health   # litellm
```

Point OpenCode at the proxy (`~/.config/opencode/opencode.json`):

```json
{
  "model": "agentgate/deepseek-v4-flash-free",
  "provider": {
    "agentgate": {
      "options": { "baseURL": "http://localhost:8080", "apiKey": "test-key" }
    }
  }
}
```

Test the chat path:

```bash
curl -X POST http://localhost:8080/v1/messages \
  -H 'Content-Type: application/json' -H 'x-api-key: test-key' \
  -d '{"model":"deepseek-v4-flash-free","max_tokens":50,
       "messages":[{"role":"user","content":"Hello"}]}'
```

Air-gapped / portable bundle: see [`agent-gate-portable/`](agent-gate-portable/) and its
[README](agent-gate-portable/README.md) (`setup.sh` bootstraps a new machine).

## API

| method | url | purpose |
|---|---|---|
| POST | `localhost:8080/v1/messages` | chat path (proxy → policy → litellm) |
| POST | `localhost:8081/check` | raw policy decision (allow/deny JSON) |
| GET | `localhost:8081/denied-requests?limit=20` | denial audit ring |
| GET | `localhost:9090/metrics` | Prometheus counters |
| GET | `localhost:8080/health` | proxy health |

Observe denials live: `docker logs agent-gate-agentgate-1 | grep "IO IN"` (headers+body)
and `grep "IO OUT"` (decision). Gated by `ENABLE_IO_DUMP` in `src/server/http.zig`;
secrets are redacted from dumps.

## Policy model

Runtime file: `policies/ai-agent.json` (36 rules, mounted read-only into agentgate).
First-match-wins; no match → deny. Destructive-command deny rules + sensitive-path
deny rules first, then workspace allow rules. Matchers: exact/wildcard tool and agent,
substring command, prefix/substring path (see `src/policy/types.zig`).

Regenerate the policy/endpoint tables in the living docs after editing rules:

```bash
python3 tools/gen-docs.py          # rewrite generated blocks
python3 tools/gen-docs.py --check  # CI drift check
```

## Configuration

`.env` (never committed — see `.env.example`): `LICENSE_KEY`, `ADMIN_API_KEY`,
`AGENTGATE_JWT_SECRET`, `OPENCODE_API_KEY`, plus mode files `.env.opencode` /
`.env.claude` selecting upstream (`AGENTGATE_PROXY_ANTHROPIC_URL`).
Switch modes: `./switch.sh opencode|claude`, then `docker compose up -d --build`.
AgentGate engine config: `config.json` (server/policy/timeouts/auth/tls).
LiteLLM routing: `litellm-config.yaml`.

## Develop

Requires Zig 0.15.2 (see `.zig-version`), Go 1.22+, Docker.

```bash
zig build test-all   # unit + e2e + config + security + audit + gap suites
zig build run        # run agentgate locally
docker compose logs -f proxy | head -50
```

Repo layout: `src/` (Zig engine: `server/http.zig`, `policy/`, `auth/`, `audit/`,
`metrics/`), `proxy/` (Go), `license-server/` (Go + SQLite), `policies/`,
`scripts/` (certs, license seed, mtls/proxy tests), `tools/` (`gen-docs.py`,
`loadtest.zig`), `docs/`, `agent-gate-portable/` (release snapshot bundle).

## Docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — canonical system overview
- [`docs/HLD.md`](docs/HLD.md) / [`docs/LLD.md`](docs/LLD.md) — high/low-level design
- [`docs/CURRENT_WORKING.md`](docs/CURRENT_WORKING.md) — live topology, endpoints, policy table
- [`docs/saas/`](docs/saas/) — full SaaS/deployment guide (13 parts)
- [`docs/adr/`](docs/adr/) — policy collapse, denial-log, IO-dump decisions

## Security notes

- Never commit `.env*`, `config.json`, `keys/`, `certs/`, `*.pem`/`*.key`/`*.p12`
  (enforced by `.gitignore`). `proxy/license/public.pem` is the only committed key,
  and it is public.
- Past commits once contained private keys/certs and an API key; they were removed
  from tracking. **Rotate any credential that ever appeared in git history.**
- Planning/scratch docs (`task_plan.md`, `progress.md`, `findings.md`, `commands*.txt`,
  `docs/plans/`) are local-only and git-ignored.

## License

MIT — no LICENSE file in repo yet; add one before publishing.
