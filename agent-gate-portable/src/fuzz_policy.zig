//! Policy parser fuzzing target for libFuzzer.
//!
//! Fuzzes `parse` (PolicyFile parser) to find crashes from malformed JSON or
//! unexpected policy structures. Exercises deeply nested JSON, invalid syntax, etc.
//!
//! Usage:
//!   zig build fuzz-policy -- -runs=10000      # libFuzzer mode
//!   echo '{"version":"1","policies":[]}' | zig build fuzz-policy  # standalone
//!
//! Seed corpus: fuzz/corpus/policy/
//!
//! NOTE: This file lives at src/ level so file-path imports resolve within src/.

const std = @import("std");
const policy_parse = @import("policy/parser.zig").parse;
const SecurityArena = @import("memory.zig").SecurityArena;

/// libFuzzer entry point.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) i32 {
    fuzzBytes(data[0..size]) catch return 0;
    return 0;
}

/// Core fuzz logic — parse a policy file.
fn fuzzBytes(input: []const u8) !void {
    const alloc = std.heap.c_allocator;

    // Arena for parsed policy — reset on each iteration.
    var arena = try SecurityArena.init(alloc, 4096);
    defer arena.deinit();

    // Parse the fuzzer input as a policy file.
    const parse_result = policy_parse(input, &arena);

    if (parse_result) |_| {
        // Parsing succeeded — arena owns all memory.
    } else |_| {
        // Parse errors are expected — no crash check only.
    }
}

/// Standalone entry point for development without libFuzzer.
///
/// Usage:
///   echo '{"version":"1","policies":[]}' | zig build fuzz-policy   # stdin mode
pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // If stdin is a terminal, print usage and exit.
    if (std.fs.File.stdin().isTty()) {
        std.debug.print(
            \\fuzz_policy: Policy parser fuzzing target
            \\
            \\Usage (standalone):
            \\  echo '...' | fuzz_policy
            \\
            \\Usage (libFuzzer):
            \\  zig build-exe src/fuzz_policy.zig -fsanitize=fuzzer -lc
            \\  ./fuzz_policy -runs=10000 fuzz/corpus/policy/
            \\
        , .{});
        return;
    }

    const stdin = std.fs.File.stdin();
    const input = try stdin.readToEndAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(input);

    if (input.len == 0) {
        std.debug.print("fuzz_policy: empty input\n", .{});
        return;
    }

    _ = try fuzzBytes(input);
    std.debug.print("fuzz_policy: OK ({} bytes)\n", .{input.len});
}
