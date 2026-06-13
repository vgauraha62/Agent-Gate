package main

import (
	"log"
	"net/http"
	"os"

	"github.com/agentgate/license-server/internal"
)

func main() {
	// ── Configuration from environment ────────────────────────────────────
	listen := getEnv("LISTEN", ":4001")
	dbPath := getEnv("DB_PATH", "/var/lib/agentgate/license.db")
	privateKeyPath := getEnv("PRIVATE_KEY", "/etc/agentgate/private.pem")
	adminKey := getEnv("ADMIN_API_KEY", "change-me")

	// ── Load RSA private key ──────────────────────────────────────────────
	privateKeyPEM, err := os.ReadFile(privateKeyPath)
	if err != nil {
		log.Fatalf("Failed to read private key (%s): %v", privateKeyPath, err)
	}
	signer, err := internal.NewSigner(privateKeyPEM)
	if err != nil {
		log.Fatalf("Failed to load private key: %v", err)
	}

	// ── Open database ─────────────────────────────────────────────────────
	db, err := internal.OpenDB(dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	// ── Handlers ──────────────────────────────────────────────────────────
	licenseHandler := &internal.LicenseHandler{DB: db, Signer: signer}
	adminHandler := &internal.AdminHandler{
		DB:       db,
		Signer:   signer,
		AdminKey: adminKey,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", licenseHandler.Health)

	// License API
	mux.HandleFunc("/api/v1/license/activate", licenseHandler.Activate)
	mux.HandleFunc("/api/v1/license/validate", licenseHandler.Validate)

	// Admin API
	mux.HandleFunc("/admin/licenses", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			adminHandler.ListLicenses(w, r)
		case http.MethodPost:
			adminHandler.CreateLicense(w, r)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/admin/licenses/", func(w http.ResponseWriter, r *http.Request) {
		// Match /admin/licenses/{key} or /admin/licenses/{key}/revoke
		switch r.Method {
		case http.MethodGet:
			adminHandler.GetLicenseDetail(w, r)
		case http.MethodPost:
			adminHandler.RevokeLicense(w, r)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	// ── Start server ──────────────────────────────────────────────────────
	log.Printf("License Server starting on %s", listen)
	log.Printf("  DB path: %s", dbPath)
	log.Printf("  Admin API: enabled (use X-Admin-Key header)")

	if err := http.ListenAndServe(listen, withLogging(mux)); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}
