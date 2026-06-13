# macOS Port Plan: Agent-Gate

> **Status**: Planning complete. Ready for implementation.
> **Date**: 2026-05-25
> **Target Zig Version**: 0.15.2 (matching current `.zig-version`)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Codebase Analysis](#2-codebase-analysis)
3. [Platform-Specific Inventory](#3-platform-specific-inventory)
4. [Architecture](#4-architecture)
5. [Tasks](#5-tasks)
6. [Dependency Graph](#6-dependency-graph)
7. [Windows Considerations (Future)](#7-windows-considerations-future)
8. [Appendix: kqueue API Reference](#8-appendix-kqueue-api-reference)

---

## 1. Overview

### What is Agent-Gate?

Agent-Gate is a high-performance policy-based access control (PBAC) sidecar proxy written in Zig. It features:

- Custom HTTP/1.1 server with epoll-based async I/O
- JSON-based policy engine (allow/deny rules)
- JWT authentication and mTLS support
- Tamper-evident audit logging (Merkle chain + Ed25519 signing)
- Prometheus-compatible metrics
- Denial request tracking

### Goal

Port Agent-Gate from Linux-only to **cross-platform** (macOS first, Windows later).

**Strategy**: macOS targets are POSIX-compliant and share most of the same kernel APIs as Linux (signals, sockets, file I/O, threads). The **sole major blocker** is epoll, which is Linux-specific. The solution is to implement a **kqueue-based** server module that mirrors the existing epoll-based `http.zig`.

### Approach

| Decision | Choice |
|----------|--------|
| I/O strategy | **kqueue server** (macOS native async I/O, same performance class as epoll) |
| Code organization | **Separate file per OS**: `http_kqueue.zig` sits alongside `http.zig` |
| Sync fallback | POSIX `poll()` (available on both Linux and macOS) |
| Zig version | **0.15.2** — match existing `.zig-version`, verify kqueue bindings exist |
| Build system | Detect target OS at comptime in `build.zig` → select the right server module |

---

## 2. Codebase Analysis

### Directory Structure

```
src/
├── main.zig                    # Entry point, server mode selection
├── agent.zig                   # Agent context (32-byte ID, permission bitmask)
├── secret.zig                  # Zeroizing secret container
├── memory.zig                  # SecurityArena (bump allocator)
├── config.zig                  # Config loading (JSON + env overrides)
├── errors.zig                  # Unified error taxonomy
├── denial_tracker.zig          # Ring buffer for denied requests
├── shutdown.zig                # SIGTERM/SIGINT handler
├── security_system.zig         # Stub/placeholder
├── hardware_interface.zig      # Stub/placeholder
│
├── auth/
│   ├── jwt.zig                 # JWT parsing & HMAC verification
│   └── mTLS.zig                # mTLS certificate handling (placeholder)
│
├── audit/
│   ├── logger.zig              # Tamper-evident ring buffer audit log
│   ├── crypto.zig              # Ed25519 signing
│   ├── verify.zig              # Audit log verification
│   └── types.zig               # LogEntry, Checkpoint types
│
├── policy/
│   ├── types.zig               # Policy, Condition, Decision, PolicySet
│   ├── parser.zig              # JSON policy file parser
│   └── engine.zig              # Policy evaluation engine
│
├── server/
│   ├── http.zig                # **epoll-based HTTP server** (Linux)
│   ├── http_async.zig          # **epoll-based, single-threaded** (Linux)
│   ├── http_uring.zig          # **io_uring-based server** (Linux-only, standalone)
│   └── auth_middleware.zig     # JWT auth middleware
│
└── metrics/
    ├── prometheus.zig           # Prometheus metric export
    └── histogram.zig            # HDR histogram for latencies
```

---

## 3. Platform-Specific Inventory

### 3.1 Linux-specific: epoll (MAJOR BLOCKER)

**Files**: `src/server/http.zig`, `src/server/http_async.zig`

Both files use:
- `c.epoll_create1(0)` — create epoll instance
- `c.epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev)` — register file descriptors
- `c.epoll_wait(epfd, events, max, timeout)` — wait for events
- `std.c.epoll_event` struct — event data structure
- `EPOLLIN`, `EPOLLOUT`, `EPOLLET` constants
- `EPOLL_CTL_ADD`, `EPOLL_CTL_MOD`, `EPOLL_CTL_DEL`

These are **not available on macOS**. They must be replaced with **kqueue**.

### 3.2 Linux-specific: io_uring (NOT IN MAIN BUILD)

**File**: `src/server/http_uring.zig`

Uses raw Linux syscalls:
- `io_uring_setup()`, `io_uring_enter()` extern declarations
- `mmap()` / `munmap()` for ring buffers
- Linux-specific `io_uring_params`, `struct_io_uring_sqe`, `struct_io_uring_cqe`

**Status**: This file is **not compiled into the main binary** (`main.zig` does not import it, and `build.zig` does not include it). It's a standalone experiment. No action needed for macOS, but should be guarded for future-proofing.

### 3.3 POSIX — works on macOS (no changes needed)

| API | File(s) | macOS Status |
|-----|---------|--------------|
| `c.socket()`, `c.bind()`, `c.listen()`, `c.accept()` | `http.zig`, `http_async.zig`, `http_uring.zig` | ✅ Standard POSIX |
| `c.read()`, `c.write()`, `c.close()` | All server files | ✅ Standard POSIX |
| `c.setsockopt()` with `SO.REUSEADDR` | All server files | ✅ Available (same constant values) |
| `posix.AF.INET`, `SOCK.STREAM`, `SOCK.NONBLOCK` | All server files | ✅ Available |
| `posix.sockaddr.in` | All server files | ✅ Same layout |
| `posix.signal(SIG.TERM, ...)` / `SIG.INT` | `shutdown.zig` | ✅ POSIX signals |
| `posix.getenv()` | `config.zig` | ✅ POSIX |
| `posix.accept()` | `mTLS.zig` | ✅ POSIX |
| `Thread.Pool`, `Thread.Mutex` | Various | ✅ Cross-platform in std |
| `std.time`, `std.fs`, `std.json`, `std.crypto` | Various | ✅ Cross-platform |

### 3.4 Pure Zig — works everywhere (no changes needed)

- `agent.zig` — Agent struct, PermissionSet
- `secret.zig` — Secret zeroizing container
- `memory.zig` — SecurityArena bump allocator
- `errors.zig` — Error taxonomy
- `denial_tracker.zig` — Ring buffer
- `auth/jwt.zig` — JWT parser/verifier (uses `std.crypto.sha2`, `std.crypto.hmac`)
- `auth/mTLS.zig` — Certificate loading (uses `std.fs`, base64 decode — pure Zig)
- `audit/logger.zig` — Audit logger (uses `std.crypto`)
- `audit/crypto.zig` — Ed25519 signer (uses `std.crypto.sign.Ed25519`)
- `audit/types.zig` — Log entry types
- `audit/verify.zig` — Verification logic
- `policy/types.zig` — Policy, Condition, PolicySet
- `policy/parser.zig` — JSON policy parser
- `policy/engine.zig` — Policy evaluation
- `metrics/prometheus.zig` — Prometheus metrics
- `metrics/histogram.zig` — HDR histogram
- `config.zig` — Config types, env var parsing

### 3.5 Summary

| Category | Count | Action |
|----------|-------|--------|
| **Linux-only (epoll)** | 2 files | Rewrite using kqueue |
| **Linux-only (io_uring)** | 1 file (standalone) | Guard with comptime error for macOS |
| **POSIX (works on macOS)** | ~8 API usages | No changes needed |
| **Pure Zig (fully portable)** | ~20 files | No changes needed |

**Key finding**: The only real barrier is **epoll** in `http.zig` and `http_async.zig`.

---

## 4. Architecture

### 4.1 Server Module Selection

```
                       Build System (build.zig)
                              │
                    ┌─────────┴──────────┐
                    │  target.os.tag     │
                    └─────────┬──────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                                ▼
      Linux (.tag == .linux)           macOS (.tag == .macos)
              │                                │
              ▼                                ▼
  src/server/http.zig               src/server/http_kqueue.zig
  (epoll + Thread.Pool)             (kqueue + Thread.Pool)
              │                                │
              └───────────────┬───────────────┘
                              │
                              ▼
                    Server (identical interface)
                    • .init() / .deinit() / .run()
                    • handleRequestThread()
                    • parseHttpRequestFast()
                    • send*Response() helpers
```

### 4.2 Shared Logic (identical across both files)

The following code in `http.zig` is **platform-independent** and will be copied verbatim into `http_kqueue.zig`:

- `ParsedRequest` struct
- `SSLClientInfo` struct
- `parseSSLHeaders()` — X-SSL header parsing
- `extractHeaderValue()` — header extraction
- `deriveAgentIdFromPEM()` — PEM fingerprinting
- `isAgentIdZero()` — zero check
- `handleRequestThread()` — request handler (uses only POSIX read/write/close)
- `parseHttpRequestFast()` — HTTP parser
- `detectKeepAlive()` — connection keep-alive detection
- `wantsKeepAlive()` — keep-alive check
- `parseCheckRequestFast()` — JSON body parser
- `handleCheckRequest()` — policy evaluation
- `handleDeniedRequests()` — denial endpoint
- All `send*()` response helpers
- `statusText()` — HTTP status text mapping

### 4.3 Platform-Specific Code (replaced in kqueue version)

The following functions in `http.zig` must be rewritten for kqueue:

| http.zig function | kqueue replacement |
|-------------------|--------------------|
| `runAsyncEpoll()` | `runAsyncKqueue()` |
| `acceptConnections()` | Same accept logic, but add fds via `kevent()` instead of `epoll_ctl()` |
| `handleClientAsync()` | Remove `epoll_ctl` DEL; let close handle cleanup |
| `deinit()` (epoll close) | Close `kq_fd` instead of `epoll_fd` |
| Epoll constants | kqueue constants (see Appendix) |
| `epoll_fd` field | `kq_fd` field |

### 4.4 ServerMode Enum

```zig
pub const ServerMode = enum {
    async_default,  // platform's best: epoll on Linux, kqueue on macOS
    sync_posix,     // POSIX poll-based fallback (both platforms)
};
```

Command-line flags: `--async` / `--sync`

---

## 5. Tasks

### Task 1: Create `src/server/http_kqueue.zig`

**Complexity**: Medium

**Description**: Port the full `http.zig` (1037 lines) to use kqueue instead of epoll. Keep all shared logic identical.

**Detailed steps**:

1. **Copy** `http.zig` → `http_kqueue.zig` as starting template.

2. **Replace epoll constants** (lines 29-34 in http.zig):
   ```
   EPOLLIN       → EVFILT_READ    (std.c.EVFILT_READ)
   EPOLLOUT      → EVFILT_WRITE   (std.c.EVFILT_WRITE)
   EPOLLET       → EV_CLEAR       (std.c.EV_CLEAR)
   EPOLL_CTL_ADD → (handled via EV_ADD flag below)
   EPOLL_CTL_MOD → (handled via EV_ADD | EV_DISABLE)
   EPOLL_CTL_DEL → (handled via EV_DELETE flag)
   ```

3. **Replace struct fields** (lines 287-288):
   ```
   epoll_fd: c_int = -1  →  kq_fd: c_int = -1
   ```

4. **Update `deinit()`** (around line 344):
   ```zig
   if (self.kq_fd >= 0) {
       _ = c.close(self.kq_fd);
       self.kq_fd = -1;
   }
   ```

5. **Rewrite `runAsyncEpoll()`** → `runAsyncKqueue()`:
   ```zig
   fn runAsyncKqueue(self: *Self) !void {
       // Create listening socket (same as epoll version)
       self.listen_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
       // ... (bind, listen — identical) ...

       // Create kqueue instance (replaces epoll_create1)
       self.kq_fd = c.kqueue();
       if (self.kq_fd < 0) return error.KqueueCreateFailed;

       // Register listen fd with kqueue (replaces epoll_ctl ADD)
       var change: std.posix.Kevent = .{
           .ident = @as(u64, @bitCast(self.listen_fd)),
           .filter = std.c.EVFILT_READ,
           .flags = std.c.EV_ADD | std.c.EV_CLEAR,
           .fflags = 0,
           .data = 0,
           .udata = null,
       };
       _ = std.posix.kevent(self.kq_fd, &.{change}, 0, null, null);

       // Event loop (replaces epoll_wait)
       var events: [MAX_EVENTS]std.posix.Kevent = undefined;
       var timeout = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 10_000_000 };

       while (true) {
           // Check shutdown (same)
           self.shutdown_lock.lock();
           const is_shutdown = self.shutdown;
           self.shutdown_lock.unlock();
           if (is_shutdown) break;

           const num_events = std.posix.kevent(
               self.kq_fd, null, 0, &events, &timeout
           );
           if (num_events < 0) continue;

           for (0..@as(usize, @intCast(num_events))) |i| {
               const fd = @as(c_int, @intCast(events[i].ident));
               const filter = events[i].filter;

               if (filter == std.c.EVFILT_READ) {
                   if (fd == self.listen_fd) {
                       self.acceptConnections();
                   } else {
                       self.handleClientAsync(fd);
                   }
               }
           }
       }
   }
   ```

6. **Rewrite `acceptConnections()`**:
   Same accept logic, but register client fds with kqueue instead of epoll:
   ```zig
   fn acceptConnections(self: *Self) void {
       var accepted: usize = 0;
       const MAX_ACCEPTS_PER_LOOP = 64;
       
       while (accepted < MAX_ACCEPTS_PER_LOOP) {
           var client_addr: std.posix.sockaddr.in = undefined;
           var addr_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
           
           const client_fd = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
           if (client_fd < 0) break;
           accepted += 1;

           // Register with kqueue (replaces epoll_ctl)
           var change: std.posix.Kevent = .{
               .ident = @as(u64, @bitCast(client_fd)),
               .filter = std.c.EVFILT_READ,
               .flags = std.c.EV_ADD | std.c.EV_CLEAR,
               .fflags = 0,
               .data = 0,
               .udata = null,
           };
           if (std.posix.kevent(self.kq_fd, &.{change}, 0, null, null) < 0) {
               _ = c.close(client_fd);
           }
       }
   }
   ```

7. **Rewrite `handleClientAsync()`**:
   Remove epoll DEL — with kqueue, removing the fd from the kqueue happens automatically when `close(fd)` is called (if EV_CLOSE is set) or we can explicitly remove it. Simplest approach: remove explicit kqueue deletion; the close() in handleRequestThread will handle it.
   ```zig
   fn handleClientAsync(self: *Self, client_fd: c_int) void {
       self.thread_pool.spawn(handleRequestThread, .{ self, client_fd }) catch |err| {
           std.log.err("Thread spawn failed: {}", .{err});
           _ = c.close(client_fd);
       };
   }
   ```

8. **Verify the `handleRequestThread()` function** — it uses only `c.read()`, `c.write()`, `c.close()`, which are POSIX and work identically on macOS. No changes needed.

9. **Replace `runSyncPosix()`** to use POSIX `poll()` as fallback (if not already implemented):
   ```zig
   fn runSyncPosix(self: *Self) !void {
       // Use POSIX poll() for maximum portability
       // This is a fallback for --sync mode
       ...
   }
   ```

10. **Update `ServerMode` enum** to be OS-neutral:
    ```zig
    pub const ServerMode = enum {
        async_default,
        sync_posix,
    };
    ```

11. **Add import for kqueue types**:
    ```zig
    const std = @import("std");
    const c = std.c;
    const posix = std.posix;
    ```

### Task 2: Update `build.zig` for platform detection

**Complexity**: Low

**Changes to `build.zig`**:

1. **Detect target OS** at the top of the `build()` function:
   ```zig
   const target = b.standardTargetOptions(.{});
   const os_tag = target.result.os.tag;
   const is_linux = os_tag == .linux;
   const is_macos = os_tag == .macos;
   ```

2. **Update the `server` module import** to use the right source file:
   ```zig
   const server_source = if (is_macos)
       b.path("src/server/http_kqueue.zig")
   else
       b.path("src/server/http.zig");
   
   const server = b.addModule("server", .{
       .root_source_file = server_source,
   });
   ```

3. **Add a comtime flag for conditional code in main.zig** (optional):
   ```zig
   server.addOption(bool, "is_macos", is_macos);
   server.addOption(bool, "is_linux", is_linux);
   ```

### Task 3: Update `src/main.zig` for macOS server mode

**Complexity**: Low

**Changes**:

1. **Update the `http` import** — it will resolve to the right file based on build.zig:
   ```zig
   // No change needed — build.zig handles which http module to use
   const http = @import("server/http.zig");
   ```

2. **Update server mode defaults** based on platform (if needed):
   ```zig
   var mode = http.ServerMode.async_default;
   // Remove epoll-specific flag names from help text on macOS
   ```

3. **Update CLI argument handling** to accept macOS-specific flags:
   ```zig
   while (args.next()) |arg| {
       if (std.mem.eql(u8, arg, "--sync")) {
           mode = http.ServerMode.sync_posix;
       } else if (std.mem.eql(u8, arg, "--async") or
                  std.mem.eql(u8, arg, "--async-default")) {
           mode = http.ServerMode.async_default;
       }
       // --async-io, --thread-pool: keep as-is for both platforms
   }
   ```

### Task 4: Test on macOS

**Complexity**: Low

**Test plan**:

```bash
# 1. Build the project
zig build

# 2. Run all unit tests (pure Zig, should pass without changes)
zig build test

# 3. Run integration tests
zig build test-e2e
zig build test-security
zig build test-config
zig build test-audit
zig build test-gaps
zig build test-all

# 4. Manual smoke test
./zig-out/bin/agent-gate &
sleep 1

curl -v http://localhost:8080/health
# Expected: HTTP/1.1 200 OK

curl -v -X POST http://localhost:8080/check \
  -H "Content-Type: application/json" \
  -d '{"path":"/api/test","method":"GET"}'
# Expected: HTTP/1.1 200 OK, {"allowed":true}

curl -v -X POST http://localhost:8080/check \
  -H "Content-Type: application/json" \
  -d '{"path":"/admin/secret","method":"GET"}'
# Expected: HTTP/1.1 403 Forbidden (if policy denies)

# 5. Sync mode test
./zig-out/bin/agent-gate --sync &
# Should fall back to poll() and still work

# 6. Benchmark (optional)
zig build benchmark -- --url http://localhost:8080 --requests 10000

# 7. Kill server
kill %1
```

**Expected issues to watch for**:
- kqueue `EV_CLEAR` (edge-triggered) semantics may differ slightly from epoll `EPOLLET` — may need to adjust the read loop to handle partial reads correctly
- File descriptor limits are 256 by default on macOS (vs 1024+ on Linux) — may hit `EMFILE` under load
- `SO_REUSEPORT` has different semantics on macOS — avoid using it
- `getCPUCount()` may return different values — thread pool sizing should adapt automatically

### Task 5: Guard io_uring for macOS

**Complexity**: Low

Add a comptime error at the top of `src/server/http_uring.zig` to prevent accidental compilation on macOS:

```zig
comptime {
    if (@import("builtin").os.tag != .linux) {
        @compileError("io_uring is Linux-only. Use http_kqueue.zig on macOS.");
    }
}
```

---

## 6. Dependency Graph

```
Task 1: Create http_kqueue.zig
     │
     ├── Requires: knowledge of kqueue API
     │             Copy of http.zig as template
     │
     ▼
Task 2: Update build.zig
     │
     ├── Requires: Task 1 file to exist
     ├── Requires: knowing target options API
     │
     ▼
Task 3: Update main.zig
     │
     ├── Requires: Task 2 build system changes
     │
     ▼
Task 4: Test on macOS
     │
     ├── Requires: Tasks 1-3 done
     ├── Requires: macOS machine or CI runner
     │
     ▼
Task 5: Guard io_uring
     │
     ├── No dependencies (can be done at any time)
```

**Execution order**: 1 → 2 → 3 → 4 (5 is independent)

---

## 7. Windows Considerations (Future)

Windows will require a **fundamentally different approach** than macOS. Key differences:

### 7.1 I/O Model
- No epoll, no kqueue → uses **IOCP** (I/O Completion Ports)
- Different socket API: `WSASocket()`, `WSASend()`, `WSARecv()` instead of POSIX socket functions
- Event-driven via `GetQueuedCompletionStatus()` / `PostQueuedCompletionStatus()`
- Zig provides `std.os.windows.*` bindings

### 7.2 Signals
- No POSIX signals (SIGTERM/SIGINT)
- Use **Console Ctrl Handler** (`SetConsoleCtrlHandler`) instead
- `shutdown.zig` must be rewritten

### 7.3 Threading
- `std.Thread.Pool` works on Windows
- Thread pools use Windows `TP_POOL` internally

### 7.4 File System
- Paths use `\` instead of `/`
- File APIs are different (`CreateFileW` instead of `open`)
- `std.fs` abstracts this in Zig — may work if Zig handles the translation

### 7.5 Networking
- `AF.INET` = 2 (same as Linux)
- But setsockopt options differ (some constants have different values)
- `SOCK.NONBLOCK` works differently — Windows uses `ioctlsocket(FIONBIO)`
- `std.posix.sockaddr.in` may have different layout

### 7.6 Effort estimate
- **Windows port**: Significant (3-5× more work than macOS)
- New module: `http_iocp.zig` or use `std.event.Loop`
- New shutdown: `shutdown_windows.zig`
- May need compatibility shims in config and mTLS

---

## 8. Appendix: kqueue API Reference

### 8.1 Key Functions

```c
// Create a kqueue instance
int kq = kqueue();

// Register and/or wait for events
int n = kevent(
    int kq,                    // kqueue fd
    const struct kevent *changelist,  // events to register (can be NULL)
    int nchanges,              // count of changelist
    struct kevent *eventlist,  // received events (can be NULL)
    int nevents,               // max events to receive
    const struct timespec *timeout   // timeout (NULL = block indefinitely)
);
```

### 8.2 struct kevent

```c
struct kevent {
    uintptr_t ident;     // file descriptor (for EVFILT_READ/WRITE)
    int16_t   filter;    // EVFILT_READ, EVFILT_WRITE, etc.
    uint16_t  flags;     // EV_ADD, EV_DELETE, EV_ENABLE, EV_CLEAR, etc.
    uint32_t  fflags;    // filter-specific flags
    intptr_t  data;      // filter-specific data (bytes available, etc.)
    void     *udata;     // user-defined data
};
```

### 8.3 Important Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `EVFILT_READ` | -1 | Monitor for readability |
| `EVFILT_WRITE` | -2 | Monitor for writability |
| `EV_ADD` | 0x0001 | Add event to kqueue |
| `EV_DELETE` | 0x0002 | Remove event from kqueue |
| `EV_ENABLE` | 0x0004 | Enable event |
| `EV_DISABLE` | 0x0008 | Disable event (not remove) |
| `EV_ONESHOT` | 0x0010 | Fire only once |
| `EV_CLEAR` | 0x0020 | Edge-triggered (epoll EPOLLET equivalent) |
| `EV_EOF` | 0x8000 | EOF condition (returned in flags) |
| `EV_ERROR` | 0x4000 | Error condition (returned in flags) |

### 8.4 Usage Pattern

```zig
// === SETUP ===
const kq = std.posix.kqueue();

// Register listen fd for readability (edge-triggered)
var change: std.posix.Kevent = .{
    .ident = @as(u64, @bitCast(listen_fd)),
    .filter = std.c.EVFILT_READ,
    .flags = std.c.EV_ADD | std.c.EV_CLEAR,
    .fflags = 0,
    .data = 0,
    .udata = null,
};
_ = std.posix.kevent(kq, &.{change}, 0, null, null);

// === EVENT LOOP ===
var events: [64]std.posix.Kevent = undefined;
var timeout = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 10_000_000 };

// Wait for events
const n = std.posix.kevent(kq, null, 0, &events, &timeout);

for (0..@as(usize, @intCast(n))) |i| {
    const ev = events[i];
    const fd = @as(c_int, @intCast(ev.ident));
    
    if (ev.flags & std.c.EV_EOF != 0) {
        // Connection closed
        _ = c.close(fd);
        continue;
    }
    
    if (ev.filter == std.c.EVFILT_READ) {
        // Socket readable — how many bytes are available in data field
        const bytes_available = ev.data;
        // Actually, data gives hint; still need to read()
        var buf: [8192]u8 = undefined;
        const nread = c.read(fd, &buf, buf.len);
        // ...
    }
}
```

### 8.5 Edge-Triggered Semantics

- kqueue `EV_CLEAR` is equivalent to epoll `EPOLLET`
- After a `EV_CLEAR` event is delivered, the fd is **disabled** until more data arrives and you call `kevent()` again
- You must read until `EAGAIN`/`EWOULDBLOCK` in edge-triggered mode
- With level-triggered (default, no `EV_CLEAR`), you get continuous notifications until you read

**Recommendation**: Use `EV_CLEAR` (edge-triggered) for server sockets and high-throughput connections, matching the existing epoll behavior. Use level-triggered for simpler cases.

### 8.6 Zig Bindings Availability (0.15.2)

In Zig 0.15.2:

- `std.posix.kqueue()` — function, creates a kqueue, returns fd
- `std.posix.kevent()` — function, register/wait for events
- `std.posix.Kevent` — struct type
- `std.c.EVFILT_READ`, `std.c.EVFILT_WRITE` — filter constants
- `std.c.EV_ADD`, `std.c.EV_DELETE`, `std.c.EV_CLEAR`, `std.c.EV_EOF`, `std.c.EV_ERROR` — flag constants
- `std.posix.timespec` — time struct for timeout

If `std.posix` does not expose these in 0.15.2, fall back to `extern` declarations:

```zig
const system = struct {
    extern "c" fn kqueue() c_int;
    extern "c" fn kevent(
        kq: c_int,
        changelist: ?[*]const std.posix.Kevent,
        nchanges: c_int,
        eventlist: ?[*]std.posix.Kevent,
        nevents: c_int,
        timeout: ?*const std.posix.timespec,
    ) c_int;
};
```

---

## End of Plan
