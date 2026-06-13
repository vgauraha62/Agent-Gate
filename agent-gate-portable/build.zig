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
    main_module.addImport("apikey", b.addModule("apikey", .{ .root_source_file = b.path("src/apikey.zig") }));
    main_module.addImport("usage", b.addModule("usage", .{ .root_source_file = b.path("src/usage.zig") }));
    main_module.addImport("hosted", b.addModule("hosted", .{ .root_source_file = b.path("src/hosted.zig") }));

const server = b.addModule("server", .{ .root_source_file = b.path("src/server/http.zig") });
    server.addImport("auth_middleware", b.addModule("auth_middleware", .{ .root_source_file = b.path("src/server/auth_middleware.zig") }));
    server.addImport("audit", b.addModule("audit", .{ .root_source_file = b.path("src/audit/logger.zig") }));
    server.addImport("apikey", b.addModule("apikey", .{ .root_source_file = b.path("src/apikey.zig") }));
    server.addImport("hosted", b.addModule("hosted", .{ .root_source_file = b.path("src/hosted.zig") }));
    main_module.addImport("server", server);
    
    // Add async HTTP server module
    const server_async = b.addModule("server_async", .{ .root_source_file = b.path("src/server/http_async.zig") });
    server_async.addImport("audit", b.addModule("audit", .{ .root_source_file = b.path("src/audit/logger.zig") }));
    server_async.addImport("apikey", b.addModule("apikey", .{ .root_source_file = b.path("src/apikey.zig") }));
    server_async.addImport("hosted", b.addModule("hosted", .{ .root_source_file = b.path("src/hosted.zig") }));
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

    // Config integration tests module
    const config_test_module = b.createModule(.{
        .root_source_file = b.path("src/config_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_test_obj = b.addTest(.{
        .root_module = config_test_module,
    });

    const config_test_step = b.step("test-config", "Run config integration tests");
    const config_test_run = b.addRunArtifact(config_test_obj);
    config_test_step.dependOn(&config_test_run.step);

    // Security integration tests (formerly orphaned — src/integration_test.zig)
    const security_test_module = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const security_test_obj = b.addTest(.{
        .root_module = security_test_module,
    });

    const security_test_step = b.step("test-security", "Run SecurityArena/Secret/Agent integration tests");
    const security_test_run = b.addRunArtifact(security_test_obj);
    security_test_step.dependOn(&security_test_run.step);

    // Audit integration tests (formerly orphaned — src/audit/integration_test.zig).
    // Uses wrapper at src/ level so module root = src/, allowing @import("../config.zig")
    // in src/audit/ files to resolve within the module path.
    const audit_test_module = b.createModule(.{
        .root_source_file = b.path("src/audit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const audit_test_obj = b.addTest(.{
        .root_module = audit_test_module,
    });

    const audit_test_step = b.step("test-audit", "Run audit log integrity integration tests");
    const audit_test_run = b.addRunArtifact(audit_test_obj);
    audit_test_step.dependOn(&audit_test_run.step);

    // Gap coverage tests (edge cases not covered by existing unit/integration tests)
    const gap_test_module = b.createModule(.{
        .root_source_file = b.path("src/gap_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gap_test_obj = b.addTest(.{
        .root_module = gap_test_module,
    });

    const gap_test_step = b.step("test-gaps", "Run coverage gap tests (edge cases, boundary conditions)");
    const gap_test_run = b.addRunArtifact(gap_test_obj);
    gap_test_step.dependOn(&gap_test_run.step);

    // Combined test step
    const all_tests_step = b.step("test-all", "Run all tests (unit + E2E + config + security + audit + gaps)");
    all_tests_step.dependOn(&test_run.step);
    all_tests_step.dependOn(&e2e_run.step);
    all_tests_step.dependOn(&e2e_server_run.step);
    all_tests_step.dependOn(&config_test_run.step);
    all_tests_step.dependOn(&security_test_run.step);
    all_tests_step.dependOn(&audit_test_run.step);
    all_tests_step.dependOn(&gap_test_run.step);

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

    // ============================================================================
    // Fuzzing Targets
    // ============================================================================
    // Fuzz targets live at src/ level so file-path imports resolve within src/.
    // For libFuzzer mode, compile with -fsanitize=fuzzer externally.

    // --- fuzz_jwt ---
    const fuzz_jwt_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_jwt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fuzz_jwt_exe = b.addExecutable(.{
        .name = "fuzz_jwt",
        .root_module = fuzz_jwt_module,
    });
    fuzz_jwt_exe.linkLibC();

    b.installArtifact(fuzz_jwt_exe);

    const fuzz_jwt_run = b.addRunArtifact(fuzz_jwt_exe);
    if (b.args) |args| {
        fuzz_jwt_run.addArgs(args);
    }

    const fuzz_jwt_step = b.step("fuzz-jwt", "Run JWT fuzzing target");
    fuzz_jwt_step.dependOn(&fuzz_jwt_run.step);

    // --- fuzz_policy ---
    const fuzz_policy_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_policy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fuzz_policy_exe = b.addExecutable(.{
        .name = "fuzz_policy",
        .root_module = fuzz_policy_module,
    });
    fuzz_policy_exe.linkLibC();

    b.installArtifact(fuzz_policy_exe);

    const fuzz_policy_run = b.addRunArtifact(fuzz_policy_exe);
    if (b.args) |args| {
        fuzz_policy_run.addArgs(args);
    }

    const fuzz_policy_step = b.step("fuzz-policy", "Run Policy parser fuzzing target");
    fuzz_policy_step.dependOn(&fuzz_policy_run.step);
}
