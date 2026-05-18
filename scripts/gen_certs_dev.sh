#!/bin/bash
# gen_certs_dev.sh - Generate development certificates for mTLS testing
# Usage: ./scripts/gen_certs_dev.sh [--output DIR]
#
# Generates:
#   - Root CA (self-signed, 10 years)
#   - Server certificate (signed by CA, 2 years)
#   - Agent certificates (5 agents, signed by CA, 1 year each)

set -e

OUTPUT_DIR="./certs"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --env)
            ENV="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Generating certificates in $OUTPUT_DIR..."

# ============================================================
# Step 1: Generate Root CA (private key + certificate)
# ============================================================
echo "[1/5] Generating Root CA..."

# Generate CA private key
openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096 2>/dev/null

# Generate self-signed CA certificate (10 years)
openssl req -x509 -new -nodes -key "$OUTPUT_DIR/ca.key" \
    -sha256 -days 3650 \
    -out "$OUTPUT_DIR/ca.crt" \
    -subj "/CN=AgentGate Dev CA/O=Development/OU=Security" \
    2>/dev/null

echo "  - CA private key: $OUTPUT_DIR/ca.key"
echo "  - CA certificate: $OUTPUT_DIR/ca.crt"

# ============================================================
# Step 2: Generate Server Certificate
# ============================================================
echo "[2/5] Generating Server certificate..."

# Generate server private key
openssl genrsa -out "$OUTPUT_DIR/server.key" 2048 2>/dev/null

# Generate server CSR
openssl req -new -key "$OUTPUT_DIR/server.key" \
    -out "$OUTPUT_DIR/server.csr" \
    -subj "/CN=localhost/O=AgentGate/OU=Server" \
    2>/dev/null

# Create server certificate extensions config
cat > "$OUTPUT_DIR/server.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1
EOF

# Sign server certificate with CA (2 years)
openssl x509 -req -in "$OUTPUT_DIR/server.csr" \
    -CA "$OUTPUT_DIR/ca.crt" \
    -CAkey "$OUTPUT_DIR/ca.key" \
    -CAcreateserial \
    -out "$OUTPUT_DIR/server.crt" \
    -days 730 \
    -sha256 \
    -extfile "$OUTPUT_DIR/server.ext" \
    2>/dev/null

# Cleanup CSR and ext file
rm -f "$OUTPUT_DIR/server.csr" "$OUTPUT_DIR/server.ext"

echo "  - Server private key: $OUTPUT_DIR/server.key"
echo "  - Server certificate: $OUTPUT_DIR/server.crt"

# ============================================================
# Step 3: Generate Agent Certificates
# ============================================================
echo "[3/5] Generating Agent certificates..."

AGENT_COUNT=5

for i in $(seq 1 $AGENT_COUNT); do
    AGENT_NAME="agent-$i"

    # Generate agent private key
    openssl genrsa -out "$OUTPUT_DIR/$AGENT_NAME.key" 2048 2>/dev/null

    # Generate agent CSR
    openssl req -new -key "$OUTPUT_DIR/$AGENT_NAME.key" \
        -out "$OUTPUT_DIR/$AGENT_NAME.csr" \
        -subj "/CN=$AGENT_NAME/O=AgentGate/OU=Agent" \
        2>/dev/null

    # Create agent certificate extensions
    cat > "$OUTPUT_DIR/$AGENT_NAME.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

    # Sign agent certificate with CA (1 year)
    openssl x509 -req -in "$OUTPUT_DIR/$AGENT_NAME.csr" \
        -CA "$OUTPUT_DIR/ca.crt" \
        -CAkey "$OUTPUT_DIR/ca.key" \
        -CAcreateserial \
        -out "$OUTPUT_DIR/$AGENT_NAME.crt" \
        -days 365 \
        -sha256 \
        -extfile "$OUTPUT_DIR/$AGENT_NAME.ext" \
        2>/dev/null

    # Cleanup CSR and ext file
    rm -f "$OUTPUT_DIR/$AGENT_NAME.csr" "$OUTPUT_DIR/$AGENT_NAME.ext"

    echo "  - $AGENT_NAME: $OUTPUT_DIR/$AGENT_NAME.crt"
done

# ============================================================
# Step 4: Create client certificate in PKCS12 format (for curl)
# ============================================================
echo "[4/5] Creating PKCS12 bundles for curl..."

for i in $(seq 1 $AGENT_COUNT); do
    AGENT_NAME="agent-$i"

    # Create PKCS12 bundle (includes key + cert + CA)
    openssl pkcs12 -export \
        -in "$OUTPUT_DIR/$AGENT_NAME.crt" \
        -inkey "$OUTPUT_DIR/$AGENT_NAME.key" \
        -certfile "$OUTPUT_DIR/ca.crt" \
        -out "$OUTPUT_DIR/$AGENT_NAME.p12" \
        -password pass:agent123 \
        2>/dev/null

    echo "  - $AGENT_NAME.p12 (password: agent123)"
done

# ============================================================
# Step 5: Generate CA serial file (for signing)
# ============================================================
echo "[5/5] Generating CA serial file..."
echo "01" > "$OUTPUT_DIR/ca.srl"

echo ""
echo "=============================================="
echo "Certificate generation complete!"
echo "=============================================="
echo ""
echo "Files created in $OUTPUT_DIR:"
echo ""
ls -la "$OUTPUT_DIR" | tail -n +2
echo ""
echo "Usage examples:"
echo ""
echo "  # Test with curl (requires client cert)"
echo "  curl --cert ./certs/agent-1.crt --key ./certs/agent-1.key \\"
echo "       --cacert ./certs/ca.crt https://localhost:8080/health"
echo ""
echo "  # Or use PKCS12 bundle"
echo "  curl --cert-type P12 --cert ./certs/agent-1.p12:agent123 \\"
echo "       --cacert ./certs/ca.crt https://localhost:8080/health"
echo ""
echo "  # Verify server certificate"
echo "  openssl verify -CAfile ./certs/ca.crt ./certs/server.crt"
echo ""
echo "  # Verify agent certificate"
echo "  openssl verify -CAfile ./certs/ca.crt ./certs/agent-1.crt"
echo ""

# Calculate agent_id for each agent (SHA256 of DER cert)
echo "Agent IDs (SHA256 of certificate):"
echo ""
for i in $(seq 1 $AGENT_COUNT); do
    AGENT_NAME="agent-$i"
    AGENT_ID=$(openssl x509 -in "$OUTPUT_DIR/$AGENT_NAME.crt" -outform DER | sha256sum | cut -d' ' -f1 | cut -c1-64)
    echo "  $AGENT_NAME: $AGENT_ID"
done
echo ""

# Cleanup serial files
rm -f "$OUTPUT_DIR/ca.srl"

echo "Done!"