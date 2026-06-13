#!/bin/bash
# Switch between Claude Code and OpenCode modes

set -e

cd ~/zig/agent-gate

case "$1" in
  claude)
    echo "🔄 Switching to Claude Code (Anthropic) mode..."
    cp .env.claude .env
    cp config.claude.json config.json
    cp litellm-config.claude.yaml litellm-config.yaml
    echo "✅ Switched to Claude mode"
    echo "⚠️  Run: sudo docker compose up -d"
    ;;
  opencode)
    echo "🔄 Switching to OpenCode mode..."
    cp .env.opencode .env
    cp config.opencode.json config.json
    cp litellm-config.opencode.yaml litellm-config.yaml
    echo "✅ Switched to OpenCode mode"
    echo "⚠️  Run: sudo docker compose up -d"
    ;;
  status)
    if grep -q "host.docker.internal" .env 2>/dev/null; then
      echo "Current mode: Claude Code (Ollama)"
    elif grep -q "litellm" .env 2>/dev/null; then
      echo "Current mode: OpenCode (LiteLLM → Zen API)"
    else
      echo "Current mode: Unknown"
    fi
    echo "  proxy → $(grep AGENTGATE_PROXY_ANTHROPIC_URL .env 2>/dev/null | cut -d= -f2)"
    echo "  model: $(grep -m1 model_name litellm-config.yaml 2>/dev/null)"
    ;;
  *)
    echo "Usage: $0 {claude|opencode|status}"
    echo ""
    echo "  claude    - Switch to Claude Code (Anthropic API)"
    echo "  opencode  - Switch to OpenCode (OpenCode API)"
    echo "  status    - Show current mode"
    exit 1
    ;;
esac
