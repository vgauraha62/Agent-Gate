package upstream

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/agentgate/proxy/anthropic"
	"github.com/agentgate/proxy/policy"
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

// ForwardStreamFiltered sends a streaming request to the upstream and filters
// the SSE response for tool_use content blocks. Each tool_use block is evaluated
// against the policy engine before being forwarded to the client.
//
// Dangerous tool_use blocks (denied by policy) are replaced with text deltas
// explaining the denial. Safe blocks pass through unchanged.
func (c *Client) ForwardStreamFiltered(apiKey string, body []byte, headers http.Header, w io.Writer, policyClient *policy.Client, agentID string) error {
	log.Printf("DEBUG ForwardStreamFiltered body: %s", string(body))

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

	log.Printf("DEBUG LiteLLM response: status=%d content-type=%s", resp.StatusCode, resp.Header.Get("Content-Type"))

	if resp.StatusCode != http.StatusOK {
		// Non-200 response — pass through as-is
		_, err = io.Copy(w, resp.Body)
		return err
	}

	// Wrap the upstream body with a counting reader so we can detect
	// when the upstream returns data that isn't valid SSE (see Bug #3).
	cr := &countingReader{r: resp.Body}
	reader := bufio.NewReader(cr)
	state := anthropic.NewStreamFilterState()

	var eventsForwarded int

	for {
		evt, err := anthropic.ParseSSEEvent(reader)
		if err != nil {
			if err == io.EOF {
				break
			}
			return fmt.Errorf("SSE parse error: %w", err)
		}

		dataPreview := string(evt.Data)
		if len(dataPreview) > 120 {
			dataPreview = dataPreview[:120]
		}
		log.Printf("DEBUG SSE event: event=%s data=%s", evt.Event, dataPreview)

		// Process through the state machine
		forward, pendingPolicy, err := state.ProcessEvent(evt)
		if err != nil {
			log.Printf("SSE process error: %v", err)
			// Forward the original event on error rather than dropping it
			forward = []*anthropic.SSEEvent{evt}
		}

		// Write any events that should be forwarded immediately
		for _, fwd := range forward {
			if _, err := w.Write(anthropic.RenderSSEEvent(fwd)); err != nil {
				return fmt.Errorf("write event: %w", err)
			}
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			eventsForwarded++
		}

		// If a tool block needs policy evaluation, do it now
		if pendingPolicy != nil {
			result := c.evaluateToolPolicy(policyClient, pendingPolicy, agentID)

			replacement := state.ProcessPolicyResult(result)
			for _, rep := range replacement {
				if _, err := w.Write(anthropic.RenderSSEEvent(rep)); err != nil {
					return fmt.Errorf("write policy result: %w", err)
				}
				if flusher, ok := w.(http.Flusher); ok {
					flusher.Flush()
				}
				eventsForwarded++
			}
		}
	}

	// Guard: if the upstream sent data but none of it was valid SSE,
	// return an error so the caller can inform the client (Bug #3).
	if cr.bytesRead > 0 && eventsForwarded == 0 {
		return fmt.Errorf("upstream returned %d bytes of non-SSE data", cr.bytesRead)
	}

	return nil
}

// countingReader wraps an io.Reader and counts the total bytes read.
// Used to detect non-SSE responses from the upstream.
type countingReader struct {
	r         io.Reader
	bytesRead int64
}

func (cr *countingReader) Read(p []byte) (int, error) {
	n, err := cr.r.Read(p)
	cr.bytesRead += int64(n)
	return n, err
}

// evaluateToolPolicy sends a tool invocation to the AgentGate policy engine
// and returns the decision. Results are cached for the lifetime of this method.
func (c *Client) evaluateToolPolicy(policyClient *policy.Client, pending *anthropic.ToolBlockPolicyEvent, agentID string) *anthropic.ToolBlockPolicyEvent {
	result := &anthropic.ToolBlockPolicyEvent{
		Index:    pending.Index,
		ToolName: pending.ToolName,
		Command:  pending.Command,
		Path:     pending.Path,
		Allowed:  false, // default deny if policy check fails
		Reason:   "default deny (no matching policy)",
		PolicyID: "default-deny",
	}

	checkResp, err := policyClient.Check(&policy.CheckRequest{
		AgentID: agentID,
		Tool:    pending.ToolName,
		Command: pending.Command,
		Path:    pending.Path,
	})
	if err != nil {
		log.Printf("POLICY CHECK ERROR (response tool): tool=%s err=%v", pending.ToolName, err)
		result.Reason = fmt.Sprintf("policy engine unreachable: %v", err)
		result.PolicyID = "policy-error"
		return result
	}

	result.Allowed = checkResp.Allowed
	result.Reason = checkResp.Reason
	result.PolicyID = checkResp.PolicyID

	if !checkResp.Allowed {
	} else {
		log.Printf("POLICY ALLOW (response tool): tool=%s command=%s path=%s",
			pending.ToolName, pending.Command, pending.Path)
	}

	return result
}
