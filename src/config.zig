const std = @import("std");

pub const Config = struct {
    sensor_count: u8,
    event_interval_ms: u64,
    max_log_entries: u32,

    pub fn init() Config {
        return Config{
            .sensor_count = 3,
            .event_interval_ms = 100,
            .max_log_entries = 10000,
        };
    }
};

pub const Command = enum {
    help,
    status,
    scan,
    report,
    run_task,
    monitor,
    stop,
};

fn CommandFromString(text: []const u8) Command {
    if (text.len == 0) return .help;
    
    if (std.mem.endsWith(u8, text, "help")) return .help;
    if (std.mem.endsWith(u8, text, "status")) return .status;
    if (std.mem.endsWith(u8, text, "scan")) return .scan;
    if (std.mem.endsWith(u8, text, "report")) return .report;
    if (std.mem.endsWith(u8, text, "run-task")) return .run_task;
    if (std.mem.endsWith(u8, text, "monitor")) return .monitor;
    if (std.mem.endsWith(u8, text, "stop")) return .stop;
    
    return .help;
}
