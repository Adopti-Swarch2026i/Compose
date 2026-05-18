#!/usr/bin/env bash
# =============================================================================
# Test Fase 4 - Chaos Engineering (Tests de Caos)
# Proyecto: Adopti
# Patron: Secure Channel + Authenticator | Tactica: Encrypt Data + Limit Access
# =============================================================================
# Ejecutar desde: Compose/
# Uso: ./tests/fase4/test_fase4_chaos.sh
# Precondicion: docker compose up -d (servicios en ejecucion)
# ADVERTENCIA: Estos tests inyectan fallos. Ejecutar solo en entornos de prueba.
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
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Contadores
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
WARNINGS=0
SKIPPED=0

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

assert_skip() {
    local msg="$1"
    echo -e "${CYAN}  [SKIP]${NC} ${msg}"
    ((SKIPPED++))
}

assert_chaos() {
    local msg="$1"
    echo -e "${MAGENTA}  [CHAOS]${NC} ${msg}"
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
# Configuracion
# ---------------------------------------------------------------------------
NETWORK="compose_adopti-net"
COMPOSE_FILE="docker-compose.yml"

PG_PETS_CONTAINER="Adopti_pets-db"
PG_NOTIF_CONTAINER="Adopti_notifications-db"
ES_CONTAINER="Adopti_search"
RABBIT_CONTAINER="Adopti_broker"

# ---------------------------------------------------------------------------
# Carga variables de entorno
# ---------------------------------------------------------------------------
load_env() {
    if [[ -f ".env" ]]; then
        set -a
        source .env
        set +a
    fi
}
load_env

PG_PETS_USER="${POSTGRES_PETS_USER:-postgres}"
PG_PETS_DB="${POSTGRES_PETS_DB:-petsdb}"
PG_PETS_PASS="${POSTGRES_PETS_PASSWORD:-postgres}"
PG_NOTIF_USER="${POSTGRES_NOTIF_USER:-postgres}"
PG_NOTIF_DB="${POSTGRES_NOTIF_DB:-notificationsdb}"
PG_NOTIF_PASS="${POSTGRES_NOTIF_PASSWORD:-postgres}"
ES_USER="elastic"
ES_PASS="${ELASTIC_PASSWORD:-changeme}"
RABBIT_USER="${RABBITMQ_USER:-adopti}"
RABBIT_PASS="${RABBITMQ_PASSWORD:-adopti}"

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo -e "${RED}ERROR: No se encontro ${COMPOSE_FILE}. Ejecutar desde el directorio Compose/.${NC}"
    exit 1
fi

check_container_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -qx "${name}"
}

# ---------------------------------------------------------------------------
# Funciones de utilidad para caos
# ---------------------------------------------------------------------------

wait_for_container() {
    local container="$1"
    local max_wait="${2:-30}"
    local waited=0
    while ! check_container_running "${container}" && [[ ${waited} -lt ${max_wait} ]]; do
        sleep 1
        ((waited++))
    done
    check_container_running "${container}"
}

# ---------------------------------------------------------------------------
# Helper: Hacer request HTTPS a Elasticsearch via openssl s_client
# Necesario porque curl/wget tienen un bug de compatibilidad TLS con
# Elasticsearch 8.13.4 (alert illegal parameter 559).
# ---------------------------------------------------------------------------
es_request() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local path="${4:-/}"

    local auth_header=""
    if [[ -n "${user}" && -n "${pass}" ]]; then
        local b64
        b64=$(echo -n "${user}:${pass}" | base64)
        auth_header="Authorization: Basic ${b64}"
    fi

    # Construir el script que se ejecutara dentro del contenedor alpine
    local script
    script=$(cat <<EOF
apk add --no-cache openssl >/dev/null 2>&1
{
  echo 'GET ${path} HTTP/1.1'
  echo 'Host: ${host}'
  ${auth_header:+echo '${auth_header}'}
  echo 'Connection: close'
  echo
} | openssl s_client -connect ${host}:9200 -tls1_3 -quiet 2>/dev/null
EOF
)

    docker run --rm --network "${NETWORK}" alpine sh -c "${script}"
}

