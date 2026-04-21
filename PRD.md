# AgentGate - Technical PRD & 15-Day Implementation Plan

## Document Information
- **Project**: AgentGate - Lightweight Agent Security Sidecar
- **Language**: Zig (latest stable)
- **Timeline**: 15 days, 3 phases of 5 days each
- **Target**: Working prototype ready for acquisition demo

---

## 📋 Executive Summary

AgentGate is a lightweight policy enforcement sidecar for agentic swarms, built in Zig. It intercepts agent requests, validates identity, checks policies (compile-time generated), and allows/denies with sub-50µs latency.

**Success Criteria (Day 15)**:
- ✅ Working sidecar that authenticates agents and enforces policies
- ✅ Benchmark showing <50µs P99 latency, >100K checks/sec
- ✅ Zero memory leaks under load (24-hour stress test)
- ✅ Deployable via Docker Compose in one command
- ✅ Complete documentation for acquisition due diligence

---

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Agent Swarm                             │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐                    │
│  │Agent1│  │Agent2│  │Agent3│  │AgentN│                    │
│  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘                    │
│     │         │         │         │                         │
│     └─────────┴─────────┴─────────┘                         │
│                    │ HTTP/gRPC                              │
├────────────────────┼────────────────────────────────────────┤
│              ┌─────▼──────┐                                 │
│              │ AgentGate  │                                 │
│              │  Sidecar   │                                 │
│              └─────┬──────┘                                 │
│                    │                                         │
│         ┌──────────┼──────────┐                             │
│         │          │          │                             │
│    ┌────▼────┐ ┌───▼────┐ ┌───▼────┐                       │
│    │ Auth    │ │Policy  │ │Audit   │                       │
│    │ Engine  │ │Engine  │ │Logger  │                       │
│    └─────────┘ └────────┘ └────────┘                       │
│         │          │          │                             │
│         └──────────┼──────────┘                             │
│                    │                                         │
│              ┌─────▼──────┐                                 │
│              │ Upstream   │                                 │
│              │  Service   │                                 │
│              └────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

### Component Specifications

| Component | Responsibility | Zig Features Used |
|-----------|---------------|-------------------|
| Auth Engine | JWT/PASETO validation, mTLS handshake | `std.crypto.sign`, `std.crypto.auth` |
| Policy Engine | Allow/deny decisions, compile-time policy generation | `comptime`, `std.meta` |
| Audit Logger | Immutable audit trail, cryptographic proof | `std.crypto.hash`, ring buffer |
| Metrics | Prometheus endpoint, latency/throughput tracking | `std.time`, atomic counters |

---

## 📅 Phase 1: Core Foundation (Days 1-5)

### Day 1: Project Setup & Build System

**Morning (4 hours)**
- [ ] Initialize Zig project: `zig init-exe`
- [ ] Configure `build.zig` with:
  - ReleaseFast mode for benchmarks
  - Debug mode for development
  - Test coverage flags
- [ ] Set up directory structure:
```
agentgate/
├── src/
│   ├── main.zig
│   ├── auth/
│   │   ├── jwt.zig
│   │   └── mTLS.zig
│   ├── policy/
│   │   ├── engine.zig
│   │   └── parser.zig
│   ├── audit/
│   │   └── logger.zig
│   ├── server/
│   │   └── http.zig
│   └── metrics/
│       └── prometheus.zig
├── build.zig
├── build.zig.zon
├── README.md
├── ARCHITECTURE.md
└── THREAT_MODEL.md
```

**Afternoon (4 hours)**
- [ ] Implement `build.zig` with multiple configurations:
```zig
// build.zig structure
const exe = b.addExecutable(.{
    .name = "agentgate",
    .root_source_file = .{ .path = "src/main.zig" },
    .target = target,
    .optimize = optimize,
});

// Add configurations
const features = b.addOptions();
exe.root_module.addOptions("build_options");
```

- [ ] Set up GitHub repository with:
  - GPG signing enabled
  - Branch protection rules (main requires PR)
  - Issue templates (bug, feature, security)
- [ ] Create initial `README.md` with project vision

**Day 1 Deliverable**: Working `zig build` and `zig build test` with no errors

