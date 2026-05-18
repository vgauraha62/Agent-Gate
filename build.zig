const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    var optimize = b.standardOptimizeOption(.{});
    
    // Default to ReleaseSafe for better performance with correct semantics
    if (optimize == .Debug) optimize = .ReleaseSafe;

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
    main_module.addImport("errors", b.addModule("errors", .{ .root_source_file = b.path("src/errors.zig") }));
    main_module.addImport("auth_middleware", b.addModule("auth_middleware", .{ .root_source_file = b.path("src/server/auth_middleware.zig") }));

const server = b.addModule("server", .{ .root_source_file = b.path("src/server/http.zig") });
    server.addImport("auth_middleware", b.addModule("auth_middleware", .{ .root_source_file = b.path("src/server/auth_middleware.zig") }));
    server.addImport("audit", b.addModule("audit", .{ .root_source_file = b.path("src/audit/logger.zig") }));
    main_module.addImport("server", server);
    
    // Add async HTTP server module
    const server_async = b.addModule("server_async", .{ .root_source_file = b.path("src/server/http_async.zig") });
    server_async.addImport("audit", b.addModule("audit", .{ .root_source_file = b.path("src/audit/logger.zig") }));
    main_module.addImport("server_async", server_async);

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

    // Unit tests module
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_obj = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    const test_run = b.addRunArtifact(test_obj);
    test_step.dependOn(&test_run.step);

    // E2E Integration tests module
    const e2e_module = b.createModule(.{
        .root_source_file = b.path("src/integration_e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const e2e_obj = b.addTest(.{
        .root_module = e2e_module,
    });

    const e2e_step = b.step("test-e2e", "Run E2E integration tests");
    const e2e_run = b.addRunArtifact(e2e_obj);
    e2e_step.dependOn(&e2e_run.step);

    // E2E Server tests module
    const e2e_server_module = b.createModule(.{
        .root_source_file = b.path("src/e2e_server_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const e2e_server_obj = b.addTest(.{
        .root_module = e2e_server_module,
    });

    const e2e_server_step = b.step("test-e2e-server", "Run E2E server tests");
    const e2e_server_run = b.addRunArtifact(e2e_server_obj);
    e2e_server_step.dependOn(&e2e_server_run.step);

    // Combined test step
    const all_tests_step = b.step("test-all", "Run all tests (unit + E2E)");
    all_tests_step.dependOn(&test_run.step);
    all_tests_step.dependOn(&e2e_run.step);
    all_tests_step.dependOn(&e2e_server_run.step);

    // ============================================================================
    // Benchmark (Load Testing) Tool
    // ============================================================================

    // First create secret and memory modules (dependencies)
    const secret_module = b.addModule("secret", .{
        .root_source_file = b.path("src/secret.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memory_module = b.addModule("memory", .{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Then create jwt module that depends on secret and memory
    const jwt_module = b.addModule("jwt", .{
        .root_source_file = b.path("src/auth/jwt.zig"),
        .target = target,
        .optimize = optimize,
    });
    jwt_module.addImport("secret", secret_module);
    jwt_module.addImport("memory", memory_module);

    // Finally create the benchmark module
    const benchmark_module = b.addModule("loadtest", .{
        .root_source_file = b.path("tools/loadtest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    benchmark_module.addImport("auth/jwt", jwt_module);
    benchmark_module.addImport("secret", secret_module);
    benchmark_module.addImport("memory", memory_module);

    const benchmark_exe = b.addExecutable(.{
        .name = "loadtest",
        .root_module = benchmark_module,
    });

    b.installArtifact(benchmark_exe);

    const benchmark_run_cmd = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| {
        benchmark_run_cmd.addArgs(args);
    }

    const benchmark_step = b.step("benchmark", "Run load testing benchmark");
    benchmark_step.dependOn(&benchmark_run_cmd.step);
}
