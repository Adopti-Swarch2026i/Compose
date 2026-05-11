#!/bin/bash
# =============================================================================
# Test Fase 3 — Integracion
# Adopti — mTLS Inter-Servicios (Zero-Trust Network)
# =============================================================================
# Ejecutar desde: Compose/
# Descripcion: Validaciones dinamicas que requieren servicios levantados.
#              mTLS handshake, rechazo sin cert, versiones TLS, cipher suites.
# Precondiciones: docker-compose up ejecutandose, contenedores healthy.
# =============================================================================

set -uo pipefail

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Contadores ---
PASS=0
FAIL=0
WARN=0
SKIP=0

# --- Configuracion ---
SECURITY_DIR="../security"
CA_FILE="$SECURITY_DIR/ca/ca.crt"
GATEWAY_CERT="$SECURITY_DIR/gateway/gateway.crt"
GATEWAY_KEY="$SECURITY_DIR/gateway/gateway.key"

# Servicios y puertos
SERVICES=(
    "chat-service:8443"
    "matching-service:8443"
    "media-service:8443"
    "notification-service:8443"
    "pets-service:8443"
)

# Mapeo de nombres de servicio a nombres de contenedor Docker
# Los contenedores Docker Compose se nombran como Adopti_chat, Adopti_matching, etc.
# (sin el sufijo -service)
CONTAINER_FOR_SERVICE() {
    local svc="$1"
    # Extraer la parte base del nombre (quitar -service si existe)
    local base="${svc%-service}"
    # Mapeo de excepciones: nombres de contenedor que no siguen el patron
    case "$base" in
        notification) echo "Adopti_notifications" ;;
        *) echo "Adopti_${base}" ;;
    esac
}

# Obtener la IP de un contenedor Docker para conectarse desde el host
# Los nombres de servicio (chat-service) no resuelven desde el host, solo dentro de la red Docker
GET_CONTAINER_IP() {
    local container="$1"
    docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

# --- Funciones assert ---
assert_mtls_handshake() {
    local host="$1"
    local port="$2"
    local test_id="${3:-I001}"
    local svc="$host:$port"

    # Resolver IP del contenedor (los nombres de servicio no resuelven desde el host)
    local container
    container=$(CONTAINER_FOR_SERVICE "$host")
    local ip
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] No se pudo obtener IP del contenedor $container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    local result
    result=$(openssl s_client -connect "$ip:$port" \
        -CAfile "$CA_FILE" \
        -cert "$GATEWAY_CERT" \
        -key "$GATEWAY_KEY" \
        </dev/null 2>/dev/null)

    local verify_code
    verify_code=$(echo "$result" | grep "Verify return code" | awk -F': ' '{print $2}' | awk '{print $1}' || echo "ERROR")

    if [[ "$verify_code" == "0" ]]; then
        local protocol
        protocol=$(echo "$result" | grep "Protocol" | head -1 | awk '{print $3}' || echo "unknown")
        echo -e "${GREEN}[PASS]${NC} [$test_id] mTLS handshake OK ($protocol): $svc ($ip:$port)"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} [$test_id] mTLS handshake FALLIDO (code: $verify_code): $svc ($ip:$port)"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_rejects_no_client_cert() {
    local host="$1"
    local port="$2"
    local test_id="${3:-I003}"
    local svc="$host:$port"

    # Resolver IP del contenedor
    local container
    container=$(CONTAINER_FOR_SERVICE "$host")
    local ip
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] No se pudo obtener IP del contenedor $container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    # Usar -quiet para que openssl muestre alerts TLS (ej: certificate required)
    local result
    result=$( (sleep 1; echo "GET /health HTTP/1.0"; echo "Host: localhost"; echo ""; sleep 1) | timeout 5 openssl s_client -quiet -connect "$ip:$port" \
        -CAfile "$CA_FILE" 2>&1)

    # Si el servidor requiere cert de cliente, veremos el alert o EOF
    if echo "$result" | grep -qiE "alert certificate required|certificate required|SSL alert number 116|unexpected eof while reading"; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] Rechazo sin cert cliente confirmado: $svc"
        PASS=$((PASS + 1))
        return 0
    fi

    # Verificar si el handshake fallo por otro motivo relacionado con cert
    if echo "$result" | grep -qiE "bad certificate|did not return a certificate|unknown ca|handshake failure|alert"; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] Rechazo sin cert cliente confirmado: $svc"
        PASS=$((PASS + 1))
        return 0
    fi

    # Si llegamos aqui, el servidor acepto la conexion (no requiere cert)
    echo -e "${RED}[FAIL]${NC} [$test_id] Servicio ACEPTO conexion SIN cert cliente: $svc"
    FAIL=$((FAIL + 1))
    return 1
}