---

### Day 2: Core Data Structures & Memory Management

**Morning (4 hours)**
- [ ] Implement custom arena allocator in `src/memory.zig`:
```zig
pub const SecurityArena = struct {
    buffer: []u8,
    index: usize,
    
    pub fn init(capacity: usize) SecurityArena { ... }
    pub fn alloc(self: *SecurityArena, size: usize) ![]u8 { ... }
    pub fn reset(self: *SecurityArena) void { ... }
    pub fn deinit(self: *SecurityArena) void { ... }
};
```

- [ ] Implement zeroizing secret container:
```zig
pub const Secret = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Secret { ... }
    pub fn asBytes(self: *const Secret) []const u8 { ... }
    pub fn zeroize(self: *Secret) void { ... }
    pub fn deinit(self: *Secret) void { ... }
};
```

**Afternoon (4 hours)**
- [ ] Implement Agent context structure:
```zig
pub const Agent = struct {
    id: [32]u8,  // SHA256 of public key
    authenticated_at: i128,  // Unix timestamp
    permissions: PermissionSet,
    
    pub fn deinit(self: *Agent) void { ... }
};
```

- [ ] Write memory safety tests:
```zig
test "Secret zeroization" {
    var secret = try Secret.init(testing.allocator, "super-secret-key");
    defer secret.deinit();
    
    const ptr = secret.asBytes().ptr;
    secret.zeroize();
    
    // Verify memory is zeroed
    try testing.expect(@as(u8, @ptrCast(ptr)) == 0);
}
```

**Day 2 Deliverable**: Memory-safe data structures with >90% test coverage

---

### Day 3: Authentication Engine (JWT)

**Morning (4 hours)**
- [ ] Implement JWT parser in `src/auth/jwt.zig`:
```zig
pub const JWT = struct {
    header: Header,
    payload: Payload,
    signature: [32]u8,
    
    pub fn parse(token: []const u8) !JWT { ... }
    pub fn verify(self: *const JWT, secret: Secret) !bool { ... }
};

const Header = struct {
    alg: []const u8,  // Only HS256/HS384/HS512 initially
    typ: []const u8,
};

const Payload = struct {
    sub: []const u8,  // Agent ID
    exp: u64,         // Expiration
    aud: []const u8,  // Audience
    // Custom claims
    extra: std.StringHashMap([]const u8),
};
```

**Afternoon (4 hours)**
- [ ] Implement constant-time comparison:
```zig
pub fn secureCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        result |= a_byte ^ b_byte;
    }
    return result == 0;
}
```

- [ ] Add tests for JWT verification:
  - Valid token passes
  - Expired token fails
  - Tampered signature fails
  - Wrong secret fails

**Day 3 Deliverable**: JWT authentication with timing-attack protection

---

### Day 4: Policy Engine Foundation

**Morning (4 hours)**
- [ ] Design policy language (JSON-based):
```json
{
  "version": "1",
  "policies": [
    {
      "id": "policy-001",
      "effect": "allow",
      "match": {
        "agent_id": "auth-service",
        "path": "/api/users/*",
        "method": ["GET", "POST"]
      }
    },
    {
      "id": "policy-002", 
      "effect": "deny",
      "match": {
        "agent_id": "*",
        "path": "/api/admin/*"
      }
    }
  ]
}
```

- [ ] Implement policy parser in `src/policy/parser.zig`:
```zig
pub const Policy = struct {
    id: []const u8,
    effect: Effect,
    conditions: []Condition,
    
    pub fn evaluate(self: *const Policy, ctx: RequestContext) bool { ... }
};

const Effect = enum { allow, deny };
const Condition = union(enum) {
    agent_id: []const u8,
    path: []const u8,
    method: Method,
    custom: CustomCondition,
};
```

**Afternoon (4 hours)**
- [ ] Implement compile-time policy generation:
```zig
pub fn PolicySet(comptime policies_file: []const u8) type {
    comptime {
        const policies = @embedFile(policies_file);
        // Parse at compile time
        // Generate decision tree
        // Return optimized type
    }
}
```

- [ ] Add policy evaluation benchmarks

**Day 4 Deliverable**: Policy engine that can evaluate 1000 policies in <100µs

