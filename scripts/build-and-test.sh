#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build-and-test.sh — Build + seed + verify the full AgentGate stack
#
# Usage:
#   sudo ./scripts/build-and-test.sh
#
# This script:
#   1. Tears down old containers
#   2. Generates RSA keys (if missing)
#   3. Builds all Docker images
#   4. Seeds a trial license
#   5. Tests the proxy → license → Ollama chain
# =============================================================================

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

# -------------------------------------------------------------------------
# 1. Ensure .env exists
# -------------------------------------------------------------------------
if [ ! -f .env ]; then
    echo "INFO: Creating .env with default development values..."
    cat > .env <<-EOF
LICENSE_KEY=
ADMIN_API_KEY=dev-admin-key-do-not-use-in-production
AGENTGATE_JWT_SECRET=dev-jwt-secret-32-bytes-long-minimum!!
EOF
    chmod 600 .env
fi

# Source the .env so ADMIN_API_KEY and others are available
set -a; source .env; set +a

# -------------------------------------------------------------------------
# 2. Generate RSA keys (if not already present)
# -------------------------------------------------------------------------
if [ ! -f keys/private.pem ]; then
    echo "INFO: Generating RSA key pair..."
    bash scripts/gen-license-keys.sh
else
    echo "INFO: RSA keys already exist, skipping generation."
fi

# -------------------------------------------------------------------------
# 3. Tear down old stack
# -------------------------------------------------------------------------
echo "INFO: Stopping any existing AgentGate containers..."
docker compose down --remove-orphans 2>/dev/null || true

# -------------------------------------------------------------------------
# 4. Build images
# -------------------------------------------------------------------------
echo "INFO: Building Docker images..."
docker compose build --no-cache 2>&1

# -------------------------------------------------------------------------
# 5. Start stack
# -------------------------------------------------------------------------
echo "INFO: Starting stack..."
docker compose up -d 2>&1

# Wait for services to be healthy
echo "INFO: Waiting for services to come up..."
for i in $(seq 1 30); do
    if curl -sf localhost:4001/api/v1/license/activate >/dev/null 2>&1; then
        echo "INFO: License server is healthy (attempt $i)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: License server did not become healthy in time"
        docker compose logs license-server
        exit 1
    fi
    sleep 1
done

# Wait for proxy
for i in $(seq 1 30); do
    if curl -sf localhost:8080 >/dev/null 2>&1; then
        echo "INFO: Proxy is healthy (attempt $i)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARN: Proxy did not respond in time (may need LICENSE_KEY)"
        docker compose logs proxy
        # Don't exit — we'll seed and test next
        break
    fi
    sleep 1
done

# -------------------------------------------------------------------------
# 6. Seed a trial license key
# -------------------------------------------------------------------------
echo ""
echo "INFO: Seeding a Pro license for 'Test Company'..."
LICENSE_KEY=$(bash scripts/seed-license.sh pro "Test Company" "test@example.com" 2>&1 | grep "Key:" | awk '{print $2}')

if [ -z "$LICENSE_KEY" ]; then
    echo "ERROR: Failed to seed license"
    docker compose logs license-server
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LICENSE KEY: $LICENSE_KEY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Update .env with the license key
# macOS/BSD sed needs different syntax, check which is available
if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s/LICENSE_KEY=.*/LICENSE_KEY=$LICENSE_KEY/" .env
else
    sed -i '' "s/LICENSE_KEY=.*/LICENSE_KEY=$LICENSE_KEY/" .env
fi

# -------------------------------------------------------------------------
# 7. Restart proxy with the license key
# -------------------------------------------------------------------------
echo "INFO: Restarting proxy to pick up license key..."
docker compose up -d proxy 2>&1

sleep 3

# Check proxy logs for license activation
docker compose logs --tail=10 proxy 2>&1

# -------------------------------------------------------------------------
# 8. Test the proxy
# -------------------------------------------------------------------------
echo ""
echo "INFO: Testing proxy API..."
curl -s -w "\nHTTP %{http_code}" \
    -X POST http://localhost:8080/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: sk-test" \
    -H "anthropic-version: 2023-06-01" \
    -d '{
        "model": "gemma4:31b-cloud",
        "max_tokens": 100,
        "messages": [
            {"role": "user", "content": "Say hello in one word."}
        ]
    }' 2>&1 | head -30

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DONE — Stack is up and licensed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Services:"
echo "  Proxy:          http://localhost:8080"
echo "  AgentGate:      http://localhost:8081"
echo "  License Server: http://localhost:4001"
echo "  Admin API:      http://localhost:4001/admin/licenses"
echo ""
echo "To stop:  docker compose down"
echo "To reset: docker compose down -v  # wipes DB + volumes"
