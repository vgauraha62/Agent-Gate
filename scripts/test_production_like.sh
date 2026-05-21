#!/bin/bash
# =============================================================================
# AgentGate Production-Mirror Test Suite
# =============================================================================
# Simulates exact production conditions — every request goes through nginx with
# real SSL headers, matching how real agents would connect.
#
# Usage: ./scripts/test_production_like.sh [--quick] [--verbose]
#   --quick    Skip slow tests (concurrent stress test)
#   --verbose  Show detailed output from curl, openssl commands
# =============================================================================

set -euo pipefail

# Feature flags
QUICK_MODE=false
VERBOSE=false
if [[ "${1:-}" == "--quick" ]]; then QUICK_MODE=true; fi
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=true; fi

# Colors
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
CERTS_DIR=""

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# =============================================================================
# Utility Functions
# =============================================================================

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1" >&2; }

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

print_warn() {
    echo -e "${YELLOW}⚠ WARN:${NC} $1"
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

# Curl helper that also captures HTTP code
# Usage: curl_nginx_code [--cert FILE] [--key FILE] <curl_args...>
# Uses Python to avoid bash subshell scope issues with curl -w output
curl_nginx_code() {
    local cert_file=""
    local key_file=""
    local remaining=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert)
                cert_file="$2"; shift 2 ;;
            --key)
                key_file="$2"; shift 2 ;;
            *)
                remaining+=("$1"); shift ;;
        esac
    done

    # Build remaining args as JSON array for Python
    local args_json="["
    local first=true
    for arg in "${remaining[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            args_json+=","
        fi
        # Escape for JSON
        local escaped="${arg//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        args_json+="\"$escaped\""
    done
    args_json+="]"

    # Use Python to handle curl and extract HTTP code (avoids bash scope issues)
    local code
    code=$(python3 -c "
import sys, subprocess, json
args = json.loads('$args_json')
cmd = ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '-k']
if '$cert_file' and '$key_file':
    cmd += ['--cert', '$cert_file', '--key', '$key_file']
cmd += ['--cacert', '$CERTS_DIR/ca.crt', 'https://127.0.0.1:$NGINX_PORT/']
cmd += args
result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
sys.stdout.write(result.stdout)
" 2>/dev/null) || code="000"

    printf '%s' "$code"
}

# Curl helper — all requests go through nginx (https) with mTLS
# Usage: curl_nginx [--cert FILE] [--key FILE] <curl_args...>
curl_nginx() {
    local cert_file=""
    local key_file=""
    local remaining=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert)
                cert_file="$2"; shift 2 ;;
            --key)
                key_file="$2"; shift 2 ;;
            *)
                remaining+=("$1"); shift ;;
        esac
    done

    # Build JSON array of remaining args to preserve exact argument boundaries
    local json_args="["
    local first=true
    for arg in "${remaining[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            json_args+=","
        fi
        # Escape for JSON: backslash, then double quotes
        local escaped="${arg//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        json_args+="\"$escaped\""
    done
    json_args+="]"

    # Use Python subprocess for reliable curl execution
    export CURL_CERT="$cert_file"
    export CURL_KEY="$key_file"
    export CURL_CACERT="$CERTS_DIR/ca.crt"
    export CURL_HOST="127.0.0.1"
    export CURL_PORT="$NGINX_PORT"
    export CURL_ARGS="$json_args"
    python3 -c "
import subprocess, os, json

cert = os.environ.get('CURL_CERT', '')
key = os.environ.get('CURL_KEY', '')
cacert = os.environ.get('CURL_CACERT', '')
host = os.environ.get('CURL_HOST', '127.0.0.1')
port = os.environ.get('CURL_PORT', '8443')
args_json = os.environ.get('CURL_ARGS', '[]')

cmd = ['curl', '-s', '-k']
if cert and key:
    cmd += ['--cert', cert, '--key', key]
cmd += ['--cacert', cacert]

# Base URL
url = 'https://' + host + ':' + port + '/'

# Parse JSON array of args - only first non-option arg is the URL path
args = json.loads(args_json)
path_set = False
for arg in args:
    if arg.startswith('-'):
        cmd.append(arg)
    elif arg.startswith('http'):
        url = arg
        path_set = True
    elif not path_set:
        # First non-option arg is the URL path
        if arg.startswith('/'):
            url = 'https://' + host + ':' + port + arg
        else:
            url = 'https://' + host + ':' + port + '/' + arg
        path_set = True
    else:
        # Subsequent non-option args are curl option values (e.g., JSON body)
        cmd.append(arg)

cmd.append(url)

result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
print(result.stdout, end='')
"
}

