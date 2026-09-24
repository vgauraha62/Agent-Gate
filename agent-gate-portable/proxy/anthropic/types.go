package anthropic

import "encoding/json"

// MessagesRequest is the request body for the Anthropic Messages API.
type MessagesRequest struct {
	Model       string        `json:"model"`
	Messages    []Message     `json:"messages"`
	System      string        `json:"system,omitempty"`
	MaxTokens   int           `json:"max_tokens"`
	Tools       []ToolDef     `json:"tools,omitempty"`
	ToolChoice  *ToolChoice   `json:"tool_choice,omitempty"`
	Stream      bool          `json:"stream,omitempty"`
	Temperature float64       `json:"temperature,omitempty"`
}

// Message is a single message in the conversation.
type Message struct {
	Role    string         `json:"role"`
	Content []ContentBlock `json:"content"`
}

// UnmarshalJSON handles both string and []ContentBlock formats for the content field.
//
// The Anthropic Messages API historically accepted content as a string for
// simple text-only messages, but now requires an array of content blocks to
// support multi-modal content (text, tool_use, tool_result, etc.).
//
// This custom unmarshaler provides backward compatibility by accepting either
// format and normalizing to []ContentBlock.
func (m *Message) UnmarshalJSON(data []byte) error {
	var raw struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	m.Role = raw.Role

	// Handle null or missing content
	if len(raw.Content) == 0 || string(raw.Content) == "null" {
		m.Content = nil
		return nil
	}

	// Try as a simple string (backward compatible format)
	var contentStr string
	if err := json.Unmarshal(raw.Content, &contentStr); err == nil {
		m.Content = []ContentBlock{{Type: "text", Text: contentStr}}
		return nil
	}

	// Try as an array of content blocks (current API format)
	return json.Unmarshal(raw.Content, &m.Content)
}

// ContentBlock is a block of content within a message.
type ContentBlock struct {
	Type  string          `json:"type"`
	Text  string          `json:"text,omitempty"`
	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`
}

// ToolDef defines a tool that the model may use.
type ToolDef struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	InputSchema interface{} `json:"input_schema"`
}

// ToolChoice configures how the model should choose tools.
type ToolChoice struct {
	Type string `json:"type"`
	Name string `json:"name,omitempty"`
}

// ── SSE Streaming Types ─────────────────────────────────────────────────────

// SSEEvent represents a single Server-Sent Event from the Anthropic API.
type SSEEvent struct {
	Event string          // The event type from the "event:" line
	Data  json.RawMessage // The JSON data from the "data:" line
}

// ContentBlockStartData is the data payload for content_block_start events.
type ContentBlockStartData struct {
	Index        int             `json:"index"`
	ContentBlock ContentBlock    `json:"content_block"`
}

// ContentBlockDeltaData is the data payload for content_block_delta events.
type ContentBlockDeltaData struct {
	Index int         `json:"index"`
	Delta DeltaBlock  `json:"delta"`
}

// DeltaBlock represents the delta field in content_block_delta events.
type DeltaBlock struct {
	Type        string `json:"type"`
	Text        string `json:"text,omitempty"`
	PartialJSON string `json:"partial_json,omitempty"`
}

// ContentBlockStopData is the data payload for content_block_stop events.
type ContentBlockStopData struct {
	Index int `json:"index"`
}

// MessagesResponse is the non-streaming response body from the Anthropic API.
type MessagesResponse struct {
	ID      string         `json:"id"`
	Type    string         `json:"type"`
	Role    string         `json:"role"`
	Content []ContentBlock `json:"content"`
	Model   string         `json:"model"`
	Usage   *UsageInfo     `json:"usage,omitempty"`
}

// UsageInfo contains token usage information.
type UsageInfo struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}
