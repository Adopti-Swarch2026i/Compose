#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Test Fase 1 — Integracion (requiere servicios corriendo)
# =============================================================================
# Validaciones de redireccion HTTPS, TLS, headers de seguridad.
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
echo "  Fase 1 — Tests de Integracion"
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

# 1. curl -I http://localhost/ → esperar 301
section "Redireccion HTTP a HTTPS"

run_test "HTTP / retorna 301" "yes" \
    "curl -sI http://localhost/ | head -1 | grep -q '301'"

# 2. curl -k https://localhost/health → esperar 200
section "HTTPS /health responde 200"

run_test "HTTPS /health retorna 200" "yes" \
    "curl -s -o /dev/null -k -w '%{http_code}' https://localhost/health | grep -q '200'"

# 3. openssl s_client -connect localhost:443 -tls1_2 → OK
section "TLS 1.2 handshake exitoso"

run_test "TLS 1.2 handshake completa (Verify return code: 0)" "yes" \
    "echo | openssl s_client -connect localhost:443 -tls1_2 2>/dev/null | grep -q 'Verify return code: 0'"

# 4. openssl s_client -connect localhost:443 -tls1_1 → FAIL
section "TLS 1.1 rechazado"

run_test "TLS 1.1 handshake falla" "no" \
    "echo | openssl s_client -connect localhost:443 -tls1_1 2>&1 | grep -qE 'handshake failure|no protocols available|Protocol : TLSv1.1'"

# 5. Verificar headers HSTS, X-Frame-Options, X-Content-Type-Options
section "Headers de seguridad"

run_test "HSTS header presente" "yes" \
    "curl -sIk https://localhost/ | grep -qi 'Strict-Transport-Security'"

run_test "X-Frame-Options header presente" "yes" \
    "curl -sIk https://localhost/ | grep -qi 'X-Frame-Options'"

run_test "X-Content-Type-Options header presente" "yes" \
    "curl -sIk https://localhost/ | grep -qi 'X-Content-Type-Options'"

# 6. Verificar cipher suite es ECDHE+AESGCM
section "Cipher suite negociado"

run_test "Cipher suite usa ECDHE+AESGCM" "yes" \
    "echo | openssl s_client -connect localhost:443 2>/dev/null | grep 'Cipher *:' | grep -qE 'ECDHE.*AES.*GCM'"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================================="

exit $FAIL
