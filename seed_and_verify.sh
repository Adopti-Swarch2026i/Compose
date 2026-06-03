#!/bin/bash
# Seed test data en los masters y verifica replicación WAL a las réplicas read-only.
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

PETS_MASTER="Adopti_pets-db"
PETS_REPLICA="Adopti_pets-db-replica"
NOTIF_MASTER="Adopti_notifications-db"
NOTIF_REPLICA="Adopti_notifications-db-replica"

# ── 0. Verificar que los 4 contenedores DB están healthy ─────────────────────

info "Verificando contenedores DB..."
for c in "$PETS_MASTER" "$PETS_REPLICA" "$NOTIF_MASTER" "$NOTIF_REPLICA"; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "missing")
    if [ "$status" != "healthy" ]; then
        fail "$c no está healthy (estado: $status). Corre 'docker compose up -d' primero."
    fi
    ok "$c → healthy"
done

# ── 1. Seed petsdb ────────────────────────────────────────────────────────────

info "\nInsertando datos en petsdb (master)..."

docker exec "$PETS_MASTER" psql -U postgres -d petsdb -c "
INSERT INTO pets (name, type, breed, color, age, image_urls) VALUES
  ('Luna',  'cat', 'Siamese',       'white',         '2 years', '[]'),
  ('Rocky', 'dog', 'Labrador',      'golden',        '3 years', '[]'),
  ('Mochi', 'cat', 'Scottish Fold', 'gray and white','1 year',  '[]')
ON CONFLICT DO NOTHING;
" > /dev/null

PET_IDS=$(docker exec "$PETS_MASTER" psql -U postgres -d petsdb -At -c \
  "SELECT id FROM pets WHERE name IN ('Luna','Rocky','Mochi') ORDER BY id LIMIT 3;")
PET1=$(echo "$PET_IDS" | sed -n '1p')
PET2=$(echo "$PET_IDS" | sed -n '2p')

docker exec "$PETS_MASTER" psql -U postgres -d petsdb -c "
INSERT INTO reports (status, location, city, description, owner_name, owner_phone, pet_id, owner_id) VALUES
  ('lost',  'Parque 93',   'Bogotá',   'Luna se perdió cerca al parque', 'Ana García',    '3101234567', $PET1, 'uid-test-001'),
  ('found', 'Calle 80',    'Bogotá',   'Rocky encontrado sin collar',    'Luis Pérez',    '3209876543', $PET2, 'uid-test-002'),
  ('lost',  'Av. El Lago', 'Medellín', 'Mochi escapó del apartamento',  'Sara Martínez', '3157654321', NULL,  'uid-test-003')
ON CONFLICT DO NOTHING;
" > /dev/null

ok "3 pets y 3 reports insertados"

# ── 2. Seed notificationsdb ───────────────────────────────────────────────────

info "\nInsertando datos en notificationsdb (master)..."

docker exec "$NOTIF_MASTER" psql -U postgres -d notificationsdb -c "
INSERT INTO device_tokens (user_id, token, updated_at) VALUES
  ('uid-test-001', 'fcm-token-ana-abc123',  now()),
  ('uid-test-002', 'fcm-token-luis-def456', now()),
  ('uid-test-003', 'fcm-token-sara-ghi789', now())
ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, updated_at = now();
" > /dev/null

docker exec "$NOTIF_MASTER" psql -U postgres -d notificationsdb -c "
INSERT INTO notifications (user_id, event_id, event_type, channel, status, payload) VALUES
  ('uid-test-001', 'evt-seed-001', 'pet.lost',  'push',  'sent',    '{\"pet\":\"Luna\",  \"city\":\"Bogotá\"}'),
  ('uid-test-002', 'evt-seed-002', 'pet.found', 'push',  'sent',    '{\"pet\":\"Rocky\", \"city\":\"Bogotá\"}'),
  ('uid-test-003', 'evt-seed-003', 'pet.lost',  'email', 'pending', '{\"pet\":\"Mochi\", \"city\":\"Medellín\"}')
ON CONFLICT (event_id, channel) DO NOTHING;
" > /dev/null

ok "3 device_tokens y 3 notifications insertados"