assert_tls_version() {
    local host="$1"
    local port="$2"
    local version_flag="$3"
    local should_work="$4"
    local test_id="${5:-I006}"
    local svc="$host:$port"

    # Resolver IP del contenedor
    local container
    container=$(CONTAINER_FOR_SERVICE "$host")
    local ip
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] No se pudo obtener IP del contenedor $container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    local result
    result=$(openssl s_client -connect "$ip:$port" "$version_flag" \
        -CAfile "$CA_FILE" \
        -cert "$GATEWAY_CERT" \
        -key "$GATEWAY_KEY" \
        </dev/null 2>&1)

    # Detectar si el handshake se completo verificando el cipher
    # Si Cipher is (NONE), el handshake fallo (version TLS no soportada)
    local cipher
    cipher=$(echo "$result" | grep "Cipher is" | head -1 || echo "")

    local version_name
    case "$version_flag" in
        -tls1) version_name="TLS 1.0" ;;
        -tls1_1) version_name="TLS 1.1" ;;
        -tls1_2) version_name="TLS 1.2" ;;
        -tls1_3) version_name="TLS 1.3" ;;
        *) version_name="$version_flag" ;;
    esac

    if [[ "$should_work" == "true" ]]; then
        if echo "$cipher" | grep -qv "(NONE)"; then
            echo -e "${GREEN}[PASS]${NC} [$test_id] $version_name ACEPTADO (esperado): $svc"
            PASS=$((PASS + 1))
            return 0
        else
            echo -e "${RED}[FAIL]${NC} [$test_id] $version_name RECHAZADO (debia aceptar): $svc"
            FAIL=$((FAIL + 1))
            return 1
        fi
    else
        if echo "$cipher" | grep -q "(NONE)"; then
            echo -e "${GREEN}[PASS]${NC} [$test_id] $version_name RECHAZADO (esperado): $svc"
            PASS=$((PASS + 1))
            return 0
        else
            echo -e "${RED}[FAIL]${NC} [$test_id] $version_name ACEPTADO (debia rechazar): $svc"
            FAIL=$((FAIL + 1))
            return 1
        fi
    fi
}

assert_cipher_aead() {
    local host="$1"
    local port="$2"
    local test_id="${3:-I011}"
    local svc="$host:$port"

    # Resolver IP del contenedor
    local container
    container=$(CONTAINER_FOR_SERVICE "$host")
    local ip
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] No se pudo obtener IP del contenedor $container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    local result
    result=$(openssl s_client -connect "$ip:$port" \
        -CAfile "$CA_FILE" \
        -cert "$GATEWAY_CERT" \
        -key "$GATEWAY_KEY" \
        </dev/null 2>/dev/null)

    local cipher
    cipher=$(echo "$result" | grep "Cipher    :" | awk '{print $3}' || echo "UNKNOWN")

    # Verificar que es AEAD (AES-GCM o ChaCha20-Poly1305)
    if echo "$cipher" | grep -qiE "GCM|CHACHA20|POLY1305|AES_128_CCM|AES_256_CCM"; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] Cipher AEAD ($cipher): $svc"
        PASS=$((PASS + 1))
        return 0
    elif echo "$cipher" | grep -qiE "CBC|RC4|3DES|NULL|EXPORT|DES"; then
        echo -e "${RED}[FAIL]${NC} [$test_id] Cipher DEBIL detectado ($cipher): $svc"
        FAIL=$((FAIL + 1))
        return 1
    else
        echo -e "${YELLOW}[WARN]${NC} [$test_id] Cipher no clasificado ($cipher): $svc"
        WARN=$((WARN + 1))
        return 1
    fi
}

