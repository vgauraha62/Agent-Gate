---
title: FAQ
nav_order: 12
---

# Frequently Asked Questions

## General

### What is AgentGate Cage?

AgentGate Cage is an AI-native policy enforcement proxy. It sits between AI coding agents (OpenCode, Claude Code, Cursor) and the LLM (DeepSeek, Claude, Ollama), intercepts every tool invocation, evaluates it against security policies, and blocks dangerous operations before they reach the model.

### Why would I need this?

AI agents execute powerful operations — bash commands, file writes, network access. Without policy enforcement, an agent can accidentally (or through prompt injection) run `rm -rf /`, read your SSH keys, delete production databases, or exfiltrate secrets. AgentGate gives you fine-grained control over what tools agents can use.

### Is this a replacement for LiteLLM?

No. AgentGate **includes** LiteLLM as a component for format translation. The key difference is that AgentGate adds a policy enforcement layer *before* LiteLLM. LiteLLM alone has no policy engine and no audit trail.

### Is this a replacement for Kong/nginx/Envoy?

No. Those are general-purpose API gateways for URL-level routing, load balancing, and rate limiting. AgentGate is a specialized proxy for AI agent traffic. You can run both — put AgentGate behind nginx for TLS termination and routing.

### How is this different from Azure AI Content Safety?

Azure AI Content Safety is a cloud-based content moderation service focused on detecting harmful content (hate speech, toxicity, etc.). AgentGate is a self-hosted policy enforcement proxy focused on preventing dangerous tool invocations. They solve different problems and can be used together.

## Technical

### What language is AgentGate written in?

Three languages, each chosen for its strengths:
- **Zig**: Policy engine — deterministic performance, zero-cost abstractions, no GC latency
- **Go**: HTTP proxy — excellent standard library, battle-tested for API servers
- **Python**: LiteLLM translation layer — ecosystem compatibility with AI providers

### How fast is it?

Policy decisions complete in **<50µs P99** (measured on Ryzen 9 7950X). The proxy handles **85,000+ requests/second** on a single core. Total memory usage is **under 50MB**.

### Does it work without Docker?

Currently, Docker Compose is the only supported deployment method. The individual components can run natively (Go binary, Zig binary, Python), but there's no documented native deployment flow yet.

### Does it work on ARM64 (Apple Silicon)?

Yes, but with caveats. Docker Desktop on Apple Silicon emulates x86_64 for the Zig build, which adds build time. Runtime performance is still acceptable. For native ARM64 builds, modify the Dockerfile's target to `aarch64-linux-musl`.

### Does it work on Windows?

Not recommended. The Docker setup assumes a Linux host with SELinux or AppArmor. WSL2 may work but is not tested.

## Licensing

### Is AgentGate free?

**Development mode is completely free.** Set `AGENTGATE_PROXY_SKIP_LICENSE=true` and the proxy runs unrestricted — no license server, no signup, no credit card.

**Production use requires a license** for audit features, rate limiting, mTLS, and priority support. Contact us for pricing.

### Can I use this for commercial projects?

The code is MIT licensed. You can use, modify, and distribute it freely. The development mode is unlimited.

### What does the license check actually do?

In production mode, the proxy validates a JWT token from the license server at startup and every hour. Without a valid token, the proxy rejects all requests with `402 Payment Required`. In development mode (`SKIP_LICENSE=true`), all requests are allowed.

## Security

### Does AgentGate send my data anywhere?

**No.** AgentGate Cage is fully self-hosted. The only outbound traffic is the AI API call to your configured provider (Zen API, Anthropic, or Ollama). No telemetry, no analytics, no usage data is collected.

### Can AgentGate prevent prompt injection?

Indirectly, yes. Prompt injection works by convincing the agent to execute dangerous tool calls. AgentGate's policy engine blocks those tool calls regardless of how they were generated. Direct prompt injection into the LLM response is not prevented (this is on the roadmap for v0.4).

### What happens if the policy engine is down?

The proxy **fails closed**. If AgentGate is unreachable or returns errors, the proxy denies all requests. This prevents agents from operating without policy enforcement.

## Operations

### How do I update the policies without restarting?

Currently, policy changes require a container restart. Hot-reload is on the roadmap (v0.2).

### How do I view denied requests?

```bash
curl http://localhost:8081/denied-requests
```

Returns the audit log with all denied requests, including the tool, command, policy that blocked it, and the cryptographic hash for verification.

### How do I monitor the system?

AgentGate exposes Prometheus metrics on `localhost:9090/metrics`. Use these with Prometheus + Grafana for monitoring and alerting.

### How do I back up the audit log?

The audit log is stored in the `agentgate_data` Docker volume. To back it up:

```bash
# Export the audit log
docker run --rm -v agentgate_data:/data alpine tar czf - /data > agentgate-audit-backup.tar.gz

# Or query via API and save
curl http://localhost:8081/denied-requests > audit-export.json
```

### How do I migrate to a new machine?

1. On the old machine: export Docker images:
   ```bash
   docker save -o agentgate-images.tar agentgate-cage_proxy agentgate-cage_agentgate
   docker pull ghcr.io/berriai/litellm:main-latest
   docker save -o litellm-image.tar ghcr.io/berriai/litellm:main-latest
   ```
2. Copy the `agent-gate-portable` directory and images to the new machine
3. On the new machine:
   ```bash
   docker load -i agentgate-images.tar
   docker load -i litellm-image.tar
   sudo ./setup.sh   # Re-run setup with your secrets
   ```

## Configuration

### What's the difference between OpenCode mode and Claude Code mode?

| Aspect | OpenCode Mode | Claude Code Mode |
|--------|---------------|------------------|
| Upstream | LiteLLM → Zen API | Direct → Anthropic API |
| Format | Anthropic → OpenAI (translated) | Anthropic (native) |
| Models | DeepSeek V4 Flash Free, DeepSeek V4 Flash | Claude Sonnet 4 |
| LiteLLM | Required | Not needed |
| API key | Zen API key | Anthropic API key |

### How do I switch modes?

```bash
sudo ./switch.sh opencode   # Switch to OpenCode mode
sudo ./switch.sh claude     # Switch to Claude mode
```

Then restart the containers:
```bash
sudo docker compose up -d --build
```

### How do I add a new model?

Edit `litellm-config.yaml` to add a new model routing entry:

```yaml
model_list:
  - model_name: "my-new-model"
    litellm_params:
      model: "openai/my-new-model"
      api_base: https://my-api-provider.com/v1
      api_key: "MY_API_KEY"
```

See the [Configuration](05-configuration.md) documentation for details.

## Troubleshooting

*See the [Troubleshooting](11-troubleshooting.md) guide for detailed solutions to common issues.*

### Quick fixes:

| Problem | Quick Fix |
|---------|-----------|
| "No connected db" from LiteLLM | Ignore — harmless cosmetic error |
| Container restarting | Check logs: `docker compose logs [name]` |
| Port conflict | Change host port in `docker-compose.yml` |
| SELinux permission denied | Add `:z` to volume mounts |
| "ConfigInvalidError" | Use `"provider"` not `"providers"` in OpenCode config |
| Proxy can't connect to agentgate | Check agentgate health: `curl localhost:8081/health` |
