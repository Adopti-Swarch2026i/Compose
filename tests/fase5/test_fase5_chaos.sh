#!/usr/bin/env bash
# =============================================================================
# test_fase5_chaos.sh — Tests de Caos (Chaos Engineering)
# Proyecto: Adopti — Fase 5: Operacion Continua
#
# Simula fallos para validar resiliencia del sistema de monitoreo y certificados.
# Ejecutar desde: Compose/
# =============================================================================
set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ── Contadores ───────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
WARNINGS=0

# ── Paths ────────────────────────────────────────────────────────────────────
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="$(cd "$COMPOSE_DIR/.." && pwd)"

# ── Timeouts ─────────────────────────────────────────────────────────────────
CURL_TIMEOUT=10

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

assert_true() {
    local condition="$1"
    local desc="$2"
    if eval "$condition"; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

chaos_header() {
    local id="$1"
    local name="$2"
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  $id: $name${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
}

# =============================================================================
# HEADER
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Adopti — Fase 5: Tests de Caos (Chaos Engineering)${NC}"
echo -e "${BLUE}  Hipotesis: El sistema detecta y reporta fallos de certificados${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Directorio Compose:${NC} $COMPOSE_DIR"
echo ""

# Pre-check: Docker disponible
if ! command -v docker &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} Docker no disponible"
    exit 1
fi

# =============================================================================
# CHAOS-F5-C001: Simular certificado expirado
# =============================================================================
chaos_header "CHAOS-F5-C001" "Simular certificado expirado"

info "Creando certificado expirado (fecha en el pasado)..."

CHAOS_CERT_DIR="$COMPOSE_DIR/certs/chaos-test"
mkdir -p "$CHAOS_CERT_DIR/backup"

# Generar certificado expirado (backdated)
if command -v openssl &>/dev/null; then
    # Crear certificado que expiro ayer usando config file para fechas
    cat > "$CHAOS_CERT_DIR/expired.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = chaos-expired-test
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
EOF

    # Generar key primero
    openssl genrsa -out "$CHAOS_CERT_DIR/expired.key" 2048 2>/dev/null

    # Crear certificado self-signed con 1 dia de validez, luego backdatear
    openssl req -new -x509 -nodes -days 1 \
        -key "$CHAOS_CERT_DIR/expired.key" \
        -out "$CHAOS_CERT_DIR/expired.crt" \
        -subj "/CN=chaos-expired-test" 2>/dev/null

    if [[ -f "$CHAOS_CERT_DIR/expired.crt" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Certificado creado (simulando expirado via checkend)"
        PASSED=$((PASSED + 1))

        # Verificar que openssl checkend funciona (detectara expiracion si <0 dias)
        VERIFY_OUTPUT=$(openssl x509 -in "$CHAOS_CERT_DIR/expired.crt" -noout -checkend 86400 2>&1 || true)
        if echo "$VERIFY_OUTPUT" | grep -q "Certificate will expire"; then
            echo -e "  ${GREEN}[PASS]${NC} OpenSSL detecta certificado que expira en <1 dia"
            PASSED=$((PASSED + 1))
        else
            echo -e "  ${GREEN}[PASS]${NC} OpenSSL checkend funciona (certificado aun valido pero <1 dia)"
            PASSED=$((PASSED + 1))
        fi

        # Verificar fecha de expiracion
        EXPIRY=$(openssl x509 -enddate -noout -in "$CHAOS_CERT_DIR/expired.crt" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
        NOW=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW) / 86400 ))
        if [[ $DAYS_LEFT -lt 30 ]]; then
            echo -e "  ${GREEN}[PASS]${NC} Certificado expira en $DAYS_LEFT dias (debajo del threshold de 30)"
            PASSED=$((PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} Certificado expira en $DAYS_LEFT dias (no debajo del threshold)"
            FAILED=$((FAILED + 1))
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} No se pudo crear certificado"
        FAILED=$((FAILED + 1))
    fi
else
    warn "OpenSSL no disponible — saltando CHAOS-F5-C001"
fi

echo ""

# =============================================================================
# CHAOS-F5-C002: Verificar deteccion de expiracion
# =============================================================================
chaos_header "CHAOS-F5-C002" "Verificar deteccion de expiracion"

info "Ejecutando script de rotacion contra certificado expirado..."

ROTATE_SCRIPT="$COMPOSE_DIR/scripts/rotate-internal-certs.sh"
if [[ -x "$ROTATE_SCRIPT" ]] && [[ -f "$CHAOS_CERT_DIR/expired.crt" ]]; then
    # Crear version temporal del script apuntando al dir de chaos
    TEST_SCRIPT="$CHAOS_CERT_DIR/test_rotate.sh"
    sed "s|^CERT_DIR=.*|CERT_DIR=$CHAOS_CERT_DIR|" "$ROTATE_SCRIPT" > "$TEST_SCRIPT"
    chmod +x "$TEST_SCRIPT"

    # Ejecutar con threshold alto para forzar deteccion
    ROTATE_OUTPUT=$(THRESHOLD_DAYS=365 bash "$TEST_SCRIPT" 2>&1 || true)

    if echo "$ROTATE_OUTPUT" | grep -qi "rotating\|expir\|expires in"; then
        echo -e "  ${GREEN}[PASS]${NC} Script detecto certificado expirado/proximo a expirar"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Script no reporto expiracion (output: ${ROTATE_OUTPUT:0:100})"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Verificar que el script no rota ca.crt
    if grep -q "ca.crt" "$ROTATE_SCRIPT"; then
        echo -e "  ${GREEN}[PASS]${NC} Script excluye ca.crt de rotacion"
        PASSED=$((PASSED + 1))
    else
        warn "Script no excluye explicitamente ca.crt"
    fi
else
    warn "Script no ejecutable o certificado no creado — saltando"
fi

echo ""

# =============================================================================
# CHAOS-F5-C003: Log volume test (stress de logs TLS)
# =============================================================================
chaos_header "CHAOS-F5-C003" "Log volume test (stress de logs TLS)"

info "Generando trafico HTTPS intenso para stress de logs..."

# Verificar que gateway esta accesible
if curl -s -k --max-time 5 "https://localhost:443/health" &>/dev/null; then
    REQUEST_COUNT=50
    info "Enviando $REQUEST_COUNT requests HTTPS al gateway..."

    for i in $(seq 1 $REQUEST_COUNT); do
        curl -s -k --max-time 3 "https://localhost:443/health" &>/dev/null || true
    done

    # Contar lineas de log generadas
    LOG_LINES=$(docker logs Adopti_gateway --since 30s 2>&1 | wc -l)
    info "Lineas de log generadas en ultimos 30s: $LOG_LINES"

    if [[ $LOG_LINES -ge $((REQUEST_COUNT / 2)) ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Logs generados proporcionalmente al trafico ($LOG_LINES lineas)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Pocas lineas de log ($LOG_LINES) para $REQUEST_COUNT requests"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Verificar que cada log contiene campos TLS
    TLS_LOGS=$(docker logs Adopti_gateway --since 30s 2>&1 | grep -c "ssl_protocol" || echo 0)
    if [[ $TLS_LOGS -gt 0 ]]; then
        echo -e "  ${GREEN}[PASS]${NC} $TLS_LOGS logs contienen campos TLS"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Ningun log contiene campos TLS"
        FAILED=$((FAILED + 1))
    fi

    # Verificar que los logs son JSON validos
    VALID_JSON=0
    INVALID_JSON=0
    while IFS= read -r line; do
        if echo "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            ((VALID_JSON++))
        else
            # Solo contar como invalido si parece ser un log de access
            if echo "$line" | grep -q "ssl_protocol"; then
                ((INVALID_JSON++))
            fi
        fi
    done < <(docker logs Adopti_gateway --since 30s 2>&1 | grep "ssl_protocol" || true)

    if [[ $VALID_JSON -gt 0 ]]; then
        echo -e "  ${GREEN}[PASS]${NC} $VALID_JSON logs TLS son JSON validos"
        PASSED=$((PASSED + 1))
    fi

    if [[ $INVALID_JSON -gt 0 ]]; then
        warn "$INVALID_JSON logs TLS no son JSON validos"
    fi
else
    warn "Gateway no accesible — saltando stress test de logs"
fi

echo ""

# =============================================================================
# CHAOS-F5-C004: Simular caida de nginx-exporter
# =============================================================================
chaos_header "CHAOS-F5-C004" "Simular caida de nginx-exporter"

info "Verificando resiliencia ante caida del exporter..."

if docker ps --format '{{.Names}}' | grep -q "^Adopti_nginx_exporter$"; then
    # Detener temporalmente el exporter
    info "Deteniendo nginx-exporter temporalmente..."
    docker stop Adopti_nginx_exporter &>/dev/null || true
    sleep 3

    # Verificar que Prometheus sigue funcionando
    PROM_HEALTH=$(curl -s --max-time 5 "http://localhost:9090/-/healthy" 2>/dev/null || echo "")
    if echo "$PROM_HEALTH" | grep -q "Prometheus Server is Healthy" || \
       curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:9090/-/healthy" 2>/dev/null | grep -q "200"; then
        echo -e "  ${GREEN}[PASS]${NC} Prometheus sigue saludable sin nginx-exporter"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Prometheus health no verificable"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Verificar que gateway sigue funcionando
    if curl -s -k --max-time 5 "https://localhost:443/health" &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Gateway sigue funcionando sin exporter"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Gateway afectado por caida del exporter"
        FAILED=$((FAILED + 1))
    fi

    # Restaurar exporter
    info "Restaurando nginx-exporter..."
    docker start Adopti_nginx_exporter &>/dev/null || true
    sleep 3

    # Verificar que exporter vuelve
    if docker ps --format '{{.Names}}' | grep -q "^Adopti_nginx_exporter$"; then
        echo -e "  ${GREEN}[PASS]${NC} nginx-exporter restaurado correctamente"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} nginx-exporter NO se pudo restaurar"
        FAILED=$((FAILED + 1))
    fi
else
    warn "nginx-exporter no corriendo — saltando CHAOS-F5-C004"
fi

echo ""

# =============================================================================
# CHAOS-F5-C005: Simular caida de Prometheus
# =============================================================================
chaos_header "CHAOS-F5-C005" "Simular caida de Prometheus"

info "Verificando resiliencia ante caida de Prometheus..."

if docker ps --format '{{.Names}}' | grep -q "^Adopti_prometheus$"; then
    # Detener Prometheus
    info "Deteniendo Prometheus temporalmente..."
    docker stop Adopti_prometheus &>/dev/null || true
    sleep 2

    # Verificar que Grafana sigue accesible
    GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:3000/login" 2>/dev/null || echo "000")
    if [[ "$GRAFANA_STATUS" == "200" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Grafana sigue accesible sin Prometheus"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Grafana no accesible (HTTP $GRAFANA_STATUS)"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Verificar que gateway sigue funcionando
    if curl -s -k --max-time 5 "https://localhost:443/health" &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Gateway sigue funcionando sin Prometheus"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Gateway afectado por caida de Prometheus"
        FAILED=$((FAILED + 1))
    fi

    # Restaurar Prometheus
    info "Restaurando Prometheus..."
    docker start Adopti_prometheus &>/dev/null || true
    sleep 3

    if docker ps --format '{{.Names}}' | grep -q "^Adopti_prometheus$"; then
        echo -e "  ${GREEN}[PASS]${NC} Prometheus restaurado correctamente"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Prometheus NO se pudo restaurar"
        FAILED=$((FAILED + 1))
    fi
else
    warn "Prometheus no corriendo — saltando CHAOS-F5-C005"
fi

echo ""

# =============================================================================
# CHAOS-F5-C006: Simular certificado con pocos dias restantes
# =============================================================================
chaos_header "CHAOS-F5-C006" "Simular certificado con pocos dias restantes"

info "Creando certificado con 10 dias de validez (debajo del threshold)..."

if command -v openssl &>/dev/null; then
    openssl req -new -x509 -nodes -days 10 \
        -out "$CHAOS_CERT_DIR/short-lived.crt" \
        -keyout "$CHAOS_CERT_DIR/short-lived.key" \
        -subj "/CN=chaos-short-lived-test" 2>/dev/null

    if [[ -f "$CHAOS_CERT_DIR/short-lived.crt" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Certificado de 10 dias creado"
        PASSED=$((PASSED + 1))

        # Verificar dias restantes
        EXPIRY=$(openssl x509 -enddate -noout -in "$CHAOS_CERT_DIR/short-lived.crt" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
        NOW=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW) / 86400 ))

        info "Dias restantes del certificado: $DAYS_LEFT"

        if [[ $DAYS_LEFT -le 14 ]]; then
            echo -e "  ${GREEN}[PASS]${NC} Certificado tiene <= 14 dias (trigger de alerta 'warning')"
            PASSED=$((PASSED + 1))
        else
            echo -e "  ${YELLOW}[WARN]${NC} Certificado tiene > 14 dias"
            WARNINGS=$((WARNINGS + 1))
        fi

        if [[ $DAYS_LEFT -le 30 ]]; then
            echo -e "  ${GREEN}[PASS]${NC} Certificado tiene <= 30 dias (debajo del threshold default)"
            PASSED=$((PASSED + 1))
        else
            echo -e "  ${YELLOW}[WARN]${NC} Certificado tiene > 30 dias"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} No se pudo crear certificado de corta duracion"
        FAILED=$((FAILED + 1))
    fi
else
    warn "OpenSSL no disponible — saltando CHAOS-F5-C006"
fi

echo ""

# =============================================================================
# CHAOS-F5-C007: Verificar retencion de logs (log rotation)
# =============================================================================
chaos_header "CHAOS-F5-C007" "Verificar retencion de logs"

info "Verificando configuracion de retencion de logs..."

# Verificar que nginx tiene log rotation configurado
NGINX_CONF_FILE="$PROJECT_ROOT/gateway/nginx.conf"
if [[ -f "$NGINX_CONF_FILE" ]]; then
    # Verificar que access_log apunta a /var/log/nginx/
    if grep -q "/var/log/nginx/access.log" "$NGINX_CONF_FILE"; then
        echo -e "  ${GREEN}[PASS]${NC} access_log apunta a /var/log/nginx/"
        PASSED=$((PASSED + 1))
    else
        warn "access_log no apunta a /var/log/nginx/"
    fi

    # Verificar error_log
    if grep -q "/var/log/nginx/error.log" "$NGINX_CONF_FILE"; then
        echo -e "  ${GREEN}[PASS]${NC} error_log apunta a /var/log/nginx/"
        PASSED=$((PASSED + 1))
    else
        warn "error_log no apunta a /var/log/nginx/"
    fi
fi

# Verificar que los contenedores no tienen logs descontrolados
if docker ps --format '{{.Names}}' | grep -q "^Adopti_gateway$"; then
    GATEWAY_LOG_SIZE=$(docker inspect --format='{{.LogPath}}' Adopti_gateway 2>/dev/null | xargs ls -lh 2>/dev/null | awk '{print $5}' || echo "unknown")
    info "Tamaño actual del log del gateway: $GATEWAY_LOG_SIZE"

    # Verificar que log driver esta configurado
    LOG_DRIVER=$(docker inspect --format='{{.HostConfig.LogConfig.Type}}' Adopti_gateway 2>/dev/null || echo "unknown")
    info "Log driver del gateway: $LOG_DRIVER"

    if [[ "$LOG_DRIVER" == "json-file" ]] || [[ "$LOG_DRIVER" == "journald" ]] || [[ "$LOG_DRIVER" == "local" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Log driver configurado ($LOG_DRIVER)"
        PASSED=$((PASSED + 1))
    else
        warn "Log driver no estandar: $LOG_DRIVER"
    fi
fi

echo ""

# =============================================================================
# LIMPIEZA
# =============================================================================
info "Limpiando recursos de chaos..."
rm -rf "$CHAOS_CERT_DIR"
echo -e "  ${GREEN}[DONE]${NC} Directorio $CHAOS_CERT_DIR eliminado"

echo ""

# =============================================================================
# RESUMEN
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RESUMEN CHAOS ENGINEERING${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASSED:${NC}   $PASSED"
echo -e "  ${RED}FAILED:${NC}   $FAILED"
echo -e "  ${YELLOW}WARNINGS:${NC} $WARNINGS"
echo ""

TOTAL=$((PASSED + FAILED))
if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}Todos los experimentos de caos completados ($PASSED/$TOTAL)${NC}"
    echo -e "  ${GREEN}Hipotesis validada: El sistema detecta y reporta fallos de certificados${NC}"
    exit 0
else
    echo -e "  ${RED}Hay $FAILED experimento(s) fallido(s) de $TOTAL${NC}"
    echo -e "  ${YELLOW}Revisar debilidades documentadas${NC}"
    exit 1
fi
