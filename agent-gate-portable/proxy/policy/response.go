package policy

import (
	"encoding/json"
	"fmt"
)

// DenyErrorResponse formats a policy violation as an Anthropic-compatible error response.
// This allows Claude Code to display a meaningful error message when a tool call is blocked.
func DenyErrorResponse(tool, policyID, reason string) []byte {
	resp := map[string]interface{}{
		"type": "error",
		"error": map[string]interface{}{
			"type":      "policy_error",
			"message":   fmt.Sprintf("Tool '%s' blocked by policy '%s': %s", tool, policyID, reason),
			"policy_id": policyID,
			"tool":      tool,
		},
	}
	data, _ := json.Marshal(resp)
	return data
}