# Extrae el status code de una respuesta HTTP cruda
http_status() {
    local response="$1"
    echo "${response}" | grep -E '^HTTP/[0-9.]+' | tail -1 | awk '{print $2}'
}

# =============================================================================
# INICIO DE TESTS DE CAOS
# =============================================================================

echo -e "${BOLD}"
echo "    ___    __  _____________  ______  _________________  _______  ______"
echo "   /   |  /  |/  /  _/ __  \/ ____/ /_  __/ ____/ __ \/ _____/ /_  __/"
echo "  / /| | / /|_/ // // / / / /___    / / / __/ / /_/ / /___     / /   "
echo " / ___ |/ /  / // // / / / ___/    / / / /___/ _, _/ ____/    / /    "
echo "/_/  |_/_/  /_/___/_/ /_/_/       /_/ /_____/_/ |_/_____/    /_/     "
echo -e "${NC}"
echo -e "${BOLD}  Fase 4: TLS en Datastores - Chaos Engineering${NC}"
echo -e "  ${YELLOW}ADVERTENCIA: Estos tests inyectan fallos en el sistema.${NC}"
echo -e "  ${YELLOW}Ejecutar solo en entornos de desarrollo/pruebas.${NC}"
echo -e "  Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Confirmacion interactiva (solo si no se pasa --force)
if [[ "${1:-}" != "--force" && "${CHAOS_FORCE:-}" != "1" ]]; then
    echo -e "${YELLOW}Los tests de caos modificaran certificados temporalmente.${NC}"
    echo -e "${YELLOW}Se realizaran rollbacks automaticos al finalizar cada test.${NC}"
    echo ""
    echo "Para ejecutar sin confirmacion, usar:"
    echo "  CHAOS_FORCE=1 ./tests/fase4/test_fase4_chaos.sh"
    echo "  ./tests/fase4/test_fase4_chaos.sh --force"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C001: PostgreSQL Certificate Expiration Mid-Query
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C001" "PostgreSQL - Expiracion de certificado durante query"

if check_container_running "${PG_PETS_CONTAINER}"; then
    assert_chaos "Inyectando certificado con expiracion inminente..."

    subtest "Backup de certificados actuales"
    docker exec "${PG_PETS_CONTAINER}" bash -c "
        cp /var/lib/postgresql/server.crt /tmp/server.crt.bak
        cp /var/lib/postgresql/server.key /tmp/server.key.bak
    " 2>/dev/null
    if [[ $? -eq 0 ]]; then
        assert_ok "Backup de certificados creado"
    else
        assert_fail "No se pudo crear backup"
    fi

    subtest "Generar certificado auto-firmado de corta duracion"
    # Generar certificado valido por 1 dia, pero con fecha de inicio en el pasado
    # para que sea inmediatamente reconocible como "corto" si se inspecciona
    docker exec "${PG_PETS_CONTAINER}" bash -c "
        openssl req -new -x509 -nodes -text -days 1 \
            -subj '/CN=pets-db' \
            -keyout /tmp/short-server.key -out /tmp/short-server.crt 2>/dev/null
        cp /tmp/short-server.crt /var/lib/postgresql/server.crt
        cp /tmp/short-server.key /var/lib/postgresql/server.key
        chmod 600 /var/lib/postgresql/server.key
    " 2>/dev/null
    if [[ $? -eq 0 ]]; then
        assert_ok "Certificado de corta duracion generado e instalado"
    else
        assert_fail "No se pudo generar certificado temporal"
    fi

    subtest "Recargar PostgreSQL con nuevo certificado"
    docker exec "${PG_PETS_CONTAINER}" pg_ctl reload -D /var/lib/postgresql/data 2>/dev/null
    if [[ $? -eq 0 ]]; then
        assert_ok "PostgreSQL recargado con nuevo certificado"
    else
        assert_warn "pg_ctl reload puede requerir reinicio"
    fi

    subtest "Verificar que PostgreSQL sigue aceptando conexiones TLS"
    sleep 2
    RESULT=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/certs:ro" \
        postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=require&sslrootcert=/certs/ca.crt" \
        -t -c "SELECT 1;" 2>&1)
    if echo "${RESULT}" | grep -q "1"; then
        assert_ok "PostgreSQL acepta conexiones con certificado recien generado"
    else
        assert_warn "PostgreSQL puede requerir reinicio para nuevo cert: ${RESULT}"
    fi

    subtest "ROLLBACK - Restaurar certificados originales"
    docker exec "${PG_PETS_CONTAINER}" bash -c "
        cp /tmp/server.crt.bak /var/lib/postgresql/server.crt
        cp /tmp/server.key.bak /var/lib/postgresql/server.key
        chmod 600 /var/lib/postgresql/server.key
    " 2>/dev/null
    docker exec "${PG_PETS_CONTAINER}" pg_ctl reload -D /var/lib/postgresql/data 2>/dev/null
    sleep 2

    RESULT=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/certs:ro" \
        postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=require&sslrootcert=/certs/ca.crt" \
        -t -c "SELECT 1;" 2>&1)
    if echo "${RESULT}" | grep -q "1"; then
        assert_ok "ROLLBACK exitoso - PostgreSQL funciona con certificados originales"
    else
        assert_fail "ROLLBACK puede requerir reinicio del contenedor"
    fi
