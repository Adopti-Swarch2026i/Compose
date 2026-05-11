#!/bin/bash
set -e
# Entrypoint wrapper: copia certs a /tmp con permisos correctos (como root)
# y luego delega al entrypoint oficial de PostgreSQL.

cp /var/lib/postgresql/server.crt /tmp/server.crt
cp /var/lib/postgresql/server.key /tmp/server.key
cp /var/lib/postgresql/ca.crt /tmp/ca.crt
chown 999:999 /tmp/server.key
chmod 600 /tmp/server.key

exec /usr/local/bin/docker-entrypoint.sh \
  postgres \
  -c ssl=on \
  -c ssl_cert_file=/tmp/server.crt \
  -c ssl_key_file=/tmp/server.key \
  -c ssl_ca_file=/tmp/ca.crt \
  -c ssl_min_protocol_version=TLSv1.2 \
  "$@"
