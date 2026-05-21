#!/usr/bin/env bash
#
# test_fase2_unitarios.sh — Tests estaticos (sin servicios levantados)
#
# Proyecto: Adopti — Fase 2: Hardening de Clientes
# Patron: Secure Channel Pattern (Encrypt Data + Resist Attacks)
#
# Ejecutar desde: Compose/
#   bash tests/fase2/test_fase2_unitarios.sh
#
set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT="/home/blend-pc-juan/Documentos/Proyecto Personal/ArquisoftPrototype2/Adopti"
FRONTEND_ENV="${PROJECT_ROOT}/frontend-ssr/.env.example"
MOBILE_ENV="${PROJECT_ROOT}/adopti-mobile-app-arquisoft/.env.example"
FRONTEND_SRC="${PROJECT_ROOT}/frontend-ssr/src"
MOBILE_SRC="${PROJECT_ROOT}/adopti-mobile-app-arquisoft"

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

# ── Header ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Adopti — Fase 2: Tests Unitarios (Estaticos)${NC}"
echo -e "${BOLD}  Secure Channel Pattern | Encrypt Data + Resist Attacks${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U001 / TEST-F2-U003: EnvConfig / Zod rechaza HTTP en produccion
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}--- Grupo 1: Validacion de URLs HTTPS en .env.example ---${NC}"

# 1.1 Validar que frontend-ssr/.env.example no contiene http://
info "TEST-F2-U003: Validando frontend-ssr/.env.example (sin http://)..."
if [[ -f "$FRONTEND_ENV" ]]; then
  HTTP_MATCHES=$(grep -n "http://" "$FRONTEND_ENV" 2>/dev/null || true)
  if [[ -z "$HTTP_MATCHES" ]]; then
    assert_pass "frontend-ssr/.env.example no contiene URLs http://"
  else
    # Excluir comentarios/documentacion (lineas que empiezan con #)
    NON_COMMENT_HTTP=$(echo "$HTTP_MATCHES" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -z "$NON_COMMENT_HTTP" ]]; then
      assert_pass "frontend-ssr/.env.example: solo comentarios contienen http:// (ok)"
    else
      assert_fail "frontend-ssr/.env.example contiene http:// en valores activos:\n$NON_COMMENT_HTTP"
    fi
  fi
else
  assert_fail "No se encontro frontend-ssr/.env.example"
fi

# 1.2 Validar que adopti-mobile-app-arquisoft/.env.example no contiene http://
info "TEST-F2-U001: Validando adopti-mobile-app-arquisoft/.env.example (sin http://)..."
if [[ -f "$MOBILE_ENV" ]]; then
  HTTP_MATCHES=$(grep -n "http://" "$MOBILE_ENV" 2>/dev/null || true)
  if [[ -z "$HTTP_MATCHES" ]]; then
    assert_pass "adopti-mobile-app-arquisoft/.env.example no contiene URLs http://"
  else
    # Excluir comentarios/documentacion (lineas que empiezan con #, con o sin numero de linea)
    NON_COMMENT_HTTP=$(echo "$HTTP_MATCHES" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -z "$NON_COMMENT_HTTP" ]]; then
      assert_pass "mobile/.env.example: solo comentarios contienen http:// (ok)"
    else
      assert_fail "mobile/.env.example contiene http:// en valores activos:\n$NON_COMMENT_HTTP"
    fi
  fi
else
  assert_fail "No se encontro adopti-mobile-app-arquisoft/.env.example"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U004: Cookie config es Secure + HttpOnly + SameSite
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 2: Configuracion de Cookies de Sesion ---${NC}"

info "TEST-F2-U004: Validando SESSION_COOKIE_SECURE en frontend-ssr/.env.example..."
if [[ -f "$FRONTEND_ENV" ]]; then
  if grep -q "SESSION_COOKIE_SECURE=true" "$FRONTEND_ENV"; then
    assert_pass "frontend-ssr/.env.example tiene SESSION_COOKIE_SECURE=true"
  else
    assert_fail "frontend-ssr/.env.example NO tiene SESSION_COOKIE_SECURE=true"
  fi
else
  assert_fail "No se encontro frontend-ssr/.env.example"
fi

