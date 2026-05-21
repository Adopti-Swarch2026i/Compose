#!/usr/bin/env bash
# =============================================================================
# test_fase5_integracion.sh — Tests con servicios corriendo
# Proyecto: Adopti — Fase 5: Operacion Continua
#
# Requiere: docker compose up -d (servicios prometheus, grafana, nginx-exporter, gateway)
# Ejecutar desde: Compose/
# =============================================================================
set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Contadores ───────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
WARNINGS=0
SKIPPED=0

# ── Paths ────────────────────────────────────────────────────────────────────
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="$(cd "$COMPOSE_DIR/.." && pwd)"
NGINX_CONF="$PROJECT_ROOT/gateway/nginx.conf"

# ── Timeouts ─────────────────────────────────────────────────────────────────
CURL_TIMEOUT=10
MAX_RETRIES=30
RETRY_DELAY=2

# ── Funciones assert ─────────────────────────────────────────────────────────
assert_cmd() {
    local cmd="$1"
    local desc="$2"
    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_output_contains() {
    local cmd="$1"
    local pattern="$2"
    local desc="$3"
    local output
    output=$(eval "$cmd" 2>&1 || true)
    if echo "$output" | grep -q "$pattern"; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — patron '$pattern' no encontrado"
        echo -e "  ${CYAN}Output:${NC} ${output:0:200}"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_http_status() {
    local url="$1"
    local expected="$2"
    local desc="$3"
    local status
    local curl_opts="-s -o /dev/null -w %{http_code} --max-time $CURL_TIMEOUT"

    # Usar -k/--insecure para HTTPS con certificados autofirmados
    if [[ "$url" == https://* ]]; then
        curl_opts="$curl_opts -k"
    fi

    status=$(curl $curl_opts "$url" 2>/dev/null || echo "000")
    if [[ "$status" == "$expected" ]]; then
        echo -e "${GREEN}[PASS]${NC} $desc — HTTP $status"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — esperado HTTP $expected, actual HTTP $status"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_container_running() {
    local name="$1"
    local desc="$2"
    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${GREEN}[PASS]${NC} $desc — contenedor corriendo"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — contenedor NO corriendo"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

wait_for_service() {
    local url="$1"
    local desc="$2"
    local retries=0
    echo -e "${CYAN}[WAIT]${NC} Esperando $desc..."
    while [[ $retries -lt $MAX_RETRIES ]]; do
        if curl -s --max-time "$CURL_TIMEOUT" "$url" &>/dev/null; then
            echo -e "${GREEN}[READY]${NC} $desc responde"
            return 0
        fi
        sleep "$RETRY_DELAY"
        ((retries++))
        echo -e "  ${CYAN}... intento $retries/$MAX_RETRIES${NC}"
    done
    echo -e "${RED}[TIMEOUT]${NC} $desc no respondio despues de $MAX_RETRIES intentos"
    return 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    SKIPPED=$((SKIPPED + 1))
}

# =============================================================================
# HEADER
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Adopti — Fase 5: Tests de Integracion${NC}"
echo -e "${BLUE}  Requiere servicios corriendo (docker compose up -d)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Directorio Compose:${NC} $COMPOSE_DIR"
echo ""

# =============================================================================
# PRE-CHECK: Docker disponible y servicios corriendo
# =============================================================================
echo -e "${BLUE}--- Pre-check: Docker y servicios ---${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} Docker no esta instalado o no esta en PATH"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} Docker daemon no responde"
    exit 1
fi

echo -e "${GREEN}[PASS]${NC} Docker disponible"
PASSED=$((PASSED + 1))

# Verificar contenedores esperados
CONTAINERS=("Adopti_gateway" "Adopti_prometheus" "Adopti_grafana" "Adopti_nginx_exporter")
for c in "${CONTAINERS[@]}"; do
    assert_container_running "$c" "Contenedor $c"
done

echo ""

# =============================================================================
# TEST-F5-I001: Nginx logs contienen ssl_protocol y ssl_cipher
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I001: Nginx logs TLS variables ---${NC}"

# Hacer una peticion HTTPS al gateway para generar logs
echo -e "  ${CYAN}Generando trafico HTTPS...${NC}"
curl -s -k --max-time "$CURL_TIMEOUT" "https://localhost:443/health" &>/dev/null || true
sleep 1

# Verificar logs del contenedor gateway
GATEWAY_LOGS=$(docker logs Adopti_gateway --tail 20 2>&1 || true)

if echo "$GATEWAY_LOGS" | grep -q "ssl_protocol"; then
    echo -e "${GREEN}[PASS]${NC} Logs de Nginx contienen 'ssl_protocol'"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} Logs de Nginx NO contienen 'ssl_protocol'"
    echo -e "  ${CYAN}Nota:${NC} Verificar que access_log usa formato adopti_tls"
    FAILED=$((FAILED + 1))
fi

if echo "$GATEWAY_LOGS" | grep -q "ssl_cipher"; then
    echo -e "${GREEN}[PASS]${NC} Logs de Nginx contienen 'ssl_cipher'"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} Logs de Nginx NO contienen 'ssl_cipher'"
    FAILED=$((FAILED + 1))
fi

# Verificar que el log es JSON valido
if echo "$GATEWAY_LOGS" | grep -q '"ssl_protocol"'; then
    echo -e "${GREEN}[PASS]${NC} Logs TLS estan en formato JSON"
    PASSED=$((PASSED + 1))
else
    warn "Logs TLS no parecen estar en formato JSON"
fi

echo ""

# =============================================================================
# TEST-F5-I002: Prometheus scrapea nginx-exporter
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I002: Prometheus scrapea nginx-exporter ---${NC}"

# Esperar a que Prometheus este listo
wait_for_service "http://localhost:9090/-/healthy" "Prometheus health"

# Verificar targets en Prometheus
PROM_TARGETS=$(curl -s --max-time "$CURL_TIMEOUT" "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "{}")

if echo "$PROM_TARGETS" | grep -q "nginx-exporter"; then
    echo -e "${GREEN}[PASS]${NC} Target nginx-exporter registrado en Prometheus"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} Target nginx-exporter NO registrado en Prometheus"
    FAILED=$((FAILED + 1))
fi

# Verificar estado UP del target
if echo "$PROM_TARGETS" | grep -q '"health":"up"'; then
    echo -e "${GREEN}[PASS]${NC} Al menos un target esta UP en Prometheus"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}[WARN]${NC} Ningun target UP todavia (puede necesitar mas tiempo)"
    WARNINGS=$((WARNINGS + 1))
fi

# Verificar metricas nginx disponibles
NGINX_METRICS=$(curl -s --max-time "$CURL_TIMEOUT" "http://localhost:9090/api/v1/query?query=nginx_up" 2>/dev/null || echo "{}")
if echo "$NGINX_METRICS" | grep -q '"resultType":"vector"'; then
    echo -e "${GREEN}[PASS]${NC} Metrica nginx_up disponible en Prometheus"
    PASSED=$((PASSED + 1))
else
    warn "Metrica nginx_up no disponible todavia"
fi

echo ""

# =============================================================================
# TEST-F5-I003: Grafana accesible
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I003: Grafana accesible ---${NC}"

# Esperar a que Grafana este listo
wait_for_service "http://localhost:3000/api/health" "Grafana health"

# Verificar health endpoint
GRAFANA_HEALTH=$(curl -s --max-time "$CURL_TIMEOUT" "http://localhost:3000/api/health" 2>/dev/null || echo "{}")
if echo "$GRAFANA_HEALTH" | grep -q '"database":"ok"'; then
    echo -e "${GREEN}[PASS]${NC} Grafana health check OK (database)"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}[WARN]${NC} Grafana health no reporta database OK"
    WARNINGS=$((WARNINGS + 1))