# ── 3. Esperar propagación WAL ────────────────────────────────────────────────

info "\nEsperando propagación WAL (2 s)..."
sleep 2

# ── 4. Verificar réplica petsdb ───────────────────────────────────────────────

info "\nVerificando réplica petsdb..."

PET_COUNT=$(docker exec "$PETS_REPLICA" psql -U postgres -d petsdb -At -c \
  "SELECT COUNT(*) FROM pets WHERE name IN ('Luna','Rocky','Mochi');")
REP_COUNT=$(docker exec "$PETS_REPLICA" psql -U postgres -d petsdb -At -c \
  "SELECT COUNT(*) FROM reports WHERE owner_id IN ('uid-test-001','uid-test-002','uid-test-003');")

[ "$PET_COUNT" -ge 3 ] \
  && ok "Réplica petsdb: $PET_COUNT/3 pets replicados" \
  || fail "Réplica petsdb: solo $PET_COUNT pets (esperado ≥3)"

[ "$REP_COUNT" -ge 3 ] \
  && ok "Réplica petsdb: $REP_COUNT/3 reports replicados" \
  || fail "Réplica petsdb: solo $REP_COUNT reports (esperado ≥3)"

# ── 5. Verificar réplica notificationsdb ─────────────────────────────────────

info "\nVerificando réplica notificationsdb..."

TOK_COUNT=$(docker exec "$NOTIF_REPLICA" psql -U postgres -d notificationsdb -At -c \
  "SELECT COUNT(*) FROM device_tokens WHERE user_id IN ('uid-test-001','uid-test-002','uid-test-003');")
NOT_COUNT=$(docker exec "$NOTIF_REPLICA" psql -U postgres -d notificationsdb -At -c \
  "SELECT COUNT(*) FROM notifications WHERE event_id IN ('evt-seed-001','evt-seed-002','evt-seed-003');")

[ "$TOK_COUNT" -ge 3 ] \
  && ok "Réplica notificationsdb: $TOK_COUNT/3 device_tokens replicados" \
  || fail "Réplica notificationsdb: solo $TOK_COUNT tokens (esperado ≥3)"

[ "$NOT_COUNT" -ge 3 ] \
  && ok "Réplica notificationsdb: $NOT_COUNT/3 notifications replicadas" \
  || fail "Réplica notificationsdb: solo $NOT_COUNT notificaciones (esperado ≥3)"

# ── 6. Confirmar que las réplicas rechazan escrituras ────────────────────────

info "\nVerificando que las réplicas son read-only..."

PETS_WRITE=$(docker exec "$PETS_REPLICA" psql -U postgres -d petsdb -c \
  "INSERT INTO pets(name,type) VALUES('WriteTest','dog');" 2>&1 || true)
NOTIF_WRITE=$(docker exec "$NOTIF_REPLICA" psql -U postgres -d notificationsdb -c \
  "INSERT INTO device_tokens(user_id,token,updated_at) VALUES('write-test','tok',now());" 2>&1 || true)

echo "$PETS_WRITE"  | grep -q "read-only" \
  && ok "Réplica petsdb rechaza INSERT correctamente" \
  || fail "Réplica petsdb aceptó un INSERT (no debería ser posible)"

echo "$NOTIF_WRITE" | grep -q "read-only" \
  && ok "Réplica notificationsdb rechaza INSERT correctamente" \
  || fail "Réplica notificationsdb aceptó un INSERT (no debería ser posible)"

# ── 7. Lag de replicación ─────────────────────────────────────────────────────

info "\nLag de replicación WAL:"
echo "  [petsdb]"
docker exec "$PETS_MASTER" psql -U postgres -c \
  "SELECT application_name, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;" \
  2>/dev/null || echo "  (sin conexiones de replicación activas aún)"

echo "  [notificationsdb]"
docker exec "$NOTIF_MASTER" psql -U postgres -c \
  "SELECT application_name, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;" \
  2>/dev/null || echo "  (sin conexiones de replicación activas aún)"

# ── Resumen ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Todas las verificaciones pasaron      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  petsdb          →  3 pets | 3 reports"
echo "  notificationsdb →  3 device_tokens | 3 notifications"
