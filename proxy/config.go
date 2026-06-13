package main

import (
	"os"
	"time"
)

// Config holds all configuration for the AgentGate proxy.
type Config struct {
	ListenAddr      string
	AgentGateURL    string
	AnthropicAPIURL string
	PolicyTimeout   time.Duration
	UpstreamTimeout time.Duration
	LicenseKey      string
	LicenseServerURL string
}

// LoadConfig reads configuration from environment variables with defaults.
func LoadConfig() *Config {
	return &Config{
		ListenAddr:       getEnv("AGENTGATE_PROXY_LISTEN", ":8080"),
		AgentGateURL:     getEnv("AGENTGATE_PROXY_AGENTGATE_URL", "http://agentgate:8080"),
		AnthropicAPIURL:  getEnv("AGENTGATE_PROXY_ANTHROPIC_URL", "https://api.anthropic.com"),
		PolicyTimeout:    getDuration("AGENTGATE_PROXY_POLICY_TIMEOUT", 5*time.Second),
		UpstreamTimeout:  getDuration("AGENTGATE_PROXY_UPSTREAM_TIMEOUT", 300*time.Second),
		LicenseKey:       getEnv("AGENTGATE_PROXY_LICENSE_KEY", ""),
		LicenseServerURL: getEnv("AGENTGATE_PROXY_LICENSE_URL", "http://license-server:4001"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		d, err := time.ParseDuration(v)
		if err == nil {
			return d
		}
	}
	return fallback
}
