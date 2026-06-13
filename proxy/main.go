package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/agentgate/proxy/anthropic"
	"github.com/agentgate/proxy/license"
	"github.com/agentgate/proxy/policy"
	"github.com/agentgate/proxy/upstream"
)

var cfg *Config
var licenseClient *license.Client

func main() {
	cfg = LoadConfig()

	// ── License activation ──────────────────────────────────────────────
	// The proxy will NOT start without a valid license. If the license
	// server is unreachable, a previously cached token (within 24h grace
	// period) will be used. If neither is available, the process exits.
	//
	// Set AGENTGATE_PROXY_SKIP_LICENSE=true to bypass all checks in dev/test.
	var err error
	if os.Getenv("AGENTGATE_PROXY_SKIP_LICENSE") == "true" {
		licenseClient = license.NewSkippedClient()
	} else {
		licenseClient, err = license.NewClient(cfg.LicenseKey, cfg.LicenseServerURL, license.PublicKeyPEM)
		if err != nil {
			log.Fatalf("LICENSE SYSTEM ERROR: %v", err)
		}
		if err := licenseClient.Activate(); err != nil {
			log.Fatalf("LICENSE REQUIRED: %v.\nSet AGENTGATE_PROXY_LICENSE_KEY to a valid license key.", err)
		}
		licenseClient.StartBackgroundRefresh()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/messages", handleMessages)
	mux.HandleFunc("/health", handleHealth)

	server := &http.Server{
		Addr:    cfg.ListenAddr,
		Handler: withLogging(mux),
	}

	// Start server in background
	go func() {
		log.Printf("AgentGate Proxy starting on %s", cfg.ListenAddr)
		log.Printf("  License: %s", licenseClient.State().String())
		feat := licenseClient.Features()
		log.Printf("  Tier: %s (max_req/day=%d, max_agents=%d)",
			licenseClient.State().String(), feat.MaxRequestsPerDay, feat.MaxAgents)
		log.Printf("  AgentGate URL: %s", cfg.AgentGateURL)
		log.Printf("  Anthropic URL: %s", cfg.AnthropicAPIURL)
		log.Printf("  Policy timeout: %s", cfg.PolicyTimeout)
		log.Printf("  Upstream timeout: %s", cfg.UpstreamTimeout)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("Shutting down...")
	licenseClient.Stop()
	server.Close()
}

// withLogging wraps an http.Handler with basic request logging.
func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}

// handleHealth responds to health checks with a simple OK.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// normalizeBodyContent converts string content fields to the array format
// required by the Anthropic Messages API. For example:
//
//	{"role":"user","content":"Hello"} → {"role":"user","content":[{"type":"text","text":"Hello"}]}
//
// Leaves already-correct content and all other fields untouched.
// Returns the original body unchanged if no normalization is needed or
// if the body cannot be parsed.
func normalizeBodyContent(body []byte) []byte {
	var req map[string]interface{}
	if err := json.Unmarshal(body, &req); err != nil {
		return body // not valid JSON, forward as-is
	}

	messages, ok := req["messages"].([]interface{})
	if !ok {
		return body // no messages array, nothing to normalize
	}

	changed := false
	for i, msg := range messages {
		msgMap, ok := msg.(map[string]interface{})
		if !ok {
			continue
		}
		content, ok := msgMap["content"]
		if !ok {
			continue
		}
		contentStr, ok := content.(string)
		if !ok {
			continue // already an array or other type, leave as-is
		}
		msgMap["content"] = []interface{}{
			map[string]interface{}{
				"type": "text",
				"text": contentStr,
			},
		}
		messages[i] = msgMap
		changed = true
	}

	if !changed {
		return body // avoid unnecessary marshal
	}
	req["messages"] = messages
	normalized, err := json.Marshal(req)
	if err != nil {
		return body // fall back to original on marshal error
	}
	return normalized
}

// handleMessages is the main Anthropic API proxy handler.
// It intercepts /v1/messages requests, extracts tool calls, checks them
// against AgentGate policies, and forwards allowed requests upstream.
func handleMessages(w http.ResponseWriter, r *http.Request) {
	// ── License check ───────────────────────────────────────────────────
	if !licenseClient.CanServeRequest() {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusPaymentRequired)
		w.Write([]byte(license.DenyMessage("license expired or invalid. Please renew your subscription.")))
		return
	}
	if licenseClient.IsRateLimited() {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusTooManyRequests)
		w.Write([]byte(license.DenyMessage("daily request limit exceeded. Upgrade your plan.")))
		return
	}
	licenseClient.IncrementRequestCount()

	// ── Free tier branding watermark ───────────────────────────────────
	if wm := license.Watermark(licenseClient.Features().Tier); wm != "" {
		w.Header().Set("X-Powered-By", wm)
	}

	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// 1. Read and parse incoming request body
	body, err := io.ReadAll(r.Body)
	if err != nil || len(body) == 0 {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}

	var msgReq anthropic.MessagesRequest
	if err := json.Unmarshal(body, &msgReq); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	// 2. Extract API key from incoming request (per-agent key passthrough)
	apiKey := r.Header.Get("x-api-key")
	if apiKey == "" {
		http.Error(w, `{"type":"error","error":{"type":"authentication_error","message":"missing x-api-key header"}}`, http.StatusUnauthorized)
		return
	}

	// 3. Extract tool calls from the request
	agentID := r.Header.Get("X-Agent-ID") // optional agent/session identification
	tools := anthropic.ExtractToolInvocations(&msgReq, agentID)

	// 4. Check each tool invocation against AgentGate policy (request-side)
	policyClient := policy.NewClient(cfg.AgentGateURL, cfg.PolicyTimeout)

	if len(tools) > 0 {
		for _, tool := range tools {
			result, err := policyClient.Check(&policy.CheckRequest{
				AgentID: agentID,
				Tool:    tool.Tool,
				Command: tool.Command,
				Path:    tool.Path,
				Input:   tool.Input,
			})

			// If policy check failed or returned denied, block the request
			if err != nil || result == nil || !result.Allowed {
				reason := "policy denied"
				policyID := "unknown"
				if result != nil {
					if result.Reason != "" {
						reason = result.Reason
					}
					if result.PolicyID != "" {
						policyID = result.PolicyID
					}
				}
				log.Printf("POLICY DENY: tool=%s policy=%s reason=%s (agent=%s)", tool.Tool, policyID, reason, agentID)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				w.Write(policy.DenyErrorResponse(tool.Tool, policyID, reason))
				return
			}
		}
		log.Printf("POLICY ALLOW: %d tools checked (agent=%s)", len(tools), agentID)
	}

	// 5. Normalize body content for upstream Anthropic API.
	//    Converts "content": "string" to "content": [{"type":"text","text":"string"}]
	//    so the upstream API doesn't reject string-format content.
	normalizedBody := normalizeBodyContent(body)
	if len(normalizedBody) != len(body) {
		log.Printf("Normalized content format for upstream request (agent=%s)", agentID)
		log.Printf("DEBUG normalized body: %s", string(normalizedBody))
	} else {
		log.Printf("DEBUG body (no normalization): %s", string(body))
	}

	// 6. Forward to upstream (streaming or non-streaming)
	upstreamClient := upstream.NewClient(cfg.AnthropicAPIURL, cfg.UpstreamTimeout)

	if msgReq.Stream {
		// SSE streaming mode — with response-side tool filtering
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")

		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}

		if err := upstreamClient.ForwardStreamFiltered(apiKey, normalizedBody, r.Header, &flushWriter{w: w, flusher: flusher}, policyClient, agentID); err != nil {
			log.Printf("Stream error: %v", err)
			// Write an error event so the client doesn't hang waiting for data.
			// Headers (Content-Type: text/event-stream) were already written above,
			// so we must speak SSE even on failure.
			errorData, _ := json.Marshal(map[string]interface{}{
				"type": "error",
				"error": map[string]string{
					"message": "upstream stream failed",
				},
			})
			fmt.Fprintf(w, "event: error\ndata: %s\n\n", errorData)
			flusher.Flush()
		}
	} else {
		// Non-streaming mode — with response-side tool filtering
		upstreamResp, err := upstreamClient.ForwardRequest(apiKey, normalizedBody, r.Header)
		if err != nil {
			log.Printf("Upstream error: %v", err)
			http.Error(w, "upstream request failed", http.StatusBadGateway)
			return
		}
		defer upstreamResp.Body.Close()

		// Read the full response body
		respBody, err := io.ReadAll(upstreamResp.Body)
		if err != nil {
			log.Printf("Failed to read upstream response: %v", err)
			http.Error(w, "failed to read upstream response", http.StatusBadGateway)
			return
		}

		// Check for dangerous tool_use blocks in the response
		filteredBody := filterNonStreamingResponse(respBody, policyClient, agentID)

		// Copy upstream response headers
		for k, vv := range upstreamResp.Header {
			for _, v := range vv {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(upstreamResp.StatusCode)
		w.Write(filteredBody)
	}
}

// flushWriter wraps http.ResponseWriter to flush after every write for SSE.
type flushWriter struct {
	w       http.ResponseWriter
	flusher http.Flusher
}

func (fw *flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	if err == nil {
		fw.flusher.Flush()
	}
	return n, err
}

// filterNonStreamingResponse parses a non-streaming Anthropic API response,
// checks each tool_use content block against the policy engine, and removes
// any denied tool blocks from the response. Returns the (possibly modified)
// response body.
func filterNonStreamingResponse(body []byte, policyClient *policy.Client, agentID string) []byte {
	var resp anthropic.MessagesResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		// Not a valid response — pass through as-is
		return body
	}

	// Only filter responses that have content blocks
	if len(resp.Content) == 0 {
		return body
	}

	changed := false
	var filtered []anthropic.ContentBlock

	for _, block := range resp.Content {
		if block.Type != "tool_use" {
			// Text blocks pass through unchanged
			filtered = append(filtered, block)
			continue
		}

		// Extract tool invocation and check policy
		toolInv := anthropic.ExtractToolInvocationFromInput(block.Name, block.Input)
		result, err := policyClient.Check(&policy.CheckRequest{
			AgentID: agentID,
			Tool:    toolInv.Tool,
			Command: toolInv.Command,
			Path:    toolInv.Path,
			Input:   toolInv.Input,
		})

		if err != nil || result == nil || !result.Allowed {
			// Tool denied — replace with explanatory text block
			reason := "policy denied"
			policyID := "default-deny"
			if result != nil {
				if result.Reason != "" {
					reason = result.Reason
				}
				if result.PolicyID != "" {
					policyID = result.PolicyID
				}
			}
			log.Printf("POLICY DENY (response): tool=%s command=%s path=%s policy=%s reason=%s",
				block.Name, toolInv.Command, toolInv.Path, policyID, reason)

			filtered = append(filtered, anthropic.ContentBlock{
				Type: "text",
				Text: fmt.Sprintf(
					"[AgentGate Policy Denied] Tool '%s' was blocked by policy '%s': %s",
					block.Name, policyID, reason,
				),
			})
			changed = true
		} else {
			// Tool allowed — pass through unchanged
			filtered = append(filtered, block)
		}
	}

	if !changed {
		return body
	}

	resp.Content = filtered
	modifiedBody, err := json.Marshal(resp)
	if err != nil {
		log.Printf("Failed to marshal filtered response: %v", err)
		return body
	}
	return modifiedBody
}
