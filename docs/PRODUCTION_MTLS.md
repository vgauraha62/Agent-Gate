# Production mTLS Setup Guide

## Overview

This guide covers setting up mTLS (mutual TLS) for production deployments of AgentGate. mTLS provides certificate-based authentication for agents, offering stronger security than JWT alone.

---

## Certificate Requirements

### Root CA

- **Purpose**: Trust anchor for verifying agent certificates
- **Type**: Self-signed X.509 certificate
- **Key Size**: 4096-bit RSA recommended
- **Validity**: 10+ years (rotate only when necessary)

### Server Certificate

- **Purpose**: Identity for the AgentGate server itself
- **Type**: X.509 certificate signed by Root CA
- **Key Size**: 2048-bit RSA minimum
- **Validity**: 1-2 years recommended
- **Required Extensions**:
  - `keyUsage`: `digitalSignature`, `keyEncipherment`
  - `extendedKeyUsage`: `serverAuth`
- **Subject Alternative Names (SAN)**:
  - DNS names for the server
  - IP addresses (if applicable)

### Agent Certificates

- **Purpose**: Identity for connecting agents
- **Type**: X.509 certificate signed by Root CA
- **Key Size**: 2048-bit RSA minimum
- **Validity**: 1 year recommended (enable automated rotation)
- **Required Extensions**:
  - `keyUsage`: `digitalSignature`
  - `extendedKeyUsage`: `clientAuth`
- **CN (Common Name)**: Agent identifier (used for agent_id derivation)

---

## Identity Derivation

AgentGate derives the `agent_id` from the client certificate using:

```
agent_id = SHA256(DER-encoded client certificate)
```

This produces a deterministic 32-byte identifier that matches the `Agent` struct's `id: [32]u8` requirement.

**Important**: The same certificate always produces the same agent_id, enabling:
- Consistent policy enforcement across restarts
- Audit log correlation by agent_id
- Easy certificate rotation (new cert = new agent_id)

---

## Integration with Existing PKI

### HashiCorp Vault

```bash
# Enable PKI secrets engine
vault secrets enable pki

# Configure CA and issuing endpoints
vault write pki/root/generate/internal \
    common_name="AgentGate Root CA" \
    ttl=87600h

# Create server certificate role
vault write pki/roles/agentgate-server \
    allowed_domains="agentgate.internal" \
    allow_subdomains=true \
    extended_key_usage="serverAuth" \
    ttl=720h

# Create agent certificate role
vault write pki/roles/agentgate-agent \
    allowed_domains="agent.internal" \
    allow_subdomains=true \
    extended_key_usage="clientAuth" \
    ttl=8760h

# Issue server certificate
vault write pki/issue/agentgate-server \
    common_name="agentgate.internal" \
    alt_names="localhost,127.0.0.1" \
    format=pem_bundle

# Issue agent certificate
vault write pki/issue/agentgate-agent \
    common_name="agent-001" \
    format=pem_bundle
```

### AWS Private CA

1. Create Private CA in AWS Certificate Manager
2. Configure certificate policy
3. Issue certificates using AWS CLI:

```bash
aws acm-pca issue-certificate \
    --certificate-authority-arn arn:aws:acm-pca:region:account:certificate-authority/id \
    --csr fileb://agent.csr \
    --signing-algorithm SHA256WITHRSA \
    --validity Value=365,Type=DAYS
```

### Step CA (smallstep)

```bash
# Initialize CA
step ca init --name "AgentGate CA" --dns localhost --address 127.0.0.1:8443

# Create server certificate
step ca certificate agentgate.internal server.crt server.key \
    --san localhost --san 127.0.0.1

# Create agent certificate
step ca certificate agent-001 agent.crt agent.key
```

---

## Configuration

### Config File (config.json)

```json
{
  "server": {
    "port": 8443
  },
  "auth": {
    "jwt_secret": "your-jwt-secret-min-32-chars"
  },
  "tls": {
    "enabled": true,
    "ca_cert_path": "/etc/agentgate/certs/ca.crt",
    "server_cert_path": "/etc/agentgate/certs/server.crt",
    "server_key_path": "/etc/agentgate/certs/server.key",
    "require_client_cert": true
  }
}
```

### Environment Variable Overrides

```bash
# Override certificate paths
export AGENTGATE_TLS_CA=/etc/agentgate/certs/ca.crt
export AGENTGATE_TLS_CERT=/etc/agentgate/certs/server.crt
export AGENTGATE_TLS_KEY=/etc/agentgate/certs/server.key
```

---

## Testing

### Verify Server Certificate

```bash
openssl verify -CAfile /etc/agentgate/certs/ca.crt \
    /etc/agentgate/certs/server.crt
```

### Test with curl (mTLS)

```bash
# Using PEM files
curl --cert ./certs/agent-1.crt \
     --key ./certs/agent-1.key \
     --cacert ./certs/ca.crt \
     https://localhost:8443/health

# Using PKCS12 bundle
curl --cert-type P12 \
     --cert ./certs/agent-1.p12:agent123 \
     --cacert ./certs/ca.crt \
     https://localhost:8443/health
```

### Check Agent ID

```bash
# Derive agent_id from certificate
openssl x509 -in agent-1.crt -outform DER | sha256sum | cut -d' ' -f1
```

---

## Certificate Rotation

### Manual Rotation (Development)

1. Generate new certificates using `scripts/gen_certs_dev.sh`
2. Deploy new certificates to servers
3. Restart AgentGate

### Automated Rotation (Production)

1. Use short-lived certificates (e.g., 24-72 hours)
2. Implement certificate refresh in agent code
3. Configure automatic reload in AgentGate:

```bash
# SIGHUP triggers config reload (including TLS certs)
kill -HUP $(pidof agent-gate)
```

---

## Security Considerations

### Private Key Protection

- Store private keys in secure locations (e.g., HashiCorp Vault, AWS Secrets Manager)
- Use file permissions `chmod 600` for key files
- Consider using Hardware Security Modules (HSM) for production

### Network

- Use TLS 1.2 or higher
- Disable weak cipher suites
- Consider mutual TLS only (no plaintext fallback in production)

### Monitoring

- Log TLS handshake failures
- Monitor certificate expiration
- Alert on unauthorized certificate usage

---

## Troubleshooting

### "certificate verify failed"

- Verify the CA certificate is correct
- Check the server is using the right certificate
- Ensure certificates haven't expired

### "no client certificate provided"

- Ensure client is sending a certificate
- Verify `require_client_cert` is set to `true`

### "certificate unknown"

- The client certificate wasn't signed by a trusted CA
- Verify the CA is correctly configured in AgentGate

---

## Related Files

- `scripts/gen_certs_dev.sh` - Development certificate generation
- `src/config.zig` - TLS configuration structure
- `src/auth/mTLS.zig` - mTLS implementation
- `src/server/http.zig` - Server with TLS integration