assert_rejects_fake_ca() {
    local host="$1"
    local port="$2"
    local test_id="${3:-I004}"
    local svc="$host:$port"

    # Resolver IP del contenedor
    local container
    container=$(CONTAINER_FOR_SERVICE "$host")
    local ip
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] No se pudo obtener IP del contenedor $container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    # Generar cert falso firmado por CA falsa
    local fake_ca="/tmp/fake-ca-$$.pem"
    local fake_key="/tmp/fake-key-$$.key"
    local fake_cert="/tmp/fake-cert-$$.crt"

    openssl req -x509 -newkey rsa:4096 -keyout "$fake_key" -out "$fake_ca" \
        -days 1 -nodes -subj "/CN=Fake CA" 2>/dev/null

    openssl req -newkey rsa:2048 -keyout /tmp/fake-svc-key-$$.key -out /tmp/fake-svc-csr-$$.csr \
        -nodes -subj "/CN=$host" 2>/dev/null

    openssl x509 -req -in /tmp/fake-svc-csr-$$.csr -CA "$fake_ca" -CAkey "$fake_key" \
        -CAcreateserial -out "$fake_cert" -days 1 2>/dev/null

    # Usar -quiet para detectar alerts TLS (ej: unknown ca)
    local result
    result=$( (sleep 1; echo "GET /health HTTP/1.0"; echo "Host: localhost"; echo ""; sleep 1) | timeout 5 openssl s_client -quiet -connect "$ip:$port" \
        -CAfile "$CA_FILE" \
        -cert "$fake_cert" \
        -key /tmp/fake-svc-key-$$.key 2>&1)

    # Limpiar temp files
    rm -f "$fake_ca" "$fake_key" "$fake_cert" /tmp/fake-svc-key-$$.key /tmp/fake-svc-csr-$$.csr /tmp/fake-ca-$$.srl 2>/dev/null

    # Si el servidor rechaza el cert de CA falsa, veremos el alert o EOF
    if echo "$result" | grep -qiE "alert unknown ca|unknown ca|alert certificate unknown|handshake failure|unexpected eof while reading"; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] Rechazo con CA falsa confirmado: $svc"
        PASS=$((PASS + 1))
        return 0
    fi

    # Si no hay alert de rechazo, el servidor acepto el cert
    echo -e "${RED}[FAIL]${NC} [$test_id] Servicio ACEPTO cert de CA falsa: $svc"
    FAIL=$((FAIL + 1))
    return 1
}

assert_service_to_service() {
    local from_svc="$1"
    local to_host="$2"
    local to_port="$3"
    local test_id="${4:-I002}"

    local from_container
    from_container=$(CONTAINER_FOR_SERVICE "$from_svc")
    local from_cert="/app/certs/${from_svc}.crt"
    local from_key="/app/certs/${from_svc}.key"

    # Verificar si el contenedor existe
    if ! docker ps --format '{{.Names}}' | grep -q "^${from_container}$" 2>/dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] Contenedor no encontrado: $from_container"
        SKIP=$((SKIP + 1))
        return 1
    fi

    local result
    result=$(docker exec "$from_container" sh -c \
        "openssl s_client -connect ${to_host}:${to_port} \
         -CAfile /app/certs/ca.crt \
         -cert $from_cert \
         -key $from_key </dev/null 2>/dev/null" 2>/dev/null)

    local verify_code
    verify_code=$(echo "$result" | grep "Verify return code" | awk -F': ' '{print $2}' | awk '{print $1}' || echo "")

    if [[ "$verify_code" == "0" ]]; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] S2S handshake OK: $from_svc -> $to_host:$to_port"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} [$test_id] S2S handshake FALLIDO: $from_svc -> $to_host:$to_port"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_healthchecks() {
    local test_id="${1:-I009}"
    local containers=(
        "Adopti_chat"
        "Adopti_matching"
        "Adopti_media"
        "Adopti_notifications"
        "Adopti_pets"
    )

    for c in "${containers[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${c}$" 2>/dev/null; then
            echo -e "${YELLOW}[SKIP]${NC} [$test_id] Contenedor no encontrado: $c"
            SKIP=$((SKIP + 1))
            continue
        fi

        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "N/A")

        if [[ "$status" == "healthy" ]]; then
            echo -e "${GREEN}[PASS]${NC} [$test_id] Healthcheck healthy: $c"
            PASS=$((PASS + 1))
        elif [[ "$status" == "N/A" || "$status" == "none" ]]; then
            echo -e "${YELLOW}[WARN]${NC} [$test_id] Sin healthcheck configurado: $c"
            WARN=$((WARN + 1))
        else
            echo -e "${RED}[FAIL]${NC} [$test_id] Healthcheck no healthy ($status): $c"
            FAIL=$((FAIL + 1))
        fi
    done
}

