#!/usr/bin/env bash
# ============================================================================
# AgentGate Cage — Portable Setup Script
# ============================================================================
# One-command bootstrap for a new machine:
#   ✓ Installs Docker + prerequisites
#   ✓ Prompts for API keys (interactive)
#   ✓ Generates configs from templates
#   ✓ Builds and starts all Docker services
#   ✓ Configures OpenCode client
#   ✓ Prints success summary
#
# Usage:
#   chmod +x setup.sh && sudo ./setup.sh
# ============================================================================

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLUE}╰─➤${NC}  $*"; }
ok()    { echo -e "${GREEN}✅${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠️${NC}  $*"; }
err()   { echo -e "${RED}❌${NC}  $*"; }
header(){ echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"; }

# ── Step counter ───────────────────────────────────────────────────────────
STEP=0
next_step() { STEP=$((STEP+1)); echo ""; header "[$STEP/7] $*"; }

# ── Determine script directory (works even when sourced symlinked) ─────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Banner ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}"
echo "   ╔═══════════════════════════════════════════════╗"
echo "   ║        AgentGate Cage — Portable Setup        ║"
echo "   ║     AI Proxy Stack: Docker One-Click Deploy   ║"
echo "   ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================================
# STEP 1: Install Prerequisites
# ============================================================================
next_step "Installing Prerequisites"

# Detect OS
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
fi

# Ensure we have sudo powers
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        warn "Not running as root — re-executing with sudo..."
        exec sudo "$0" "$@"
    else
        err "This script needs root privileges to install packages."
        err "Please run: sudo $0"
        exit 1
    fi
fi

install_pkg() {
    local pkg="$1"
    if ! command -v "$pkg" >/dev/null 2>&1; then
        info "Installing $pkg..."
        case "$OS" in
            ubuntu|debian)
                apt-get install -y -qq "$pkg" >/dev/null 2>&1 || {
                    apt-get update -qq >/dev/null 2>&1
                    apt-get install -y -qq "$pkg" >/dev/null 2>&1
                }
                ;;
            fedora|rhel|centos)
                dnf install -y -q "$pkg" >/dev/null 2>&1
                ;;
            arch|manjaro)
                pacman -S --noconfirm "$pkg" >/dev/null 2>&1
                ;;
            *)
                warn "Unknown OS '$OS'. Please install $pkg manually."
                return 1
                ;;
        esac
        ok "$pkg installed"
    else
        ok "$pkg already installed"
    fi
}

# Core prerequisites
install_pkg curl
install_pkg openssl

# Docker Engine
if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker Engine..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    ok "Docker installed"
else
    ok "Docker already installed: $(docker --version 2>/dev/null || true)"
fi

# Docker Compose plugin
if ! docker compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 plugin not found."
    info "Installing docker-compose-plugin..."
    case "$OS" in
        ubuntu|debian)
            apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || \
            apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
            ;;
        fedora|rhel|centos)
            dnf install -y -q docker-compose-plugin >/dev/null 2>&1
            ;;
        *)
            err "Please install Docker Compose manually: https://docs.docker.com/compose/install/"
            exit 1
            ;;
    esac
    ok "Docker Compose installed"
else
    ok "Docker Compose already installed: $(docker compose version 2>/dev/null || true)"
fi

# Ensure Docker is running
if ! docker info >/dev/null 2>&1; then
    info "Starting Docker daemon..."
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    sleep 2
    if ! docker info >/dev/null 2>&1; then
        err "Docker daemon failed to start. Please check system logs."
        exit 1
    fi
    ok "Docker daemon started"
fi

# Architecture check
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    warn "Architecture: $ARCH (expected x86_64)"
    warn "The Zig build targets x86_64-linux-musl. Docker build may be slow on non-x86_64 hosts."
    warn "This is expected to work on Apple Silicon (ARM64) Macs via Docker Desktop emulation."
fi

# ============================================================================
# STEP 2: Select Mode
# ============================================================================
next_step "Selecting Mode"

echo ""
echo "  Which AI client do you want to use?"
echo ""
echo "    ${BOLD}1) OpenCode${NC}     — AgentGate → LiteLLM → Zen API (opencode.ai)"
echo "                    Uses DeepSeek models, needs a Zen API key"
echo ""
echo "    ${BOLD}2) Claude Code${NC}  — AgentGate → Anthropic API (api.anthropic.com)"
echo "                    Uses Claude models, needs an Anthropic API key"
echo ""
read -r -p "  Enter choice [1]: " MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

if [ "$MODE_CHOICE" = "2" ]; then
    MODE="claude"
    MODE_TEMPLATE="env/.env.claude.template"
    CONFIG_TEMPLATE="config/config.claude.json"
    ok "Selected Claude Code mode"
else
    MODE="opencode"
    MODE_TEMPLATE="env/.env.opencode.template"
    CONFIG_TEMPLATE="config/config.opencode.json"
    ok "Selected OpenCode mode"
fi

