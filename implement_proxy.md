# 🏰 AgentGate Cage — Implementation Plan

> **Proxy (Go, MVP) + Policy Engine (Zig, existing)**  
> Full SSE streaming, per-agent key passthrough, tool-aware policies  
> gVisor sandbox deferred to v2

---

## 📋 Executive Summary

This plan extends the existing **AgentGate** (Zig policy enforcement sidecar) with an **AI API proxy** (Go, MVP) that intercepts Claude Code / Anthropic API requests, extracts tool calls, checks them against policies, and forwards allowed requests to the upstream API.

**Architecture**: Two-service Docker Compose:
- **`proxy`** (Go, port 8080) — Anthropic API reverse proxy with tool extraction + policy enforcement
- **`agentgate`** (Zig, port 8081) — Existing policy engine, audit logging, metrics

> **v2 Roadmap**: Replace Go proxy with native Zig implementation for single-binary deployment.

---

## 🎯 Architecture

```
┌─ Claude Code ───────────────────────────────────────┐
│ ANTHROPIC_BASE_URL = http://localhost:8080          │
│ x-api-key: <real Anthropic key>                     │
└──────────┬──────────────────────────────────────────┘
           │
           ▼
┌─ AGENTGATE PROXY (Go) ── Port 8080 ────────────────┐
│                                                      │
│  Routes:                                             │
│  ┌─ /v1/messages → Anthropic proxy                  │
│  │  1. Parse request, extract tool_calls            │
│  │  2. POST /check to AgentGate:8081                │
│  │  3. ALLOW → forward to api.anthropic.com         │
│  │         → SSE passthrough                        │
│  │  4. DENY  → return 403 policy error              │
│  │                                                   │
│  └─ /health → health check (passthrough to AG)      │
└──────────┬──────────────────────────────────────────┘
           │                  ▲
           │ POST /check     │
           ▼                  │
┌─ AGENTGATE CORE (Zig) ── Port 8081 ─────────────────┐
│                                                      │
│  Existing endpoints:                                 │
│  ┌─ /health                                          │
│  ├─ /metrics                                         │
│  ├─ /check (policy evaluation)                       │
│  │  NEW: tool-aware conditions                       │
│  ├─ /v1/admin/* (hosted API key management)          │
│  ├─ /denied-requests                                 │
│  └─ Audit logging, metrics, denial tracking          │
└──────────────────────────────────────────────────────┘
```

---

## 🛠️ Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **API Proxy** | Go (net/http) | Anthropic API interception, SSE passthrough |
| **Policy Engine** | Zig (existing) | Allow/deny decisions, tool-aware matching |
| **Audit Logger** | Zig (existing) | Tamper-evident audit trail |
| **Metrics** | Zig (existing) | Prometheus `/metrics` |
| **Orchestration** | Docker Compose | Two-service deployment |
| **Future Proxy** | Zig (v2) | Single-binary replacement |

---

## 📦 Project Structure (New/Modified Files)

```
agent-gate/
├── proxy/                          # NEW: Go proxy service
│   ├── go.mod                      # Go module definition
│   ├── go.sum
│   ├── main.go                     # Entry point, HTTP server
│   ├── config.go                   # Environment-based configuration
│   ├── anthropic/
│   │   ├── types.go                # Anthropic Messages API types
│   │   └── extract.go              # Tool call extraction from messages
│   ├── policy/
│   │   ├── client.go               # AgentGate HTTP client
│   │   └── response.go             # DENY error response formatting
│   ├── upstream/
│   │   ├── client.go               # Anthropic API HTTP client
│   │   └── stream.go               # SSE streaming passthrough
│   └── Dockerfile                  # Multi-stage Go build
├── policies/
│   └── ai-agent.json               # NEW: AI-optimized policy set
├── docs/
│   └── POLICY_API.md               # NEW: Go ↔ AgentGate contract
├── docker-compose.yml              # MODIFIED: proxy + agentgate
├── install.sh                      # NEW: One-command installer
└── src/
    └── policy/
        ├── types.zig               # MODIFIED: tool-aware conditions
        └── parser.zig              # MODIFIED: tool condition parser
```