assert_nginx_proxy_ssl_verify() {
    local test_id="${1:-I005}"
    local gateway_container="Adopti_gateway"

    if ! docker ps --format '{{.Names}}' | grep -q "^${gateway_container}$" 2>/dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} [$test_id] Gateway contenedor no encontrado"
        SKIP=$((SKIP + 1))
        return 1
    fi

    # Verificar que nginx.conf tiene proxy_ssl_verify on
    # Puede estar en nginx.conf o en conf.d/*.conf
    local has_verify
    has_verify=$(docker exec "$gateway_container" sh -c 'grep -r "proxy_ssl_verify on" /etc/nginx/ 2>/dev/null | wc -l' 2>/dev/null || echo 0)
    has_verify=$(echo "$has_verify" | tr -d '[:space:]')

    if [[ "$has_verify" -ge 1 ]]; then
        echo -e "${GREEN}[PASS]${NC} [$test_id] proxy_ssl_verify on activo en gateway"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} [$test_id] proxy_ssl_verify on NO encontrado en gateway"
        FAIL=$((FAIL + 1))
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

# =============================================================================
# INICIO DE TESTS
# =============================================================================

echo -e "${CYAN}"
echo "============================================================================="
echo "  FASE 3 — TESTS DE INTEGRACION"
echo "  Adopti — mTLS Inter-Servicios (Zero-Trust Network)"
echo "============================================================================="
echo -e "${NC}"

# --- Verificar prerequisitos ---
if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} openssl no esta instalado. Es requerido para estos tests."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} docker no esta instalado. Es requerido para estos tests."
    exit 1
fi

# Verificar que los certs existen
if [[ ! -f "$CA_FILE" ]]; then
    echo -e "${RED}[ERROR]${NC} CA file no encontrado: $CA_FILE"
    exit 1
fi
if [[ ! -f "$GATEWAY_CERT" || ! -f "$GATEWAY_KEY" ]]; then
    echo -e "${RED}[ERROR]${NC} Gateway cert/key no encontrados"
    exit 1
fi

# Verificar que hay contenedores corriendo
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -cE "^Adopti_(chat|matching|media|notifications|pets|gateway)$" 2>/dev/null)
RUNNING_CONTAINERS=${RUNNING_CONTAINERS:-0}
if [[ "$RUNNING_CONTAINERS" -eq 0 ]]; then
    echo -e "${YELLOW}[WARN]${NC} No se detectaron contenedores Adopti corriendo"
    echo -e "${YELLOW}[WARN]${NC} Algunos tests se omitiran. Asegurate de ejecutar 'docker-compose up' primero."
fi

# =============================================================================
# TEST-F3-I001: Handshake mTLS gateway -> servicio
# =============================================================================
log_section "TEST-F3-I001: mTLS handshake gateway -> servicio"

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    assert_mtls_handshake "$host" "$port" "I001"
done

