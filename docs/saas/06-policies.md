---
title: Policies
nav_order: 6
---

# Policies

The policy engine is the core of AgentGate. It evaluates every tool invocation against configurable rules and decides whether to allow or deny the request.

## Policy Language

Policies are defined in JSON files. Each policy file contains a version field and an array of policy rules.

### Structure

```json
{
  "version": "1",
  "policies": [
    { "id": "policy-id", "effect": "allow|deny", "match": { ... } }
  ]
}
```

### Policy Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | ✅ | Unique identifier for the policy (used in audit logs) |
| `effect` | string | ✅ | `"allow"` or `"deny"` — what to do if the policy matches |
| `match` | object | ✅ | The pattern to match against the tool invocation |

### Match Fields

| Field | Type | Description |
|-------|------|-------------|
| `tool` | string | Exact tool name match: `"bash"`, `"read"`, `"write"`, `"edit"` |
| `tool_pattern` | string | Glob pattern for tool name: `"read_*"`, `"write_*"` |
| `command_pattern` | string | Regex pattern for bash commands: `"rm.*-rf.*"` |
| `path_pattern` | string | Glob pattern for file paths: `"/etc/*"`, `"~/.ssh/*"` |
| `input_pattern` | string | Regex pattern for input content: `"password\|secret\|key"` |

## Evaluation Order

```
1. Deny policies are checked first (fail-closed)
2. If no deny matches, allow policies are checked
3. If no policy matches at all → DENIED BY DEFAULT
```

**Important**: AgentGate is **fail-closed** and **default-deny**. If an action doesn't match an allow policy and doesn't match a deny policy, it is denied.

## Default Policy Set

The default policy file (`policies/ai-agent.json`) contains practical rules for safe AI agent operation:

```json
{
  "version": "1",
  "policies": [
    // ── Block dangerous bash commands ──
    { "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } },
    { "id": "block-env-access", "effect": "deny", "match": { "command_pattern": ".env" } },
    { "id": "block-passwd", "effect": "deny", "match": { "tool": "bash", "command_pattern": "/etc/passwd" } },

    // ── Block sensitive file reads ──
    { "id": "block-ssh-keys", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.ssh/" } },
    { "id": "block-aws-creds", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.aws/" } },
    { "id": "block-home-read", "effect": "deny", "match": { "tool": "read", "path_pattern": "/home/" } },

    // ── Block writes to system paths ──
    { "id": "block-write-sensitive", "effect": "deny", "match": { "tool": "write", "path_pattern": "/etc/" } },
    { "id": "block-edit-etc", "effect": "deny", "match": { "tool": "edit", "path_pattern": "/etc/" } },

    // ── Allow safe operations ──
    { "id": "allow-bash", "effect": "allow", "match": { "tool": "bash" } },
    { "id": "allow-read-workspace", "effect": "allow", "match": { "tool_pattern": "read_*", "path_pattern": "/workspace/*" } },
    { "id": "allow-read", "effect": "allow", "match": { "tool": "read", "path_pattern": "/workspace/*" } },
    { "id": "allow-write-workspace", "effect": "allow", "match": { "tool": "write", "path_pattern": "/workspace/*" } },
    { "id": "allow-edit-workspace", "effect": "allow", "match": { "tool": "edit", "path_pattern": "/workspace/*" } }
  ]
}
```

## Examples

### Basic: Block destructive commands

```json
{ "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } }
```

This blocks any bash command containing `rm -rf`. Matches:
- `rm -rf /`
- `rm -rf ~/project`
- `sudo rm -rf /var/log`

### Intermediate: Block database access in production

```json
{ "id": "block-prod-db-write", "effect": "deny", "match": { "tool": "bash", "command_pattern": "(kubectl|psql|mysql).*prod.*(delete|drop|truncate)" } }
```

Blocks destructive database commands against production environments.

### Advanced: Allow only specific git operations

```json
{ "id": "allow-git-safe", "effect": "allow", "match": { "tool": "bash", "command_pattern": "git (add|commit|push|pull|status|log|diff)" } },
{ "id": "deny-git-force", "effect": "deny", "match": { "tool": "bash", "command_pattern": "git (push|reset|rebase).*--force" } },
{ "id": "deny-git-delete", "effect": "deny", "match": { "tool": "bash", "command_pattern": "git branch -D" } }
```

Allows normal git operations but blocks force pushes and branch deletion.

### Multi-condition policies

```json
{ "id": "deny-dangerous-writes", "effect": "deny", "match": {
  "tool": "write",
  "path_pattern": "/(etc|bin|sbin|boot|dev)/*"
}}
```

Blocks writes to system directories (`/etc`, `/bin`, `/sbin`, `/boot`, `/dev`).

## Best Practices

### 1. Always have allow policies for legitimate operations

Without allow policies, all operations will be denied by default. Make sure you have explicit allow rules for the tools and paths your agents need.

### 2. Deny-specific, Allow-general

A good pattern is to deny specific dangerous patterns while allowing general safe operations:

```json
// Deny specific dangerous operations
{ "id": "block-prod-kubectl", "effect": "deny", "match": { "tool": "bash", "command_pattern": "kubectl.*--context=prod" } },

// Allow bash generally
{ "id": "allow-bash", "effect": "allow", "match": { "tool": "bash" } }
```

### 3. Use the most specific match possible

More specific matches reduce false positives:

```json
// Too broad — blocks all bash (bad)
{ "id": "block-all-bash", "effect": "deny", "match": { "tool": "bash" } }

// Specific — blocks only dangerous operations (good)
{ "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } }
```

### 4. Test policies with curl

Before deploying policies, test them:

```bash
# This should be allowed
curl -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test-key" \
  -d '{"model":"deepseek-v4-flash-free","max_tokens":10,"messages":[{"role":"user","content":[{"type":"text","text":"list files"}],"tool_calls":[{"type":"tool_use","name":"bash","input":{"command":"ls"}}]}]}'

# This should be denied (blocked by block-rm-rf policy)
curl -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test-key" \
  -d '{"model":"deepseek-v4-flash-free","max_tokens":10,"messages":[{"role":"user","content":[{"type":"text","text":"delete everything"}],"tool_calls":[{"type":"tool_use","name":"bash","input":{"command":"rm -rf /"}}]}]}'
```

## Loading Custom Policies

1. Create your policy file in the `policies/` directory
2. Update `config.json` to point to your new policy file:
   ```json
   { "policy": { "policies_path": "/etc/agent-gate/policies/my-policies.json" } }
   ```
3. Restart the services: `docker compose up -d --build`

## Related

- [**Configuration**](05-configuration.md) — Config file reference
- [**API Reference**](09-api-reference.md) — Policy check endpoint docs
- [**Architecture**](03-architecture.md) — Policy engine internals
