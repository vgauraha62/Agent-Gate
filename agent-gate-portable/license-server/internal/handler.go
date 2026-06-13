package internal

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

const (
	tokenDuration = 24 * time.Hour
	graceDuration = 24 * time.Hour
)

// LicenseHandler holds dependencies for the license API handlers.
type LicenseHandler struct {
	DB     *DB
	Signer *Signer
}

// ── Request / Response types ────────────────────────────────────────────────

type activateRequest struct {
	Key         string `json:"key"`
	Fingerprint string `json:"fingerprint"`
	ContainerID string `json:"container_id,omitempty"`
	IPAddress   string `json:"ip_address,omitempty"`
}

type validateRequest struct {
	Key         string `json:"key"`
	Token       string `json:"token"`
	Fingerprint string `json:"fingerprint"`
}

type tokenResponse struct {
	Token     string `json:"token"`
	ExpiresIn int    `json:"expires_in"` // seconds
}

type errorResponse struct {
	Error string `json:"error"`
}

// ── POST /api/v1/license/activate ───────────────────────────────────────────

func (h *LicenseHandler) Activate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, errorResponse{Error: "method not allowed"})
		return
	}

	var req activateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid request body"})
		return
	}

	if req.Key == "" || req.Fingerprint == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "key and fingerprint are required"})
		return
	}

	// Validate key format
	if !ValidateLicenseKeyFormat(req.Key) {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid license key format"})
		return
	}

	// Look up license
	lic, err := h.DB.GetLicenseByKey(req.Key)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse{Error: "license key not found"})
		return
	}

	// Check status
	switch lic.Status {
	case "revoked":
		writeJSON(w, http.StatusForbidden, errorResponse{Error: "license has been revoked"})
		return
	case "expired":
		writeJSON(w, http.StatusForbidden, errorResponse{Error: "license has expired"})
		return
	}

	// Check expiry
	if lic.ExpiresAt != nil {
		expiresAt, err := time.Parse(time.RFC3339, *lic.ExpiresAt)
		if err == nil && time.Now().After(expiresAt) {
			writeJSON(w, http.StatusForbidden, errorResponse{Error: "license has expired"})
			return
		}
	}

	// Record this activation
	_ = h.DB.UpsertActivation(lic.ID, req.Fingerprint, req.ContainerID, req.IPAddress)

	// Generate JWT
	token, err := h.Signer.GenerateToken(lic, req.Fingerprint, tokenDuration)
	if err != nil {
		log.Printf("ERROR: failed to sign token: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "failed to generate token"})
		return
	}

	log.Printf("ACTIVATED: key=%s tier=%s fingerprint=%s", maskKey(req.Key), lic.Tier, shortFP(req.Fingerprint))

	writeJSON(w, http.StatusOK, tokenResponse{
		Token:     token,
		ExpiresIn: int(tokenDuration.Seconds()),
	})
}

// ── POST /api/v1/license/validate ───────────────────────────────────────────

func (h *LicenseHandler) Validate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, errorResponse{Error: "method not allowed"})
		return
	}

	var req validateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid request body"})
		return
	}

	if req.Key == "" || req.Token == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "key and token are required"})
		return
	}

	lic, err := h.DB.GetLicenseByKey(req.Key)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse{Error: "license key not found"})
		return
	}

	switch lic.Status {
	case "revoked":
		writeJSON(w, http.StatusForbidden, errorResponse{Error: "license has been revoked"})
		return
	case "expired":
		writeJSON(w, http.StatusForbidden, errorResponse{Error: "license has expired"})
		return
	}

	// Generate a fresh token
	token, err := h.Signer.GenerateToken(lic, req.Fingerprint, tokenDuration)
	if err != nil {
		log.Printf("ERROR: failed to sign token: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "failed to generate token"})
		return
	}

	writeJSON(w, http.StatusOK, tokenResponse{
		Token:     token,
		ExpiresIn: int(tokenDuration.Seconds()),
	})
}

// ── Health ──────────────────────────────────────────────────────────────────

func (h *LicenseHandler) Health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// ── Helpers ─────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func maskKey(key string) string {
	if len(key) <= 8 {
		return "****"
	}
	return key[:4] + "-****-**" + key[len(key)-4:]
}

func shortFP(fp string) string {
	if len(fp) > 12 {
		return fp[:12] + "..."
	}
	return fp
}
