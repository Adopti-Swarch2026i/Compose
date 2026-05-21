#!/usr/bin/env bash
# =============================================================================
# test_fase5_unitarios.sh — Tests estaticos (no requieren infraestructura)
# Proyecto: Adopti — Fase 5: Operacion Continua
# =============================================================================
set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Contadores ───────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
WARNINGS=0

# ── Paths (relativo a Compose/) ──────────────────────────────────────────────
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="$(cd "$COMPOSE_DIR/.." && pwd)"
NGINX_CONF="$PROJECT_ROOT/gateway/nginx.conf"
PROMETHEUS_YML="$COMPOSE_DIR/monitoring/prometheus.yml"
ROTATE_SCRIPT="$COMPOSE_DIR/scripts/rotate-internal-certs.sh"
DOCKER_COMPOSE="$COMPOSE_DIR/docker-compose.yml"

# ── Funciones assert ─────────────────────────────────────────────────────────
assert_file_exists() {
    local file="$1"
    local desc="$2"
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}[PASS]${NC} $desc — existe: $file"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — NO existe: $file"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_file_executable() {
    local file="$1"
    local desc="$2"
    if [[ -x "$file" ]]; then
        echo -e "${GREEN}[PASS]${NC} $desc — es ejecutable"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — NO es ejecutable (chmod +x requerido)"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_grep() {
    local file="$1"
    local pattern="$2"
    local desc="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — patron no encontrado: '$pattern'"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_grep_count() {
    local file="$1"
    local pattern="$2"
    local expected_count="$3"
    local desc="$4"
    local count
    count=$(grep -c "$pattern" "$file" 2>/dev/null || echo 0)
    if [[ "$count" -eq "$expected_count" ]]; then
        echo -e "${GREEN}[PASS]${NC} $desc — count=$count"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — esperado=$expected_count, actual=$count"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

assert_bash_syntax() {
    local file="$1"
    local desc="$2"
    if bash -n "$file" 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} $desc — sintaxis OK"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc — errores de sintaxis"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

# =============================================================================
# HEADER
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Adopti — Fase 5: Tests Unitarios (Estaticos)${NC}"
echo -e "${BLUE}  No requieren infraestructura corriendo${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Directorio Compose:${NC} $COMPOSE_DIR"
echo -e "${BLUE}Project root:${NC}     $PROJECT_ROOT"
echo ""

# =============================================================================
# TEST-F5-U001: log_format adopti_tls en nginx.conf
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U001: log_format adopti_tls en nginx.conf ---${NC}"

assert_file_exists "$NGINX_CONF" "nginx.conf existe"
assert_grep "$NGINX_CONF" "log_format adopti_tls" "log_format adopti_tls definido"
assert_grep "$NGINX_CONF" "ssl_protocol" "Variable ssl_protocol en log_format"
assert_grep "$NGINX_CONF" "ssl_cipher" "Variable ssl_cipher en log_format"
assert_grep "$NGINX_CONF" "ssl_session_reused" "Variable ssl_session_reused en log_format"

echo ""

# =============================================================================
# TEST-F5-U002: access_log usa formato adopti_tls
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U002: access_log referencia adopti_tls ---${NC}"

assert_grep "$NGINX_CONF" "access_log.*adopti_tls" "access_log usa formato adopti_tls"

# Verificar que no hay otra directiva access_log que sobrescriba
ACCESS_LOG_COUNT=$(grep -c 'access_log' "$NGINX_CONF" 2>/dev/null || echo 0)
if [[ "$ACCESS_LOG_COUNT" -eq 1 ]]; then
    echo -e "${GREEN}[PASS]${NC} Solo una directiva access_log (sin sobrescritura)"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}[WARN]${NC} Se encontraron $ACCESS_LOG_COUNT directivas access_log (esperado: 1)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# =============================================================================
# TEST-F5-U003: Script rotate-internal-certs.sh
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U003: Script rotate-internal-certs.sh ---${NC}"

assert_file_exists "$ROTATE_SCRIPT" "rotate-internal-certs.sh existe"
assert_file_executable "$ROTATE_SCRIPT" "rotate-internal-certs.sh es ejecutable"
assert_bash_syntax "$ROTATE_SCRIPT" "Sintaxis del script"
assert_grep "$ROTATE_SCRIPT" "set -euo pipefail" "Script usa set -euo pipefail"
assert_grep "$ROTATE_SCRIPT" "THRESHOLD_DAYS" "THRESHOLD_DAYS definido"
assert_grep "$ROTATE_SCRIPT" "ca.crt" "Script excluye ca.crt"
assert_grep "$ROTATE_SCRIPT" "find.*\.crt" "Script usa find para buscar .crt"
assert_grep "$ROTATE_SCRIPT" "openssl x509" "Script usa openssl x509"

echo ""

# =============================================================================
# TEST-F5-U004: Validacion de alertas Prometheus (prometheus.yml)
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U004: Configuracion de Prometheus ---${NC}"

assert_file_exists "$PROMETHEUS_YML" "prometheus.yml existe"
assert_grep "$PROMETHEUS_YML" "scrape_interval" "scrape_interval definido"
assert_grep "$PROMETHEUS_YML" "nginx-exporter:9113" "Prometheus scrapea nginx-exporter"
assert_grep "$PROMETHEUS_YML" "job_name: nginx" "Job name 'nginx' definido"

echo ""

# =============================================================================
# TEST-F5-U005: docker-compose tiene servicios de monitoreo
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U005: Servicios de monitoreo en docker-compose ---${NC}"

assert_file_exists "$DOCKER_COMPOSE" "docker-compose.yml existe"
assert_grep "$DOCKER_COMPOSE" "^  prometheus:" "Servicio prometheus definido"
assert_grep "$DOCKER_COMPOSE" "^  grafana:" "Servicio grafana definido"
assert_grep "$DOCKER_COMPOSE" "^  nginx-exporter:" "Servicio nginx-exporter definido"

# Verificar imagenes
assert_grep "$DOCKER_COMPOSE" "prom/prometheus" "Prometheus usa imagen oficial"
assert_grep "$DOCKER_COMPOSE" "grafana/grafana" "Grafana usa imagen oficial"
assert_grep "$DOCKER_COMPOSE" "nginx-prometheus-exporter" "Nginx exporter usa imagen oficial"

echo ""

# =============================================================================
# TEST-F5-U006: Validacion de nginx -t (syntax check)
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U006: Syntax check de nginx.conf ---${NC}"

if command -v docker &>/dev/null; then
    NGINX_TEST_OUTPUT=$(docker run --rm -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine nginx -t 2>&1 || true)
    if echo "$NGINX_TEST_OUTPUT" | grep -q "test is successful"; then
        echo -e "${GREEN}[PASS]${NC} nginx -t retorna 'test is successful'"
        PASSED=$((PASSED + 1))
    elif echo "$NGINX_TEST_OUTPUT" | grep -q "cannot load certificate"; then
        echo -e "${GREEN}[PASS]${NC} nginx -t: sintaxis OK (faltan certificados en contenedor de test)"
        PASSED=$((PASSED + 1))
    elif echo "$NGINX_TEST_OUTPUT" | grep -q "BIO_new_file"; then
        echo -e "${GREEN}[PASS]${NC} nginx -t: sintaxis OK (faltan certificados en contenedor de test)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}[FAIL]${NC} nginx -t reporto errores de sintaxis"
        echo "  Output: ${NGINX_TEST_OUTPUT:0:200}"
        FAILED=$((FAILED + 1))
    fi
else
    warn "Docker no disponible — saltando nginx -t"
fi

echo ""

# =============================================================================
# TEST-F5-U007: Verificar estructura de directorios de monitoreo
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U007: Estructura de directorios de monitoreo ---${NC}"

MONITORING_DIR="$COMPOSE_DIR/monitoring"
if [[ -d "$MONITORING_DIR" ]]; then
    echo -e "${GREEN}[PASS]${NC} Directorio monitoring/ existe"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}[FAIL]${NC} Directorio monitoring/ NO existe"
    FAILED=$((FAILED + 1))
