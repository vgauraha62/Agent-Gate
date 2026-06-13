---
title: Configuration
nav_order: 5
---

# Configuration

AgentGate Cage is configured through a combination of environment variables (for the proxy) and JSON/YAML files (for the policy engine and LiteLLM).

## Environment Variables

The proxy reads configuration from the `.env` file at startup.

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTGATE_PROXY_LISTEN` | `:8080` | Proxy listen address |
| `AGENTGATE_PROXY_AGENTGATE_URL` | `http://agentgate:8081` | Policy engine URL |
| `AGENTGATE_PROXY_ANTHROPIC_URL` | `https://api.anthropic.com` | Upstream AI API URL |
| `AGENTGATE_PROXY_POLICY_TIMEOUT` | `5s` | Timeout for policy engine requests |
| `AGENTGATE_PROXY_UPSTREAM_TIMEOUT` | `300s` | Timeout for upstream AI API |

### License Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTGATE_PROXY_SKIP_LICENSE` | `false` | Skip all license checks (dev mode) |
| `AGENTGATE_PROXY_LICENSE_KEY` | `""` | License key for production |
| `AGENTGATE_PROXY_LICENSE_URL` | `http://license-server:4001` | License server URL |

### Auth Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTGATE_JWT_SECRET` | — | JWT secret for AgentGate auth (auto-generated if empty) |
| `AGENTGATE_AUTH_JWT_SECRET` | Same | Passed to agentgate container |

### Upstream URL Reference

| Mode | `AGENTGATE_PROXY_ANTHROPIC_URL` | Description |
|------|--------------------------------|-------------|
| **OpenCode** (LiteLLM) | `http://litellm:4000` | Translate Anthropic → OpenAI |
| **Claude Code** (direct) | `https://api.anthropic.com` | Direct Anthropic API |
| **Ollama** (local) | `http://host.docker.internal:11434` | Local inference |

## Config Files

### `config.json` — AgentGate Policy Engine

Controls the policy engine behavior:

```json
{
  "server": { "port": 8081, "host": "0.0.0.0" },
  "policy": {
    "policies_path": "/etc/agent-gate/policies/ai-agent.json",
    "policy_timeout_ms": 20,
    "max_policies": 100
  },
  "timeouts": { "policy_ms": 20, "request_ms": 10000 },
  "auth": { "jwt_secret": "" },
  "tls": { "mode": "disabled" },
  "audit": { "buffer_size": 1024, "audit_timeout_ms": 10 },
  "request": {
    "request_timeout_ms": 10000,
    "max_body_size": 1048576,
    "max_headers": 64
  },
  "shutdown": {
    "grace_period_ms": 30000,
    "enable_signals": true
  }
}
```

### `litellm-config.yaml` — LiteLLM Routing

Controls model-to-provider routing:

```yaml
model_list:
  - model_name: "deepseek-*"
    litellm_params:
      model: "openai/deepseek-v4-flash"
      api_base: https://opencode.ai/zen/v1
      api_key: "YOUR_ZEN_API_KEY_HERE"   # ⚠️ Contains secrets

litellm_settings:
  accept_anthropic_format: true       # Required for Anthropic→OpenAI translation
  drop_params: true                    # Remove unsupported params silently
  set_verbose: true                    # Debug logging

general_settings:
  master_key: sk-litellm-master-key    # Admin API key
  enable_telemetry: false              # Privacy
```

### `policies/ai-agent.json` — Policy Rules

Defines the allow/deny rules for tool invocations:

```json
{
  "version": "1",
  "policies": [
    { "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } }
  ]
}
```

See the [Policies](06-policies.md) documentation for the full policy language reference.

## Mode-Specific Configs

The `switch.sh` script toggles between OpenCode and Claude Code configurations:

| File | OpenCode Mode | Claude Mode |
|------|---------------|-------------|
| `.env` | Points to `litellm:4000` | Points to `api.anthropic.com` |
| `config.json` | OpenCode variant | Claude variant |
| `litellm-config.yaml` | Used (translates format) | Not used (direct Anthropic) |

## Secrets That Must Be Protected

| File | Contains | Protection |
|------|----------|------------|
| `.env` | JWT secret, API keys | `chmod 600`, never commit |
| `litellm-config.yaml` | Zen API / Anthropic API key | `chmod 600`, never commit |
| `keys/private.pem` | RSA private key | `chmod 600`, never commit |
| `certs/*.key` | mTLS private keys | `chmod 600`, never commit |

## Related

- [**Quickstart**](02-quickstart.md) — Getting started
- [**Policies**](06-policies.md) — Policy language reference
- [**Deployment**](04-deployment.md) — Deployment guide
