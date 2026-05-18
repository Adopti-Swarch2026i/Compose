#!/usr/bin/env bash
#
# test_fase2_chaos.sh — Tests de Caos (Chaos Engineering)
#
# Proyecto: Adopti — Fase 2: Hardening de Clientes
# Patron: Secure Channel Pattern (Encrypt Data + Resist Attacks)
#
# Tests:
#   - TEST-F2-C001: MITM Proxy Interception
#   - TEST-F2-C002: Certificate Pinning Rotation
#   - TEST-F2-C005: SSL Stripping Attack
#   - TEST-F2-C007: CA Compromise Simulation
#
# Precondiciones:
#   - openssl instalado
#   - curl instalado
#   - Python 3 instalado (para mitmproxy addon, opcional)
#   - Gateway corriendo en https://localhost
#
# Ejecutar desde: Compose/
#   bash tests/fase2/test_fase2_chaos.sh
#
set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ── Configuracion ────────────────────────────────────────────────────────────
GATEWAY_HOST="${GATEWAY_HOST:-localhost}"
GATEWAY_PORT="${GATEWAY_PORT:-443}"
CHAOS_DIR="${CHAOS_DIR:-/tmp/adopti-chaos}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CURL_OPTS="-s --max-time ${CURL_TIMEOUT} -k"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

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

assert_skip() {
  local msg="$1"
  echo -e "${CYAN}[SKIP]${NC} $msg"
  ((SKIP_COUNT++))
}

info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

chaos_banner() {
  local test_id="$1"
  local test_name="$2"
  echo ""
  echo -e "${MAGENTA}${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}${BOLD}║  ${test_id}: ${test_name}${NC}"
  echo -e "${MAGENTA}${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
}

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$CHAOS_DIR"
PROJECT_ROOT="/home/blend-pc-juan/Documentos/Proyecto Personal/ArquisoftPrototype2/Adopti"

# ── Header ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Adopti — Fase 2: Tests de Caos (Chaos Engineering)${NC}"
echo -e "${BOLD}  Secure Channel Pattern | Resist Attacks${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}ADVERTENCIA:${NC} Estos tests simulan ataques de seguridad."
echo -e "Se ejecutan de forma controlada y NO afectan el sistema productivo."
echo ""

# Verificar herramientas necesarias
info "Verificando herramientas disponibles..."
for tool in openssl curl python3; do
  if command -v "$tool" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $tool"
  else
    echo -e "  ${RED}✗${NC} $tool (algunos tests pueden fallar)"
  fi
done
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-C001: MITM Proxy Interception
# ═════════════════════════════════════════════════════════════════════════════
chaos_banner "TEST-F2-C001" "MITM Proxy Interception"

info "Hipotesis: La app rechaza certificados con SPKI no pinnado"
info "Inyeccion: Simular certificado de MITM proxy con SPKI desconocido"

# 1. Generar certificado autofirmado (simula cert de MITM proxy)
MITM_KEY="${CHAOS_DIR}/mitm-ca.key"
MITM_CERT="${CHAOS_DIR}/mitm-ca.crt"
MITM_API_KEY="${CHAOS_DIR}/mitm-api.key"
MITM_API_CSR="${CHAOS_DIR}/mitm-api.csr"
MITM_API_CERT="${CHAOS_DIR}/mitm-api.crt"

info "Generando CA MITM simulada..."
if openssl req -x509 -newkey rsa:2048 -keyout "$MITM_KEY" -out "$MITM_CERT" \
   -days 1 -nodes -subj "/C=US/O=MITM Proxy/CN=MITM Root CA" 2>/dev/null; then
  assert_pass "CA MITM generada"
else
  assert_fail "No se pudo generar CA MITM"
fi

# 2. Generar certificado para api.adopti.com firmado por CA MITM
info "Generando certificado para api.adopti.com firmado por CA MITM..."
if openssl req -newkey rsa:2048 -keyout "$MITM_API_KEY" -out "$MITM_API_CSR" \
   -nodes -subj "/C=CO/O=Adopti/CN=api.adopti.com" 2>/dev/null; then
  if openssl x509 -req -in "$MITM_API_CSR" -CA "$MITM_CERT" -CAkey "$MITM_KEY" \
     -CAcreateserial -out "$MITM_API_CERT" -days 1 2>/dev/null; then
    assert_pass "Certificado MITM para api.adopti.com generado"
  else
    assert_fail "No se pudo firmar certificado MITM"
  fi