# Validar que la cookie en el codigo fuente usa httpOnly y secure
info "Validando opciones de cookie en codigo fuente (session/route.ts)..."
SESSION_ROUTE="${FRONTEND_SRC}/app/api/session/route.ts"
if [[ -f "$SESSION_ROUTE" ]]; then
  if grep -q "httpOnly: true" "$SESSION_ROUTE"; then
    assert_pass "session/route.ts establece httpOnly: true"
  else
    assert_fail "session/route.ts NO establece httpOnly: true"
  fi

  if grep -q "secure:" "$SESSION_ROUTE"; then
    assert_pass "session/route.ts configura secure dinamicamente"
  else
    assert_fail "session/route.ts NO configura secure"
  fi

  if grep -q "sameSite:" "$SESSION_ROUTE"; then
    assert_pass "session/route.ts configura sameSite"
  else
    assert_fail "session/route.ts NO configura sameSite"
  fi
else
  assert_fail "No se encontro session/route.ts"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U008 / TEST-F2-U010: WebSocket URL usa wss:// no ws://
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 3: Validacion de WebSocket URLs (wss:// vs ws://) ---${NC}"

info "TEST-F2-U008/U010: Validando ausencia de ws:// en .env.example files..."

# 3.1 Frontend SSR
if [[ -f "$FRONTEND_ENV" ]]; then
  WS_MATCHES=$(grep -n "ws://" "$FRONTEND_ENV" 2>/dev/null || true)
  if [[ -z "$WS_MATCHES" ]]; then
    assert_pass "frontend-ssr/.env.example no contiene ws:// (solo wss://)"
  else
    NON_COMMENT_WS=$(echo "$WS_MATCHES" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -z "$NON_COMMENT_WS" ]]; then
      assert_pass "frontend-ssr/.env.example: solo comentarios contienen ws:// (ok)"
    else
      assert_fail "frontend-ssr/.env.example contiene ws:// en valores activos:\n$NON_COMMENT_WS"
    fi
  fi
else
  assert_fail "No se encontro frontend-ssr/.env.example"
fi

# 3.2 Mobile app
if [[ -f "$MOBILE_ENV" ]]; then
  WS_MATCHES=$(grep -n "ws://" "$MOBILE_ENV" 2>/dev/null || true)
  if [[ -z "$WS_MATCHES" ]]; then
    assert_pass "mobile/.env.example no contiene ws:// (solo wss://)"
  else
    NON_COMMENT_WS=$(echo "$WS_MATCHES" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -z "$NON_COMMENT_WS" ]]; then
      assert_pass "mobile/.env.example: solo comentarios contienen ws:// (ok)"
    else
      assert_fail "mobile/.env.example contiene ws:// en valores activos:\n$NON_COMMENT_WS"
    fi
  fi
else
  assert_fail "No se encontro mobile/.env.example"
fi

# 3.3 Validar que mobile env.example tiene wss:// para WS
if [[ -f "$MOBILE_ENV" ]]; then
  if grep -q "wss://" "$MOBILE_ENV"; then
    assert_pass "mobile/.env.example contiene al menos una URL wss://"
  else
    assert_warn "mobile/.env.example NO contiene URLs wss://"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U009: Headers de seguridad presentes en respuesta
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 4: Headers de Seguridad HTTP (nginx.conf) ---${NC}"

info "TEST-F2-U009: Validando headers de seguridad en gateway/nginx.conf..."
NGINX_CONF="${PROJECT_ROOT}/gateway/nginx.conf"
if [[ -f "$NGINX_CONF" ]]; then
  if grep -q "Strict-Transport-Security" "$NGINX_CONF"; then
    assert_pass "nginx.conf contiene Strict-Transport-Security (HSTS)"
  else
    assert_fail "nginx.conf NO contiene Strict-Transport-Security"
  fi

  if grep -q "X-Content-Type-Options" "$NGINX_CONF"; then
    assert_pass "nginx.conf contiene X-Content-Type-Options"
  else
    assert_fail "nginx.conf NO contiene X-Content-Type-Options"
  fi

  if grep -q "X-Frame-Options" "$NGINX_CONF"; then
    assert_pass "nginx.conf contiene X-Frame-Options"
  else
    assert_fail "nginx.conf NO contiene X-Frame-Options"
  fi

  if grep -q "Referrer-Policy" "$NGINX_CONF"; then
    assert_pass "nginx.conf contiene Referrer-Policy"
  else
    assert_fail "nginx.conf NO contiene Referrer-Policy"
  fi
else
  assert_fail "No se encontro gateway/nginx.conf"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U005/U006/U007: Certificate Pinning (verificacion estatica de codigo)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 5: Certificate Pinning (codigo fuente) ---${NC}"

info "TEST-F2-U005/U006/U007: Buscando implementacion de certificate pinning..."