# ============================================================================
# STEP 3: Collect Secrets
# ============================================================================
next_step "Collecting Secrets"

# ── JWT Secret ──────────────────────────────────────────────────────────
JWT_SECRET=""
DEFAULT_JWT_SECRET=$(openssl rand -hex 16 2>/dev/null || echo "change-me-in-dev-32bytes-secret-key!")
read -r -p "  AgentGate JWT secret [auto-generate]: " JWT_SECRET
JWT_SECRET="${JWT_SECRET:-$DEFAULT_JWT_SECRET}"
ok "JWT secret configured"

# ── Mode-specific secrets ──────────────────────────────────────────────
ZEN_API_KEY=""
ANTHROPIC_API_KEY=""

if [ "$MODE" = "opencode" ]; then
    while [ -z "$ZEN_API_KEY" ] || [ "$ZEN_API_KEY" = "YOUR_ZEN_API_KEY_HERE" ]; do
        echo ""
        echo "  ${YELLOW}Enter your OpenCode Zen API key.${NC}"
        echo "  Get one at: ${BLUE}https://opencode.ai${NC}"
        echo "  It looks like: sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        read -r -p "  Zen API Key: " ZEN_API_KEY
        echo ""
    done
    ok "Zen API key collected"
else
    read -r -p "  Anthropic API Key (sk-ant-...): " ANTHROPIC_API_KEY
    while [ -z "$ANTHROPIC_API_KEY" ]; do
        read -r -p "  Anthropic API Key (required): " ANTHROPIC_API_KEY
    done
    ok "Anthropic API key collected"
fi

# ── LiteLLM Master Key ─────────────────────────────────────────────────
LITELLM_MASTER_KEY=""
read -r -p "  LiteLLM master key [sk-litellm-master-key]: " LITELLM_MASTER_KEY
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-master-key}"
ok "LiteLLM master key configured"

# ============================================================================
# STEP 4: Generate Config Files
# ============================================================================
next_step "Generating Config Files"

# ── .env ───────────────────────────────────────────────────────────────
if [ -f ".env" ]; then
    warn ".env already exists — backing up to .env.backup.$(date +%s)"
    cp .env ".env.backup.$(date +%s)"
fi

cp "$MODE_TEMPLATE" .env
chmod 600 .env

# Inject secrets into .env
sed -i "s/YOUR_JWT_SECRET_HERE/$JWT_SECRET/g" .env

# ── config.json ────────────────────────────────────────────────────────
cp "$CONFIG_TEMPLATE" config.json

# ── litellm-config.yaml ────────────────────────────────────────────────
if [ "$MODE" = "opencode" ]; then
    cp config/litellm-config.yaml litellm-config.yaml
    chmod 600 litellm-config.yaml

    # Escape the API key for sed (it may contain slashes)
    ESCAPED_ZEN_KEY=$(printf '%s\n' "$ZEN_API_KEY" | sed 's/[\/&]/\\&/g')
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/YOUR_ZEN_API_KEY_HERE/$ESCAPED_ZEN_KEY/g" litellm-config.yaml
    else
        sed -i "s/YOUR_ZEN_API_KEY_HERE/$ESCAPED_ZEN_KEY/g" litellm-config.yaml
    fi
    ok "litellm-config.yaml generated with Zen API key"
fi

# ── RSA keys for license server ────────────────────────────────────────
if [ ! -f "keys/private.pem" ] || [ ! -f "keys/public.pem" ]; then
    warn "No RSA keys found — generating new key pair for license server..."
    mkdir -p keys
    openssl genrsa -out keys/private.pem 2048 >/dev/null 2>&1
    openssl rsa -in keys/private.pem -pubout -out keys/public.pem >/dev/null 2>&1
    chmod 600 keys/private.pem
    ok "RSA key pair generated in keys/"
else
    ok "RSA keys already present"
fi

ok "All config files generated"

# ============================================================================
# STEP 5: Build and Start Docker Services
# ============================================================================
next_step "Building and Starting Docker Services"

echo ""
info "This will build the proxy (Go) and agentgate (Zig) containers."
info "First build may take 3-5 minutes (Docker layer caching speeds up repeats)."
echo ""

# Start build
docker compose up -d --build 2>&1 | awk '{print "  " $0}'

# ── Wait for services ──────────────────────────────────────────────────
echo ""
info "Waiting for services to become healthy..."

# AgentGate (policy engine, port 8081)
for i in $(seq 1 60); do
    if curl -sf http://localhost:8081/health >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} AgentGate policy engine — healthy (port 8081)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        warn "AgentGate health check timed out. Check logs: docker compose logs agentgate"
    fi
    sleep 2
done

# Proxy (port 8080)
for i in $(seq 1 30); do
    if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Proxy — healthy (port 8080)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Proxy health check timed out. Check logs: docker compose logs proxy"
    fi
    sleep 2
done

