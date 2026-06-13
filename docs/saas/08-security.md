---
title: Security
nav_order: 8
---

# Security

## Security Model Overview

AgentGate Cage follows several core security principles:

1. **Fail closed** — If the policy engine is unreachable, all requests are denied
2. **Default deny** — If no policy matches, the request is denied
3. **Defense in depth** — Multiple security layers: license → auth → policy → audit
4. **Least privilege** — Agents can only perform explicitly allowed operations
5. **Tamper evidence** — All decisions are cryptographically chained and verifiable

## Trust Boundaries

```
Untrusted (AI Clients)
    │
    ▼
┌─────────────────────┐
│   TLS Boundary      │  ← mTLS if configured
└─────────────────────┘
    │
    ▼
┌─────────────────────┐
│  AgentGate Cage     │  ← Trusted computing base
│  (Proxy + AgentGate │
│   + LiteLLM)        │
└─────────────────────┘
    │
    ▼
┌─────────────────────┐
│  Upstream AI API    │  ← Partially trusted (external)
└─────────────────────┘
```

## Authentication

### JWT Authentication

AgentGate supports JWT token authentication between the proxy and the policy engine:

```yaml
# docker-compose.yml
services:
  agentgate:
    environment:
      - AGENTGATE_AUTH_JWT_SECRET=${AGENTGATE_JWT_SECRET}
```

The proxy signs requests to the policy engine with the JWT secret. The policy engine validates the signature before processing the request.

**Security considerations:**
- Use a strong, randomly generated JWT secret (`openssl rand -hex 32`)
- Rotate the secret regularly
- Never use the default development secret in production

### mTLS Authentication

For higher security environments, AgentGate supports mutual TLS between the proxy and policy engine:

```bash
# Generate certificates
./scripts/gen_certs_dev.sh
```

The certificates are stored in `certs/`:
- `ca.crt` / `ca.key` — Certificate authority
- `server.crt` / `server.key` — Server certificate
- `agent-*.crt` / `agent-*.key` — Client certificates

Enable mTLS in `config.json`:
```json
{ "tls": { "mode": "required" } }
```

### API Key Authentication

AI clients authenticate to the proxy using the `x-api-key` header:

```http
POST /v1/messages HTTP/1.1
x-api-key: test-key
```

The proxy passes this header to the upstream. API keys can be:
- Simple shared keys (development)
- Per-agent keys (auditing)
- Upstream API keys (passthrough to AI provider)

## Threat Model

### Attack Vectors

| Attack Vector | Description | Severity | Mitigation |
|---------------|-------------|----------|------------|
| **Policy bypass** | Agent crafts request to avoid tool detection | High | Recursive content parsing; all content formats normalized |
| **Rate limit bypass** | Agent rotates X-Agent-ID to reset limits | Medium | IP-based fallback limiting; combined IP+Agent-ID tracking |
| **Audit tampering** | Attacker modifies on-disk audit log | High | SHA256 chain; Merkle root signing; any modification invalidates chain |
| **License bypass** | Attacker removes license check | Medium | License check compiled into binary; must explicitly set env var |
| **Memory scraping** | Extracts API keys from process memory | Medium | Secrets zeroized on drop; containers run with restricted caps |
| **Docker escape** | Breaks out of container to host | High | Non-root containers; minimal capabilities; SELinux `:z` labels |
| **Prompt injection** | Agent's prompt causes dangerous tool use | Medium | Policy engine blocks tool calls regardless of how they were generated |
| **Upstream compromise** | AI provider returns malicious response | Low | Response filtering (planned in v0.4) |

### Assumptions

This threat model assumes:
- The host OS is secure and properly configured
- Docker daemon is up-to-date and securely configured
- Network access to the host is firewalled
- Secrets are managed appropriately (not in version control)
- AI clients are running in a trusted user context

## Audit Trail

### Hash Chain

Every policy decision is recorded in a tamper-evident audit log:

```
Entry N:   [timestamp | agent | tool | command_hash | decision | policy_id | reason | prev_hash | nonce]
           → SHA256(entry) = hash_N

Entry N+1: [timestamp | agent | tool | command_hash | decision | policy_id | reason | prev_hash=hash_N | nonce]
           → SHA256(entry) = hash_{N+1}
```

If any entry is modified, all subsequent hashes change, making tampering detectable.

### Merkle Tree Signing

Periodically (every 1000 entries), the current hash chain root is signed with the RSA private key:

```text
Merkle root = SHA256(hash_0 || hash_1 || ... || hash_N)
Signature = RSA_sign(private_key, Merkle root)
```

The signature can be verified with the public key:

```text
RSA_verify(public_key, Merkle root, signature) → valid/invalid
```

### Audit Verification

```python
import hashlib
from cryptography.hazmat.primitives import hashes, asymmetric

def verify_audit_chain(entries, public_key_pem):
    """Verify the integrity of an audit log chain."""
    public_key = asymmetric.rsa.RSAPublicKey.from_pem(public_key_pem)
    prev_hash = b''
    
    for entry in entries:
        # Construct the entry bytes
        entry_bytes = construct_entry_bytes(entry)
        
        # Verify the hash chain
        expected_hash = hashlib.sha256(entry_bytes + prev_hash).digest()
        if expected_hash != bytes.fromhex(entry['hash']):
            return False, f"Hash mismatch at entry {entry['seq']}"
        
        prev_hash = expected_hash
    
    # Verify the Merkle root signature
    root_hash = hashlib.sha256(prev_hash).digest()
    try:
        public_key.verify(
            base64.b64decode(entries[-1]['signature']),
            root_hash,
            asymmetric.padding.PKCS1v15(),
            hashes.SHA256()
        )
        return True, "Audit chain verified, signature valid"
    except:
        return False, "Invalid Merkle root signature"
```

## Production Hardening Checklist

### Required

- [ ] Disable `SKIP_LICENSE` — Set up a real license server
- [ ] Set a strong JWT secret (`openssl rand -hex 32`)
- [ ] Replace all default passwords and API keys
- [ ] Restrict exposed ports (only 8080 should be external)
- [ ] Enable Docker's `read_only: true` for agentgate container
- [ ] Set resource limits on all containers
- [ ] Configure Docker daemon for logging and security

### Recommended

- [ ] Enable mTLS between proxy and agentgate
- [ ] Configure audit log persistence (bind mount)
- [ ] Set up log shipping to SIEM
- [ ] Enable Prometheus monitoring and alerting
- [ ] Use secrets manager (Vault, AWS Secrets Manager)
- [ ] Run containers with `--cap-drop=ALL`
- [ ] Use a read-only root filesystem for all containers
- [ ] Implement regular key rotation

### Advanced

- [ ] Deploy behind a reverse proxy (nginx, Traefik) with TLS termination
- [ ] Configure IP whitelisting for proxy access
- [ ] Implement network policies (Kubernetes NetworkPolicy)
- [ ] Run compliance validation (OpenSCAP, CIS benchmarks)
- [ ] Penetration test the deployment

## Related

- [**Threat Model**](../THREAT_MODEL.md) — Full threat model document
- [**Architecture**](03-architecture.md) — Component internals
- [**API Reference**](09-api-reference.md) — Audit endpoint docs
