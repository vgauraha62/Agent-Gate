#!/bin/bash
# =============================================================================
# JWT Helper — HS256 JWT generator for AgentGate test suite
# =============================================================================
# Generates HS256-signed JWTs that AgentGate can validate.
# Used by test_jwt_ssl_conflict to test SSL header vs JWT precedence.
#
# Usage:
#   source scripts/jwt_helper.sh
#   JWT=$(generate_jwt "agent-1" "production-mirror-test-secret-32!")
#
# Or standalone:
#   ./scripts/jwt_helper.sh "agent-1" "production-mirror-test-secret-32!"
# =============================================================================

set -euo pipefail

# Base64url encoding (no padding, URL-safe characters)
base64url() {
    local data="$1"
    printf '%s' "$data" | base64 -w 0 | tr '+/' '-_' | tr -d '='
}

# Generate HS256 JWT
# Args: subject claim, secret key
generate_jwt() {
    local subject="${1:-agent-1}"
    local secret="${2:-}"

    if [[ -z "$secret" ]]; then
        echo "ERROR: secret is required" >&2
        return 1
    fi

    local now
    now=$(date +%s)
    local exp=$((now + 3600))  # 1 hour expiry

    # JWT Header (HS256)
    local header='{"alg":"HS256","typ":"JWT"}'
    local header_b64
    header_b64=$(base64url "$header")

    # JWT Payload
    local payload="{\"sub\":\"${subject}\",\"exp\":${exp},\"iat\":${now}}"
    local payload_b64
    payload_b64=$(base64url "$payload")

    # Signing input
    local sign_input="${header_b64}.${payload_b64}"

    # HMAC-SHA256 signature using openssl
    # hexkey must be a hex string, so convert secret using od
    local hex_secret
    hex_secret=$(printf '%s' "$secret" | od -A n -t x1 | tr -d ' \n')
    local signature
    signature=$(printf '%s' "$sign_input" | openssl dgst -sha256 \
        -mac HMAC -macopt "hexkey:${hex_secret}" -binary 2>/dev/null)

    if [[ -z "$signature" ]]; then
        echo "ERROR: failed to generate signature" >&2
        return 1
    fi

    local signature_b64
    signature_b64=$(printf '%s' "$signature" | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    # Final JWT
    printf '%s.%s.%s' "$header_b64" "$payload_b64" "$signature_b64"
}

# If called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <subject> <secret>" >&2
        echo "Example: $0 agent-1 'production-mirror-test-secret-32!'" >&2
        exit 1
    fi
    generate_jwt "$1" "$2"
fi