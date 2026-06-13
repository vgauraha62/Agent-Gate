package anthropic

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// ── SSE Parser ──────────────────────────────────────────────────────────────

// ParseSSEEvent reads a single SSE event from a bufio.Reader.
// Returns the event, nil on success, io.EOF when the stream ends.
func ParseSSEEvent(r *bufio.Reader) (*SSEEvent, error) {
	var eventType string
	var dataBuf bytes.Buffer

	for {
		line, err := r.ReadString('\n')
		if err != nil {
			if err == io.EOF && dataBuf.Len() > 0 {
				// Return whatever we have
				break
			}
			return nil, err
		}

		line = strings.TrimRight(line, "\r\n")

		if line == "" {
			// Empty line marks end of an event
			if eventType != "" || dataBuf.Len() > 0 {
				break
			}
			continue
		}

		if strings.HasPrefix(line, "event: ") {
			eventType = strings.TrimPrefix(line, "event: ")
		} else if strings.HasPrefix(line, "data: ") {
			dataStr := strings.TrimPrefix(line, "data: ")
			if dataBuf.Len() > 0 {
				dataBuf.WriteString("\n")
			}
			dataBuf.WriteString(dataStr)
		}
		// Ignore other SSE fields (id:, retry:, etc.)
	}

	if eventType == "" && dataBuf.Len() == 0 {
		return nil, io.EOF
	}

	evt := &SSEEvent{
		Event: eventType,
		Data:  json.RawMessage(dataBuf.String()),
	}
	return evt, nil
}

// ── Content Block State Machine ─────────────────────────────────────────────

// ContentBlockBuffer holds the state for a single in-progress content block
// that we're buffering for policy evaluation.
type ContentBlockBuffer struct {
	Index      int
	BlockType  string // "text", "tool_use", etc.
	ToolName   string // "bash", "read", "write", "edit" (only for tool_use)
	ToolID     string // ID of the tool_use block
	JSONBuffer strings.Builder // Accumulated partial_json fragments
	StartEvent *SSEEvent       // The original content_block_start event (replayed on allow)
}

// ToolBlockPolicyEvent represents the result of evaluating a tool_use block
// against the policy engine. It tells the caller what to do.
type ToolBlockPolicyEvent struct {
	Index    int
	Allowed  bool
	ToolName string
	Command  string
	Path     string
	Reason   string
	PolicyID string
}

// StreamFilterState manages the state for filtering an SSE stream.
type StreamFilterState struct {
	buffers           map[int]*ContentBlockBuffer // Active content block buffers by index
	savedMessageDelta *SSEEvent                   // message_delta held while flushing buffered tool_use blocks
}

// NewStreamFilterState creates a new stream filter state.
func NewStreamFilterState() *StreamFilterState {
	return &StreamFilterState{
		buffers: make(map[int]*ContentBlockBuffer),
	}
}

// findFirstBufferedToolUse returns the first buffered tool_use block, or -1/nil if none.
// Used to flush residual buffers when upstream omits content_block_stop.
func (s *StreamFilterState) findFirstBufferedToolUse() (int, *ContentBlockBuffer) {
	for idx, cb := range s.buffers {
		if cb.BlockType == "tool_use" {
			return idx, cb
		}
	}
	return -1, nil
}

