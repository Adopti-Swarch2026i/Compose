#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NGINX_CONF="$PROJECT_DIR/gateway/nginx.conf"

echo "=== P3 Baseline Verification ==="
ERRORS=0

assert_ok() {
    echo "  ✓ $1"
}

assert_fail() {
    echo "  ✗ $1"
    ERRORS=$((ERRORS + 1))
}

active_location_block() {
    local location="$1"
    awk -v target="$location" '
        $0 ~ "location[[:space:]]+" target "[[:space:]]*\\{" {
            in_block=1
            depth=0
        }
        in_block {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)
            print line
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth <= 0) {
                in_block=0
            }
        }
    ' "$NGINX_CONF"
}

location_has_active_limit() {
    local location="$1"
    active_location_block "$location" | grep -Eq "^[[:space:]]*limit_req[[:space:]]+zone="
}

# 1. Verificar 4 redes Docker
echo "[1/6] Verificando 4 redes Docker..."
NETWORK_COUNT=$(docker network ls --format '{{.Name}}' | grep -cE "frontend-net|backend-net|data-net|broker-net" || true)
if [ "$NETWORK_COUNT" -eq 4 ]; then
    assert_ok "4 redes encontradas"
else
    assert_fail "Solo $NETWORK_COUNT redes encontradas (esperadas 4)"
fi

# 2. Verificar rate limiting en nginx.conf
echo "[2/6] Verificando rate limiting en nginx.conf..."
if [ ! -f "$NGINX_CONF" ]; then
    assert_fail "nginx.conf no encontrado en $NGINX_CONF"
else
    if grep -q "limit_req_zone .*zone=api_general.*rate=10r/s" "$NGINX_CONF" \
        && grep -q "limit_req_zone .*zone=api_write.*rate=5r/s" "$NGINX_CONF" \
        && grep -q "limit_conn_zone .*zone=conn_per_ip" "$NGINX_CONF"; then
        assert_ok "zonas api_general, api_write y conn_per_ip configuradas"
    else
        assert_fail "zonas de rate limiting incompletas"
    fi

    RATE_LIMITED_LOCATIONS=(
        "= /api/chat/graphql"
        "/api/chat/"
        "/api/notifications"
        "/api/matches"
        "/api/search"
        "/api/media"
        "/api/chat/ws"
    )

    for location in "${RATE_LIMITED_LOCATIONS[@]}"; do
        if location_has_active_limit "$location"; then
            assert_ok "location ${location} tiene limit_req activo"
        else
            assert_fail "location ${location} no tiene limit_req activo"
        fi
    done

    if location_has_active_limit "/api/pets"; then
        assert_fail "location /api/pets tiene limit_req activo; debe quedar libre para pruebas P3 de performance"
    else
        assert_ok "location /api/pets sin limit_req activo (excepcion para performance P3)"
    fi
fi

# 3. Verificar que solo gateway tiene puertos públicos
echo "[3/6] Verificando puertos públicos..."
PUBLIC_PORTS=$(docker ps --format '{{.Names}} {{.Ports}}' | grep "^Adopti_" | grep "0.0.0.0" | grep -v "Adopti_gateway" || true)
if [ -z "$PUBLIC_PORTS" ]; then
    assert_ok "Solo gateway tiene puertos públicos"
else
    echo "  ✗ Servicios con puertos públicos detectados:"
    echo "$PUBLIC_PORTS"
    ERRORS=$((ERRORS + 1))
fi

# 4. Verificar que frontend no resuelve postgres
echo "[4/6] Verificando aislamiento de redes..."
if docker exec Adopti_frontend sh -c "getent hosts postgres" 2>/dev/null; then
    assert_fail "Frontend puede resolver postgres (debería estar aislado)"
else
    assert_ok "Frontend no puede resolver postgres (aislamiento correcto)"
fi

# 5. Verificar reverse proxy del frontend
echo "[5/6] Verificando gateway -> frontend..."
ROOT_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/ || true)
if [ "$ROOT_STATUS" = "200" ]; then
    assert_ok "https://localhost/ responde 200"
else
    assert_fail "https://localhost/ responde ${ROOT_STATUS:-sin respuesta} (esperado 200)"
fi

# 6. Verificar rate limiting dinamico en un endpoint limitado
echo "[6/6] Verificando HTTP 429 en endpoint con rate limiting..."
RATE_RESULT=$(
    for _ in $(seq 1 50); do
        curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/api/search || true
    done | sort | uniq -c
)
echo "$RATE_RESULT" | sed 's/^/    /'
RATE_429=$(echo "$RATE_RESULT" | awk '$2 == "429" {print $1 + 0}')
if [ "${RATE_429:-0}" -gt 0 ]; then
    assert_ok "/api/search rechaza rafagas con HTTP 429"
else
    assert_fail "/api/search no produjo HTTP 429 bajo rafaga"
fi

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "=== ✅ TODAS LAS VERIFICACIONES PASARON ==="
    exit 0
else
    echo ""
    echo "=== ❌ $ERRORS VERIFICACIONES FALLARON ==="
    exit 1
fi