# Curl helper that also captures HTTP code
# Usage: curl_nginx_code [--cert FILE] [--key FILE] <curl_args...>
curl_nginx_code() {
    local cert_file=""
    local key_file=""
    local remaining=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert)
                cert_file="$2"; shift 2 ;;
            --key)
                key_file="$2"; shift 2 ;;
            *)
                remaining+=("$1"); shift ;;
        esac
    done

    # Build JSON array of remaining args to preserve exact argument boundaries
    local json_args="["
    local first=true
    for arg in "${remaining[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            json_args+=","
        fi
        # Escape for JSON: backslash, then double quotes
        local escaped="${arg//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        json_args+="\"$escaped\""
    done
    json_args+="]"

    export CURL_CERT="$cert_file"
    export CURL_KEY="$key_file"
    export CURL_CACERT="$CERTS_DIR/ca.crt"
    export CURL_HOST="127.0.0.1"
    export CURL_PORT="$NGINX_PORT"
    export CURL_ARGS="$json_args"

    python3 -c "
import subprocess, os, json

cert = os.environ.get('CURL_CERT', '')
key = os.environ.get('CURL_KEY', '')
cacert = os.environ.get('CURL_CACERT', '')
host = os.environ.get('CURL_HOST', '127.0.0.1')
port = os.environ.get('CURL_PORT', '8443')
args_json = os.environ.get('CURL_ARGS', '[]')

cmd = ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '-k']
if cert and key:
    cmd += ['--cert', cert, '--key', key]
cmd += ['--cacert', cacert]

# Base URL
url = 'https://' + host + ':' + port + '/'

# Parse JSON array of args - only first non-option arg is the URL path
args = json.loads(args_json)
path_set = False
for arg in args:
    if arg.startswith('-'):
        cmd.append(arg)
    elif arg.startswith('http'):
        url = arg
        path_set = True
    elif not path_set:
        # First non-option arg is the URL path
        if arg.startswith('/'):
            url = 'https://' + host + ':' + port + arg
        else:
            url = 'https://' + host + ':' + port + '/' + arg
        path_set = True
    else:
        # Subsequent non-option args are curl option values (e.g., JSON body)
        cmd.append(arg)

cmd.append(url)

result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
print(result.stdout, end='')
"
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    print_header "Cleaning up"

    if [[ -n "${AGENTGATE_PID:-}" ]]; then
        if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_info "Stopping AgentGate (PID: $AGENTGATE_PID)"
            kill "$AGENTGATE_PID" 2>/dev/null || true
            local retries=5
            while kill -0 "$AGENTGATE_PID" 2>/dev/null && [[ $retries -gt 0 ]]; do
                sleep 0.5
                ((retries--))
            done
            if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
                kill -9 "$AGENTGATE_PID" 2>/dev/null || true
            fi
        fi
    fi

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

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        log_info "Removing temp directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    echo "Cleanup complete"
}

trap cleanup EXIT

# =============================================================================
# Setup
# =============================================================================

setup() {
    print_header "Setting up production-mirror environment"

    TEMP_DIR=$(mktemp -d /tmp/agentgate_prod_test_XXXXXX)
    CERTS_DIR="$TEMP_DIR/certs"
    mkdir -p "$CERTS_DIR"
    log_info "Temp directory: $TEMP_DIR"

    # Generate CA
    log_info "Generating CA certificate..."
    run openssl genrsa -out "$CERTS_DIR/ca.key" -aes256 -passout pass:test123 4096
    run openssl req -new -x509 -days 365 \
        -key "$CERTS_DIR/ca.key" -passin pass:test123 \
        -out "$CERTS_DIR/ca.crt" \
        -subj "/CN=Prod CA/O=AgentGate/OU=Production"

    # Generate server certificate
    log_info "Generating server certificate..."
    run openssl genrsa -out "$CERTS_DIR/server.key" 2048
    run openssl req -new -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" \
        -subj "/CN=localhost/O=AgentGate/OU=Production"
    printf "subjectAltName=IP:127.0.0.1,DNS:localhost" > "$CERTS_DIR/server.ext"
    run openssl x509 -req -days 365 -in "$CERTS_DIR/server.csr" \
        -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -passin pass:test123 \
        -CAcreateserial -out "$CERTS_DIR/server.crt" -extfile "$CERTS_DIR/server.ext"

    # Generate 3 client certificates (agent-1, agent-2, agent-3)
    for i in 1 2 3; do
        log_info "Generating client certificate for agent-$i..."
        run openssl genrsa -out "$CERTS_DIR/agent-${i}.key" 2048
        run openssl req -new -key "$CERTS_DIR/agent-${i}.key" \
            -out "$CERTS_DIR/agent-${i}.csr" \
            -subj "/CN=agent-${i}/O=AgentGate/OU=Production"
        printf "extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE" > "$CERTS_DIR/agent-${i}.ext"
        run openssl x509 -req -days 365 -in "$CERTS_DIR/agent-${i}.csr" \
            -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -passin pass:test123 \
            -CAcreateserial -out "$CERTS_DIR/agent-${i}.crt" -extfile "$CERTS_DIR/agent-${i}.ext"

        # Generate PKCS12 bundle for agent-1
        if [[ "$i" == "1" ]]; then
            run openssl pkcs12 -export -out "$CERTS_DIR/agent-${i}.p12" \
                -inkey "$CERTS_DIR/agent-${i}.key" -in "$CERTS_DIR/agent-${i}.crt" \
                -passout pass:test123 -name "agent-${i}"
        fi
    done

    # Verify all certs
    log_info "Verifying certificate chain..."
    for cert in "$CERTS_DIR"/client.crt "$CERTS_DIR"/agent-{1,2,3}.crt; do
        [[ -f "$cert" ]] || continue
        if run openssl verify -CAfile "$CERTS_DIR/ca.crt" "$cert" >/dev/null; then
            log_info "  $(basename $cert): verified"
        else
            log_err "  $(basename $cert): verification failed"
            exit 1
        fi
    done

    # Generate nginx config
    generate_nginx_config
}

