#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# gen-license-keys.sh — Generate RSA key pair for license server
#
# This script creates the RSA key pair used to sign and verify license JWTs.
#
# Output:
#   keys/private.pem  — RSA private key (KEEP SECRET, mount into license-server)
#   keys/public.pem   — RSA public key (baked into proxy binary at build time)
#   proxy/license/public.pem — copy for the proxy build
# =============================================================================

DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="$DIR/keys"
PROXY_PUBLIC="$DIR/proxy/license/public.pem"

echo "🔐 Generating RSA key pair..."

mkdir -p "$KEYS_DIR"

# Generate 2048-bit RSA private key
openssl genpkey -algorithm RSA -out "$KEYS_DIR/private.pem" -pkeyopt rsa_keygen_bits:2048
chmod 600 "$KEYS_DIR/private.pem"

# Extract public key
openssl rsa -pubout -in "$KEYS_DIR/private.pem" -out "$KEYS_DIR/public.pem"

# Copy to proxy build directory
cp "$KEYS_DIR/public.pem" "$PROXY_PUBLIC"

echo "✅ Key pair generated:"
echo "   Private: $KEYS_DIR/private.pem"
echo "   Public:  $KEYS_DIR/public.pem"
echo "   Proxy:   $PROXY_PUBLIC"
echo ""
echo "🔑 Public key fingerprint:"
openssl pkey -in "$KEYS_DIR/private.pem" -pubout -outform DER | openssl dgst -sha256
