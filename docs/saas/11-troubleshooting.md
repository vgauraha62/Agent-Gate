---
title: Troubleshooting
nav_order: 11
---

# Troubleshooting

## Docker Build Fails

### Symptom: `docker compose up -d --build` exits with error

```
[+] Building ... error: failed to solve: ...
```

**Common causes and solutions:**

| Error | Cause | Solution |
|-------|-------|----------|
| `go: github.com/...: read tcp ...: i/o timeout` | Go module proxy unreachable | Set `GOPROXY=direct` in `proxy/Dockerfile` |
| `error: unable to fetch package '...'` | Zig package registry unreachable | Wait and retry; or set up a Zig package mirror |
| `tar: Error is not recoverable: exiting now` | Download corrupted | Clean Docker build cache: `docker builder prune -f` |
| `C compiler not found` | Zig can't find system C compiler | Not needed for musl target; check `-Dtarget=x86_64-linux-musl` |
| `no such file or directory` during COPY | Missing source file | Verify file paths in Dockerfile match the repository structure |

**Clean rebuild:**
```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

## Proxy Fails to Start

### Symptom: Proxy container exits immediately

```bash
docker compose logs proxy
```

| Log Message | Cause | Solution |
|-------------|-------|----------|
| `AgentGate URL: http://agentgate:8081` then `connection refused` | AgentGate not healthy yet | Wait; check `depends_on: condition: service_healthy` |
| `License check failed` | License server unreachable | Set `AGENTGATE_PROXY_SKIP_LICENSE=true` for dev |
| `Upstream error: connection refused` | LiteLLM or upstream not running | Check `AGENTGATE_PROXY_ANTHROPIC_URL` in `.env` |
| `Failed to load config` | `.env` file missing or malformed | Check `.env` exists and is valid format |
| `Port :8080 already in use` | Port conflict | Change `ports: "8080:8080"` to another port |

## LiteLLM "No Connected DB"

### Symptom: LiteLLM logs show:

```json
{"error": {"message": "No connected db.", "type": "no_db_connection"}}
```

**Cause**: LiteLLM v1.60+ enables database-backed features by default. AgentGate doesn't use these features.

**Impact**: **None.** The proxy still functions correctly. This error is cosmetic.

**Solution**: Ignore the error. Or add to `litellm-config.yaml`:
```yaml
general_settings:
  disable_db: true   # Future LiteLLM versions may support this
```

## SELinux Denials

### Symptom: Container logs show "Permission denied"

```
Error: open /app/config.yaml: permission denied
```

**Cause**: SELinux is blocking the container from reading bind-mounted files.

**Solution**: Add `:z` flag to all bind-mounted volumes in `docker-compose.yml`:
```yaml
volumes:
  - ./litellm-config.yaml:/app/config.yaml:ro,z  # ← Note :z
  - ./config.json:/etc/agent-gate/config.json:ro,z
  - ./policies:/etc/agent-gate/policies:ro,z
```

Then restart: `docker compose down && docker compose up -d`

## Port Conflicts

### Symptom: Docker reports "port already allocated"

```
Error: Port 8080 is already in use
```

**Solution**: Change the host port mapping:

```yaml
services:
  proxy:
    ports:
      - "8082:8080"     # Map host:8082 to container:8080
```

Then update your client to use the new port:
```bash
# OpenCode: update baseURL in opencode.json
"baseURL": "http://localhost:8082"

# Claude Code: update env var
export ANTHROPIC_BASE_URL=http://localhost:8082
```

## OpenCode "ConfigInvalidError"

### Symptom: OpenCode fails to start:

```
ConfigInvalidError: configuration is not valid

Caused by:
  unknown field `providers`, expected `provider`
```

**Cause**: OpenCode v1.15+ uses `"provider"` (singular) instead of `"providers"` (plural).

**Fix**: 
```diff
- "providers": { "agentgate": {...} }
+ "provider": { "agentgate": {...} }
```

## OpenCode "model not found"

### Symptom: OpenCode shows error about model not being available.

**Cause**: The model name uses an incorrect naming convention.

**Fix**: Ensure the model follows `provider/model` format:
```json
"model": "agentgate/deepseek-v4-flash-free"
```

The part before `/` must match a key in the `provider` map.

## Container Restart Loop

### Symptom: Container repeatedly exits and restarts

```bash
docker compose ps
# NAME               STATUS
# agent-gate-proxy   Restarting (1) 5 seconds ago
```

**Troubleshooting:**

1. **Check logs**: `docker compose logs --tail=50 proxy`
2. **Check config**: Verify `.env` and `config.json` are valid
3. **Check dependencies**: Is agentgate healthy? `curl localhost:8081/health`
4. **Check ports**: Is port 8080 already in use?
5. **Force rebuild**: `docker compose up -d --build --force-recreate`

## Health Check Fails

### Symptom: `curl localhost:8080/health` returns nothing or connection refused

| Service | Check Command | Expected | If Fails |
|---------|--------------|----------|----------|
| AgentGate | `curl localhost:8081/health` | `200 OK` | Check agentgate config, policy file |
| Proxy | `curl localhost:8080/health` | `200 OK` | Check `.env`, agentgate dependency |
| LiteLLM | `curl localhost:4000/health` | `200 OK` | Check `litellm-config.yaml` |

## Getting Help

If you can't resolve an issue:

1. **Check the logs**: `docker compose logs --tail=100 [service-name]`
2. **Verify your configuration**: Run `docker compose config` to validate
3. **Search the FAQ**: See [FAQ](12-faq.md)
4. **Open an issue**: Include logs, config (redact secrets), and steps to reproduce

## Related

- [**FAQ**](12-faq.md) — Frequently asked questions
- [**Deployment**](04-deployment.md) — Deployment guide
- [**Configuration**](05-configuration.md) — Configuration reference