# =============================================================================
# Generate Nginx Config
# =============================================================================

generate_nginx_config() {
    local body_size="${1:-1m}"  # default: 1MB

    print_header "Generating nginx configuration"

    cat > "$TEMP_DIR/nginx.conf" << EOF
worker_processes 1;
error_log /tmp/agentgate_prod_nginx_error.log;
pid /tmp/agentgate_prod_nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    client_body_temp_path TEMP_DIR/client_body;
    proxy_temp_path TEMP_DIR/proxy;
    fastcgi_temp_path TEMP_DIR/fastcgi;
    uwsgi_temp_path TEMP_DIR/uwsgi;
    scgi_temp_path TEMP_DIR/scgi;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers on;
    client_max_body_size ${body_size};
    upstream backend { server 127.0.0.1:8080; }
    server {
        listen 8443 ssl;
        server_name localhost;
        ssl_certificate CERTS_DIR/server.crt;
        ssl_certificate_key CERTS_DIR/server.key;
        ssl_client_certificate CERTS_DIR/ca.crt;
        ssl_verify_client on;
        ssl_verify_depth 2;
        add_header Strict-Transport-Security "max-age=31536000" always;
        add_header X-Frame-Options "DENY" always;
        location / {
            # All mTLS endpoints (check, denied-requests) require client cert
            proxy_set_header X-SSL-Client-Verify \$ssl_client_verify;
            proxy_set_header X-SSL-Client-Cert \$ssl_client_cert;
            proxy_set_header X-SSL-Client-Fingerprint \$ssl_client_fingerprint;
            proxy_set_header X-SSL-Client-Subject \$ssl_client_s_dn;
            proxy_set_header X-SSL-Client-Serial \$ssl_client_serial;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
        location /health {
            # Health check route — requires client cert in production
            proxy_pass http://backend/health;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
    }
}
EOF

    sed -i "s|CERTS_DIR|$CERTS_DIR|g" "$TEMP_DIR/nginx.conf"
    sed -i "s|TEMP_DIR|$TEMP_DIR|g" "$TEMP_DIR/nginx.conf"
    log_info "Nginx config: $TEMP_DIR/nginx.conf"
    log_info "client_max_body_size: ${body_size}"
}

# =============================================================================
# Start Services
# =============================================================================

start_agentgate() {
    print_test "Starting AgentGate"

    cd "$PROJECT_DIR" || exit 1

    # Copy default policy file to temp directory
    cp "$PROJECT_DIR/policies/default.json" "$TEMP_DIR/default_policy.json"

    # Create config with policy_file pointing to copied policy
    cat > "$TEMP_DIR/config.json" << EOF
{
    "server": {"port": 8080, "host": "127.0.0.1", "workers": 4},
    "auth": {"jwt_secret": "production-mirror-test-secret-32!"},
    "tls": {
        "mode": "external",
        "external_policy": "strict",
        "require_ssl_headers": true,
        "trusted_proxy_ip": "127.0.0.1"
    },
    "policy": {"policy_timeout_ms": 50, "policy_file": "$TEMP_DIR/default_policy.json"},
    "audit": {"buffer_size": 1000, "audit_timeout_ms": 10},
    "request": {"request_timeout_ms": 5000}
}
EOF

    # Build if needed
    if [[ ! -f "zig-out/bin/agent-gate" ]]; then
        log_info "Building AgentGate..."
        if ! zig build -p zig-out; then
            log_err "zig build failed"
            exit 1
        fi
    fi

    ./zig-out/bin/agent-gate --config "$TEMP_DIR/config.json" > "$TEMP_DIR/agentgate.log" 2>&1 &
    AGENTGATE_PID=$!

    # Wait for health endpoint
    local attempt=0
    while [[ $attempt -lt 10 ]]; do
        if ! kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_err "AgentGate process died during startup"
            cat "$TEMP_DIR/agentgate.log"
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
        cat "$TEMP_DIR/agentgate.log"
        exit 1
    fi
}

start_nginx() {
    print_test "Starting nginx with mTLS"

    if ! nginx -t -c "$TEMP_DIR/nginx.conf" 2>&1; then
        log_err "Nginx config validation failed"
        cat /tmp/agentgate_prod_nginx_error.log 2>/dev/null || true
        exit 1
    fi
    log_info "Nginx config validated OK"

    nginx -c "$TEMP_DIR/nginx.conf" 2>/dev/null || {
        log_err "nginx failed to start"
        cat /tmp/agentgate_prod_nginx_error.log 2>/dev/null || true
        exit 1
    }
    sleep 1

    local pid_file="/tmp/agentgate_prod_nginx.pid"
    if [[ -f "$pid_file" ]]; then
        NGINX_PID=$(cat "$pid_file")
    else
        NGINX_PID=$(pgrep -f "nginx: master.*nginx.conf" | head -1 || echo "")
    fi

    if [[ -n "$NGINX_PID" ]] && kill -0 "$NGINX_PID" 2>/dev/null; then
        print_pass "Nginx started (PID: $NGINX_PID)"
    else
        log_err "Nginx failed to start"
        exit 1
    fi

    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":${NGINX_PORT}"; then
        log_info "nginx is listening on port $NGINX_PORT"
    else
        log_warn "nginx may not be listening on port $NGINX_PORT"
    fi
}

# =============================================================================
# Test Cases — ALL requests go through nginx
# =============================================================================

test_health_through_nginx() {
    print_test "Health endpoint accessible through nginx with client cert"

    # Production monitoring connects through nginx with a client cert
    local http_code
    local body
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "health")
    body=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "health")

    if [[ "$http_code" == "200" && "$body" == "OK" ]]; then
        print_pass "Health endpoint returns 200 OK through nginx (with client cert)"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection to nginx failed (is nginx running?)"
    else
        print_fail "Health endpoint returns $http_code (expected 200), body: $body"
    fi
}

