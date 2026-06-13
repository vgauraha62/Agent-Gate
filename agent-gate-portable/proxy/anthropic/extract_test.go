package anthropic

import (
	"encoding/json"
	"testing"
)

func TestExtractToolInvocations_NoTools(t *testing.T) {
	req := &MessagesRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []Message{
			{Role: "user", Content: []ContentBlock{{Type: "text", Text: "Hello"}}},
		},
		MaxTokens: 100,
	}

	tools := ExtractToolInvocations(req, "session-123")
	if len(tools) != 0 {
		t.Errorf("expected 0 tools, got %d", len(tools))
	}
}

func TestExtractToolInvocations_WithToolUse(t *testing.T) {
	inputRaw := json.RawMessage(`{"command": "ls -la"}`)

	req := &MessagesRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []Message{
			{Role: "user", Content: []ContentBlock{{Type: "text", Text: "List files"}}},
			{Role: "assistant", Content: []ContentBlock{
				{Type: "text", Text: "I'll list the files"},
				{Type: "tool_use", ID: "call_1", Name: "bash", Input: inputRaw},
			}},
		},
		MaxTokens: 100,
	}

	tools := ExtractToolInvocations(req, "session-123")
	if len(tools) != 1 {
		t.Fatalf("expected 1 tool, got %d", len(tools))
	}
	if tools[0].Tool != "bash" {
		t.Errorf("expected tool 'bash', got '%s'", tools[0].Tool)
	}
	if tools[0].Command != "ls -la" {
		t.Errorf("expected command 'ls -la', got '%s'", tools[0].Command)
	}
	if tools[0].AgentID != "session-123" {
		t.Errorf("expected agent 'session-123', got '%s'", tools[0].AgentID)
	}
}

func TestExtractToolInvocations_WithToolDefinitions(t *testing.T) {
	req := &MessagesRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []Message{
			{Role: "user", Content: []ContentBlock{{Type: "text", Text: "Hi"}}},
		},
		MaxTokens: 100,
		Tools: []ToolDef{
			{Name: "bash", Description: "Run shell commands", InputSchema: map[string]interface{}{"type": "object"}},
			{Name: "read_file", Description: "Read files", InputSchema: map[string]interface{}{"type": "object"}},
		},
	}

	tools := ExtractToolInvocations(req, "session-456")
	// Should extract from both tool_use (0) and tool definitions (2)
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools (from definitions), got %d", len(tools))
	}
	if tools[0].Tool != "bash" {
		t.Errorf("expected first tool 'bash', got '%s'", tools[0].Tool)
	}
	if tools[1].Tool != "read_file" {
		t.Errorf("expected second tool 'read_file', got '%s'", tools[1].Tool)
	}
}

func TestExtractToolArgs_Bash(t *testing.T) {
	input := json.RawMessage(`{"command": "cat /etc/passwd"}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "bash"}

	extractToolArgs("bash", input, &inv)
	if inv.Command != "cat /etc/passwd" {
		t.Errorf("expected command 'cat /etc/passwd', got '%s'", inv.Command)
	}
}

func TestExtractToolArgs_ReadFile(t *testing.T) {
	input := json.RawMessage(`{"path": "/workspace/main.go"}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "read_file"}

	extractToolArgs("read_file", input, &inv)
	if inv.Path != "/workspace/main.go" {
		t.Errorf("expected path '/workspace/main.go', got '%s'", inv.Path)
	}
}

func TestExtractToolArgs_Write(t *testing.T) {
	input := json.RawMessage(`{"path": "/workspace/new.go", "content": "package main"}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "write"}

	extractToolArgs("write", input, &inv)
	if inv.Path != "/workspace/new.go" {
		t.Errorf("expected path '/workspace/new.go', got '%s'", inv.Path)
	}
	if inv.Command != "package main" {
		t.Errorf("expected command 'package main', got '%s'", inv.Command)
	}
}

func TestExtractToolArgs_Edit(t *testing.T) {
	input := json.RawMessage(`{"path": "/workspace/file.go", "content": "// updated"}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "edit"}

	extractToolArgs("edit", input, &inv)
	if inv.Path != "/workspace/file.go" {
		t.Errorf("expected path '/workspace/file.go', got '%s'", inv.Path)
	}
	if inv.Command != "// updated" {
		t.Errorf("expected command '// updated', got '%s'", inv.Command)
	}
}

