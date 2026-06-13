#!/bin/bash
# Quick Benchmark Script for AgentGate
# Runs a short benchmark with timeout protection

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== AgentGate Quick Benchmark ==="
echo ""

# Kill any existing server
pkill -9 -f agent-gate 2>/dev/null || true
sleep 1

# Start server
echo "Starting server..."
JWT_SECRET="agent-gate-default-secret-32bytes!" ./zig-out/bin/agent-gate &
SERVER_PID=$!

# Wait for server
sleep 2

# Verify server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start"
    exit 1
fi

echo "Server PID: $SERVER_PID"
echo ""

# Run curl tests
echo "=== Connectivity Test ==="
echo "GET /health:"
curl -s --max-time 5 http://127.0.0.1:8080/health
echo ""
echo ""
echo "GET /v1/agents:"
curl -s --max-time 5 http://127.0.0.1:8080/v1/agents
echo ""
echo ""

# Run benchmark
echo "=== Running Loadtest Benchmark ==="
timeout 30 ./zig-out/bin/loadtest --workers 5 --requests 100 --no-spawn || echo "(loadtest timed out or failed)"

# Cleanup
echo ""
echo "Stopping server..."
kill -9 $SERVER_PID 2>/dev/null || true

echo ""
echo "=== Benchmark Complete ==="