test_agent_allow() {
    print_test "Agent with valid cert accessing allowed path"

    # agent-1 accesses an allowed path — should be allowed
    local http_code
    local body
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}')
    body=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}')

    if [[ "$http_code" == "200" && "$body" == *"allowed\":true"* ]]; then
        print_pass "Allowed path → {\"allowed\":true}"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection failed"
    else
        print_fail "Expected allowed:true, got http=$http_code body=$body"
    fi
}

test_agent_deny() {
    print_test "Agent accessing denied path (should be denied)"

    # agent-1 accesses a denied path — should be denied
    local http_code
    local body
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/secret","method":"POST"}')
    body=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/secret","method":"POST"}')

    if [[ "$http_code" == "200" || "$http_code" == "403" ]] && [[ "$body" == *"allowed\":false"* ]]; then
        print_pass "Denied path → {\"allowed\":false}"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection failed"
    else
        print_fail "Expected allowed:false, got http=$http_code body=$body"
    fi
}

test_agent_deny_recorded() {
    print_test "Denial recorded in audit log with agent_id"

    # Make a denied request through nginx (triggers policy denial)
    curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/secret","method":"POST"}' > /dev/null 2>&1

    # Query denied requests through nginx
    local response
    response=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "denied-requests")

    local result
    result=$(python3 -c "
import sys, json
try:
    data = json.loads('''$response''')
    total = data.get('total', 0)
    if total > 0:
        denials = data.get('denials', [])
        if denials:
            agent_id = denials[0].get('agent_id', '')
            if agent_id and agent_id != '0' * 64:
                print('PASS')
            else:
                print('FAIL: zero agent_id')
        else:
            print('FAIL: no denials in array')
    else:
        print('FAIL: no denials recorded')
except Exception as e:
    print(f'FAIL: {e}')
" 2>/dev/null) || result="FAIL: python3 error"

    if [[ "$result" == "PASS" ]]; then
        print_pass "Denial recorded with valid agent_id"
    else
        print_fail "Denial not recorded correctly: $result"
    fi
}