---

### Day 5: HTTP Server Foundation

**Morning (4 hours)**
- [ ] Implement minimal HTTP server in `src/server/http.zig`:
```zig
pub const Server = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, port: u16) !Server { ... }
    pub fn run(self: *Server, handler: *const Handler) !void { ... }
    pub fn deinit(self: *Server) void { ... }
};

const Request = struct {
    method: Method,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn parse(reader: anytype) !Request { ... }
    pub fn deinit(self: *Request) void { ... }
};
```

**Afternoon (4 hours)**
- [ ] Implement request routing:
```zig
pub const Router = struct {
    routes: std.StringHashMap(Route),
    
    pub fn add(self: *Router, path: []const u8, method: Method, handler: HandlerFn) !void { ... }
    pub fn route(self: *Router, req: *const Request) !HandlerFn { ... }
};
```

- [ ] Test HTTP server with curl:
```bash
curl -X POST http://localhost:8080/check \
  -H "Authorization: Bearer <JWT>" \
  -d '{"path": "/api/users", "method": "GET"}'
```

**Day 5 Deliverable**: Working HTTP server that can receive and parse requests

### Phase 1 Success Criteria
- [ ] All tests passing
- [ ] No memory leaks in basic operations
- [ ] HTTP server responds to requests
- [ ] JWT verification works

---

## 📅 Phase 2: Integration & Features (Days 6-10)

### Day 6: End-to-End Request Processing

**Morning (4 hours)**
- [ ] Implement main request handler:
```zig
pub fn handleRequest(
    auth: *AuthEngine,
    policy: *PolicyEngine,
    audit: *AuditLogger,
    req: Request,
) !Response {
    // Step 1: Extract and validate JWT
    const token = extractBearer(req.headers) orelse return error.Unauthorized;
    const agent = try auth.verify(token) orelse return error.Unauthorized;
    defer agent.deinit();
    
    // Step 2: Check policy
    const ctx = RequestContext{
        .agent_id = agent.id,
        .path = req.path,
        .method = req.method,
    };
    
    const decision = try policy.evaluate(ctx);
    
    // Step 3: Log decision
    try audit.log(.{
        .timestamp = std.time.timestamp(),
        .agent_id = agent.id,
        .path = req.path,
        .decision = decision,
    });
    
    // Step 4: Return response
    return Response{
        .status = if (decision == .allow) 200 else 403,
        .body = decision.toJson(),
    };
}
```

**Afternoon (4 hours)**
- [ ] Add concurrent request handling:
```zig
pub fn run(self: *Server, handler: *Handler) !void {
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = self.allocator, .n_jobs = 4 });
    defer pool.deinit();
    
    while (true) {
        const conn = try self.listener.accept();
        try pool.spawn(handleConnection, .{conn, handler});
    }
}
```

**Day 6 Deliverable**: End-to-end request processing with concurrency

---

### Day 7: Audit Logging System

**Morning (4 hours)**
- [ ] Implement ring buffer audit log in `src/audit/logger.zig`:
```zig
pub const AuditLog = struct {
    buffer: []LogEntry,
    write_index: usize,
    integrity_hash: [32]u8,  // Merkle tree root
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !AuditLog { ... }
    pub fn log(self: *AuditLog, entry: LogEntry) !void { ... }
    pub fn verify(self: *const AuditLog) !bool { ... }
    pub fn export(self: *const AuditLog, writer: anytype) !void { ... }
};

const LogEntry = struct {
    timestamp: i128,
    agent_id: [32]u8,
    path: []const u8,
    decision: Decision,
    request_hash: [32]u8,  // SHA256 of request body
};
```

**Afternoon (4 hours)**
- [ ] Add cryptographic proof chain:
```zig
pub fn addEntry(self: *AuditLog, entry: LogEntry) !void {
    const index = self.write_index;
    self.buffer[index] = entry;
    
    // Update Merkle tree
    const entry_hash = hashEntry(&entry);
    self.merkle_tree.update(index, entry_hash);
    
    // Sign new root with server private key
    const new_root = self.merkle_tree.root();
    self.signature = try crypto.sign(new_root, self.private_key);
    
    self.write_index = (index + 1) % self.buffer.len;
}
```