---

## 🚀 Phase 0: Repository & Environment Setup (Day 1)

### Task 0.1 — Go proxy project skeleton

Create `proxy/` directory with Go module:

**proxy/go.mod:**
```
module github.com/agentgate/proxy

go 1.22
```

**proxy/main.go** — skeleton HTTP server on port 8080:
```go
package main

import (
    "log"
    "net/http"
    "os"
    "os/signal"
    "syscall"
)

func main() {
    cfg := LoadConfig()
    mux := http.NewServeMux()
    mux.HandleFunc("/v1/messages", handleMessages)
    mux.HandleFunc("/health", handleHealth)

    server := &http.Server{Addr: cfg.ListenAddr, Handler: mux}
    go func() {
        log.Printf("AgentGate Proxy starting on %s", cfg.ListenAddr)
        if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            log.Fatalf("Server error: %v", err)
        }
    }()

    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    log.Println("Shutting down...")
    server.Close()
}
```

### Task 0.2 — Define shared policy contract

Create `docs/POLICY_API.md` documenting the Go ↔ Zig contract:

```markdown
# Policy API Contract

## Endpoint
`POST /check` on AgentGate (port 8081)

## Request
```json
{
  "agent_id": "claude-code-session-abc123",
  "tool": "bash",
  "command": "cat /etc/passwd",
  "path": "/etc/passwd",
  "input": {
    "command": "cat /etc/passwd",
    "description": "..."
  }
}
```

## Response (ALLOW)
```json
{
  "allowed": true,
  "policy_id": "allow-bash"
}
```

## Response (DENY)
```json
{
  "allowed": false,
  "policy_id": "block-secrets",
  "reason": "Access to /etc/passwd blocked"
}
```
```

### Task 0.3 — Update Docker Compose

Two-service compose file (covered in Phase 3).

---

## 🚀 Phase 1: Go Proxy — Core Proxy (Days 2-4)

### Task 1.1 — Config system

**proxy/config.go:**
```go
package main

import "os"

type Config struct {
    ListenAddr      string
    AgentGateURL    string
    AnthropicAPIURL string
    PolicyTimeout   string
    UpstreamTimeout string
}

func LoadConfig() *Config {
    return &Config{
        ListenAddr:      getEnv("AGENTGATE_PROXY_LISTEN", ":8080"),
        AgentGateURL:    getEnv("AGENTGATE_PROXY_AGENTGATE_URL", "http://agentgate:8081"),
        AnthropicAPIURL: getEnv("AGENTGATE_PROXY_ANTHROPIC_URL", "https://api.anthropic.com"),
        PolicyTimeout:   getEnv("AGENTGATE_PROXY_POLICY_TIMEOUT", "5s"),
        UpstreamTimeout: getEnv("AGENTGATE_PROXY_UPSTREAM_TIMEOUT", "300s"),
    }
}

func getEnv(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}
```

### Task 1.2 — Anthropic Messages API types

**proxy/anthropic/types.go:**
```go
package anthropic

// Messages API request body
type MessagesRequest struct {
    Model       string        `json:"model"`
    Messages    []Message     `json:"messages"`
    System      string        `json:"system,omitempty"`
    MaxTokens   int           `json:"max_tokens"`
    Tools       []ToolDef     `json:"tools,omitempty"`
    ToolChoice  *ToolChoice   `json:"tool_choice,omitempty"`
    Stream      bool          `json:"stream,omitempty"`
    Temperature float64       `json:"temperature,omitempty"`
}

type Message struct {
    Role    string        `json:"role"`
    Content []ContentBlock `json:"content"`
}

type ContentBlock struct {
    Type string          `json:"type"`
    Text string          `json:"text,omitempty"`
    ID   string          `json:"id,omitempty"`
    Name string          `json:"name,omitempty"`
    Input json.RawMessage `json:"input,omitempty"`
}

type ToolDef struct {
    Name        string      `json:"name"`
    Description string      `json:"description"`
    InputSchema interface{} `json:"input_schema"`
}

type ToolChoice struct {
    Type string `json:"type"`
    Name string `json:"name,omitempty"`
}
```

