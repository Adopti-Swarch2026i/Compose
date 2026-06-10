#!/usr/bin/env bash
# =============================================================================
# test_gateway_active_redundancy.sh — Adopti API Gateway failover validation
#
# Validates the P4 Active Redundancy scenario for the NGINX API Gateway:
# two active gateway nodes behind the public reverse proxy, no visible outage,
# failover under 1 second, and no user-visible state loss for stateless routing.
#
# Usage:
#   cd AdoptiFinal/Compose
#   bash scripts/test_gateway_active_redundancy.sh
# =============================================================================
set -euo pipefail

URL="${URL:-https://localhost/api/pets?page=1&page_size=5}"
TARGET_CONTAINER="${TARGET_CONTAINER:-Adopti_gateway_1}"
SURVIVOR_CONTAINER="${SURVIVOR_CONTAINER:-Adopti_gateway_2}"
MAX_FAILOVER_MS="${MAX_FAILOVER_MS:-1000}"
REQUESTS_AFTER_FAILURE="${REQUESTS_AFTER_FAILURE:-20}"
SLEEP_BETWEEN_REQUESTS="${SLEEP_BETWEEN_REQUESTS:-0.05}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

fail() {
    echo -e "${RED}[FAIL]${NC} $*" >&2
    exit 1
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

container_health() {
    docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || true
}

request_code() {
    curl -sk --connect-timeout 1 --max-time 3 -o /dev/null -w '%{http_code}' "$URL" || true
}

restore_gateway() {
    docker start "$TARGET_CONTAINER" >/dev/null 2>&1 || true
}
trap restore_gateway EXIT

echo ""
echo -e "${BOLD}Adopti — Gateway Active Redundancy Validation${NC}"
echo "URL: $URL"
echo "Fault target: $TARGET_CONTAINER"
echo "Survivor: $SURVIVOR_CONTAINER"
echo ""

for container in "$TARGET_CONTAINER" "$SURVIVOR_CONTAINER" Adopti_reverse_proxy; do
    health="$(container_health "$container")"
    [ "$health" = "healthy" ] || fail "$container is not healthy (state: ${health:-missing})"
done

info "Warm-up request through public reverse proxy"
code="$(request_code)"
[ "$code" = "200" ] || fail "warm-up expected HTTP 200, got HTTP $code"
pass "public endpoint is reachable before failure"

info "Stopping $TARGET_CONTAINER to simulate gateway crash"
failure_started_ms="$(date +%s%3N)"
docker stop -t 1 "$TARGET_CONTAINER" >/dev/null

first_success_ms=""
errors=0

for _ in $(seq 1 "$REQUESTS_AFTER_FAILURE"); do
    now_ms="$(date +%s%3N)"
    code="$(request_code)"
    if [ "$code" = "200" ]; then
        if [ -z "$first_success_ms" ]; then
            first_success_ms="$now_ms"
        fi
    else
        errors=$((errors + 1))
        echo -e "${YELLOW}[WARN]${NC} request returned HTTP ${code:-000}"
    fi
    sleep "$SLEEP_BETWEEN_REQUESTS"
done

[ -n "$first_success_ms" ] || fail "no successful request after gateway failure"

failover_ms=$((first_success_ms - failure_started_ms))
info "Observed failover time: ${failover_ms} ms"
info "User-visible failed requests after failure: $errors"

[ "$failover_ms" -le "$MAX_FAILOVER_MS" ] || \
    fail "failover exceeded ${MAX_FAILOVER_MS} ms"

[ "$errors" -eq 0 ] || \
    fail "expected 0 visible request failures, got $errors"

pass "gateway failover stayed within ${MAX_FAILOVER_MS} ms with 0 visible request failures"

info "Restoring $TARGET_CONTAINER"
restore_gateway
pass "validation complete"