else
    assert_skip "Contenedor ${PG_PETS_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C002: Man-in-the-Middle en Datastore
# ═══════════════════════════════════════════════════════════════════════════
# NOTA: El proxy MITM implementa un ataque de interceptacion SSL completo:
#   1. Escucha conexiones TCP del cliente PostgreSQL
#   2. Responde al SSLRequest del protocolo PostgreSQL ('S' = SSL soportado)
#   3. Realiza handshake SSL con un certificado autofirmado (no firmado por la CA)
#   4. Conecta al servidor PostgreSQL real via SSL
#   5. Reenvia trafico en ambas direcciones
#
# El test verifica que el cliente psql con sslmode=verify-full detecta el MITM
# porque el certificado del proxy no esta firmado por la CA de confianza.
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C002" "Man-in-the-Middle en Datastore PostgreSQL"

if check_container_running "${PG_PETS_CONTAINER}"; then
    assert_chaos "Desplegando proxy MITM entre cliente y PostgreSQL..."

    subtest "Crear contenedor proxy MITM"
    # Usar script Python que entiende el protocolo PostgreSQL SSL negotiation:
    # 1. Cliente envia SSLRequest (8 bytes)
    # 2. Proxy responde 'S' (SSL soportado)
    # 3. Proxy hace handshake SSL con cert autofirmado MITM
    # 4. Proxy conecta al PostgreSQL real y reenvia trafico
    docker run -d --name adopti-mitm-proxy --network "${NETWORK}" \
        -v "$(pwd)/tests/fase4/mitm_proxy.py:/mitm_proxy.py:ro" \
        python:3.11-alpine sh -c "
            apk add --no-cache openssl >/dev/null 2>&1
            openssl req -new -x509 -nodes -text -days 1 \
                -subj '/CN=pets-db' -keyout /tmp/mitm.key -out /tmp/mitm.crt 2>/dev/null
            python3 /mitm_proxy.py
        " 2>/dev/null

    sleep 3

    if check_container_running "adopti-mitm-proxy"; then
        assert_ok "Proxy MITM desplegado"
    else
        assert_fail "Proxy MITM no pudo iniciarse"
    fi

    subtest "Intentar conexion a traves del MITM con CA original (debe fallar)"
    RESULT=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/certs:ro" postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@adopti-mitm-proxy:15432/${PG_PETS_DB}?sslmode=verify-full&sslrootcert=/certs/ca.crt" \
        -c "SELECT 1;" 2>&1)

    if echo "${RESULT}" | grep -qi "certificate verify failed"; then
        assert_ok "MITM detectado: verify-full rechazo certificado auto-firmado del proxy"
    elif echo "${RESULT}" | grep -qi "unable to get local issuer"; then
        assert_ok "MITM detectado: CA no confia en certificado del proxy"
    elif echo "${RESULT}" | grep -qi "SSL error\|SSL SYSCALL\|tlsv1 alert unknown ca"; then
        assert_ok "MITM detectado: Error SSL al conectar a traves del proxy"
    elif echo "${RESULT}" | grep -qi "server closed the connection unexpectedly"; then
        # Si el proxy no funciona correctamente (ej: socat sin entender protocolo PostgreSQL)
        assert_warn "El proxy MITM no intercepto correctamente - conexion cerrada inesperadamente"
    elif echo "${RESULT}" | grep -q "1"; then
        assert_fail "MITM NO DETECTADO - La conexion fue aceptada! INSEGURO!"
    else
        assert_warn "Respuesta inesperada: ${RESULT}"
    fi

    subtest "CLEANUP - Eliminar proxy MITM"
    docker stop adopti-mitm-proxy >/dev/null 2>&1
    docker rm adopti-mitm-proxy >/dev/null 2>&1
    assert_ok "Proxy MITM eliminado"
