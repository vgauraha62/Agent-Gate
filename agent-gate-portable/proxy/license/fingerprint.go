package license

import (
	"crypto/sha256"
	"fmt"
	"net"
	"os"
	"strings"
)

// MachineFingerprint computes a stable identifier for the host machine.
// It combines the first non-loopback MAC address, the hostname, and
// /etc/machine-id (if present) into a SHA-256 hash.
//
// This is used to bind a license activation to a specific machine,
// preventing license key sharing across different hosts.
func MachineFingerprint() string {
	h := sha256.New()
	h.Write([]byte(macAddress()))
	h.Write([]byte(hostname()))
	h.Write([]byte(machineID()))
	return fmt.Sprintf("%x", h.Sum(nil))
}

// macAddress returns the first non-loopback MAC address.
func macAddress() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return "unknown-mac"
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		if len(iface.HardwareAddr) == 0 {
			continue
		}
		return iface.HardwareAddr.String()
	}
	return "unknown-mac"
}

// hostname returns the system hostname.
func hostname() string {
	n, err := os.Hostname()
	if err != nil {
		return "unknown-host"
	}
	return n
}

// machineID reads /etc/machine-id (Linux) or /var/lib/dbus/machine-id.
func machineID() string {
	for _, path := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		data, err := os.ReadFile(path)
		if err == nil {
			return strings.TrimSpace(string(data))
		}
	}
	return "unknown-machine-id"
}
