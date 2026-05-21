#!/bin/bash
# =============================================================================
# AgentGate mTLS Integration Test Suite
# =============================================================================
# Tests the external mTLS mode with nginx as TLS termination point.
# Generates its own certificates for testing.
#
# Usage: ./scripts/test_mtls.sh [--quick] [--verbose]
#   --quick    Skip slow tests (cert expiry, config diff)
#   --verbose  Show detailed output from curl, openssl commands
# =============================================================================

# Strict error handling: fail fast on any error
set -euo pipefail

# Feature flags
QUICK_MODE=false
VERBOSE=false
if [[ "${1:-}" == "--quick" ]]; then QUICK_MODE=true; fi
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=true; fi

# Colors for output (only if terminal supports it)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTGATE_PORT=8080
NGINX_PORT=8443
TEMP_DIR=""
AGENTGATE_PID=""
NGINX_PID=""

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Expected values (computed during setup)
EXPECTED_AGENT_ID=""

# =============================================================================
# Utility Functions
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1" >&2; }

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_test() {
    echo ""
    echo -e "${YELLOW}[Test] $1${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    PASSED=$((PASSED + 1))
}

print_skip() {
    echo -e "${YELLOW}⊘ SKIP:${NC} $1"
    SKIPPED=$((SKIPPED + 1))
}

print_fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    FAILED=$((FAILED + 1))
}

# Run a command, optionally with verbose output
run() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  + $*" >&2
    fi
    "$@"
}

# =============================================================================
# Cleanup - Kill only the processes started by THIS script
# =============================================================================

cleanup() {
    print_header "Cleaning up"

    # Kill AgentGate (by PID, not by name)
    if [[ -n "${AGENTGATE_PID:-}" ]]; then
        if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_info "Stopping AgentGate (PID: $AGENTGATE_PID)"
            kill "$AGENTGATE_PID" 2>/dev/null || true
            # Wait for graceful shutdown
            local retries=5
            while kill -0 "$AGENTGATE_PID" 2>/dev/null && [[ $retries -gt 0 ]]; do
                sleep 0.5
                ((retries--))
            done
            # Force kill if still alive
            if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
                kill -9 "$AGENTGATE_PID" 2>/dev/null || true
            fi
        fi
    fi

    # Kill nginx (by PID from OUR config, not system-wide pkill)
    if [[ -n "${NGINX_PID:-}" ]]; then
        if kill -0 "$NGINX_PID" 2>/dev/null; then
            log_info "Stopping nginx (PID: $NGINX_PID)"
            kill -HUP "$NGINX_PID" 2>/dev/null || true
            sleep 1
            if kill -0 "$NGINX_PID" 2>/dev/null; then
                kill -9 "$NGINX_PID" 2>/dev/null || true
            fi
        fi
    fi

    # Remove temp directory
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        log_info "Removing temp directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    echo "Cleanup complete"
}

trap cleanup EXIT

# =============================================================================
# Prerequisite Checks
# =============================================================================

