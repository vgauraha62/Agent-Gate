//! JWT fuzzing target for libFuzzer.
//!
//! Fuzzes `JWT.parse` + `JWT.verify` to find crashes from malformed tokens.
//! The HMAC path is exercised when `verify` is called after successful parse.
//!
//! Usage:
//!   zig build fuzz-jwt -- -runs=10000        # libFuzzer mode
//!   echo "eyJ..." | zig build fuzz-jwt       # standalone stdin mode
//!
//! Seed corpus: fuzz/corpus/jwt/
//!
//! NOTE: This file lives at src/ level so file-path imports resolve within src/.

const std = @import("std");
const jwt = @import("auth/jwt.zig");
const SecurityArena = @import("memory.zig").SecurityArena;
const Secret = @import("secret.zig").Secret;

/// libFuzzer entry point.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) i32 {
    fuzzBytes(data[0..size]) catch return 0;
    return 0;
}

/// Core fuzz logic — parse and verify a JWT token.
fn fuzzBytes(input: []const u8) !void {
    const alloc = std.heap.c_allocator;

    // Arena for parsed token — reset on each iteration to prevent memory growth.
    var arena = try SecurityArena.init(alloc, 4096);
    defer arena.deinit();

    // Static test secret (same across all iterations).
    var secret = try Secret.init(alloc, "fuzz-test-secret-key-for-jwt-00000000");
    defer secret.deinit();

    // Parse the fuzzer input as a JWT.
    const parse_result = jwt.JWT.parse(input, &arena);

    // If parsing succeeds, also call verify to exercise the HMAC path.
    // This is critical: the HMAC signature verification is where the stack
    // buffer overflow was fixed (messages >192 bytes for HS256).
    if (parse_result) |token| {
        _ = token.verify(&secret, .{}) catch {};
    } else |_| {
        // Parse errors are expected — we just verify no crash occurs.
    }
}

/// Standalone entry point for development without libFuzzer.
///
/// Usage:
///   echo "eyJhbGci..." | zig build fuzz-jwt        # stdin mode
///   zig build fuzz-jwt -- --help                    # (passthrough to --help)
///   zig build fuzz-jwt -- -runs=10000              # (passthrough for libFuzzer)
pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // If stdin is a terminal, print usage and exit.
    if (std.fs.File.stdin().isTty()) {
        std.debug.print(
            \\fuzz_jwt: JWT fuzzing target
            \\
            \\Usage (standalone):
            \\  echo 'eyJhbGci...' | fuzz_jwt
            \\
            \\Usage (libFuzzer):
            \\  zig build-exe src/fuzz_jwt.zig -fsanitize=fuzzer -lc
            \\  ./fuzz_jwt -runs=10000 fuzz/corpus/jwt/
            \\
        , .{});
        return;
    }

    const stdin = std.fs.File.stdin();
    const input = try stdin.readToEndAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(input);

    if (input.len == 0) {
        std.debug.print("fuzz_jwt: empty input (pass a JWT token via stdin)\n", .{});
        return;
    }

    _ = try fuzzBytes(input);
    std.debug.print("fuzz_jwt: OK ({} bytes)\n", .{input.len});
}
