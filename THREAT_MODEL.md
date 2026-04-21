# Threat Model

## Assets

| Asset | Storage | Protection |
|-------|---------|------------|
| JWT Secrets | Memory only | Zeroize on drop |
| Policy Decisions | Audit log | Merkle tree signature |
| Agent Identities | mTLS certs | Hash-based reference |

## Trust Boundaries

```
┌─────────────────────────────────────┐
│  Untrusted (External Agents)        │
│              │                      │
│              ▼                      │
│  ┌───────────────────┐             │
│  │   TLS Boundary    │             │
│  └───────────────────┘             │
│              │                      │
│              ▼                      │
│  ┌───────────────────┐             │
│  │   AgentGate       │  Trusted    │
│  │   (This Process)  │             │
│  └───────────────────┘             │
│              │                      │
│              ▼                      │
│  ┌───────────────────┐             │
│  │   Upstream        │  Partially  │
│  │   Services        │  Trusted    │
│  └───────────────────┘             │
└─────────────────────────────────────┘
```

## Attack Vectors & Mitigations

### 1. Timing Attacks
- **Threat**: Signature comparison leaks timing info
- **Mitigation**: Constant-time `std.crypto.timing.equal`

### 2. Memory Disclosure
- **Threat**: Secrets persist in memory after use
- **Mitigation**: `Secret.zeroize()` before deallocation

### 3. Policy Bypass
- **Threat**: Runtime policy manipulation
- **Mitigation**: Compile-time policy generation, read-only after build

### 4. Audit Tampering
- **Threat**: Delete/modify audit entries
- **Mitigation**: Merkle tree root signed with server key

### 5. Replay Attacks
- **Threat**: Reuse valid JWT
- **Mitigation**: Expiration checks, optional nonce tracking

### 6. DoS via Resource Exhaustion
- **Threat**: Flood connections, exhaust memory
- **Mitigation**: Connection limits, arena caps, request timeouts

## Assumptions

1. TLS provides confidentiality/integrity in transit
2. Filesystem config is trusted (not user-writable)
3. Server private keys are securely managed externally

## Out of Scope

- Physical access attacks
- Side-channel attacks (power analysis, EM)
- Compiler/toolchain compromises
