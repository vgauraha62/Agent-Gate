# =============================================================================
# Stage 1 — Builder: compile agent-gate with musl for Alpine compatibility
# =============================================================================
FROM debian:bookworm-slim AS builder

# Install tools needed to download and extract Zig
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Download and install Zig 0.15.2 (matching .zig-version)
RUN curl -fsSL \
    https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /app

# Copy only what's needed for the build (leverages Docker layer caching)
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY tools/ tools/

# Build with musl target for full static linking on Alpine
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe install

# =============================================================================
# Stage 2 — Runtime: minimal Alpine image
# =============================================================================
FROM alpine:latest

# ca-certificates are needed if the binary makes any outbound HTTPS calls
RUN apk add --no-cache ca-certificates

# Copy the compiled binary from the builder stage
COPY --from=builder /app/zig-out/bin/agent-gate /usr/local/bin/agent-gate

# Bake a container-appropriate default configuration.
# All values can be overridden at runtime via AGENTGATE_* environment variables.
# IMPORTANT: Override AGENTGATE_AUTH_JWT_SECRET in production.
RUN mkdir -p /etc/agent-gate && \
    cat > /etc/agent-gate/config.json << 'CONFIG'
{
  "server": {
    "port": 8080,
    "host": "0.0.0.0",
    "workers": 4
  },
  "auth": {
    "jwt_secret": "change-me-in-production-0123456789",
    "auth_timeout_ms": 100
  },
  "policy": {
    "policy_timeout_ms": 50,
    "max_policies": 1000,
    "policy_file": "/etc/agent-gate/policies/default.json"
  },
  "audit": {
    "buffer_size": 1024,
    "audit_timeout_ms": 10
  },
  "request": {
    "request_timeout_ms": 5000,
    "max_body_size": 65536,
    "max_headers": 64
  },
  "shutdown": {
    "grace_period_ms": 30000,
    "enable_signals": true
  },
  "tls": {
    "mode": "external",
    "trusted_proxy_ip": "127.0.0.1",
    "require_ssl_headers": true,
    "external_policy": "strict"
  }
}
CONFIG

# Copy the default policy file (used when AGENTGATE_POLICY_POLICY_FILE is not set)
COPY policies/default.json /etc/agent-gate/policies/default.json

# Port 8080  — main proxy traffic
# Port 9090  — Prometheus metrics (when implemented)
EXPOSE 8080 9090

# Default entrypoint — use --config to point at the baked config
ENTRYPOINT ["/usr/local/bin/agent-gate"]
CMD ["--config", "/etc/agent-gate/config.json"]
