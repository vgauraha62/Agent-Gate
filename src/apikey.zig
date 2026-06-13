//! API Key Manager for hosted AgentGate.
//!
//! Provides API key generation, persistent storage, validation,
//! and management for the hosted REST API.
//!
//! Keys use format: `ag_` + 32-byte random (base62 encoded = 43 chars)
//! Stored in a JSON file with metadata.

const std = @import("std");
const crypto = std.crypto;

// ============================================================================
// Constants
// ============================================================================

/// Prefix for all generated API keys for easy identification.
pub const KEY_PREFIX: []const u8 = "ag_";
/// Length of the random portion in bytes (before encoding).
pub const RANDOM_BYTES: usize = 32;
/// Total key length: prefix (3) + base62 encoded random (43) = 46 chars
pub const KEY_TOTAL_LENGTH: usize = KEY_PREFIX.len + 43;
/// Default max keys per admin
pub const MAX_KEYS_PER_ADMIN: usize = 1000;
/// Default rate limit (requests per second) per key
pub const DEFAULT_RATE_LIMIT: u32 = 100;
/// Storage file name (written alongside config)
pub const STORAGE_FILE: []const u8 = "api_keys.json";

// ============================================================================
// Types
// ============================================================================

/// Status of an API key.
pub const KeyStatus = enum {
    active,
    revoked,
    expired,
};

/// Metadata stored alongside each API key.
pub const ApiKeyMetadata = struct {
    /// Human-readable name for this key (e.g., "CI pipeline", "dev-1")
    name: []const u8,
    /// Unix timestamp when created
    created_at: i64,
    /// Unix timestamp when last used (0 = never)
    last_used_at: i64,
    /// Status of the key
    status: KeyStatus,
    /// Optional expiry (0 = no expiry)
    expires_at: i64,
    /// Rate limit (requests per second)
    rate_limit: u32,
    /// Total requests made with this key
    total_requests: u64,
    /// Optional notes
    notes: []const u8,
};

/// A single API key entry (full key is NOT stored — only a hash).
pub const ApiKeyEntry = struct {
    /// SHA256 hash of the full API key (used for lookup)
    hash: [32]u8,
    /// First 8 chars of the key for display/identification
    key_prefix_display: [KEY_PREFIX.len + 8]u8,
    /// Metadata about this key
    metadata: ApiKeyMetadata,

    const Self = @This();

    /// Create a new key entry from a generated key.
    pub fn init(key: []const u8, name: []const u8, rate_limit: u32, expires_at: i64, notes: []const u8, allocator: std.mem.Allocator) !Self {
        var entry = Self{
            .hash = undefined,
            .key_prefix_display = undefined,
            .metadata = .{
                .name = try allocator.dupe(u8, name),
                .created_at = std.time.timestamp(),
                .last_used_at = 0,
                .status = .active,
                .expires_at = expires_at,
                .rate_limit = rate_limit,
                .total_requests = 0,
                .notes = try allocator.dupe(u8, notes),
            },
        };

        // Hash the key for secure storage
        crypto.hash.sha2.Sha256.hash(key, &entry.hash, .{});

        // Store first 8+3 chars for display
        const display_len = @min(key.len, KEY_PREFIX.len + 8);
        @memcpy(entry.key_prefix_display[0..display_len], key[0..display_len]);
        if (display_len < KEY_PREFIX.len + 8) {
            @memset(entry.key_prefix_display[display_len..], ' ');
        }

        return entry;
    }

    /// Check if this key matches a given raw key (constant-time compare on hash).
    pub fn matchesKey(self: *const Self, key: []const u8) bool {
        var key_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(key, &key_hash, .{});
        return secureCompare(&key_hash, &self.hash);
    }

    /// Constant-time byte comparison.
    fn secureCompare(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var result: u8 = 0;
        for (a, 0..) |byte, i| {
            result |= byte ^ b[i];
        }
        return result == 0;
    }

    /// Check if key is active and not expired.
    pub fn isValid(self: *const Self) bool {
        if (self.metadata.status != .active) return false;
        if (self.metadata.expires_at > 0 and self.metadata.expires_at < std.time.timestamp()) {
            return false;
        }
        return true;
    }

    /// Deinit owned strings.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.metadata.name);
        allocator.free(self.metadata.notes);
    }
};