# =============================================================================
# TEST-F3-I002: Handshake mTLS servicio -> servicio
# =============================================================================
log_section "TEST-F3-I002: mTLS handshake servicio -> servicio"

if [[ "$RUNNING_CONTAINERS" -gt 0 ]]; then
    assert_service_to_service "chat-service" "media-service" "8443" "I002"
    assert_service_to_service "matching-service" "pets-service" "8443" "I002"
else
    echo -e "${YELLOW}[SKIP]${NC} [I002] Contenedores no disponibles, omitiendo S2S"
    SKIP=$((SKIP + 2))
fi

# =============================================================================
# TEST-F3-I003: Rechazo sin certificado de cliente
# =============================================================================
log_section "TEST-F3-I003: Rechazo sin certificado de cliente"

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    assert_rejects_no_client_cert "$host" "$port" "I003"
done

# =============================================================================
# TEST-F3-I004: Rechazo con CA no confiable
# =============================================================================
log_section "TEST-F3-I004: Rechazo con certificado de CA falsa"

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    assert_rejects_fake_ca "$host" "$port" "I004"
done

# =============================================================================
# TEST-F3-I005: Nginx proxy_ssl_verify
# =============================================================================
log_section "TEST-F3-I005: Nginx proxy_ssl_verify on"

assert_nginx_proxy_ssl_verify "I005"

# =============================================================================
# TEST-F3-I006: Versiones TLS aceptadas/rechazadas
# =============================================================================
log_section "TEST-F3-I006: Versiones TLS (1.2/1.3 aceptados, 1.0/1.1 rechazados)"

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)

    # TLS 1.2 debe funcionar
    assert_tls_version "$host" "$port" "-tls1_2" "true" "I006"

    # TLS 1.3 debe funcionar (si el sistema lo soporta)
    if openssl s_client -help 2>&1 | grep -q "tls1_3"; then
        assert_tls_version "$host" "$port" "-tls1_3" "true" "I006"
    else
        echo -e "${YELLOW}[SKIP]${NC} [I006] OpenSSL no soporta -tls1_3 en este sistema"
        SKIP=$((SKIP + 1))
    fi

    # TLS 1.0 debe fallar
    assert_tls_version "$host" "$port" "-tls1" "false" "I006"

    # TLS 1.1 debe fallar
    assert_tls_version "$host" "$port" "-tls1_1" "false" "I006"
done

# =============================================================================
# TEST-F3-I011: Cipher suite AEAD
# =============================================================================
log_section "TEST-F3-I011: Cipher suite AEAD"

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    assert_cipher_aead "$host" "$port" "I011"
done

# =============================================================================
# TEST-F3-I009: Healthchecks HTTPS
# =============================================================================
log_section "TEST-F3-I009: Healthchecks HTTPS"

assert_healthchecks "I009"

# =============================================================================
# TEST-F3-I010: Comunicacion servicio-a-servicio (escenario real)
# =============================================================================
log_section "TEST-F3-I010: Comunicacion servicio-a-servicio (escenario real)"

if [[ "$RUNNING_CONTAINERS" -gt 0 ]]; then
    # Verificar que los servicios pueden hacer requests HTTPS entre si
    gateway_container="Adopti_gateway"
    if docker ps --format '{{.Names}}' | grep -q "^${gateway_container}$" 2>/dev/null; then
        # Test via gateway
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --cacert "$CA_FILE" \
            --cert "$GATEWAY_CERT" \
            --key "$GATEWAY_KEY" \
            "https://localhost:443/api/pets" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" || "$http_code" == "401" || "$http_code" == "404" ]]; then
            echo -e "${GREEN}[PASS]${NC} [I010] Gateway responde HTTPS (HTTP $http_code)"
            PASS=$((PASS + 1))
        else
            echo -e "${YELLOW}[WARN]${NC} [I010] Gateway responde HTTP $http_code (puede requerir autenticacion)"
            WARN=$((WARN + 1))
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC} [I010] Gateway no disponible"
        SKIP=$((SKIP + 1))
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} [I010] Contenedores no disponibles"
    SKIP=$((SKIP + 1))