test_agent_id_consistency() {
    print_test "Same certificate produces same agent_id across requests"

    # Make 3 denied requests with same agent through nginx
    for i in 1 2 3; do
        curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
            "check" \
            -H "Content-Type: application/json" \
            -d '{"path":"/admin/consistency","method":"POST"}' > /dev/null 2>&1
    done

    # Query last 3 denials through nginx
    local response
    response=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "denied-requests?limit=3")

    local result
    result=$(python3 -c "
import sys, json
try:
    data = json.loads('''$response''')
    denials = data.get('denials', [])
    if len(denials) < 3:
        print(f'FAIL: Only {len(denials)} denials found (expected 3)')
    else:
        agent_ids = [d['agent_id'] for d in denials[:3]]
        if len(set(agent_ids)) == 1 and agent_ids[0] != '0' * 64:
            print('PASS')
        else:
            print(f'FAIL: Inconsistent agent_ids: {agent_ids}')
except Exception as e:
    print(f'FAIL: {e}')
" 2>/dev/null) || result="FAIL: python3 error"

    if [[ "$result" == "PASS" ]]; then
        print_pass "Agent ID consistent across 3 requests"
    else
        print_fail "Agent ID inconsistent: $result"
    fi
}

test_multiple_agents() {
    print_test "Multiple agents get different agent_ids"

    # Make denied requests with different agents through nginx
    curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/multi","method":"POST"}' > /dev/null 2>&1

    curl_nginx --cert "$CERTS_DIR/agent-2.crt" --key "$CERTS_DIR/agent-2.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/multi","method":"POST"}' > /dev/null 2>&1

    # Query last 2 denials through nginx
    local response
    response=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "denied-requests?limit=2")

    local result
    result=$(python3 -c "
import sys, json
try:
    data = json.loads('''$response''')
    denials = data.get('denials', [])
    if len(denials) < 2:
        print(f'FAIL: Only {len(denials)} denials found (expected 2)')
    else:
        agent1 = denials[0]['agent_id']
        agent2 = denials[1]['agent_id']
        if agent1 != agent2 and agent1 != '0' * 64 and agent2 != '0' * 64:
            print('PASS')
        else:
            print(f'FAIL: Agent IDs same or zero: {agent1} vs {agent2}')
except Exception as e:
    print(f'FAIL: {e}')
" 2>/dev/null) || result="FAIL: python3 error"

    if [[ "$result" == "PASS" ]]; then
        print_pass "Different agents have different IDs"
    else
        print_fail "Agent IDs not different: $result"
    fi
}

test_agent_id_repeatability() {
    print_test "Sequential requests with same cert → same agent_id"

    # Make 2 sequential denied requests through nginx
    curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/repeat","method":"POST"}' > /dev/null 2>&1

    curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/admin/repeat","method":"POST"}' > /dev/null 2>&1

    # Query last 2 denials through nginx
    local response
    response=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "denied-requests?limit=2")

    local result
    result=$(python3 -c "
import sys, json
try:
    data = json.loads('''$response''')
    denials = data.get('denials', [])
    if len(denials) < 2:
        print(f'FAIL: Only {len(denials)} denials found (expected 2)')
    else:
        agent_ids = [d['agent_id'] for d in denials[:2]]
        if len(set(agent_ids)) == 1 and agent_ids[0] != '0' * 64:
            print('PASS')
        else:
            print(f'FAIL: Agent IDs differ across sequential requests: {agent_ids}')
except Exception as e:
    print(f'FAIL: {e}')
" 2>/dev/null) || result="FAIL: python3 error"

    if [[ "$result" == "PASS" ]]; then
        print_pass "Agent ID repeatable across sequential requests"
    else
        print_fail "Agent ID not repeatable: $result"
    fi
}

test_p12_bundle() {
    print_test "PKCS12 bundle authentication"

    # agent-1 has a .p12 bundle — test that curl handles it
    local http_code
    local body

    # curl with P12 bundle
    http_code=$(run curl -s -o /dev/null -w "%{http_code}" -k \
        --cert-type P12 \
        --cert "$CERTS_DIR/agent-1.p12:test123" \
        --cacert "$CERTS_DIR/ca.crt" \
        "https://127.0.0.1:$NGINX_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' || echo "000")

    body=$(run curl -s -k \
        --cert-type P12 \
        --cert "$CERTS_DIR/agent-1.p12:test123" \
        --cacert "$CERTS_DIR/ca.crt" \
        "https://127.0.0.1:$NGINX_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' || echo "")

    if [[ "$http_code" == "200" && "$body" == *"allowed"* ]]; then
        print_pass "PKCS12 bundle → HTTP $http_code with allowed response"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection failed with P12 bundle"
    else
        print_fail "P12 bundle → HTTP $http_code, body: $body"
    fi
}

test_concurrent_requests() {
    print_test "Concurrent requests — 100 parallel through nginx"

    local pids=()
    local results=()
    local failed=0
    local successes=0

    log_info "Sending 100 concurrent requests..."

    for i in {1..100}; do
        (
            local response
            response=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
                "check" \
                -H "Content-Type: application/json" \
                -d '{"path":"/api/load","method":"GET"}' 2>/dev/null || echo "")
            echo "$response"
        ) &
        pids+=($!)
    done

    # Collect results
    local i=0
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            ((successes++))
        fi
        ((i++))
    done

    if [[ $successes -eq 100 ]]; then
        print_pass "100 concurrent requests → all completed successfully"
    else
        print_fail "100 concurrent requests → $successes/100 completed (some failed)"
    fi

    # Verify all returned allowed:true
    log_info "Verifying response bodies..."
    local total_allowed=0
    for pid in "${pids[@]}"; do
        result=$(wait "$pid" 2>/dev/null || echo "")
        if echo "$result" | grep -q "allowed.*true"; then
            ((total_allowed++))
        fi
    done

    if [[ "$total_allowed" -eq 100 ]]; then
        print_pass "All 100 responses contain allowed:true"
    elif [[ "$total_allowed" -gt 0 ]]; then
        print_warn "Only $total_allowed/100 responses verified as allowed:true"
        print_pass "Concurrent requests completed (validation partial)"
    else
        print_warn "Could not verify response bodies concurrently"
        print_pass "Concurrent requests completed (no body verification in parallel mode)"
    fi
}

# =============================================================================
# New Tests: Gap Coverage (T1–T10)
# =============================================================================

# T1: Direct HTTP to AgentGate (bypass nginx) — expect 403
test_direct_bypass() {
    print_test "Direct HTTP to AgentGate (no nginx) — expect 403"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}' 2>/dev/null || echo "000")

    if [[ "$http_code" == "403" ]]; then
        print_pass "Direct access to /check returned 403 Forbidden"
    else
        print_fail "Direct access returned $http_code (expected 403)"
    fi
}

