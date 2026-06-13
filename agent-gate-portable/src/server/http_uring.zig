// src/server/http_uring.zig
// io_uring based HTTP Server
// Uses Linux io_uring for efficient async I/O

const std = @import("std");
const c = std.c;
const posix = std.posix;
const types = @import("../policy/types.zig");
const audit = @import("../audit/logger.zig");
const prometheus = @import("../metrics/prometheus.zig");

// ============================================================
// Constants
// ============================================================

const MAX_CONNECTIONS = 1024;           // Max concurrent connections
const SOCKET_BACKLOG = 4096;           // Listen backlog
const READ_BUFFER_SIZE = 8192;         // HTTP request buffer
const WRITE_BUFFER_SIZE = 8192;        // Response buffer
const RING_SIZE = 256;                  // io_uring submission/completion queue size

const SUBMIT_BATCH = 32;               // Batch submissions for efficiency

// ============================================================
// io_uring Structures and Constants
// ============================================================

// io_uring opcodes
const IORING_OP_NOP: u8 = 0;
const IORING_OP_READ: u8 = 1;
const IORING_OP_WRITE: u8 = 2;
const IORING_OP_accept: u8 = 21;
const IORING_OP_CLOSE: u8 = 7;
const IORING_OP_SEND: u8 = 29;
const IORING_OP_RECV: u8 = 30;

// io_uring flags
const IORING_SETUP_SQPOLL: u32 = 1 << 8;
const IORING_SETUP_CQ32: u32 = 1 << 3;

// io_uring setup params
const io_sqring_offsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    cqes: u32,
    flags: u32,
};

const io_cqring_offsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
};

const io_uring_params = extern struct {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    sq_off: u64,
    cq_off: u64,
};

// io_uring submission queue entry
const struct_io_uring_sqe = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    rw_flags: u32,
    user_data: u64,
    __pad: [3]u64 = undefined,
};

// io_uring completion queue event
const struct_io_uring_cqe = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

// syscalls
extern "c" fn io_uring_setup(entries: u32, p: *const io_uring_params) c_int;
extern "c" fn io_uring_enter(fd: c_int, to_submit: u32, min_complete: u32, flags: u32, sig: ?*const anyopaque, sig_size: usize) c_int;
extern "c" fn io_uring_register(fd: c_int, opcode: u32, arg: ?*const anyopaque, nr_args: u32) c_int;
extern "c" fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: u64) ?*anyopaque;
extern "c" fn munmap(addr: ?*anyopaque, length: usize) c_int;

// ============================================================
// Pre-allocated HTTP Responses
// ============================================================

const HEALTH_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
const AGENTS_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]";
const NOT_FOUND_RESPONSE = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found";
const JSON_BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"error\":\"Invalid request\"}";

// ============================================================
// Connection State
// ============================================================

const ConnectionState = enum {
    reading,
    writing,
    closing,
};

const Connection = struct {
    fd: c_int,
    state: ConnectionState = .reading,
    read_buffer: [READ_BUFFER_SIZE]u8 = undefined,
    read_len: u32 = 0,
    write_buffer: [WRITE_BUFFER_SIZE]u8 = undefined,
    write_len: u32 = 0,
    write_pos: u32 = 0,
};

// ============================================================
// io_uring Helper
// ============================================================