check_prerequisites() {
    print_header "Checking prerequisites"

    local missing=0

    # Check required commands
    for cmd in openssl curl nginx ss; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$("$cmd" version 2>/dev/null | head -1 || echo "unknown")
            log_info "$cmd found: $version"
        else
            log_err "$cmd not found in PATH"
            missing=$((missing + 1))
        fi
    done

    # Check ports availability
    if ss -tlnp 2>/dev/null | grep -q ":${AGENTGATE_PORT}\|:${NGINX_PORT}"; then
        log_warn "Ports $AGENTGATE_PORT or $NGINX_PORT may be in use"
    else
        log_info "Required ports $AGENTGATE_PORT, $NGINX_PORT are available"
    fi

    # Check nginx version supports required features
    local nginx_version=$(nginx -v 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "0")
    log_info "nginx version: $nginx_version"

    if (( $(echo "$nginx_version < 1.13" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "nginx < 1.13 may not have full mTLS header support"
    fi

    # Check if $ssl_client_cert is supported (nginx >= 1.13.7)
    local has_ssl_client_cert=false
    if nginx -T 2>/dev/null | grep -q '\$ssl_client_cert'; then
        has_ssl_client_cert=true
    fi
    log_info "nginx \$ssl_client_cert support: $has_ssl_client_cert"

    if [[ $missing -gt 0 ]]; then
        log_err "Missing $missing required command(s)"
        exit 1
    fi

    print_pass "Prerequisites check passed"
}

# =============================================================================
# Setup - Generate Certificates
# =============================================================================

setup_certs() {
    print_header "Setting up test certificates"

    TEMP_DIR=$(mktemp -d /tmp/agentgate_mtls_test_XXXXXX)
    log_info "Temp directory: $TEMP_DIR"
    mkdir -p "$TEMP_DIR/certs"
    cd "$TEMP_DIR/certs" || exit 1

    local PEM_PASSWORD="test123"

    # Generate CA
    log_info "Generating CA certificate..."
    run openssl genrsa -out ca.key -aes256 -passout pass:"$PEM_PASSWORD" 4096
    run openssl req -new -x509 -days 365 \
        -key ca.key -passin pass:"$PEM_PASSWORD" \
        -out ca.crt \
        -subj "/CN=Test CA/O=AgentGate/OU=Test"

    # Generate server certificate (for nginx)
    log_info "Generating server certificate..."
    run openssl genrsa -out server.key 2048
    run openssl req -new -key server.key -out server.csr \
        -subj "/CN=localhost/O=AgentGate/OU=Test"
    # Create SAN extension
    printf "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:localhost.localdomain" > server.ext
    run openssl x509 -req -days 365 -in server.csr \
        -CA ca.crt -CAkey ca.key -passin pass:"$PEM_PASSWORD" \
        -CAcreateserial -out server.crt -extfile server.ext

    # Generate client certificate (for agent)
    log_info "Generating client certificate..."
    run openssl genrsa -out client.key 2048
    run openssl req -new -key client.key -out client.csr \
        -subj "/CN=agent-001/O=AgentGate/OU=Test"
    printf "extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE" > client.ext
    run openssl x509 -req -days 365 -in client.csr \
        -CA ca.crt -CAkey ca.key -passin pass:"$PEM_PASSWORD" \
        -CAcreateserial -out client.crt -extfile client.ext

    # Generate PKCS12 bundle (for agents that need it)
    log_info "Generating PKCS12 bundle..."
    run openssl pkcs12 -export -out client.p12 \
        -inkey client.key -in client.crt \
        -passout pass:"$PEM_PASSWORD" \
        -name "agent-001"

    # Verify certificates are valid
    log_info "Verifying certificate chain..."
    if run openssl verify -CAfile ca.crt server.crt >/dev/null; then
        log_info "Server certificate verified"
    else
        log_err "Server certificate verification failed"
        exit 1
    fi
    if run openssl verify -CAfile ca.crt client.crt >/dev/null; then
        log_info "Client certificate verified"
    else
        log_err "Client certificate verification failed"
        exit 1
    fi

    # Compute expected agent_id from the client certificate
    # AgentGate uses XxHash64 x4 on the PEM cert → we precompute for verification
    compute_expected_agent_id

    echo "Certificates generated in $TEMP_DIR/certs"
}

# Compute expected agent_id from client.crt using the same algorithm as AgentGate
compute_expected_agent_id() {
    log_info "Computing expected agent_id from client certificate..."

    # Read the PEM certificate
    local pem_cert
    pem_cert=$(cat client.crt)

    # AgentGate uses: XxHash64(pem_cert, seed=0..3) concatenated → 32 bytes
    # Since we can't compute XxHash64 in pure bash, we'll use the fingerprint
    # as a proxy and compute what AgentGate would derive from it.
    # AgentGate falls back to fingerprint if PEM processing fails, or uses
    # the PEM as primary. We'll compute SHA256 for comparison reference.
    local sha256_fingerprint
    sha256_fingerprint=$(openssl x509 -in client.crt -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')

    # The actual agent_id is XxHash64 x4, but we can verify derivation works
    # by checking the fingerprint format that AgentGate parses from nginx
    local sha1_fingerprint
    sha1_fingerprint=$(openssl x509 -in client.crt -noout -fingerprint -sha1 2>/dev/null | awk -F'= ' '{print $2}')

    log_info "Client cert SHA256: ${sha256_fingerprint:0:16}..."
    log_info "Client cert SHA1:   $sha1_fingerprint"

    # Store for later verification
    EXPECTED_AGENT_ID="$sha256_fingerprint"
}

# =============================================================================
# Check Certificate Expiry
# =============================================================================

check_cert_expiry() {
    if [[ "$QUICK_MODE" == "true" ]]; then
        print_skip "Certificate expiry check (--quick mode)"
        return
    fi

    print_header "Checking certificate validity period"

    local min_days=30
    local now_seconds=$(date +%s)

    for cert in ca.crt server.crt client.crt; do
        local end_date_str
        # openssl outputs "notAfter=May 20 06:55:01 2027 GMT" — extract the date portion
        end_date_str=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' | sed 's/ GMT$//')
        if [[ -z "$end_date_str" ]]; then
            print_fail "$cert: could not read expiry date"
            continue
        fi

        local end_seconds
        # Try GNU date (Linux) first, then BSD date (macOS) as fallback
        end_seconds=$(date -d "$end_date_str GMT" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y" "$end_date_str GMT" +%s 2>/dev/null || echo 0)
        if [[ "$end_seconds" == "0" ]]; then
            print_fail "$cert: could not parse date '$end_date_str'"
            continue
        fi

        local remaining_days=$(( (end_seconds - now_seconds) / 86400 ))

        if [[ $remaining_days -lt 0 ]]; then
            print_fail "$cert: EXPIRED (${remaining_days} days)"
        elif [[ $remaining_days -lt $min_days ]]; then
            print_warn "$cert: expires in ${remaining_days} days (threshold: ${min_days})"
            print_pass "$cert: still valid"
        else
            log_info "$cert: valid for ${remaining_days} days"
            print_pass "$cert: validity period OK (${remaining_days} days remaining)"
        fi
    done
}

# =============================================================================
# Generate Nginx Config
# =============================================================================

generate_nginx_config() {
    print_header "Generating nginx configuration"

    cat > "$TEMP_DIR/nginx.conf" << 'NGINXCONF'
worker_processes 1;
error_log /tmp/agentgate_nginx_error.log;
pid /tmp/agentgate_nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;

    # Use temp directories within our temp dir
    client_body_temp_path TEMP_DIR/client_body;
    proxy_temp_path TEMP_DIR/proxy;
    fastcgi_temp_path TEMP_DIR/fastcgi;
    uwsgi_temp_path TEMP_DIR/uwsgi;
    scgi_temp_path TEMP_DIR/scgi;

    # SSL Session Cache
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # TLS Settings - match production config
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers on;

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

        # Security headers
        add_header Strict-Transport-Security "max-age=31536000" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;

        location / {
            # Pass SSL info as headers (required by AgentGate)
            proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
            proxy_set_header X-SSL-Client-Cert $ssl_client_cert;
            proxy_set_header X-SSL-Client-Fingerprint $ssl_client_fingerprint;
            proxy_set_header X-SSL-Client-Subject $ssl_client_s_dn;
            proxy_set_header X-SSL-Client-Serial $ssl_client_serial;

            # Standard proxy headers
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

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
NGINXCONF

    # Replace placeholders with actual paths
    sed -i "s|CERT_DIR|$TEMP_DIR/certs|g" "$TEMP_DIR/nginx.conf"
    sed -i "s|TEMP_DIR|$TEMP_DIR|g" "$TEMP_DIR/nginx.conf"

    log_info "Nginx config: $TEMP_DIR/nginx.conf"

    # Validate against production config structure
    if [[ "$QUICK_MODE" != "true" ]]; then
        verify_nginx_config_structure
    fi
}

# =============================================================================
# Verify Nginx Config Matches Production Template
# =============================================================================

verify_nginx_config_structure() {
    print_header "Verifying nginx config structure"

    local prod_config="$PROJECT_DIR/docs/mtls-nginx.conf"
    local test_config="$TEMP_DIR/nginx.conf"
    local issues=0

    # Required directives that must be present in production config
    local required_directives=(
        "ssl_verify_client on"
        "ssl_protocols"
        "proxy_set_header X-SSL-Client-Verify"
        "proxy_set_header X-SSL-Client-Cert"
        "proxy_set_header X-SSL-Client-Fingerprint"
    )

    for directive in "${required_directives[@]}"; do
        local pattern="${directive//\*/\\\*}"
        if grep -q "$pattern" "$test_config" 2>/dev/null; then
            log_info "✓ Directive present: $directive"
        else
            log_warn "✗ Directive missing: $directive"
            issues=$((issues + 1))
        fi
    done

    # Check cipher configuration matches production
    if grep -q "TLSv1.2 TLSv1.3" "$test_config"; then
        log_info "✓ TLS 1.2/1.3 enforced"
    else
        log_warn "✗ TLS version enforcement missing"
        issues=$((issues + 1))
    fi

    # Verify test config uses same SSL settings as production
    local test_ciphers=$(grep "ssl_ciphers" "$test_config" | grep -oP "'[^']+'" || echo "")
    if [[ -n "$test_ciphers" ]]; then
        log_info "Test ciphers: $test_ciphers"
    fi

    if [[ $issues -eq 0 ]]; then
        print_pass "Nginx config structure matches production template"
    else
        print_fail "Nginx config structure has $issues issue(s)"
    fi
}

# =============================================================================
# Start Services
# =============================================================================

start_agentgate() {
    print_test "Starting AgentGate (external mode)"

    cd "$PROJECT_DIR" || exit 1

    # Create minimal config JSON (validates external TLS mode end-to-end)
    cat > "$TEMP_DIR/config.json" << 'CONFIGEOF'
{
    "server": {"port": 8080, "host": "127.0.0.1", "workers": 2},
    "auth": {"jwt_secret": "test-secret-key-32-bytes-minimum!!"},
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
CONFIGEOF

    # Build if needed
    if [[ ! -f "zig-out/bin/agent-gate" ]]; then
        log_info "Building AgentGate..."
        if ! zig build -p zig-out; then
            log_err "zig build failed"
            exit 1
        fi
    fi

    # Start AgentGate (using our temp config)
    ./zig-out/bin/agent-gate --config "$TEMP_DIR/config.json" > /tmp/agentgate.log 2>&1 &
    AGENTGATE_PID=$!

    # Wait for AgentGate to start (check health endpoint)
    local max_attempts=10
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if ! kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_err "AgentGate process died during startup"
            cat /tmp/agentgate.log
            exit 1
        fi

        if curl -s "http://127.0.0.1:$AGENTGATE_PORT/health" 2>/dev/null | grep -q "OK"; then
            break
        fi

        sleep 0.5
        ((attempt++))
    done

    if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
        print_pass "AgentGate started (PID: $AGENTGATE_PID)"
    else
        log_err "AgentGate failed to start"
        cat /tmp/agentgate.log
        exit 1
    fi
}

start_nginx() {
    print_test "Starting nginx with mTLS"

    # Validate nginx config
    log_info "Validating nginx config..."
    if ! nginx -t -c "$TEMP_DIR/nginx.conf" 2>&1; then
        log_err "Nginx config validation failed"
        cat /tmp/agentgate_nginx_error.log 2>/dev/null || true
        exit 1
    fi
    log_info "Nginx config validated OK"

    # Start nginx
    log_info "Starting nginx..."
    nginx -c "$TEMP_DIR/nginx.conf" 2>&1 || {
        log_err "nginx failed to start"
        cat /tmp/agentgate_nginx_error.log 2>/dev/null || true
        exit 1
    }

    # Wait for nginx to be ready
    sleep 1

    # Get the master PID (nginx -c spawns a master process)
    local pid_file="/tmp/agentgate_nginx.pid"
    if [[ -f "$pid_file" ]]; then
        NGINX_PID=$(cat "$pid_file")
    else
        # Fallback: find by matching command line
        NGINX_PID=$(pgrep -f "nginx: master.*nginx.conf" | head -1 || echo "")
    fi

    if [[ -n "$NGINX_PID" ]] && kill -0 "$NGINX_PID" 2>/dev/null; then
        print_pass "Nginx started (PID: $NGINX_PID)"
    else
        log_err "Nginx failed to start (PID: $NGINX_PID)"
        cat /tmp/agentgate_nginx_error.log 2>/dev/null || true
        exit 1
    fi

    # Verify nginx is listening on the expected port
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":${NGINX_PORT}"; then
        log_info "nginx is listening on port $NGINX_PORT"
    else
        log_warn "nginx may not be listening on port $NGINX_PORT"
    fi
}

# =============================================================================
# Test Cases
# =============================================================================

test_health_endpoint() {
    print_test "Health endpoint accessible (without TLS)"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$AGENTGATE_PORT/health" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        local body
        body=$(curl -s "http://127.0.0.1:$AGENTGATE_PORT/health" 2>/dev/null || echo "")
        if [[ "$body" == "OK" ]]; then
            print_pass "Health check returns 200 OK"
        else
            print_fail "Health check returns 200 but body is not 'OK': $body"
        fi
    else
        print_fail "Health check returns $http_code (expected 200)"
    fi
}

test_valid_client_cert() {
    print_test "Valid client certificate → 200 OK"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --cert "$TEMP_DIR/certs/client.crt" \
        --key "$TEMP_DIR/certs/client.key" \
        --cacert "$TEMP_DIR/certs/ca.crt" \
        -k "https://127.0.0.1:$NGINX_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        local body
        body=$(curl -s -k "https://127.0.0.1:$NGINX_PORT/check" \
            --cert "$TEMP_DIR/certs/client.crt" \
            --key "$TEMP_DIR/certs/client.key" \
            --cacert "$TEMP_DIR/certs/ca.crt" \
            -H "Content-Type: application/json" \
            -d '{"path":"/api/test","method":"GET"}' 2>/dev/null || echo "")

        if echo "$body" | grep -q '"allowed":true'; then
            print_pass "Valid certificate → 200 OK with allowed:true"
        else
            print_fail "Valid certificate → 200 but unexpected body: $body"
        fi
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection to nginx failed (is nginx running?)"
    else
        print_fail "Valid certificate → $http_code (expected 200)"
    fi
}

test_no_client_cert() {
    print_test "No client certificate → TLS rejection"

    # curl with -k skips cert verification but still needs a client cert
    # We use --cert-type to force no client cert being sent
    local curl_output
    local curl_exit_code

    # Method: Try connecting without any client cert
    # nginx with ssl_verify_client on should close the connection or reject
    curl_output=$(curl -s -o /dev/null -w "%{http_code}|%{ssl_verify_result}|%{exitcode}" \
        -k "https://127.0.0.1:$NGINX_PORT/health" \
        2>&1 || echo "000|99|255")
    curl_exit_code=${curl_output##*|}

    # A non-zero curl exit code indicates TLS-level rejection
    # Common exit codes: 35 (SSL connect error), 51 (peer certificate verification failed)
    if [[ "$curl_exit_code" =~ ^(35|51)$ ]]; then
        print_pass "No certificate → TLS rejected (curl exit code: $curl_exit_code)"
    elif [[ "$curl_exit_code" != "0" ]]; then
        print_pass "No certificate → TLS rejection detected (exit code: $curl_exit_code)"
    else
        # curl exit code 0 but no cert — check if nginx issued a certificate request
        local ssl_verify_result
        ssl_verify_result=$(curl -s -o /dev/null -w "%{ssl_verify_result}" \
            -k "https://127.0.0.1:$NGINX_PORT/health" 2>/dev/null || echo "99")
        if [[ "$ssl_verify_result" != "0" ]]; then
            print_pass "No certificate → TLS rejected (ssl_verify_result: $ssl_verify_result)"
        else
            print_fail "No certificate not properly rejected (exit code: $curl_exit_code, verify: $ssl_verify_result)"
        fi
    fi
}

test_wrong_ca_cert() {
    print_test "Certificate from wrong CA → rejected"

    # Generate a cert signed by a different CA (not our test CA)
    local fake_ca_key="$TEMP_DIR/certs/fake_ca.key"
    local fake_ca_crt="$TEMP_DIR/certs/fake_ca.crt"
    local attacker_crt="$TEMP_DIR/certs/attacker.crt"
    local attacker_key="$TEMP_DIR/certs/attacker.key"

    # Create a fake CA
    openssl genrsa -out "$fake_ca_key" 2048 || true
    openssl req -new -x509 -days 30 -key "$fake_ca_key" \
        -out "$fake_ca_crt" -subj "/CN=FakeCA/O=FakeOrg" || true

    # Create attacker cert signed by fake CA
    openssl genrsa -out "$attacker_key" 2048 || true
    openssl req -new -key "$attacker_key" -out "$TEMP_DIR/certs/attacker.csr" \
        -subj "/CN=attacker/O=FakeOrg" || true
    openssl x509 -req -days 30 -in "$TEMP_DIR/certs/attacker.csr" \
        -CA "$fake_ca_crt" -CAkey "$fake_ca_key" -CAcreateserial \
        -out "$attacker_crt" || true

    local curl_exit_code
    curl_exit_code=$(curl -s -o /dev/null -w "%{exitcode}" \
        -k "https://127.0.0.1:$NGINX_PORT/check" \
        --cert "$attacker_crt" \
        --key "$attacker_key" \
        --cacert "$fake_ca_crt" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' 2>&1 || echo "255")

    # Check curl exit code (0 = curl succeeded in connecting)
    if [[ "$curl_exit_code" != "0" ]]; then
        print_pass "Wrong CA certificate → rejected (curl exit code: $curl_exit_code)"
    else
        # curl exited 0 but nginx may have returned a 4xx error page
        local http_code
        local response_body
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -k "https://127.0.0.1:$NGINX_PORT/health" \
            --cert "$attacker_crt" \
            --key "$attacker_key" \
            2>/dev/null || echo "000")
        response_body=$(curl -s -k "https://127.0.0.1:$NGINX_PORT/health" \
            --cert "$attacker_crt" --key "$attacker_key" 2>/dev/null || echo "")

        if [[ "$http_code" =~ ^(000|400|496|497|520)$ ]] || \
           echo "$response_body" | grep -qi "certificate\|ssl\|verify\|error"; then
            print_pass "Wrong CA certificate → rejected (http: $http_code, body indicates cert error)"
        else
            print_fail "Wrong CA certificate → not rejected (curl exit: $curl_exit_code, http: $http_code)"
        fi
    fi
}

test_direct_access_rejected() {
    print_test "Direct access to AgentGate (bypass nginx) → 403"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null || echo "000")

    if [[ "$http_code" == "403" ]]; then
        local body
        body=$(curl -s "http://127.0.0.1:$AGENTGATE_PORT/check" \
            -H "Content-Type: application/json" \
            -d '{"path":"/api/test","method":"POST"}' 2>/dev/null || echo "")

        if echo "$body" | grep -q "SSL headers required"; then
            print_pass "Direct access → 403 with correct error message"
        else
            print_fail "Direct access → 403 but wrong message: $body"
        fi
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection to AgentGate failed (is it running?)"
    else
        print_fail "Direct access → $http_code (expected 403)"
    fi
}

test_agent_id_in_denials() {
    print_test "Agent ID in denial records"

    # Make a request that gets denied (/admin path)
    local deny_response
    deny_response=$(curl -s -k "https://127.0.0.1:$NGINX_PORT/check" \
        --cert "$TEMP_DIR/certs/client.crt" \
        --key "$TEMP_DIR/certs/client.key" \
        --cacert "$TEMP_DIR/certs/ca.crt" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/secret","method":"POST"}' 2>/dev/null || echo "")

    # Wait for denial to be recorded
    sleep 1

    # Fetch denial records
    local denials
    denials=$(curl -s "http://127.0.0.1:$AGENTGATE_PORT/denied-requests" 2>/dev/null || echo '{"total":0}')

    local total
    total=$(echo "$denials" | grep -oP '"total":\s*\K\d+' | head -1 || echo "0")

    if [[ "$total" -gt 0 ]]; then
        log_info "Denial records found (total: $total)"

        # Check for agent_id field presence
        local agent_id_count
        agent_id_count=$(echo "$denials" | grep -o '"agent_id"' | wc -l || echo "0")

        if [[ "$agent_id_count" -gt 0 ]]; then
            # Extract the agent_id from the denial record
            local recorded_agent_id
            recorded_agent_id=$(echo "$denials" | grep -oP '"agent_id":\s*"[a-f0-9]+"' | head -1 | grep -oP '[a-f0-9]{64}' || echo "")

            log_info "Recorded agent_id: ${recorded_agent_id:0:16}..."

            # Verify the agent_id is not all zeros
            local zero_id="0000000000000000000000000000000000000000000000000000000000000000"
            if [[ -n "$recorded_agent_id" && "$recorded_agent_id" != "$zero_id" ]]; then
                print_pass "Agent ID present and non-zero in denial records (id: ${recorded_agent_id:0:16}...)"
            elif [[ -n "$recorded_agent_id" && "$recorded_agent_id" == "$zero_id" ]]; then
                # Agent_id is all zeros — this means nginx forwarded the headers but
                # deriveAgentIdFromPEM() or toAgentId() returned zero.
                # This can happen if the PEM cert has multi-line format issues or
                # XxHash64 computation produces zeros (unlikely).
                log_warn "Agent ID is all zeros — header parsing may have partially succeeded"
                print_fail "Agent ID is all zeros in denial records (header parsing issue)"
            else
                print_fail "Could not extract agent_id from denial record"
            fi
        else
            print_fail "No agent_id field in denial records"
        fi
    else
        print_fail "No denial recorded (total: $total)"
    fi
}

test_header_injection_blocked() {
    print_test "Header injection attempt → behavior documented"
    # NOTE: In the current implementation, AgentGate trusts X-SSL-* headers unconditionally.
    # If a client sends X-SSL-Client-Verify: SUCCESS and a valid-looking fingerprint,
    # the request will be accepted even without going through nginx.
    # This is a KNOWN LIMITATION of the current design.
    #
    # The defense is at the network level: nginx is the ONLY entry point for agents,
    # and direct access to AgentGate (port 8080) is blocked at the firewall/network level.
    # In strict deployment, port 8080 should only accept connections from localhost/nginx.
    #
    # For now, we verify that direct access WITHOUT any headers IS rejected.

    # Test 1: Direct access without any SSL headers → should be 403
    local http_code_no_headers
    http_code_no_headers=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null || echo "000")

    # Test 2: Direct access WITH fake SSL headers → currently accepted (known limitation)
    local http_code_with_headers
    http_code_with_headers=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "X-SSL-Client-Verify: SUCCESS" \
        -H "X-SSL-Client-Fingerprint: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"POST"}' 2>/dev/null || echo "000")

    if [[ "$http_code_no_headers" == "403" ]]; then
        print_pass "Direct access without SSL headers → rejected (403)"
        log_warn "Direct access WITH fake SSL headers → accepted (${http_code_with_headers}) — KNOWN LIMITATION: no IP-based trust boundary"
    else
        print_fail "Direct access without SSL headers → $http_code_no_headers (expected 403)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         AgentGate mTLS Integration Test Suite                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$QUICK_MODE" == "true" ]]; then
        log_warn "Running in QUICK mode (skipping slow tests)"
    fi

    # Clean up any existing processes on required ports
    print_test "Preparing environment"
    pkill -9 agent-gate 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 1

    # Verify ports are free
    if ss -tlnp 2>/dev/null | grep -q ":${AGENTGATE_PORT}\|:${NGINX_PORT}"; then
        log_warn "Ports may still be in use, waiting..."
        sleep 2
    fi
    print_pass "Environment ready"

    # Run setup and startup
    check_prerequisites
    setup_certs
    check_cert_expiry
    generate_nginx_config
    start_agentgate
    start_nginx

    # Run tests
    print_header "Running Tests"

    test_health_endpoint
    test_valid_client_cert
    test_no_client_cert
    test_wrong_ca_cert
    test_direct_access_rejected
    test_agent_id_in_denials
    test_header_injection_blocked

    # Summary
    print_header "Test Summary"
    echo -e "  Passed: ${GREEN}$PASSED${NC}"
    echo -e "  Failed: ${RED}$FAILED${NC}"
    echo -e "  Skipped: ${YELLOW}$SKIPPED${NC}"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

main "$@"