// ProcessEvent handles a single SSE event from the stream.
// It returns:
//   - forward: events to write to the client immediately
//   - pendingPolicy: a tool block that needs policy evaluation (nil if none)
//   - err: any error encountered
//
// Callers should:
//  1. Write all events in `forward` to the client
//  2. If `pendingPolicy` is non-nil, call the policy engine with it
//  3. Resume processing with the policy result via ProcessPolicyResult()
func (s *StreamFilterState) ProcessEvent(evt *SSEEvent) (forward []*SSEEvent, pendingPolicy *ToolBlockPolicyEvent, err error) {
	switch evt.Event {
	case "content_block_start":
		var data ContentBlockStartData
		if err := json.Unmarshal(evt.Data, &data); err != nil {
			return nil, nil, fmt.Errorf("parse content_block_start: %w", err)
		}

		cb := &ContentBlockBuffer{
			Index:     data.Index,
			BlockType: data.ContentBlock.Type,
		}

		if data.ContentBlock.Type == "tool_use" {
			cb.ToolName = data.ContentBlock.Name
			cb.ToolID = data.ContentBlock.ID
			cb.StartEvent = evt // Store for replay on allow

			// Tool_use blocks have initial input JSON in the start event
			if data.ContentBlock.Input != nil && len(data.ContentBlock.Input) > 0 {
				cb.JSONBuffer.WriteString(string(data.ContentBlock.Input))
			}

			// Buffer tool_use — do NOT forward yet
			s.buffers[data.Index] = cb
			return nil, nil, nil

		} else {
			// Text blocks — forward immediately
			s.buffers[data.Index] = cb
			forward = append(forward, evt)
			return forward, nil, nil
		}

	case "content_block_delta":
		var data ContentBlockDeltaData
		if err := json.Unmarshal(evt.Data, &data); err != nil {
			return nil, nil, fmt.Errorf("parse content_block_delta: %w", err)
		}

		cb, exists := s.buffers[data.Index]
		if !exists {
			// Unknown block — forward anyway
			return []*SSEEvent{evt}, nil, nil
		}

		if cb.BlockType == "tool_use" && data.Delta.Type == "input_json_delta" {
			// Accumulate JSON fragments — do NOT forward yet
			cb.JSONBuffer.WriteString(data.Delta.PartialJSON)
			return nil, nil, nil
		}

		// Text delta or other — forward immediately
		return []*SSEEvent{evt}, nil, nil

	case "content_block_stop":
		var data ContentBlockStopData
		if err := json.Unmarshal(evt.Data, &data); err != nil {
			return nil, nil, fmt.Errorf("parse content_block_stop: %w", err)
		}

		cb, exists := s.buffers[data.Index]
		if !exists {
			// Unknown block — forward stop event
			return []*SSEEvent{evt}, nil, nil
		}

		if cb.BlockType == "tool_use" {
			// Tool_use is complete — extract command/path and check policy
			completeJSON := cb.JSONBuffer.String()

			toolName, command, path := ExtractToolFromJSON(cb.ToolName, []byte(completeJSON))

			pendingPolicy = &ToolBlockPolicyEvent{
				Index:    data.Index,
				Allowed:  false, // default deny
				ToolName: toolName,
				Command:  command,
				Path:     path,
			}

			// Do NOT clean up buffer yet — ProcessPolicyResult needs it
			// to replay the original content_block_start on allow.
			// Cleanup happens in ProcessPolicyResult.

			// Do NOT forward stop event yet — wait for policy result
			return nil, pendingPolicy, nil
		}

		// Non-tool block — forward stop event
		delete(s.buffers, data.Index)
		return []*SSEEvent{evt}, nil, nil

	case "message_delta":
		// Some upstreams (e.g., LiteLLM → Zen API) omit content_block_stop and
		// terminate content blocks implicitly via message_delta. Check for
		// residual buffered tool_use blocks and flush them.
		if idx, cb := s.findFirstBufferedToolUse(); cb != nil {
			s.savedMessageDelta = evt // Save for replay after policy evaluation
			completeJSON := cb.JSONBuffer.String()
			toolName, command, path := ExtractToolFromJSON(cb.ToolName, []byte(completeJSON))
			delete(s.buffers, idx)
			return nil, &ToolBlockPolicyEvent{
				Index:    idx,
				Allowed:  false, // default deny
				ToolName: toolName,
				Command:  command,
				Path:     path,
			}, nil
		}
		// No residual buffers — pass through normally
		return []*SSEEvent{evt}, nil, nil

	case "message_start", "ping":
		// Pass through without modification
		return []*SSEEvent{evt}, nil, nil

	case "message_stop":
		// If residual tool_use blocks remain (e.g., upstream skipped both
		// content_block_stop and message_delta with implicit termination),
		// flush them before the stream ends. This is a defensive fallback.
		if idx, cb := s.findFirstBufferedToolUse(); cb != nil {
			s.savedMessageDelta = evt // Store message_stop to replay after policy eval
			completeJSON := cb.JSONBuffer.String()
			toolName, command, path := ExtractToolFromJSON(cb.ToolName, []byte(completeJSON))
			delete(s.buffers, idx)
			return nil, &ToolBlockPolicyEvent{
				Index:    idx,
				Allowed:  false,
				ToolName: toolName,
				Command:  command,
				Path:     path,
			}, nil
		}
		return []*SSEEvent{evt}, nil, nil

	default:
		// Unknown events — pass through
		return []*SSEEvent{evt}, nil, nil
	}
}