/// Container for all API keys with persistence.
pub const ApiKeyStore = struct {
    /// All stored keys (indexed by hash for fast lookup)
    entries: std.ArrayList(ApiKeyEntry),
    /// Path to storage file
    storage_path: []const u8,
    /// Allocator for everything
    allocator: std.mem.Allocator,
    /// RW lock for concurrent access
    mutex: std.Thread.Mutex,

    const Self = @This();

    /// Initialize the key store, loading from file if it exists.
    pub fn init(allocator: std.mem.Allocator, storage_dir: []const u8) !Self {
        const path = try std.fs.path.join(allocator, &.{ storage_dir, STORAGE_FILE });
        var store = Self{
            .entries = std.ArrayList(ApiKeyEntry){},
            .storage_path = path,
            .allocator = allocator,
            .mutex = .{},
        };

        // Try to load existing keys
        _ = store.loadFromFile() catch {};
        return store;
    }

    pub fn deinit(self: *Self) void {
        // Save before shutting down
        self.saveToFile() catch {};
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.storage_path);
    }

    /// Generate a new API key and store it.
    /// Returns the full key string (caller must save it — it won't be shown again!).
    pub fn createKey(self: *Self, name: []const u8, rate_limit: u32, expires_at: i64, notes: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.items.len >= MAX_KEYS_PER_ADMIN) {
            return error.MaxApiKeysReached;
        }

        // Generate random bytes
        var random_bytes: [RANDOM_BYTES]u8 = undefined;
        crypto.random.bytes(&random_bytes);

        // Encode to base62 for URL-safe key
        const encoded = try base62Encode(&random_bytes, self.allocator);
        defer self.allocator.free(encoded);

        // Build full key: ag_<encoded>
        const full_key = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ KEY_PREFIX, encoded });

        // Create entry (stores only hash)
        const entry = try ApiKeyEntry.init(full_key, name, rate_limit, expires_at, notes, self.allocator);
        try self.entries.append(self.allocator, entry);

        // Persist immediately
        self.saveToFile() catch {};

        return full_key;
    }

    /// Validate an API key and return its entry index if valid.
    pub fn validateKey(self: *Self, key: []const u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items, 0..) |*entry, i| {
            if (entry.matchesKey(key)) {
                if (entry.isValid()) {
                    // Update last used timestamp
                    entry.metadata.last_used_at = std.time.timestamp();
                    entry.metadata.total_requests += 1;
                    self.saveToFile() catch {};
                    return i;
                }
                return null; // Found but invalid
            }
        }
        return null;
    }

    /// Revoke a key by its display prefix.
    pub fn revokeKey(self: *Self, display_prefix: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |*entry| {
            const entry_prefix = entry.key_prefix_display[0..@min(display_prefix.len, entry.key_prefix_display.len)];
            if (std.mem.eql(u8, entry_prefix, display_prefix)) {
                if (entry.metadata.status == .active) {
                    entry.metadata.status = .revoked;
                    try self.saveToFile();
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    /// List all keys (with display prefix, not full key).
    pub fn listKeys(self: *Self, allocator: std.mem.Allocator) ![]KeyListItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayList(KeyListItem){};
        for (self.entries.items) |*entry| {
            try list.append(allocator, KeyListItem{
                .key_prefix = &entry.key_prefix_display,
                .name = entry.metadata.name,
                .status = entry.metadata.status,
                .created_at = entry.metadata.created_at,
                .last_used_at = entry.metadata.last_used_at,
                .total_requests = entry.metadata.total_requests,
                .rate_limit = entry.metadata.rate_limit,
                .expires_at = entry.metadata.expires_at,
                .notes = entry.metadata.notes,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Get usage stats summary.
    pub fn getStats(self: *Self) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = Stats{};
        for (self.entries.items) |*entry| {
            stats.total_keys += 1;
            if (entry.metadata.status == .active) stats.active_keys += 1;
            stats.total_requests += entry.metadata.total_requests;
        }
        return stats;
    }

    // ========================================================================
    // Persistence
    // ========================================================================

    /// JSON-serializable representation for storage.
    const StoredEntry = struct {
        hash_hex: []const u8,
        key_prefix_display: []const u8,
        name: []const u8,
        created_at: i64,
        last_used_at: i64,
        status: []const u8,
        expires_at: i64,
        rate_limit: u32,
        total_requests: u64,
        notes: []const u8,
    };

    fn entryToStored(_: *Self, entry: *const ApiKeyEntry, allocator: std.mem.Allocator) !StoredEntry {
        return StoredEntry{
            .hash_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&entry.hash, .lower)}),
            .key_prefix_display = &entry.key_prefix_display,
            .name = entry.metadata.name,
            .created_at = entry.metadata.created_at,
            .last_used_at = entry.metadata.last_used_at,
            .status = @tagName(entry.metadata.status),
            .expires_at = entry.metadata.expires_at,
            .rate_limit = entry.metadata.rate_limit,
            .total_requests = entry.metadata.total_requests,
            .notes = entry.metadata.notes,
        };
    }

    fn saveToFile(self: *Self) !void {
        // Build JSON string in memory first
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        try buf.writer(self.allocator).writeAll("[\n");
        for (self.entries.items, 0..) |*entry, i| {
            if (i > 0) try buf.writer(self.allocator).writeAll(",\n");

            const s = try self.entryToStored(entry, self.allocator);
            defer self.allocator.free(s.hash_hex);

            try buf.writer(self.allocator).print(
                \\{{"hash_hex":"{s}","key_prefix_display":"{s}","name":"{s}","created_at":{},"last_used_at":{},"status":"{s}","expires_at":{},"rate_limit":{},"total_requests":{},"notes":"{s}"}}
            , .{
                s.hash_hex,
                std.mem.trimRight(u8, s.key_prefix_display, " "),
                s.name,
                s.created_at,
                s.last_used_at,
                s.status,
                s.expires_at,
                s.rate_limit,
                s.total_requests,
                s.notes,
            });
        }
        try buf.writer(self.allocator).writeAll("\n]\n");

        // Write to file
        const file = std.fs.cwd().createFile(self.storage_path, .{}) catch |err| {
            std.debug.print("[ApiKey] Warning: could not save keys: {}\n", .{err});
            return;
        };
        defer file.close();

        try file.writeAll(buf.items);
    }

    fn loadFromFile(self: *Self) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.storage_path, 10 * 1024 * 1024) catch |err| {
            return err;
        };
        defer self.allocator.free(data);

        var parsed = try std.json.parseFromSlice([]StoredEntry, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const stored_entries = parsed.value;
        for (stored_entries) |s| {
            var hash: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash, s.hash_hex) catch continue;

            var display_buf: [KEY_PREFIX.len + 8]u8 = undefined;
            const display_len = @min(s.key_prefix_display.len, KEY_PREFIX.len + 8);
            @memcpy(display_buf[0..display_len], s.key_prefix_display[0..display_len]);
            if (display_len < KEY_PREFIX.len + 8) {
                @memset(display_buf[display_len..], ' ');
            }

            const status: KeyStatus = if (std.mem.eql(u8, s.status, "revoked")) .revoked else if (std.mem.eql(u8, s.status, "expired")) .expired else .active;

            try self.entries.append(self.allocator, ApiKeyEntry{
                .hash = hash,
                .key_prefix_display = display_buf,
                .metadata = .{
                    .name = try self.allocator.dupe(u8, s.name),
                    .created_at = s.created_at,
                    .last_used_at = s.last_used_at,
                    .status = status,
                    .expires_at = s.expires_at,
                    .rate_limit = s.rate_limit,
                    .total_requests = s.total_requests,
                    .notes = try self.allocator.dupe(u8, s.notes),
                },
            });
        }
    }
};

