// Package license provides client-side license validation, tier enforcement,
// and offline grace period handling for the AgentGate proxy.
package license

import "fmt"

// Tier represents a subscription tier.
type Tier string

const (
	TierFree       Tier = "free"
	TierStarter    Tier = "starter"
	TierPro        Tier = "pro"
	TierEnterprise Tier = "enterprise"
)

// Features defines the entitlements available to a given tier.
type Features struct {
	Tier              Tier   `json:"tier"`
	MaxRequestsPerDay int    `json:"max_requests_per_day"`
	MaxAgents         int    `json:"max_agents"`
	AuditRetentionDays int   `json:"audit_retention_days"`
	CustomPolicies    bool   `json:"custom_policies"`
	MetricsEndpoint   bool   `json:"metrics_endpoint"`
	SSO               bool   `json:"sso"`
	SupportLevel      string `json:"support_level"`
}

// TierFeatures maps each tier to its feature set.
var TierFeatures = map[Tier]Features{
	TierFree: {
		MaxRequestsPerDay:  100,
		MaxAgents:          1,
		AuditRetentionDays: 0,
		CustomPolicies:     false,
		MetricsEndpoint:    false,
		SSO:                false,
		SupportLevel:       "community",
	},
	TierStarter: {
		MaxRequestsPerDay:  1000,
		MaxAgents:          5,
		AuditRetentionDays: 7,
		CustomPolicies:     true,
		MetricsEndpoint:    true,
		SSO:                false,
		SupportLevel:       "email",
	},
	TierPro: {
		MaxRequestsPerDay:  10000,
		MaxAgents:          20,
		AuditRetentionDays: 90,
		CustomPolicies:     true,
		MetricsEndpoint:    true,
		SSO:                false,
		SupportLevel:       "email",
	},
	TierEnterprise: {
		MaxRequestsPerDay:  -1, // unlimited
		MaxAgents:          -1,
		AuditRetentionDays: 365,
		CustomPolicies:     true,
		MetricsEndpoint:    true,
		SSO:                true,
		SupportLevel:       "phone",
	},
}

// IsUnlimited returns true if the value is -1 (unlimited sentinel).
func IsUnlimited(n int) bool { return n < 0 }

// ValidTiers returns all known subscription tiers.
func ValidTiers() []Tier {
	return []Tier{TierFree, TierStarter, TierPro, TierEnterprise}
}

// Watermark returns a branding header value for free-tier responses.
// Paid tiers return an empty string (no watermark).
func Watermark(tier Tier) string {
	if tier == TierFree {
		return "Powered by AgentGate — agentgate.dev"
	}
	return ""
}

// DenyMessage returns a human-readable message explaining why the proxy is blocked.
func DenyMessage(reason string) string {
	return fmt.Sprintf(`{"type":"error","error":{"type":"license_error","message":"%s"}}`, reason)
}
