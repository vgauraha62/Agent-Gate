# 🏰 AgentGate Cage: Complete Technical PRD for Proxy + OS-Level Sandbox

## Executive Summary

This PRD provides a **complete, production-ready implementation plan** for AgentGate Cage — a local proxy + gVisor-based sandbox that intercepts ALL AI agent API requests and physically isolates code execution.

**Core Architecture:** API Proxy (intercepts at network layer) + gVisor Sandbox (isolates at OS level). This guarantees 100% enforcement regardless of agent cooperation .


## 🎯 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              YOUR LOCAL MACHINE                                 │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                         CLAUDE CODE PROCESS                              │    │
│  │  ANTHROPIC_BASE_URL = http://localhost:8080                             │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                      │                                           │
│                                      ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    AGENTGATE PROXY (Port 8080)                           │    │
│  │                                                                          │    │
│  │  ┌─────────────────────────────────────────────────────────────────┐    │    │
│  │  │ 1. Intercept API Request                                         │    │    │
│  │  │ 2. Extract tool calls (bash, read_file, etc.)                   │    │    │
│  │  │ 3. Check policy via AgentGate API (port 8081)                    │    │    │
│  │  │ 4. ALLOW → Forward to Anthropic/OpenAI                           │    │    │
│  │  │    DENY  → Return policy error, never reaches cloud              │    │    │
│  │  └─────────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                    │                              │                              │
│                    │ Forward (if ALLOW)           │ Policy check (internal)      │
│                    ▼                              ▼                              │
│  ┌─────────────────────────────┐    ┌─────────────────────────────────────────┐ │
│  │   ANTHROPIC/OPENAI API      │    │      AGENTGATE POLICY ENGINE            │ │
│  │   (Cloud)                    │    │      (Port 8081)                        │ │
│  │   Returns real responses     │    │      - Evaluate allow/deny              │ │
│  └─────────────────────────────┘    │      - Store audit logs                  │ │
│                                      └─────────────────────────────────────────┘ │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    GVISOR SANDBOX (OS-Level Isolation)                   │    │
│  │                                                                          │    │
│  │  ┌─────────────────────────────────────────────────────────────────┐    │    │
│  │  │  Docker Container with runtime=runsc (gVisor)                    │    │    │
│  │  │  - Read-only root filesystem                                     │    │    │
│  │  │  - Only /workspace and /tmp mounted                              │    │    │
│  │  │  - No access to ~/.aws, ~/.ssh, .env                             │    │    │
│  │  │  - No network egress (or limited to proxy)                       │    │    │
│  │  │  - All capabilities dropped                                      │    │    │
│  │  └─────────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```


## 🔧 Core Components & Technology Stack

| Component | Technology | Purpose | Source |
|-----------|-----------|---------|--------|
| **API Proxy** | Go (claude-code-proxy pattern) or Python (oc-cc-proxy pattern) | Intercept Anthropic/OpenAI API requests |  |
| **Policy Engine** | Your existing AgentGate API (Zig) | Allow/deny decisions, audit logging | Your code |
| **Sandbox Runtime** | gVisor (runsc) | OS-level isolation, system call interception |  |
| **Container Orchestration** | Docker + runsc runtime | Sandbox lifecycle management |  |
| **Kubernetes (Enterprise)** | GKE Agent Sandbox + SandboxWarmPool | Production-scale sandbox pools |  |
| **Security Gateway** | MCPKernel (optional integration) | Additional policy enforcement, taint tracking |  |


## 📋 Implementation Phases (Day-by-Day)

### Phase 0: Environment Setup (Day 1)

**Goal:** Install all required tools and verify sandbox runtime.

| Time | Task | Commands/Details |
|------|------|------------------|
| 1 hour | Install Docker | `curl -fsSL https://get.docker.com \| sh` |
| 30 min | Install gVisor (runsc) | Follow gVisor installation guide  |
| 30 min | Verify gVisor | `docker run --runtime=runsc --rm hello-world` |
| 1 hour | Install Go 1.21+ | `wget https://go.dev/dl/go1.21.5.linux-amd64.tar.gz` |
| 1 hour | Clone reference projects | `git clone https://github.com/nielspeter/claude-code-proxy` |

**Success Criteria:** `docker run --runtime=runsc --rm alpine echo "gVisor works"` succeeds.