/// Public key info for listing.
pub const KeyListItem = struct {
    key_prefix: []const u8,
    name: []const u8,
    status: KeyStatus,
    created_at: i64,
    last_used_at: i64,
    total_requests: u64,
    rate_limit: u32,
    expires_at: i64,
    notes: []const u8,
};

/// Summary statistics.
pub const Stats = struct {
    total_keys: usize = 0,
    active_keys: usize = 0,
    total_requests: u64 = 0,
};

// ============================================================================
// Base62 Encoding (URL-safe, no padding)
// ============================================================================

const BASE62_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn base62Encode(bytes: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Convert bytes to a big integer, then to base62
    // Simple approach: treat bytes as big-endian number
    var value: u256 = 0;
    for (bytes) |b| {
        value = (value << 8) | b;
    }

    // Estimate output length: ceil(log_62(2^256)) = 43
    var buf: [48]u8 = undefined;
    var pos: usize = buf.len;

    if (value == 0) {
        buf[pos - 1] = '0';
        pos -= 1;
    } else {
        while (value > 0) {
            pos -= 1;
            buf[pos] = BASE62_ALPHABET[@as(usize, @intCast(value % 62))];
            value /= 62;
        }
    }

    return try allocator.dupe(u8, buf[pos..]);
}

// ============================================================================
// Tests
// ============================================================================