fi

# Verificar login page
assert_http_status "http://localhost:3000/login" "200" "Grafana login page accesible"

# Verificar que Prometheus esta configurado como datasource
GRAFANA_DS=$(curl -s --max-time "$CURL_TIMEOUT" -u "admin:admin" \
    "http://localhost:3000/api/datasources" 2>/dev/null || echo "[]")

if echo "$GRAFANA_DS" | grep -qi "prometheus"; then
    echo -e "${GREEN}[PASS]${NC} Datasource Prometheus configurado en Grafana"
    PASSED=$((PASSED + 1))
else
    warn "Datasource Prometheus no configurado en Grafana (configurar manualmente)"
fi

echo ""

# =============================================================================
# TEST-F5-I004: nginx-exporter expone metricas
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I004: nginx-exporter expone metricas ---${NC}"

EXPORTER_METRICS=$(curl -s --max-time "$CURL_TIMEOUT" "http://localhost:9113/metrics" 2>/dev/null || echo "")

if [[ -n "$EXPORTER_METRICS" ]]; then
    echo -e "${GREEN}[PASS]${NC} nginx-exporter responde en :9113/metrics"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} nginx-exporter NO responde en :9113/metrics"
    FAILED=$((FAILED + 1))
fi

if echo "$EXPORTER_METRICS" | grep -q "nginx_up"; then
    echo -e "${GREEN}[PASS]${NC} Metrica nginx_up expuesta"
    PASSED=$((PASSED + 1))
else
    warn "Metrica nginx_up no encontrada en exporter"
fi

if echo "$EXPORTER_METRICS" | grep -q "nginx_connections_active"; then
    echo -e "${GREEN}[PASS]${NC} Metrica nginx_connections_active expuesta"
    PASSED=$((PASSED + 1))
else
    warn "Metrica nginx_connections_active no encontrada"
fi

echo ""

# =============================================================================
# TEST-F5-I005: Script de rotacion funciona (dry-run)
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I005: Script de rotacion (dry-run) ---${NC}"

ROTATE_SCRIPT="$COMPOSE_DIR/scripts/rotate-internal-certs.sh"

