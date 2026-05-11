#!/usr/bin/env bash
# =============================================================================
# Test Fase 4 - Unitarios (Tests Estaticos)
# Proyecto: Adopti
# Patron: Secure Channel + Authenticator | Tactica: Encrypt Data + Limit Access
# =============================================================================
# Ejecutar desde: Compose/
# Uso: ./tests/fase4/test_fase4_unitarios.sh
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Colores
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Contadores
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Funciones assert
# ---------------------------------------------------------------------------

assert_ok() {
    local msg="$1"
    echo -e "${GREEN}  [PASS]${NC} ${msg}"
    ((PASSED++))
}

assert_fail() {
    local msg="$1"
    echo -e "${RED}  [FAIL]${NC} ${msg}"
    ((FAILED++))
}

assert_warn() {
    local msg="$1"
    echo -e "${YELLOW}  [WARN]${NC} ${msg}"
    ((WARNINGS++))
}

section() {
    local id="$1"
    local name="$2"
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  ${id} - ${name}${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

subtest() {
    local msg="$1"
    echo -e "\n${CYAN}  > ${msg}${NC}"
}

# ---------------------------------------------------------------------------
# Validacion de contenedores
# ---------------------------------------------------------------------------

check_container() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -qx "${name}"
}

# ---------------------------------------------------------------------------
# Paths del proyecto (relativos a Compose/)
# ---------------------------------------------------------------------------
PROJECT_ROOT=".."
SECURITY_DIR="${PROJECT_ROOT}/security"
COMPOSE_FILE="docker-compose.yml"

# =============================================================================
# INICIO DE TESTS
# =============================================================================

echo -e "${BOLD}"
echo "    ___    __  _____________  ______  _________________  _______  ______"
echo "   /   |  /  |/  /  _/ __  \/ ____/ /_  __/ ____/ __ \/ _____/ /_  __/"
echo "  / /| | / /|_/ // // / / / /___    / / / __/ / /_/ / /___     / /   "
echo " / ___ |/ /  / // // / / / ___/    / / / /___/ _, _/ ____/    / /    "
echo "/_/  |_/_/  /_/___/_/ /_/_/       /_/ /_____/_/ |_/_____/    /_/     "
echo -e "${NC}"
echo -e "${BOLD}  Fase 4: TLS en Datastores y Mensajeria - Tests Unitarios (Estaticos)${NC}"
echo -e "  Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Directorio de trabajo: $(pwd)"
echo ""

# ---------------------------------------------------------------------------
# Pre-check: estamos en el directorio correcto
# ---------------------------------------------------------------------------
if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo -e "${RED}ERROR: No se encontro ${COMPOSE_FILE}. Ejecutar desde el directorio Compose/.${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. PostgreSQL - Certificados existen
# ---------------------------------------------------------------------------
section "TEST-F4-U001" "Validacion de certificados PostgreSQL (pets-db)"

subtest "Certificado servidor (pets-server.crt) existe"
if [[ -f "${SECURITY_DIR}/postgres/pets-server.crt" ]]; then
    assert_ok "pets-server.crt existe en security/postgres/"
else
    assert_fail "pets-server.crt NO encontrado en security/postgres/"
fi

subtest "Clave privada servidor (pets-server.key) existe"
if [[ -f "${SECURITY_DIR}/postgres/pets-server.key" ]]; then
    assert_ok "pets-server.key existe en security/postgres/"
else
    assert_fail "pets-server.key NO encontrado en security/postgres/"
fi

subtest "CA cert (ca.crt) existe para pets-db"
if [[ -f "${SECURITY_DIR}/postgres/ca.crt" ]]; then
    assert_ok "ca.crt existe en security/postgres/"
else
    assert_fail "ca.crt NO encontrado en security/postgres/"
fi

section "TEST-F4-U001b" "Validacion de certificados PostgreSQL (notifications-db)"

subtest "Certificado servidor (notif-server.crt) existe"
if [[ -f "${SECURITY_DIR}/postgres-notifications/notif-server.crt" ]]; then
    assert_ok "notif-server.crt existe en security/postgres-notifications/"
else
    assert_fail "notif-server.crt NO encontrado en security/postgres-notifications/"
fi

subtest "Clave privada servidor (notif-server.key) existe"
if [[ -f "${SECURITY_DIR}/postgres-notifications/notif-server.key" ]]; then
    assert_ok "notif-server.key existe en security/postgres-notifications/"
else
    assert_fail "notif-server.key NO encontrado en security/postgres-notifications/"
fi

subtest "CA cert (ca.crt) existe para notifications-db"
if [[ -f "${SECURITY_DIR}/postgres-notifications/ca.crt" ]]; then
    assert_ok "ca.crt existe en security/postgres-notifications/"
else
    assert_fail "ca.crt NO encontrado en security/postgres-notifications/"
fi

# ---------------------------------------------------------------------------
# 2. Elasticsearch - Certificados existen
# ---------------------------------------------------------------------------
section "TEST-F4-U006/U007" "Validacion de certificados Elasticsearch"

subtest "Directorio de certificados Elasticsearch existe"
if [[ -d "${SECURITY_DIR}/elasticsearch" ]]; then
    assert_ok "Directorio security/elasticsearch/ existe"
else
    assert_fail "Directorio security/elasticsearch/ NO existe"
fi

subtest "Certificados PKCS#12 (elastic-certificates.p12) existen"
if [[ -f "${SECURITY_DIR}/elasticsearch/elastic-certificates.p12" ]]; then
    assert_ok "elastic-certificates.p12 existe"
else
    # Tambien aceptamos archivos .crt/.key alternativos
    if [[ -f "${SECURITY_DIR}/elasticsearch/http.crt" || -f "${SECURITY_DIR}/elasticsearch/transport.crt" ]]; then
        assert_ok "Certificados .crt/.key alternativos encontrados"
    else
        assert_fail "No se encontraron certificados Elasticsearch (.p12 ni .crt)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. RabbitMQ - Certificados existen
# ---------------------------------------------------------------------------
section "TEST-F4-U008" "Validacion de certificados RabbitMQ"

subtest "Certificado servidor RabbitMQ (rabbitmq.crt) existe"
if [[ -f "${SECURITY_DIR}/rabbitmq/rabbitmq.crt" ]]; then
    assert_ok "rabbitmq.crt existe en security/rabbitmq/"
else
    assert_fail "rabbitmq.crt NO encontrado en security/rabbitmq/"
fi

subtest "Clave privada RabbitMQ (rabbitmq.key) existe"
if [[ -f "${SECURITY_DIR}/rabbitmq/rabbitmq.key" ]]; then
    assert_ok "rabbitmq.key existe en security/rabbitmq/"
else
    assert_fail "rabbitmq.key NO encontrado en security/rabbitmq/"
fi

subtest "CA cert RabbitMQ (ca.crt) existe"
if [[ -f "${SECURITY_DIR}/rabbitmq/ca.crt" ]]; then
    assert_ok "ca.crt existe en security/rabbitmq/"
else
    assert_fail "ca.crt NO encontrado en security/rabbitmq/"
fi

# ---------------------------------------------------------------------------
# 4. RabbitMQ - rabbitmq.conf tiene listeners.tcp = none
# ---------------------------------------------------------------------------
section "TEST-F4-U008b" "Validacion de rabbitmq.conf - TCP deshabilitado"

RABBITMQ_CONF="./rabbitmq/rabbitmq.conf"

subtest "Archivo rabbitmq.conf existe"
if [[ -f "${RABBITMQ_CONF}" ]]; then
    assert_ok "rabbitmq.conf encontrado en Compose/rabbitmq/"
else
    # Fallback: buscar en security/rabbitmq/
    RABBITMQ_CONF="${SECURITY_DIR}/rabbitmq/rabbitmq.conf"
    if [[ -f "${RABBITMQ_CONF}" ]]; then
        assert_ok "rabbitmq.conf encontrado en security/rabbitmq/"
    else
        assert_fail "rabbitmq.conf NO encontrado en rabbitmq/ ni security/rabbitmq/"
    fi
fi

if [[ -f "${RABBITMQ_CONF}" ]]; then
    subtest "listeners.tcp = none"
    if grep -q "^listeners.tcp\s*=\s*none" "${RABBITMQ_CONF}"; then
        assert_ok "TCP plano deshabilitado (listeners.tcp = none)"
    else
        assert_fail "listeners.tcp = none NO encontrado en rabbitmq.conf"
    fi

    subtest "listeners.ssl.default = 5671"
    if grep -q "^listeners.ssl.default\s*=\s*5671" "${RABBITMQ_CONF}"; then
        assert_ok "SSL listener en puerto 5671 configurado"
    else
        assert_fail "listeners.ssl.default = 5671 NO encontrado"
    fi

    subtest "ssl_options.verify = verify_peer"
    if grep -q "^ssl_options.verify\s*=\s*verify_peer" "${RABBITMQ_CONF}"; then
        assert_ok "Verificacion de peer habilitada"
    else
        assert_fail "ssl_options.verify = verify_peer NO encontrado"
    fi

    subtest "ssl_options.versions incluye TLS 1.3 y 1.2"
    if grep -q "tlsv1.3" "${RABBITMQ_CONF}" && grep -q "tlsv1.2" "${RABBITMQ_CONF}"; then
        assert_ok "TLS 1.3 y 1.2 configurados"
    else
        assert_fail "Versiones TLS 1.3/1.2 NO configuradas correctamente"
    fi

    subtest "management.ssl.port = 15671"
    if grep -q "^management.ssl.port\s*=\s*15671" "${RABBITMQ_CONF}"; then
        assert_ok "Management SSL en puerto 15671 configurado"
    else
        assert_fail "management.ssl.port = 15671 NO encontrado"
    fi
fi

# ---------------------------------------------------------------------------
# 5. docker-compose.yml - ssl=on para PostgreSQL
# ---------------------------------------------------------------------------
section "TEST-F4-U003" "Validacion de docker-compose - PostgreSQL SSL habilitado"

subtest "postgres (pets-db) tiene ssl=on"
if grep -A 35 "^  postgres:" "${COMPOSE_FILE}" | grep -q "ssl=on"; then
    assert_ok "pets-db: ssl=on encontrado en command"
else
    assert_fail "pets-db: ssl=on NO encontrado en docker-compose.yml"
fi

subtest "postgres-notifications tiene ssl=on"
if grep -A 35 "^  postgres-notifications:" "${COMPOSE_FILE}" | grep -q "ssl=on"; then
    assert_ok "notifications-db: ssl=on encontrado en command"
else
    assert_fail "notifications-db: ssl=on NO encontrado en docker-compose.yml"
fi

subtest "postgres (pets-db) tiene ssl_min_protocol_version=TLSv1.2"
if grep -A 35 "^  postgres:" "${COMPOSE_FILE}" | grep -q "ssl_min_protocol_version"; then
    assert_ok "pets-db: ssl_min_protocol_version configurado"
else
    assert_fail "pets-db: ssl_min_protocol_version NO configurado"
fi

subtest "postgres-notifications tiene ssl_min_protocol_version=TLSv1.2"
if grep -A 35 "^  postgres-notifications:" "${COMPOSE_FILE}" | grep -q "ssl_min_protocol_version"; then
    assert_ok "notifications-db: ssl_min_protocol_version configurado"
else
    assert_fail "notifications-db: ssl_min_protocol_version NO configurado"
fi

# ---------------------------------------------------------------------------
# 6. Connection strings - No tienen sslmode=disable
# ---------------------------------------------------------------------------
section "TEST-F4-U004/U005/U009" "Validacion de connection strings - ausencia de sslmode=disable"

# Buscar en todo el proyecto (subiendo desde Compose/)
PROJECT_ROOT_ABS="$(cd "${PROJECT_ROOT}" && pwd)"

subtest "Buscar sslmode=disable en codigo fuente"
DISABLE_COUNT=$(grep -r "sslmode=disable" \
    --include="*.go" --include="*.java" --include="*.kt" \
    --include="*.properties" --include="*.yml" --include="*.yaml" \
    --include="*.py" --include="*.ts" --include="*.js" \
    --include="*.env" --include="*.sql" \
    "${PROJECT_ROOT_ABS}" 2>/dev/null | \
    grep -vE "node_modules/|\.git/|/ENVS/|compose-updated|\.bak|\.md:|README|test_fase4" | \
    wc -l)

if [[ "${DISABLE_COUNT}" -eq 0 ]]; then
    assert_ok "Cero ocurrencias de sslmode=disable en el proyecto"
else
    assert_fail "${DISABLE_COUNT} ocurrencias de sslmode=disable encontradas"
    grep -r "sslmode=disable" \
        --include="*.go" --include="*.java" --include="*.kt" \
        --include="*.properties" --include="*.yml" --include="*.yaml" \
        --include="*.py" --include="*.ts" --include="*.js" \
        --include="*.env" --include="*.sql" \
        "${PROJECT_ROOT_ABS}" 2>/dev/null | \
        grep -vE "node_modules/|\.git/|/ENVS/|compose-updated|\.bak|\.md:|README|test_fase4" | \
        while read -r line; do
        echo -e "${RED}       ${line}${NC}"
    done
fi

subtest "Buscar amqp:// (sin 's') en codigo de conexion"
# Excluir: node_modules, .git, docs, archivos de backup, ENVS, compose-updated
AMQP_PLAIN_COUNT=$(grep -r "amqp://" \
    --include="*.go" --include="*.java" --include="*.kt" \
    --include="*.properties" --include="*.yml" --include="*.yaml" \
    --include="*.py" --include="*.ts" --include="*.js" \
    --include="*.env" \
    "${PROJECT_ROOT_ABS}" 2>/dev/null | \
    grep -v "amqps://" | \
    grep -vE "node_modules/|\.git/|/ENVS/|compose-updated|\.bak|\.md:|README" | \
    wc -l)

if [[ "${AMQP_PLAIN_COUNT}" -eq 0 ]]; then
    assert_ok "Cero ocurrencias de amqp:// plano en codigo de conexion"
else
    assert_warn "${AMQP_PLAIN_COUNT} ocurrencias de amqp:// encontradas (verificar si son docs/ejemplos)"
    grep -r "amqp://" \
        --include="*.go" --include="*.java" --include="*.kt" \
        --include="*.properties" --include="*.yml" --include="*.yaml" \
        --include="*.py" --include="*.ts" --include="*.js" \
        --include="*.env" \
        "${PROJECT_ROOT_ABS}" 2>/dev/null | \
        grep -v "amqps://" | \
        grep -vE "node_modules/|\.git/|/ENVS/|compose-updated|\.bak|\.md:|README" | \
        while read -r line; do
        echo -e "${YELLOW}       ${line}${NC}"
    done
fi

subtest "Buscar sslmode=prefer (menos seguro que verify-full)"
PREFER_COUNT=$(grep -r "sslmode=prefer" \
    --include="*.go" --include="*.java" --include="*.kt" \
    --include="*.properties" --include="*.yml" --include="*.yaml" \
    --include="*.py" --include="*.ts" --include="*.js" \
    --include="*.env" \
    "${PROJECT_ROOT_ABS}" 2>/dev/null | wc -l)

if [[ "${PREFER_COUNT}" -eq 0 ]]; then
    assert_ok "Cero ocurrencias de sslmode=prefer"
else
    assert_warn "${PREFER_COUNT} ocurrencias de sslmode=prefer encontradas"
fi

# ---------------------------------------------------------------------------
# 7. Elasticsearch - xpack.security habilitado
# ---------------------------------------------------------------------------
section "TEST-F4-U006" "Validacion de xpack.security en docker-compose"

subtest "xpack.security.enabled=true"
if grep -A 30 "^  elasticsearch:" "${COMPOSE_FILE}" | grep -q "xpack.security.enabled=true"; then
    assert_ok "xpack.security.enabled=true encontrado"
else
    assert_fail "xpack.security.enabled=true NO encontrado"
fi

subtest "xpack.security.http.ssl.enabled=true"
if grep -A 30 "^  elasticsearch:" "${COMPOSE_FILE}" | grep -q "xpack.security.http.ssl.enabled=true"; then
    assert_ok "xpack.security.http.ssl.enabled=true encontrado"
else
    assert_fail "xpack.security.http.ssl.enabled=true NO encontrado"
fi

subtest "xpack.security.transport.ssl.enabled=true"
if grep -A 30 "^  elasticsearch:" "${COMPOSE_FILE}" | grep -q "xpack.security.transport.ssl.enabled=true"; then
    assert_ok "xpack.security.transport.ssl.enabled=true encontrado"
else
    assert_fail "xpack.security.transport.ssl.enabled=true NO encontrado"
fi

# ---------------------------------------------------------------------------
# 8. Volumenes de certificados - read_only
# ---------------------------------------------------------------------------
section "TEST-F4-U010" "Validacion de volumenes de certificados read-only"

subtest "Volumenes de certificados tienen flag :ro"
RO_COUNT=$(grep -c ":ro" "${COMPOSE_FILE}")
if [[ "${RO_COUNT}" -gt 0 ]]; then
    assert_ok "${RO_COUNT} volumenes con flag :ro (read-only) encontrados"
else
    assert_fail "Ningun volumen con flag :ro encontrado"
fi

# Verificar que todos los mounts de certs tienen :ro
CERT_MOUNTS=$(grep -E "certs.*:ro|security.*:ro" "${COMPOSE_FILE}" | wc -l)
CERT_TOTAL=$(grep -E "certs|security/" "${COMPOSE_FILE}" | grep -v "^#" | wc -l)

subtest "Todos los mounts de certificados son read-only"
if [[ "${CERT_MOUNTS}" -eq "${CERT_TOTAL}" && "${CERT_TOTAL}" -gt 0 ]]; then
    assert_ok "${CERT_MOUNTS}/${CERT_TOTAL} mounts de certificados son read-only"
else
    assert_warn "${CERT_MOUNTS}/${CERT_TOTAL} mounts de certificados son read-only (alguno podria no serlo)"
fi

# ---------------------------------------------------------------------------
# 9. Validacion de permisos de archivos de certificados (filesystem)
# ---------------------------------------------------------------------------
section "TEST-F4-U001c" "Validacion de permisos de archivos de certificados"

subtest "Permisos de pets-server.key (debe ser 600)"
if [[ -f "${SECURITY_DIR}/postgres/pets-server.key" ]]; then
    PERM=$(stat -c '%a' "${SECURITY_DIR}/postgres/pets-server.key" 2>/dev/null)
    if [[ "${PERM}" == "600" ]]; then
        assert_ok "pets-server.key tiene permisos 600"
    else
        assert_warn "pets-server.key tiene permisos ${PERM} (esperado: 600)"
    fi
else
    assert_warn "No se puede verificar: pets-server.key no existe"
fi

subtest "Permisos de pets-server.crt (debe ser 644)"
if [[ -f "${SECURITY_DIR}/postgres/pets-server.crt" ]]; then
    PERM=$(stat -c '%a' "${SECURITY_DIR}/postgres/pets-server.crt" 2>/dev/null)
    if [[ "${PERM}" == "644" || "${PERM}" == "664" || "${PERM}" == "600" ]]; then
        assert_ok "pets-server.crt tiene permisos ${PERM} (aceptable)"
    else
        assert_warn "pets-server.crt tiene permisos ${PERM} (esperado: 644)"
    fi
else
    assert_warn "No se puede verificar: pets-server.crt no existe"
fi

subtest "Permisos de notif-server.key (debe ser 600)"
if [[ -f "${SECURITY_DIR}/postgres-notifications/notif-server.key" ]]; then
    PERM=$(stat -c '%a' "${SECURITY_DIR}/postgres-notifications/notif-server.key" 2>/dev/null)
    if [[ "${PERM}" == "600" ]]; then
        assert_ok "notif-server.key tiene permisos 600"
    else
        assert_warn "notif-server.key tiene permisos ${PERM} (esperado: 600)"
    fi
else
    assert_warn "No se puede verificar: notif-server.key no existe"
fi

# ---------------------------------------------------------------------------
# 10. Validacion de vigencia de certificados (si openssl disponible)
# ---------------------------------------------------------------------------
section "TEST-F4-U002" "Validacion de vigencia de certificados"

if command -v openssl &>/dev/null; then
    subtest "Vigencia de pets-server.crt"
    if [[ -f "${SECURITY_DIR}/postgres/pets-server.crt" ]]; then
        openssl x509 -in "${SECURITY_DIR}/postgres/pets-server.crt" -noout -checkend 86400 &>/dev/null
        if [[ $? -eq 0 ]]; then
            assert_ok "pets-server.crt vigente (mas de 1 dia de validez)"
        else
            assert_fail "pets-server.crt expirado o expira en menos de 1 dia"
        fi
    else
        assert_warn "No se puede verificar: pets-server.crt no existe"
    fi

    subtest "Vigencia de ca.crt (pets-db)"
    if [[ -f "${SECURITY_DIR}/postgres/ca.crt" ]]; then
        openssl x509 -in "${SECURITY_DIR}/postgres/ca.crt" -noout -checkend 86400 &>/dev/null
        if [[ $? -eq 0 ]]; then
            assert_ok "ca.crt (pets-db) vigente"
        else
            assert_fail "ca.crt (pets-db) expirado o expira pronto"
        fi
    else
        assert_warn "No se puede verificar: ca.crt no existe"
    fi

    subtest "Vigencia de rabbitmq.crt"
    if [[ -f "${SECURITY_DIR}/rabbitmq/rabbitmq.crt" ]]; then
        openssl x509 -in "${SECURITY_DIR}/rabbitmq/rabbitmq.crt" -noout -checkend 86400 &>/dev/null
        if [[ $? -eq 0 ]]; then
            assert_ok "rabbitmq.crt vigente"
        else
            assert_fail "rabbitmq.crt expirado o expira pronto"
        fi
    else
        assert_warn "No se puede verificar: rabbitmq.crt no existe"
    fi
else
    assert_warn "openssl no disponible, saltando validacion de vigencia"
fi

# ---------------------------------------------------------------------------
# 11. Resumen
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  RESUMEN - Tests Unitarios Fase 4${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Pasados:   ${PASSED}${NC}"
echo -e "  ${RED}Fallidos:  ${FAILED}${NC}"
echo -e "  ${YELLOW}Advertencias: ${WARNINGS}${NC}"
echo -e "  ${BOLD}Total:     $((PASSED + FAILED + WARNINGS))${NC}"
echo ""

if [[ ${FAILED} -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Resultado: TODOS LOS TESTS CRITICOS PASARON${NC}"
    if [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "  ${YELLOW}Nota: Revisar ${WARNINGS} advertencia(s)${NC}"
    fi
    exit 0
else
    echo -e "  ${RED}${BOLD}Resultado: ${FAILED} TEST(S) FALLIDO(S)${NC}"
    exit 1
fi
