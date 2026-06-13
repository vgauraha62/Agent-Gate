package internal

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const keyAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no I,O,0,1 to avoid confusion

// LicensePrefixes maps tiers to their key prefix.
var LicensePrefixes = map[string]string{
	"free":       "TRIAL",
	"starter":    "STARTER",
	"pro":        "PRO",
	"enterprise": "ENT",
}

// GenerateLicenseKey creates a human-readable license key with format:
// PREFIX-XXXX-XXXX-XXXX  (e.g., PRO-A3B2-C7F1-D9E4)
func GenerateLicenseKey(tier string) string {
	prefix, ok := LicensePrefixes[tier]
	if !ok {
		prefix = "PROD"
	}
	parts := make([]string, 3)
	for i := 0; i < 3; i++ {
		parts[i] = randomString(4)
	}
	key := fmt.Sprintf("%s-%s-%s-%s", prefix, parts[0], parts[1], parts[2])

	// Append checksum character
	checksum := keyChecksum(key)
	return key + "-" + checksum
}

// keyChecksum computes a single-character checksum to detect typos.
func keyChecksum(key string) string {
	h := sha256.Sum256([]byte(key))
	idx := int(h[0]) % len(keyAlphabet)
	return string(keyAlphabet[idx])
}

// ValidateLicenseKeyFormat checks the key format and checksum.
func ValidateLicenseKeyFormat(key string) bool {
	if len(key) != 23 { // PREFIX-XXXX-XXXX-XXXX-X (4+1+4+1+4+1+4+1+1+1 = 23)
		return false
	}
	if key[4] != '-' || key[9] != '-' || key[14] != '-' || key[19] != '-' {
		return false
	}
	checksum := string(key[20])
	body := key[:20]
	return keyChecksum(body) == checksum
}

// TokenClaims represents claims embedded in the signed JWT.
type TokenClaims struct {
	jwt.RegisteredClaims
	Tier               string `json:"tier"`
	MachineFingerprint string `json:"machine_fingerprint,omitempty"`
	MaxRequestsPerDay  int    `json:"max_requests_per_day"`
	MaxAgents          int    `json:"max_agents"`
}

// Signer creates signed JWT tokens using RSA.
type Signer struct {
	privateKey *rsa.PrivateKey
}

// NewSigner loads an RSA private key from PEM bytes.
func NewSigner(pemBytes []byte) (*Signer, error) {
	key, err := jwt.ParseRSAPrivateKeyFromPEM(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}
	return &Signer{privateKey: key}, nil
}

// GenerateToken creates a signed JWT for the given license.
func (s *Signer) GenerateToken(lic *License, fingerprint string, duration time.Duration) (string, error) {
	now := time.Now()
	claims := TokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "agentgate",
			Subject:   lic.Key,
			ID:       fmt.Sprintf("%x", now.UnixNano()),
			IssuedAt: jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(duration)),
		},
		Tier:               lic.Tier,
		MachineFingerprint: fingerprint,
		MaxRequestsPerDay:  lic.MaxRequests,
		MaxAgents:          lic.MaxAgents,
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	return token.SignedString(s.privateKey)
}

// randomString generates a cryptographically random string of the given length.
func randomString(length int) string {
	result := make([]byte, length)
	for i := range result {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(keyAlphabet))))
		if err != nil {
			// Fall back to time-based randomness if crypto fails
			panic(fmt.Sprintf("crypto/rand failed: %v", err))
		}
		result[i] = keyAlphabet[n.Int64()]
	}
	return string(result)
}

// HexHash returns a hex-encoded SHA-256 hash for general use.
func HexHash(data string) string {
	h := sha256.Sum256([]byte(data))
	return hex.EncodeToString(h[:])
}
