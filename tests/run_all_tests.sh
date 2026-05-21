#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
#  run_all_tests.sh
#  Script maestro para ejecutar todos los tests del Plan P3 — Adopti
#  Incluye: baseline, k6 sin cache, k6 con cache, chaos test (kill Redis)
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/.."
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$RESULTS_DIR/${TIMESTAMP}_report.txt"

mkdir -p "$RESULTS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# 1. Setup k6 (descarga automática si no existe)
# ─────────────────────────────────────────────────────────────────────────────
setup_k6() {
    if command -v k6 >/dev/null 2>&1; then
        command -v k6
        return 0
    fi

    local K6_LOCAL="/tmp/k6"
    if [ -x "$K6_LOCAL" ]; then
        echo "$K6_LOCAL"
        return 0
    fi

    echo -e "${YELLOW}[setup] k6 no encontrado. Descargando a /tmp/k6 ...${NC}" >&2
    local ARCH
    ARCH=$(uname -m)
    local K6_URL=""
    case "$ARCH" in
        x86_64)
            K6_URL="https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-amd64.tar.gz"
            ;;
        aarch64|arm64)
            K6_URL="https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-arm64.tar.gz"
            ;;
        *)
            echo -e "${RED}ERROR: Arquitectura $ARCH no soportada para descarga automática.${NC}" >&2
            exit 1
            ;;
    esac

    if ! curl -sL "$K6_URL" | tar -xz -C /tmp --strip-components=1 2>/dev/null; then
        echo -e "${RED}ERROR: No se pudo descargar k6. Instálalo manualmente: https://k6.io/docs/get-started/installation/${NC}" >&2
        exit 1
    fi

    chmod +x "$K6_LOCAL"
    echo -e "${GREEN}[setup] k6 listo en $K6_LOCAL${NC}" >&2
    echo "$K6_LOCAL"
}

K6_BIN=$(setup_k6)

# ─────────────────────────────────────────────────────────────────────────────
# 2. Helpers
# ─────────────────────────────────────────────────────────────────────────────
extract_summary() {
    local LOGFILE=$1
    local LABEL=$2
    echo ""
    echo "  $LABEL"
    if [ -f "$LOGFILE" ]; then
        grep -E "http_req_duration|http_req_failed|http_reqs|checks|iteration_duration" "$LOGFILE" | sed 's/^/    /' || true
    else
        echo "    (log no encontrado)"
    fi
}

