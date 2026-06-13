---
title: Roadmap
nav_order: 13
---

# Roadmap

## Current Status: Beta (v0.1)

AgentGate Cage is functional and tested for development workflows. It is not yet production-ready — see the v1.0 checklist below for what's needed.

## Version History

### v0.1 (Current) — Foundation

**Released**: June 2026

**Features:**
- ✅ Single-node Docker Compose deployment
- ✅ Policy enforcement for AI tool invocations (bash, read, write, edit)
- ✅ Merkle-signed tamper-evident audit trail
- ✅ OpenCode (DeepSeek via Zen API) support
- ✅ Claude Code (Anthropic) support
- ✅ LiteLLM format translation (Anthropic ↔ OpenAI)
- ✅ Free development mode (`AGENTGATE_PROXY_SKIP_LICENSE`)
- ✅ One-command new machine setup (`setup.sh`)
- ✅ SELinux `:z` volume mount compatibility
- ✅ mTLS certificate generation and support
- ✅ Prometheus metrics
- ✅ Static binaries (Zig + Go, musl-linked, Alpine-based)
- ✅ 0 external dependencies at runtime

## Upcoming Releases

### v0.2 — Production Readiness

**Target**: Q3 2026

| Feature | Status | Description |
|---------|--------|-------------|
| Hot-reload policies | 🟡 Planned | Update `policies/ai-agent.json` without restarting containers |
| Multi-tenant config | 🟡 Planned | Different policy sets for different teams/projects |
| Audit log streaming | 🟡 Planned | Stream audit logs to S3, Splunk, ELK, or stdout |
| Prometheus alerting rules | 🟡 Planned | Pre-built alert rules for common scenarios |
| Helm chart | 🟡 Planned | Deploy on Kubernetes with one `helm install` |
| Terraform provider | 🟡 Planned | Infrastructure-as-code for agentgate deployments |
| GitHub Actions CI | 🟡 Planned | Automated build, test, and release pipeline |
| Container image registry | 🟡 Planned | Pre-built images on ghcr.io (no local build needed) |

### v0.3 — Control Plane

**Target**: Q4 2026

| Feature | Status | Description |
|---------|--------|-------------|
| Cloud control plane | 🔴 Research | Centralized policy management across your fleet |
| SSO/SAML/OIDC | 🔴 Research | Enterprise single sign-on for policy management |
| Policy recommendation engine | 🔴 Research | ML-based tool call analysis to suggest policies |
| Real-time dashboard | 🔴 Research | React + WebSocket dashboard for live monitoring |
| Programmatic policy API | 🔴 Research | REST API for managing policies at scale |
| Multi-cluster support | 🔴 Research | Manage policies across multiple Kubernetes clusters |

### v0.4 — Content Safety

**Target**: Q1 2027

| Feature | Status | Description |
|---------|--------|-------------|
| Response content filtering | 🔴 Research | Block sensitive data in LLM responses |
| PII redaction | 🔴 Research | Automatically redact PII (SSN, credit cards, etc.) |
| Prompt injection detection | 🔴 Research | Detect and block prompt injection attempts |
| Data leakage prevention | 🔴 Research | Block sensitive data from being sent to LLMs |
| Compliance mode | 🔴 Research | Pre-built compliance policies (HIPAA, GDPR, SOC2) |

### v1.0 — Enterprise

**Target**: Q2 2027

| Feature | Status | Description |
|---------|--------|-------------|
| High availability | 🔴 Research | Multi-region, active-active deployment |
| Enterprise SSO | 🔴 Research | Okta, Azure AD, Ping Identity integration |
| SOC2 Type II audit | 🔴 Research | Pre-built audit package for SOC2 certification |
| 99.99% uptime SLA | 🔴 Research | Production-grade reliability guarantees |
| Dedicated support | 🔴 Research | Direct support channels for enterprise customers |
| Air-gapped deployment | 🔴 Research | Fully offline operation for classified environments |

## Feature Requests

We welcome feature requests and contributions. If you'd like to see something on the roadmap, please:

1. Check the existing issues
2. Open a new issue with the "feature request" label
3. Describe the use case, expected behavior, and any implementation ideas

## How to Contribute

AgentGate is open source (MIT). Contributions are welcome:

- **Code**: Submit PRs for bug fixes, features, or improvements
- **Documentation**: Improve docs, fix typos, add examples
- **Testing**: Write tests, report bugs, add edge cases
- **Feedback**: Share your use cases and requirements

## Related

- [**Overview**](01-overview.md) — What is AgentGate Cage?
- [**Architecture**](03-architecture.md) — System design
- [**Whitepaper**](../AGENTGATE_WHITEPAPER.md) — Full technical analysis