### Task 1.3 — Tool call extraction

**proxy/anthropic/extract.go:**
```go
package anthropic

// ToolInvocation represents a tool call to check against policy
type ToolInvocation struct {
    AgentID string      `json:"agent_id"`
    Tool    string      `json:"tool"`
    Command string      `json:"command"`
    Path    string      `json:"path"`
    Input   interface{} `json:"input"`
}

// ExtractToolInvocations parses a MessagesRequest and extracts tool uses
// from the conversation history and tool definitions.
func ExtractToolInvocations(req *MessagesRequest, agentID string) []ToolInvocation {
    var invocations []ToolInvocation

    // Scan message content for tool_use blocks
    for _, msg := range req.Messages {
        for _, block := range msg.Content {
            if block.Type == "tool_use" {
                inv := ToolInvocation{
                    AgentID: agentID,
                    Tool:    block.Name,
                    Input:   block.Input,
                }
                // Extract semantic command/path from tool input
                extractToolArgs(block.Name, block.Input, &inv)
                invocations = append(invocations, inv)
            }
        }
    }
    // Also extract from the tools definitions themselves (for policy evaluation)
    for _, t := range req.Tools {
        invocations = append(invocations, ToolInvocation{
            AgentID: agentID,
            Tool:    t.Name,
            Input:   t.InputSchema,
        })
    }
    return invocations
}

func extractToolArgs(name string, input json.RawMessage, inv *ToolInvocation) {
    // Parse known tool schemas to extract command/path fields
    var fields map[string]interface{}
    if err := json.Unmarshal(input, &fields); err != nil {
        return
    }
    switch name {
    case "bash":
        if cmd, ok := fields["command"].(string); ok {
            inv.Command = cmd
        }
    case "read", "read_file", "write", "edit", "write_file":
        if p, ok := fields["path"].(string); ok {
            inv.Path = p
        }
        if cmd, ok := fields["content"].(string); ok {
            inv.Command = cmd
        }
    }
}
```

### Task 1.4 — AgentGate policy client

**proxy/policy/client.go:**
```go
package policy

import (
    "bytes"
    "encoding/json"
    "fmt"
    "net/http"
    "time"
)

type CheckRequest struct {
    AgentID string      `json:"agent_id"`
    Tool    string      `json:"tool"`
    Command string      `json:"command"`
    Path    string      `json:"path"`
    Input   interface{} `json:"input"`
}

type CheckResponse struct {
    Allowed  bool   `json:"allowed"`
    PolicyID string `json:"policy_id"`
    Reason   string `json:"reason,omitempty"`
}

type Client struct {
    baseURL    string
    httpClient *http.Client
}

func NewClient(baseURL string, timeout time.Duration) *Client {
    return &Client{
        baseURL: baseURL,
        httpClient: &http.Client{
            Timeout: timeout,
            Transport: &http.Transport{
                MaxIdleConns:        100,
                IdleConnTimeout:     90 * time.Second,
                DisableCompression:  true,
            },
        },
    }
}

func (c *Client) Check(req *CheckRequest) (*CheckResponse, error) {
    body, err := json.Marshal(req)
    if err != nil {
        return nil, fmt.Errorf("marshal request: %w", err)
    }

    resp, err := c.httpClient.Post(
        c.baseURL+"/check",
        "application/json",
        bytes.NewReader(body),
    )
    if err != nil {
        return nil, fmt.Errorf("http call: %w", err)
    }
    defer resp.Body.Close()

    var result CheckResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    return &result, nil
}
```

### Task 1.5 — Upstream Anthropic client

