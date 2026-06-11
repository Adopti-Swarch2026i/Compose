#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$TESTS_DIR/results/p4}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
BASE_URL="${BASE_URL:-https://localhost}"
TARGET_REPLICA="${TARGET_REPLICA:-Adopti_pets_2}"
PETS_LB_CONTAINER="${PETS_LB_CONTAINER:-Adopti_pets_lb}"
FAILED=0
REPLICA_STOPPED=0

mkdir -p "$RESULTS_DIR"

setup_k6() {
    if command -v k6 >/dev/null 2>&1; then
        command -v k6
        return 0
    fi

    local k6_local="/tmp/k6"
    if [ -x "$k6_local" ]; then
        echo "$k6_local"
        return 0
    fi

    local arch k6_url
    arch="$(uname -m)"
    case "$arch" in
        x86_64) k6_url="https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-amd64.tar.gz" ;;
        aarch64|arm64) k6_url="https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-arm64.tar.gz" ;;
        *) echo "Unsupported architecture for k6 auto-install: $arch" >&2; exit 1 ;;
    esac

    echo "[setup] k6 not found. Downloading to /tmp/k6 ..." >&2
    curl -sL "$k6_url" | tar -xz -C /tmp --strip-components=1
    chmod +x "$k6_local"
    echo "$k6_local"
}

wait_for_gateway_health() {
    local attempts="${1:-30}"
    local delay="${2:-5}"
    local attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        if curl -sfk "$BASE_URL/health" >/dev/null 2>&1; then
            return 0
        fi
        echo "[wait] Gateway not healthy yet ($attempt/$attempts)."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    echo "[error] Gateway did not become healthy at $BASE_URL/health" >&2
    return 1
}

wait_for_container_healthy() {
    local container="$1"
    local attempts="${2:-30}"
    local delay="${3:-5}"
    local attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        local status
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            return 0
        fi
        echo "[wait] $container status=$status ($attempt/$attempts)."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    echo "[error] $container did not become healthy" >&2
    return 1
}

restore_replica() {
    if [ "$REPLICA_STOPPED" -eq 1 ]; then
        echo "[cleanup] Restarting $TARGET_REPLICA ..."
        docker start "$TARGET_REPLICA" >/dev/null 2>&1 || true
        wait_for_container_healthy "$TARGET_REPLICA" 30 5 || true
        REPLICA_STOPPED=0
    fi
}

trap restore_replica EXIT

capture_distribution() {
    local since="$1"
    local output_file="$2"

    {
        echo "P1 replica distribution"
        echo "Captured at: $(date -Iseconds)"
        echo "Since: $since"
        echo ""
        echo "Nginx stream upstream distribution ($PETS_LB_CONTAINER):"
        docker logs --since "$since" "$PETS_LB_CONTAINER" 2>&1 \
            | sed -n 's/.*"upstream_addr":"\([^"]*\)".*/\1/p' \
            | sort \
            | uniq -c \
            | sort -nr || true
        echo ""
        echo "Pets-service access log fallback:"
        for container in Adopti_pets_1 Adopti_pets_2 Adopti_pets_3; do
            local count
            count="$(docker logs --since "$since" "$container" 2>&1 | grep -c 'GET /api/pets' || true)"
            printf "%s %s\n" "$container" "$count"
        done
    } | tee "$output_file"
}

run_p1_k6() {
    local label="$1"
    local stdout_file="$RESULTS_DIR/${TIMESTAMP}_${label}_k6.txt"
    local summary_file="$RESULTS_DIR/${TIMESTAMP}_${label}_summary.json"
    local raw_file="$RESULTS_DIR/${TIMESTAMP}_${label}_raw.json"

    echo "[p1] Running $label: 300 VUs, 1200 requests, 30s maxDuration."
    set +e
    PERF_PROFILE=p1 \
    PERF_VUS="${PERF_VUS:-300}" \
    PERF_ITERATIONS="${PERF_ITERATIONS:-1200}" \
    PERF_MAX_DURATION="${PERF_MAX_DURATION:-30s}" \
    BASE_URL="$BASE_URL" \
    "$K6_BIN" run \
        --insecure-skip-tls-verify \
        --summary-export "$summary_file" \
        --out "json=$raw_file" \
        "$TESTS_DIR/perf/pets_load_test.js" 2>&1 | tee "$stdout_file"
    local status=${PIPESTATUS[0]}
    set -e
    echo "$status" > "$RESULTS_DIR/${TIMESTAMP}_${label}_exit_code.txt"
    if [ "$status" -ne 0 ]; then
        FAILED=1
    fi
}

cd "$COMPOSE_DIR"
K6_BIN="$(setup_k6)"

if [ "${SKIP_STACK_UP:-0}" != "1" ]; then
    echo "[infra] Starting Compose stack for P1 evidence ..."
    docker compose up -d --build
fi

wait_for_gateway_health

BASELINE_SINCE="$(date -Iseconds)"
run_p1_k6 "p1_load_balancer"
capture_distribution "$BASELINE_SINCE" "$RESULTS_DIR/${TIMESTAMP}_p1_replica_distribution.txt"

echo "[p1] Stopping $TARGET_REPLICA to validate failed-replica exclusion ..."
docker stop "$TARGET_REPLICA" >/dev/null
REPLICA_STOPPED=1
sleep "${LB_FAILOVER_SETTLE_SECONDS:-2}"

FAILOVER_SINCE="$(date -Iseconds)"
run_p1_k6 "p1_replica_down_exclusion"
capture_distribution "$FAILOVER_SINCE" "$RESULTS_DIR/${TIMESTAMP}_p1_replica_down_exclusion.txt"
restore_replica

{
    echo "P1 Load Balancer evidence manifest"
    echo "Timestamp: $TIMESTAMP"
    echo "Base URL: $BASE_URL"
    echo "Target replica stopped for exclusion test: $TARGET_REPLICA"
    echo "Expected scenario: 300 VUs / 1200 requests / 30s / p95 < 2s / 0% errors"
    echo ""
    ls -1 "$RESULTS_DIR/${TIMESTAMP}"* | sed 's/^/- /'
} > "$RESULTS_DIR/${TIMESTAMP}_p1_manifest.txt"

echo "[p1] Evidence written to $RESULTS_DIR"
exit "$FAILED"
