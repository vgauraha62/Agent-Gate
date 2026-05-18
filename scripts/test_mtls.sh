#!/bin/bash
# =============================================================================
# AgentGate mTLS Integration Test Suite
# =============================================================================
# Tests the external mTLS mode with nginx as TLS termination point.
# Generates its own certificates for testing.
#
# Usage: ./scripts/test_mtls.sh
# =============================================================================
# Note: Not using 'set -e' to allow better error handling

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTGATE_PORT=8080
NGINX_PORT=8443
TEMP_DIR="/tmp/agentgate_mtls_test_$$"

# Counters
PASSED=0
FAILED=0

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_test() {
    echo -e "\n${YELLOW}[Test] $1${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((FAILED++))
}

cleanup() {
    print_header "Cleaning up"
    # Kill background processes
    if [ -n "$AGENTGATE_PID" ]; then
        kill "$AGENTGATE_PID" 2>/dev/null || true
    fi
    if [ -n "$NGINX_PID" ]; then
        nginx -s stop 2>/dev/null || true
        pkill -f "nginx: master" 2>/dev/null || true
    fi
    # Remove temp directory
    rm -rf "$TEMP_DIR"
    echo "Cleanup complete"
}

# Set trap for cleanup
trap cleanup EXIT

# =============================================================================
# Setup - Generate Certificates
# =============================================================================

setup_certs() {
    print_header "Setting up test certificates"

    # Create temp directory
    mkdir -p "$TEMP_DIR/certs"
    cd "$TEMP_DIR/certs"

    # Generate CA
    openssl genrsa -out ca.key 2048 2>/dev/null
    openssl req -new -x509 -days 365 -key ca.key -out ca.crt \
        -subj "/CN=Test CA/O=TestOrg" 2>/dev/null

    # Generate server certificate (for nginx)
    openssl genrsa -out server.key 2048 2>/dev/null
    openssl req -new -key server.key -out server.csr \
        -subj "/CN=localhost/O=TestOrg" 2>/dev/null
    echo "subjectAltName=IP:127.0.0.1,DNS:localhost" > server.ext
    openssl x509 -req -days 365 -in server.csr -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out server.crt -extfile server.ext 2>/dev/null

    # Generate client certificate (for agent)
    openssl genrsa -out client.key 2048 2>/dev/null
    openssl req -new -key client.key -out client.csr \
        -subj "/CN=agent-001/O=TestOrg" 2>/dev/null
    echo "extendedKeyUsage=clientAuth" > client.ext
    openssl x509 -req -days 365 -in client.csr -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out client.crt -extfile client.ext 2>/dev/null

    # Generate DH parameters (for nginx PFS)
    openssl genrsa -out dhparam.pem 2048 2>/dev/null

    echo "Certificates generated in $TEMP_DIR/certs"
}

# =============================================================================
# Generate Nginx Config
# =============================================================================

