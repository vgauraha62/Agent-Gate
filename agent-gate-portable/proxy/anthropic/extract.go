package anthropic

import "encoding/json"

// ToolInvocation represents a single tool call to be checked against policy.
type ToolInvocation struct {
	AgentID string      `json:"agent_id"`
	Tool    string      `json:"tool"`
	Command string      `json:"command"`
	Path    string      `json:"path"`
	Input   interface{} `json:"input"`
}

// ExtractToolInvocations parses a MessagesRequest and extracts tool use
// invocations from both the conversation history and tool definitions.
// agentID is an optional session identifier passed through from X-Agent-ID header.
func ExtractToolInvocations(req *MessagesRequest, agentID string) []ToolInvocation {
	var invocations []ToolInvocation

	// Scan message content for tool_use blocks (assistant tool calls in history)
	for _, msg := range req.Messages {
		for _, block := range msg.Content {
			if block.Type == "tool_use" {
				inv := ToolInvocation{
					AgentID: agentID,
					Tool:    block.Name,
					Input:   block.Input,
				}
				// Extract semantic command/path from tool input
				extractToolArgs(block.Name, block.Input, &inv)
				invocations = append(invocations, inv)
			}
		}
	}

	// Also extract from tool definitions themselves (for policy evaluation
	// of which tools the model is even allowed to use)
	for _, t := range req.Tools {
		invocations = append(invocations, ToolInvocation{
			AgentID: agentID,
			Tool:    t.Name,
			Input:   t.InputSchema,
		})
	}

	return invocations
}

// extractToolArgs parses known tool schemas to extract structured fields
// like command and path from the raw JSON input.
func extractToolArgs(name string, input json.RawMessage, inv *ToolInvocation) {
	var fields map[string]interface{}
	if err := json.Unmarshal(input, &fields); err != nil {
		return
	}

	switch name {
	case "bash":
		if cmd, ok := fields["command"].(string); ok {
			inv.Command = cmd
		}
	case "read", "read_file":
		if p, ok := fields["path"].(string); ok {
			inv.Path = p
		}
	case "write", "write_file":
		if p, ok := fields["path"].(string); ok {
			inv.Path = p
		}
		if cmd, ok := fields["content"].(string); ok {
			inv.Command = cmd
		}
	case "edit":
		if p, ok := fields["path"].(string); ok {
			inv.Path = p
		}
		if cmd, ok := fields["content"].(string); ok {
			inv.Command = cmd
		}
	}
}
