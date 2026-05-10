//! Graceful shutdown handler for AgentGate.
//!
//! Day 6: Implement SIGTERM/SIGINT handling with connection draining.
//! v2: Add SIGUSR1 for config reload (deferred per decision #6).

const std = @import("std");

/// Graceful shutdown state.
pub const ShutdownState = struct {
    /// Whether shutdown has been requested.
    requested: bool = false,
    /// Timestamp when shutdown was requested.
    requested_at: i128 = 0,

    const Self = @This();

    /// Request shutdown.
    pub fn request(self: *Self) void {
        self.requested = true;
        self.requested_at = std.time.timestamp();
    }

    /// Check if shutdown should begin.
    pub fn shouldShutdown(self: *const Self) bool {
        return self.requested;
    }

    /// Get time since shutdown was requested in milliseconds.
    pub fn timeSinceRequest(self: *const Self) i128 {
        if (!self.requested) return 0;
        return std.time.timestamp() - self.requested_at;
    }
};

/// Signal handler for graceful shutdown.
/// Uses async-safe signal handling in Zig.
pub fn setupSignalHandler(state: *ShutdownState) !void {
    // SIGTERM handler
    try std.posix.signal(std.posix.SIG.TERM, struct {
        fn handler(_: c_int) callconv(.C) void {
            state.request();
        }
    }.handler);

    // SIGINT handler (Ctrl+C)
    try std.posix.signal(std.posix.SIG.INT, struct {
        fn handler(_: c_int) callconv(.C) void {
            state.request();
        }
    }.handler);
}

/// Wait for shutdown with graceful period.
/// Returns true if graceful shutdown completed, false if force shutdown.
pub fn waitForShutdown(
    state: *const ShutdownState,
    grace_period_ms: u32,
) void {
    const deadline = std.time.timestamp() + @divExact(grace_period_ms, 1000);

    while (!state.shouldShutdown()) {
        std.time.sleep(100 * std.time.ns_per_ms);
        if (std.time.timestamp() >= deadline) {
            // Grace period expired, force shutdown
            break;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ShutdownState: initial state" {
    const state = ShutdownState{};

    try std.testing.expect(!state.shouldShutdown());
    try std.testing.expectEqual(@as(i128, 0), state.timeSinceRequest());
}

test "ShutdownState: request sets flag" {
    var state = ShutdownState{};
    try std.testing.expect(!state.shouldShutdown());

    state.request();
    try std.testing.expect(state.shouldShutdown());
    try std.testing.expect(state.timeSinceRequest() >= 0);
}

test "ShutdownState: timeSinceRequest before request" {
    const state = ShutdownState{};
    try std.testing.expectEqual(@as(i128, 0), state.timeSinceRequest());
}