# Buscar archivos relacionados con certificate pinning en el proyecto mobile
PINNING_FILES=$(find "$MOBILE_SRC" -type f -name "*.dart" | xargs grep -l "pinning\|Pinning\|SPKI\|spki\|certificate.*hash\|public.*key.*hash" 2>/dev/null || true)
if [[ -n "$PINNING_FILES" ]]; then
  assert_pass "Se encontraron archivos con logica de certificate pinning:"
  for f in $PINNING_FILES; do
    echo -e "       ${BLUE}->${NC} $(basename "$f")"
  done
else
  assert_warn "No se encontro implementacion de certificate pinning en el codigo mobile (puede estar pendiente de implementar)"
fi

# Verificar que dio usa SecurityContext o similar
DIO_FILES=$(find "$MOBILE_SRC" -type f -name "*.dart" | xargs grep -l "SecurityContext\|badCertificate\|onBadCertificate" 2>/dev/null || true)
if [[ -n "$DIO_FILES" ]]; then
  assert_pass "Se encontro configuracion de certificados en Dio:"
  for f in $DIO_FILES; do
    echo -e "       ${BLUE}->${NC} $(basename "$f")"
  done
else
  assert_warn "No se encontro configuracion de validacion de certificados en Dio"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U011: Zod schema acepta HTTPS en desarrollo (validacion estatica)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 6: Validacion de Esquema Zod (env.ts) ---${NC}"

info "TEST-F2-U011: Validando estructura de env.ts..."
ENV_TS="${FRONTEND_SRC}/lib/env.ts"
if [[ -f "$ENV_TS" ]]; then
  if grep -q "zod\|z\." "$ENV_TS"; then
    assert_pass "env.ts utiliza Zod para validacion de esquemas"
  else
    assert_fail "env.ts NO utiliza Zod"
  fi

  if grep -q "url()" "$ENV_TS"; then
    assert_pass "env.ts valida URLs con z.string().url()"
  else
    assert_warn "env.ts no usa z.string().url() explicitamente"
  fi

  # Verificar valores por defecto (deben ser http en dev, pero el .env.example debe ser https)
  DEFAULT_HTTP=$(grep -n "http://localhost" "$ENV_TS" 2>/dev/null || true)
  if [[ -n "$DEFAULT_HTTP" ]]; then
    assert_warn "env.ts tiene defaults con http:// (aceptable para desarrollo local, pero verificar que .env.example usa https)"
  fi
else
  assert_fail "No se encontro env.ts"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-U012: Forzar Secure retorna 421 en request no seguro
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}--- Grupo 7: Middleware de Forzar Secure ---${NC}"

info "TEST-F2-U012: Buscando logica de forzar secure / rechazo HTTP..."

# Buscar middleware o logica que retorne 421
MIDDLEWARE_421=$(find "$FRONTEND_SRC" -type f \( -name "*.ts" -o -name "*.tsx" \) | xargs grep -l "421\|Misdirected\|forceSecure\|x-forwarded-proto" 2>/dev/null || true)
if [[ -n "$MIDDLEWARE_421" ]]; then
  assert_pass "Se encontro logica de rechazo de requests no seguros:"
  for f in $MIDDLEWARE_421; do
    echo -e "       ${BLUE}->${NC} $(basename "$f")"
  done
else
  assert_warn "No se encontro logica explicita de retorno 421 para requests HTTP (verificar middleware.ts o next.config.ts)"
fi

# Verificar que nginx redirige 80->443 (ya validado en Fase 1, revalidar aqui)
if [[ -f "$NGINX_CONF" ]]; then
  if grep -q "return 301 https://" "$NGINX_CONF"; then
    assert_pass "nginx.conf redirige HTTP a HTTPS (301)"
  else
    assert_fail "nginx.conf NO redirige HTTP a HTTPS"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Resumen
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RESUMEN — Tests Unitarios Fase 2${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS:${NC}  $PASS_COUNT"
echo -e "  ${RED}FAIL:${NC}  $FAIL_COUNT"
echo -e "  ${YELLOW}WARN:${NC}  $WARN_COUNT"
echo -e "${BOLD}───────────────────────────────────────────────────────────────────${NC}"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "  ${GREEN}Resultado: TODOS LOS TESTS PASARON${NC}"
  exit 0
else
  echo -e "  ${RED}Resultado: $FAIL_COUNT TEST$( (($FAIL_COUNT == 1)) && echo "" || echo "S" ) FALLARON${NC}"
  exit 1
fi
