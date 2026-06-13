package internal

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"
)

var timeNow = time.Now
const timeFormat = time.RFC3339

// AdminHandler provides endpoints for license management (key generation,
// listing, revocation). Protected by an API key header.
type AdminHandler struct {
	DB      *DB
	Signer  *Signer
	AdminKey string
}

// adminAuth checks the X-Admin-Key header against the configured admin key.
func (h *AdminHandler) adminAuth(r *http.Request) bool {
	return r.Header.Get("X-Admin-Key") == h.AdminKey
}

// ── Request types ───────────────────────────────────────────────────────────

type createLicenseRequest struct {
	Tier          string `json:"tier"`
	MaxRequests   int    `json:"max_requests"`
	MaxAgents     int    `json:"max_agents"`
	TrialDays     *int   `json:"trial_days,omitempty"`
	CustomerName  string `json:"customer_name"`
	CustomerEmail string `json:"customer_email"`
}

type createLicenseResponse struct {
	Key      string `json:"key"`
	ID       string `json:"id"`
	Tier     string `json:"tier"`
	Status   string `json:"status"`
	ExpiresAt *string `json:"expires_at,omitempty"`
}

// ── GET /admin/licenses ─────────────────────────────────────────────────────

func (h *AdminHandler) ListLicenses(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeJSON(w, http.StatusUnauthorized, errorResponse{Error: "invalid admin key"})
		return
	}

	licenses, err := h.DB.ListLicenses()
	if err != nil {
		log.Printf("ERROR: list licenses: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "database error"})
		return
	}
	if licenses == nil {
		licenses = []License{}
	}

	writeJSON(w, http.StatusOK, licenses)
}

// ── POST /admin/licenses ────────────────────────────────────────────────────

func (h *AdminHandler) CreateLicense(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeJSON(w, http.StatusUnauthorized, errorResponse{Error: "invalid admin key"})
		return
	}

	var req createLicenseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid request body"})
		return
	}

	// Validate tier
	validTiers := map[string]bool{"free": true, "starter": true, "pro": true, "enterprise": true}
	if !validTiers[req.Tier] {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "invalid tier: must be free, starter, pro, or enterprise"})
		return
	}

	if req.MaxRequests <= 0 {
		req.MaxRequests = 100
	}
	if req.MaxAgents <= 0 {
		req.MaxAgents = 1
	}

	key := GenerateLicenseKey(req.Tier)

	lic := &License{
		ID:           newID(),
		Key:          key,
		Tier:         req.Tier,
		Status:       "active",
		MaxRequests:  req.MaxRequests,
		MaxAgents:    req.MaxAgents,
		TrialDays:    req.TrialDays,
		CustomerName: req.CustomerName,
		CustomerEmail: req.CustomerEmail,
	}

	if req.Tier == "free" && req.TrialDays == nil {
		days := 14
		lic.TrialDays = &days
	}

	if req.TrialDays != nil {
		expiresAt := timeNow().AddDate(0, 0, *req.TrialDays).Format(timeFormat)
		lic.ExpiresAt = &expiresAt
	}

	if err := h.DB.InsertLicense(lic); err != nil {
		log.Printf("ERROR: insert license: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "failed to create license"})
		return
	}

	log.Printf("LICENSE CREATED: key=%s tier=%s customer=%s", maskKey(key), req.Tier, req.CustomerName)

	writeJSON(w, http.StatusCreated, createLicenseResponse{
		Key:       key,
		ID:        lic.ID,
		Tier:      lic.Tier,
		Status:    lic.Status,
		ExpiresAt: lic.ExpiresAt,
	})
}

// ── POST /admin/licenses/{key}/revoke ───────────────────────────────────────

func (h *AdminHandler) RevokeLicense(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeJSON(w, http.StatusUnauthorized, errorResponse{Error: "invalid admin key"})
		return
	}

	// Extract key from URL path: /admin/licenses/PRO-XXXX-XXXX-XXXX-X/revoke
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 4 {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "missing license key in path"})
		return
	}
	key := parts[3]

	lic, err := h.DB.GetLicenseByKey(key)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse{Error: "license not found"})
		return
	}

	if err := h.DB.RevokeLicense(lic.Key); err != nil {
		log.Printf("ERROR: revoke license: %v", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "failed to revoke"})
		return
	}

	log.Printf("LICENSE REVOKED: key=%s", maskKey(key))
	writeJSON(w, http.StatusOK, map[string]string{"status": "revoked", "key": key})
}

// ── GET /admin/licenses/{key} ───────────────────────────────────────────────

func (h *AdminHandler) GetLicenseDetail(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeJSON(w, http.StatusUnauthorized, errorResponse{Error: "invalid admin key"})
		return
	}

	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 4 {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "missing license key in path"})
		return
	}
	key := parts[3]

	lic, err := h.DB.GetLicenseByKey(key)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse{Error: "license not found"})
		return
	}

	activations, _ := h.DB.GetActivations(lic.ID)

	resp := map[string]interface{}{
		"license":     lic,
		"activations": activations,
	}
	writeJSON(w, http.StatusOK, resp)
}