### Phase 1: Basic API Proxy (Day 2-3)

**Goal:** Create a local proxy that intercepts Anthropic API requests and forwards to cloud.

**Architecture Reference:** claude-code-proxy pattern from search results .

| Task | Description | Time |
|------|-------------|------|
| 1.1 | Create HTTP proxy server in Go | 2 hours |
| 1.2 | Implement `/v1/messages` endpoint handler | 2 hours |
| 1.3 | Add request/response passthrough to Anthropic | 2 hours |
| 1.4 | Add streaming response support | 2 hours |
| 1.5 | Test with Claude Code | 1 hour |

**Key Code Structure (Go):**

```go
// proxy.go
package main

import (
    "net/http"
    "net/http/httputil"
    "net/url"
)

func main() {
    // Target Anthropic API
    remote, _ := url.Parse("https://api.anthropic.com")
    proxy := httputil.NewSingleHostReverseProxy(remote)
    
    // Custom request handler for policy check
    http.HandleFunc("/v1/messages", func(w http.ResponseWriter, r *http.Request) {
        // 1. Read request body
        // 2. Extract tool calls
        // 3. Call AgentGate policy engine (port 8081)
        // 4. If DENY, return 403
        // 5. If ALLOW, forward to Anthropic
        proxy.ServeHTTP(w, r)
    })
    
    http.ListenAndServe(":8080", nil)
}
```

**Configuration for Claude Code:**

```json
// ~/.claude/settings.json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8080",
    "ANTHROPIC_API_KEY": "dummy-key-proxy-will-handle"
  }
}
```

### Phase 2: Policy Integration (Day 4-5)

**Goal:** Connect proxy to existing AgentGate API for allow/deny decisions.

| Task | Description | Time |
|------|-------------|------|
| 2.1 | Add HTTP client to call AgentGate API (port 8081) | 1 hour |
| 2.2 | Implement tool call extraction from request | 2 hours |
| 2.3 | Add policy decision caching (reduce latency) | 1 hour |
| 2.4 | Implement DENY response formatting | 1 hour |
| 2.5 | Add audit logging integration | 2 hours |

**Policy Check API Contract:**

```json
// Request to AgentGate (port 8081)
POST /v1/check
{
  "agent_id": "claude-code",
  "tool": "bash",
  "command": "cat .env",
  "path": ".env"
}

// Response
{
  "decision": "DENY",
  "policy_id": "block-secrets",
  "reason": ".env files contain credentials"
}
```

### Phase 3: gVisor Sandbox Integration (Day 6-8)

**Goal:** Run Claude Code inside gVisor sandbox with restricted access.

**Reference:** MAGI (Multi-Agent gVisor Isolation) pattern from search results .

| Task | Description | Time |
|------|-------------|------|
| 3.1 | Create Dockerfile with Claude Code installation | 2 hours |
| 3.2 | Configure Docker to use runsc runtime | 1 hour |
| 3.3 | Set up volume mounts (workspace read-write, secrets read-only/blocked) | 2 hours |
| 3.4 | Configure network isolation (no external egress) | 1 hour |
| 3.5 | Test sandbox with policy enforcement | 2 hours |

**Dockerfile with gVisor:**

```dockerfile
# Dockerfile
FROM alpine:latest

RUN apk add --no-cache nodejs npm bash

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN adduser -D -u 1000 claude

USER claude
WORKDIR /home/claude

# Claude Code will use host's proxy via host.docker.internal
CMD ["sh", "-c", "export ANTHROPIC_BASE_URL=http://host.docker.internal:8080 && claude"]
```

**Docker Run with gVisor:**

```bash
docker run --runtime=runsc \
  -v /home/user/workspace:/workspace:rw \
  -v /tmp:/tmp:rw \
  --read-only \
  --cap-drop ALL \
  --network none \
  claude-sandbox:latest
```

### Phase 4: GKE Agent Sandbox (Enterprise - Day 9-11)

**Goal:** Deploy scalable sandbox infrastructure on Kubernetes for enterprise customers.

**Reference:** GKE Agent Sandbox deployment pattern .

