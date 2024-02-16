#!/usr/bin/env bash
# Deletes everything, including the database and docker containers

set -euo pipefail

docker compose down
docker volume rm firezone_postgres-data
docker compose run elixir /bin/sh -c 'cd apps/domain && mix ecto.seed'
docker compose up -d --build --remove-orphans api web client relay gateway dns.httpbin httpbin