test "ApiKey: generate and validate" {
    const allocator = std.testing.allocator;

    // Use a temp dir for storage
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    // Create a key
    const key = try store.createKey("test-key", 100, 0, "testing");
    defer allocator.free(key);

    try std.testing.expect(key.len > KEY_PREFIX.len);
    try std.testing.expect(std.mem.startsWith(u8, key, KEY_PREFIX));

    // Validate it
    const idx = store.validateKey(key);
    try std.testing.expect(idx != null);
}

test "ApiKey: reject unknown key" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    const idx = store.validateKey("ag_invalidkey12345");
    try std.testing.expect(idx == null);
}

test "ApiKey: revoke key" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    const key = try store.createKey("revoke-test", 100, 0, "");
    defer allocator.free(key);

    // Display prefix is ag_ + first 8 chars of encoded
    const display_prefix = key[0 .. KEY_PREFIX.len + 8];
    const revoked = try store.revokeKey(display_prefix);
    try std.testing.expect(revoked);

    // Should no longer validate
    const idx = store.validateKey(key);
    try std.testing.expect(idx == null);
}

test "ApiKey: persist and reload" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create and save
    const key = blk: {
        var store = try ApiKeyStore.init(allocator, tmp_path);
        defer store.deinit();
        const k = try store.createKey("persist-test", 50, 0, "");
        const duped = try allocator.dupe(u8, k);
        allocator.free(k); // Free the original allocation from createKey
        break :blk duped;
    };
    defer allocator.free(key);

    // Reload from file
    var store2 = try ApiKeyStore.init(allocator, tmp_path);
    defer store2.deinit();

    const idx = store2.validateKey(key);
    try std.testing.expect(idx != null);
}

test "ApiKey: key format is correct" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    const key = try store.createKey("format-test", 100, 0, "");
    defer allocator.free(key);

    // Check format: ag_<base62>
    try std.testing.expect(std.mem.startsWith(u8, key, "ag_"));
    try std.testing.expect(key.len == KEY_TOTAL_LENGTH);
    // Check all chars after prefix are alphanumeric (base62)
    for (key[KEY_PREFIX.len..]) |c| {
        const is_alphanumeric = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        try std.testing.expect(is_alphanumeric);
    }
}

test "ApiKey: expired key is invalid" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    // Create key that expired 1 second ago
    const past = std.time.timestamp() - 1;
    const key = try store.createKey("expired-test", 100, past, "");
    defer allocator.free(key);

    // Should be invalid (expired)
    const idx = store.validateKey(key);
    try std.testing.expect(idx == null);
}

test "ApiKey: rate limit tracking" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    const key = try store.createKey("rate-test", 100, 0, "");
    defer allocator.free(key);

    // First validation should update last_used
    const idx1 = store.validateKey(key);
    try std.testing.expect(idx1 != null);
    try std.testing.expect(store.entries.items[idx1.?].metadata.total_requests == 1);

    // Second validation should increment
    const idx2 = store.validateKey(key);
    try std.testing.expect(idx2 != null);
    try std.testing.expect(store.entries.items[idx2.?].metadata.total_requests == 2);
}

test "ApiKey: list keys" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var store = try ApiKeyStore.init(allocator, tmp_path);
    defer store.deinit();

    const key1 = try store.createKey("key1", 100, 0, "first key");
    defer allocator.free(key1);
    const key2 = try store.createKey("key2", 200, 0, "second key");
    defer allocator.free(key2);

    const list = try store.listKeys(allocator);
    defer allocator.free(list);

    try std.testing.expect(list.len == 2);
}
