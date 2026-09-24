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

    // ponytail: one helper over 7 copy-pasted test stanzas
    const TestSuite = struct { step_name: []const u8, desc: []const u8, src: []const u8 };
    const suites = [_]TestSuite{
        .{ .step_name = "test", .desc = "Run unit tests", .src = "src/test_integration.zig" },
        .{ .step_name = "test-e2e", .desc = "Run E2E integration tests", .src = "src/integration_e2e_test.zig" },
        .{ .step_name = "test-e2e-server", .desc = "Run E2E server tests", .src = "src/e2e_server_test.zig" },
        .{ .step_name = "test-config", .desc = "Run config integration tests", .src = "src/config_integration_test.zig" },
        .{ .step_name = "test-security", .desc = "Run SecurityArena/Secret/Agent integration tests", .src = "src/integration_test.zig" },
        .{ .step_name = "test-audit", .desc = "Run audit log integrity integration tests", .src = "src/audit_tests.zig" },
        .{ .step_name = "test-gaps", .desc = "Run coverage gap tests (edge cases, boundary conditions)", .src = "src/gap_test.zig" },
    };
    // Combined test step
    const all_tests_step = b.step("test-all", "Run all tests (unit + E2E + config + security + audit + gaps)");
    inline for (suites) |s| {
        const mod = b.createModule(.{
            .root_source_file = b.path(s.src),
            .target = target,
            .optimize = optimize,
        });
        const obj = b.addTest(.{ .root_module = mod });
        const stp = b.step(s.step_name, s.desc);
        const run = b.addRunArtifact(obj);
        stp.dependOn(&run.step);
        all_tests_step.dependOn(&run.step);
    }

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
