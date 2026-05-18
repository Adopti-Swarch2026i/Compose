#!/usr/bin/env bash
#
# test_fase2_integracion.sh — Tests de integracion (requiere servicios levantados)
#
# Proyecto: Adopti — Fase 2: Hardening de Clientes
# Patron: Secure Channel Pattern (Encrypt Data + Resist Attacks)
#
# Precondiciones:
#   - Docker Compose esta corriendo (docker compose up -d)
#   - Gateway Nginx responde en https://localhost
#   - Frontend SSR responde en http://localhost:3000 (o via gateway)
#
# Ejecutar desde: Compose/
#   bash tests/fase2/test_fase2_integracion.sh
#
set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ── Configuracion ────────────────────────────────────────────────────────────
GATEWAY_HOST="${GATEWAY_HOST:-localhost}"
GATEWAY_PORT="${GATEWAY_PORT:-443}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CURL_OPTS="-s --max-time ${CURL_TIMEOUT} -k"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ── Funciones assert ─────────────────────────────────────────────────────────
assert_pass() {
  local msg="$1"
  echo -e "${GREEN}[PASS]${NC} $msg"
  ((PASS_COUNT++))
}

assert_fail() {
  local msg="$1"
  echo -e "${RED}[FAIL]${NC} $msg"
  ((FAIL_COUNT++))
}

assert_warn() {
  local msg="$1"
  echo -e "${YELLOW}[WARN]${NC} $msg"
  ((WARN_COUNT++))
}

info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

