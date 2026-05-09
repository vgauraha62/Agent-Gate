const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    main_module.addImport("agent", b.addModule("agent", .{ .root_source_file = b.path("src/agent.zig") }));
    main_module.addImport("config", b.addModule("config", .{ .root_source_file = b.path("src/config.zig") }));
    main_module.addImport("secret", b.addModule("secret", .{ .root_source_file = b.path("src/secret.zig") }));
    main_module.addImport("memory", b.addModule("memory", .{ .root_source_file = b.path("src/memory.zig") }));
    main_module.addImport("metrics", b.addModule("metrics", .{ .root_source_file = b.path("src/metrics/prometheus.zig") }));
    main_module.addImport("policy", b.addModule("policy", .{ .root_source_file = b.path("src/policy/types.zig") }));

    const server = b.addModule("server", .{ .root_source_file = b.path("src/server/http.zig") });
    server.addImport("auth_middleware", b.addModule("auth_middleware", .{ .root_source_file = b.path("src/server/auth_middleware.zig") }));
    server.addImport("audit", b.addModule("audit", .{ .root_source_file = b.path("src/audit/logger.zig") }));
    main_module.addImport("server", server);

    const exe = b.addExecutable(.{
        .name = "agent-gate",
        .root_module = main_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the agent-gate");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_obj = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run integration tests");
    const test_run = b.addRunArtifact(test_obj);
    test_step.dependOn(&test_run.step);
}
