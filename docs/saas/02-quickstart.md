---
title: Quickstart
nav_order: 2
---

# Quickstart

Get AgentGate Cage running on a new machine in under 5 minutes.

## Prerequisites

- A Linux machine (x86_64 recommended)
- Internet connection (to pull Docker images)
- Your Zen API key from [opencode.ai](https://opencode.ai)

## Option 1: One-Command Setup (Recommended)

```bash
# Extract the portable package
tar xzf agent-gate-portable.tar.gz
cd agent-gate-portable

# Run the setup script — it handles everything
sudo ./setup.sh
```

The script will:
1. Install Docker + Docker Compose + curl + openssl (if missing)
2. Ask which mode (OpenCode or Claude Code)
3. Prompt for your API keys
4. Generate configs with your secrets
5. Build and start all Docker containers
6. Configure OpenCode CLI
7. Print a success summary

## Option 2: Manual Setup

### Step 1: Install Prerequisites

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y docker.io docker-compose-v2 curl openssl
sudo systemctl enable docker
sudo systemctl start docker

# Fedora/RHEL
sudo dnf install -y docker docker-compose-plugin curl openssl
sudo systemctl enable docker
sudo systemctl start docker
```

### Step 2: Prepare Configs

```bash
# Copy environment template
cp env/.env.opencode.template .env

# Edit .env to set your JWT secret (or use the auto-generated one)
# AGENTGATE_JWT_SECRET=your-secret-here

# Copy and edit LiteLLM config with your Zen API key
cp config/litellm-config.yaml litellm-config.yaml
# Edit: replace YOUR_ZEN_API_KEY_HERE with your actual key

# Copy mode-specific config
cp config/config.opencode.json config.json
```

### Step 3: Generate RSA Keys

```bash
mkdir -p keys
openssl genrsa -out keys/private.pem 2048
openssl rsa -in keys/private.pem -pubout -out keys/public.pem
chmod 600 keys/private.pem
```

### Step 4: Build and Start

```bash
sudo docker compose up -d --build
```

### Step 5: Verify Health

```bash
# Check all services are healthy
curl http://localhost:8081/health   # AgentGate policy engine
curl http://localhost:8080/health   # Proxy
curl http://localhost:4000/health   # LiteLLM
```

All three should return `200 OK`.

### Step 6: Configure Your Client

**OpenCode:**
```bash
# setup.sh can do this automatically, or create manually:
mkdir -p ~/.config/opencode
cat > ~/.config/opencode/opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "agentgate/deepseek-v4-flash-free",
  "provider": {
    "agentgate": {
      "name": "AgentGate Proxy",
      "options": {
        "baseURL": "http://localhost:8080",
        "apiKey": "test-key"
      }
    }
  }
}
EOF
```

**Claude Code:**
```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
claude
```

## Test the Setup

Send a test request through the proxy:

```bash
curl -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test-key" \
  -d '{
    "model": "deepseek-v4-flash-free",
    "max_tokens": 50,
    "messages": [
      {"role": "user", "content": "Say hello"}
    ]
  }'
```

You should get a response from the AI model.

## What's Next?

- [**Architecture**](03-architecture.md) — Understand how it works under the hood
- [**Policies**](06-policies.md) — Customize security rules
- [**Configuration**](05-configuration.md) — All configuration options
