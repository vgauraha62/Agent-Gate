package license

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// DefaultLicenseServer is the default URL for the license server.
	DefaultLicenseServer = "http://license-server:4001"
	// RecheckInterval is how often the proxy re-validates with the license server.
	RecheckInterval = 1 * time.Hour
)

// ClientState represents the current license state.
type ClientState int

const (
	StateUninitialized ClientState = iota
	StateValid
	StateGracePeriod // server unreachable, using cached token
	StateExpired
	StateBlocked
)

func (s ClientState) String() string {
	switch s {
	case StateUninitialized:
		return "uninitialized"
	case StateValid:
		return "valid"
	case StateGracePeriod:
		return "grace_period"
	case StateExpired:
		return "expired"
	case StateBlocked:
		return "blocked"
	default:
		return "unknown"
	}
}

// Client manages license validation for the proxy.
// It handles first-time activation, periodic re-validation,
// offline grace periods, and rate-limit enforcement.
type Client struct {
	licenseKey    string
	serverURL     string
	fingerprint   string
	validator     *Validator
	cache         *Cache

	mu            sync.RWMutex
	state         ClientState
	token         string
	claims        *TokenClaims
	features      Features
	lastCheck     time.Time
	requestCount  atomic.Int64
	dailyReset    time.Time

	httpClient    *http.Client
	stopCh        chan struct{}
}

// NewClient creates a license client with the given key and server URL.
// The public key PEM is used to verify JWT signatures.
func NewClient(licenseKey, serverURL string, publicKeyPEM []byte) (*Client, error) {
	validator, err := NewValidator(publicKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("license validator: %w", err)
	}

	return &Client{
		licenseKey:  licenseKey,
		serverURL:   serverURL,
		fingerprint: MachineFingerprint(),
		validator:   validator,
		cache:       NewCache(""),
		state:       StateUninitialized,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		stopCh: make(chan struct{}),
	}, nil
}

// Activate performs the initial license activation.
// It tries the license server first, then falls back to a cached token
// (if within the grace period).
func (c *Client) Activate() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("License: activating with key %s...", maskKey(c.licenseKey))
	log.Printf("License: machine fingerprint %s", c.fingerprint)

	// Try server first
	token, err := c.serverActivate()
	if err == nil {
		return c.processToken(token)
	}

	log.Printf("License: server unreachable (%v), checking cache...", err)

	// Fall back to cache
	cached, err := c.cache.Load()
	if err != nil {
		return fmt.Errorf("license server unreachable and no cache: %w", err)
	}
	if cached == nil {
		return fmt.Errorf("license server unreachable and no cached license: %w", err)
	}

	if !IsWithinGracePeriod(cached.CachedAt) {
		return fmt.Errorf("license grace period expired (%v ago), cannot start", GracePeriod)
	}

	log.Printf("License: using cached token (%.0fh old, within grace period)",
		time.Since(cached.CachedAt).Hours())

	claims, err := c.validator.ValidateToken(cached.Token, c.fingerprint)
	if err != nil {
		return fmt.Errorf("cached token invalid: %w", err)
	}

	c.token = cached.Token
	c.claims = claims
	c.features = FeaturesFromClaims(claims)
	c.state = StateGracePeriod
	c.lastCheck = time.Now()
	return nil
}