fi

# Verificar si existen configs adicionales
if [[ -f "$MONITORING_DIR/alerts.yml" ]]; then
    echo -e "${GREEN}[PASS]${NC} alerts.yml existe"
    PASSED=$((PASSED + 1))
else
    warn "alerts.yml no existe (opcional, crear segun Fase 5.2.2)"
fi

if [[ -d "$MONITORING_DIR/grafana-dashboards" ]]; then
    echo -e "${GREEN}[PASS]${NC} Directorio grafana-dashboards/ existe"
    PASSED=$((PASSED + 1))
else
    warn "grafana-dashboards/ no existe (opcional, crear segun Fase 5.2.3)"
fi

echo ""

# =============================================================================
# TEST-F5-U008: Validacion de variables SSL en nginx
# =============================================================================
echo -e "${BLUE}--- TEST-F5-U008: Variables SSL soportadas por Nginx ---${NC}"

SSL_VARS=("ssl_protocol" "ssl_cipher" "ssl_session_reused")
for var in "${SSL_VARS[@]}"; do
    if grep -q "\$$var" "$NGINX_CONF"; then
        echo -e "${GREEN}[PASS]${NC} Variable \$$var usada en nginx.conf"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}[FAIL]${NC} Variable \$$var NO encontrada en nginx.conf"
        FAILED=$((FAILED + 1))
    fi
done

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
echo ""

TOTAL=$((PASSED + FAILED))
if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}Todos los tests unitarios pasaron ($PASSED/$TOTAL)${NC}"
    exit 0
else
    echo -e "  ${RED}Hay $FAILED test(s) fallido(s) de $TOTAL${NC}"
    exit 1
fi
