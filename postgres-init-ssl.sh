#!/bin/bash
set -e
# PostgreSQL init script: fuerza SSL rechazando conexiones planas.
# Reemplaza TODAS las reglas 'host all all' por 'hostssl' y agrega 'hostnossl reject'.

# Reemplazar host all all por hostssl all all (conservando la direccion)
sed -i 's/^host[[:space:]]\+all[[:space:]]\+all/hostssl all all/' "$PGDATA/pg_hba.conf"

# Agregar regla catch-all de rechazo para conexiones sin SSL
sed -i '/^hostssl all all all scram-sha-256$/a hostnossl all all all reject' "$PGDATA/pg_hba.conf"

echo "PostgreSQL SSL forced: all 'host' rules converted to 'hostssl', hostnossl reject added"

# Crear usuario de replicación
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_secret' LOGIN;
EOSQL

# Regla SSL para replicación — debe ser hostssl porque postgres-init-ssl.sh
# ya rechaza conexiones sin SSL via "hostnossl reject"
echo "hostssl replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

echo "PostgreSQL replication enabled: user 'replicator' created, pg_hba rule added"
