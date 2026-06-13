package upstream

import (
	"bytes"
	"io"
	"net/http"
	"time"
)

// Client forwards requests to the upstream Anthropic API.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient creates a new upstream client with the given base URL and timeout.
func NewClient(baseURL string, timeout time.Duration) *Client {
	return &Client{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				MaxIdleConns:        50,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}
}

// ForwardRequest sends a non-streaming request to the upstream Anthropic API
// and returns the full response. The caller is responsible for closing resp.Body.
func (c *Client) ForwardRequest(apiKey string, body []byte, headers http.Header) (*http.Response, error) {
	req, err := http.NewRequest("POST", c.baseURL+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", apiKey)
	req.Header.Set("anthropic-version", headers.Get("anthropic-version"))

	return c.httpClient.Do(req)
}

// ForwardStream sends a streaming request to the upstream Anthropic API and
// copies SSE events directly to the provided writer. It handles flushing
// after each write for real-time streaming to the client.
func (c *Client) ForwardStream(apiKey string, body []byte, headers http.Header, w io.Writer) error {
	req, err := http.NewRequest("POST", c.baseURL+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", apiKey)
	req.Header.Set("anthropic-version", headers.Get("anthropic-version"))
	req.Header.Set("Accept", "text/event-stream")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	_, err = io.Copy(w, resp.Body)
	return err
}
