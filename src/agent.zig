//! Agent - Authenticated agent context structure.
//!
//! Represents an authenticated agent with ID, timestamp, and permissions.

const std = @import("std");
const Secret = @import("secret.zig").Secret;
const Config = @import("config.zig").Config;
const Command = @import("config.zig").Command;

/// Permission flags for agent access control.
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

/// Bitset container for permission flags.
pub const PermissionSet = packed struct {
    flags: u64 = 0,

    const Self = @This();

    /// Check if the permission is granted.
    pub fn has(self: PermissionSet, p: Permission) bool {
        return (self.flags & @intFromEnum(p)) != 0;
    }

    /// Grant a permission.
    pub fn set(self: *Self, p: Permission) void {
        self.flags |= @intFromEnum(p);
    }

    /// Revoke a permission.
    pub fn clear(self: *Self, p: Permission) void {
        self.flags &= ~@intFromEnum(p);
    }

    /// Grant all permissions.
    pub fn all(self: *Self) void {
        self.flags = std.math.maxInt(u64);
    }

    /// Revoke all permissions.
    pub fn none(self: *Self) void {
        self.flags = 0;
    }
};

/// Agent context representing an authenticated agent.
pub const Agent = struct {
    id: [32]u8,
    authenticated_at: i128,
    permissions: PermissionSet,

    const Self = @This();

    /// Initialize a new agent context.
    pub fn init(id: [32]u8, timestamp: i128, permissions: PermissionSet) Self {
        return Self{
            .id = id,
            .authenticated_at = timestamp,
            .permissions = permissions,
        };
    }

    /// Create an agent with no permissions.
    pub fn initUnauthenticated(id: [32]u8) Self {
        return Self{
            .id = id,
            .authenticated_at = 0,
            .permissions = PermissionSet{},
        };
    }

    /// Check if the agent has a specific permission.
    pub fn hasPermission(self: *const Self, p: Permission) bool {
        return self.permissions.has(p);
    }

    /// Grant a permission to the agent.
    pub fn grantPermission(self: *Self, p: Permission) void {
        self.permissions.set(p);
    }

    /// Check if the agent is authenticated (non-zero timestamp).
    pub fn isAuthenticated(self: *const Self) bool {
        return self.authenticated_at > 0;
    }

    /// Get the agent ID as a slice.
    pub fn idSlice(self: *const Self) []const u8 {
        return &self.id;
    }
};

test "Agent basic creation" {
    const id = [_]u8{1} ** 32;
    var agent = Agent.init(id, 1234567890, PermissionSet{});

    try std.testing.expectEqualSlices(u8, &id, agent.idSlice());
    try std.testing.expectEqual(@as(i128, 1234567890), agent.authenticated_at);
}

test "Agent no permissions" {
    const id = [_]u8{1} ** 32;
    var agent = Agent.initUnauthenticated(id);

    try std.testing.expect(!agent.hasPermission(.read_users));
    try std.testing.expect(!agent.hasPermission(.write_admin));
}

test "Agent permission operations" {
    const id = [_]u8{1} ** 32;
    var agent = Agent.initUnauthenticated(id);

    // Grant permission
    agent.grantPermission(.read_users);
    try std.testing.expect(agent.hasPermission(.read_users));

    // Grant more permissions
    agent.grantPermission(.write_users);
    agent.grantPermission(.read_admin);

    try std.testing.expect(agent.hasPermission(.read_users));
    try std.testing.expect(agent.hasPermission(.write_users));
    try std.testing.expect(agent.hasPermission(.read_admin));
    try std.testing.expect(!agent.hasPermission(.write_admin));
}

test "Agent authentication check" {
    const id = [_]u8{1} ** 32;

    var unauth = Agent.initUnauthenticated(id);
    try std.testing.expect(!unauth.isAuthenticated());

    var auth = Agent.init(id, 1234567890, PermissionSet{});
    try std.testing.expect(auth.isAuthenticated());
}

test "PermissionSet all/none" {
    var perms = PermissionSet{};

    perms.all();
    try std.testing.expect(perms.has(.read_users));
    try std.testing.expect(perms.has(.write_admin));

    perms.none();
    try std.testing.expect(!perms.has(.read_users));
    try std.testing.expect(!perms.has(.write_admin));
}

test "Agent ID is fixed size" {
    const id = [_]u8{0xAB} ** 32;
    var agent = Agent.init(id, 0, PermissionSet{});

    // Verify ID is exactly 32 bytes
    try std.testing.expectEqual(@as(usize, 32), agent.idSlice().len);
}
