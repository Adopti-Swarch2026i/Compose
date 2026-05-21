#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K6_OUT="/tmp/chaos_k6.json"
CONTAINER_NAME="Adopti_cache-queue"

echo "[chaos] Starting k6 load test in background..."
k6 run --out "json=$K6_OUT" "$PROJECT_DIR/Compose/tests/perf/pets_load_test.js" &
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

echo "[chaos] Done."