# LiteLLM (port 4000) — only in OpenCode mode
if [ "$MODE" = "opencode" ]; then
    for i in $(seq 1 30); do
        if curl -sf http://localhost:4000/health >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} LiteLLM — responsive (port 4000)"
            break
        fi
        if [ "$i" -eq 30 ]; then
            warn "LiteLLM health check timed out. Check logs: docker compose logs litellm"
        fi
        sleep 2
    done
fi

ok "All services started"

# ============================================================================
# STEP 6: Configure OpenCode (optional)
# ============================================================================
if [ "$MODE" = "opencode" ]; then
    next_step "Configuring OpenCode Client"

    echo ""
    read -r -p "  Configure OpenCode CLI to use this proxy? [Y/n]: " CONFIGURE_OPENCODE
    CONFIGURE_OPENCODE="${CONFIGURE_OPENCODE:-Y}"

    if [[ "$CONFIGURE_OPENCODE" =~ ^[Yy] ]]; then
        OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
        OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/opencode.json"

        mkdir -p "$OPENCODE_CONFIG_DIR"

        if [ -f "$OPENCODE_CONFIG_FILE" ]; then
            warn "OpenCode config already exists — backing up to opencode.json.bak"
            cp "$OPENCODE_CONFIG_FILE" "${OPENCODE_CONFIG_FILE}.bak"
        fi

        cat > "$OPENCODE_CONFIG_FILE" << 'EOF'
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
      "prompt": "You are a senior software engineer focused on building high-quality code.",
      "tools": {
        "write": true,
        "edit": true,
        "bash": true
      }
    },
    "plan": {
      "mode": "primary",
      "model": "agentgate/deepseek-v4-flash-free",
      "prompt": "You are a solutions architect and technical planner.",
      "tools": {
        "write": false,
        "edit": false,
        "bash": false
      }
    }
  }
}
EOF
        chmod 600 "$OPENCODE_CONFIG_FILE"
        ok "OpenCode configured at $OPENCODE_CONFIG_FILE"

        # Check if opencode CLI is installed
        if command -v opencode >/dev/null 2>&1; then
            ok "OpenCode CLI found: $(opencode --version 2>/dev/null || opencode version 2>/dev/null || echo 'installed')"
        else
            warn "OpenCode CLI not found on PATH."
            echo ""
            echo "  Install it with:"
            echo "    curl -fsSL https://opencode.ai/install | sh"
            echo ""
            echo "  Or download from: https://github.com/opencode-ai/opencode/releases"
        fi
    else
        ok "Skipping OpenCode configuration"
    fi
fi

# ============================================================================
# STEP 7: Success Summary
# ============================================================================
next_step "Setup Complete!"

echo ""
echo -e "  ${GREEN}${BOLD}AgentGate Cage is running!${NC}"
echo ""

echo -e "  ${BOLD}Services:${NC}"
echo -e "    Proxy:     ${BLUE}http://localhost:8080${NC}     (AI API endpoint)"
echo -e "    AgentGate: ${BLUE}http://localhost:8081${NC}     (policy engine)"
if [ "$MODE" = "opencode" ]; then
    echo -e "    LiteLLM:   ${BLUE}http://localhost:4000${NC}     (format translation)"
fi
echo ""

echo -e "  ${BOLD}Mode:${NC} ${MODE^}"
echo ""

if [ "$MODE" = "opencode" ]; then
    echo -e "  ${BOLD}To start chatting:${NC}"
    echo -e "    opencode"
    echo ""
    echo -e "  ${BOLD}Test the proxy directly:${NC}"
    echo -e '    curl -X POST http://localhost:8080/v1/messages \'
    echo -e '      -H "Content-Type: application/json" \'
    echo -e '      -H "x-api-key: test-key" \'
    echo -e '      -d '\''{"model":"deepseek-v4-flash-free","max_tokens":50,"messages":[{"role":"user","content":"Hello"}]}'\'
    echo ""
fi

echo -e "  ${BOLD}Management commands:${NC}"
echo -e "    View logs:     ${YELLOW}docker compose logs -f${NC}"
echo -e "    Stop:          ${YELLOW}docker compose down${NC}"
echo -e "    Restart:       ${YELLOW}docker compose up -d${NC}"
echo -e "    Rebuild:       ${YELLOW}docker compose up -d --build${NC}"
echo ""

echo -e "  ${BOLD}Configuration files:${NC}"
echo -e "    .env                     — environment variables (${YELLOW}contains secrets${NC})"
echo -e "    config.json              — AgentGate policy engine config"
echo -e "    litellm-config.yaml      — LiteLLM routing rules (${YELLOW}contains secrets${NC})"
echo -e "    keys/private.pem         — RSA private key (${YELLOW}contains secrets${NC})"
echo ""

echo -e "  ${BOLD}Switch modes (after stopping containers):${NC}"
echo -e "    ${YELLOW}sudo ./switch.sh opencode${NC}   → OpenCode mode"
echo -e "    ${YELLOW}sudo ./switch.sh claude${NC}     → Claude Code mode"
echo ""

echo -e "  ${BOLD}${GREEN}Enjoy your AI coding assistant!${NC}"
echo ""
