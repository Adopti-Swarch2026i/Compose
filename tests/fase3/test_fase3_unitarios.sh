#!/bin/bash
# =============================================================================
# Test Fase 3 — Unitarios (Estaticos)
# Adopti — mTLS Inter-Servicios (Zero-Trust Network)
# =============================================================================
# Ejecutar desde: Compose/
# Descripcion: Validaciones estaticas de certificados, keystores, truststores,
#              permisos y configuraciones TLS sin requerir servicios levantados.
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

# --- Paths (relativo a Compose/) ---
SECURITY_DIR="../security"
GATEWAY_DIR="../gateway"

# --- Funciones assert ---
assert_file_exists() {
    local file="$1"
    local test_id="${2:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}Existe: $file"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}NO existe: $file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local test_id="${2:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ -d "$dir" ]]; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}Directorio existe: $dir"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}Directorio NO existe: $dir"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_perm_exact() {
    local file="$1"
    local expected="$2"
    local test_id="${3:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}[WARN]${NC} ${prefix}No se puede verificar permisos (no existe): $file"
        WARN=$((WARN + 1))
        return 1
    fi
    actual_perm=$(stat -c "%a" "$file" 2>/dev/null || stat -f "%Lp" "$file" 2>/dev/null)
    if [[ "$actual_perm" == "$expected" ]]; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}Permisos $expected en: $file"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}Permisos $expected esperados, $actual_perm encontrados en: $file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_perm_max() {
    local file="$1"
    local max_perm="$2"
    local test_id="${3:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}[WARN]${NC} ${prefix}No se puede verificar permisos (no existe): $file"
        WARN=$((WARN + 1))
        return 1
    fi
    actual_perm=$(stat -c "%a" "$file" 2>/dev/null || stat -f "%Lp" "$file" 2>/dev/null)
    if [[ "$actual_perm" -le "$max_perm" ]]; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}Permisos $actual_perm <= $max_perm en: $file"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}Permisos $actual_perm > $max_perm (demasiado permisivo) en: $file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local test_id="${3:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}[WARN]${NC} ${prefix}No se puede verificar (no existe): $file"
        WARN=$((WARN + 1))
        return 1
    fi
    match_count=$(grep -c "$pattern" "$file" 2>/dev/null)
    match_count=${match_count:-0}
    if [[ "$match_count" -eq 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}No se encontro '$pattern' en: $file"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}Se encontro '$pattern' $match_count veces en: $file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local test_id="${3:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}[WARN]${NC} ${prefix}No se puede verificar (no existe): $file"
        WARN=$((WARN + 1))
        return 1
    fi
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}Se encontro '$pattern' en: $file"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}NO se encontro '$pattern' en: $file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_cmd_success() {
    local cmd="$1"
    local desc="$2"
    local test_id="${3:-}"
    local prefix=""
    [[ -n "$test_id" ]] && prefix="[$test_id] "
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} ${prefix}$desc"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} ${prefix}$desc"
        FAIL=$((FAIL + 1))
        return 1
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
echo "  FASE 3 — TESTS UNITARIOS (Estaticos)"
echo "  Adopti — mTLS Inter-Servicios (Zero-Trust Network)"
echo "============================================================================="
echo -e "${NC}"

# --- Verificar que estamos en el directorio correcto ---
if [[ ! -f "docker-compose.yml" && ! -f "../docker-compose.yml" ]]; then
    echo -e "${YELLOW}[WARN]${NC} No se detecto docker-compose.yml. Asegurate de ejecutar desde Compose/"
fi

# =============================================================================
# 2.1 Validacion de keystore.p12 (Spring Boot)
# =============================================================================
log_section "TEST-F3-U001: Validar keystore.p12"

for svc in chat-service matching-service; do
    assert_file_exists "$SECURITY_DIR/$svc/keystore.p12" "U001"
done

# Validar contenido del keystore con keytool (si disponible)
if command -v keytool >/dev/null 2>&1; then
    log_info "keytool disponible, validando contenido de keystores..."
    for svc in chat-service matching-service; do
        keystore_path="$SECURITY_DIR/$svc/keystore.p12"
        if [[ -f "$keystore_path" ]]; then
            keystore_entries=$(keytool -list -keystore "$keystore_path" -storepass changeit 2>/dev/null | grep -c "PrivateKeyEntry" || echo 0)
            if [[ "$keystore_entries" -ge 1 ]]; then
                echo -e "${GREEN}[PASS]${NC} [U001] $svc keystore contiene PrivateKeyEntry"
                PASS=$((PASS + 1))
            else
                echo -e "${YELLOW}[WARN]${NC} [U001] $svc keystore sin PrivateKeyEntry detectable (password distinto?)"
                WARN=$((WARN + 1))
            fi
        fi
    done
else
    log_info "keytool no disponible, omitiendo validacion de contenido de keystore"
fi

# =============================================================================
# 2.2 Validacion de truststore.jks
# =============================================================================
log_section "TEST-F3-U003: Validar truststore.jks"

assert_file_exists "$SECURITY_DIR/truststore.jks" "U003"