**proxy/upstream/client.go:**
```go
package upstream

import (
    "io"
    "net/http"
    "time"
)

type Client struct {
    baseURL    string
    httpClient *http.Client
    apiKey     string // Set per-request from incoming x-api-key
}

func NewClient(baseURL string, timeout time.Duration) *Client {
    return &Client{
        baseURL: baseURL,
        httpClient: &http.Client{
            Timeout: timeout,
            Transport: &http.Transport{
                MaxIdleConns:        50,
                IdleConnTimeout:     90 * time.Second,
            },
        },
    }
}

// ForwardRequest sends the original request to the upstream Anthropic API.
// Returns the full response (read completely for non-streaming).
func (c *Client) ForwardRequest(apiKey string, body []byte, headers http.Header) (*http.Response, error) {
    req, err := http.NewRequest("POST", c.baseURL+"/v1/messages", io.NopCloser(bytes.NewReader(body)))
    if err != nil {
        return nil, err
    }
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("x-api-key", apiKey)
    req.Header.Set("anthropic-version", headers.Get("anthropic-version"))

    return c.httpClient.Do(req)
}

// ForwardStream forwards a streaming request and copies SSE events to the writer.
func (c *Client) ForwardStream(apiKey string, body []byte, headers http.Header, w io.Writer) error {
    req, _ := http.NewRequest("POST", c.baseURL+"/v1/messages", io.NopCloser(bytes.NewReader(body)))
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("x-api-key", apiKey)
    req.Header.Set("anthropic-version", headers.Get("anthropic-version"))
    req.Header.Set("Accept", "text/event-stream")

    resp, err := c.httpClient.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    _, err = io.Copy(w, resp.Body)
    return err
}
```

### Task 1.6 — DENY response formatting

**proxy/policy/response.go:**
```go
package policy

import (
    "encoding/json"
    "fmt"
)

// DenyErrorResponse formats a policy violation as an Anthropic-compatible error.
func DenyErrorResponse(tool, policyID, reason string) []byte {
    resp := map[string]interface{}{
        "type": "error",
        "error": map[string]interface{}{
            "type":      "policy_error",
            "message":   fmt.Sprintf("Tool '%s' blocked by policy '%s': %s", tool, policyID, reason),
            "policy_id": policyID,
            "tool":      tool,
        },
    }
    data, _ := json.Marshal(resp)
    return data
}
```

### Task 1.7 — SSE streaming passthrough

**proxy/upstream/stream.go** — integrated into `ForwardStream` above.

The streaming logic is:
1. Parse `stream: true` from the incoming request body
2. If true, set `Accept: text/event-stream` on upstream request
3. Copy `resp.Body` directly to `http.ResponseWriter` with SSE headers
4. Flush after every write

```go
// In main.go handler for streaming:
func handleStreaming(w http.ResponseWriter, r *http.Request, upstreamResp *http.Response) {
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("Connection", "keep-alive")

    flusher, ok := w.(http.Flusher)
    if !ok {
        http.Error(w, "streaming unsupported", 500)
        return
    }

    buf := make([]byte, 4096)
    for {
        n, err := upstreamResp.Body.Read(buf)
        if n > 0 {
            w.Write(buf[:n])
            flusher.Flush()
        }
        if err != nil {
            break
        }
    }
}
```

### Task 1.8 — Main request handler

**proxy/main.go** (full handler):