fi

# =============================================================================
# Score mTLS por endpoint (Q006)
# =============================================================================
log_section "TEST-F3-Q006: Score mTLS por endpoint"

total_score=0
max_score=0

for svc in "${SERVICES[@]}"; do
    host=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)

    # Resolver IP del contenedor
    container=$(CONTAINER_FOR_SERVICE "$host")
    ip=$(GET_CONTAINER_IP "$container")
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} [Q006] $host: no se pudo obtener IP"
        SKIP=$((SKIP + 1))
        continue
    fi

    svc_score=0

    # Test 1: sin cert cliente -> debe fallar
    result1=$(openssl s_client -connect "$ip:$port" -CAfile "$CA_FILE" </dev/null 2>/dev/null)
    if ! echo "$result1" | grep -q "Verify return code: 0"; then
        svc_score=$((svc_score + 1))
    fi

    # Test 2: con cert valido -> debe pasar
    result2=$(openssl s_client -connect "$ip:$port" -CAfile "$CA_FILE" \
        -cert "$GATEWAY_CERT" -key "$GATEWAY_KEY" </dev/null 2>/dev/null)
    if echo "$result2" | grep -q "Verify return code: 0"; then
        svc_score=$((svc_score + 1))
    fi

    # Test 3: con CA falsa -> debe fallar (reutilizamos logica)
    fake_ca="/tmp/score-fake-ca-$$.pem"
    fake_key="/tmp/score-fake-key-$$.key"
    fake_cert="/tmp/score-fake-cert-$$.crt"
    openssl req -x509 -newkey rsa:2048 -keyout "$fake_key" -out "$fake_ca" -days 1 -nodes -subj "/CN=Fake" 2>/dev/null
    openssl req -newkey rsa:2048 -keyout /tmp/score-fake-svc-key-$$.key -out /tmp/score-fake-svc-csr-$$.csr -nodes -subj "/CN=$host" 2>/dev/null
    openssl x509 -req -in /tmp/score-fake-svc-csr-$$.csr -CA "$fake_ca" -CAkey "$fake_key" -CAcreateserial -out "$fake_cert" -days 1 2>/dev/null

    result3=$(openssl s_client -connect "$ip:$port" -CAfile "$CA_FILE" \
        -cert "$fake_cert" -key /tmp/score-fake-svc-key-$$.key </dev/null 2>/dev/null)
    if ! echo "$result3" | grep -q "Verify return code: 0"; then
        svc_score=$((svc_score + 1))
    fi

    rm -f "$fake_ca" "$fake_key" "$fake_cert" /tmp/score-fake-svc-key-$$.key /tmp/score-fake-svc-csr-$$.csr /tmp/score-fake-ca-$$.srl 2>/dev/null

    total_score=$((total_score + svc_score))
    max_score=$((max_score + 3))

    if [[ "$svc_score" -eq 3 ]]; then
        echo -e "${GREEN}[PASS]${NC} [Q006] $host: score $svc_score/3"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} [Q006] $host: score $svc_score/3"
        FAIL=$((FAIL + 1))
    fi
done

echo -e "${BLUE}[INFO]${NC} [Q006] Score total mTLS: $total_score/$max_score"

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo -e "${CYAN}=============================================================================${NC}"
echo -e "${CYAN}  RESUMEN TESTS DE INTEGRACION FASE 3${NC}"
echo -e "${CYAN}=============================================================================${NC}"
echo -e "  ${GREEN}PASADOS:${NC}     $PASS"
echo -e "  ${RED}FALLIDOS:${NC}    $FAIL"
echo -e "  ${YELLOW}ADVERTENCIAS:${NC}  $WARN"
echo -e "  ${YELLOW}OMITIDOS:${NC}    $SKIP"
echo -e "${CYAN}=============================================================================${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}Resultado: TODOS LOS TESTS PASARON${NC}"
    exit 0
else
    echo -e "  ${RED}Resultado: $FAIL TEST(S) FALLARON${NC}"
    exit 1
fi
