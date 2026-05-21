#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NGINX_CONF="$PROJECT_DIR/gateway/nginx.conf"

echo "=== P3 Baseline Verification ==="
ERRORS=0

# 1. Verificar 4 redes Docker
echo "[1/4] Verificando 4 redes Docker..."
NETWORK_COUNT=$(docker network ls --format '{{.Name}}' | grep -cE "frontend-net|backend-net|data-net|broker-net" || true)
if [ "$NETWORK_COUNT" -eq 4 ]; then
    echo "  ✓ 4 redes encontradas"
else
    echo "  ✗ Solo $NETWORK_COUNT redes encontradas (esperadas 4)"
    ERRORS=$((ERRORS + 1))
fi

# 2. Verificar rate limiting en nginx.conf
echo "[2/4] Verificando rate limiting en nginx.conf..."
if [ ! -f "$NGINX_CONF" ]; then
    echo "  ✗ nginx.conf no encontrado en $NGINX_CONF"
    ERRORS=$((ERRORS + 1))
else
    LIMIT_COUNT=$(grep -cE "limit_req|limit_conn" "$NGINX_CONF" || true)
    if [ "$LIMIT_COUNT" -ge 3 ]; then
        echo "  ✓ $LIMIT_COUNT directivas limit_req/limit_conn encontradas"
    else
        echo "  ✗ Solo $LIMIT_COUNT directivas encontradas (esperadas >=3)"
        ERRORS=$((ERRORS + 1))
    fi
fi

# 3. Verificar que solo gateway tiene puertos públicos
echo "[3/4] Verificando puertos públicos..."
PUBLIC_PORTS=$(docker ps --format '{{.Names}} {{.Ports}}' | grep "^Adopti_" | grep "0.0.0.0" | grep -v "Adopti_gateway" || true)
if [ -z "$PUBLIC_PORTS" ]; then
    echo "  ✓ Solo gateway tiene puertos públicos"
else
    echo "  ✗ Servicios con puertos públicos detectados:"
    echo "$PUBLIC_PORTS"
    ERRORS=$((ERRORS + 1))
fi

# 4. Verificar que frontend no resuelve postgres
echo "[4/4] Verificando aislamiento de redes..."
if docker exec Adopti_frontend sh -c "getent hosts postgres" 2>/dev/null; then
    echo "  ✗ Frontend puede resolver postgres (debería estar aislado)"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ Frontend no puede resolver postgres (aislamiento correcto)"
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