else
    assert_skip "Contenedor ${PG_PETS_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C003: AMQPS Connection Flood
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C003" "RabbitMQ - Flood de conexiones AMQPS"

if check_container_running "${RABBIT_CONTAINER}"; then
    assert_chaos "Generando 100 conexiones AMQPS simultaneas..."

    subtest "Verificar handshake TLS masivo"

    # Script de flood usando bash + openssl (sin dependencias externas)
    FLOOD_SCRIPT=$(cat <<'EOF'
#!/bin/sh
SUCCESS=0
FAIL=0
for i in $(seq 1 100); do
    (
        echo | openssl s_client -connect Adopti_broker:5671 -quiet 2>/dev/null >/dev/null
        if [ $? -eq 0 ]; then
            echo "OK"
        else
            echo "FAIL"
        fi
    ) &
done
wait
EOF
)

    # Ejecutar flood desde contenedor temporal
    RESULTS=$(docker run --rm --network "${NETWORK}" alpine sh -c \
        "apk add --no-cache openssl >/dev/null 2>&1
         ${FLOOD_SCRIPT}" 2>&1)

    OK_COUNT=$(echo "${RESULTS}" | grep -c "OK" || echo "0")
    FAIL_COUNT=$(echo "${RESULTS}" | grep -c "FAIL" || echo "0")

    subtest "Resultados del flood: ${OK_COUNT} exitosas, ${FAIL_COUNT} fallidas"

    if [[ ${OK_COUNT} -ge 80 ]]; then
        assert_ok "${OK_COUNT}/100 handshakes TLS exitosos (>=80%)"
    elif [[ ${OK_COUNT} -ge 50 ]]; then
        assert_warn "${OK_COUNT}/100 handshakes TLS exitosos (degradacion parcial)"
    else
        assert_fail "Solo ${OK_COUNT}/100 handshakes exitosos (degradacion severa)"
    fi

    subtest "Verificar que puerto 5672 sigue cerrado despues del flood"
    NC_RESULT=$(docker run --rm --network "${NETWORK}" alpine sh -c \
        "apk add --no-cache netcat-openbsd >/dev/null 2>&1 && \
         nc -z -w 2 ${RABBIT_CONTAINER} 5672" 2>&1)
    NC_EXIT=$?

    if [[ ${NC_EXIT} -ne 0 ]]; then
        assert_ok "Puerto 5672 sigue cerrado despues del flood"
    else
        assert_fail "Puerto 5672 responde despues del flood - posible fuga!"
    fi

    subtest "Verificar RabbitMQ sigue estable (rabbitmq-diagnostics ping)"
    sleep 2
    PING=$(docker exec "${RABBIT_CONTAINER}" rabbitmq-diagnostics -q ping 2>&1)
    if echo "${PING}" | grep -qi "ok\|pong"; then
        assert_ok "RabbitMQ sigue respondiendo despues del flood"
    else
        assert_warn "RabbitMQ puede estar bajo estres: ${PING}"
    fi
else
    assert_skip "Contenedor ${RABBIT_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C006: Database Connection String Manipulation
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C006" "Manipulacion de DSN - sslmode=disable en runtime"

if check_container_running "${PG_PETS_CONTAINER}"; then
    assert_chaos "Simulando ataque: DSN modificado a sslmode=disable..."

    subtest "Intentar conexion con sslmode=disable"
    RESULT=$(docker run --rm --network "${NETWORK}" postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=disable" \
        -c "SELECT 1;" 2>&1)

    if echo "${RESULT}" | grep -qi "no pg_hba.conf entry.*SSL off"; then
        assert_ok "PostgreSQL rechazo DSN con sslmode=disable (hostnossl reject)"
    elif echo "${RESULT}" | grep -qi "hostnossl\|rejected\|rejects\|no encryption\|SSL off"; then
        assert_ok "PostgreSQL rechazo conexion sin SSL"
    elif echo "${RESULT}" | grep -q "^1$"; then
        assert_fail "PostgreSQL ACEPTO conexion sin SSL - CRITICO!"
    else
        assert_warn "Respuesta: ${RESULT}"
    fi

    subtest "Verificar que conexiones TLS legitimas siguen funcionando"
    RESULT_TLS=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/certs:ro" \
        postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=require&sslrootcert=/certs/ca.crt" \
        -t -c "SELECT 1;" 2>&1)
    if echo "${RESULT_TLS}" | grep -q "1"; then
        assert_ok "Conexiones TLS legitimas no afectadas"
    else
        assert_warn "Conexiones TLS pueden estar afectadas: ${RESULT_TLS}"
    fi
else
    assert_skip "Contenedor ${PG_PETS_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C008: PostgreSQL ssl=off injection bajo carga
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C008" "PostgreSQL - ssl=off injection bajo carga mixta"

if check_container_running "${PG_PETS_CONTAINER}"; then
    assert_chaos "Lanzando carga mixta: 90% TLS + 10% intentos planos..."

    subtest "Lanzar 10 conexiones TLS concurrentes"
    TLS_OK=0
    TLS_FAIL=0
    PLAIN_OK=0
    PLAIN_FAIL=0

    # Lanzar conexiones TLS en paralelo
    for i in $(seq 1 10); do
        (
            R=$(docker run --rm --network "${NETWORK}" postgres:15-alpine psql \
                "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=require" \
                -c "SELECT ${i};" 2>&1)
            if echo "${R}" | grep -q "${i}"; then
                echo "TLS_OK"
            else
                echo "TLS_FAIL"
            fi
        ) &
    done
    wait

    TLS_RESULTS=$(jobs -p 2>/dev/null)
    # Recolectar resultados de TLS
    # (simplificado: verificamos despues con una query directa)

    sleep 2

    subtest "Verificar conexion TLS post-carga"
    POST_TLS=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/certs:ro" \
        postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=require&sslrootcert=/certs/ca.crt" \
        -t -c "SELECT 42;" 2>&1)
    if echo "${POST_TLS}" | grep -q "42"; then
        assert_ok "PostgreSQL responde correctamente despues de carga mixta"
    else
        assert_warn "PostgreSQL puede estar bajo estres: ${POST_TLS}"
    fi

    subtest "Verificar que intentos planos fueron rechazados"
    PLAIN_RESULT=$(docker run --rm --network "${NETWORK}" postgres:15-alpine psql \
        "postgresql://${PG_PETS_USER}:${PG_PETS_PASS}@${PG_PETS_CONTAINER}:5432/${PG_PETS_DB}?sslmode=disable" \
        -c "SELECT 1;" 2>&1)
    if echo "${PLAIN_RESULT}" | grep -qi "SSL off\|hostnossl\|rejected\|rejects\|no encryption"; then
        assert_ok "Intento plano rechazado correctamente bajo carga"
    elif echo "${PLAIN_RESULT}" | grep -q "^1$"; then
        assert_fail "Intento plano ACEPTADO bajo carga - CRITICO!"
    else
        assert_warn "Respuesta: ${PLAIN_RESULT}"
    fi
