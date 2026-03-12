#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"
DEFAULT_COUNT="${DEFAULT_COUNT:-100}"
PREFIX="${PREFIX:-thomas-firezone-client}"
IMAGE="${IMAGE:-ghcr.io/firezone/client:main}"

usage() {
  cat <<'EOF'
Usage:
  ./clients.sh [COUNT]

Notes:
  - COUNT defaults to DEFAULT_COUNT or 100.
  - This script only generates docker-compose.yml.
  - Run `docker compose` commands yourself after generation.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

count_arg() {
  local value="${1:-$DEFAULT_COUNT}"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
    die "count must be a positive integer"
  fi
  printf '%s\n' "$value"
}
generate() {
  local count="$1"

  {
    cat <<EOF
x-firezone-env: &firezone-env
  FIREZONE_TOKEN: ".SFMyNTY.g2gDaANtAAAAJDFkM2UzNDRhLTk1MDAtNDVhZi05N2JhLWNmNzJlYWVlYmNhOG0AAAAkMDNmZmZlMDEtZjU1Mi00MDAxLTliMmQtZmIwM2ExZGYxOWJmbQAAADhPVEpVUjZNT09QQ0sySlY4M0s4T0EwSlFDSzJINFZCVlM2SFI1TE85TTNHTFA4OTdHQTAwPT09PW4GAMHbwuCcAWIAAVGA.K8cSzI1GI71qde2bQNvDKUEHz_DTYROklGhHCt1301U"
  FIREZONE_API_URL: "wss://api.firez.one"
  RUST_LOG: "info"

x-firezone-client: &firezone-client
  image: ${IMAGE}
  restart: unless-stopped
  cap_add:
    - NET_ADMIN
  devices:
    - /dev/net/tun:/dev/net/tun
  environment: *firezone-env

services:
EOF

    for ((index = 1; index <= count; index++)); do
      local name
      name="$(printf "%s-%04d" "$PREFIX" "$index")"
      local firezone_id
      firezone_id="$(printf "%s" "$name" | shasum -a 256 | awk '{print $1}')"
      cat <<EOF
  ${name}:
    <<: *firezone-client
    container_name: ${name}
    hostname: ${name}
    environment:
      <<: *firezone-env
      FIREZONE_ID: "${firezone_id}"

EOF
    done
  } >"$COMPOSE_FILE"

  echo "wrote $COMPOSE_FILE with $count clients"
}

main() {
  case "${1:-}" in
    "" )
      generate "$(count_arg)"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      generate "$(count_arg "$1")"
      ;;
  esac
}

main "$@"
