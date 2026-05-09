# Agent-Gate: Policy-Based Access Control System

A Rust-based authorization framework built in Zig for implementing policy-based access control (PBAC) systems. This implementation provides a robust and extensible architecture for managing agent permissions, audit logging, and security policies.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent-Gate System                          │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Agent      │───▶│   Policy     │───▶│   Event       │      │
│  │  Context     │    │ Validator    │    │  Logger       │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         ▲                  ▲                   ▲                │
│         │                  │                   │                │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Resource   │◀───│   Rule       │◀───│   Config     │      │
│  │  Metadata    │    │ Matcher      │    │ Loader        │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Agent Module (`src/agent.zig`)

- **Agent context** with ID, timestamp, and permissions
- **Permission bitmask** for efficient access control
- Support for:
  - User read/write operations
  - Admin operations
  - Policy management
  - Audit access

### 2. Rule Engine (`src/rules/`)

- **Policy rules** with priority and timeout settings
- **Matcher system** for condition evaluation
- **Event stream processor** for real-time authorization

### 3. Resource Metadata (`src/resources/`)

- Resource descriptors with access paths
- Attribute-based filtering
- Permission inheritance chains

### 4. Event Logging (`src/events/`)

- Audit trail persistence
- Security event capture
- Compliance reporting support

### 5. Configuration (`config.zig`)

- YAML/JSON schema for policies
- Environment variable injection
- Hot-reload capabilities

## Installation

```bash
cd /home/vg/opensource/Agent-Gate

# Clone and build
git clone https://github.com/vg/agent-gate.git
cd Agent-Gate

# Install dependencies
zig build install

# Run tests
zig build test

# Build release
zig build -Drelease=true
```

## Configuration Example

```yaml
# config.yaml
server:
  host: "0.0.0.0"
  port: 8080

agent:
  id_prefix: "agent-"
  default_timeout: 3600  # seconds

policy:
  default_denial: true
  max_rules_per_group: 1000

logging:
  level: "info"
  file: "/var/log/agent-gate/audit.log"
  format: "json"
```

## Usage

```zig
const std = @import("std");
const Server = @import("server.zig").Server;
const Config = @import("config.zig").Config;

pub fn main() !void {
    // Initialize configuration
    var config = try Config.initFromFile("config.yaml");
    
    // Create server instance
    var server = try Server.init(&config);
    
    // Load policies
    try server.loadPolicies();
    
    // Validate secrets
    try server.validateSecrets();
    
    // Bind and start server
    try server.bind("0.0.0.0", 8080);
    try server.run();
    
    // Cleanup
    defer server.deinit();
}
```

## API Documentation

### Agent API

```zig
const Agent = @import("agent.zig").Agent;

// Create authenticated agent
const agent = Agent.init(id, timestamp, permissions);

// Grant permission
agent.grantPermission(.read_users);

// Revoke permission
agent.clearPermission(.write_admin);

// Check authentication
if (agent.isAuthenticated()) {
    std.debug.print("Agent {s} is authenticated\n", .{agent.id});
}
```

### Permission Flags

```zig
pub const Permission = enum(u64) {
    read_users = 1 << 0,
    write_users = 1 << 1,
    read_admin = 1 << 2,
    write_admin = 1 << 3,
    read_policies = 1 << 4,
    write_policies = 1 << 5,
    read_audit = 1 << 6,
    write_audit = 1 << 7,
};
```

## Security Features

- **Zero-copy permission checks**: Bitwise operations
- **Cryptographic identity**: 32-byte agent IDs
- **Secret validation**: Environment variable injection
- **Audit trail**: Immutable event logging
- **Policy isolation**: Resource-level permission scoping

## Testing

Run unit tests:

```bash
zig build test
zig build test-coverage
```

Example test:

```zig
test "Agent basic creation" {
    const id = [_]u8{1} ** 32;
    var agent = Agent.init(id, 1234567890, PermissionSet{});
    
    try std.testing.expectEqualSlices(u8, &id, agent.idSlice());
    try std.testing.expectEqual(@as(i128, 1234567890), agent.authenticated_at);
}
```

## License

MIT License - See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit pull requests with tests
4. Follow Zig coding standards

## Dependencies

- Zig v0.11+
- Linux Kernel 5.4+
- OpenSSL 1.1+ for TLS support

## Contact

- Issues: [GitHub Issues](https://github.com/vg/agent-gate/issues)
- Documentation: [ReadTheDocs](https://agent-gate.readthedocs.org)

---

**Note**: This implementation uses Zig for maximum performance in a Rust-like ecosystem.