func TestExtractToolArgs_UnknownTool(t *testing.T) {
	input := json.RawMessage(`{"foo": "bar"}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "unknown_tool"}

	extractToolArgs("unknown_tool", input, &inv)
	// Should not panic, fields remain empty
	if inv.Command != "" {
		t.Errorf("expected empty command for unknown tool, got '%s'", inv.Command)
	}
}

func TestExtractToolArgs_InvalidJSON(t *testing.T) {
	input := json.RawMessage(`{invalid json}`)
	inv := ToolInvocation{AgentID: "a1", Tool: "bash"}

	extractToolArgs("bash", input, &inv)
	// Should not panic, fields remain empty
}

// ---------- Message.UnmarshalJSON tests ----------

func TestMessageUnmarshal_StringContent(t *testing.T) {
	jsonStr := `{"role": "user", "content": "Just text"}`
	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal string content: %v", err)
	}
	if msg.Role != "user" {
		t.Errorf("Expected role 'user', got '%s'", msg.Role)
	}
	if len(msg.Content) != 1 {
		t.Fatalf("Expected 1 content block, got %d", len(msg.Content))
	}
	if msg.Content[0].Type != "text" {
		t.Errorf("Expected type 'text', got '%s'", msg.Content[0].Type)
	}
	if msg.Content[0].Text != "Just text" {
		t.Errorf("Expected text 'Just text', got '%s'", msg.Content[0].Text)
	}
}

func TestMessageUnmarshal_ArrayContent(t *testing.T) {
	jsonStr := `{"role": "user", "content": [{"type": "text", "text": "Hello"}]}`
	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal array content: %v", err)
	}
	if msg.Role != "user" {
		t.Errorf("Expected role 'user', got '%s'", msg.Role)
	}
	if len(msg.Content) != 1 {
		t.Fatalf("Expected 1 content block, got %d", len(msg.Content))
	}
	if msg.Content[0].Type != "text" || msg.Content[0].Text != "Hello" {
		t.Errorf("Content block mismatch: got type=%s text=%s", msg.Content[0].Type, msg.Content[0].Text)
	}
}

func TestMessageUnmarshal_NullContent(t *testing.T) {
	jsonStr := `{"role": "user", "content": null}`
	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal null content: %v", err)
	}
	if msg.Role != "user" {
		t.Errorf("Expected role 'user', got '%s'", msg.Role)
	}
	if msg.Content != nil {
		t.Errorf("Expected nil content for null input, got %v", msg.Content)
	}
}

func TestMessageUnmarshal_MissingContent(t *testing.T) {
	jsonStr := `{"role": "user"}`
	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal missing content: %v", err)
	}
	if msg.Role != "user" {
		t.Errorf("Expected role 'user', got '%s'", msg.Role)
	}
	if msg.Content != nil {
		t.Errorf("Expected nil content for missing field, got %v", msg.Content)
	}
}

func TestMessageUnmarshal_MultipleBlocks(t *testing.T) {
	jsonStr := `{
		"role": "assistant",
		"content": [
			{"type": "text", "text": "Let me check"},
			{"type": "tool_use", "id": "call_1", "name": "bash", "input": {"command": "ls"}}
		]
	}`
	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal multi-block content: %v", err)
	}
	if len(msg.Content) != 2 {
		t.Fatalf("Expected 2 content blocks, got %d", len(msg.Content))
	}
	if msg.Content[0].Type != "text" || msg.Content[0].Text != "Let me check" {
		t.Errorf("First block mismatch: got type=%s text=%s", msg.Content[0].Type, msg.Content[0].Text)
	}
	if msg.Content[1].Type != "tool_use" || msg.Content[1].Name != "bash" {
		t.Errorf("Second block mismatch: got type=%s name=%s", msg.Content[1].Type, msg.Content[1].Name)
	}
}

// TestMessagesRequestUnmarshal_FullRequest validates that a complete
// Anthropic API request with mixed string/array content can be parsed.
func TestMessagesRequestUnmarshal_FullRequest(t *testing.T) {
	jsonStr := `{
		"model": "claude-sonnet-4-20250514",
		"max_tokens": 100,
		"messages": [
			{"role": "user", "content": "Hello"},
			{"role": "assistant", "content": [{"type": "text", "text": "Hi"}]}
		]
	}`
	var req MessagesRequest
	if err := json.Unmarshal([]byte(jsonStr), &req); err != nil {
		t.Fatalf("Failed to unmarshal full request: %v", err)
	}
	if len(req.Messages) != 2 {
		t.Fatalf("Expected 2 messages, got %d", len(req.Messages))
	}
	// First message: string content
	if req.Messages[0].Role != "user" || len(req.Messages[0].Content) != 1 {
		t.Errorf("First message mismatch: role=%s content_len=%d", req.Messages[0].Role, len(req.Messages[0].Content))
	}
	if req.Messages[0].Content[0].Text != "Hello" {
		t.Errorf("Expected first message text 'Hello', got '%s'", req.Messages[0].Content[0].Text)
	}
	// Second message: array content
	if req.Messages[1].Content[0].Text != "Hi" {
		t.Errorf("Expected second message text 'Hi', got '%s'", req.Messages[1].Content[0].Text)
	}
}

func TestMessagesRequestUnmarshal_EmptyMessages(t *testing.T) {
	jsonStr := `{"model": "claude-sonnet-4-20250514", "max_tokens": 100, "messages": []}`
	var req MessagesRequest
	if err := json.Unmarshal([]byte(jsonStr), &req); err != nil {
		t.Fatalf("Failed to unmarshal with empty messages: %v", err)
	}
	if len(req.Messages) != 0 {
		t.Errorf("Expected 0 messages, got %d", len(req.Messages))
	}
}

// TestExtractToolInvocations_StringContent verifies that tool extraction
// still works when messages use string content format.
func TestExtractToolInvocations_StringContent(t *testing.T) {
	// Build from struct literals (no JSON round-trip needed) — test extraction
	// logic with string-based content blocks produced by UnmarshalJSON.
	req := &MessagesRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []Message{
			// Simulate what UnmarshalJSON produces from string content
			{Role: "user", Content: []ContentBlock{{Type: "text", Text: "List files"}}},
		},
		MaxTokens: 100,
	}

	tools := ExtractToolInvocations(req, "session-1")
	if len(tools) != 0 {
		t.Errorf("expected 0 tools from text-only messages, got %d", len(tools))
	}
}

func TestExtractMultipleToolUses(t *testing.T) {
	bashInput := json.RawMessage(`{"command": "ls"}`)
	readInput := json.RawMessage(`{"path": "/workspace/file.txt"}`)

	req := &MessagesRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []Message{
			{Role: "assistant", Content: []ContentBlock{
				{Type: "tool_use", ID: "call_1", Name: "bash", Input: bashInput},
				{Type: "tool_use", ID: "call_2", Name: "read", Input: readInput},
			}},
		},
		MaxTokens: 100,
	}

	tools := ExtractToolInvocations(req, "session-789")
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools, got %d", len(tools))
	}
	if tools[0].Tool != "bash" || tools[0].Command != "ls" {
		t.Errorf("first tool should be bash with 'ls', got %s/%s", tools[0].Tool, tools[0].Command)
	}
	if tools[1].Tool != "read" || tools[1].Path != "/workspace/file.txt" {
		t.Errorf("second tool should be read with path, got %s/%s", tools[1].Tool, tools[1].Path)
	}
}
