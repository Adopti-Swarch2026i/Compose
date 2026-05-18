#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Test Fase 1 — Unitarios/Estaticos (sin servicios corriendo)
# =============================================================================
# Validaciones de configuracion, certificados, y secretos.
# No requiere Docker Compose levantado.
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

# Rutas base (relativas a Compose/)
GATEWAY_DIR="../gateway"
NGINX_CONF="${GATEWAY_DIR}/nginx.conf"
CERTS_DIR="${GATEWAY_DIR}/certs"
COMPOSE_FILE="docker-compose.yml"

# ─────────────────────────────────────────────────────────────────────────────
echo "=============================================="
echo "  Fase 1 — Tests Unitarios / Estaticos"
echo "  (sin servicios corriendo)"
echo "=============================================="

# 1. Verificar que docker-compose.yml NO tiene `ports:` en postgres, rabbitmq, frontend
section "Puertos no expuestos en servicios internos"

run_test "postgres no declara ports:" "no" \
    "grep -A 30 '^  postgres:' '$COMPOSE_FILE' | grep -q '^\s*ports:'"

run_test "rabbitmq no declara ports:" "no" \
    "grep -A 30 '^  rabbitmq:' '$COMPOSE_FILE' | grep -q '^\s*ports:'"

run_test "frontend no declara ports:" "no" \
    "grep -A 30 '^  frontend:' '$COMPOSE_FILE' | grep -q '^\s*ports:'"

# 2. Verificar que no hay passwords hardcodeadas (grep "password" en valores)
section "Sin passwords hardcodeadas en docker-compose.yml"

run_test "No passwords hardcodeadas en valores de environment" "no" \
    "grep -iE 'password:\\s*[^\$\$]' '$COMPOSE_FILE' | grep -vE '\$\{|:\\?|#|^\$' | grep -q ."

# 3. Verificar que `.env.example` existe y tiene placeholders
section ".env.example con placeholders"

run_test ".env.example existe" "yes" \
    "test -f .env.example"

run_test ".env.example tiene placeholders __...__" "yes" \
    "grep -qE '__.*__' .env.example"

# 4. Verificar que `.gitignore` ignora `.env`
section ".gitignore ignora secrets"

run_test ".gitignore ignora .env" "yes" \
    "grep -q '^\\.env\$' .gitignore || grep -q '\\.env' .gitignore"

# 5. Verificar que nginx.conf tiene dos server blocks (80 y 443)
section "nginx.conf: dos bloques server"

run_test "nginx.conf tiene exactamente 2 bloques server" "yes" \
    "test \$(grep -c 'server {' '$NGINX_CONF') -eq 2"

run_test "Bloque 80 escucha en puerto 80" "yes" \
    "grep -q 'listen 80;' '$NGINX_CONF'"

run_test "Bloque 443 escucha en puerto 443 ssl" "yes" \
    "grep -q 'listen 443 ssl' '$NGINX_CONF'"

# 6. Verificar que nginx.conf tiene `ssl_protocols TLSv1.2 TLSv1.3`
section "nginx.conf: protocolos TLS"

run_test "ssl_protocols incluye TLSv1.2 y TLSv1.3" "yes" \
    "grep 'ssl_protocols' '$NGINX_CONF' | grep -q 'TLSv1.2' && grep 'ssl_protocols' '$NGINX_CONF' | grep -q 'TLSv1.3'"

# 7. Verificar que nginx.conf tiene `proxy_ssl_verify on`
section "nginx.conf: proxy_ssl_verify"

run_test "proxy_ssl_verify esta activado (on)" "yes" \
    "grep -q 'proxy_ssl_verify on' '$NGINX_CONF'"

# 8. Verificar que certificados existen en gateway/certs/
section "Certificados TLS en gateway/certs/"

run_test "server.crt existe" "yes" \
    "test -f '${CERTS_DIR}/server.crt'"

run_test "server.key existe" "yes" \
    "test -f '${CERTS_DIR}/server.key'"

run_test "server.crt es un certificado valido (OpenSSL)" "yes" \
    "openssl x509 -in '${CERTS_DIR}/server.crt' -noout"

# 9. Verificar que `xpack.security.enabled=true` en docker-compose
section "Elasticsearch: xpack.security habilitado"

run_test "xpack.security.enabled=true en docker-compose" "yes" \
    "grep -q 'xpack.security.enabled=true' '$COMPOSE_FILE'"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================================="

exit $FAIL