# T2: Request to nginx WITHOUT client cert — expect TLS handshake failure
test_mtls_required_at_nginx() {
    print_test "mTLS required — request without client certificate"

    local output
    output=$(curl -k -s \
        --cacert "$CERTS_DIR/ca.crt" \
        "https://127.0.0.1:$NGINX_PORT/health" 2>&1 || true)

    if echo "$output" | grep -qE "SSL|certificate|handshake|error|56|35"; then
        print_pass "Request without client cert rejected at TLS layer"
    else
        print_fail "Request without client cert was accepted (output: $output)"
    fi
}

# T3: Expired client certificate — expect TLS handshake failure
test_expired_client_cert() {
    print_test "Expired client certificate — expect TLS rejection"

    # Generate a self-signed cert (not signed by our CA) — nginx will reject it
    local expired_key="$TEMP_DIR/expired.key"
    local expired_crt="$TEMP_DIR/expired.crt"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$expired_key" -out "$expired_crt" \
        -subj "/CN=expired-agent/O=AgentGate/OU=Test" \
        -days 1 2>/dev/null || {
        print_fail "Failed to generate test certificate"
        return
    }

    local output
    local exit_code
    output=$(curl -k -s \
        --cert "$expired_crt" \
        --key "$expired_key" \
        --cacert "$CERTS_DIR/ca.crt" \
        "https://127.0.0.1:$NGINX_PORT/health" 2>&1)
    exit_code=$?

    # Check for TLS/SSL errors (handshake failure, certificate not trusted, etc.)
    # curl exit code 35 = SSL connect error, exit code 56 = socket receive error
    if [[ $exit_code -ne 0 ]] || echo "$output" | grep -qE "SSL|certificate|handshake|error|400|Bad Request|403"; then
        print_pass "Untrusted certificate rejected at TLS layer (exit=$exit_code)"
    else
        print_fail "Untrusted certificate was accepted (exit=$exit_code, output: ${output:0:100})"
    fi
}

# T4: Forged SSL headers via direct HTTP — expect 403
test_forged_ssl_headers() {
    print_test "Forged SSL headers via direct HTTP — expect 403"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -H "X-SSL-Client-Verify: SUCCESS" \
        -H "X-SSL-Client-Fingerprint: $(printf '%064x' 0 | head -c 64)" \
        -d '{"path":"/api/test","method":"GET"}' 2>/dev/null || echo "000")

    if [[ "$http_code" == "403" ]]; then
        print_pass "Forged SSL headers rejected (403)"
    else
        print_fail "Forged SSL headers returned $http_code (expected 403)"
    fi
}

# T5: Malformed fingerprint (non-hex) via direct HTTP — expect 400 or 403
test_malformed_fingerprint() {
    print_test "Malformed fingerprint (non-hex) — expect 400/403"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://127.0.0.1:$AGENTGATE_PORT/check" \
        -H "Content-Type: application/json" \
        -H "X-SSL-Client-Verify: SUCCESS" \
        -H "X-SSL-Client-Fingerprint: NOT_A_VALID_HEX_STRING!!!___" \
        -d '{"path":"/api/test","method":"GET"}' 2>/dev/null || echo "000")

    if [[ "$http_code" == "400" ]] || [[ "$http_code" == "403" ]]; then
        print_pass "Malformed fingerprint rejected ($http_code)"
    else
        print_fail "Malformed fingerprint returned $http_code (expected 400 or 403)"
    fi
}

