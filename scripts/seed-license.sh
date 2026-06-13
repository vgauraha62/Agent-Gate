#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# seed-license.sh — Insert a license key into the license server database
#
# Usage:
#   ./scripts/seed-license.sh <tier> [customer_name] [customer_email]
#
# Examples:
#   ./scripts/seed-license.sh pro "Acme Corp" "admin@acme.com"
#   ./scripts/seed-license.sh free "Trial User"  # 14-day trial
#   ./scripts/seed-license.sh enterprise "BigCo"
#
# Requires:
#   - Docker container running (license-server must be up)
#   - ADMIN_API_KEY set in environment or docker-compose
# =============================================================================

TIER="${1:-}"
CUSTOMER_NAME="${2:-Unknown}"
CUSTOMER_EMAIL="${3:-}"

if [ -z "$TIER" ]; then
    echo "Usage: $0 <tier> [customer_name] [customer_email]"
    echo "  tier: free, starter, pro, enterprise"
    exit 1
fi

case "$TIER" in
    free|starter|pro|enterprise) ;;
    *) echo "Invalid tier: $TIER (must be: free, starter, pro, enterprise)"; exit 1 ;;
esac

ADMIN_KEY="${ADMIN_API_KEY:-change-me-in-production}"
URL="http://localhost:4001/admin/licenses"

echo "🌱 Seeding license: tier=$TIER customer=$CUSTOMER_NAME"

# Determine max_requests and max_agents based on tier
case "$TIER" in
    free)       MAX_REQ=100;   MAX_AGENTS=1 ;;
    starter)    MAX_REQ=1000;  MAX_AGENTS=5 ;;
    pro)        MAX_REQ=10000; MAX_AGENTS=20 ;;
    enterprise) MAX_REQ=-1;    MAX_AGENTS=-1 ;;
esac

# Build JSON payload
JSON=$(cat <<EOF
{
    "tier": "$TIER",
    "max_requests": $MAX_REQ,
    "max_agents": $MAX_AGENTS,
    "customer_name": "$CUSTOMER_NAME",
    "customer_email": "$CUSTOMER_EMAIL"
}
EOF
)

# Send request
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Key: $ADMIN_KEY" \
    -d "$JSON")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "201" ]; then
    LICENSE_KEY=$(echo "$BODY" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
    echo "✅ License created!"
    echo "   Key: $LICENSE_KEY"
    echo ""
    echo "   Set this as AGENTGATE_PROXY_LICENSE_KEY or LICENSE_KEY to activate."
else
    echo "❌ Failed (HTTP $HTTP_CODE):"
    echo "$BODY"
    exit 1
fi