wait_for_gateway_health() {
    local max_attempts="${1:-24}"
    local sleep_seconds="${2:-5}"
    local attempt=1

    echo "[infra] Verificando gateway (intenta HTTPS primero, luego HTTP) ..."
    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -sfk https://localhost/health >/dev/null 2>&1; then
            export GATEWAY_BASE_URL="https://localhost"
            export GATEWAY_SCHEME="https"
            echo -e "${GREEN}[infra] Gateway responde OK en HTTPS (modo P3/main).${NC}"
            return 0
        fi
        if curl -sf http://localhost/health >/dev/null 2>&1; then
            export GATEWAY_BASE_URL="http://localhost"
            export GATEWAY_SCHEME="http"
            echo -e "${YELLOW}[VULN-V2] Gateway responde SOLO HTTP — TLS/Secure Channel NO está activo.${NC}"
            echo -e "${YELLOW}[VULN-V2] Esta es la vulnerabilidad que la versión main (P3) corrigió:${NC}"
            echo -e "${YELLOW}          - Tráfico cliente↔gateway viaja en texto plano (susceptible a MITM/sniffing).${NC}"
            echo -e "${YELLOW}          - Pattern aplicado en main: Secure Channel (TLS 1.2/1.3 en 443, mTLS interno).${NC}"
            echo -e "${YELLOW}[infra] Continuando suite con BASE_URL=http://localhost para exponer el resto de gaps.${NC}"
            return 0
        fi

        echo "[infra] Intento ${attempt}/${max_attempts}: gateway aun no responde (ni HTTPS ni HTTP). Reintentando en ${sleep_seconds}s ..."
        sleep "$sleep_seconds"
        attempt=$((attempt + 1))
    done

    echo -e "${RED}[error] Gateway no responde ni en HTTPS ni en HTTP.${NC}"
    echo "        Revisa: docker compose logs -f gateway"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Docker Compose reset + UP
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  PREPARACIÓN INFRAESTRUCTURA${NC}"
echo -e "${CYAN}==========================================${NC}"
cd "$COMPOSE_DIR"

echo "[infra] Bajando servicios previos con docker compose down ..."
docker compose down --remove-orphans || true

echo "[infra] Levantando servicios con docker compose up -d ..."
docker compose up -d

echo "[infra] Esperando a que el gateway quede disponible ..."
wait_for_gateway_health

# ─────────────────────────────────────────────────────────────────────────────
# 4. BASELINE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  1/4 - BASELINE VERIFICATION${NC}"
echo -e "${CYAN}==========================================${NC}"

set +e
bash "$SCRIPT_DIR/p3_baseline.sh" | tee "$RESULTS_DIR/${TIMESTAMP}_baseline.log"
BASELINE_STATUS=$?
set -e

# ─────────────────────────────────────────────────────────────────────────────
# 5. K6 SIN CACHE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  2/4 - K6 LOAD TEST (SIN CACHE)${NC}"
echo -e "${CYAN}==========================================${NC}"

echo "[test] Redis FLUSHALL ..."
docker exec Adopti_cache-queue redis-cli FLUSHALL >/dev/null 2>&1 || true

echo "[test] Reiniciando pets-service para limpiar singleflight/cache en memoria ..."
cd "$COMPOSE_DIR"
docker compose restart pets-service >/dev/null 2>&1

echo "[test] Esperando 20s a que pets-service vuelva a estar healthy ..."
sleep 20

K6_NO_CACHE_JSON="$RESULTS_DIR/${TIMESTAMP}_nocache.json"
K6_NO_CACHE_LOG="$RESULTS_DIR/${TIMESTAMP}_nocache.log"

set +e
PERF_PROFILE=nocache $K6_BIN run --insecure-skip-tls-verify --env "GATEWAY_BASE_URL=${GATEWAY_BASE_URL:-https://localhost}" --out "json=$K6_NO_CACHE_JSON" "$SCRIPT_DIR/perf/pets_load_test.js" | tee "$K6_NO_CACHE_LOG"
set -e

# ─────────────────────────────────────────────────────────────────────────────
# 6. K6 CON CACHE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  3/4 - K6 LOAD TEST (CON CACHE)${NC}"
echo -e "${CYAN}==========================================${NC}"

echo "[test] La cache ya está calentada por el test anterior."

K6_CACHE_JSON="$RESULTS_DIR/${TIMESTAMP}_cache.json"
K6_CACHE_LOG="$RESULTS_DIR/${TIMESTAMP}_cache.log"

set +e
PERF_PROFILE=cache $K6_BIN run --insecure-skip-tls-verify --env "GATEWAY_BASE_URL=${GATEWAY_BASE_URL:-https://localhost}" --out "json=$K6_CACHE_JSON" "$SCRIPT_DIR/perf/pets_load_test.js" | tee "$K6_CACHE_LOG"
set -e

# ─────────────────────────────────────────────────────────────────────────────
# 7. CHAOS TEST
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  4/4 - CHAOS TEST (Kill Redis)${NC}"
echo -e "${CYAN}==========================================${NC}"

K6_CHAOS_JSON="$RESULTS_DIR/${TIMESTAMP}_chaos.json"
K6_CHAOS_LOG="$RESULTS_DIR/${TIMESTAMP}_chaos.log"

echo "[chaos] Iniciando k6 en background ..."
set +e
PERF_PROFILE=chaos $K6_BIN run --insecure-skip-tls-verify --env "GATEWAY_BASE_URL=${GATEWAY_BASE_URL:-https://localhost}" --out "json=$K6_CHAOS_JSON" "$SCRIPT_DIR/perf/pets_load_test.js" > "$K6_CHAOS_LOG" 2>&1 &
K6_PID=$!

echo "[chaos] Warming up 30s ..."
sleep 30

echo "[chaos] Matando Redis (Adopti_cache-queue) ..."
docker stop Adopti_cache-queue >/dev/null 2>&1 || true

echo "[chaos] Redis abajo, esperando 60s ..."
sleep 60

echo "[chaos] Reviviendo Redis ..."
docker start Adopti_cache-queue >/dev/null 2>&1 || true
echo "[chaos] Esperando 15s a que Redis arranque ..."
sleep 15

echo "[chaos] Esperando a que k6 termine ..."
wait $K6_PID || true
echo -e "${GREEN}[chaos] Finalizado.${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# 8. REPORTE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  GENERANDO REPORTE${NC}"
echo -e "${CYAN}==========================================${NC}"

{
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  Plan P3 — Resultados de Tests"
    echo "  Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Modo:  ${GATEWAY_SCHEME:-?} (BASE_URL=${GATEWAY_BASE_URL:-?})"
    if [ "${GATEWAY_SCHEME:-}" = "http" ]; then
        echo "  >> Ejecución en rama V2 (P2 baseline). Los FAILs documentan las"
        echo "     vulnerabilidades que la rama main (P3) corrige: Secure Channel,"
        echo "     Network Segmentation, Reverse Proxy y Rate Limiting."
    fi
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "1. BASELINE VERIFICATION"
    if [ $BASELINE_STATUS -eq 0 ]; then
        echo "   Estado: ✅ PASSED"
    else
        echo "   Estado: ❌ FAILED"
    fi
    echo ""
    echo "2. K6 LOAD TEST — SIN CACHE"
    echo "   JSON: $K6_NO_CACHE_JSON"
    echo "   LOG:  $K6_NO_CACHE_LOG"
    extract_summary "$K6_NO_CACHE_LOG" "Resumen métricas:"
    echo ""
    echo "3. K6 LOAD TEST — CON CACHE"
    echo "   JSON: $K6_CACHE_JSON"
    echo "   LOG:  $K6_CACHE_LOG"
    extract_summary "$K6_CACHE_LOG" "Resumen métricas:"
    echo ""
    echo "4. CHAOS TEST (Redis kill)"
    echo "   JSON: $K6_CHAOS_JSON"
    echo "   LOG:  $K6_CHAOS_LOG"
    extract_summary "$K6_CHAOS_LOG" "Resumen métricas:"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  INSTRUCCIONES PARA DOCUMENTO"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  Copia los valores numéricos de arriba (p95, p99, avg, error rate)"
    echo "  y péguelos en p3_1a.md reemplazando los placeholders [EJECUTAR]."
    echo "═══════════════════════════════════════════════════════════════════════════════"
} > "$REPORT_FILE"

cat "$REPORT_FILE"

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  ✅ TODOS LOS TESTS FINALIZADOS${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Archivos generados en: $RESULTS_DIR"
ls -lh "$RESULTS_DIR/${TIMESTAMP}"*
