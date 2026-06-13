#!/bin/bash
# AgentGate Quick Benchmark using Apache Bench (ab)
# Uses ab for quick HTTP load testing

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== AgentGate Quick Benchmark ==="
echo ""

# Configuration
HOST="127.0.0.1"
PORT=8080
JWT_SECRET="agent-gate-default-secret-32bytes!"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [ -n "$SERVER_PID" ]; then
        kill -9 $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Kill any existing server
echo "Killing any existing server..."
pkill -9 -f agent-gate 2>/dev/null || true
sleep 1

# Build if needed
echo "Building server..."
zig build -Doptimize=ReleaseSafe 2>/dev/null

# Start server
echo "Starting server on port $PORT..."
JWT_SECRET="$JWT_SECRET" ./zig-out/bin/agent-gate &
SERVER_PID=$!
export JWT_SECRET

# Wait for server to start
echo "Waiting for server to be ready..."
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Server failed to start!"
    exit 1
fi

echo "Server PID: $SERVER_PID"
echo ""

# Test with curl first
echo "=== Connectivity Test ==="
RESPONSE=$(curl -s -w "\n%{http_code}" http://$HOST:$PORT/v1/agents 2>/dev/null)
echo "Response: $RESPONSE"
echo ""

# Run ab benchmark
echo "=== Running Apache Bench Benchmark ==="
echo "Target: http://$HOST:$PORT/v1/agents"
echo "Concurrency: 10, Total requests: 1000"
echo ""

ab -n 1000 -c 10 -H "Authorization: Bearer test-token" http://$HOST:$PORT/v1/agents 2>&1

echo ""
echo "=== Quick Benchmark Complete ==="