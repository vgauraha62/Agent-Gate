package policy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// CheckRequest is the request body sent to AgentGate's /check endpoint.
type CheckRequest struct {
	AgentID string      `json:"agent_id"`
	Tool    string      `json:"tool"`
	Command string      `json:"command"`
	Path    string      `json:"path"`
	Input   interface{} `json:"input"`
}

// CheckResponse is the response from AgentGate's /check endpoint.
type CheckResponse struct {
	Allowed  bool   `json:"allowed"`
	PolicyID string `json:"policy_id"`
	Reason   string `json:"reason,omitempty"`
}

// Client is an HTTP client for the AgentGate policy engine.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient creates a new AgentGate policy client with the given base URL and timeout.
func NewClient(baseURL string, timeout time.Duration) *Client {
	return &Client{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				MaxIdleConns:        100,
				IdleConnTimeout:     90 * time.Second,
				DisableCompression:  true,
			},
		},
	}
}

// Check sends a tool invocation to AgentGate for policy evaluation.
// Returns the policy decision or an error if the request fails.
func (c *Client) Check(req *CheckRequest) (*CheckResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	resp, err := c.httpClient.Post(
		c.baseURL+"/check",
		"application/json",
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("http call: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	var result CheckResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	// If AgentGate returned a non-200 status but we still got valid JSON,
	// the Allowed field will be false (the AgentGate always sets it in the body).
	return &result, nil
}