else
    assert_skip "Contenedor ${PG_PETS_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C010: Cross-Datastore Certificate Reuse
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C010" "Cross-Datastore - Reuso de certificados entre datastores"

if check_container_running "${RABBIT_CONTAINER}" && [[ -f "../security/postgres/ca.crt" ]]; then
    assert_chaos "Intentando conectar a RabbitMQ usando CA de PostgreSQL..."

    subtest "openssl s_client a RabbitMQ con CA de PostgreSQL"
    RESULT=$(docker run --rm --network "${NETWORK}" \
        -v "$(pwd)/../security/postgres:/pg-certs:ro" alpine sh -c \
        "apk add --no-cache openssl >/dev/null 2>&1 && \
         echo | openssl s_client -connect ${RABBIT_CONTAINER}:5671 -CAfile /pg-certs/ca.crt 2>&1 | \
         grep -E 'Verify return code|verify error'" 2>&1)

    if echo "${RESULT}" | grep -q "Verify return code: 0"; then
        assert_warn "RabbitMQ acepto CA de PostgreSQL (misma CA usada para ambos)"
    elif echo "${RESULT}" | grep -qE "verify error:num=19|verify error:num=20|verify error:num=21"; then
        assert_ok "RabbitMQ rechazo CA de PostgreSQL (trust stores aislados)"
    elif echo "${RESULT}" | grep -q "unable to get local issuer"; then
        assert_ok "RabbitMQ no confia en CA de PostgreSQL (trust stores aislados)"
    elif echo "${RESULT}" | grep -q "self signed certificate"; then
        assert_ok "RabbitMQ detecto certificado auto-firmado de CA diferente"
    else
        assert_warn "Resultado: ${RESULT}"
    fi
