#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$PROJECT_DIR/Compose/tests/results/p4}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
K6_OUT="${K6_OUT:-$RESULTS_DIR/${TIMESTAMP}_p2_redis_chaos_raw.json}"
K6_LOG="${K6_LOG:-$RESULTS_DIR/${TIMESTAMP}_p2_redis_chaos_k6.txt}"
CONTAINER_NAME="${CONTAINER_NAME:-Adopti_cache-queue}"

mkdir -p "$RESULTS_DIR"

echo "[chaos] Starting k6 load test in background..."
PERF_PROFILE="${PERF_PROFILE:-chaos}" \
k6 run --insecure-skip-tls-verify --out "json=$K6_OUT" "$PROJECT_DIR/Compose/tests/perf/pets_load_test.js" > "$K6_LOG" 2>&1 &
K6_PID=$!

echo "[chaos] Warming up for 30s..."
sleep 30

echo "[chaos] Killing Redis container ($CONTAINER_NAME)..."
docker stop "$CONTAINER_NAME" || true

echo "[chaos] Redis is down, waiting 60s..."
sleep 60

echo "[chaos] Restarting Redis container ($CONTAINER_NAME)..."
docker start "$CONTAINER_NAME" || true

echo "[chaos] Waiting for k6 to finish..."
wait $K6_PID || true

echo "[chaos] Metrics summary:"
if command -v jq >/dev/null 2>&1; then
    echo "  Overall p95 latency:"
    jq -r '
      select(.metric == "http_req_duration" and .type == "Point")
      | .data.value
    ' "$K6_OUT" | jq -s 'sort | if length > 0 then .[(length*0.95|floor)] else "N/A" end'
else
    echo "  jq not found; raw data saved to $K6_OUT"
fi

echo "[chaos] k6 stdout saved to $K6_LOG"
echo "[chaos] Done."