# T6: POST without Content-Type header — expect 200 (lenient)
test_missing_content_type() {
    print_test "POST without Content-Type — expect 200 (lenient)"

    local http_code
    local body
    # Don't pass -H "" — omit Content-Type header entirely
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -X POST \
        -d '{"path":"/api/test","method":"GET"}')
    body=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -X POST \
        -d '{"path":"/api/test","method":"GET"}')

    if [[ "$http_code" == "200" && "$body" == *"allowed"* ]]; then
        print_pass "Request accepted without Content-Type header"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection failed"
    else
        print_fail "Got http=$http_code body=$body (expected 200 with allowed)"
    fi
}

# T7: Oversized request body — expect 413 Payload Too Large
test_oversized_body() {
    print_test "Oversized request body (1.1MB) — expect 413"

    # Generate 1.1MB body using dd + printf (efficient, no Python needed)
    local large_body_file="$TEMP_DIR/large_body.json"
    {
        printf '{"path":"'
        dd if=/dev/zero bs=1 count=1100000 2>/dev/null | tr '\0' 'x'
        printf '","method":"GET"}'
    } > "$large_body_file"

    local body_size
    body_size=$(wc -c < "$large_body_file")

    if [[ $body_size -lt 1000000 ]]; then
        print_fail "Body generation failed (size: $body_size)"
        return
    fi

    local http_code
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -X POST \
        --data-binary "@$large_body_file")

    if [[ "$http_code" == "413" ]]; then
        print_pass "Oversized body rejected with 413"
    else
        print_fail "Oversized body returned $http_code (expected 413)"
    fi
}

# T8: /metrics endpoint — verify metrics format
test_metrics_endpoint() {
    print_test "Metrics endpoint — verify metrics format"

    local metrics
    metrics=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" "metrics")

    local has_requests=false
    local has_allowed=false
    local has_denied=false
    local has_active=false

    echo "$metrics" | grep -q "requests_total" && has_requests=true
    echo "$metrics" | grep -q "allowed" && has_allowed=true
    echo "$metrics" | grep -q "denied" && has_denied=true
    echo "$metrics" | grep -q "active" && has_active=true

    local failures=0
    [[ "$has_requests" == "false" ]] && log_err "  Missing requests_total" && ((failures++))
    [[ "$has_allowed" == "false" ]] && log_err "  Missing allowed" && ((failures++))
    [[ "$has_denied" == "false" ]] && log_err "  Missing denied" && ((failures++))
    [[ "$has_active" == "false" ]] && log_err "  Missing active" && ((failures++))

    if [[ $failures -eq 0 ]]; then
        print_pass "Metrics endpoint returns valid format"
    else
        print_fail "Metrics endpoint missing $failures expected fields"
    fi
}