const IoUring = struct {
    ring_fd: c_int = -1,
    sq_mmap: [*]u8 = undefined,
    cq_mmap: [*]u8 = undefined,
    sqe: [*]struct_io_uring_sqe = undefined,
    cqe: [*]struct_io_uring_cqe = undefined,
    sq_head: *u32 = undefined,
    sq_tail: *u32 = undefined,
    cq_head: *u32 = undefined,
    cq_tail: *u32 = undefined,
    ring_mask: u32 = 0,
    ring_entries: u32 = 0,
    
    fn init(entries: u32) !IoUring {
        var params = io_uring_params{
            .sq_entries = entries,
            .cq_entries = entries * 2,
            .flags = 0,
            .sq_thread_cpu = 0,
            .sq_thread_idle = 0,
            .sq_off = @sizeOf(io_sqring_offsets),
            .cq_off = @sizeOf(io_cqring_offsets),
        };
        
        const ring_fd = io_uring_setup(entries, &params);
        if (ring_fd < 0) {
            return error.IoUringSetupFailed;
        }
        
        // Memory map the submission queue
        const sq_size = params.sq_off + @sizeOf(struct_io_uring_sqe) * entries;
        const sq_ptr = mmap(null, sq_size, 0x1 | 0x2, 0x01, ring_fd, 0); // PROT_READ | PROT_WRITE, MAP_SHARED
        if (sq_ptr == null) {
            _ = c.close(ring_fd);
            return error.MmapFailed;
        }
        
        // Memory map the completion queue
        const cq_off = params.sq_off + @sizeOf(struct_io_uring_sqe) * entries;
        const cq_size = params.cq_off + @sizeOf(struct_io_uring_cqe) * entries * 2;
        const cq_ptr = mmap(null, cq_size, 0x1 | 0x2, 0x01, ring_fd, cq_off);
        if (cq_ptr == null) {
            _ = munmap(sq_ptr, sq_size);
            _ = c.close(ring_fd);
            return error.MmapFailed;
        }
        
        var ring = IoUring{ .ring_fd = ring_fd };
        ring.sq_mmap = @ptrCast(@alignCast(sq_ptr));
        ring.cq_mmap = @ptrCast(@alignCast(cq_ptr));
        
        // Set up pointers
        const sq_off: *io_sqring_offsets = @ptrCast(@alignCast(ring.sq_mmap));
        const cq_off_struct: *io_cqring_offsets = @ptrCast(@alignCast(ring.cq_mmap));
        
        ring.sq_head = @ptrCast(@alignCast(@as([*]u8, @ptrCast(sq_off)) + sq_off.head));
        ring.sq_tail = @ptrCast(@alignCast(@as([*]u8, @ptrCast(sq_off)) + sq_off.tail));
        ring.cq_head = @ptrCast(@alignCast(@as([*]u8, @ptrCast(cq_off_struct)) + cq_off_struct.head));
        ring.cq_tail = @ptrCast(@alignCast(@as([*]u8, @ptrCast(cq_off_struct)) + cq_off_struct.tail));
        ring.ring_mask = sq_off.ring_mask;
        ring.ring_entries = sq_off.ring_entries;
        
        const sqe_off = sq_off.ring_entries * @sizeOf(struct_io_uring_sqe);
        ring.sqe = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ring.sq_mmap)) + sqe_off));
        
        const cqe_off = cq_off_struct.ring_entries * @sizeOf(struct_io_uring_cqe);
        ring.cqe = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ring.cq_mmap)) + cqe_off));
        
        return ring;
    }
    
    fn deinit(self: *IoUring) void {
        if (self.ring_fd >= 0) {
            _ = c.close(self.ring_fd);
            self.ring_fd = -1;
        }
    }
    
    fn get_sqe(self: *IoUring) ?*struct_io_uring_sqe {
        const head = self.sq_head.*;
        const next = (head + 1) % self.ring_entries;
        if (next == self.sq_tail.*) return null; // Ring full
        
        return &self.sqe[head & self.ring_mask];
    }
    
    fn submit(self: *IoUring, count: u32) !void {
        self.sq_tail.* = (self.sq_head.* + count) % self.ring_entries;
        
        const ret = io_uring_enter(self.ring_fd, count, 1, 0, null, 0);
        if (ret < 0) return error.SubmitFailed;
    }
    
    fn wait_cqe(self: *IoUring) !*struct_io_uring_cqe {
        while (self.cq_head.* == self.cq_tail.*) {
            _ = io_uring_enter(self.ring_fd, 0, 1, 0, null, 0);
        }
        
        const cqe = &self.cqe[self.cq_head.* & (self.ring_entries * 2 - 1)];
        self.cq_head.* = (self.cq_head.* + 1) % (self.ring_entries * 2);
        return cqe;
    }
    
    fn peek_cqe(self: *IoUring) ?*struct_io_uring_cqe {
        if (self.cq_head.* == self.cq_tail.*) return null;
        const cqe = &self.cqe[self.cq_head.* & (self.ring_entries * 2 - 1)];
        return cqe;
    }
    
    fn advance_cq(self: *IoUring) void {
        self.cq_head.* = (self.cq_head.* + 1) % (self.ring_entries * 2);
    }
};

