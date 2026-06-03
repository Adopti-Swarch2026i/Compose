#!/bin/bash
set -e

# Copiar certs con permisos correctos (igual que el master)
cp /var/lib/postgresql/server.crt /tmp/server.crt
cp /var/lib/postgresql/server.key /tmp/server.key
cp /var/lib/postgresql/ca.crt     /tmp/ca.crt
chown 999:999 /tmp/server.key
chmod 600     /tmp/server.key

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# Solo clonar el master en el primer arranque (PGDATA vacío)
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "[replica] Esperando al master en $REPLICA_PRIMARY_HOST ..."
    until PGPASSWORD=replicator_secret pg_isready -h "$REPLICA_PRIMARY_HOST" -U replicator; do
        sleep 2
    done

    echo "[replica] Clonando master con pg_basebackup..."
    PGPASSWORD=replicator_secret pg_basebackup \
        -h "$REPLICA_PRIMARY_HOST" \
        -U replicator \
        -D "$PGDATA" \
        -P -v -R \
        --no-password

    chown -R 999:999 "$PGDATA"
    chmod 700 "$PGDATA"
fi

echo "[replica] Arrancando PostgreSQL en modo standby..."
exec gosu postgres postgres \
    -D "$PGDATA" \
    -c ssl=on \
    -c ssl_cert_file=/tmp/server.crt \
    -c ssl_key_file=/tmp/server.key \
    -c ssl_ca_file=/tmp/ca.crt \
    -c ssl_min_protocol_version=TLSv1.2 \
    -c hot_standby=on \
    "$@"