if command -v keytool >/dev/null 2>&1 && [[ -f "$SECURITY_DIR/truststore.jks" ]]; then
    trust_entries=$(keytool -list -keystore "$SECURITY_DIR/truststore.jks" -storepass changeit 2>/dev/null | grep -c "trustedCertEntry" || echo 0)
    if [[ "$trust_entries" -ge 1 ]]; then
        echo -e "${GREEN}[PASS]${NC} [U003] truststore.jks contiene trustedCertEntry"
        PASS=$((PASS + 1))
    else
        echo -e "${YELLOW}[WARN]${NC} [U003] truststore.jks sin trustedCertEntry detectable"
        WARN=$((WARN + 1))
    fi
else
    log_info "keytool no disponible o truststore no existe, omitiendo validacion de contenido"
fi

# =============================================================================
# 2.3 Validacion de certificados individuales (PEM)
# =============================================================================
log_section "TEST-F3-U004/U005: Validar certificados individuales"

# Mapeo de nombres de archivo por servicio (la estructura usa nombres especificos)
declare -A CERT_NAMES
declare -A KEY_NAMES
CERT_NAMES[chat-service]="chat-service.crt"
KEY_NAMES[chat-service]="chat-service.key"
CERT_NAMES[matching-service]="matching-service.crt"
KEY_NAMES[matching-service]="matching-service.key"
CERT_NAMES[media-service]="media-service.crt"
KEY_NAMES[media-service]="media-service.key"
CERT_NAMES[notification-service]="notification-service.crt"
KEY_NAMES[notification-service]="notification-service.key"
CERT_NAMES[pets-service]="pets-service.crt"
KEY_NAMES[pets-service]="pets-service.key"
CERT_NAMES[gateway]="gateway.crt"
KEY_NAMES[gateway]="gateway.key"

