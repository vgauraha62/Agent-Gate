#!/bin/bash
# Simple benchmark runner script for AgentGate

set -e

# Kill any existing server
pkill -9 -f agent-gate 2>/dev/null || true
sleep 1

# Set JWT secret
export JWT_SECRET="agent-gate-default-secret-32bytes!"

# Start server
./zig-out/bin/agent-gate &
SERVER_PID=$!
echo "Server started with PID: $SERVER_PID"

# Wait for server to start
sleep 3

# Test connectivity
echo "Testing connectivity..."
curl -s -w "\nHTTP_CODE:%{http_code}\n" http://127.0.0.1:8080/v1/agents || echo "Server not responding"

# Run simple loadtest
echo "Running loadtest..."
timeout 30 ./zig-out/bin/loadtest --workers 2 --requests 100 --no-spawn || echo "Loadtest failed"

# Cleanup
echo "Stopping server..."
kill $SERVER_PID 2>/dev/null || true
sleep 1

echo "Benchmark complete!"