// ProcessPolicyResult generates the replacement events when a policy decision
// is made for a buffered tool_use block.
//
// If allowed: returns the buffered content_block_start (replayed so the client
// sees the tool_use block) followed by the content_block_stop.
//
// If denied: returns a synthetic content_block_start {type:"text"} followed by
// a content_block_delta with an explanatory message, then content_block_stop.
//
// IMPORTANT: The SSE protocol requires every content block to begin with a
// content_block_start event before any deltas or stop. Omitting this causes
// the client to hang (Bug #1).
func (s *StreamFilterState) ProcessPolicyResult(decision *ToolBlockPolicyEvent) []*SSEEvent {
	if decision.Allowed {
		// Tool is allowed — replay the stored start event, then emit stop.
		// The original content_block_start {type:"tool_use"} was buffered
		// and never forwarded to the client.
		cb, exists := s.buffers[decision.Index]
		stopData, _ := json.Marshal(ContentBlockStopData{Index: decision.Index})
		stopEvent := &SSEEvent{Event: "content_block_stop", Data: json.RawMessage(stopData)}

		if exists && cb.StartEvent != nil {
			delete(s.buffers, decision.Index)
			result := []*SSEEvent{cb.StartEvent, stopEvent}
			// Release saved message_delta now that all buffers are clear
			if s.savedMessageDelta != nil && len(s.buffers) == 0 {
				result = append(result, s.savedMessageDelta)
				s.savedMessageDelta = nil
			}
			return result
		}
		// Fallback: emit stop only (shouldn't happen in practice)
		delete(s.buffers, decision.Index)
		result := []*SSEEvent{stopEvent}
		if s.savedMessageDelta != nil && len(s.buffers) == 0 {
			result = append(result, s.savedMessageDelta)
			s.savedMessageDelta = nil
		}
		return result
	}

	// Tool is denied — emit a synthetic text block explaining the denial.
	// The client needs a content_block_start {type:"text"} before the delta.
	reason := decision.Reason
	if reason == "" {
		reason = fmt.Sprintf("Blocked by AgentGate policy")
	}

	denialText := fmt.Sprintf(
		"[AgentGate Policy Denied] Tool '%s' was blocked by policy '%s': %s",
		decision.ToolName, decision.PolicyID, reason,
	)

	// 1. Synthetic content_block_start with type:"text"
	startData, _ := json.Marshal(ContentBlockStartData{
		Index: decision.Index,
		ContentBlock: ContentBlock{
			Type: "text",
		},
	})

	// 2. Text delta with the denial message
	delta := DeltaBlock{
		Type: "text_delta",
		Text: denialText,
	}
	deltaData, _ := json.Marshal(ContentBlockDeltaData{
		Index: decision.Index,
		Delta: delta,
	})

	// 3. Stop the text block
	stopData, _ := json.Marshal(ContentBlockStopData{Index: decision.Index})

	// Clean up the buffer — no longer needed
	delete(s.buffers, decision.Index)

	result := []*SSEEvent{
		{Event: "content_block_start", Data: json.RawMessage(startData)},
		{Event: "content_block_delta", Data: json.RawMessage(deltaData)},
		{Event: "content_block_stop", Data: json.RawMessage(stopData)},
	}

	// Release saved message_delta now that all buffers are clear
	if s.savedMessageDelta != nil && len(s.buffers) == 0 {
		result = append(result, s.savedMessageDelta)
		s.savedMessageDelta = nil
	}

	return result
}

// ExtractToolFromJSON parses tool input JSON and extracts structured fields
// like command and path. This mirrors extractToolArgs in extract.go but works
// with raw JSON bytes rather than unmarshalled content.
func ExtractToolFromJSON(toolName string, inputJSON []byte) (name string, command string, path string) {
	name = toolName

	var fields map[string]interface{}
	if err := json.Unmarshal(inputJSON, &fields); err != nil {
		return name, "", ""
	}

	switch toolName {
	case "bash":
		if cmd, ok := fields["command"].(string); ok {
			command = cmd
		}
	case "read", "read_file":
		if p, ok := fields["path"].(string); ok {
			path = p
		}
		if cmd, ok := fields["command"].(string); ok {
			command = cmd
		}
	case "write", "write_file":
		if p, ok := fields["path"].(string); ok {
			path = p
		}
		if cmd, ok := fields["content"].(string); ok {
			command = cmd
		}
	case "edit":
		if p, ok := fields["path"].(string); ok {
			path = p
		}
		if cmd, ok := fields["content"].(string); ok {
			command = cmd
		}
	}

	return name, command, path
}

// RenderSSEEvent serializes an SSE event to bytes for writing to the wire.
func RenderSSEEvent(evt *SSEEvent) []byte {
	var buf bytes.Buffer
	if evt.Event != "" {
		buf.WriteString(fmt.Sprintf("event: %s\n", evt.Event))
	}
	// Multi-line data (split on \n if needed)
	dataStr := string(evt.Data)
	for _, line := range strings.Split(dataStr, "\n") {
		buf.WriteString(fmt.Sprintf("data: %s\n", line))
	}
	buf.WriteString("\n")
	return buf.Bytes()
}