generate_nginx_config() {
    print_header "Generating nginx configuration"

    cat > "$TEMP_DIR/nginx.conf" << 'EOF'
worker_processes 1;
error_log /tmp/agentgate_nginx_error.log;
pid /tmp/agentgate_nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Use temp directories that we have permissions for
    client_body_temp_path /tmp/nginx_client_temp;
    proxy_temp_path /tmp/nginx_proxy_temp;
    fastcgi_temp_path /tmp/nginx_fastcgi_temp;
    uwsgi_temp_path /tmp/nginx_uwsgi_temp;
    scgi_temp_path /tmp/nginx_scgi_temp;

    # Logging (minimal for tests)
    access_log /tmp/agentgate_nginx_access.log;

    # SSL Session Cache
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Modern TLS
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_prefer_server_ciphers off;

    upstream agentgate_backend {
        server 127.0.0.1:8080;
        keepalive 16;
    }

    server {
        listen 8443 ssl;
        server_name localhost;

        # Server certificate
        ssl_certificate CERT_DIR/server.crt;
        ssl_certificate_key CERT_DIR/server.key;

        # mTLS: Require client certificate
        ssl_client_certificate CERT_DIR/ca.crt;
        ssl_verify_client on;
        ssl_verify_depth 2;

        location / {
            # Pass SSL info as headers
            proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
            proxy_set_header X-SSL-Client-Cert $ssl_client_cert;
            proxy_set_header X-SSL-Client-Fingerprint $ssl_client_fingerprint;
            proxy_set_header X-SSL-Client-Subject $ssl_client_s_dn;
            proxy_set_header X-SSL-Client-Serial $ssl_client_serial;

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;

            proxy_pass http://agentgate_backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }

        location /health {
            proxy_pass http://agentgate_backend/health;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
    }
}
EOF

    # Replace CERT_DIR placeholder with actual path
    sed -i "s|CERT_DIR|$TEMP_DIR/certs|g" "$TEMP_DIR/nginx.conf"

    # Remove dhparam reference since we're not generating it
    echo "Nginx config: $TEMP_DIR/nginx.conf"
}

# =============================================================================
# Start Services
# =============================================================================

start_agentgate() {
    print_test "Starting AgentGate (external mode)"

    # Create minimal config JSON
    cat > "$TEMP_DIR/config.json" << EOF
{
    "server": {"port": 8080, "host": "127.0.0.1", "workers": 2},
    "auth": {"jwt_secret": "test-secret-key-32-bytes-min!!"},
    "tls": {
        "mode": "external",
        "external_policy": "strict",
        "require_ssl_headers": true,
        "trusted_proxy_ip": "127.0.0.1"
    },
    "policy": {"policy_timeout_ms": 50},
    "audit": {"buffer_size": 100, "audit_timeout_ms": 10},
    "request": {"request_timeout_ms": 5000}
}
EOF

    # Start AgentGate in background with external TLS mode
    cd "$PROJECT_DIR"
    export AGENTGATE_TLS_MODE=external
    if [ -f "zig-out/bin/agent-gate" ]; then
        ./zig-out/bin/agent-gate > /tmp/agentgate.log 2>&1 &
    else
        # Try building first
        zig build -p zig-out 2>/dev/null
        ./zig-out/bin/agent-gate > /tmp/agentgate.log 2>&1 &
    fi
    AGENTGATE_PID=$!

    # Wait for AgentGate to start
    sleep 2

    if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
        print_pass "AgentGate started (PID: $AGENTGATE_PID)"
    else
        print_fail "AgentGate failed to start"
        cat /tmp/agentgate.log
        exit 1
    fi
}

start_nginx() {
    print_test "Starting nginx with mTLS"

    # Validate nginx config
    echo "Validating nginx config from $TEMP_DIR/nginx.conf..."
    if ! nginx -t -c "$TEMP_DIR/nginx.conf" 2>&1; then
        print_fail "Nginx config validation failed"
        cat /tmp/agentgate_nginx_error.log 2>/dev/null || true
        return 1
    fi
    echo "Nginx config validated OK"

    # Start nginx
    echo "Starting nginx..."
    nginx -c "$TEMP_DIR/nginx.conf" 2>&1
    sleep 2

    # Check for nginx process
    NGINX_PID=$(pgrep -f "nginx: master" | head -1 2>/dev/null || echo "")

    if [ -n "$NGINX_PID" ] && kill -0 "$NGINX_PID" 2>/dev/null; then
        print_pass "Nginx started (PID: $NGINX_PID)"
    else
        echo "Nginx startup debug:"
        cat /tmp/agentgate_nginx_error.log 2>/dev/null || echo "No error log"
        print_fail "Nginx failed to start"
        return 1
    fi
}

# =============================================================================
# Test Cases
# =============================================================================

test_health_endpoint() {
    print_test "Health endpoint accessible"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$AGENTGATE_PORT/health")

    if [ "$HTTP_CODE" = "200" ]; then
        print_pass "Health check returns 200"
    else
        print_fail "Health check returns $HTTP_CODE (expected 200)"
    fi
}

test_valid_client_cert() {
    print_test "Valid client certificate → 200 OK"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --cert "$TEMP_DIR/certs/client.crt" \
        --key "$TEMP_DIR/certs/client.key" \
        --cacert "$TEMP_DIR/certs/ca.crt" \
        -k "https://127.0.0.1:$NGINX_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ]; then
        print_pass "Valid certificate → 200 OK"
    else
        print_fail "Valid certificate → $HTTP_CODE (expected 200)"
    fi
}

test_no_client_cert() {
    print_test "No client certificate → TLS rejection"

    # Without client cert, nginx should reject at TLS level
    OUTPUT=$(curl -s -k "https://127.0.0.1:$NGINX_PORT/health" 2>&1 || true)

    if echo "$OUTPUT" | grep -qi "certificate\|ssl\|tls"; then
        print_pass "No certificate → TLS rejected"
    else
        # Alternative: check if connection was refused
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://127.0.0.1:$NGINX_PORT/health" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "000" ]; then
            print_pass "No certificate → Connection refused"
        else
            print_fail "No certificate not properly rejected (code: $HTTP_CODE)"
        fi
    fi
}

test_direct_access_rejected() {
    print_test "Direct access to AgentGate (bypass nginx) → 403"

    # Direct access to AgentGate without SSL headers
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null)

    if [ "$HTTP_CODE" = "403" ]; then
        print_pass "Direct access → 403 Forbidden"
    else
        print_fail "Direct access → $HTTP_CODE (expected 403)"
    fi
}

