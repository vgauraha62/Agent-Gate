const std = @import("std");

// Security system main logic
fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator.init(.{})
        .create();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Security System Starting...", .{});

    // System is running
    while (true) {
        _ = std.time.sleep(std.time.ns_per_s / (std.time.ns_per_ms));
    }
}