**Day 7 Deliverable**: Tamper-evident audit log with cryptographic verification

---

### Day 8: Metrics & Monitoring

**Morning (4 hours)**
- [ ] Implement Prometheus metrics in `src/metrics/prometheus.zig`:
```zig
pub const Metrics = struct {
    // Counters
    requests_total: std.atomic.Atomic(u64),
    allowed_total: std.atomic.Atomic(u64),
    denied_total: std.atomic.Atomic(u64),
    
    // Histograms (using HDR histogram)
    latency_hist: HdrHistogram,
    
    // Gauges
    active_sessions: std.atomic.Atomic(u32),
    
    pub fn recordRequest(self: *Metrics, latency_us: u64, allowed: bool) void { ... }
    pub fn export(self: *Metrics, writer: anytype) !void { ... }
};
```

**Afternoon (4 hours)**
- [ ] Add `/metrics` endpoint:
```zig
pub fn metricsHandler(metrics: *Metrics, req: Request) !Response {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try metrics.export(buffer.writer());
    
    return Response{
        .status = 200,
        .headers = .{.content_type = "text/plain"},
        .body = buffer.items,
    };
}
```

**Day 8 Deliverable**: Prometheus metrics endpoint with latency histograms

---

### Day 9: mTLS Support

**Morning (4 hours)**
- [ ] Implement mTLS using Zig's std.crypto.tls:
```zig
pub const TLSConfig = struct {
    ca_cert: []const u8,
    server_cert: []const u8,
    server_key: Secret,
    
    pub fn load(paths: struct {
        ca: []const u8,
        cert: []const u8,
        key: []const u8,
    }) !TLSConfig { ... }
};

pub const TLSServer = struct {
    config: TLSConfig,
    inner: std.crypto.tls.Server,
    
    pub fn accept(self: *TLSServer) !struct { conn: std.net.Stream, agent_id: [32]u8 } {
        const conn = try self.inner.accept();
        const cert = try conn.getPeerCertificate();
        const agent_id = try hashCertificate(cert);
        return .{ .conn = conn, .agent_id = agent_id };
    }
};
```

**Afternoon (4 hours)**
- [ ] Generate test certificates:
```bash
# Generate CA
openssl req -new -x509 -days 365 -keyout ca.key -out ca.crt

# Generate server cert
openssl req -new -keyout server.key -out server.csr
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -out server.crt

# Generate agent cert
openssl req -new -keyout agent.key -out agent.csr
openssl x509 -req -in agent.csr -CA ca.crt -CAkey ca.key -out agent.crt
```

**Day 9 Deliverable**: mTLS support with mutual authentication

---

### Day 10: Configuration System

**Morning (4 hours)**
- [ ] Implement configuration parser in `src/config.zig`:
```zig
pub const Config = struct {
    server: ServerConfig,
    auth: AuthConfig,
    policy: PolicyConfig,
    audit: AuditConfig,
    
    pub fn load(path: []const u8) !Config {
        const file = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(file);
        
        const parsed = try std.json.parseFromSlice(Config, allocator, file, .{});
        return parsed.value;
    }
};

const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    workers: u8 = 4,
    enable_tls: bool = false,
};
```

**Afternoon (4 hours)**
- [ ] Add environment variable override:
```zig
pub fn fromEnv(comptime T: type) T {
    var config: T = default(T);
    inline for (@typeInfo(T).Struct.fields) |field| {
        const env_var = "AGENTGATE_" ++ std.ascii.upperString(field.name);
        if (std.process.getEnvVarOwned(allocator, env_var)) |value| {
            @field(config, field.name) = parseField(field, value);
        } else |_| {}
    }
    return config;
}
```

**Day 10 Deliverable**: Flexible configuration system with file and env support

### Phase 2 Success Criteria
- [ ] End-to-end request processing (<100µs)
- [ ] Audit logging with verification
- [ ] Prometheus metrics
- [ ] mTLS authentication
- [ ] Configuration system working

---

## 📅 Phase 3: Production Readiness (Days 11-15)

### Day 11: Performance Optimization