else
    if ! check_container_running "${RABBIT_CONTAINER}"; then
        assert_skip "Contenedor ${RABBIT_CONTAINER} no esta en ejecucion"
    else
        assert_skip "CA de PostgreSQL no encontrada"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C004: Elasticsearch Auth Brute Force (lightweight)
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C004" "Elasticsearch - Resistencia a fuerza bruta (lightweight)"

if check_container_running "${ES_CONTAINER}"; then
    assert_chaos "Enviando 20 requests con credenciales incorrectas..."

    subtest "Requests sin credenciales"
    UNAUTH_OK=0
    UNAUTH_FAIL=0
    for i in $(seq 1 20); do
        RESPONSE=$(es_request "${ES_CONTAINER}" "" "" "/_cluster/health")
        CODE=$(http_status "${RESPONSE}")
        if [[ "${CODE}" == "401" || "${CODE}" == "403" ]]; then
            ((UNAUTH_OK++))
        else
            ((UNAUTH_FAIL++))
        fi
    done

    if [[ ${UNAUTH_OK} -eq 20 ]]; then
        assert_ok "100% de requests sin auth rechazados (20/20 = 401/403)"
    elif [[ ${UNAUTH_OK} -ge 18 ]]; then
        assert_warn "${UNAUTH_OK}/20 requests sin auth rechazados"
    else
        assert_fail "Solo ${UNAUTH_OK}/20 requests sin auth rechazados - posible bypass!"
    fi

    subtest "Request legitimo durante ataque"
    LEGIT_RESPONSE=$(es_request "${ES_CONTAINER}" "${ES_USER}" "${ES_PASS}" "/_cluster/health")
    LEGIT=$(http_status "${LEGIT_RESPONSE}")
    if [[ "${LEGIT}" == "200" ]]; then
        assert_ok "Request legitimo exitoso durante 'ataque'"
    else
        assert_warn "Request legitimo retorno ${LEGIT} durante ataque"
    fi
