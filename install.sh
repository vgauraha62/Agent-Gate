#!/bin/bash
# ============================================================================
# AgentGate Cage — One-Command Docker Compose Installer
# ============================================================================
# Spins up the full AgentGate Cage: Go proxy (port 8080) + Zig AgentGate
# policy engine (port 8081) with AI-optimized policies.
#
# Usage:
#   curl -fsSL https://agentgate.dev/install.sh | bash
#
# Environment variables:
#   AGENTGATE_JWT_SECRET          JWT secret for AgentGate (auto-generated if empty)
#   AGENTGATE_PROXY_ANTHROPIC_URL Upstream Anthropic API URL (default: https://api.anthropic.com)
# ============================================================================

set -e

echo "╔══════════════════════════════════════════════╗"
echo "║       AgentGate Cage — Docker Installer     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ============================================================================
# Step 1: Check prerequisites
# ============================================================================
echo "[1/4] Checking prerequisites..."

SUDO_CMD=""

if ! command -v docker >/dev/null 2>&1; then
    echo "  ✗ Docker is required but not installed."
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check docker socket permissions
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        SUDO_CMD="sudo"
        echo "  ⚠  Using sudo for Docker commands (user not in docker group)"
    else
        echo "  ✗ Cannot connect to Docker daemon."
        echo "    Either add your user to the docker group:"
        echo "      sudo usermod -aG docker \$USER && newgrp docker"
        echo "    Or run this script with sudo:"
        echo "      sudo $0"
        exit 1
    fi
fi

if $SUDO_CMD docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="$SUDO_CMD docker compose"
elif $SUDO_CMD docker-compose --version >/dev/null 2>&1; then
    COMPOSE_CMD="$SUDO_CMD docker-compose"
else
    echo "  ✗ Docker Compose is required but not installed."
    echo "  Install Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi

echo "  ✓ Docker found: $(docker --version)"
echo "  ✓ Docker Compose found"

# ============================================================================
# Step 2: Generate secrets
# ============================================================================
echo ""
echo "[2/4] Generating secrets..."

if [ -z "${AGENTGATE_JWT_SECRET:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        AGENTGATE_JWT_SECRET=$(openssl rand -hex 16)
        echo "  ✓ Generated JWT secret"
    else
        AGENTGATE_JWT_SECRET="change-me-in-dev-32chars!"
        echo "  ⚠  Using default JWT secret (not suitable for production)"
    fi
fi

# ============================================================================
# Step 3: Pull/build and start services
# ============================================================================
echo ""
echo "[3/4] Starting AgentGate Cage..."

# Export for docker-compose
export AGENTGATE_JWT_SECRET

$COMPOSE_CMD up -d --build

# Wait for services to start
echo "  Waiting for services to become healthy..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        echo "  ✓ Proxy is healthy"
        break
    fi
    sleep 1
done

for i in $(seq 1 30); do
    if curl -sf http://localhost:8081/health >/dev/null 2>&1; then
        echo "  ✓ AgentGate is healthy"
        break
    fi
    sleep 1
done

# ============================================================================
# Step 4: Print summary
# ============================================================================
echo ""
echo "[4/4] Setup complete!"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       AgentGate Cage is running!             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Proxy:     http://localhost:8080"
echo "  AgentGate: http://localhost:8081 (policy engine)"
echo "  Metrics:   http://localhost:9090"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Configure Claude Code:                              │"
echo "  │                                                     │"
echo "  │  export ANTHROPIC_BASE_URL=http://localhost:8080     │"
echo "  │  claude                                              │"
echo "  │                                                     │"
echo "  │  Your real Anthropic API key is passed through       │"
echo "  │  via x-api-key header automatically.                 │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  Test a policy check:"
echo '  curl -X POST http://localhost:8080/v1/messages \'
echo '    -H "x-api-key: your-anthropic-key" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"model":"claude-sonnet-4-20250514","max_tokens":100,"messages":[{"role":"user","content":[{"type":"text","text":"Hello"}]}]}'"'"''
echo ""
echo "  Check denied requests:"
echo "  curl http://localhost:8081/denied-requests"
echo ""
echo "  View metrics:"
echo "  curl http://localhost:9090/metrics"
echo ""
echo "  Stop services:  $COMPOSE_CMD down"
echo "  View logs:      $COMPOSE_CMD logs -f"
echo ""