**Morning (4 hours)**
- [ ] Implement zero-copy request parsing:
```zig
pub fn parseRequest(reader: anytype, buffer: []u8) !Request {
    // Parse directly from buffer, no allocations for headers
    var request = Request{
        .raw = buffer,
    };
    
    // Parse first line
    var iter = std.mem.splitScalar(u8, buffer, ' ');
    request.method = try parseMethod(iter.next() orelse return error.Invalid);
    request.path = iter.next() orelse return error.Invalid;
    
    // Parse headers (zero-copy)
    while (iter.next()) |line| {
        if (line.len == 0) break;  // Empty line before body
        var header_iter = std.mem.splitScalar(u8, line, ':');
        const name = header_iter.next() orelse continue;
        const value = header_iter.next() orelse continue;
        try request.headers.put(name, std.mem.trim(u8, value, " "));
    }
    
    return request;
}
```

**Afternoon (4 hours)**
- [ ] Optimize policy evaluation:
```zig
// Generate decision tree at compile time
comptime {
    var tree = DecisionTree.init();
    for (policies) |policy| {
        tree.insert(policy);
    }
    
    // Optimize: merge overlapping rules
    tree.optimize();
    
    // Generate perfect hash function for fast lookup
    const lookup = generatePerfectHash(tree);
    _ = lookup;
}
```

**Day 11 Deliverable**: Sub-50µs P99 latency benchmark

---

### Day 12: Testing & Fuzzing

**Morning (4 hours)**
- [ ] Write integration tests:
```zig
test "End-to-end: valid JWT passes" {
    var server = try TestServer.init();
    defer server.deinit();
    
    const token = generateTestJWT("agent-123", 3600);
    const response = try server.check(.{
        .method = "GET",
        .path = "/api/users",
        .auth = token,
    });
    
    try testing.expectEqual(response.status, 200);
}

test "End-to-end: expired JWT fails" {
    const token = generateTestJWT("agent-123", -3600);
    const response = try server.check(.{
        .method = "GET",
        .path = "/api/users",
        .auth = token,
    });
    
    try testing.expectEqual(response.status, 401);
}
```

**Afternoon (4 hours)**
- [ ] Set up fuzzing targets:
```zig
// fuzz/fuzz_jwt.zig
pub fn fuzz(data: []const u8) void {
    _ = JWT.parse(data) catch {};
}

pub fn fuzz_policy(data: []const u8) void {
    _ = Policy.parse(data) catch {};
}
```

**Day 12 Deliverable**: >85% test coverage, fuzzing harness ready

---

### Day 13: Deployment Artifacts

**Morning (4 hours)**
- [ ] Create Dockerfile:
```dockerfile
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY agentgate /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/agentgate"]
CMD ["--config", "/etc/agentgate/config.json"]
```

- [ ] Create docker-compose.yml:
```yaml
version: '3.8'
services:
  agentgate:
    build: .
    ports:
      - "8080:8080"
      - "9090:9090"  # metrics
    volumes:
      - ./config.json:/etc/agentgate/config.json
      - ./audit.log:/var/log/agentgate/audit.log
    environment:
      - AGENTGATE_AUTH_SECRET=${JWT_SECRET}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

**Afternoon (4 hours)**
- [ ] Create Kubernetes deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentgate
spec:
  replicas: 3
  selector:
    matchLabels:
      app: agentgate
  template:
    metadata:
      labels:
        app: agentgate
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
    spec:
      containers:
      - name: agentgate
        image: agentgate:latest
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9090
          name: metrics
        resources:
          requests:
            memory: "10Mi"
            cpu: "10m"
          limits:
            memory: "50Mi"
            cpu: "100m"
```

**Day 13 Deliverable**: Docker and K8s deployment ready

---

### Day 14: Documentation & Demo

**Morning (4 hours)**
- [ ] Complete ARCHITECTURE.md with:
  - System diagrams
  - Data flow descriptions
  - Security properties
  - Performance characteristics

