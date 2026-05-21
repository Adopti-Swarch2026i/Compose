#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Test Fase 1 — Chaos Engineering (requiere servicios corriendo)
# =============================================================================
# Experimentos controlados que validan propiedades de seguridad bajo estres.
# PRECONDICION: Docker Compose debe estar levantado.
# Ejecutar desde: Compose/
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

function run_test() {
    local name="$1"
    local expect_pass="$2"
    local cmd="$3"

    echo -n "  [TEST] $name ... "
    if eval "$cmd" >/dev/null 2>&1; then
        if [[ "$expect_pass" == "yes" ]]; then
            echo -e "${GREEN}PASS${NC}"
            PASS=$((PASS + 1))
        else
            echo -e "${RED}FAIL${NC} (esperaba fallo)"
            FAIL=$((FAIL + 1))
        fi
    else
        if [[ "$expect_pass" == "yes" ]]; then
            echo -e "${RED}FAIL${NC}"
            FAIL=$((FAIL + 1))
        else
            echo -e "${GREEN}PASS${NC}"
            PASS=$((PASS + 1))
        fi
    fi
}

function section() {
    echo ""
    echo -e "${BLUE}▶ $1${NC}"
}

function check_services_up() {
    if ! docker compose ps --format json 2>/dev/null | grep -q .; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=============================================="
echo "  Fase 1 — Tests de Caos (Chaos Engineering)"
echo "  (requiere servicios corriendo)"
echo "=============================================="

# Verificar precondicion
if ! check_services_up; then
    echo -e "${RED}ERROR: Docker Compose no esta corriendo.${NC}"
    echo "Ejecuta primero: docker compose up -d"
    exit 1
fi

# Esperar a que el gateway este listo
echo ""
echo "Esperando gateway..."
for i in {1..30}; do
    if curl -s -o /dev/null -k --max-time 2 "https://localhost/health" 2>/dev/null; then
        echo "Gateway responde."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo -e "${YELLOW}WARN: Gateway no responde a HTTPS, continuando...${NC}"
    fi
    sleep 1
done

# 1. Verificar puertos 5432, 5672, 9200 no responden desde host
section "Puertos internos cerrados al host"

run_test "Puerto 5432 (Postgres) no responde desde host" "no" \
    "nc -z -w 2 localhost 5432"

run_test "Puerto 5672 (RabbitMQ) no responde desde host" "no" \
    "nc -z -w 2 localhost 5672"

run_test "Puerto 9200 (Elasticsearch) no responde desde host" "no" \
    "nc -z -w 2 localhost 9200"

# 2. Verificar que logs no contienen secrets
section "Logs sin filtrado de secrets"

LOG_SNAPSHOT="/tmp/adopti_logs_chaos_$$.txt"
docker compose logs --no-color > "$LOG_SNAPSHOT" 2>&1 || true

SECRET_PATTERNS='password[=:][^$]|secret[=:][^$]|token[=:][^$]|bearer [a-zA-Z0-9]{10,}|basic [a-zA-Z0-9]{10,}|postgresql://[^[:space:]]+|amqp://[^[:space:]]+'
SECRET_COUNT=$(grep -iE "$SECRET_PATTERNS" "$LOG_SNAPSHOT" 2>/dev/null | grep -viE '__PLACEHOLDER__|__SET_|__.*__|missing|\$\{|\$\w' | wc -l || echo "0")

run_test "0 secretos filtrados en logs (encontrados: $SECRET_COUNT)" "no" \
    "test $SECRET_COUNT -gt 0"

rm -f "$LOG_SNAPSHOT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================================="

exit $FAIL
