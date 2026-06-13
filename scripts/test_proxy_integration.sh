#!/bin/bash
# ============================================================================
# AgentGate Cage — Integration Test Script
# ============================================================================
# Tests the full Go proxy + Zig AgentGate integration using Docker Compose.
# Verifies that tool invocations are properly evaluated against policies.
#
# Prerequisites: Docker, Docker Compose, curl, jq (optional)
#
# Usage:
#   ./scripts/test_proxy_integration.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

# ============================================================================
# Helper functions
# ============================================================================

check_deps() {
    local missing=0
    for cmd in docker curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "  ${RED}✗${NC} Missing: $cmd"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "${RED}Please install missing dependencies.${NC}"
        exit 1
    fi
}

assert() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        echo "  ${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo "  ${RED}✗${NC} $name"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1"
    local needle="$2"
    local haystack="$3"

    if echo "$haystack" | grep -q "$needle"; then
        echo "  ${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo "  ${RED}✗${NC} $name"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Main
# ============================================================================

echo "═══════════════════════════════════════════════"
echo "  AgentGate Cage — Integration Test Suite"
echo "═══════════════════════════════════════════════"
echo ""

# Step 1: Check dependencies
echo "--- Step 1: Checking dependencies ---"
check_deps
echo ""

# Step 2: Start services
echo "--- Step 2: Starting services ---"
export AGENTGATE_JWT_SECRET="test-integration-secret-32bytes!"
docker compose up -d --build 2>&1 | tail -5 || {
    echo "${RED}Failed to start services${NC}"
    exit 1
}

# Wait for services to be healthy
echo "  Waiting for services..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8080/health >/dev/null 2>&1 && \
       curl -sf http://localhost:8081/health >/dev/null 2>&1; then
        echo "  ${GREEN}✓${NC} Both services healthy after ${i}s"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "  ${RED}✗${NC} Services did not become healthy"
        docker compose logs --tail=20 proxy agentgate
        docker compose down
        exit 1
    fi
    sleep 1
done
echo ""

# Step 3: Test health endpoints
echo "--- Step 3: Health endpoints ---"

PROXY_HEALTH=$(curl -sf http://localhost:8080/health)
assert "Proxy /health returns OK" "OK" "$PROXY_HEALTH"

AG_HEALTH=$(curl -sf http://localhost:8081/health)
assert "AgentGate /health returns OK" "OK" "$AG_HEALTH"
echo ""

# Step 4: Test AgentGate /check directly (tool-aware format)
echo "--- Step 4: AgentGate /check (direct) ---"

# Test: allowed bash command
ALLOW_RESP=$(curl -sf -X POST http://localhost:8081/check \
    -H "Content-Type: application/json" \
    -d '{"tool":"bash","command":"ls","path":"/workspace"}')
assert_contains "Allowed bash contains allowed:true" '"allowed":true' "$ALLOW_RESP"

# Test: denied rm -rf
DENY_RM=$(curl -s -X POST http://localhost:8081/check \
    -H "Content-Type: application/json" \
    -d '{"tool":"bash","command":"rm -rf /"}')
assert_contains "Denied rm -rf contains allowed:false" '"allowed":false' "$DENY_RM"
assert_contains "Denied rm -rf contains policy_id" '"policy_id"' "$DENY_RM"

# Test: denied /etc/passwd access
DENY_PASSWD=$(curl -s -X POST http://localhost:8081/check \
    -H "Content-Type: application/json" \
    -d '{"tool":"bash","command":"cat /etc/passwd"}')
assert_contains "Denied /etc/passwd contains allowed:false" '"allowed":false' "$DENY_PASSWD"

# Test: allowed read within workspace
ALLOW_READ=$(curl -sf -X POST http://localhost:8081/check \
    -H "Content-Type: application/json" \
    -d '{"tool":"read","path":"/workspace/main.go"}')
assert_contains "Allowed read in workspace" '"allowed":true' "$ALLOW_READ"

# Test: denied read outside workspace (legacy format)
DENY_READ_ETC=$(curl -s -X POST http://localhost:8081/check \
    -H "Content-Type: application/json" \
    -d '{"tool":"read","path":"/etc/passwd"}')
assert_contains "Denied read /etc/passwd" '"allowed":false' "$DENY_READ_ETC"

echo ""

# Step 5: Test via Go proxy (mock direct /v1/messages)
echo "--- Step 5: Go proxy /v1/messages ---"

# The proxy requires a real x-api-key. We use a test key here.
# Since there's no actual upstream, the request will fail at the upstream call,
# but the policy check should work correctly first.
# We use a key that will trigger a check.

echo "  ${YELLOW}⚡ Note: /v1/messages requires a valid Anthropic key for upstream forwarding.${NC}"
echo "  ${YELLOW}⚡ Policy checks happen before upstream call.${NC}"
echo ""

# Step 6: Test metrics endpoint
echo "--- Step 6: Metrics ---"

METRICS=$(curl -sf http://localhost:8081/metrics)
assert_contains "Metrics endpoint responds" "requests_total" "$METRICS"
echo ""

# Step 7: Test denied-requests endpoint
echo "--- Step 7: Denied requests ---"

DENIED=$(curl -sf http://localhost:8081/denied-requests)
assert_contains "Denied requests returns JSON" '"denials"' "$DENIED"
echo ""

# Step 8: Cleanup
echo "--- Step 8: Cleanup ---"
docker compose down 2>&1 | tail -3
echo ""

# Summary
echo "═══════════════════════════════════════════════"
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "═══════════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