- [ ] Complete THREAT_MODEL.md:
```markdown
# Threat Model

## Assets
- JWT secrets (memory only, zeroized)
- Policy decisions (audit logged)
- Agent identities (certificate hashes)

## Attack Vectors
1. Timing attacks → mitigated by constant-time comparisons
2. Memory disclosure → mitigated by Secret zeroization
3. Policy bypass → mitigated by compile-time verification
4. Audit tampering → mitigated by Merkle tree proofs

## Trust Boundaries
- TLS between agent and AgentGate
- Filesystem for config (trusted)
- Upstream service (partially trusted)
```

**Afternoon (4 hours)**
- [ ] Record 5-minute demo video:
  1. Show problem (0:30)
  2. Deploy AgentGate (1:00)
  3. Send valid request → allowed (0:30)
  4. Send invalid request → denied (0:30)
  5. Show metrics (0:30)
  6. Show audit log (0:30)
  7. Show performance benchmark (1:00)
  8. Show Zig advantage (0:30)

**Day 14 Deliverable**: Complete documentation and demo video

---

### Day 15: Final Testing & Package

**Morning (4 hours)**
- [ ] Run 24-hour stress test (simulated):
```bash
# Load testing script
./scripts/stress-test.sh \
  --duration 24h \
  --rate 10000 req/s \
  --jwt-valid 80% \
  --jwt-expired 10% \
  --jwt-invalid 10%
```

- [ ] Validate all metrics:
  - [ ] P99 latency <50µs
  - [ ] Throughput >100K req/s
  - [ ] Zero memory leaks (24-hour run)
  - [ ] CPU <10% at 10K req/s
  - [ ] Memory <50MB steady state

**Afternoon (4 hours)**
- [ ] Create release package:
```
agentgate-v1.0.0/
├── bin/
│   ├── agentgate (x86_64-linux)
│   ├── agentgate (aarch64-linux)
│   └── agentgate (x86_64-macos)
├── config/
│   ├── config.example.json
│   └── policies.example.json
├── deploy/
│   ├── docker-compose.yml
│   └── kubernetes/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── THREAT_MODEL.md
│   ├── API.md
│   └── DEPLOYMENT.md
├── demo/
│   └── demo.mp4
└── README.md
```

- [ ] Final validation checklist:
```bash
# Build all targets
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-macos

# Run all tests
zig build test

# Run benchmarks
zig build benchmark

# Run fuzzing (24 hours)
./scripts/fuzz.sh --duration 24h

# Verify deployment
docker-compose up -d
curl http://localhost:8080/health
curl http://localhost:9090/metrics
```

**Day 15 Deliverable**: Production-ready prototype ready for acquisition demo

---

## 📊 Success Metrics Dashboard

| Metric | Target | Measurement | Day |
|--------|--------|-------------|-----|
| P99 Latency | <50µs | `benchmark.zig` | 11 |
| Throughput | >100K req/s | Load test | 15 |
| Memory (steady) | <50MB | `ps aux` | 15 |
| Binary size | <5MB | `ls -lh` | 1 |
| Test coverage | >85% | `zig build cov` | 12 |
| Fuzzing runs | 24h no crash | libfuzzer | 15 |
| Audit verification | 100% | `verify_audit` | 7 |

---

## 🚨 Risk Mitigation

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Zig compiler bug | Low | High | Pin stable version, test on multiple versions | Dev |
| Performance not met | Medium | High | Benchmark daily, optimize early | Dev |
| Memory leak | Medium | Medium | GPA in tests, valgrind on Friday | Dev |
| Documentation incomplete | Low | Medium | Write as you code, review weekly | All |
| Demo fails | Low | High | Dry run daily from Day 10 | Dev |

---

## 📞 Next Actions

**Immediate (today)**:
- [ ] Create GitHub repository
- [ ] Initialize Zig project
- [ ] Set up GPG signing
- [ ] Write Day 1 plan in project board

**Tomorrow morning**:
- [ ] Start Day 1 implementation
- [ ] Commit every hour with signed commits
- [ ] End of day: push working build

**Weekly review (Day 5, 10)**:
- [ ] Phase success criteria check
- [ ] Performance benchmark review
- [ ] Update documentation

---

This PRD is your blueprint. Execute day by day, test thoroughly, and by Day 15 you'll have an acquisition-ready prototype. Want me to expand any specific day's implementation details or create the actual code files?
