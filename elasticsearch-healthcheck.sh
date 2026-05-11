#!/bin/sh
# Healthcheck script for Elasticsearch that reads password from env var
# without exposing it in docker-compose command logs.
curl -fsS -k -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_cluster/health || exit 1
