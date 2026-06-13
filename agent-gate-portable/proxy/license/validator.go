package license

import (
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TokenClaims represents the JWT claims embedded in a license token.
type TokenClaims struct {
	jwt.RegisteredClaims
	Tier              Tier   `json:"tier"`
	MachineFingerprint string `json:"machine_fingerprint"`
	MaxRequestsPerDay int    `json:"max_requests_per_day"`
	MaxAgents         int    `json:"max_agents"`
}

// Validator verifies JWT license tokens using an RSA public key.
type Validator struct {
	publicKey *rsa.PublicKey
}

// NewValidator creates a Validator from a PEM-encoded RSA public key.
func NewValidator(pemBytes []byte) (*Validator, error) {
	key, err := jwt.ParseRSAPublicKeyFromPEM(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("parse public key: %w", err)
	}
	return &Validator{publicKey: key}, nil
}

// ValidateToken parses and verifies the JWT signature, then checks:
//   - Token is not expired
//   - Tier is known
//   - Machine fingerprint matches (if provided)
//
// Returns the parsed claims on success.
func (v *Validator) ValidateToken(tokenStr string, expectedFingerprint string) (*TokenClaims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &TokenClaims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return v.publicKey, nil
	})
	if err != nil {
		return nil, fmt.Errorf("parse token: %w", err)
	}

	claims, ok := token.Claims.(*TokenClaims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("invalid token claims")
	}

	// Verify tier is known
	valid := false
	for _, t := range ValidTiers() {
		if claims.Tier == t {
			valid = true
			break
		}
	}
	if !valid {
		return nil, fmt.Errorf("unknown tier: %s", claims.Tier)
	}

	// Verify machine fingerprint
	if expectedFingerprint != "" && claims.MachineFingerprint != "" {
		if claims.MachineFingerprint != expectedFingerprint {
			return nil, fmt.Errorf("machine fingerprint mismatch: token belongs to a different machine")
		}
	}

	return claims, nil
}

// FeaturesFromClaims converts JWT claims into a Features struct.
// Falls back to TierFeatures for any zero-valued fields.
func FeaturesFromClaims(claims *TokenClaims) Features {
	def := TierFeatures[claims.Tier]

	f := Features{
		Tier:               claims.Tier,
		MaxRequestsPerDay:  def.MaxRequestsPerDay,
		MaxAgents:          def.MaxAgents,
		AuditRetentionDays: def.AuditRetentionDays,
		CustomPolicies:     def.CustomPolicies,
		MetricsEndpoint:    def.MetricsEndpoint,
		SSO:                def.SSO,
		SupportLevel:       def.SupportLevel,
	}

	// Allow the JWT to override defaults (for custom tiers)
	if claims.MaxRequestsPerDay > 0 {
		f.MaxRequestsPerDay = claims.MaxRequestsPerDay
	}
	if claims.MaxAgents > 0 {
		f.MaxAgents = claims.MaxAgents
	}

	return f
}

// CacheData is the serialized format stored on disk for offline grace.
type CacheData struct {
	Token         string    `json:"token"`
	Fingerprint   string    `json:"fingerprint"`
	CachedAt      time.Time `json:"cached_at"`
	ExpiresAt     time.Time `json:"expires_at"`
	Claims        json.RawMessage `json:"claims"`
}

// Checksum returns a SHA-256 checksum for integrity verification.
func (c *CacheData) Checksum() string {
	h := sha256.Sum256([]byte(c.Token + c.Fingerprint + c.CachedAt.String() + c.ExpiresAt.String()))
	return hex.EncodeToString(h[:])
}
