package internal

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "modernc.org/sqlite"
)

// DB wraps the SQLite database connection and provides CRUD operations
// for licenses, activations, and usage tracking.
type DB struct {
	conn *sql.DB
}

// License represents a license record in the database.
type License struct {
	ID            string    `json:"id"`
	Key           string    `json:"key"`
	Tier          string    `json:"tier"`
	Status        string    `json:"status"`
	MaxRequests   int       `json:"max_requests"`
	MaxAgents     int       `json:"max_agents"`
	TrialDays     *int      `json:"trial_days,omitempty"`
	ExpiresAt     *string   `json:"expires_at,omitempty"`
	CustomerName  string    `json:"customer_name"`
	CustomerEmail string    `json:"customer_email"`
	CreatedAt     string    `json:"created_at"`
	UpdatedAt     string    `json:"updated_at"`
}

// Activation represents a machine activation record.
type Activation struct {
	ID                string `json:"id"`
	LicenseID         string `json:"license_id"`
	MachineFingerprint string `json:"machine_fingerprint"`
	ContainerID       string `json:"container_id"`
	IPAddress         string `json:"ip_address"`
	ActivatedAt       string `json:"activated_at"`
	LastSeenAt        string `json:"last_seen_at"`
}

// OpenDB opens or creates the SQLite database and runs migrations.
func OpenDB(path string) (*DB, error) {
	if err := os.MkdirAll(dirname(path), 0755); err != nil {
		return nil, fmt.Errorf("create db dir: %w", err)
	}

	conn, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	conn.SetMaxOpenConns(1) // SQLite doesn't support concurrent writers

	// Run schema
	schema, err := os.ReadFile("schema.sql")
	if err != nil {
		return nil, fmt.Errorf("read schema: %w", err)
	}
	if _, err := conn.Exec(string(schema)); err != nil {
		return nil, fmt.Errorf("exec schema: %w", err)
	}

	return &DB{conn: conn}, nil
}

// Close closes the database connection.
func (db *DB) Close() error {
	return db.conn.Close()
}

// ── License CRUD ────────────────────────────────────────────────────────────

// GetLicenseByKey retrieves a license by its human-readable key.
func (db *DB) GetLicenseByKey(key string) (*License, error) {
	row := db.conn.QueryRow(`
		SELECT id, key, tier, status, max_requests, max_agents, trial_days, expires_at,
		       customer_name, customer_email, created_at, updated_at
		FROM licenses WHERE key = ?`, key)

	lic := &License{}
	var trialDays sql.NullInt64
	var expiresAt sql.NullString
	err := row.Scan(
		&lic.ID, &lic.Key, &lic.Tier, &lic.Status, &lic.MaxRequests, &lic.MaxAgents,
		&trialDays, &expiresAt, &lic.CustomerName, &lic.CustomerEmail,
		&lic.CreatedAt, &lic.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	if trialDays.Valid {
		v := int(trialDays.Int64)
		lic.TrialDays = &v
	}
	if expiresAt.Valid {
		lic.ExpiresAt = &expiresAt.String
	}
	return lic, nil
}

// InsertLicense creates a new license record.
func (db *DB) InsertLicense(lic *License) error {
	_, err := db.conn.Exec(`
		INSERT INTO licenses (id, key, tier, status, max_requests, max_agents, trial_days, expires_at,
		                      customer_name, customer_email)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		lic.ID, lic.Key, lic.Tier, lic.Status, lic.MaxRequests, lic.MaxAgents,
		lic.TrialDays, lic.ExpiresAt, lic.CustomerName, lic.CustomerEmail)
	return err
}

// ListLicenses returns all license records.
func (db *DB) ListLicenses() ([]License, error) {
	rows, err := db.conn.Query(`
		SELECT id, key, tier, status, max_requests, max_agents, trial_days, expires_at,
		       customer_name, customer_email, created_at, updated_at
		FROM licenses ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var licenses []License
	for rows.Next() {
		var l License
		var trialDays sql.NullInt64
		var expiresAt sql.NullString
		if err := rows.Scan(
			&l.ID, &l.Key, &l.Tier, &l.Status, &l.MaxRequests, &l.MaxAgents,
			&trialDays, &expiresAt, &l.CustomerName, &l.CustomerEmail,
			&l.CreatedAt, &l.UpdatedAt,
		); err != nil {
			return nil, err
		}
		if trialDays.Valid {
			v := int(trialDays.Int64)
			l.TrialDays = &v
		}
		if expiresAt.Valid {
			l.ExpiresAt = &expiresAt.String
		}
		licenses = append(licenses, l)
	}
	return licenses, nil
}

// RevokeLicense sets a license status to "revoked".
func (db *DB) RevokeLicense(key string) error {
	_, err := db.conn.Exec(`UPDATE licenses SET status = 'revoked', updated_at = datetime('now') WHERE key = ?`, key)
	return err
}

// ── Activation CRUD ─────────────────────────────────────────────────────────

// GetActivations returns all activations for a given license key.
func (db *DB) GetActivations(licenseID string) ([]Activation, error) {
	rows, err := db.conn.Query(`
		SELECT id, license_id, machine_fingerprint, container_id, ip_address, activated_at, last_seen_at
		FROM activations WHERE license_id = ? ORDER BY activated_at DESC`, licenseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var activations []Activation
	for rows.Next() {
		var a Activation
		if err := rows.Scan(&a.ID, &a.LicenseID, &a.MachineFingerprint, &a.ContainerID,
			&a.IPAddress, &a.ActivatedAt, &a.LastSeenAt); err != nil {
			return nil, err
		}
		activations = append(activations, a)
	}
	return activations, nil
}

// UpsertActivation inserts or updates a machine activation.
func (db *DB) UpsertActivation(licID, fingerprint, containerID, ipAddr string) error {
	_, err := db.conn.Exec(`
		INSERT INTO activations (id, license_id, machine_fingerprint, container_id, ip_address)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(license_id, machine_fingerprint) DO UPDATE SET
			last_seen_at = datetime('now'),
			container_id = excluded.container_id,
			ip_address = excluded.ip_address`,
		newID(), licID, fingerprint, containerID, ipAddr)
	return err
}

// ── Usage Logging ───────────────────────────────────────────────────────────

// RecordUsage increments the request count for a license on the current date.
func (db *DB) RecordUsage(licenseID string) error {
	today := time.Now().Format("2006-01-02")
	_, err := db.conn.Exec(`
		INSERT INTO usage_log (license_id, date, request_count)
		VALUES (?, ?, 1)
		ON CONFLICT(license_id, date) DO UPDATE SET
			request_count = request_count + 1`, licenseID, today)
	return err
}

// GetUsage returns the request count for a license on a given date.
func (db *DB) GetUsage(licenseID, date string) (int, error) {
	var count int
	err := db.conn.QueryRow(
		`SELECT request_count FROM usage_log WHERE license_id = ? AND date = ?`, licenseID, date,
	).Scan(&count)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return count, err
}

// ── Helpers ─────────────────────────────────────────────────────────────────

func dirname(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return "."
}

var idCounter int

func newID() string {
	idCounter++
	return fmt.Sprintf("%08x", time.Now().UnixNano()^int64(idCounter))
}
