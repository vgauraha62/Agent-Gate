#!/bin/bash
# AgentGate Benchmark Script
# Runs performance benchmarks against the AgentGate server

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== AgentGate Benchmark Runner ==="
echo ""

# Configuration
HOST="127.0.0.1"
PORT=8080
JWT_SECRET="agent-gate-default-secret-32bytes!"

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    if [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill any existing server
echo "Killing any existing server..."
pkill -9 -f agent-gate 2>/dev/null || true
sleep 1

# Build if needed
if [ ! -f ./zig-out/bin/agent-gate ]; then
    echo "Building server..."
    zig build -Doptimize=ReleaseFast
fi

if [ ! -f ./zig-out/bin/loadtest ]; then
    echo "Building loadtest..."
    zig build benchmark -Doptimize=ReleaseFast
fi

# Start server
echo "Starting server on port $PORT..."
JWT_SECRET="$JWT_SECRET" ./zig-out/bin/agent-gate &
SERVER_PID=$!
export JWT_SECRET

# Wait for server to start
echo "Waiting for server to be ready..."
for i in {1..10}; do
    if curl -s -o /dev/null http://$HOST:$PORT/v1/agents 2>/dev/null; then
        echo "Server is ready!"
        break
    fi
    sleep 1
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server died! Check logs."
        exit 1
    fi
done

echo ""
echo "=== Running Baseline Benchmark ==="
echo "Target: http://$HOST:$PORT"
echo "Workers: 10, Requests: 1000"
echo ""

# Run loadtest
./zig-out/bin/loadtest --workers 10 --requests 1000 --no-spawn 2>&1

echo ""
echo "=== Benchmark Complete ==="