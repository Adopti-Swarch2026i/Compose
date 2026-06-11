#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$TESTS_DIR/results/p4}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
BASE_URL="${BASE_URL:-https://localhost}"
REDIS_CONTAINER="${REDIS_CONTAINER:-Adopti_cache-queue}"
FAILED=0

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

restore_cache_mode() {
    export PETS_CACHE_ENABLED=true
    docker start "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    docker compose up -d --force-recreate --no-deps pets-service-1 pets-service-2 pets-service-3 pets-lb >/dev/null 2>&1 || true
}

trap restore_cache_mode EXIT

set_cache_mode() {
    local enabled="$1"
    export PETS_CACHE_ENABLED="$enabled"
    export PETS_REDIS_URL="${PETS_REDIS_URL:-redis://redis:6379/0}"

    echo "[p2] Recreating pets-service replicas with CACHE_ENABLED=$PETS_CACHE_ENABLED ..."
    docker compose up -d --force-recreate --no-deps pets-service-1 pets-service-2 pets-service-3 >/dev/null
    wait_for_container_healthy Adopti_pets_1
    wait_for_container_healthy Adopti_pets_2
    wait_for_container_healthy Adopti_pets_3

    echo "[p2] Recreating pets-lb so static upstream DNS resolves current replica IPs ..."
    docker compose up -d --force-recreate --no-deps pets-lb >/dev/null
    wait_for_container_healthy Adopti_pets_lb
    wait_for_gateway_health
}

redis_snapshot() {
    local label="$1"
    local output_file="$RESULTS_DIR/${TIMESTAMP}_${label}_redis_snapshot.txt"
    {
        echo "Redis snapshot: $label"
        echo "Captured at: $(date -Iseconds)"
        echo ""
        echo "PING:"
        docker exec "$REDIS_CONTAINER" redis-cli PING || true
        echo ""
        echo "pets:* key count:"
        docker exec "$REDIS_CONTAINER" sh -c "redis-cli --scan --pattern 'pets:*' | wc -l" || true
        echo ""
        echo "INFO stats:"
        docker exec "$REDIS_CONTAINER" redis-cli INFO stats | grep -E 'keyspace_hits|keyspace_misses|expired_keys|evicted_keys|total_commands_processed' || true
    } | tee "$output_file"
}

flush_redis() {
    echo "[p2] Redis FLUSHALL ..."
    docker exec "$REDIS_CONTAINER" redis-cli FLUSHALL >/dev/null
}

warm_cache() {
    local requests="${CACHE_WARM_REQUESTS:-20}"
    echo "[p2] Warming cache with $requests GET requests ..."
    for _ in $(seq 1 "$requests"); do
        curl -sfk "$BASE_URL/api/pets?page=1&page_size=20" >/dev/null || true
    done
}

run_k6_profile() {
    local profile="$1"
    local label="$2"
    local stdout_file="$RESULTS_DIR/${TIMESTAMP}_${label}_k6.txt"
    local summary_file="$RESULTS_DIR/${TIMESTAMP}_${label}_summary.json"
    local raw_file="$RESULTS_DIR/${TIMESTAMP}_${label}_raw.json"

    echo "[p2] Running $label with PERF_PROFILE=$profile ..."
    set +e
    PERF_PROFILE="$profile" \
    PERF_VUS="${P2_PERF_VUS:-20}" \
    PERF_RAMP_UP="${P2_RAMP_UP:-10s}" \
    PERF_STEADY="${P2_STEADY:-30s}" \
    PERF_RAMP_DOWN="${P2_RAMP_DOWN:-10s}" \
    PERF_SLEEP_SECONDS="${P2_SLEEP_SECONDS:-0.5}" \
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

run_redis_chaos() {
    local label="p2_redis_chaos"
    local stdout_file="$RESULTS_DIR/${TIMESTAMP}_${label}_k6.txt"
    local summary_file="$RESULTS_DIR/${TIMESTAMP}_${label}_summary.json"
    local raw_file="$RESULTS_DIR/${TIMESTAMP}_${label}_raw.json"

    echo "[p2] Starting chaos k6 run ..."
    set +e
    PERF_PROFILE=chaos \
    PERF_VUS="${P2_CHAOS_VUS:-20}" \
    PERF_RAMP_UP="${P2_CHAOS_RAMP_UP:-10s}" \
    PERF_STEADY="${P2_CHAOS_STEADY:-30s}" \
    PERF_RAMP_DOWN="${P2_CHAOS_RAMP_DOWN:-10s}" \
    PERF_SLEEP_SECONDS="${P2_SLEEP_SECONDS:-0.5}" \
    BASE_URL="$BASE_URL" \
    "$K6_BIN" run \
        --insecure-skip-tls-verify \
        --summary-export "$summary_file" \
        --out "json=$raw_file" \
        "$TESTS_DIR/perf/pets_load_test.js" > "$stdout_file" 2>&1 &
    local k6_pid=$!
    set -e

    sleep "${REDIS_CHAOS_WARMUP_SECONDS:-10}"
    echo "[p2] Stopping Redis ($REDIS_CONTAINER) ..." | tee -a "$stdout_file"
    docker stop "$REDIS_CONTAINER" >/dev/null || true

    sleep "${REDIS_CHAOS_DOWN_SECONDS:-15}"
    echo "[p2] Restarting Redis ($REDIS_CONTAINER) ..." | tee -a "$stdout_file"
    docker start "$REDIS_CONTAINER" >/dev/null || true
    wait_for_container_healthy "$REDIS_CONTAINER" 20 3 || true

    set +e
    wait "$k6_pid"
    local status=$?
    set -e
    echo "$status" > "$RESULTS_DIR/${TIMESTAMP}_${label}_exit_code.txt"
    if [ "$status" -ne 0 ]; then
        FAILED=1
    fi
}

cd "$COMPOSE_DIR"
K6_BIN="$(setup_k6)"

if [ "${SKIP_STACK_UP:-0}" != "1" ]; then
    echo "[infra] Starting Compose stack for P2 evidence ..."
    docker compose up -d --build
fi

wait_for_gateway_health
wait_for_container_healthy "$REDIS_CONTAINER"

set_cache_mode false
flush_redis
redis_snapshot "p2_nocache_before"
run_k6_profile "nocache" "p2_nocache"
redis_snapshot "p2_nocache_after"

set_cache_mode true
flush_redis
redis_snapshot "p2_cache_before"
warm_cache
redis_snapshot "p2_cache_after_warmup"
run_k6_profile "cache" "p2_cache"
redis_snapshot "p2_cache_after"

flush_redis
warm_cache
redis_snapshot "p2_redis_chaos_before"
run_redis_chaos
redis_snapshot "p2_redis_chaos_after"

{
    echo "P2 Cache-Aside Redis evidence manifest"
    echo "Timestamp: $TIMESTAMP"
    echo "Base URL: $BASE_URL"
    echo "Redis container: $REDIS_CONTAINER"
    echo "No-cache phase uses CACHE_ENABLED=false."
    echo "Cache phase uses CACHE_ENABLED=true and Redis URL ${PETS_REDIS_URL:-redis://redis:6379/0}."
    echo "Chaos phase stops Redis during load and expects graceful degradation."
    echo ""
    ls -1 "$RESULTS_DIR/${TIMESTAMP}"* | sed 's/^/- /'
} > "$RESULTS_DIR/${TIMESTAMP}_p2_manifest.txt"

echo "[p2] Evidence written to $RESULTS_DIR"
exit "$FAILED"