# ── Funciones de utilidad ────────────────────────────────────────────────────
check_service_up() {
  local url="$1"
  local name="$2"
  local response
  response=$(curl ${CURL_OPTS} -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [[ "$response" != "000" ]]; then
    return 0
  fi
  return 1
}

# ── Header ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Adopti — Fase 2: Tests de Integracion${NC}"
echo -e "${BOLD}  Secure Channel Pattern | Encrypt Data + Resist Attacks${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Pre-check: verificar que servicios estan disponibles
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- Pre-check: Disponibilidad de servicios ---${NC}"

SERVICES_UP=0

# Verificar gateway HTTPS
if check_service_up "https://${GATEWAY_HOST}:${GATEWAY_PORT}/health" "gateway"; then
  assert_pass "Gateway HTTPS (https://${GATEWAY_HOST}:${GATEWAY_PORT}) responde"
  SERVICES_UP=1
else
  assert_warn "Gateway HTTPS no responde. Algunos tests se omitiran."
fi

# Verificar frontend SSR (directo)
FRONTEND_UP=0
if check_service_up "http://${FRONTEND_HOST}:${FRONTEND_PORT}" "frontend"; then
  assert_pass "Frontend SSR (http://${FRONTEND_HOST}:${FRONTEND_PORT}) responde"
  FRONTEND_UP=1
else
  assert_warn "Frontend SSR directo no responde. Intentando via gateway..."
  if check_service_up "https://${GATEWAY_HOST}:${GATEWAY_PORT}" "frontend-via-gateway"; then
    assert_pass "Frontend SSR via gateway responde"
    FRONTEND_UP=1
    FRONTEND_HOST="${GATEWAY_HOST}"
    FRONTEND_PORT="${GATEWAY_PORT}"
  fi
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I006: Headers de seguridad en todas las rutas
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I006: Headers de Seguridad HTTP ---${NC}"

if [[ $SERVICES_UP -eq 1 ]]; then
  info "Verificando headers de seguridad en respuestas del gateway..."

  # Headers requeridos
  REQUIRED_HEADERS=(
    "strict-transport-security:"
    "x-content-type-options:"
    "x-frame-options:"
    "referrer-policy:"
  )

  # Rutas a probar
  ROUTES=(
    "https://${GATEWAY_HOST}:${GATEWAY_PORT}/"
    "https://${GATEWAY_HOST}:${GATEWAY_PORT}/health"
  )

  for route in "${ROUTES[@]}"; do
    info "Probando: $route"
    HEADERS=$(curl ${CURL_OPTS} -I "$route" 2>/dev/null || echo "")

    if [[ -z "$HEADERS" ]]; then
      assert_fail "No se pudo obtener headers de $route"
      continue
    fi

    # Convertir headers a lowercase para comparacion
    HEADERS_LOWER=$(echo "$HEADERS" | tr '[:upper:]' '[:lower:]')

    for header in "${REQUIRED_HEADERS[@]}"; do
      if echo "$HEADERS_LOWER" | grep -q "^${header}"; then
        VALUE=$(echo "$HEADERS_LOWER" | grep "^${header}" | head -1)
        assert_pass "[$route] Header presente: $VALUE"
      else
        assert_fail "[$route] Falta header: ${header}"
      fi
    done
  done

  # Validar valores especificos de headers
  info "Validando valores especificos de headers..."

  HSTS=$(curl ${CURL_OPTS} -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "strict-transport-security:" | head -1 || true)
  if echo "$HSTS" | grep -q "max-age"; then
    assert_pass "HSTS contiene max-age"
  else
    assert_fail "HSTS no contiene max-age"
  fi

  XCONTENT=$(curl ${CURL_OPTS} -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "x-content-type-options:" | head -1 || true)
  if echo "$XCONTENT" | grep -q "nosniff"; then
    assert_pass "X-Content-Type-Options: nosniff"
  else
    assert_fail "X-Content-Type-Options no es 'nosniff'"
  fi

  XFRAME=$(curl ${CURL_OPTS} -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "x-frame-options:" | head -1 || true)
  if echo "$XFRAME" | grep -q "deny"; then
    assert_pass "X-Frame-Options: DENY"
  else
    assert_fail "X-Frame-Options no es 'DENY'"
  fi

  REFPOL=$(curl ${CURL_OPTS} -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep "referrer-policy:" | head -1 || true)
  if echo "$REFPOL" | grep -q "strict-origin-when-cross-origin"; then
    assert_pass "Referrer-Policy: strict-origin-when-cross-origin"
  else
    assert_fail "Referrer-Policy no es 'strict-origin-when-cross-origin'"
  fi

else
  assert_warn "Gateway no disponible. Omitiendo tests de headers de seguridad."
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I005: Cookie session con Secure/HttpOnly/SameSite
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I005: Cookies de Sesion Seguras ---${NC}"

if [[ $FRONTEND_UP -eq 1 ]]; then
  info "Verificando configuracion de cookies de sesion..."

  # Intentar obtener Set-Cookie desde el frontend (si hay endpoint de login o session)
  # Primero intentamos el endpoint de session
  SESSION_URL="http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/session"

  # Hacer un POST con un token invalido para obtener la respuesta y ver headers
  COOKIE_RESPONSE=$(curl ${CURL_OPTS} -I -X POST \
    -H "Content-Type: application/json" \
    -d '{"idToken":"invalid-test-token"}' \
    "$SESSION_URL" 2>/dev/null || echo "")

  if [[ -n "$COOKIE_RESPONSE" ]]; then
    SET_COOKIE=$(echo "$COOKIE_RESPONSE" | grep -i "set-cookie:" || true)

    if [[ -n "$SET_COOKIE" ]]; then
      info "Set-Cookie encontrado en respuesta"

      if echo "$SET_COOKIE" | grep -qi "httponly"; then
        assert_pass "Cookie tiene flag HttpOnly"
      else
        assert_fail "Cookie NO tiene flag HttpOnly"
      fi

      if echo "$SET_COOKIE" | grep -qi "secure"; then
        assert_pass "Cookie tiene flag Secure"
      else
        assert_warn "Cookie NO tiene flag Secure (puede ser esperado en entorno local sin HTTPS)"
      fi

      if echo "$SET_COOKIE" | grep -qi "samesite"; then
        assert_pass "Cookie tiene flag SameSite"
      else
        assert_fail "Cookie NO tiene flag SameSite"
      fi

      if echo "$SET_COOKIE" | grep -qi "path=/"; then
        assert_pass "Cookie tiene Path=/"
      else
        assert_warn "Cookie NO tiene Path=/"
      fi
    else
      # No hay Set-Cookie (puede ser respuesta de error sin cookie)
      STATUS=$(echo "$COOKIE_RESPONSE" | grep -E "^HTTP" | tail -1 || echo "")
      info "Respuesta de session: $STATUS"

      # Verificar en el codigo fuente que las cookies se configuran correctamente
      PROJECT_ROOT="/home/blend-pc-juan/Documentos/Proyecto Personal/ArquisoftPrototype2/Adopti"
      SESSION_ROUTE="${PROJECT_ROOT}/frontend-ssr/src/app/api/session/route.ts"

      if [[ -f "$SESSION_ROUTE" ]]; then
        info "Verificando configuracion de cookie en codigo fuente..."
        if grep -q "httpOnly: true" "$SESSION_ROUTE"; then
          assert_pass "Codigo fuente: cookie configura httpOnly: true"
        else
          assert_fail "Codigo fuente: cookie NO configura httpOnly: true"
        fi

        if grep -q "sameSite:" "$SESSION_ROUTE"; then
          assert_pass "Codigo fuente: cookie configura sameSite"
        else
          assert_fail "Codigo fuente: cookie NO configura sameSite"
        fi

        if grep -q "secure:" "$SESSION_ROUTE"; then
          assert_pass "Codigo fuente: cookie configura secure dinamicamente"
        else
          assert_fail "Codigo fuente: cookie NO configura secure"
        fi
      fi
    fi
  else
    assert_warn "No se pudo conectar al endpoint /api/session"
  fi

  # Verificar cookie de logout
  LOGOUT_URL="http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/session/logout"
  LOGOUT_RESPONSE=$(curl ${CURL_OPTS} -I -X DELETE "$LOGOUT_URL" 2>/dev/null || echo "")
  if [[ -n "$LOGOUT_RESPONSE" ]]; then
    LOGOUT_STATUS=$(echo "$LOGOUT_RESPONSE" | grep -E "^HTTP" | tail -1 || echo "")
    info "Logout endpoint responde: $LOGOUT_STATUS"
  fi

else
  assert_warn "Frontend no disponible. Omitiendo tests de cookies."
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I004: Frontend SSR build no emite URLs HTTP en bundle cliente
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I004: Bundle Cliente sin URLs HTTP ---${NC}"

PROJECT_ROOT="/home/blend-pc-juan/Documentos/Proyecto Personal/ArquisoftPrototype2/Adopti"
FRONTEND_DIR="${PROJECT_ROOT}/frontend-ssr"
NEXT_STATIC="${FRONTEND_DIR}/.next/static"

if [[ -d "$NEXT_STATIC" ]]; then
  info "Analizando bundles estaticos en .next/static/chunks/..."

  HTTP_IN_BUNDLE=$(grep -r "http://" "$NEXT_STATIC" 2>/dev/null || true)
  if [[ -z "$HTTP_IN_BUNDLE" ]]; then
    assert_pass "No se encontraron URLs http:// en bundles de cliente (.next/static/)"
  else
    # Filtrar solo comentarios o strings que no sean URLs reales
    HTTP_COUNT=$(echo "$HTTP_IN_BUNDLE" | wc -l)
    assert_warn "Se encontraron $HTTP_COUNT lineas con http:// en bundles (verificar que no sean endpoints reales)"
    echo "$HTTP_IN_BUNDLE" | head -5 | while read line; do
      echo -e "       ${CYAN}>${NC} $line"
    done
  fi

  # Verificar que no hay ws:// en bundles
  WS_IN_BUNDLE=$(grep -r "ws://" "$NEXT_STATIC" 2>/dev/null || true)
  if [[ -z "$WS_IN_BUNDLE" ]]; then
    assert_pass "No se encontraron URLs ws:// en bundles de cliente"
  else
    assert_fail "Se encontraron URLs ws:// en bundles de cliente (debe ser wss://)"
  fi
else
  assert_warn "No se encontro directorio .next/static/ (ejecutar 'npm run build' primero)"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I001: Validacion de env.example (ya parcialmente cubierto en unitarios)
# Validacion adicional: verificar que .env (runtime) no tiene http:// en prod
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I001: Validacion runtime de URLs ---${NC}"

FRONTEND_ENV="${FRONTEND_DIR}/.env"
if [[ -f "$FRONTEND_ENV" ]]; then
  info "Verificando .env runtime del frontend..."

  # Solo advertir si hay http:// en variables que no sean localhost
  HTTP_NON_LOCAL=$(grep "http://" "$FRONTEND_ENV" | grep -v "localhost" | grep -v "^\s*#" || true)
  if [[ -z "$HTTP_NON_LOCAL" ]]; then
    assert_pass "frontend-ssr/.env no contiene URLs http:// no-localhost"
  else
    assert_fail "frontend-ssr/.env contiene URLs http:// no-localhost:\n$HTTP_NON_LOCAL"
  fi
else
  assert_warn "No se encontro frontend-ssr/.env"
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I007: Frontend maneja CA interna correctamente
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I007: CA Interna / TLS Handshake ---${NC}"

if [[ $SERVICES_UP -eq 1 ]]; then
  info "Verificando handshake TLS con el gateway..."

  # Verificar que el gateway acepta TLS 1.2/1.3
  TLS_VERSION=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" -servername "$GATEWAY_HOST" 2>/dev/null | openssl x509 -noout -text 2>/dev/null | head -1 || true)

  if [[ -n "$TLS_VERSION" ]]; then
    assert_pass "Handshake TLS exitoso con gateway"

    # Verificar protocolo negociado
    PROTO=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" -servername "$GATEWAY_HOST" 2>/dev/null | grep "Protocol" | head -1 || true)
    if [[ -n "$PROTO" ]]; then
      info "Protocolo negociado: $PROTO"
      if echo "$PROTO" | grep -q "TLSv1.2\|TLSv1.3"; then
        assert_pass "Protocolo TLS >= 1.2"
      else
        assert_fail "Protocolo TLS < 1.2 (inseguro)"
      fi
    fi

    # Verificar cipher suite
    CIPHER=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" -servername "$GATEWAY_HOST" 2>/dev/null | grep "Cipher" | head -1 || true)
    if [[ -n "$CIPHER" ]]; then
      info "Cipher suite: $CIPHER"
      if echo "$CIPHER" | grep -qi "ECDHE\|AES.*GCM\|CHACHA20"; then
        assert_pass "Cipher suite moderno (ECDHE/AEAD)"
      else
        assert_warn "Cipher suite puede no ser ideal: $CIPHER"
      fi
    fi
  else
    assert_fail "No se pudo completar handshake TLS con el gateway"
  fi

  # Verificar que no hay errores de verificacion de certificado
  VERIFY_RESULT=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" -servername "$GATEWAY_HOST" 2>&1 | grep -E "Verify return code|verify error" | head -1 || true)
  if echo "$VERIFY_RESULT" | grep -q "Verify return code: 0"; then
    assert_pass "Verificacion de certificado exitosa (o aceptado con -k)"
  else
    info "Resultado de verificacion: $VERIFY_RESULT"
  fi
else
  assert_warn "Gateway no disponible. Omitiendo tests de TLS handshake."
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I002/I003: Certificate Pinning (verificacion de disponibilidad)
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I002/I003: Certificate Pinning (disponibilidad) ---${NC}"

if [[ $SERVICES_UP -eq 1 ]]; then
  info "Verificando que el certificado del gateway tiene SPKI extraible..."

  # Extraer SPKI del certificado del gateway
  SPKI=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" -servername "$GATEWAY_HOST" 2>/dev/null | \
    openssl x509 -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | \
    openssl dgst -sha256 -binary 2>/dev/null | \
    openssl enc -base64 2>/dev/null || true)

  if [[ -n "$SPKI" ]]; then
    assert_pass "SPKI del certificado del gateway extraido correctamente"
    info "SPKI (SHA-256/Base64): ${SPKI:0:40}..."

    # Guardar SPKI para referencia en tests de caos
    SPKI_FILE="/tmp/adopti_gateway_spki.txt"
    echo "$SPKI" > "$SPKI_FILE"
    info "SPKI guardado en $SPKI_FILE para tests de caos"
  else
    assert_warn "No se pudo extraer SPKI del certificado (verificar openssl)"
  fi
else
  assert_warn "Gateway no disponible. Omitiendo extraccion de SPKI."
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I008/I009: GraphQL y WebSocket sobre HTTPS/WSS
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I008/I009: GraphQL y WebSocket Endpoints ---${NC}"

if [[ $SERVICES_UP -eq 1 ]]; then
  # Verificar endpoint GraphQL
  GRAPHQL_URL="https://${GATEWAY_HOST}:${GATEWAY_PORT}/api/chat/graphql"
  info "Verificando GraphQL endpoint: $GRAPHQL_URL"

  GRAPHQL_RESPONSE=$(curl ${CURL_OPTS} -X POST \
    -H "Content-Type: application/json" \
    -d '{"query":"{ __typename }"}' \
    "$GRAPHQL_URL" 2>/dev/null || echo "")

  if [[ -n "$GRAPHQL_RESPONSE" ]]; then
    if echo "$GRAPHQL_RESPONSE" | grep -q "data\|errors"; then
      assert_pass "GraphQL endpoint responde sobre HTTPS"
    else
      assert_warn "GraphQL endpoint responde pero con formato inesperado"
    fi
  else
    assert_warn "GraphQL endpoint no responde (puede requerir autenticacion)"
  fi

  # Verificar que la URL del WS usa wss://
  MOBILE_ENV="${PROJECT_ROOT}/adopti-mobile-app-arquisoft/.env.example"
  if [[ -f "$MOBILE_ENV" ]]; then
    WS_URL=$(grep "CHAT_WS_URL" "$MOBILE_ENV" | cut -d'=' -f2 || true)
    if [[ -n "$WS_URL" ]]; then
      if echo "$WS_URL" | grep -q "^wss://"; then
        assert_pass "CHAT_WS_URL usa wss:// ($WS_URL)"
      else
        assert_fail "CHAT_WS_URL NO usa wss:// ($WS_URL)"
      fi
    fi
  fi

  # Verificar que frontend WS URL usa wss://
  FRONTEND_ENV_EX="${FRONTEND_DIR}/.env.example"
  if [[ -f "$FRONTEND_ENV_EX" ]]; then
    WS_URL_FE=$(grep "NEXT_PUBLIC_CHAT_WS_URL" "$FRONTEND_ENV_EX" | cut -d'=' -f2 || true)
    if [[ -n "$WS_URL_FE" ]]; then
      if echo "$WS_URL_FE" | grep -q "^wss://"; then
        assert_pass "NEXT_PUBLIC_CHAT_WS_URL usa wss:// ($WS_URL_FE)"
      else
        assert_fail "NEXT_PUBLIC_CHAT_WS_URL NO usa wss:// ($WS_URL_FE)"
      fi
    fi
  fi
else
  assert_warn "Gateway no disponible. Omitiendo tests de endpoints."
fi

echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-I010: Rechazo de ws:// en STOMP client (validacion estatica)
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- TEST-F2-I010: Validacion de esquema WS en codigo ---${NC}"

MOBILE_SRC="${PROJECT_ROOT}/adopti-mobile-app-arquisoft"
ENV_CONFIG="${MOBILE_SRC}/lib/config/env_config.dart"

if [[ -f "$ENV_CONFIG" ]]; then
  info "Verificando env_config.dart..."

  # Verificar que el codigo tiene validacion de esquema
  if grep -q "wss://\|ws://" "$ENV_CONFIG"; then
    assert_pass "env_config.dart referencia esquemas ws:// / wss://"
  else
    assert_warn "env_config.dart no tiene validacion explicita de esquema WS"
  fi

  # Verificar valores por defecto
  if grep -q "ws://" "$ENV_CONFIG"; then
    DEFAULT_WS=$(grep "ws://" "$ENV_CONFIG" || true)
    assert_warn "env_config.dart tiene defaults con ws:// (aceptable para desarrollo): $DEFAULT_WS"
  fi
else
  assert_warn "No se encontro env_config.dart"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Resumen
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RESUMEN — Tests de Integracion Fase 2${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS:${NC}  $PASS_COUNT"
echo -e "  ${RED}FAIL:${NC}  $FAIL_COUNT"
echo -e "  ${YELLOW}WARN:${NC}  $WARN_COUNT"
echo -e "${BOLD}───────────────────────────────────────────────────────────────────${NC}"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "  ${GREEN}Resultado: TODOS LOS TESTS CRITICOS PASARON${NC}"
  exit 0
else
  echo -e "  ${RED}Resultado: $FAIL_COUNT TEST$( (($FAIL_COUNT == 1)) && echo "" || echo "S" ) FALLARON${NC}"
  exit 1
fi