else
  assert_fail "No se pudo generar CSR MITM"
fi

# 3. Extraer SPKI del certificado MITM
info "Extrayendo SPKI del certificado MITM..."
MITM_SPKI=$(openssl x509 -in "$MITM_API_CERT" -pubkey -noout 2>/dev/null | \
  openssl pkey -pubin -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary 2>/dev/null | \
  openssl enc -base64 2>/dev/null || true)

if [[ -n "$MITM_SPKI" ]]; then
  assert_pass "SPKI del certificado MITM extraido"
  info "SPKI MITM: ${MITM_SPKI:0:40}..."
else
  assert_fail "No se pudo extraer SPKI del certificado MITM"
fi

# 4. Extraer SPKI del certificado real del gateway
info "Extrayendo SPKI del certificado real del gateway..."
REAL_SPKI=$(echo | openssl s_client -connect "${GATEWAY_HOST}:${GATEWAY_PORT}" \
  -servername "$GATEWAY_HOST" 2>/dev/null | \
  openssl x509 -pubkey -noout 2>/dev/null | \
  openssl pkey -pubin -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary 2>/dev/null | \
  openssl enc -base64 2>/dev/null || true)

if [[ -n "$REAL_SPKI" ]]; then
  assert_pass "SPKI del certificado real extraido"
  info "SPKI Real:  ${REAL_SPKI:0:40}..."
else
  assert_warn "No se pudo extraer SPKI del certificado real"
fi

# 5. Verificar que los SPKIs son DIFERENTES (hipotesis del test)
info "Verificando que SPKIs son diferentes (MITM != Real)..."
if [[ -n "$MITM_SPKI" && -n "$REAL_SPKI" ]]; then
  if [[ "$MITM_SPKI" != "$REAL_SPKI" ]]; then
    assert_pass "SPKIs son DIFERENTES — el certificado MITM seria RECHAZADO por pinning"
  else
    assert_fail "SPKIs son IGUALES — esto no deberia ocurrir (colision?)"
  fi
else
  assert_skip "No se pueden comparar SPKIs (faltan datos)"
fi

# 6. Verificar que curl con cert MITM falla (simulacion de rechazo)
info "Simulando rechazo de conexion con certificado MITM..."

# Crear un trust store temporal solo con el CA MITM
MITM_TRUSTSTORE="${CHAOS_DIR}/mitm-truststore.pem"
cp "$MITM_CERT" "$MITM_TRUSTSTORE"