```go
func handleMessages(w http.ResponseWriter, r *http.Request) {
    // 1. Read and parse incoming request
    body, _ := io.ReadAll(r.Body)
    var msgReq anthropic.MessagesRequest
    json.Unmarshal(body, &msgReq)

    // 2. Extract API key from incoming request (per-agent passthrough)
    apiKey := r.Header.Get("x-api-key")
    if apiKey == "" {
        http.Error(w, "missing x-api-key", 401)
        return
    }

    // 3. Extract tool calls
    agentID := r.Header.Get("X-Agent-ID") // optional agent identification
    tools := anthropic.ExtractToolInvocations(&msgReq, agentID)

    // 4. Check each tool against policy
    policyClient := policy.NewClient(cfg.AgentGateURL, policyTimeout)
    for _, tool := range tools {
        result, err := policyClient.Check(&policy.CheckRequest{
            AgentID: agentID,
            Tool:    tool.Tool,
            Command: tool.Command,
            Path:    tool.Path,
            Input:   tool.Input,
        })
        if err != nil || result == nil || !result.Allowed {
            reason := "policy denied"
            if result != nil && result.Reason != "" {
                reason = result.Reason
            }
            w.WriteHeader(403)
            w.Write(policy.DenyErrorResponse(tool.Tool, result.PolicyID, reason))
            return
        }
    }

    // 5. Forward to upstream (streaming or non-streaming)
    upstreamClient := upstream.NewClient(cfg.AnthropicAPIURL, upstreamTimeout)
    if msgReq.Stream {
        upstreamClient.ForwardStream(apiKey, body, r.Header, w)
    } else {
        resp, _ := upstreamClient.ForwardRequest(apiKey, body, r.Header)
        io.Copy(w, resp.Body)
    }
}
```

### Task 1.9 — Go proxy Dockerfile

```dockerfile
# proxy/Dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /proxy .

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /proxy /usr/local/bin/proxy
EXPOSE 8080
CMD ["proxy"]
```

---

## 🚀 Phase 2: Zig AgentGate — Policy Engine Extension (Days 3-5)

### Task 2.1 — Add tool-aware conditions to `src/policy/types.zig`

Extend the `Condition` union with tool-related variants:

```zig
pub const Condition = union(enum) {
    agent_id: []const u8,
    path: []const u8,
    method: Method,
    methods: []const Method,
    slow_match: u64,

    // NEW: Tool-aware conditions for AI agent proxy
    /// Match on tool name (e.g., "bash", "read_file", "edit")
    tool: []const u8,
    /// Match on tool name with wildcard (e.g., "tool:*", "read_*")
    tool_pattern: []const u8,
    /// Substring/regex match on command content (e.g., "rm -rf", "cat .env")
    command_pattern: []const u8,
    /// Substring/prefix match on file path accessed by tool
    path_pattern: []const u8,
};
```

### Task 2.2 — Implement matching logic for new conditions

Add `matches()` implementations:

```zig
fn matchesTool(pattern: []const u8, tool: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    // Check for suffix wildcard (e.g., "read_*")
    if (pattern.len >= 2 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, tool, prefix);
    }
    return std.mem.eql(u8, pattern, tool);
}

fn matchesCommandPattern(pattern: []const u8, command: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.eql(u8, pattern, "*")) return true;
    // Simple substring match (can be extended to regex later)
    return std.mem.indexOf(u8, command, pattern) != null;
}

fn matchesPathPattern(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.eql(u8, pattern, "*")) return true;
    // Prefix match (e.g., "/workspace/*")
    if (pattern.len >= 2 and pattern[pattern.len - 2] == '/' and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 2];
        return std.mem.startsWith(u8, path, prefix);
    }
    // Exact match or substring
    return std.mem.eql(u8, pattern, path) or std.mem.indexOf(u8, path, pattern) != null;
}
```

### Task 2.3 — Update `RequestContext` for tool checks

```zig
pub const RequestContext = struct {
    agent_id: []const u8,
    path: []const u8,
    method: Method,

    // NEW: Tool-aware fields
    tool_name: []const u8,       // "bash", "read_file", etc.
    tool_command: []const u8,    // The command/content string
    tool_path: []const u8,       // The path being accessed

    pub fn init(agent_id: []const u8, path: []const u8, method: Method) Self {
        return Self{
            .agent_id = agent_id,
            .path = path,
            .method = method,
            .tool_name = "",
            .tool_command = "",
            .tool_path = "",
        };
    }

    pub fn initTool(agent_id: []const u8, tool: []const u8, command: []const u8, path: []const u8) Self {
        return Self{
            .agent_id = agent_id,
            .path = if (path.len > 0) path else tool,
            .method = .POST,
            .tool_name = tool,
            .tool_command = command,
            .tool_path = path,
        };
    }
};
```

