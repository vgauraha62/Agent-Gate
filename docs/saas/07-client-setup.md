---
title: Client Setup
nav_order: 7
---

# Client Setup

Configure AI coding agents to route through AgentGate Cage.

## OpenCode

### Configuration

Create `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "agentgate/deepseek-v4-flash-free",
  "small_model": "agentgate/deepseek-v4-flash-free",
  "provider": {
    "agentgate": {
      "name": "AgentGate Proxy",
      "options": {
        "baseURL": "http://localhost:8080",
        "apiKey": "test-key"
      }
    }
  },
  "agent": {
    "build": {
      "mode": "primary",
      "model": "agentgate/deepseek-v4-flash-free",
      "tools": { "write": true, "edit": true, "bash": true }
    },
    "plan": {
      "mode": "primary",
      "model": "agentgate/deepseek-v4-flash-free",
      "tools": { "write": false, "edit": false, "bash": false }
    }
  }
}
```

### Important Schema Notes

1. **`provider` (singular)**: The top-level key must be `"provider"`, **NOT** `"providers"`. OpenCode v1.15+ uses the singular form.
2. **Model naming**: Use `provider/model` format. `agentgate/deepseek-v4-flash-free` means "use the `agentgate` provider with model `deepseek-v4-flash-free`".
3. **The proxy receives the model without the prefix**: OpenCode strips the `agentgate/` prefix before sending, so the proxy sees `"model": "deepseek-v4-flash-free"`.

### Verification

Check that OpenCode connects to the proxy:

```bash
opencode --dry-run
# Should show: Connecting to agentgate at http://localhost:8080
```

## Claude Code

### Configuration

Set the environment variable and start Claude:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
claude
```

### How It Works

Claude Code sends the Anthropic Messages API format natively, so no format translation is needed. The proxy passes requests through to the upstream (directly to Anthropic API or to LiteLLM).

Your Anthropic API key is sent via the `x-api-key` header and passed through the proxy to the upstream.

## Custom Clients

Any client that speaks the Anthropic Messages API can route through AgentGate.

### Python (Anthropic SDK)

```python
import anthropic

client = anthropic.Anthropic(
    base_url="http://localhost:8080",
    api_key="test-key"  # Proxy API key (not your AI API key)
)

response = client.messages.create(
    model="deepseek-v4-flash-free",
    max_tokens=100,
    messages=[{"role": "user", "content": "Hello"}]
)
```

### cURL

```bash
curl -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test-key" \
  -d '{
    "model": "deepseek-v4-flash-free",
    "max_tokens": 50,
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### Node.js (Anthropic SDK)

```javascript
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic({
  baseURL: "http://localhost:8080",
  apiKey: "test-key"
});

const response = await client.messages.create({
  model: "deepseek-v4-flash-free",
  max_tokens: 100,
  messages: [{ role: "user", content: "Hello" }]
});
```

## API Key Strategy

The proxy accepts any `x-api-key` value and passes it to the upstream. This enables:

- **Per-agent API keys**: Each agent (or user) can have their own API key
- **Key rotation**: Change keys without restarting the proxy
- **Audit tracing**: The API key can be used to trace requests back to specific agents

In development mode, any non-empty value works. In production, configure the upstream (LiteLLM or Anthropic) to validate the API key.

## Troubleshooting Client Setup

### OpenCode: "ConfigInvalidError"

**Cause**: Using `"providers"` (plural) instead of `"provider"` (singular).

**Fix**: Change `"providers"` to `"provider"` in `opencode.json`.

### OpenCode: "model not found"

**Cause**: The model name doesn't match the provider prefix format.

**Fix**: Ensure the model is in `provider/model` format, e.g., `"agentgate/deepseek-v4-flash-free"`.

### Claude Code: "connection refused"

**Cause**: The proxy is not running or not reachable.

**Fix**: Check `docker compose ps` and verify `http://localhost:8080/health` returns OK.

## Related

- [**Quickstart**](02-quickstart.md) — Get running in 5 minutes
- [**API Reference**](09-api-reference.md) — Full API documentation
- [**Troubleshooting**](11-troubleshooting.md) — Common issues