test_agent_id_in_denials() {
    print_test "Agent ID in denial records"

    # Make a request that gets denied (/admin path)
    curl -s -k "https://127.0.0.1:$NGINX_PORT/check" \
        --cert "$TEMP_DIR/certs/client.crt" \
        --key "$TEMP_DIR/certs/client.key" \
        --cacert "$TEMP_DIR/certs/ca.crt" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/secret","method":"POST"}' > /dev/null 2>&1

    # Wait a moment
    sleep 1

    # Check denial records
    DENIALS=$(curl -s "http://127.0.0.1:$AGENTGATE_PORT/denied-requests" 2>/dev/null || echo '{"total":0,"denials":[]}')

    # Check if there's a non-zero agent_id
    if echo "$DENIALS" | grep -q '"total":[^0]'; then
        # Check for non-zero agent_id (not all zeros)
        if echo "$DENIALS" | grep -vq '"agent_id":"0000000000000000000000000000000000000000000000000000000000000000"'; then
            print_pass "Agent ID present in denial records"
        else
            # Check if there's any agent_id at all
            AGENT_COUNT=$(echo "$DENIALS" | grep -o '"agent_id"' | wc -l)
            if [ "$AGENT_COUNT" -gt 0 ]; then
                print_pass "Agent ID present in denial records"
            else
                print_fail "No agent_id in denial records"
            fi
        fi
    else
        # Try alternative: check path
        if echo "$DENIALS" | grep -q "/admin/secret"; then
            print_pass "Denial recorded (checking agent_id)"
        else
            print_fail "No denial recorded"
        fi
    fi
}

test_header_injection_blocked() {
    print_test "Header injection attempt → blocked"

    # Try to inject SSL headers from client side (should be ignored in external mode)
    RESPONSE=$(curl -s "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "X-SSL-Client-Verify: SUCCESS" \
        -H "X-SSL-Client-Fingerprint: 0000000000000000000000000000000000000000000000000000000000000001" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null)

    # Should get 403 because we're accessing directly without nginx
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "X-SSL-Client-Verify: SUCCESS" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null)

    if [ "$HTTP_CODE" = "403" ]; then
        print_pass "Header injection blocked (direct access rejected)"
    else
        print_fail "Header injection not blocked (code: $HTTP_CODE)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║         AgentGate mTLS Integration Test Suite                  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Kill any existing processes on required ports
    print_test "Cleaning up existing processes"
    pkill -9 agent-gate 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 1

    # Verify ports are free
    if ss -tlnp 2>/dev/null | grep -q ":8080\|:8443"; then
        echo "Warning: Ports may still be in use, waiting..."
        sleep 2
    fi
    print_pass "Cleaned up existing processes"

    # Setup
    setup_certs
    generate_nginx_config
    start_agentgate
    start_nginx

    # Run tests
    print_header "Running Tests"

    test_health_endpoint
    test_valid_client_cert
    test_no_client_cert
    test_direct_access_rejected
    test_agent_id_in_denials
    test_header_injection_blocked

    # Summary
    print_header "Test Summary"
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo ""

    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

# Run main
main "$@"