### Task 2.4 — Update policy parser in `src/policy/parser.zig`

Add parsing for new match fields:

```zig
fn parseCondition(allocator: std.mem.Allocator, match: std.json.ObjectMap) !Condition {
    // ... existing code for agent_id, path, method, methods ...

    // NEW: Tool conditions
    if (match.get("tool")) |tool_val| {
        return Condition{ .tool = tool_val.string };
    }
    if (match.get("tool_pattern")) |pat_val| {
        return Condition{ .tool_pattern = pat_val.string };
    }
    if (match.get("command_pattern")) |cmd_val| {
        return Condition{ .command_pattern = cmd_val.string };
    }
    if (match.get("path_pattern")) |pp_val| {
        return Condition{ .path_pattern = pp_val.string };
    }

    return error.InvalidCondition;
}
```

### Task 2.5 — Update `/check` endpoint handler

Modify `handleCheckRequest` in `src/server/http.zig` to accept and act on tool fields:

```zig
fn handleCheckRequest(self: *Self, client_fd: c_int, body: []const u8, agent_id: [32]u8) bool {
    // Parse the new extended request format
    const check = parseCheckRequestExtended(body);

    // Build request context (tool-aware or standard)
    const ctx = if (check.isToolRequest)
        types.RequestContext.initTool(
            std.fmt.bytesToHex(agent_id, .lower),
            check.tool,
            check.command,
            check.path,
        )
    else
        types.RequestContext.init(
            std.fmt.bytesToHex(agent_id, .lower),
            check.path,
            types.Method.parse(check.method) catch .GET,
        );

    // Evaluate with timeout
    const decision = self.policy_set.evaluateWithTimeout(&ctx, self.policy_timeout_ms) catch {
        sendJsonResponse(client_fd, .gateway_timeout,
            "{\"allowed\":false,\"policy_id\":\"timeout\"}");
        return false;
    };

    // ... existing allow/deny response logic ...
}
```

### Task 2.6 — AI agent example policies

**policies/ai-agent.json:**
```json
{
  "version": "1",
  "policies": [
    { "id": "allow-read-workspace", "effect": "allow", "match": { "tool": "read", "path_pattern": "/workspace/*" } },
    { "id": "allow-write-workspace", "effect": "allow", "match": { "tool": "write", "path_pattern": "/workspace/*" } },
    { "id": "allow-edit-workspace", "effect": "allow", "match": { "tool": "edit", "path_pattern": "/workspace/*" } },
    { "id": "allow-bash", "effect": "allow", "match": { "tool": "bash" } },
    { "id": "allow-read-file", "effect": "allow", "match": { "tool": "read_file", "path_pattern": "/workspace/*" } },
    { "id": "block-secrets", "effect": "deny", "match": { "command_pattern": ".env" } },
    { "id": "block-rm-rf", "effect": "deny", "match": { "tool": "bash", "command_pattern": "rm -rf" } },
    { "id": "block-passwd", "effect": "deny", "match": { "tool": "bash", "command_pattern": "/etc/passwd" } },
    { "id": "block-ssh-keys", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.ssh/" } },
    { "id": "block-aws-creds", "effect": "deny", "match": { "tool": "read", "path_pattern": "~/.aws/" } },
    { "id": "block-home-dir", "effect": "deny", "match": { "tool": "read", "path_pattern": "/home/" } }
  ]
}
```

---

## 🚀 Phase 3: Integration & Docker Compose (Days 4-5)

### Task 3.1 — Final Docker Compose