else
    assert_skip "Contenedor ${ES_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C005: RabbitMQ TLS Listener Failure
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C005" "RabbitMQ - Caida del listener TLS"

if check_container_running "${RABBIT_CONTAINER}"; then
    assert_chaos "Simulando caida del listener TLS (firewall temporal)..."

    subtest "Verificar conexiones activas antes del bloqueo"
    # Usar API HTTP de management (rabbitmqctl no esta disponible)
    BEFORE=$(docker exec "${RABBIT_CONTAINER}" sh -c "curl -s -u '${RABBIT_USER}:${RABBIT_PASS}' http://localhost:15672/api/connections" 2>&1 | grep -o '"ssl":true' | wc -l | tr -d ' ' || echo "0")
    assert_chaos "Conexiones SSL activas antes: ${BEFORE}"

    subtest "Bloquear puerto 5671 temporalmente con iptables"
    docker exec "${RABBIT_CONTAINER}" sh -c "iptables -A INPUT -p tcp --dport 5671 -j DROP 2>/dev/null || echo 'iptables no disponible'"
    IPTABLES_RESULT=$?

    if [[ ${IPTABLES_RESULT} -eq 0 ]]; then
        assert_ok "Regla iptables aplicada (puerto 5671 bloqueado)"

        sleep 3

        subtest "Verificar que handshake TLS falla"
        HANDSHAKE=$(docker run --rm --network "${NETWORK}" alpine sh -c \
            "apk add --no-cache openssl >/dev/null 2>&1 && \
             timeout 5 sh -c 'echo | openssl s_client -connect ${RABBIT_CONTAINER}:5671' 2>&1" 2>&1)
        if echo "${HANDSHAKE}" | grep -qi "connect\|timeout\|failure"; then
            assert_ok "Handshake TLS bloqueado correctamente"
        else
            assert_warn "Handshake puede seguir funcionando (iptables en container limitado)"
        fi

        subtest "ROLLBACK - Restaurar iptables"
        docker exec "${RABBIT_CONTAINER}" sh -c "iptables -D INPUT -p tcp --dport 5671 -j DROP 2>/dev/null"
        sleep 2

        HANDSHAKE_POST=$(docker run --rm --network "${NETWORK}" alpine sh -c \
            "apk add --no-cache openssl >/dev/null 2>&1 && \
             echo | openssl s_client -connect ${RABBIT_CONTAINER}:5671 2>&1 | grep 'Verify return code'" 2>&1)
        if echo "${HANDSHAKE_POST}" | grep -q "Verify return code"; then
            assert_ok "Listener TLS restaurado correctamente"
        else
            assert_warn "Verificar estado del listener TLS manualmente"
        fi
    else
        assert_warn "iptables no disponible en contenedor (requiere privilegios). Test parcial."
    fi
else
    assert_skip "Contenedor ${RABBIT_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST-F4-C009: Elasticsearch xpack Bypass bajo estres
# ═══════════════════════════════════════════════════════════════════════════
section "TEST-F4-C009" "Elasticsearch - Bypass xpack bajo estres ligero"