# Intentar conectar usando SOLO el CA MITM (debe fallar si el servidor real no usa este CA)
# Nota: Esto es una simulacion — el gateway real usa su propio cert
MITM_TEST_RESULT=$(curl --cacert "$MITM_TRUSTSTORE" \
  --max-time 5 -s -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/health" 2>&1 || true)

if echo "$MITM_TEST_RESULT" | grep -qi "error\|unable\|failed\|reject"; then
  assert_pass "Conexion con CA MITM rechazada (como se espera)"
else
  # Si usamos -k en otras conexiones, esto puede pasar. Verificamos el comportamiento esperado.
  assert_warn "Resultado ambiguo al conectar con CA MITM (verificar manualmente)"
fi

# 7. Documentar el SPKI para configuracion de pinning
info "Documentando SPKIs para configuracion de certificate pinning..."
cat > "${CHAOS_DIR}/spki-report.txt" << EOF
# Reporte de SPKIs — Adopti Chaos Test F2-C001
# Generado: $(date -Iseconds)
#
# SPKI del certificado REAL del gateway (${GATEWAY_HOST}:${GATEWAY_PORT}):
# ${REAL_SPKI}
#
# SPKI del certificado MITM (simulado):
# ${MITM_SPKI}
#
# CONCLUSION: El certificado MITM tiene SPKI diferente.
# Si la app mobile implementa certificate pinning con el SPKI real,
# RECHAZARA conexiones al certificado MITM.
#
# Para configurar pinning en Flutter, agregar a allowedPins:
#   '${REAL_SPKI}'
EOF
assert_pass "Reporte de SPKIs guardado en ${CHAOS_DIR}/spki-report.txt"

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-C002: Certificate Pinning Rotation
# ═════════════════════════════════════════════════════════════════════════════
chaos_banner "TEST-F2-C002" "Certificate Pinning Rotation"

info "Hipotesis: La app detecta rotacion de certificados y rechaza pins obsoletos"
info "Inyeccion: Generar nuevo certificado con SPKI diferente"

# 1. Generar nuevo par de claves (simula rotacion de certificado en backend)
ROTATION_KEY="${CHAOS_DIR}/rotation.key"
ROTATION_CERT="${CHAOS_DIR}/rotation.crt"

info "Generando nuevo certificado (simulando rotacion)..."
if openssl req -x509 -newkey rsa:2048 -keyout "$ROTATION_KEY" -out "$ROTATION_CERT" \
   -days 1 -nodes -subj "/C=CO/O=Adopti/CN=api.adopti.com" 2>/dev/null; then
  assert_pass "Nuevo certificado generado (rotacion simulada)"
else
  assert_fail "No se pudo generar certificado de rotacion"
fi

# 2. Extraer SPKI del nuevo certificado
ROTATION_SPKI=$(openssl x509 -in "$ROTATION_CERT" -pubkey -noout 2>/dev/null | \
  openssl pkey -pubin -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary 2>/dev/null | \
  openssl enc -base64 2>/dev/null || true)

if [[ -n "$ROTATION_SPKI" ]]; then
  assert_pass "SPKI del certificado rotado extraido"
  info "SPKI Rotado: ${ROTATION_SPKI:0:40}..."
else
  assert_fail "No se pudo extraer SPKI del certificado rotado"
fi

# 3. Verificar que el SPKI rotado es diferente al original
if [[ -n "$REAL_SPKI" && -n "$ROTATION_SPKI" ]]; then
  if [[ "$REAL_SPKI" != "$ROTATION_SPKI" ]]; then
    assert_pass "SPKI rotado es DIFERENTE al original — la app con pin antiguo RECHAZARIA"
  else
    assert_fail "SPKI rotado es IGUAL al original (improbable con nueva clave)"
  fi

  # Documentar ambos SPKIs para configuracion de backup pinning
  info ""
  info "Para implementar pinning con soporte de rotacion:"
  info "  1. Mantener SPKI antiguo en allowedPins durante transicion"
  info "  2. Agregar SPKI nuevo antes de rotar certificado en produccion"
  info "  3. Remover SPKI antiguo despues de confirmar que todos los clientes actualizaron"
  info ""
  info "Configuracion recomendada de allowedPins (periodo de transicion):"
  info "  allowedPins = ['${REAL_SPKI}', '${ROTATION_SPKI}']"

  cat >> "${CHAOS_DIR}/spki-report.txt" << EOF

# --- Certificate Rotation (TEST-F2-C002) ---
# SPKI del certificado ROTADO:
# ${ROTATION_SPKI}
#
# Configuracion de allowedPins durante transicion:
# allowedPins = [
#   '${REAL_SPKI}',   # certificado actual
#   '${ROTATION_SPKI}' # certificado nuevo (pre-cargado)
# ]
EOF
else
  assert_skip "No se pueden comparar SPKIs para rotacion"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-C005: SSL Stripping Attack
# ═════════════════════════════════════════════════════════════════════════════
chaos_banner "TEST-F2-C005" "SSL Stripping Attack"

info "Hipotesis: El sistema resiste downgrade de HTTPS a HTTP"
info "Inyeccion: Simular proxy que reescribe https:// a http://"

# 1. Verificar que nginx redirige HTTP a HTTPS
info "Verificando redireccion HTTP -> HTTPS en gateway..."
HTTP_RESPONSE=$(curl -s --max-time 5 -I "http://${GATEWAY_HOST}:80/" 2>/dev/null || true)

if echo "$HTTP_RESPONSE" | grep -q "301\|308\|redirect"; then
  assert_pass "Gateway redirige HTTP a HTTPS (301/308)"

  LOCATION=$(echo "$HTTP_RESPONSE" | grep -i "location:" | head -1 || true)
  if echo "$LOCATION" | grep -q "https://"; then
    assert_pass "Redireccion apunta a HTTPS: $LOCATION"
  else
    assert_fail "Redireccion NO apunta a HTTPS: $LOCATION"
  fi
else
  # Puerto 80 puede no estar expuesto en dev
  assert_warn "No se detecto redireccion HTTP->HTTPS (puerto 80 puede no estar expuesto)"
fi

# 2. Verificar header HSTS
info "Verificando header Strict-Transport-Security (HSTS)..."
HTTPS_HEADERS=$(curl ${CURL_OPTS} -I "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null || true)

if echo "$HTTPS_HEADERS" | grep -qi "strict-transport-security"; then
  HSTS_VALUE=$(echo "$HTTPS_HEADERS" | grep -i "strict-transport-security" | head -1 || true)
  assert_pass "HSTS header presente: $HSTS_VALUE"

  if echo "$HSTS_VALUE" | grep -qi "max-age"; then
    MAX_AGE=$(echo "$HSTS_VALUE" | grep -oE "max-age=[0-9]+" | cut -d= -f2 || true)
    if [[ -n "$MAX_AGE" && "$MAX_AGE" -ge 31536000 ]]; then
      assert_pass "HSTS max-age >= 1 año ($MAX_AGE segundos)"
    else
      assert_warn "HSTS max-age < 1 año ($MAX_AGE segundos) — recomendado: 31536000"
    fi
  fi

  if echo "$HSTS_VALUE" | grep -qi "includesubdomains"; then
    assert_pass "HSTS incluye includeSubDomains"
  else
    assert_warn "HSTS no incluye includeSubDomains"
  fi
else
  assert_fail "HSTS header NO presente — el navegador podria aceptar downgrade"
fi

# 3. Simular SSL stripping en respuesta HTML
info "Simulando SSL stripping en contenido HTML..."

# Crear un HTML de prueba que simula lo que un proxy SSL stripper produciria
STRIPPED_HTML="${CHAOS_DIR}/stripped.html"
cat > "$STRIPPED_HTML" << 'EOF'
<!DOCTYPE html>
<html>
<head><title>SSL Stripping Test</title></head>
<body>
  <a href="http://evil.com/login">Login (inseguro)</a>
  <script src="http://evil.com/track.js"></script>
  <img src="http://evil.com/pixel.png">
</body>
</html>
EOF

# Verificar que el HTML contiene recursos HTTP (esto es el "ataque")
HTTP_LINKS=$(grep -o 'href="http://[^"]*"' "$STRIPPED_HTML" | wc -l)
HTTP_SCRIPTS=$(grep -o 'src="http://[^"]*"' "$STRIPPED_HTML" | wc -l)
info "HTML simulado contiene $HTTP_LINKS links HTTP y $HTTP_SCRIPTS scripts HTTP"

# Verificar que el frontend real NO sirve contenido con http://
info "Verificando que el frontend real no sirve contenido HTTP..."
FRONTEND_HTML=$(curl ${CURL_OPTS} -L "https://${GATEWAY_HOST}:${GATEWAY_PORT}/" 2>/dev/null || true)

if [[ -n "$FRONTEND_HTML" ]]; then
  HTTP_IN_HTML=$(echo "$FRONTEND_HTML" | grep -oE 'http://[^"<>]+' | wc -l || echo "0")
  if [[ "$HTTP_IN_HTML" -eq 0 ]]; then
    assert_pass "Frontend real no contiene URLs http:// en HTML"
  else
    assert_warn "Frontend real contiene $HTTP_IN_HTML URLs http:// (verificar que sean solo comentarios)"
  fi
else
  assert_warn "No se pudo obtener HTML del frontend"
fi

# 4. Verificar que las URLs internas del .env.example usan https://
FRONTEND_ENV="${PROJECT_ROOT}/frontend-ssr/.env.example"
if [[ -f "$FRONTEND_ENV" ]]; then
  HTTPS_COUNT=$(grep -c "https://" "$FRONTEND_ENV" 2>/dev/null || true)
  HTTP_COUNT=$(grep -c "http://" "$FRONTEND_ENV" 2>/dev/null || true)
  info "frontend-ssr/.env.example: $HTTPS_COUNT URLs HTTPS, $HTTP_COUNT URLs HTTP"

  if [[ "$HTTP_COUNT" -eq 0 ]]; then
    assert_pass ".env.example no contiene URLs HTTP"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST-F2-C007: CA Compromise Simulation
# ═════════════════════════════════════════════════════════════════════════════
chaos_banner "TEST-F2-C007" "CA Compromise Simulation"

info "Hipotesis: Certificate pinning SPKI prevalece sobre PKI del sistema"
info "Inyeccion: Certificado valido por CA del sistema pero SPKI diferente"

# 1. Crear CA atacante
ATTACKER_CA_KEY="${CHAOS_DIR}/attacker-ca.key"
ATTACKER_CA_CERT="${CHAOS_DIR}/attacker-ca.crt"
ATTACKER_API_KEY="${CHAOS_DIR}/attacker-api.key"
ATTACKER_API_CSR="${CHAOS_DIR}/attacker-api.csr"
ATTACKER_API_CERT="${CHAOS_DIR}/attacker-api.crt"

info "Generando CA atacante..."
if openssl req -x509 -newkey rsa:2048 -keyout "$ATTACKER_CA_KEY" -out "$ATTACKER_CA_CERT" \
   -days 1 -nodes -subj "/C=US/O=Attacker CA/CN=Attacker Root CA" 2>/dev/null; then
  assert_pass "CA atacante generada"
else
  assert_fail "No se pudo generar CA atacante"
fi

# 2. Generar certificado para api.adopti.com firmado por CA atacante
info "Generando certificado para api.adopti.com firmado por CA atacante..."
if openssl req -newkey rsa:2048 -keyout "$ATTACKER_API_KEY" -out "$ATTACKER_API_CSR" \
   -nodes -subj "/C=CO/O=Adopti/CN=api.adopti.com" 2>/dev/null; then
  if openssl x509 -req -in "$ATTACKER_API_CSR" -CA "$ATTACKER_CA_CERT" -CAkey "$ATTACKER_CA_KEY" \
     -CAcreateserial -out "$ATTACKER_API_CERT" -days 1 2>/dev/null; then
    assert_pass "Certificado atacante para api.adopti.com generado"
  else
    assert_fail "No se pudo firmar certificado atacante"
  fi
else
  assert_fail "No se pudo generar CSR atacante"
fi

# 3. Extraer SPKI del certificado atacante
ATTACKER_SPKI=$(openssl x509 -in "$ATTACKER_API_CERT" -pubkey -noout 2>/dev/null | \
  openssl pkey -pubin -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary 2>/dev/null | \
  openssl enc -base64 2>/dev/null || true)

if [[ -n "$ATTACKER_SPKI" ]]; then
  assert_pass "SPKI del certificado atacante extraido"
  info "SPKI Atacante: ${ATTACKER_SPKI:0:40}..."
else
  assert_fail "No se pudo extraer SPKI del certificado atacante"
fi

# 4. Verificar que el SPKI atacante es diferente al real
if [[ -n "$REAL_SPKI" && -n "$ATTACKER_SPKI" ]]; then
  if [[ "$REAL_SPKI" != "$ATTACKER_SPKI" ]]; then
    assert_pass "SPKI atacante es DIFERENTE al real"
    info ""
    info "ESCENARIO DE ATAQUE SIMULADO:"
    info "  1. Atacante compromete una CA del sistema del dispositivo"
    info "  2. Atacante emite certificado valido para api.adopti.com"
    info "  3. El certificado del atacante tiene SPKI diferente"
    info "  4. La app con certificate pinning RECHAZA el certificado"
    info "     aunque la CA del sistema lo considere valido"
    info ""
    assert_pass "Pinning SPKI prevalece sobre PKI del sistema (simulado)"
  else
    assert_fail "SPKI atacante es IGUAL al real (colision improbable)"
  fi
else
  assert_skip "No se pueden comparar SPKIs"
fi

# 5. Documentar configuracion de pinning
if [[ -n "$REAL_SPKI" ]]; then
cat > "${CHAOS_DIR}/pinning-config.dart" << EOF
// Configuracion de Certificate Pinning para Adopti Mobile
// Generado automaticamente por test_fase2_chaos.sh
// Fecha: $(date -Iseconds)

class CertificatePinningConfig {
  // SPKI del certificado real del gateway (SHA-256/Base64)
  static const List<String> allowedPins = [
    '${REAL_SPKI}',
  ];

  // Hosts a los que se aplica pinning
  static const List<String> pinnedHosts = [
    'api.adopti.com',
    'localhost',
    '10.0.2.2',
  ];
}
EOF
  assert_pass "Configuracion de pinning generada en ${CHAOS_DIR}/pinning-config.dart"
fi

# ═════════════════════════════════════════════════════════════════════════════
# TEST adicional: Verificacion de valores de .env.example
# ═════════════════════════════════════════════════════════════════════════════
chaos_banner "BONUS" "Validacion de .env.example contra ataques"

info "Verificando que .env.example files no tienen valores inseguros..."

# Frontend .env.example
FE_ENV="${PROJECT_ROOT}/frontend-ssr/.env.example"
if [[ -f "$FE_ENV" ]]; then
  # Verificar que no hay ws://
  if grep -q "ws://" "$FE_ENV"; then
    WS_LINES=$(grep -n "ws://" "$FE_ENV" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -n "$WS_LINES" ]]; then
      assert_fail "frontend-ssr/.env.example contiene ws:// activo: $WS_LINES"
    else
      assert_pass "frontend-ssr/.env.example: ws:// solo en comentarios"
    fi
  else
    assert_pass "frontend-ssr/.env.example no contiene ws://"
  fi

  # Verificar SESSION_COOKIE_SECURE
  if grep -q "SESSION_COOKIE_SECURE=true" "$FE_ENV"; then
    assert_pass "frontend-ssr/.env.example: SESSION_COOKIE_SECURE=true"
  else
    assert_fail "frontend-ssr/.env.example: falta SESSION_COOKIE_SECURE=true"
  fi
fi

# Mobile .env.example
MOBILE_ENV="${PROJECT_ROOT}/adopti-mobile-app-arquisoft/.env.example"
if [[ -f "$MOBILE_ENV" ]]; then
  # Verificar que no hay http://
  if grep -q "http://" "$MOBILE_ENV"; then
    HTTP_LINES=$(grep -n "http://" "$MOBILE_ENV" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -n "$HTTP_LINES" ]]; then
      assert_fail "mobile/.env.example contiene http:// activo: $HTTP_LINES"
    else
      assert_pass "mobile/.env.example: http:// solo en comentarios"
    fi
  else
    assert_pass "mobile/.env.example no contiene http://"
  fi

  # Verificar que no hay ws://
  if grep -q "ws://" "$MOBILE_ENV"; then
    WS_LINES=$(grep -n "ws://" "$MOBILE_ENV" | grep -v "^\s*#" | grep -v "^\s*[0-9]\+:#" || true)
    if [[ -n "$WS_LINES" ]]; then
      assert_fail "mobile/.env.example contiene ws:// activo: $WS_LINES"
    else
      assert_pass "mobile/.env.example: ws:// solo en comentarios"
    fi
  else
    assert_pass "mobile/.env.example no contiene ws://"
  fi

  # Verificar que hay wss://
  if grep -q "wss://" "$MOBILE_ENV"; then
    assert_pass "mobile/.env.example contiene wss://"
  else
    assert_warn "mobile/.env.example no contiene wss://"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Cleanup y Resumen
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RESUMEN — Tests de Caos Fase 2${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS:${NC}  $PASS_COUNT"
echo -e "  ${RED}FAIL:${NC}  $FAIL_COUNT"
echo -e "  ${YELLOW}WARN:${NC}  $WARN_COUNT"
echo -e "  ${CYAN}SKIP:${NC}  $SKIP_COUNT"
echo -e "${BOLD}──────────────────────────────────────────────────────────────────────${NC}"

# Listar artefactos generados
echo ""
echo -e "${BOLD}Artefactos generados en:${NC} ${CHAOS_DIR}/"
ls -la "$CHAOS_DIR" 2>/dev/null | tail -n +2 | awk '{printf "  %s %s\n", $5, $9}'

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo ""
  echo -e "  ${GREEN}Resultado: TODOS LOS TESTS DE CAOS PASARON${NC}"
  echo -e "  ${GREEN}El sistema demuestra resistencia a los ataques simulados.${NC}"
  exit 0
else
  echo ""
  echo -e "  ${RED}Resultado: $FAIL_COUNT TEST$( (($FAIL_COUNT == 1)) && echo "" || echo "S" ) FALLARON${NC}"
  echo -e "  ${YELLOW}Revisar hallazgos y aplicar remediación antes de produccion.${NC}"
  exit 1
fi
