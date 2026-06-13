---
title: Deployment
nav_order: 4
---

# Deployment

## New Machine Setup

### Prerequisites

| Requirement | Minimum Version | How to Check |
|-------------|----------------|--------------|
| Docker Engine | 20.10+ | `docker --version` |
| Docker Compose | v2 plugin | `docker compose version` |
| bash | 4.0+ | `bash --version` |
| curl | Any | `curl --version` |
| openssl | 1.1+ | `openssl version` |
| x86_64 CPU | — | `uname -m` |

### One-Command Setup

```bash
tar xzf agent-gate-portable.tar.gz
cd agent-gate-portable
sudo ./setup.sh
```

The setup script is fully interactive. It will:
1. Install any missing prerequisites
2. Ask which mode (OpenCode or Claude Code)
3. Prompt for API keys
4. Generate all configuration files
5. Build Docker containers (first build: 3-5 min)
6. Wait for health checks
7. Optionally configure OpenCode

### Manual Setup

See the [Quickstart](02-quickstart.md) guide for step-by-step manual setup instructions.

## Docker Compose Reference

### Services

```yaml
services:
  proxy:        # Go-based AI proxy, port 8080
  agentgate:    # Zig-based policy engine, port 8081 + 9090
  litellm:      # Python-based format translation, port 4000
  license-server:  # Go-based license issuer, port 4001
```

### Networks

```yaml
networks:
  agentgate-net:
    driver: bridge    # Internal Docker bridge network
```

### Volumes

```yaml
volumes:
  agentgate_data:     # Persistent data for AgentGate (audit logs, etc.)
  license_data:       # SQLite database for license server
```

## SELinux

On systems with SELinux enforcing (RHEL, Fedora, CentOS), add `:z` to all bind-mounted volumes:

```yaml
volumes:
  - ./litellm-config.yaml:/app/config.yaml:ro,z
  - ./config.json:/etc/agent-gate/config.json:ro,z
  - ./policies:/etc/agent-gate/policies:ro,z
```

The `:z` flag tells SELinux to relabel the mounted file so the container can read it.

## Production Deployment

### Resource Limits

Set Docker container resource limits in `docker-compose.yml`:

```yaml
services:
  proxy:
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.5'
  agentgate:
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: '0.5'
```

### Read-Only Root Filesystem

For agentgate, enable read-only root filesystem:

```yaml
services:
  agentgate:
    read_only: true
    tmpfs:
      - /tmp
```

### Health Check Configuration

```yaml
services:
  agentgate:
    healthcheck:
      test: ["CMD", "wget", "-q", "http://127.0.0.1:8080/health", "-O", "/dev/null"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
```

### Prometheus Monitoring

AgentGate exposes Prometheus metrics on port 9090:

```yaml
# docker-compose.yml
services:
  agentgate:
    ports:
      - "9090:9090"
```

Key metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `agentgate_policy_decisions_total` | Counter | Total policy decisions, labeled by decision (allow/deny) |
| `agentgate_policy_latency_microseconds` | Histogram | Policy decision latency distribution |
| `agentgate_audit_entries_total` | Counter | Total audit log entries |
| `agentgate_rate_limited_total` | Counter | Total rate-limited requests |
| `agentgate_active_agents` | Gauge | Currently active agent sessions |

### Log Shipping

Configure Docker log driver for shipping logs to your logging infrastructure:

```yaml
services:
  proxy:
    logging:
      driver: "awslogs"        # or "gelf", "fluentd", "syslog"
      options:
        awslogs-group: "agentgate-cage"
        awslogs-region: "us-east-1"
        awslogs-stream: "proxy"
```

## Architecture-Specific Notes

### ARM64 (Apple Silicon, Raspberry Pi)

The Zig Dockerfile targets `x86_64-linux-musl`. On ARM64 hosts, Docker Desktop emulates x86_64, which adds build time. The runtime performance is still acceptable.

To improve build speed on ARM64, modify the Dockerfile:
```dockerfile
# Change the build target to native:
RUN zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe install
```

### Air-Gapped Environments

For environments without internet access:
1. Build all Docker images on a machine with internet
2. Export images: `docker save -o agentgate-images.tar agentgate-cage_proxy agentgate-cage_agentgate`
3. Import on target: `docker load -i agentgate-images.tar`
4. Pre-download LiteLLM: `docker pull ghcr.io/berriai/litellm:main-latest && docker save ...`

## Related

- [**Configuration**](05-configuration.md) — Environment variables and config files
- [**Quickstart**](02-quickstart.md) — Get running in 5 minutes
- [**Security**](08-security.md) — Production hardening checklist
