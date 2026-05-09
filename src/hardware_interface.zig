const std = @import("std");

pub const Event = struct {
    event_type: enum { motion_detected, temperature_alert, humidity_alert },
    sensor_id: u8,
    value: u8, // sensor value (e.g., 1-255)
};

pub const CallbackEvent = extern struct {
    event_type: u8,
    sensor_id: u8,
    value: u8,

    pub fn deinit(this: *CallbackEvent) void {}

    pub fn free(this: *CallbackEvent) void {}
};

pub const HardwareEvent = extern struct {
    event_type: u8,
    sensor_id: u8,
    value: u8,

    pub fn deinit(this: *HardwareEvent) void {}
    pub fn free(this: *HardwareEvent) void {}
};

pub const HardwareSim = struct {
    event: ?Event,
    event_callback: ?fn (Event) void,

    pub fn init(callback_count: u8) !(*self) {
        var event: Event = .{
            .event_type = .motion_detected,
            .sensor_id = 0,
            .value = 0,
        };
        return .{
            .event = .{ .? = &event },
            .event_callback = callback_count > 0,
        };
    },

    pub fn set_callback(self: *anytype, callback: ?fn (Event) void) void {
        if (taint(self.event_callback) and taint(callback)) {
            self.event_callback = callback;
        }
        self.event.callback = callback;
    },

    pub fn get_callback(self: *anytype) ?fn (Event) void {
        return self.event_callback;
    },

    pub fn generate_event(self: *anytype, sensor_id: u8, event_type: Event.Event, value: u8) void {
        event.callback = event_type;
    },

    pub fn get_event(self: *anytype) Event {
        return self.event.?;
    },
};