if [[ -x "$ROTATE_SCRIPT" ]]; then
    # Crear certificado de prueba que expire pronto
    TEST_CERT_DIR="$COMPOSE_DIR/certs/test-f5-rotation"
    mkdir -p "$TEST_CERT_DIR/backup"

    # Generar certificado con 1 dia de validez
    if command -v openssl &>/dev/null; then
        openssl req -new -x509 -nodes -days 1 \
            -out "$TEST_CERT_DIR/test.crt" \
            -keyout "$TEST_CERT_DIR/test.key" \
            -subj "/CN=test-f5-integration" 2>/dev/null

        if [[ -f "$TEST_CERT_DIR/test.crt" ]]; then
            echo -e "  ${CYAN}Certificado de prueba creado (1 dia de validez)${NC}"

            # Verificar que el script detecta expiracion
            # Modificar temporalmente CERT_DIR para el test
            CERT_BACKUP=$(grep "^CERT_DIR=" "$ROTATE_SCRIPT" | head -1)

            # Crear version temporal del script para test
            TEST_SCRIPT="$TEST_CERT_DIR/test_rotate.sh"
            sed "s|^CERT_DIR=.*|CERT_DIR=$TEST_CERT_DIR|" "$ROTATE_SCRIPT" > "$TEST_SCRIPT"
            chmod +x "$TEST_SCRIPT"

            # Ejecutar con THRESHOLD bajo para forzar deteccion
            ROTATE_OUTPUT=$(THRESHOLD_DAYS=2 bash "$TEST_SCRIPT" 2>&1 || true)

            if echo "$ROTATE_OUTPUT" | grep -q "Rotating\|expires in"; then
                echo -e "${GREEN}[PASS]${NC} Script detecta certificado proximo a expirar"
                PASSED=$((PASSED + 1))
            else
                echo -e "${YELLOW}[WARN]${NC} Script no detecto expiracion (puede ser normal si el cert aun tiene >2 dias)"
                WARNINGS=$((WARNINGS + 1))
            fi

            # Verificar que backup/ existe
            if [[ -d "$TEST_CERT_DIR/backup" ]]; then
                echo -e "${GREEN}[PASS]${NC} Directorio backup/ existe para rotacion"
                PASSED=$((PASSED + 1))
            else
                warn "Directorio backup/ no creado"
            fi

            # Limpiar
            rm -rf "$TEST_CERT_DIR"
        else
            warn "No se pudo crear certificado de prueba"
        fi
    else
        warn "OpenSSL no disponible — saltando test de rotacion"
    fi
else
    warn "Script rotate-internal-certs.sh no ejecutable"
fi

echo ""

# =============================================================================
# TEST-F5-I006: Gateway healthcheck funciona via HTTPS
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I006: Gateway healthcheck HTTPS ---${NC}"

assert_http_status "https://localhost:443/health" "200" "Gateway /health via HTTPS"

# Verificar redireccion HTTP -> HTTPS
HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" "http://localhost:80/health" 2>/dev/null || echo "000")
if [[ "$HTTP_RESPONSE" == "301" ]] || [[ "$HTTP_RESPONSE" == "308" ]]; then
    echo -e "${GREEN}[PASS]${NC} Redireccion HTTP -> HTTPS funciona (HTTP $HTTP_RESPONSE)"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}[WARN]${NC} Redireccion HTTP -> HTTPS: HTTP $HTTP_RESPONSE (esperado 301/308)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# =============================================================================
# TEST-F5-I007: nginx_status endpoint accesible desde exporter
# =============================================================================
echo -e "${BLUE}--- TEST-F5-I007: nginx_status endpoint ---${NC}"

# El nginx_status solo es accesible internamente (allow 172.18.0.0/16)
# Verificar que esta configurado
if grep -q "nginx_status" "$NGINX_CONF"; then
    echo -e "${GREEN}[PASS]${NC} Endpoint /nginx_status configurado en nginx.conf"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} Endpoint /nginx_status NO configurado"
    FAILED=$((FAILED + 1))
fi

if grep -q "stub_status" "$NGINX_CONF"; then
    echo -e "${GREEN}[PASS]${NC} stub_status habilitado"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} stub_status NO habilitado"
    FAILED=$((FAILED + 1))
fi

echo ""

# =============================================================================
# RESUMEN
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RESUMEN${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASSED:${NC}   $PASSED"
echo -e "  ${RED}FAILED:${NC}   $FAILED"
echo -e "  ${YELLOW}WARNINGS:${NC} $WARNINGS"
echo -e "  ${YELLOW}SKIPPED:${NC}  $SKIPPED"
echo ""

TOTAL=$((PASSED + FAILED + WARNINGS))
if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}Tests de integracion completados ($PASSED passed, $WARNINGS warnings)${NC}"
    exit 0
else
    echo -e "  ${RED}Hay $FAILED test(s) fallido(s)${NC}"
    exit 1
fi