**docker-compose.yml:**
```yaml
version: '3.8'

services:
  proxy:
    build: ./proxy
    ports:
      - "8080:8080"
    environment:
      - AGENTGATE_PROXY_LISTEN=:8080
      - AGENTGATE_PROXY_AGENTGATE_URL=http://agentgate:8081
      - AGENTGATE_PROXY_ANTHROPIC_URL=https://api.anthropic.com
      - AGENTGATE_PROXY_POLICY_TIMEOUT=5s
      - AGENTGATE_PROXY_UPSTREAM_TIMEOUT=300s
    depends_on:
      agentgate:
        condition: service_healthy
    networks:
      - agentgate-net
    restart: unless-stopped

  agentgate:
    build: .
    ports:
      - "8081:8080"
      - "9090:9090"
    volumes:
      - ./config.proxy.json:/etc/agent-gate/config.json:ro
      - ./policies:/etc/agent-gate/policies:ro
    environment:
      - AGENTGATE_SERVER_PORT=8080
      - AGENTGATE_SERVER_HOST=0.0.0.0
      - AGENTGATE_AUTH_JWT_SECRET=${AGENTGATE_JWT_SECRET:-change-me-in-dev-32chars!}
      - AGENTGATE_POLICY_POLICY_FILE=/etc/agent-gate/policies/ai-agent.json
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - agentgate-net
    restart: unless-stopped

networks:
  agentgate-net:
    driver: bridge
```

### Task 3.2 — AgentGate proxy-mode config

**config.proxy.json:**
```json
{
  "server": {
    "port": 8080,
    "host": "0.0.0.0",
    "workers": 4
  },
  "auth": {
    "jwt_secret": "change-me-in-dev-32chars!",
    "auth_timeout_ms": 100
  },
  "policy": {
    "policy_timeout_ms": 20,
    "max_policies": 100,
    "policy_file": "/etc/agent-gate/policies/ai-agent.json"
  },
  "audit": {
    "buffer_size": 1024,
    "audit_timeout_ms": 10
  },
  "request": {
    "request_timeout_ms": 10000,
    "max_body_size": 1048576,
    "max_headers": 64
  },
  "shutdown": {
    "grace_period_ms": 30000,
    "enable_signals": true
  },
  "tls": {
    "mode": "disabled"
  }
}
```

### Task 3.3 — One-command install script

**install.sh:**
```bash
#!/bin/bash
set -e
echo "=== AgentGate Cage Installer ==="

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo "Docker required"; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "Docker Compose required"; exit 1; }

# Generate JWT secret if not set
if [ -z "$AGENTGATE_JWT_SECRET" ]; then
  AGENTGATE_JWT_SECRET=$(openssl rand -hex 16)
fi

echo "Starting AgentGate Cage..."
AGENTGATE_JWT_SECRET=$AGENTGATE_JWT_SECRET docker compose up -d

echo ""
echo "=== AgentGate Cage is running! ==="
echo "Proxy:  http://localhost:8080"
echo "Admin:  http://localhost:9090 (metrics)"
echo ""
echo "Configure Claude Code:"
echo "  export ANTHROPIC_BASE_URL=http://localhost:8080"
echo "  claude"
echo ""
echo "Your real Anthropic API key is passed through via x-api-key header."
```

---

## 🚀 Phase 4: Testing & Validation (Days 5-6)

### Task 4.1 — Go proxy unit tests

- `proxy/anthropic/extract_test.go` — Test tool extraction from various message formats
- `proxy/policy/client_test.go` — Mock AgentGate server, test allow/deny flows
- `proxy/upstream/client_test.go` — Mock Anthropic API, test forwarding
- `proxy/upstream/stream_test.go` — Mock SSE event source, verify passthrough

### Task 4.2 — Zig policy extension tests

Add to existing test framework:

