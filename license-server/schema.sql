CREATE TABLE IF NOT EXISTS licenses (
    id              TEXT PRIMARY KEY,                                   -- UUID
    key             TEXT UNIQUE NOT NULL,                               -- human-readable: PROD-XXXX-XXXX
    tier            TEXT NOT NULL CHECK(tier IN ('free','starter','pro','enterprise')),
    status          TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','revoked','expired')),
    max_requests    INTEGER NOT NULL DEFAULT 100,
    max_agents      INTEGER NOT NULL DEFAULT 1,
    trial_days      INTEGER,                                            -- NULL = perpetual (paid), 14 = free trial
    expires_at      TEXT,                                               -- ISO8601 or NULL
    customer_name   TEXT NOT NULL DEFAULT '',
    customer_email  TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS activations (
    id                  TEXT PRIMARY KEY,
    license_id          TEXT NOT NULL REFERENCES licenses(id),
    machine_fingerprint TEXT NOT NULL,
    container_id        TEXT NOT NULL DEFAULT '',
    ip_address          TEXT NOT NULL DEFAULT '',
    activated_at        TEXT NOT NULL DEFAULT (datetime('now')),
    last_seen_at        TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(license_id, machine_fingerprint)
);

CREATE TABLE IF NOT EXISTS usage_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    license_id      TEXT NOT NULL REFERENCES licenses(id),
    date            TEXT NOT NULL,              -- YYYY-MM-DD
    request_count   INTEGER NOT NULL DEFAULT 0,
    UNIQUE(license_id, date)
);

-- Index for fast daily usage lookups
CREATE INDEX IF NOT EXISTS idx_usage_date ON usage_log(date);
CREATE INDEX IF NOT EXISTS idx_activations_fingerprint ON activations(machine_fingerprint);
