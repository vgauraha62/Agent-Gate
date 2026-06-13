package license

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	// DefaultCacheDir is where the license token is cached on disk.
	DefaultCacheDir = "/var/lib/agentgate"
	// CacheFileName is the name of the cached token file.
	CacheFileName = "license.cache"
	// GracePeriod is how long the proxy continues working without
	// being able to reach the license server (24 hours).
	GracePeriod = 24 * time.Hour
)

// Cache persists the license token to disk so the proxy can survive
// temporary license server outages (within the grace period).
type Cache struct {
	dir string
}

// NewCache creates a disk cache in the given directory.
func NewCache(dir string) *Cache {
	if dir == "" {
		dir = DefaultCacheDir
	}
	return &Cache{dir: dir}
}

// path returns the full path to the cache file.
func (c *Cache) path() string {
	return filepath.Join(c.dir, CacheFileName)
}

// Save persists the cache data to disk.
func (c *Cache) Save(data *CacheData) error {
	if err := os.MkdirAll(c.dir, 0755); err != nil {
		return fmt.Errorf("create cache dir: %w", err)
	}
	payload, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("marshal cache: %w", err)
	}
	if err := os.WriteFile(c.path(), payload, 0600); err != nil {
		return fmt.Errorf("write cache: %w", err)
	}
	return nil
}

// Load reads the cache data from disk.
func (c *Cache) Load() (*CacheData, error) {
	payload, err := os.ReadFile(c.path())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // no cache yet
		}
		return nil, fmt.Errorf("read cache: %w", err)
	}
	var data CacheData
	if err := json.Unmarshal(payload, &data); err != nil {
		return nil, fmt.Errorf("parse cache: %w", err)
	}
	return &data, nil
}

// IsWithinGracePeriod returns true if the cached token is still
// within the 24-hour grace window.
func IsWithinGracePeriod(cachedAt time.Time) bool {
	return time.Since(cachedAt) < GracePeriod
}

// Delete removes the cache file (e.g., on license revocation).
func (c *Cache) Delete() error {
	if err := os.Remove(c.path()); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
