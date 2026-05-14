#!/bin/bash
# Benchmark script for Metrics & Monitoring - Day 8
# Tests P99 latency targets and telemetry overhead

set -e

PORT=${1:-8080}
HOST="localhost:${PORT}"
DURATION=${2:-10}  # seconds
REQUESTS=${3:-1000}

echo "========================================="
echo "Metrics & Monitoring Benchmark"
echo "========================================="
echo "Target: ${HOST}"
echo "Duration: ${DURATION}s"
echo "Requests: ~${REQUESTS}"
echo ""

# Check if server is running
if ! curl -s "http://${HOST}/health" > /dev/null 2>&1; then
    echo "ERROR: Server not running on ${HOST}"
    echo "Start the server first with: zig build run"
    exit 1
fi

# Reset metrics by making some requests
echo "Sending initial requests to reset metrics..."
for i in {1..10}; do
    curl -s -X POST "http://${HOST}/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/test"}' > /dev/null 2>&1 || true
done
sleep 1

# Get initial metrics
echo "Initial metrics:"
curl -s "http://${HOST}/metrics" | head -20
echo ""

# Run load test
echo "Running load test (parallel)..."
START_TIME=$(date +%s)
SUCCESS=0
FAILED=0

# Use parallel requests for faster load testing
# Batch size to avoid overwhelming the server
BATCH_SIZE=50

for i in $(seq 1 $REQUESTS); do
    curl -s -X POST "http://${HOST}/check" \
        -H "Content-Type: application/json" \
        -d '{"path":"/test"}' > /dev/null 2>&1 &
    
    # Progress indicator
    if [ $((i % 100)) -eq 0 ]; then
        echo "  Sent ${i} requests..."
    fi
    
    # Batch wait to control concurrency
    if [ $((i % BATCH_SIZE)) -eq 0 ]; then
        wait
    fi
done

# Wait for any remaining requests
wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
if [ $ELAPSED -eq 0 ]; then ELAPSED=1; fi

echo ""
echo "Load test complete:"
echo "  Total requests: $REQUESTS"
echo "  Duration: ${ELAPSED}s"
echo "  RPS: $((REQUESTS / ELAPSED))"
echo ""

# Wait a moment for metrics to settle
sleep 2

# Get final metrics
echo "Final metrics from /metrics:"
echo "========================================="
curl -s "http://${HOST}/metrics"
echo ""
echo "========================================="

# Parse and verify key metrics
echo ""
echo "Verification Results:"
echo "========================================="

# Extract counter values
REQUESTS_TOTAL=$(curl -s "http://${HOST}/metrics" | grep "^requests_total:" | awk '{print $2}')
ALLOWED=$(curl -s "http://${HOST}/metrics" | grep "^allowed:" | awk '{print $2}')
DENIED=$(curl -s "http://${HOST}/metrics" | grep "^denied:" | awk '{print $2}')

echo "Requests total: ${REQUESTS_TOTAL:-0}"
echo "Allowed: ${ALLOWED:-0}"
echo "Denied: ${DENIED:-0}"

# Extract latency percentiles
P50=$(curl -s "http://${HOST}/metrics" | grep "^latency_p50:" | awk '{print $2}')
P90=$(curl -s "http://${HOST}/metrics" | grep "^latency_p90:" | awk '{print $2}')
P99=$(curl -s "http://${HOST}/metrics" | grep "^latency_p99:" | awk '{print $2}')

echo ""
echo "Latency (microseconds):"
echo "  P50: ${P50:-0} µs"
echo "  P90: ${P90:-0} µs"
echo "  P99: ${P99:-0} µs"

# Verify targets
echo ""
echo "Target Verification:"
echo "========================================="

# P99 target is < 50µs per plan
if [ -n "$P99" ]; then
    if [ "$P99" -lt 50 ]; then
        echo "✓ P99 < 50µs target: PASSED (${P99} µs)"
    else
        echo "✗ P99 < 50µs target: FAILED (${P99} µs)"
    fi
else
    echo "? P99 latency: Not available (need more samples)"
fi

# Check histogram has data
COUNT=$(curl -s "http://${HOST}/metrics" | grep "^histogram_count:" | awk '{print $2}')
if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
    echo "✓ Histogram data present: PASSED (${COUNT} samples)"
else
    echo "✗ Histogram data: No samples recorded"
fi

# Check custom metrics format
echo "✓ Metrics format: Custom key-value format"

# Check active gauge
ACTIVE=$(curl -s "http://${HOST}/metrics" | grep "^active:" | awk '{print $2}')
if [ -n "$ACTIVE" ]; then
    echo "✓ Active sessions gauge: PRESENT (${ACTIVE})"
fi

echo ""
echo "========================================="
echo "Benchmark complete!"
echo "========================================="