```zig
test "Condition tool matches by name" {
    const ctx = RequestContext.initTool("agent", "bash", "ls -la", "");
    try std.testing.expect((Condition{ .tool = "bash" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .tool = "read_file" }).matches(&ctx));
}

test "Condition command_pattern blocks sensitive command" {
    const ctx = RequestContext.initTool("agent", "bash", "cat /etc/passwd", "");
    try std.testing.expect((Condition{ .command_pattern = "/etc/passwd" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .command_pattern = "rm -rf" }).matches(&ctx));
}

test "Condition path_pattern allows workspace" {
    const ctx = RequestContext.initTool("agent", "read", "", "/workspace/src/main.zig");
    try std.testing.expect((Condition{ .path_pattern = "/workspace/*" }).matches(&ctx));
    try std.testing.expect(!(Condition{ .path_pattern = "/home/*" }).matches(&ctx));
}

test "Policy with tool + command_pattern denies dangerous command" {
    const conditions = &[_]Condition{
        Condition{ .tool = "bash" },
        Condition{ .command_pattern = "rm -rf" },
    };
    const policy = Policy{
        .id = "block-rm-rf",
        .effect = .deny,
        .conditions = conditions,
    };
    const ctx = RequestContext.initTool("agent", "bash", "rm -rf /", "");
    try std.testing.expect(policy.matchesAll(&ctx));
}
```

### Task 4.3 — Integration test (Go + Zig)

Script that:
1. Starts AgentGate in Docker container
2. Starts Go proxy in Docker container
3. Sends mock `/v1/messages` with tool calls
4. Verifies ALLOW → forwarded response
5. Verifies DENY → policy error

### Task 4.4 — Manual smoke test with Claude Code

```bash
# 1. Start services
docker compose up -d

# 2. Configure Claude Code
export ANTHROPIC_BASE_URL=http://localhost:8080

# 3. Run Claude Code
claude

# 4. Test scenarios:
#    "read file /workspace/README.md"   → should work
#    "list files in /"                  → should work
#    "cat ~/.env"                       → should be blocked
#    "cat /etc/passwd"                  → should be blocked
#    "rm -rf /"                         → should be blocked

# 5. Verify metrics
curl http://localhost:9090/metrics

# 6. Check denied requests
curl http://localhost:8081/denied-requests
```

---

## 🧩 Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Anthropic API format changes | Medium | High | Strict versioned parsing; integration tests with real API |
| SSE streaming quality | Medium | Medium | Buffer tuning; test with real Claude Code streaming |
| Tool extraction misses patterns | Medium | Medium | Start with MVP (bash, read, write, edit, read_file); iterate |
| Go ↔ Zig inter-service latency | Low | Low | Co-located Docker network; 20ms policy timeout is negligible |
| Policy bypass via non-tool API | Low | High | Proxy only allows `/v1/messages`; other paths → 404 |
| Memory leak in long-running proxy | Low | Medium | Load test; Go GC handles most cases |

---

## 📊 Effort Summary

| Phase | Tasks | Estimated Days | Dependencies |
|-------|-------|---------------|-------------|
| **Phase 0**: Setup | 3 tasks | 1 day | None |
| **Phase 1**: Go Proxy | 9 tasks | 3-4 days | Phase 0 |
| **Phase 2**: Zig Extensions | 6 tasks | 2-3 days | None |
| **Phase 3**: Integration | 3 tasks | 1 day | Phase 1 + 2 |
| **Phase 4**: Testing | 4 tasks | 1-2 days | Phase 3 |
| **Total** | **25 tasks** | **~8-10 days** | |

---

## 🗺️ v2 Roadmap

| Feature | Description | When |
|---------|-------------|------|
| **Zig-native proxy** | Replace Go with Zig for single-binary deployment | Post-MVP |
| **gVisor sandbox** | Docker + runsc for OS-level code isolation | Post-MVP |
| **OpenAI support** | `/v1/chat/completions` proxy endpoint | v2 |
| **Tool-level partial allow** | Allow some tools in a request, deny others | v2 |
| **MCPKernel integration** | Taint tracking, DLP, poisoning detection | v2 |
| **GKE sandbox pools** | Enterprise Kubernetes deployment | v2 |

---

> **Ready to implement.** Start with Phase 0 → Phase 1 → Phase 2 (can overlap) → Phase 3 → Phase 4.