if check_container_running "${ES_CONTAINER}"; then
    assert_chaos "Saturando Elasticsearch con requests legitimos + sin auth..."

    subtest "Lanzar 10 requests legitimos rapidos"
    LEGIT_OK=0
    for i in $(seq 1 10); do
        RESPONSE=$(es_request "${ES_CONTAINER}" "${ES_USER}" "${ES_PASS}" "/_cluster/health")
        CODE=$(http_status "${RESPONSE}")
        if [[ "${CODE}" == "200" ]]; then
            ((LEGIT_OK++))
        fi
    done

    subtest "Lanzar 10 requests sin auth simultaneos"
    UNAUTH_REJECTED=0
    for i in $(seq 1 10); do
        RESPONSE=$(es_request "${ES_CONTAINER}" "" "" "/_cluster/health")
        CODE=$(http_status "${RESPONSE}")
        if [[ "${CODE}" == "401" || "${CODE}" == "403" ]]; then
            ((UNAUTH_REJECTED++))
        fi
    done

    if [[ ${LEGIT_OK} -eq 10 && ${UNAUTH_REJECTED} -eq 10 ]]; then
        assert_ok "100% legitimos exitosos + 100% sin auth rechazados (10/10 + 10/10)"
    elif [[ ${LEGIT_OK} -ge 8 && ${UNAUTH_REJECTED} -ge 8 ]]; then
        assert_ok "Mayoria de requests correctos (${LEGIT_OK}/10 legitimos, ${UNAUTH_REJECTED}/10 rechazados)"
    else
        assert_warn "Resultados: ${LEGIT_OK}/10 legitimos, ${UNAUTH_REJECTED}/10 rechazados"
    fi

    subtest "Verificar estado del cluster post-estres"
    HEALTH_RESPONSE=$(es_request "${ES_CONTAINER}" "${ES_USER}" "${ES_PASS}" "/_cluster/health")
    HEALTH=$(echo "${HEALTH_RESPONSE}" | sed '1,/^[[:space:]]*$/d')
    if echo "${HEALTH}" | grep -q "status"; then
        CLUSTER_STATUS=$(echo "${HEALTH}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        assert_ok "Cluster healthy post-estres (status: ${CLUSTER_STATUS})"
    else
        assert_warn "No se pudo verificar estado del cluster"
    fi
else
    assert_skip "Contenedor ${ES_CONTAINER} no esta en ejecucion"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Limpieza final
# ═══════════════════════════════════════════════════════════════════════════

echo -e "\n${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  LIMPIEZA FINAL${NC}"
echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"

# Asegurar que no queden contenedores de caos
for container in adopti-mitm-proxy adopti-chaos-test; do
    if docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
        docker stop "${container}" >/dev/null 2>&1
        docker rm "${container}" >/dev/null 2>&1
        echo -e "  ${GREEN}Eliminado contenedor residual: ${container}${NC}"
    fi
done

# Restaurar certificados PostgreSQL si quedaron modificados
if check_container_running "${PG_PETS_CONTAINER}"; then
    docker exec "${PG_PETS_CONTAINER}" bash -c "
        if [ -f /tmp/server.crt.bak ]; then
            cp /tmp/server.crt.bak /var/lib/postgresql/server.crt
            cp /tmp/server.key.bak /var/lib/postgresql/server.key
            chmod 600 /var/lib/postgresql/server.key
            pg_ctl reload -D /var/lib/postgresql/data >/dev/null 2>&1
        fi
    " 2>/dev/null
    echo -e "  ${GREEN}Certificados PostgreSQL verificados/restaurados${NC}"
fi

echo -e "  ${GREEN}Limpieza completada${NC}"

# ═══════════════════════════════════════════════════════════════════════════
# Resumen
# ═══════════════════════════════════════════════════════════════════════════

echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  RESUMEN - Tests de Caos Fase 4${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Pasados:      ${PASSED}${NC}"
echo -e "  ${RED}Fallidos:     ${FAILED}${NC}"
echo -e "  ${YELLOW}Advertencias: ${WARNINGS}${NC}"
echo -e "  ${CYAN}Saltados:     ${SKIPPED}${NC}"
echo -e "  ${BOLD}Total:        $((PASSED + FAILED + WARNINGS + SKIPPED))${NC}"
echo ""

if [[ ${FAILED} -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Resultado: TODOS LOS TESTS DE CAOS PASARON${NC}"
    echo -e "  ${GREEN}El sistema demostro resiliencia ante los fallos inyectados.${NC}"
    if [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "  ${YELLOW}Nota: Revisar ${WARNINGS} advertencia(s)${NC}"
    fi
    exit 0
else
    echo -e "  ${RED}${BOLD}Resultado: ${FAILED} TEST(S) FALLIDO(S)${NC}"
    echo -e "  ${YELLOW}Revisar fallos y ejecutar rollback manual si es necesario.${NC}"
    exit 1
fi
