#!/usr/bin/env bash
set -euo pipefail
CERT_DIR=/home/blend-pc-juan/Documentos/Proyecto/ArquisoftPrototype2/Adopti/security
THRESHOLD_DAYS=30

for crt in $(find $CERT_DIR -name '*.crt' ! -name 'ca.crt'); do
  expiry=$(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)
  expiry_epoch=$(date -d "$expiry" +%s)
  now=$(date +%s)
  days_left=$(( (expiry_epoch - now) / 86400 ))
  if (( days_left < THRESHOLD_DAYS )); then
    echo "Rotating $crt (expires in $days_left days)"
    cn=$(openssl x509 -noout -subject -in "$crt" | sed -n 's/.*CN *= *\(.*\)/\1/p')
    # reissue logic here
  fi
done
