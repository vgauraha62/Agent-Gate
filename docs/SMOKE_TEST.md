# AgentGate Cage — Manual Smoke Test

This document describes how to manually test the AgentGate Cage (Go proxy + Zig AgentGate)
with Claude Code.

---

## Prerequisites

- Docker and Docker Compose installed
- A valid Anthropic API key
- Claude Code CLI installed (`claude` command available)

---

## 1. Start Services

```bash
# From the project root
export AGENTGATE_JWT_SECRET="your-jwt-secret-here-min-32-chars!!"
docker compose up -d --build

# Verify both services are healthy
curl http://localhost:8080/health   # Should return "OK"
curl http://localhost:8081/health   # Should return "OK"
```

---

## 2. Configure Claude Code

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
export ANTHROPIC_API_KEY=sk-ant-your-real-key-here

# Start Claude Code
claude
```

---

## 3. Test Scenarios

### ✅ Should be ALLOWED

| Action | Expected |
|--------|----------|
| `list files in /workspace` | Claude runs `ls` and shows files |
| `read /workspace/README.md` | Claude reads and shows the file |
| `write a test file in /workspace` | File is created successfully |
| `show disk usage` | Claude runs `df -h` or similar |

### ❌ Should be DENIED

| Action | Expected Behavior |
|--------|-------------------|
| `cat /etc/passwd` | Claude shows a policy error message |
| `rm -rf /` | Claude's bash tool returns a policy error |
| `read ~/.ssh/id_rsa` | Access blocked by policy |
| `cat ~/.aws/credentials` | Access blocked by policy |
| `cat /etc/shadow` | Access blocked by policy |

---

## 4. Verify Telemetry

### Check metrics

```bash
curl http://localhost:8081/metrics
```

Expected: Prometheus-formatted metrics including:
- Total request count
- Allow/deny counts
- Latency histograms

### Check denied requests

```bash
curl http://localhost:8081/denied-requests
```

Expected: JSON array of denied requests with:
- `agent_id` — session identifier
- `path` — the blocked tool/path
- `policy_id` — the policy that blocked it
- `timestamp` — when it was blocked
- `reason` — the denial reason

```bash
# Filter by agent
curl "http://localhost:8081/denied-requests?limit=10&agent=<agent_id_hex>"

# Filter by time (microseconds since epoch)
curl "http://localhost:8081/denied-requests?since=1717200000000000"
```

---

## 5. Direct API Testing (without Claude Code)

### Test ALLOW flow (mock success)

```bash
# Check AgentGate directly (tool-aware format)
curl -X POST http://localhost:8081/check \
  -H "Content-Type: application/json" \
  -d '{"tool":"bash","command":"ls -la","path":"/workspace"}'

# Expected: {"allowed":true}
```

### Test DENY flow

```bash
# Check AgentGate directly — blocked command
curl -X POST http://localhost:8081/check \
  -H "Content-Type: application/json" \
  -d '{"tool":"bash","command":"rm -rf /"}'

# Expected: {"allowed":false,"reason":"policy denied by: block-rm","policy_id":"block-rm"}
```

### Test blocked file read

```bash
curl -X POST http://localhost:8081/check \
  -H "Content-Type: application/json" \
  -d '{"tool":"read","path":"/etc/passwd"}'

# Expected: {"allowed":false,...}
```

---

## 6. Test Legacy Format (Backward Compatibility)

The `/check` endpoint still accepts the original format:

```bash
curl -X POST http://localhost:8081/check \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/users","method":"GET"}'

# Expected: {"allowed":true}
```

---

## 7. Docker Operations

```bash
# View logs
docker compose logs -f

# View specific service logs
docker compose logs -f proxy
docker compose logs -f agentgate

# Stop services
docker compose down

# Rebuild and restart
docker compose up -d --build
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Proxy health check fails | AgentGate not started | Wait or check `docker compose logs proxy` |
| "missing x-api-key" | No API key provided | Set `ANTHROPIC_API_KEY` or pass `x-api-key` header |
| All requests allowed | Wrong policy file loaded | Verify `ai-agent.json` is mounted in container |
| All requests denied | Policy too restrictive | Check `ai-agent.json` rules, add `allow-bash` |
| Upstream timeout | No internet / wrong Anthropic URL | Check `AGENTGATE_PROXY_ANTHROPIC_URL` |