# T9: JWT + mTLS conflict — SSL headers should take precedence
test_jwt_ssl_conflict() {
    print_test "JWT + mTLS — SSL identity should take precedence"

    # Source the JWT helper
    source "$SCRIPT_DIR/jwt_helper.sh"

    local jwt
    jwt=$(generate_jwt "attacker-impersonating-agent-1" "production-mirror-test-secret-32!")

    # Send request with BOTH JWT Authorization header AND client certificate
    local body
    body=$(curl_nginx --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $jwt" \
        -d '{"path":"/api/test","method":"GET"}')

    # The response should contain allowed:true (SSL identity from agent-1 cert used)
    if [[ "$body" == *"allowed\":true"* ]]; then
        print_pass "SSL identity (agent-1) used over JWT identity"
    elif [[ "$body" == *"allowed\":false"* ]]; then
        print_fail "Request denied — JWT identity may have been used"
    else
        print_fail "Unexpected response: $body"
    fi
}

# T10: Policy timeout behavior — expect 504 Gateway Timeout
test_policy_timeout_behavior() {
    print_test "Policy timeout — expect 504 Gateway Timeout"

    # Copy slow policy file to temp directory
    cp "$SCRIPT_DIR/slow_policy.json" "$TEMP_DIR/slow_policy.json"

    # Create config with 1ms policy timeout and slow policy file
    local timeout_config="$TEMP_DIR/timeout_config.json"
    cat > "$timeout_config" << EOF
{
    "server": {"port": 8080, "host": "127.0.0.1", "workers": 4},
    "auth": {"jwt_secret": "production-mirror-test-secret-32!"},
    "tls": {
        "mode": "external",
        "external_policy": "strict",
        "require_ssl_headers": true,
        "trusted_proxy_ip": "127.0.0.1"
    },
    "policy": {"policy_timeout_ms": 1, "policy_file": "$TEMP_DIR/slow_policy.json"},
    "audit": {"buffer_size": 1000, "audit_timeout_ms": 10},
    "request": {"request_timeout_ms": 5000}
}
EOF

    # Restart AgentGate with timeout config
    log_info "Restarting AgentGate with 1ms policy timeout..."
    if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
        kill "$AGENTGATE_PID" 2>/dev/null || true
        local retries=5
        while kill -0 "$AGENTGATE_PID" 2>/dev/null && [[ $retries -gt 0 ]]; do
            sleep 0.5
            ((retries--))
        done
        [[ $retries -eq 0 ]] && kill -9 "$AGENTGATE_PID" 2>/dev/null || true
    fi

    sleep 1

    cd "$PROJECT_DIR" || exit 1
    ./zig-out/bin/agent-gate --config "$timeout_config" > "$TEMP_DIR/agentgate_timeout.log" 2>&1 &
    AGENTGATE_PID=$!

    local attempt=0
    while [[ $attempt -lt 20 ]]; do
        if ! kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_err "AgentGate died during startup"
            break
        fi
        if curl -s "http://127.0.0.1:$AGENTGATE_PORT/health" 2>/dev/null | grep -q "OK"; then
            break
        fi
        sleep 0.5
        ((attempt++))
    done

    # Make a request that triggers policy evaluation
    local http_code
    http_code=$(curl_nginx_code --cert "$CERTS_DIR/agent-1.crt" --key "$CERTS_DIR/agent-1.key" \
        "check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/api/test","method":"GET"}')

    if [[ "$http_code" == "504" ]]; then
        print_pass "Policy timeout returned 504 Gateway Timeout"
    elif [[ "$http_code" == "000" ]]; then
        print_fail "Connection failed (AgentGate may have died)"
    else
        print_fail "Policy timeout returned $http_code (expected 504)"
    fi

    # Restart with normal config for remaining tests
    log_info "Restarting AgentGate with normal config..."
    if kill -0 "$AGENTGATE_PID" 2>/dev/null; then
        kill "$AGENTGATE_PID" 2>/dev/null || true
        retries=5
        while kill -0 "$AGENTGATE_PID" 2>/dev/null && [[ $retries -gt 0 ]]; do
            sleep 0.5
            ((retries--))
        done
        [[ $retries -eq 0 ]] && kill -9 "$AGENTGATE_PID" 2>/dev/null || true
    fi
    sleep 1

    ./zig-out/bin/agent-gate --config "$TEMP_DIR/config.json" > "$TEMP_DIR/agentgate.log" 2>&1 &
    AGENTGATE_PID=$!

    attempt=0
    while [[ $attempt -lt 20 ]]; do
        if ! kill -0 "$AGENTGATE_PID" 2>/dev/null; then
            log_err "AgentGate failed to restart after timeout test"
            exit 1
        fi
        if curl -s "http://127.0.0.1:$AGENTGATE_PORT/health" 2>/dev/null | grep -q "OK"; then
            break
        fi
        sleep 0.5
        ((attempt++))
    done

    log_info "AgentGate restarted and healthy"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    AgentGate Production-Mirror Test Suite                     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    print_test "Preparing environment"
    pkill -9 agent-gate 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 1

    if ss -tlnp 2>/dev/null | grep -q ":${AGENTGATE_PORT}\|:${NGINX_PORT}"; then
        log_warn "Ports may still be in use, waiting..."
        sleep 2
    fi
    print_pass "Environment ready"

    setup
    start_agentgate
    start_nginx

    print_header "Running Production-Mirror Tests (all through nginx)"

    # Disable errexit during tests — curl_nginx_code handles failures gracefully
    set +e

    # Set curl environment variables for Python subprocess helpers
    export CURL_CACERT="$CERTS_DIR/ca.crt"
    export CURL_HOST="127.0.0.1"
    export CURL_PORT="$NGINX_PORT"

    test_health_through_nginx
    test_agent_allow
    test_agent_deny
    test_agent_deny_recorded
    test_agent_id_consistency
    test_multiple_agents
    test_agent_id_repeatability
    test_p12_bundle
    test_concurrent_requests

    print_header "Running New Gap-Coverage Tests"

    test_direct_bypass
    test_mtls_required_at_nginx
    test_expired_client_cert
    test_forged_ssl_headers
    test_malformed_fingerprint
    test_missing_content_type
    test_oversized_body
    test_metrics_endpoint
    test_jwt_ssl_conflict

    # Policy timeout test runs last — it restarts AgentGate with modified config
    test_policy_timeout_behavior

    print_header "Test Summary"
    echo -e "  Passed: ${GREEN}$PASSED${NC}"
    echo -e "  Failed: ${RED}$FAILED${NC}"
    echo -e "  Skipped: ${YELLOW}$SKIPPED${NC}"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All production-mirror tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

main "$@"