// serverActivate calls the license server to activate this machine.
func (c *Client) serverActivate() (string, error) {
	body := map[string]string{
		"key":         c.licenseKey,
		"fingerprint": c.fingerprint,
	}
	payload, _ := json.Marshal(body)

	resp, err := c.httpClient.Post(c.serverURL+"/api/v1/license/activate",
		"application/json", bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("server request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var errResp struct {
			Error string `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&errResp)
		if errResp.Error != "" {
			return "", fmt.Errorf("server: %s", errResp.Error)
		}
		return "", fmt.Errorf("server returned HTTP %d", resp.StatusCode)
	}

	var result struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}
	return result.Token, nil
}

// processToken validates and stores a license token.
func (c *Client) processToken(token string) error {
	claims, err := c.validator.ValidateToken(token, c.fingerprint)
	if err != nil {
		return fmt.Errorf("invalid license token: %w", err)
	}

	c.token = token
	c.claims = claims
	c.features = FeaturesFromClaims(claims)
	c.state = StateValid
	c.lastCheck = time.Now()

	// Cache for offline grace
	cacheData := &CacheData{
		Token:       token,
		Fingerprint: c.fingerprint,
		CachedAt:    time.Now(),
		ExpiresAt:   claims.ExpiresAt.Time,
	}
	if err := c.cache.Save(cacheData); err != nil {
		log.Printf("License: warning - failed to cache token: %v", err)
	}

	log.Printf("License: activated (tier=%s, expires=%s, max_req/day=%d)",
		claims.Tier, claims.ExpiresAt.Time.Format(time.RFC3339), claims.MaxRequestsPerDay)
	return nil
}

// StartBackgroundRefresh begins the periodic re-validation loop.
// Call this after Activate() succeeds.
func (c *Client) StartBackgroundRefresh() {
	go func() {
		ticker := time.NewTicker(RecheckInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				c.refresh()
			case <-c.stopCh:
				return
			}
		}
	}()
}

// refresh performs a single re-validation with the license server.
func (c *Client) refresh() {
	c.mu.Lock()
	defer c.mu.Unlock()

	body := map[string]string{
		"key":         c.licenseKey,
		"token":       c.token,
		"fingerprint": c.fingerprint,
	}
	payload, _ := json.Marshal(body)

	resp, err := c.httpClient.Post(c.serverURL+"/api/v1/license/validate",
		"application/json", bytes.NewReader(payload))

	if err != nil {
		// Server unreachable — check grace period
		log.Printf("License: re-validation failed (%v), entering grace period", err)
		if !IsWithinGracePeriod(c.lastCheck) {
			log.Printf("License: grace period expired")
			c.state = StateExpired
		}
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("License: server rejected token (HTTP %d)", resp.StatusCode)
		c.state = StateExpired
		c.cache.Delete()
		return
	}

	var result struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		log.Printf("License: bad response: %v", err)
		return
	}

	// Validate and update
	claims, err := c.validator.ValidateToken(result.Token, c.fingerprint)
	if err != nil {
		log.Printf("License: refreshed token invalid: %v", err)
		c.state = StateExpired
		return
	}

	c.token = result.Token
	c.claims = claims
	c.features = FeaturesFromClaims(claims)
	c.state = StateValid
	c.lastCheck = time.Now()
	log.Printf("License: re-validated (tier=%s)", claims.Tier)
}

// CanServeRequest returns true if the proxy should handle this request.
// It checks for expired state, which includes grace-period expiry.
func (c *Client) CanServeRequest() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.state == StateValid || c.state == StateGracePeriod
}

// IsRateLimited returns true if the daily request limit is exceeded.
// Only enforced for limited tiers (free/starter/pro with cap).
func (c *Client) IsRateLimited() bool {
	if IsUnlimited(c.features.MaxRequestsPerDay) {
		return false
	}

	// Reset counter daily
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	c.mu.Lock()
	if !today.Equal(c.dailyReset) {
		c.requestCount.Store(0)
		c.dailyReset = today
	}
	c.mu.Unlock()

	count := c.requestCount.Load()
	return count >= int64(c.features.MaxRequestsPerDay)
}

// IncrementRequestCount records one request for rate limiting.
func (c *Client) IncrementRequestCount() {
	c.requestCount.Add(1)
}

// Features returns the current feature set for this license.
func (c *Client) Features() Features {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.features
}

// State returns the current license state.
func (c *Client) State() ClientState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.state
}

// Stop shuts down the background refresh loop.
func (c *Client) Stop() {
	close(c.stopCh)
}

// NewSkippedClient creates a license client that bypasses all license checks.
// Used for development/testing when AGENTGATE_PROXY_SKIP_LICENSE=true.
func NewSkippedClient() *Client {
	log.Println("License: SKIPPED (development mode — all requests allowed)")
	return &Client{
		fingerprint: MachineFingerprint(),
		state:       StateValid,
		features: Features{
			Tier:              TierEnterprise,
			MaxRequestsPerDay: -1, // unlimited
			MaxAgents:         -1,
			AuditRetentionDays: 365,
			CustomPolicies:    true,
			MetricsEndpoint:   true,
			SSO:               true,
			SupportLevel:      "development",
		},
		httpClient: &http.Client{Timeout: 10 * time.Second},
		stopCh:     make(chan struct{}),
	}
}

// maskKey hides all but the last 4 characters of a license key for logging.
func maskKey(key string) string {
	if len(key) <= 4 {
		return "****"
	}
	return "****-" + key[len(key)-4:]
}
