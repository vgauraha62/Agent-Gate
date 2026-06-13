#!/bin/bash
# Switch between Claude Code and OpenCode modes

set -e

cd ~/zig/agent-gate

case "$1" in
  claude)
    echo "🔄 Switching to Claude Code (Anthropic) mode..."
    cp .env.claude .env
    cp config.claude.json config.json
    echo "✅ Switched to Claude mode"
    ;;
  opencode)
    echo "🔄 Switching to OpenCode mode..."
    cp .env.opencode .env
    cp config.opencode.json config.json
    echo "✅ Switched to OpenCode mode"
    ;;
  status)
    if grep -q "api.anthropic.com" .env 2>/dev/null; then
      echo "Current mode: Claude Code (Anthropic)"
    elif grep -q "api.opencode.ai" .env 2>/dev/null; then
      echo "Current mode: OpenCode"
    else
      echo "Current mode: Unknown"
    fi
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