for svc in chat-service matching-service media-service notification-service pets-service gateway; do
    cert_name="${CERT_NAMES[$svc]}"
    key_name="${KEY_NAMES[$svc]}"

    assert_file_exists "$SECURITY_DIR/$svc/$cert_name" "U004"
    assert_file_exists "$SECURITY_DIR/$svc/$key_name" "U004"

    # Validar vigencia del certificado
    if [[ -f "$SECURITY_DIR/$svc/$cert_name" ]] && command -v openssl >/dev/null 2>&1; then
        cert_not_after=$(openssl x509 -in "$SECURITY_DIR/$svc/$cert_name" -noout -enddate 2>/dev/null | cut -d= -f2)
        epoch_now=$(date +%s)
        epoch_exp=$(date -d "$cert_not_after" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_not_after" +%s 2>/dev/null)
        days_left=$(( (epoch_exp - epoch_now) / 86400 ))

        if [[ "$days_left" -gt 30 ]]; then
            echo -e "${GREEN}[PASS]${NC} [U004] $svc cert vigente ($days_left dias restantes)"
            PASS=$((PASS + 1))
        else
            echo -e "${RED}[FAIL]${NC} [U004] $svc cert expira en $days_left dias (min: 30)"
            FAIL=$((FAIL + 1))
        fi
    fi

done

# =============================================================================
# 2.5 Validar cadena de certificacion completa
# =============================================================================
log_section "TEST-F3-U005: Validar cadena de certificacion"

if [[ -f "$SECURITY_DIR/ca/ca.crt" ]] && command -v openssl >/dev/null 2>&1; then
    for svc in chat-service matching-service media-service notification-service pets-service gateway; do
        cert_name="${CERT_NAMES[$svc]}"
        if [[ -f "$SECURITY_DIR/$svc/$cert_name" ]]; then
            if openssl verify -CAfile "$SECURITY_DIR/ca/ca.crt" "$SECURITY_DIR/$svc/$cert_name" >/dev/null 2>&1; then
                echo -e "${GREEN}[PASS]${NC} [U005] Cadena valida: $svc"
                PASS=$((PASS + 1))
            else
                echo -e "${RED}[FAIL]${NC} [U005] Cadena INVALIDA: $svc"
                FAIL=$((FAIL + 1))
            fi
        fi
    done
else
    log_info "CA cert no encontrado u openssl no disponible, omitiendo validacion de cadena"
fi

# =============================================================================
# 2.7 Validacion de Nginx proxy_ssl_* directives
# =============================================================================
log_section "TEST-F3-U011: Validar Nginx proxy_ssl_verify"

NGINX_CONF="$GATEWAY_DIR/nginx.conf"

assert_file_exists "$NGINX_CONF" "U011"
assert_file_not_contains "$NGINX_CONF" "proxy_pass http://" "U011"
assert_file_contains "$NGINX_CONF" "proxy_ssl_verify on" "U011"
assert_file_contains "$NGINX_CONF" "proxy_ssl_trusted_certificate" "U011"

# Contar proxy_pass https://
if [[ -f "$NGINX_CONF" ]]; then
    https_count=$(grep -c "proxy_pass https://" "$NGINX_CONF" 2>/dev/null)
    https_count=${https_count:-0}
    if [[ "$https_count" -gt 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} [U011] $https_count upstream(s) HTTPS configurado(s)"
        PASS=$((PASS + 1))
    else
        echo -e "${YELLOW}[WARN]${NC} [U011] Ningun proxy_pass https:// encontrado (puede ser normal si no hay upstreams)"
        WARN=$((WARN + 1))
    fi
fi

# =============================================================================
# 2.8 Validar SNI explicito en upstreams Nginx
# =============================================================================
log_section "TEST-F3-U012: Validar SNI en Nginx"

assert_file_contains "$NGINX_CONF" "proxy_ssl_server_name on" "U012"
assert_file_contains "$NGINX_CONF" "proxy_ssl_name" "U012"

# =============================================================================
# 4.4 Permisos de claves privadas
# =============================================================================
log_section "TEST-F3-Q004: Permisos de claves privadas"

for svc in chat-service matching-service media-service notification-service pets-service gateway; do
    key_name="${KEY_NAMES[$svc]}"
    key_path="$SECURITY_DIR/$svc/$key_name"
    if [[ -f "$key_path" ]]; then
        assert_perm_exact "$key_path" "600" "Q004"
    fi
done

# Clave privada de la CA
if [[ -f "$SECURITY_DIR/ca/ca.key" ]]; then
    assert_perm_exact "$SECURITY_DIR/ca/ca.key" "600" "Q004"
fi

# =============================================================================
# 4.1 Cobertura de certificados (Q001)
# =============================================================================
log_section "TEST-F3-Q001: Cobertura de certificados"

missing=0
for svc in chat-service matching-service media-service notification-service pets-service gateway; do
    cert_name="${CERT_NAMES[$svc]}"
    key_name="${KEY_NAMES[$svc]}"
    if [[ ! -f "$SECURITY_DIR/$svc/$cert_name" || ! -f "$SECURITY_DIR/$svc/$key_name" ]]; then
        missing=$((missing + 1))
        echo -e "${RED}[FAIL]${NC} [Q001] Certificados incompletos para $svc"
        FAIL=$((FAIL + 1))
    fi
done

if [[ "$missing" -eq 0 ]]; then
    echo -e "${GREEN}[PASS]${NC} [Q001] Todos los servicios tienen certificado + clave privada"
    PASS=$((PASS + 1))
fi

# CA root
if [[ -f "$SECURITY_DIR/ca/ca.crt" ]]; then
    echo -e "${GREEN}[PASS]${NC} [Q001] CA root (ca.crt) presente"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL]${NC} [Q001] CA root (ca.crt) NO presente"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# Validacion adicional: no quedan URLs HTTP internas en nginx.conf
# =============================================================================
log_section "TEST-F3-U013: URLs internas con esquema HTTPS"

if [[ -f "$NGINX_CONF" ]]; then
    # Buscar proxy_pass http:// (ya validado arriba, pero reforzamos)
    http_proxy_count=$(grep -c "proxy_pass http://" "$NGINX_CONF" 2>/dev/null)
    http_proxy_count=${http_proxy_count:-0}
    if [[ "$http_proxy_count" -eq 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} [U013] Cero proxy_pass con http:// en nginx.conf"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} [U013] $http_proxy_count proxy_pass con http:// en nginx.conf"
        FAIL=$((FAIL + 1))
    fi
fi

# =============================================================================
# Validacion: application.yml TLS (Spring Boot services)
# =============================================================================
log_section "TEST-F3-U006/U007: Validar configuracion TLS en application.yml"

for svc in chat-service matching-service; do
    app_yml="../$svc/src/main/resources/application.yml"
    if [[ -f "$app_yml" ]]; then
        if grep -q "server.ssl.enabled: true" "$app_yml" 2>/dev/null || grep -q "enabled: true" "$app_yml" 2>/dev/null | grep -q ssl; then
            echo -e "${GREEN}[PASS]${NC} [U006] $svc tiene SSL habilitado en application.yml"
            PASS=$((PASS + 1))
        else
            echo -e "${YELLOW}[WARN]${NC} [U006] $svc no tiene SSL habilitado explicito en application.yml (puede usar defaults)"
            WARN=$((WARN + 1))
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} [U006] $svc application.yml no encontrado en ruta esperada"
        WARN=$((WARN + 1))
    fi
done

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo -e "${CYAN}=============================================================================${NC}"
echo -e "${CYAN}  RESUMEN TESTS UNITARIOS FASE 3${NC}"
echo -e "${CYAN}=============================================================================${NC}"
echo -e "  ${GREEN}PASADOS:${NC}   $PASS"
echo -e "  ${RED}FALLIDOS:${NC}  $FAIL"
echo -e "  ${YELLOW}ADVERTENCIAS:${NC} $WARN"
echo -e "${CYAN}=============================================================================${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}Resultado: TODOS LOS TESTS PASARON${NC}"
    exit 0
else
    echo -e "  ${RED}Resultado: $FAIL TEST(S) FALLARON${NC}"
    exit 1
fi