| Task | Description | Time |
|------|-------------|------|
| 4.1 | Create GKE cluster with gVisor node pool | 2 hours |
| 4.2 | Deploy SandboxTemplate and SandboxWarmPool | 2 hours |
| 4.3 | Deploy Sandbox Router | 1 hour |
| 4.4 | Deploy AgentGate proxy as Kubernetes service | 2 hours |
| 4.5 | Configure network policies | 1 hour |

**SandboxTemplate YAML:**

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: agentgate-sandbox-template
spec:
  podTemplate:
    spec:
      runtimeClassName: gvisor
      containers:
      - name: agentgate-proxy
        image: agentgate/proxy:latest
        ports:
        - containerPort: 8080
      - name: claude-sandbox
        image: claude-sandbox:latest
        securityContext:
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
```

### Phase 5: MCPKernel Security Integration (Optional - Day 12-13)

**Goal:** Add MCPKernel security gateway for additional policy enforcement and taint tracking .

| Task | Description | Time |
|------|-------------|------|
| 5.1 | Install MCPKernel | `pip install "mcpkernel[all]"` | 30 min |
| 5.2 | Configure MCPKernel as security gateway | 2 hours |
| 5.3 | Integrate with AgentGate policy engine | 2 hours |
| 5.4 | Enable taint tracking and DLP | 1 hour |

**MCPKernel Gateway Configuration:**

```bash
# Run MCPKernel security gateway
mcpkernel serve --host 127.0.0.1 --port 8000 --policy strict --taint
```

**MCPKernel features that enhance AgentGate:**
- Tool poisoning detection (hidden instructions in tool descriptions)
- Taint tracking for secrets and PII across tool boundaries
- DLP chain detection (prevents data leaks across multiple tools)
- 4 sandbox backends (Docker, Firecracker, WASM, Microsandbox)
- Sigstore-signed audit logs 

### Phase 6: Testing & Validation (Day 14-15)

**Goal:** End-to-end validation of proxy + sandbox.

| Task | Description | Time |
|------|-------------|------|
| 6.1 | Test blocked operations (.env, /etc/passwd) | 2 hours |
| 6.2 | Test allowed operations (/workspace) | 1 hour |
| 6.3 | Test streaming responses | 1 hour |
| 6.4 | Performance benchmark (latency, throughput) | 2 hours |
| 6.5 | Security validation (attempt sandbox escape) | 2 hours |


## 📊 Complete Tech Stack Summary

| Layer | Technology | Purpose | Source |
|-------|-----------|---------|--------|
| **Proxy** | Go (with httputil.ReverseProxy) | High-performance API interception |  |
| **Alternative Proxy** | Python LiteLLM (oc-cc-proxy) | Quick prototyping, model routing |  |
| **Policy Engine** | Zig (your existing AgentGate) | Allow/deny decisions, audit | Your code |
| **Sandbox** | gVisor (runsc) + Docker | OS-level isolation |  |
| **K8s Sandbox** | GKE Agent Sandbox | Enterprise-scale sandbox pools |  |
| **Security Gateway** | MCPKernel | Taint tracking, DLP, poisoning detection |  |
| **Container Runtime** | Docker / containerd | Container lifecycle | — |
| **Orchestration** | Docker Compose (dev), Kubernetes (prod) | Deployment management | — |


## ✅ Success Criteria

- [ ] Proxy intercepts all Claude Code API requests via `ANTHROPIC_BASE_URL`
- [ ] gVisor sandbox blocks access to `.env`, `~/.ssh`, `~/.aws`
- [ ] Policy engine returns DENY for dangerous operations, never reaches cloud
- [ ] ALLOW operations receive real responses from Anthropic/OpenAI
- [ ] Audit logs capture every decision
- [ ] gVisor runs with `--runtime=runsc`, dropped capabilities, read-only root 
- [ ] MCPKernel integration (optional) provides taint tracking 
- [ ] One-command installer for solo developers


## 🚀 Day 1: First Command

```bash
# Install gVisor
curl -fsSL https://gvisor.dev/archive.key | sudo apt-key add -
sudo add-apt-repository "deb https://storage.googleapis.com/gvisor/releases release main"
sudo apt-get update && sudo apt-get install -y runsc
sudo runsc install
sudo systemctl restart docker

# Verify
docker run --runtime=runsc --rm alpine echo "gVisor works"
```

**Ready to begin. I will now start Phase 1 implementation.**