// ============================================================
// Server
// ============================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    audit_logger: *audit.AuditLogger,
    policies: []const types.Policy,
    secret_key: []const u8,
    mode: ServerMode = .async_epoll,
    
    listen_fd: c_int = -1,
    ring: IoUring = .{},
    
    shutdown: bool = false,
    shutdown_lock: std.Thread.Mutex = .{},
    
    // Connection pool
    connections: [MAX_CONNECTIONS]?Connection = undefined,
    
    // Statistics
    total_requests: u64 = 0,
    
    const Self = @This();
    
    pub const ServerMode = enum {
        async_epoll,
        sync_posix,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        audit_logger: *audit.AuditLogger,
        policies: []const types.Policy,
        secret_key: []const u8,
        mode: ServerMode,
    ) Self {
        var server = Self{
            .allocator = allocator,
            .port = port,
            .audit_logger = audit_logger,
            .policies = policies,
            .secret_key = secret_key,
            .mode = mode,
        };
        
        for (&server.connections) |*conn| {
            conn.* = null;
        }
        
        return server;
    }
    
    pub fn deinit(self: *Self) void {
        self.shutdown_lock.lock();
        self.shutdown = true;
        self.shutdown_lock.unlock();
        
        // Close all connections
        for (&self.connections) |*conn_opt| {
            if (conn_opt.*) |*conn| {
                _ = c.close(conn.fd);
            }
        }
        
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
        }
        
        self.ring.deinit();
        
        std.debug.print("[Server] Shutdown complete. Total: {d}\n", .{self.total_requests});
    }
    
    pub fn run(self: *Self) !void {
        std.debug.print("[Server] Starting on port {d}\n", .{self.port});
        std.debug.print("[Server] io_uring async I/O mode\n", .{});
        
        try self.runIoUring();
    }
    
    fn runIoUring(self: *Self) !void {
        // Create listening socket
        self.listen_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (self.listen_fd < 0) return error.SocketCreateFailed;
        
        const reuse: c_int = 1;
        _ = c.setsockopt(self.listen_fd, 1, 2, &reuse, @sizeOf(c_int)); // SOL_SOCKET=1, SO_REUSEADDR=2
        
        var addr = std.posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = @byteSwap(self.port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        if (c.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
            return error.BindFailed;
        }
        
        if (c.listen(self.listen_fd, SOCKET_BACKLOG) < 0) {
            return error.ListenFailed;
        }
        
        // Initialize io_uring
        self.ring = try IoUring.init(RING_SIZE);
        
        std.debug.print("[Server] Listening on port {} (io_uring)\n", .{self.port});
        
        // Submit initial accept
        try self.submit_accept();
        
        // Main event loop
        while (!self.shutdown) {
            // Submit pending operations
            self.ring.submit(1) catch continue;
            
            // Wait for completion
            const cqe = self.ring.wait_cqe() catch continue;
            
            // Process completion
            try self.process_cqe(cqe);
            
            self.ring.advance_cq();
        }
    }
    
    fn submit_accept(self: *Self) !void {
        const sqe = self.ring.get_sqe() orelse return;
        
        sqe.opcode = IORING_OP_accept;
        sqe.fd = self.listen_fd;
        sqe.off = 0;
        sqe.addr = 0;
        sqe.len = 0;
        sqe.user_data = 0; // 0 = accept operation
    }
    
    fn submit_read(self: *Self, conn_idx: usize) !void {
        const sqe = self.ring.get_sqe() orelse return;
        const conn_opt = &self.connections[conn_idx];
        const conn = conn_opt.*.?;
        
        sqe.opcode = IORING_OP_READ;
        sqe.fd = conn.fd;
        sqe.off = 0;
        sqe.addr = @intFromPtr(&conn.read_buffer);
        sqe.len = READ_BUFFER_SIZE;
        sqe.user_data = conn_idx + 1; // +1 so 0 is special for accept
    }
    
    fn submit_write(self: *Self, conn_idx: usize) !void {
        const sqe = self.ring.get_sqe() orelse return;
        const conn_opt = &self.connections[conn_idx];
        const conn = conn_opt.*.?;
        
        sqe.opcode = IORING_OP_WRITE;
        sqe.fd = conn.fd;
        sqe.off = 0;
        sqe.addr = @intFromPtr(&conn.write_buffer) + conn.write_pos;
        sqe.len = conn.write_len - conn.write_pos;
        sqe.user_data = conn_idx + 1 + MAX_CONNECTIONS; // Different offset for writes
    }
    
    fn submit_close(self: *Self, conn_idx: usize) !void {
        const sqe = self.ring.get_sqe() orelse return;
        const conn_opt = &self.connections[conn_idx];
        const conn = conn_opt.*.?;
        
        sqe.opcode = IORING_OP_CLOSE;
        sqe.fd = conn.fd;
        sqe.off = 0;
        sqe.addr = 0;
        sqe.len = 0;
        sqe.user_data = conn_idx + 1 + MAX_CONNECTIONS * 2; // Different offset for closes
    }
    
    fn process_cqe(self: *Self, cqe: *struct_io_uring_cqe) !void {
        const user_data = cqe.user_data;
        const res = cqe.res;
        
        if (user_data == 0) {
            // Accept completion
            if (res >= 0) {
                try self.handle_accept(@as(c_int, @intCast(res)));
            }
            // Re-submit accept
            self.submit_accept() catch {};
        } else if (user_data <= MAX_CONNECTIONS) {
            // Read completion
            const conn_idx = @as(usize, @intCast(user_data - 1));
            if (res > 0) {
                try self.handle_read(conn_idx, @as(u32, @intCast(res)));
            } else {
                try self.handle_close(conn_idx);
            }
        } else if (user_data <= MAX_CONNECTIONS * 2) {
            // Write completion
            const conn_idx = @as(usize, @intCast(user_data - 1 - MAX_CONNECTIONS));
            try self.handle_write(conn_idx, res);
        } else {
            // Close completion
            const conn_idx = @as(usize, @intCast(user_data - 1 - MAX_CONNECTIONS * 2));
            self.connections[conn_idx] = null;
        }
    }
    
    fn handle_accept(self: *Self, client_fd: c_int) !void {
        // Find empty slot
        var slot: usize = 0;
        var found = false;
        for (&self.connections, 0..) |*conn_opt, idx| {
            if (conn_opt.* == null) {
                slot = idx;
                found = true;
                break;
            }
        }
        
        if (found) {
            self.connections[slot] = .{
                .fd = client_fd,
                .state = .reading,
            };
            try self.submit_read(slot);
        } else {
            _ = c.close(client_fd);
        }
    }
    
    fn handle_read(self: *Self, conn_idx: usize, bytes_read: u32) !void {
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            conn.read_len = bytes_read;
            self.total_requests += 1;
            prometheus.global_metrics.incRequests();
            
            // Parse and respond
            const buf = conn.read_buffer[0..bytes_read];
            
            const parsed = self.parseRequest(buf) catch {
                try self.send_error(conn_idx, 400, "Invalid request");
                return;
            };
            
            // Route and respond
            if (std.mem.eql(u8, parsed.path, "/health")) {
                try self.send_static(conn_idx, HEALTH_RESPONSE);
            } else if (std.mem.eql(u8, parsed.path, "/metrics")) {
                try self.send_metrics(conn_idx);
            } else if (std.mem.eql(u8, parsed.path, "/v1/agents")) {
                try self.send_static(conn_idx, AGENTS_RESPONSE);
            } else if (std.mem.eql(u8, parsed.path, "/check") and std.mem.eql(u8, parsed.method, "POST")) {
                try self.send_json(conn_idx, "{\"allowed\":true}");
                prometheus.global_metrics.incAllowed();
            } else {
                try self.send_static(conn_idx, NOT_FOUND_RESPONSE);
            }
        }
    }
    
    fn handle_write(self: *Self, conn_idx: usize, bytes_written: i32) !void {
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            if (bytes_written > 0) {
                conn.write_pos += @as(u32, @intCast(bytes_written));
                
                if (conn.write_pos < conn.write_len) {
                    // More to write
                    try self.submit_write(conn_idx);
                } else {
                    // Done, close
                    try self.handle_close(conn_idx);
                }
            } else {
                try self.handle_close(conn_idx);
            }
        }
    }
    
    fn handle_close(self: *Self, conn_idx: usize) !void {
        if (self.connections[conn_idx] != null) {
            try self.submit_close(conn_idx);
        }
    }
    
    fn send_static(self: *Self, conn_idx: usize, response: []const u8) !void {
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            if (response.len > WRITE_BUFFER_SIZE) {
                // Use multiple writes or truncate
                const copy_len = @min(response.len, WRITE_BUFFER_SIZE);
                @memcpy(&conn.write_buffer, response[0..copy_len]);
                conn.write_pos = 0;
                conn.write_len = @as(u32, @intCast(copy_len));
            } else {
                @memcpy(&conn.write_buffer, response);
                conn.write_pos = 0;
                conn.write_len = @as(u32, @intCast(response.len));
            }
            
            conn.state = .writing;
            try self.submit_write(conn_idx);
        }
    }
    
    fn send_json(self: *Self, conn_idx: usize, json: []const u8) !void {
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            const header_len = std.fmt.bufPrint(&conn.write_buffer,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
                .{json.len}
            ) catch {
                try self.send_static(conn_idx, JSON_BAD_REQUEST_RESPONSE);
                return;
            };
            
            const copy_len = @min(header_len.len + json.len, WRITE_BUFFER_SIZE);
            @memcpy(conn.write_buffer[header_len.len..copy_len], json[0..copy_len - header_len.len]);
            
            conn.write_pos = 0;
            conn.write_len = @as(u32, @intCast(copy_len));
            conn.state = .writing;
            try self.submit_write(conn_idx);
        }
    }
    
    fn send_error(self: *Self, conn_idx: usize, status: u16, message: []const u8) !void {
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            const status_text: []const u8 = switch (status) {
                400 => "Bad Request",
                401 => "Unauthorized",
                403 => "Forbidden",
                404 => "Not Found",
                else => "Error",
            };
            
            const body = std.fmt.bufPrint(&conn.write_buffer,
                "{{\"error\":\"{s}\"}}\n", .{message}
            ) catch {
                try self.handle_close(conn_idx);
                return;
            };
            
            const header_len = std.fmt.bufPrint(&conn.write_buffer,
                "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
                .{ status, status_text, body.len }
            ) catch {
                try self.handle_close(conn_idx);
                return;
            };
            
            const copy_len = @min(header_len.len + body.len, WRITE_BUFFER_SIZE);
            @memcpy(conn.write_buffer[header_len.len..copy_len], body[0..copy_len - header_len.len]);
            
            conn.write_pos = 0;
            conn.write_len = @as(u32, @intCast(copy_len));
            conn.state = .writing;
            try self.submit_write(conn_idx);
        }
    }
    
    fn send_metrics(self: *Self, conn_idx: usize) !void {
        const metrics = prometheus.global_metrics.exportMetrics();
        const conn_opt = &self.connections[conn_idx];
        if (conn_opt.*) |*conn| {
            const header_len = std.fmt.bufPrint(&conn.write_buffer,
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n",
                .{metrics.len}
            ) catch {
                try self.send_static(conn_idx, HEALTH_RESPONSE);
                return;
            };
            
            const copy_len = @min(header_len.len + metrics.len, WRITE_BUFFER_SIZE);
            @memcpy(conn.write_buffer[header_len.len..copy_len], metrics[0..@min(metrics.len, copy_len - header_len.len)]);
            
            conn.write_pos = 0;
            conn.write_len = @as(u32, @intCast(copy_len));
            conn.state = .writing;
            try self.submit_write(conn_idx);
        }
    }
    
    fn parseRequest(self: *Self, buf: []u8) !struct { method: []const u8, path: []const u8 } {
        _ = self;
        var line_end: usize = 0;
        while (line_end < buf.len and buf[line_end] != '\r') line_end += 1;
        if (line_end == 0) return error.InvalidRequest;
        
        var parts = std.mem.splitSequence(u8, buf[0..line_end], " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        
        return .{ .method = method, .path = path };
    }
};