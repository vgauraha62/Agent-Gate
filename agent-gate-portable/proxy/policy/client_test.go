package policy

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCheckAllow(t *testing.T) {
	// Create a mock AgentGate server that returns ALLOW
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/check" {
			t.Errorf("expected /check, got %s", r.URL.Path)
		}
		resp := CheckResponse{Allowed: true, PolicyID: "allow-bash"}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	result, err := client.Check(&CheckRequest{
		AgentID: "session-123",
		Tool:    "bash",
		Command: "ls -la",
	})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Allowed {
		t.Error("expected allowed=true")
	}
	if result.PolicyID != "allow-bash" {
		t.Errorf("expected policy_id 'allow-bash', got '%s'", result.PolicyID)
	}
}

func TestCheckDeny(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		resp := CheckResponse{Allowed: false, PolicyID: "block-passwd", Reason: "/etc/passwd blocked"}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	result, err := client.Check(&CheckRequest{
		AgentID: "session-123",
		Tool:    "bash",
		Command: "cat /etc/passwd",
	})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Allowed {
		t.Error("expected allowed=false")
	}
	if result.PolicyID != "block-passwd" {
		t.Errorf("expected policy_id 'block-passwd', got '%s'", result.PolicyID)
	}
	if result.Reason != "/etc/passwd blocked" {
		t.Errorf("expected reason, got '%s'", result.Reason)
	}
}

func TestCheckServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		// Return invalid JSON
		w.Write([]byte("internal error"))
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	_, err := client.Check(&CheckRequest{
		Tool: "bash",
	})

	if err == nil {
		t.Error("expected error for invalid JSON response")
	}
}

func TestCheckTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
		resp := CheckResponse{Allowed: true}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, 10*time.Millisecond)
	_, err := client.Check(&CheckRequest{
		Tool: "bash",
	})

	if err == nil {
		t.Error("expected timeout error")
	}
}

func TestCheckSendsCorrectBody(t *testing.T) {
	var receivedBody CheckRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&receivedBody)
		resp := CheckResponse{Allowed: true}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)
	client.Check(&CheckRequest{
		AgentID: "agent-1",
		Tool:    "read_file",
		Command: "",
		Path:    "/workspace/file.txt",
	})

	if receivedBody.AgentID != "agent-1" {
		t.Errorf("expected agent_id 'agent-1', got '%s'", receivedBody.AgentID)
	}
	if receivedBody.Tool != "read_file" {
		t.Errorf("expected tool 'read_file', got '%s'", receivedBody.Tool)
	}
	if receivedBody.Path != "/workspace/file.txt" {
		t.Errorf("expected path '/workspace/file.txt', got '%s'", receivedBody.Path)
	}
}

func TestCheckMultipleTools(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		resp := CheckResponse{Allowed: true}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second)

	// First tool check
	result1, err1 := client.Check(&CheckRequest{Tool: "bash", Command: "ls"})
	if err1 != nil || !result1.Allowed {
		t.Errorf("first check should be allowed")
	}

	// Second tool check
	result2, err2 := client.Check(&CheckRequest{Tool: "read", Path: "/workspace/file"})
	if err2 != nil || !result2.Allowed {
		t.Errorf("second check should be allowed")
	}

	if callCount != 2 {
		t.Errorf("expected 2 calls to AgentGate, got %d", callCount)
	}
}

func TestDenyErrorResponse(t *testing.T) {
	data := DenyErrorResponse("bash", "block-rm-rf", "rm -rf is blocked")

	var resp map[string]interface{}
	if err := json.Unmarshal(data, &resp); err != nil {
		t.Fatalf("failed to parse deny response: %v", err)
	}

	if resp["type"] != "error" {
		t.Errorf("expected type 'error', got '%s'", resp["type"])
	}

	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatal("expected error object")
	}

	if errObj["type"] != "policy_error" {
		t.Errorf("expected error type 'policy_error', got '%s'", errObj["type"])
	}
	if errObj["policy_id"] != "block-rm-rf" {
		t.Errorf("expected policy_id 'block-rm-rf', got '%s'", errObj["policy_id"])
	}
	if errObj["tool"] != "bash" {
		t.Errorf("expected tool 'bash', got '%s'", errObj["tool"])
	}
}
