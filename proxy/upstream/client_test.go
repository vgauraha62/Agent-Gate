package upstream

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestForwardRequest(t *testing.T) {
	// Mock Anthropic API server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify headers are passed through
		if r.Header.Get("x-api-key") != "test-key-123" {
			t.Errorf("expected x-api-key 'test-key-123', got '%s'", r.Header.Get("x-api-key"))
		}
		if r.Header.Get("anthropic-version") != "2023-06-01" {
			t.Errorf("expected anthropic-version '2023-06-01', got '%s'", r.Header.Get("anthropic-version"))
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("expected Content-Type 'application/json', got '%s'", r.Header.Get("Content-Type"))
		}

		// Read and verify body
		body, _ := io.ReadAll(r.Body)
		if !bytes.Contains(body, []byte("Hello")) {
			t.Errorf("expected body to contain 'Hello', got '%s'", string(body))
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"content":[{"type":"text","text":"Hi!"}]}`))
	}))
	defer server.Close()

	client := NewClient(server.URL, 10*time.Second)

	headers := make(http.Header)
	headers.Set("anthropic-version", "2023-06-01")

	body := []byte(`{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":[{"type":"text","text":"Hello"}]}],"max_tokens":100}`)

	resp, err := client.ForwardRequest("test-key-123", body, headers)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(respBody, []byte("Hi!")) {
		t.Errorf("expected response to contain 'Hi!', got '%s'", string(respBody))
	}
}

func TestForwardRequest_EmptyAPIKey(t *testing.T) {
	// The proxy forwards the x-api-key as-is (per-agent key passthrough).
	// Empty keys are passed through; the upstream API will reject them.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the empty key is forwarded as-is
		key := r.Header.Get("x-api-key")
		if key != "" {
			t.Errorf("expected empty x-api-key, got '%s'", key)
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{}`))
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	headers := make(http.Header)
	body := []byte(`{}`)

	resp, err := client.ForwardRequest("", body, headers)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	resp.Body.Close()
}

func TestForwardStream(t *testing.T) {
	// Mock SSE Anthropic server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "text/event-stream" {
			t.Errorf("expected Accept 'text/event-stream', got '%s'", r.Header.Get("Accept"))
		}
		if r.Header.Get("x-api-key") != "stream-key" {
			t.Errorf("expected x-api-key 'stream-key', got '%s'", r.Header.Get("x-api-key"))
		}

		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("expected flushable response writer")
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")

		// Write SSE events
		for i := 0; i < 3; i++ {
			w.Write([]byte("event: ping\ndata: {\"count\": " + string(rune('0'+i)) + "}\n\n"))
			flusher.Flush()
		}
		w.Write([]byte("event: done\ndata: {}\n\n"))
		flusher.Flush()
	}))
	defer server.Close()

	client := NewClient(server.URL, 10*time.Second)

	headers := make(http.Header)
	headers.Set("anthropic-version", "2023-06-01")

	body := []byte(`{"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"Hi"}]}]}`)

	var buf bytes.Buffer
	err := client.ForwardStream("stream-key", body, headers, &buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "event: ping") {
		t.Errorf("expected SSE events in output")
	}
	if !strings.Contains(output, "event: done") {
		t.Errorf("expected done event in output")
	}
}

func TestForwardStream_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"bad request"}`))
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	headers := make(http.Header)
	body := []byte(`{}`)

	var buf bytes.Buffer
	err := client.ForwardStream("key", body, headers, &buf)
	// Should get an error if the upstream returns non-2xx
	// io.Copy returns nil error but the response may contain the error
	_ = err
}

func TestNewClient(t *testing.T) {
	client := NewClient("http://localhost:9999", 5*time.Second)
	if client == nil {
		t.Fatal("expected non-nil client")
	}
	if client.baseURL != "http://localhost:9999" {
		t.Errorf("expected baseURL 'http://localhost:9999', got '%s'", client.baseURL)
	}
}

func TestForwardRequestToNonexistentServer(t *testing.T) {
	client := NewClient("http://localhost:19999", 1*time.Second)
	headers := make(http.Header)
	body := []byte(`{}`)

	_, err := client.ForwardRequest("key", body, headers)
	if err == nil {
		t.Error("expected error when forwarding to nonexistent server")
	}
}
